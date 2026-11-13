// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";

import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title FixedPriceCurveHook
/// @notice Inventory-backed fixed-price curve that replaces the core v4 swap for exact-input orders.
/// @dev Price is `currency1PerCurrency0Numerator / currency1PerCurrency0Denominator` in raw token units.
contract FixedPriceCurveHook is BaseHook {
    using SafeCast for uint256;

    Currency public immutable configuredCurrency0;
    Currency public immutable configuredCurrency1;
    uint24 public immutable configuredFee;
    int24 public immutable configuredTickSpacing;
    uint128 public immutable currency1PerCurrency0Numerator;
    uint128 public immutable currency1PerCurrency0Denominator;
    uint128 public immutable maximumInputAmount;

    error InvalidConfiguration();
    error UnsupportedPool(address currency0, address currency1, uint24 fee, int24 tickSpacing);
    error ExactOutputUnsupported();
    error SwapAmountTooLarge(uint256 requested, uint256 maximum);
    error OutputRoundsToZero();
    error InsufficientReserves(address currency, uint256 available, uint256 required);
    error TokenTransferFailed(address currency, uint256 amount);

    constructor(
        IPoolManager manager,
        Currency _currency0,
        Currency _currency1,
        uint24 _fee,
        int24 _tickSpacing,
        uint128 _currency1PerCurrency0Numerator,
        uint128 _currency1PerCurrency0Denominator,
        uint128 _maximumInputAmount
    ) BaseHook(manager) {
        if (
            _currency0 >= _currency1 || _currency1PerCurrency0Numerator == 0 || _currency1PerCurrency0Denominator == 0
                || _maximumInputAmount == 0
        ) revert InvalidConfiguration();

        configuredCurrency0 = _currency0;
        configuredCurrency1 = _currency1;
        configuredFee = _fee;
        configuredTickSpacing = _tickSpacing;
        currency1PerCurrency0Numerator = _currency1PerCurrency0Numerator;
        currency1PerCurrency0Denominator = _currency1PerCurrency0Denominator;
        maximumInputAmount = _maximumInputAmount;
    }

    receive() external payable {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions.beforeInitialize = true;
        permissions.beforeSwap = true;
        permissions.beforeSwapReturnDelta = true;
    }

    /// @dev Rejects initialization of any pool other than the exact pair and pool parameters
    /// configured for this inventory. Without this binding, an attacker could attach the hook to
    /// a worthless token pair and trade against reserves intended for another pool.
    function _beforeInitialize(address, PoolKey calldata key, uint160) internal view override returns (bytes4) {
        _validatePool(key);
        return this.beforeInitialize.selector;
    }

    /// @notice Quotes the fixed curve for an exact-input trade.
    function quoteExactInput(bool zeroForOne, uint256 amountIn) public view returns (uint256) {
        return zeroForOne
            ? FullMath.mulDiv(amountIn, currency1PerCurrency0Numerator, currency1PerCurrency0Denominator)
            : FullMath.mulDiv(amountIn, currency1PerCurrency0Denominator, currency1PerCurrency0Numerator);
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _validatePool(key);
        if (params.amountSpecified >= 0) revert ExactOutputUnsupported();

        uint256 amountIn = uint256(-params.amountSpecified);
        if (amountIn > maximumInputAmount) revert SwapAmountTooLarge(amountIn, maximumInputAmount);

        uint256 amountOut = quoteExactInput(params.zeroForOne, amountIn);
        if (amountOut == 0) revert OutputRoundsToZero();

        Currency inputCurrency = params.zeroForOne ? key.currency0 : key.currency1;
        Currency outputCurrency = params.zeroForOne ? key.currency1 : key.currency0;
        uint256 outputClaimBalance = poolManager.balanceOf(address(this), outputCurrency.toId());
        uint256 available = outputClaimBalance + outputCurrency.balanceOf(address(this));
        if (available < amountOut) {
            revert InsufficientReserves(Currency.unwrap(outputCurrency), available, amountOut);
        }

        // Claims do not require the singleton to hold physical input tokens before the router settles.
        // They become backed by the trader's payment at the end of the unlock callback.
        poolManager.mint(address(this), inputCurrency.toId(), amountIn);
        _fundOutput(outputCurrency, amountOut, outputClaimBalance);

        BeforeSwapDelta hookDelta = toBeforeSwapDelta(amountIn.toInt128(), -amountOut.toInt128());
        return (this.beforeSwap.selector, hookDelta, 0);
    }

    function _fundOutput(Currency currency, uint256 amount, uint256 claimBalance) internal {
        uint256 claimsUsed = claimBalance < amount ? claimBalance : amount;
        if (claimsUsed != 0) poolManager.burn(address(this), currency.toId(), claimsUsed);

        uint256 physicalAmount = amount - claimsUsed;
        if (physicalAmount != 0) _settle(currency, physicalAmount);
    }

    function _validatePool(PoolKey calldata key) internal view {
        if (
            Currency.unwrap(key.currency0) != Currency.unwrap(configuredCurrency0)
                || Currency.unwrap(key.currency1) != Currency.unwrap(configuredCurrency1) || key.fee != configuredFee
                || key.tickSpacing != configuredTickSpacing || address(key.hooks) != address(this)
        ) {
            revert UnsupportedPool(
                Currency.unwrap(key.currency0), Currency.unwrap(key.currency1), key.fee, key.tickSpacing
            );
        }
    }

    function _settle(Currency currency, uint256 amount) internal {
        poolManager.sync(currency);
        if (currency.isAddressZero()) {
            poolManager.settle{value: amount}();
            return;
        }

        bool transferred = IERC20Minimal(Currency.unwrap(currency)).transfer(address(poolManager), amount);
        if (!transferred) revert TokenTransferFailed(Currency.unwrap(currency), amount);
        poolManager.settle();
    }
}
