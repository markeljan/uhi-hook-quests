// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {SwapAndBridgeRouter, IOptimismStandardBridge} from "../src/SwapAndBridgeRouter.sol";

contract MockStandardBridge is IOptimismStandardBridge {
    error BridgePaused();

    address public recipient;
    address public remoteToken;
    uint256 public amount;
    uint32 public minGasLimit;
    bool public paused;

    function setPaused(bool value) external {
        paused = value;
    }

    function bridgeETHTo(address to, uint32 gasLimit, bytes calldata) external payable {
        if (paused) revert BridgePaused();
        recipient = to;
        minGasLimit = gasLimit;
        amount = msg.value;
    }

    function bridgeERC20To(address local, address remote, address to, uint256 value, uint32 gasLimit, bytes calldata)
        external
    {
        if (paused) revert BridgePaused();
        recipient = to;
        remoteToken = remote;
        minGasLimit = gasLimit;
        amount = value;
        require(MockERC20(local).transferFrom(msg.sender, address(this), value));
    }
}

contract SwapAndBridgeRouterTest is Deployers {
    using StateLibrary for *;

    uint128 internal constant AMOUNT_IN = 0.001 ether;
    uint32 internal constant BRIDGE_GAS = 200_000;
    MockStandardBridge internal bridge;
    SwapAndBridgeRouter internal router;
    MockERC20 internal token;
    address internal trader = makeAddr("trader");
    address internal recipient = makeAddr("recipient");
    address internal remoteToken = makeAddr("remoteToken");

    function setUp() public {
        deployFreshManagerAndRouters();
        token = MockERC20(Currency.unwrap(deployMintAndApproveCurrency()));
        (key,) = initPool(
            Currency.wrap(address(0)), Currency.wrap(address(token)), IHooks(address(0)), 3000, SQRT_PRICE_1_1
        );
        vm.deal(address(this), 10 ether);
        modifyLiquidityRouter.modifyLiquidity{value: 1 ether}(key, LIQUIDITY_PARAMS, ZERO_BYTES);
        bridge = new MockStandardBridge();
        router = new SwapAndBridgeRouter(manager, bridge, address(token), remoteToken);
        token.mint(trader, 1 ether);
        vm.deal(trader, 1 ether);
        vm.prank(trader);
        token.approve(address(router), type(uint256).max);
    }

    function testBridgesERC20OutputToSelectedRecipient() public {
        vm.prank(trader);
        uint256 output = router.swap{value: AMOUNT_IN}(key, order(true, true), ZERO_BYTES);

        assertEq(token.balanceOf(address(bridge)), output);
        assertEq(token.balanceOf(address(router)), 0);
        assertEq(token.allowance(address(router), address(bridge)), 0);
        assertEq(bridge.amount(), output);
        assertEq(bridge.remoteToken(), remoteToken);
        assertEq(bridge.recipient(), recipient);
        assertEq(bridge.minGasLimit(), BRIDGE_GAS);
        assertEq(trader.balance, 1 ether - AMOUNT_IN);
    }

    function testBridgesNativeOutputToSelectedRecipient() public {
        vm.prank(trader);
        uint256 output = router.swap(key, order(false, true), ZERO_BYTES);

        assertEq(address(bridge).balance, output);
        assertEq(address(router).balance, 0);
        assertEq(bridge.amount(), output);
        assertEq(bridge.recipient(), recipient);
        assertEq(bridge.minGasLimit(), BRIDGE_GAS);
        assertEq(token.balanceOf(trader), 1 ether - AMOUNT_IN);
    }

    function testLocalSwapSkipsBridge() public {
        vm.prank(trader);
        uint256 output = router.swap{value: AMOUNT_IN}(key, order(true, false), ZERO_BYTES);

        assertEq(token.balanceOf(recipient), output);
        assertEq(bridge.amount(), 0);
    }

    function testRejectsExpiredOrderAndWrongNativeValue() public {
        SwapAndBridgeRouter.Order memory params = order(true, true);
        vm.warp(uint256(params.deadline) + 1);
        vm.expectRevert(SwapAndBridgeRouter.InvalidOrder.selector);
        vm.prank(trader);
        router.swap{value: AMOUNT_IN}(key, params, ZERO_BYTES);

        vm.expectRevert(SwapAndBridgeRouter.InvalidNativeValue.selector);
        vm.prank(trader);
        router.swap{value: AMOUNT_IN - 1}(key, order(true, true), ZERO_BYTES);
    }

    function testRejectsOutputBelowMinimum() public {
        SwapAndBridgeRouter.Order memory params = order(true, true);
        params.minAmountOut = 1 ether;
        vm.expectRevert(SwapAndBridgeRouter.InsufficientOutput.selector);
        vm.prank(trader);
        router.swap{value: AMOUNT_IN}(key, params, ZERO_BYTES);
    }

    function testRejectsPartialFillAtPriceLimit() public {
        SwapAndBridgeRouter.Order memory params = order(true, true);
        params.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(-1);
        vm.expectRevert(SwapAndBridgeRouter.PartialFill.selector);
        vm.prank(trader);
        router.swap{value: AMOUNT_IN}(key, params, ZERO_BYTES);
    }

    function testRejectsUnmappedBridgeToken() public {
        SwapAndBridgeRouter nativeOnlyRouter = new SwapAndBridgeRouter(manager, bridge, address(0), address(0));
        vm.expectRevert(SwapAndBridgeRouter.UnsupportedBridgeToken.selector);
        vm.prank(trader);
        nativeOnlyRouter.swap{value: AMOUNT_IN}(key, order(true, true), ZERO_BYTES);
    }

    function testBridgeRevertRollsBackSwap() public {
        bridge.setPaused(true);
        vm.expectRevert(MockStandardBridge.BridgePaused.selector);
        vm.prank(trader);
        router.swap{value: AMOUNT_IN}(key, order(true, true), ZERO_BYTES);

        (uint160 sqrtPrice,,,) = manager.getSlot0(key.toId());
        assertEq(sqrtPrice, SQRT_PRICE_1_1);
        assertEq(trader.balance, 1 ether);
        assertEq(token.balanceOf(address(router)), 0);
        assertEq(token.allowance(address(router), address(bridge)), 0);
    }

    function order(bool zeroForOne, bool shouldBridge) internal view returns (SwapAndBridgeRouter.Order memory) {
        return SwapAndBridgeRouter.Order({
            amountIn: AMOUNT_IN,
            minAmountOut: 1,
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT,
            deadline: uint48(block.timestamp + 60),
            bridgeGasLimit: BRIDGE_GAS,
            zeroForOne: zeroForOne,
            bridge: shouldBridge,
            recipient: recipient
        });
    }
}
