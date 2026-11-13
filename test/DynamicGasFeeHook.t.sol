// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {DynamicGasFeeHook} from "../src/DynamicGasFeeHook.sol";

contract DynamicGasFeeHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    DynamicGasFeeHook internal hook;

    uint160 internal constant FLAGS =
        uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
    uint24 internal constant MINIMUM_FEE = 500;
    uint24 internal constant NEUTRAL_FEE = 3_000;
    uint24 internal constant MAXIMUM_FEE = 10_000;
    uint16 internal constant SMOOTHING_WEIGHT_BPS = 2_500;
    uint256 internal constant MAXIMUM_TRACKED_GAS_PRICE = 500 gwei;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        deployCodeTo(
            "DynamicGasFeeHook.sol",
            abi.encode(manager, MINIMUM_FEE, NEUTRAL_FEE, MAXIMUM_FEE, SMOOTHING_WEIGHT_BPS, MAXIMUM_TRACKED_GAS_PRICE),
            address(FLAGS)
        );
        hook = DynamicGasFeeHook(address(FLAGS));

        (key,) = initPool(currency0, currency1, hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);
        _addLiquidity(key);
    }

    function test_firstSwapEstablishesNeutralBaseline() public {
        assertEq(_swapAndReadFee(key, true, 30 gwei), NEUTRAL_FEE);
        assertEq(hook.gasPriceAverage(key.toId()), 30 gwei);
    }

    function test_gasAbovePriorAverageChargesLowerFeeInEitherSwapDirection() public {
        _swapAndReadFee(key, true, 30 gwei);

        assertEq(_swapAndReadFee(key, false, 34 gwei), MINIMUM_FEE);
        assertEq(hook.gasPriceAverage(key.toId()), 31 gwei);
    }

    function test_gasBelowPriorAverageChargesHigherFeeInEitherSwapDirection() public {
        _swapAndReadFee(key, false, 30 gwei);

        assertEq(_swapAndReadFee(key, true, 26 gwei), MAXIMUM_FEE);
        assertEq(hook.gasPriceAverage(key.toId()), 29 gwei);
    }

    function test_gasWithinTenPercentBandUsesNeutralFee() public {
        _swapAndReadFee(key, true, 30 gwei);

        assertEq(_swapAndReadFee(key, true, 33 gwei), NEUTRAL_FEE, "upper threshold is inclusive");
        assertEq(hook.gasPriceAverage(key.toId()), 30.75 gwei);
    }

    function test_deviationBandRoundsBothDirectionsConsistently() public {
        _swapAndReadFee(key, true, 31 wei);
        assertEq(hook.quoteFee(key.toId(), 27 wei), MAXIMUM_FEE);
        assertEq(hook.quoteFee(key.toId(), 28 wei), NEUTRAL_FEE);
        assertEq(hook.quoteFee(key.toId(), 34 wei), NEUTRAL_FEE);
        assertEq(hook.quoteFee(key.toId(), 35 wei), MINIMUM_FEE);
    }

    function test_rejectsStaticFeePoolDuringInitialization() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(DynamicGasFeeHook.DynamicFeePoolRequired.selector),
                abi.encodePacked(Hooks.HookCallFailed.selector)
            )
        );
        initPool(currency0, currency1, hook, NEUTRAL_FEE, SQRT_PRICE_1_1);
    }

    function test_smoothingCapsExtremeSamplesAndFeesStayBounded() public {
        _swapAndReadFee(key, true, 100 gwei);

        assertEq(hook.quoteFee(key.toId(), 1_000 gwei), MINIMUM_FEE);
        assertEq(_swapAndReadFee(key, true, 1_000 gwei), MINIMUM_FEE);
        assertEq(hook.gasPriceAverage(key.toId()), 200 gwei, "sample is capped at 500 gwei before 25% smoothing");

        assertEq(hook.quoteFee(key.toId(), 0), MAXIMUM_FEE);
        assertLe(hook.minimumFee(), hook.neutralFee());
        assertLe(hook.neutralFee(), hook.maximumFee());
        assertLe(hook.maximumFee(), LPFeeLibrary.MAX_LP_FEE);
    }

    function test_eachPoolMaintainsIndependentAverage() public {
        (PoolKey memory secondKey,) =
            initPool(currency0, currency1, hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, 120, SQRT_PRICE_1_1);
        _addLiquidity(secondKey);

        _swapAndReadFee(key, true, 100 gwei);
        _swapAndReadFee(secondKey, true, 40 gwei);
        assertEq(hook.gasPriceAverage(key.toId()), 100 gwei);
        assertEq(hook.gasPriceAverage(secondKey.toId()), 40 gwei);

        assertEq(_swapAndReadFee(key, true, 200 gwei), MINIMUM_FEE);
        assertEq(hook.gasPriceAverage(key.toId()), 125 gwei);
        assertEq(hook.gasPriceAverage(secondKey.toId()), 40 gwei, "other pool is unchanged");
        assertEq(_swapAndReadFee(secondKey, false, 42 gwei), NEUTRAL_FEE);
    }

    function _addLiquidity(PoolKey memory pool) internal {
        modifyLiquidityRouter.modifyLiquidity(
            pool, ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18, salt: 0}), ZERO_BYTES
        );
    }

    function _swapAndReadFee(PoolKey memory pool, bool zeroForOne, uint256 gasPrice) internal returns (uint24 fee) {
        vm.txGasPrice(gasPrice);
        vm.recordLogs();
        swap(pool, zeroForOne, -1e12, ZERO_BYTES);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == IPoolManager.Swap.selector) {
                (,,,,, fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                return fee;
            }
        }
        revert("PoolManager Swap event not found");
    }
}
