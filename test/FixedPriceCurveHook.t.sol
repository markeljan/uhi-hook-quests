// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {FixedPriceCurveHook} from "../src/FixedPriceCurveHook.sol";

contract FixedPriceCurveHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;

    FixedPriceCurveHook internal hook;

    uint160 internal constant FLAGS =
        uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
    uint128 internal constant PRICE_NUMERATOR = 2;
    uint128 internal constant PRICE_DENOMINATOR = 1;
    uint128 internal constant MAXIMUM_INPUT = 100 ether;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        deployCodeTo(
            "FixedPriceCurveHook.sol",
            abi.encode(
                manager,
                currency0,
                currency1,
                uint24(3_000),
                int24(60),
                PRICE_NUMERATOR,
                PRICE_DENOMINATOR,
                MAXIMUM_INPUT
            ),
            address(FLAGS)
        );
        hook = FixedPriceCurveHook(payable(address(FLAGS)));

        (key,) = initPool(currency0, currency1, hook, 3_000, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -60_000, tickUpper: 60_000, liquidityDelta: 10_000 ether, salt: 0}),
            ZERO_BYTES
        );

        currency0.transfer(address(hook), 1_000 ether);
        currency1.transfer(address(hook), 1_000 ether);
    }

    function test_zeroForOneUsesFixedPriceAndRealSettlement() public {
        uint256 amountIn = 5 ether;
        uint256 expectedOut = 10 ether;
        uint256 trader0Before = currency0.balanceOf(address(this));
        uint256 trader1Before = currency1.balanceOf(address(this));
        uint256 hook0Before = currency0.balanceOf(address(hook));
        uint256 hook1Before = currency1.balanceOf(address(hook));
        uint256 hook0ClaimsBefore = manager.balanceOf(address(hook), currency0.toId());
        (uint160 sqrtPriceBefore,,,) = manager.getSlot0(key.toId());

        BalanceDelta delta = swap(key, true, -amountIn.toInt256(), ZERO_BYTES);

        assertEq(delta.amount0(), -amountIn.toInt256());
        assertEq(delta.amount1(), expectedOut.toInt256());
        assertEq(currency0.balanceOf(address(this)), trader0Before - amountIn);
        assertEq(currency1.balanceOf(address(this)), trader1Before + expectedOut);
        assertEq(currency0.balanceOf(address(hook)), hook0Before);
        assertEq(manager.balanceOf(address(hook), currency0.toId()), hook0ClaimsBefore + amountIn);
        assertEq(currency1.balanceOf(address(hook)), hook1Before - expectedOut);
        (uint160 sqrtPriceAfter,,,) = manager.getSlot0(key.toId());
        assertEq(sqrtPriceAfter, sqrtPriceBefore, "core concentrated-liquidity curve should be bypassed");
    }

    function test_oneForZeroUsesReciprocalFixedPrice() public {
        uint256 amountIn = 10 ether;
        uint256 expectedOut = 5 ether;

        BalanceDelta delta = swap(key, false, -amountIn.toInt256(), ZERO_BYTES);

        assertEq(delta.amount1(), -amountIn.toInt256());
        assertEq(delta.amount0(), expectedOut.toInt256());
    }

    function test_exactOutputIsRejected() public {
        _expectHookRevert(abi.encodeWithSelector(FixedPriceCurveHook.ExactOutputUnsupported.selector));
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: 1 ether, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    function test_perSwapInputLimitIsEnforced() public {
        _expectHookRevert(
            abi.encodeWithSelector(
                FixedPriceCurveHook.SwapAmountTooLarge.selector, uint256(MAXIMUM_INPUT) + 1, uint256(MAXIMUM_INPUT)
            )
        );
        swap(key, true, -int256(uint256(MAXIMUM_INPUT) + 1), ZERO_BYTES);
    }

    function test_insufficientInventoryRevertsBeforeSettlement() public {
        deal(Currency.unwrap(currency1), address(hook), 0);

        _expectHookRevert(
            abi.encodeWithSelector(
                FixedPriceCurveHook.InsufficientReserves.selector, Currency.unwrap(currency1), 0, 2 ether
            )
        );
        swap(key, true, -1 ether, ZERO_BYTES);
    }

    function test_unsupportedPairCannotAttachToPrefundedHook() public {
        Currency nativeCurrency = Currency.wrap(address(0));
        uint256 reserveBefore = currency1.balanceOf(address(hook));

        _expectBeforeInitializeRevert(
            abi.encodeWithSelector(
                FixedPriceCurveHook.UnsupportedPool.selector,
                Currency.unwrap(nativeCurrency),
                Currency.unwrap(currency1),
                uint24(3_000),
                int24(60)
            )
        );
        initPool(nativeCurrency, currency1, hook, 3_000, SQRT_PRICE_1_1);

        assertEq(currency1.balanceOf(address(hook)), reserveBefore, "configured-pair reserves must remain untouched");
    }

    function test_nativeOutputUsesRealSettlement() public {
        Currency nativeCurrency = Currency.wrap(address(0));
        address nativeHookAddress = address(FLAGS | uint160(1) << 100);
        deployCodeTo(
            "FixedPriceCurveHook.sol",
            abi.encode(
                manager,
                nativeCurrency,
                currency1,
                uint24(3_000),
                int24(60),
                PRICE_NUMERATOR,
                PRICE_DENOMINATOR,
                MAXIMUM_INPUT
            ),
            nativeHookAddress
        );
        FixedPriceCurveHook nativeHook = FixedPriceCurveHook(payable(nativeHookAddress));
        (PoolKey memory nativeKey,) = initPool(nativeCurrency, currency1, nativeHook, 3_000, SQRT_PRICE_1_1);
        deal(address(nativeHook), 100 ether);

        uint256 hookNativeBefore = address(nativeHook).balance;
        uint256 traderNativeBefore = address(this).balance;
        BalanceDelta delta = swap(nativeKey, false, -10 ether, ZERO_BYTES);

        assertEq(delta.amount1(), -10 ether);
        assertEq(delta.amount0(), 5 ether);
        assertEq(address(nativeHook).balance, hookNativeBefore - 5 ether);
        assertEq(address(this).balance, traderNativeBefore + 5 ether);
    }

    function test_emptyManagerMintsThenSpendsClaimsAcrossBothDirections() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        address emptyHookAddress = address(FLAGS | uint160(2) << 100);
        deployCodeTo(
            "FixedPriceCurveHook.sol",
            abi.encode(
                manager,
                currency0,
                currency1,
                uint24(3_000),
                int24(60),
                PRICE_NUMERATOR,
                PRICE_DENOMINATOR,
                MAXIMUM_INPUT
            ),
            emptyHookAddress
        );
        FixedPriceCurveHook emptyHook = FixedPriceCurveHook(payable(emptyHookAddress));
        (PoolKey memory emptyKey,) = initPool(currency0, currency1, emptyHook, 3_000, SQRT_PRICE_1_1);

        currency0.transfer(address(emptyHook), 100 ether);
        currency1.transfer(address(emptyHook), 100 ether);
        assertEq(currency0.balanceOf(address(manager)), 0, "manager starts without currency0 float");
        assertEq(currency1.balanceOf(address(manager)), 0, "manager starts without currency1 float");

        uint256 trader0Before = currency0.balanceOf(address(this));
        uint256 trader1Before = currency1.balanceOf(address(this));
        uint256 hook0PhysicalBefore = currency0.balanceOf(address(emptyHook));
        uint256 hook1PhysicalBefore = currency1.balanceOf(address(emptyHook));

        BalanceDelta first = swap(emptyKey, true, -5 ether, ZERO_BYTES);

        assertEq(first.amount0(), -5 ether);
        assertEq(first.amount1(), 10 ether);
        assertEq(manager.balanceOf(address(emptyHook), currency0.toId()), 5 ether, "input credited as claim");
        assertEq(currency0.balanceOf(address(emptyHook)), hook0PhysicalBefore, "input is not taken prematurely");
        assertEq(currency1.balanceOf(address(emptyHook)), hook1PhysicalBefore - 10 ether);
        assertEq(currency0.balanceOf(address(manager)), 5 ether, "trader settlement backs input claim");
        assertEq(currency1.balanceOf(address(manager)), 0, "trader receives all funded output");

        BalanceDelta reverse = swap(emptyKey, false, -12 ether, ZERO_BYTES);

        assertEq(reverse.amount1(), -12 ether);
        assertEq(reverse.amount0(), 6 ether);
        assertEq(manager.balanceOf(address(emptyHook), currency0.toId()), 0, "reverse output burns prior claim");
        assertEq(manager.balanceOf(address(emptyHook), currency1.toId()), 12 ether, "reverse input becomes claim");
        assertEq(currency0.balanceOf(address(emptyHook)), hook0PhysicalBefore - 1 ether, "reserves top up claim");
        assertEq(currency1.balanceOf(address(emptyHook)), hook1PhysicalBefore - 10 ether);
        assertEq(currency0.balanceOf(address(manager)), 0, "burned claim releases its backing");
        assertEq(currency1.balanceOf(address(manager)), 12 ether, "reverse settlement backs new claim");
        assertEq(currency0.balanceOf(address(this)), trader0Before + 1 ether);
        assertEq(currency1.balanceOf(address(this)), trader1Before - 2 ether);
    }

    function _expectHookRevert(bytes memory reason) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                reason,
                abi.encodePacked(Hooks.HookCallFailed.selector)
            )
        );
    }

    function _expectBeforeInitializeRevert(bytes memory reason) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                reason,
                abi.encodePacked(Hooks.HookCallFailed.selector)
            )
        );
    }
}
