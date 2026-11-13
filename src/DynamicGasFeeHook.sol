// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title DynamicGasFeeHook
/// @notice Adjusts a pool's fee when the transaction gas price leaves a 10% band around its smoothed history.
/// @dev The first positive gas sample establishes each pool's reference. Later samples are capped before smoothing.
contract DynamicGasFeeHook is BaseHook {
    using LPFeeLibrary for uint24;

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant DEVIATION_BPS = 1_000;

    uint24 public immutable minimumFee;
    uint24 public immutable neutralFee;
    uint24 public immutable maximumFee;
    uint16 public immutable smoothingWeightBps;
    uint256 public immutable maximumTrackedGasPrice;

    mapping(PoolId poolId => uint256 gasPrice) public gasPriceAverage;

    error InvalidConfiguration();
    error DynamicFeePoolRequired();

    constructor(
        IPoolManager manager,
        uint24 _minimumFee,
        uint24 _neutralFee,
        uint24 _maximumFee,
        uint16 _smoothingWeightBps,
        uint256 _maximumTrackedGasPrice
    ) BaseHook(manager) {
        if (
            _minimumFee > _neutralFee || _neutralFee > _maximumFee || _maximumFee > LPFeeLibrary.MAX_LP_FEE
                || _smoothingWeightBps == 0 || _smoothingWeightBps > BPS_DENOMINATOR || _maximumTrackedGasPrice == 0
        ) revert InvalidConfiguration();

        minimumFee = _minimumFee;
        neutralFee = _neutralFee;
        maximumFee = _maximumFee;
        smoothingWeightBps = _smoothingWeightBps;
        maximumTrackedGasPrice = _maximumTrackedGasPrice;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions.beforeInitialize = true;
        permissions.beforeSwap = true;
        permissions.afterSwap = true;
    }

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal pure override returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert DynamicFeePoolRequired();
        return this.beforeInitialize.selector;
    }

    /// @notice Quotes the fee against the pool's reference before the current swap updates it.
    function quoteFee(PoolId poolId, uint256 gasPrice) public view returns (uint24) {
        uint256 average = gasPriceAverage[poolId];
        if (average == 0) return neutralFee;

        uint256 boundedGasPrice = _boundGasPrice(gasPrice);
        uint256 tolerance = FullMath.mulDiv(average, DEVIATION_BPS, BPS_DENOMINATOR);
        if (boundedGasPrice > average && boundedGasPrice - average > tolerance) return minimumFee;
        if (boundedGasPrice < average && average - boundedGasPrice > tolerance) return maximumFee;
        return neutralFee;
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (!key.fee.isDynamicFee()) revert DynamicFeePoolRequired();

        uint24 fee = quoteFee(key.toId(), tx.gasprice);
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();
        uint256 sample = _boundGasPrice(tx.gasprice);
        uint256 previous = gasPriceAverage[poolId];

        if (previous == 0) {
            gasPriceAverage[poolId] = sample;
        } else if (sample > previous) {
            gasPriceAverage[poolId] = previous + FullMath.mulDiv(sample - previous, smoothingWeightBps, BPS_DENOMINATOR);
        } else {
            gasPriceAverage[poolId] = previous - FullMath.mulDiv(previous - sample, smoothingWeightBps, BPS_DENOMINATOR);
        }

        return (this.afterSwap.selector, 0);
    }

    function _boundGasPrice(uint256 gasPrice) internal view returns (uint256) {
        return gasPrice < maximumTrackedGasPrice ? gasPrice : maximumTrackedGasPrice;
    }
}
