// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {DynamicGasFeeHook} from "../src/DynamicGasFeeHook.sol";

contract DynamicGasFeeHookTest is Test, Deployers {
    DynamicGasFeeHook internal hook;

    uint160 internal constant FLAGS = uint160(Hooks.BEFORE_SWAP_FLAG);
    uint256 internal constant FLOOR_GAS_PRICE = 10 gwei;
    uint256 internal constant CEILING_GAS_PRICE = 100 gwei;
    uint24 internal constant MINIMUM_FEE = 500;
    uint24 internal constant MAXIMUM_FEE = 10_000;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        deployCodeTo(
            "DynamicGasFeeHook.sol",
            abi.encode(manager, FLOOR_GAS_PRICE, CEILING_GAS_PRICE, MINIMUM_FEE, MAXIMUM_FEE),
            address(FLAGS)
        );
        hook = DynamicGasFeeHook(address(FLAGS));

        (key,) = initPool(currency0, currency1, hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18, salt: 0}), ZERO_BYTES
        );
    }

    function test_quoteFeeIsBoundedAndLinear() public view {
        assertEq(hook.quoteFee(1 gwei), MINIMUM_FEE);
        assertEq(hook.quoteFee(FLOOR_GAS_PRICE), MINIMUM_FEE);
        assertEq(hook.quoteFee(55 gwei), 5_250);
        assertEq(hook.quoteFee(CEILING_GAS_PRICE), MAXIMUM_FEE);
        assertEq(hook.quoteFee(1_000 gwei), MAXIMUM_FEE);
    }

    function test_realPoolSwapUsesMinimumFeeBelowFloor() public {
        assertEq(_swapAndReadFee(5 gwei), MINIMUM_FEE);
    }

    function test_realPoolSwapUsesInterpolatedFee() public {
        assertEq(_swapAndReadFee(55 gwei), 5_250);
    }

    function test_realPoolSwapCapsAtMaximumFee() public {
        assertEq(_swapAndReadFee(500 gwei), MAXIMUM_FEE);
    }

    function _swapAndReadFee(uint256 gasPrice) internal returns (uint24 fee) {
        vm.txGasPrice(gasPrice);
        vm.recordLogs();
        swap(key, true, -1e12, ZERO_BYTES);

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
