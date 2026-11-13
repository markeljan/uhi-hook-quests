// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title DynamicGasFeeHook
/// @notice Linearly increases the per-swap LP fee as the transaction gas price rises.
/// @dev The configured gas-price range and LP-fee range provide explicit lower and upper bounds.
contract DynamicGasFeeHook is BaseHook {
    using LPFeeLibrary for uint24;

    uint256 public immutable floorGasPrice;
    uint256 public immutable ceilingGasPrice;
    uint24 public immutable minimumFee;
    uint24 public immutable maximumFee;

    error InvalidConfiguration();
    error DynamicFeePoolRequired();

    constructor(
        IPoolManager manager,
        uint256 _floorGasPrice,
        uint256 _ceilingGasPrice,
        uint24 _minimumFee,
        uint24 _maximumFee
    ) BaseHook(manager) {
        if (_floorGasPrice >= _ceilingGasPrice || _minimumFee > _maximumFee || _maximumFee > LPFeeLibrary.MAX_LP_FEE) revert InvalidConfiguration();

        floorGasPrice = _floorGasPrice;
        ceilingGasPrice = _ceilingGasPrice;
        minimumFee = _minimumFee;
        maximumFee = _maximumFee;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions.beforeSwap = true;
    }

    /// @notice Returns the bounded LP fee for a gas price, in hundredths of a basis point.
    function quoteFee(uint256 gasPrice) public view returns (uint24) {
        if (gasPrice <= floorGasPrice) return minimumFee;
        if (gasPrice >= ceilingGasPrice) return maximumFee;

        uint256 gasProgress = gasPrice - floorGasPrice;
        uint256 gasRange = ceilingGasPrice - floorGasPrice;
        uint256 feeRange = maximumFee - minimumFee;
        // Safe because interpolation cannot exceed `maximumFee`, which is at most 1_000_000.
        // forge-lint: disable-next-line(unsafe-typecast)
        return minimumFee + uint24(gasProgress * feeRange / gasRange);
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (!key.fee.isDynamicFee()) revert DynamicFeePoolRequired();

        uint24 fee = quoteFee(tx.gasprice);
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }
}
