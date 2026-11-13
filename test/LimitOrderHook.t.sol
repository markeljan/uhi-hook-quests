// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {LimitOrderHook} from "../src/LimitOrderHook.sol";

contract FeeOnTransferToken is MockERC20 {
    constructor() MockERC20("Fee token", "FEE", 18) {}

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        super.transferFrom(from, to, amount);
        _burn(to, amount / 100);
        return true;
    }
}

contract LimitOrderHookTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    uint24 internal constant FEE = 3_000;
    int24 internal constant TICK_SPACING = 60;
    int24 internal constant TRIGGER_TICK = 40;
    uint128 internal constant ORDER_AMOUNT = 10 ether;
    uint128 internal constant MIN_OUTPUT = 9 ether;

    LimitOrderHook internal hook;
    MockERC20 internal token0;
    MockERC20 internal token1;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal keeper = makeAddr("keeper");

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        token0 = MockERC20(Currency.unwrap(currency0));
        token1 = MockERC20(Currency.unwrap(currency1));

        address hookAddress = address(uint160(Hooks.AFTER_SWAP_FLAG));
        deployCodeTo("LimitOrderHook.sol", abi.encode(manager), hookAddress);
        hook = LimitOrderHook(hookAddress);

        (key,) = initPool(currency0, currency1, hook, FEE, TICK_SPACING, SQRT_PRICE_1_1);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(-6000),
            TickMath.getSqrtPriceAtTick(6000),
            10_000 ether,
            10_000 ether
        );
        modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams(-6000, 6000, int256(uint256(liquidity)), bytes32(0)), ZERO_BYTES
        );

        token0.mint(alice, 1_000 ether);
        token1.mint(alice, 1_000 ether);
        vm.startPrank(alice);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    function test_placeCrossExecuteAndSettleToRecipient() public {
        uint256 orderId = placeZeroForOne(MIN_OUTPUT, alice);
        assertEq(token0.balanceOf(address(hook)), ORDER_AMOUNT);

        vm.prank(keeper);
        vm.expectPartialRevert(LimitOrderHook.OrderNotTriggered.selector);
        hook.executeOrder(orderId);

        moveTickUp();
        assertTrue(hook.isTriggered(orderId));

        uint256 balanceBefore = token1.balanceOf(alice);
        vm.prank(keeper);
        uint128 amountOut = hook.executeOrder(orderId);

        assertGe(amountOut, MIN_OUTPUT);
        assertEq(token1.balanceOf(alice) - balanceBefore, amountOut);
        assertEq(token0.balanceOf(address(hook)), 0);
        assertEq(hook.getOrder(orderId).owner, address(0));
    }

    function test_crossingSwapEmitsOneKeeperPriceObservation() public {
        vm.recordLogs();
        moveTickUp();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (uint160 expectedSqrtPriceX96, int24 expectedTick) = currentPrice();
        bytes32 expectedPoolId = PoolId.unwrap(key.toId());
        uint256 observations;

        for (uint256 i; i < logs.length; i++) {
            Vm.Log memory entry = logs[i];
            if (
                entry.emitter == address(hook) && entry.topics.length != 0
                    && entry.topics[0] == LimitOrderHook.PoolPriceObserved.selector
            ) {
                observations++;
                assertEq(entry.topics[1], expectedPoolId);
                (uint160 observedSqrtPriceX96, int24 observedTick) = abi.decode(entry.data, (uint160, int24));
                assertEq(observedSqrtPriceX96, expectedSqrtPriceX96);
                assertEq(observedTick, expectedTick);
            }
        }

        assertEq(observations, 1);
    }

    function test_oneForZeroOrderExecutesAfterDownwardCross() public {
        uint256 orderId;
        vm.prank(alice);
        orderId = hook.placeOrder(
            key,
            false,
            ORDER_AMOUNT,
            MIN_OUTPUT,
            -TRIGGER_TICK,
            TickMath.getSqrtPriceAtTick(-20),
            uint64(block.timestamp + 1 days),
            bob
        );

        swap(key, true, -int256(100 ether), ZERO_BYTES);
        assertLe(currentTick(), -TRIGGER_TICK);

        uint256 balanceBefore = token0.balanceOf(bob);
        vm.prank(keeper);
        uint128 amountOut = hook.executeOrder(orderId);
        assertGe(amountOut, MIN_OUTPUT);
        assertEq(token0.balanceOf(bob) - balanceBefore, amountOut);
    }

    function test_ownerCanCancelAndRecoverAllEscrow() public {
        uint256 balanceBefore = token0.balanceOf(alice);
        uint256 orderId = placeZeroForOne(MIN_OUTPUT, alice);

        vm.prank(bob);
        vm.expectRevert(LimitOrderHook.NotOrderOwner.selector);
        hook.cancelOrder(orderId);

        vm.prank(alice);
        hook.cancelOrder(orderId);

        assertEq(token0.balanceOf(alice), balanceBefore);
        assertEq(token0.balanceOf(address(hook)), 0);
        assertEq(hook.getOrder(orderId).owner, address(0));
    }

    function test_minimumOutputFailurePreservesEscrowAndOrder() public {
        uint256 balanceBefore = token0.balanceOf(alice);
        uint256 orderId = placeZeroForOne(100 ether, alice);
        moveTickUp();

        vm.prank(keeper);
        vm.expectPartialRevert(LimitOrderHook.MinimumOutputNotMet.selector);
        hook.executeOrder(orderId);

        assertEq(hook.getOrder(orderId).owner, alice);
        assertEq(token0.balanceOf(address(hook)), ORDER_AMOUNT);

        vm.prank(alice);
        hook.cancelOrder(orderId);
        assertEq(token0.balanceOf(alice), balanceBefore);
    }

    function test_priceLimitPartialFillPreservesEscrowAndOrder() public {
        uint128 largeOrder = 500 ether;
        vm.prank(alice);
        uint256 orderId = hook.placeOrder(
            key,
            true,
            largeOrder,
            1,
            TRIGGER_TICK,
            TickMath.getSqrtPriceAtTick(-1),
            uint64(block.timestamp + 1 days),
            alice
        );
        moveTickUp();

        vm.prank(keeper);
        vm.expectPartialRevert(LimitOrderHook.PartialFill.selector);
        hook.executeOrder(orderId);

        assertEq(hook.getOrder(orderId).owner, alice);
        assertEq(token0.balanceOf(address(hook)), largeOrder);

        vm.prank(alice);
        hook.cancelOrder(orderId);
        assertEq(token0.balanceOf(address(hook)), 0);
    }

    function test_expiredOrderCannotExecuteButCanBeCancelled() public {
        uint256 orderId = placeZeroForOne(MIN_OUTPUT, alice);
        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(keeper);
        vm.expectRevert(LimitOrderHook.OrderExpired.selector);
        hook.executeOrder(orderId);

        vm.prank(alice);
        hook.cancelOrder(orderId);
        assertEq(hook.getOrder(orderId).owner, address(0));
    }

    function test_rejectsWrongSidePriceLimit() public {
        vm.prank(alice);
        vm.expectRevert(LimitOrderHook.InvalidPriceLimit.selector);
        hook.placeOrder(
            key,
            true,
            ORDER_AMOUNT,
            MIN_OUTPUT,
            TRIGGER_TICK,
            TickMath.getSqrtPriceAtTick(500),
            uint64(block.timestamp + 1 days),
            alice
        );
    }

    function test_rejectsTriggerOutsideTickMathBounds() public {
        vm.prank(alice);
        vm.expectRevert(LimitOrderHook.TriggerOutOfBounds.selector);
        hook.placeOrder(
            key,
            true,
            ORDER_AMOUNT,
            MIN_OUTPUT,
            int24(TickMath.MAX_TICK + 1),
            TickMath.getSqrtPriceAtTick(20),
            uint64(block.timestamp + 1 days),
            alice
        );
    }

    function test_rejectsFeeOnTransferInputWithoutTouchingExistingBalance() public {
        FeeOnTransferToken feeToken = new FeeOnTransferToken();
        MockERC20 pairToken = new MockERC20("Pair token", "PAIR", 18);
        Currency feeCurrency = Currency.wrap(address(feeToken));
        Currency pairCurrency = Currency.wrap(address(pairToken));
        Currency first = feeCurrency < pairCurrency ? feeCurrency : pairCurrency;
        Currency second = feeCurrency < pairCurrency ? pairCurrency : feeCurrency;
        (PoolKey memory feeKey,) = initPool(first, second, hook, FEE, TICK_SPACING, SQRT_PRICE_1_1);
        bool feeIsCurrency0 = Currency.unwrap(first) == address(feeToken);

        feeToken.mint(address(hook), 3 ether);
        feeToken.mint(alice, ORDER_AMOUNT);
        vm.startPrank(alice);
        feeToken.approve(address(hook), type(uint256).max);
        vm.expectPartialRevert(LimitOrderHook.EscrowAmountMismatch.selector);
        hook.placeOrder(
            feeKey,
            feeIsCurrency0,
            ORDER_AMOUNT,
            1,
            feeIsCurrency0 ? TRIGGER_TICK : -TRIGGER_TICK,
            TickMath.getSqrtPriceAtTick(feeIsCurrency0 ? int24(20) : int24(-20)),
            uint64(block.timestamp + 1 days),
            alice
        );
        vm.stopPrank();

        assertEq(feeToken.balanceOf(address(hook)), 3 ether);
        assertEq(feeToken.balanceOf(alice), ORDER_AMOUNT);
    }

    function placeZeroForOne(uint128 minAmountOut, address recipient) internal returns (uint256 orderId) {
        vm.prank(alice);
        orderId = hook.placeOrder(
            key,
            true,
            ORDER_AMOUNT,
            minAmountOut,
            TRIGGER_TICK,
            TickMath.getSqrtPriceAtTick(20),
            uint64(block.timestamp + 1 days),
            recipient
        );
    }

    function moveTickUp() internal {
        swap(key, false, -int256(100 ether), ZERO_BYTES);
        assertGe(currentTick(), TRIGGER_TICK);
    }

    function currentTick() internal view returns (int24 tick) {
        (, tick) = currentPrice();
    }

    function currentPrice() internal view returns (uint160 sqrtPriceX96, int24 tick) {
        (sqrtPriceX96, tick,,) = manager.getSlot0(key.toId());
    }
}
