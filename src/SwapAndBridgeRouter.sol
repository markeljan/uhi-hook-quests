// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {SafeCallback} from "v4-periphery/src/base/SafeCallback.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";

interface IOptimismStandardBridge {
    function bridgeETHTo(address recipient, uint32 minGasLimit, bytes calldata extraData) external payable;

    function bridgeERC20To(
        address localToken,
        address remoteToken,
        address recipient,
        uint256 amount,
        uint32 minGasLimit,
        bytes calldata extraData
    ) external;
}

/// @notice Executes a full exact-input v4 swap, then pays the recipient locally or starts an OP Stack bridge transfer.
/// @dev Educational router for native ETH and standard ERC20s. One ERC20 bridge pair is set at deployment.
contract SwapAndBridgeRouter is SafeCallback, ReentrancyGuard {
    using SafeCast for int128;
    using SafeTransferLib for ERC20;

    struct Order {
        uint128 amountIn;
        uint128 minAmountOut;
        uint160 sqrtPriceLimitX96;
        uint48 deadline;
        uint32 bridgeGasLimit;
        bool zeroForOne;
        bool bridge;
        address recipient;
    }

    error InvalidOrder();
    error InvalidBridge();
    error InvalidNativeValue();
    error UnsupportedBridgeToken();
    error PartialFill();
    error InsufficientOutput();
    error UnexpectedBalanceChange();

    IOptimismStandardBridge public immutable standardBridge;
    address public immutable localBridgeToken;
    address public immutable remoteBridgeToken;

    constructor(IPoolManager manager, IOptimismStandardBridge bridge, address localToken, address remoteToken)
        SafeCallback(manager)
    {
        if (
            address(bridge).code.length == 0 || address(bridge) == address(manager)
                || (localToken == address(0)) != (remoteToken == address(0))
        ) revert InvalidBridge();
        standardBridge = bridge;
        localBridgeToken = localToken;
        remoteBridgeToken = remoteToken;
    }

    receive() external payable {
        if (msg.sender != address(poolManager)) revert InvalidNativeValue();
    }

    function swap(PoolKey calldata key, Order calldata order, bytes calldata hookData)
        external
        payable
        nonReentrant
        returns (uint256 amountOut)
    {
        if (
            block.timestamp > order.deadline || order.recipient == address(0) || order.recipient == address(this)
                || order.recipient == address(poolManager) || order.recipient == address(standardBridge)
                || order.amountIn == 0 || order.amountIn > uint128(type(int128).max) || order.minAmountOut == 0
                || (order.bridge && order.bridgeGasLimit == 0)
        ) revert InvalidOrder();

        Currency input = order.zeroForOne ? key.currency0 : key.currency1;
        Currency output = order.zeroForOne ? key.currency1 : key.currency0;
        if (msg.value != (input.isAddressZero() ? order.amountIn : 0)) revert InvalidNativeValue();
        if (order.bridge && !output.isAddressZero() && Currency.unwrap(output) != localBridgeToken) {
            revert UnsupportedBridgeToken();
        }

        amountOut = abi.decode(poolManager.unlock(abi.encode(key, order, msg.sender, hookData)), (uint256));
        if (order.bridge) _bridge(output, order.recipient, amountOut, order.bridgeGasLimit);
    }

    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        (PoolKey memory key, Order memory order, address payer, bytes memory hookData) =
            abi.decode(data, (PoolKey, Order, address, bytes));
        BalanceDelta delta = poolManager.swap(
            key, SwapParams(order.zeroForOne, -int256(uint256(order.amountIn)), order.sqrtPriceLimitX96), hookData
        );
        int128 inputDelta = order.zeroForOne ? delta.amount0() : delta.amount1();
        int128 outputDelta = order.zeroForOne ? delta.amount1() : delta.amount0();
        if (int256(inputDelta) != -int256(uint256(order.amountIn))) revert PartialFill();
        if (int256(outputDelta) < int256(uint256(order.minAmountOut))) revert InsufficientOutput();
        uint128 amountOut = outputDelta.toUint128();

        Currency input = order.zeroForOne ? key.currency0 : key.currency1;
        Currency output = order.zeroForOne ? key.currency1 : key.currency0;
        poolManager.sync(input);
        if (input.isAddressZero()) {
            poolManager.settle{value: order.amountIn}();
        } else {
            ERC20(Currency.unwrap(input)).safeTransferFrom(payer, address(poolManager), order.amountIn);
            if (poolManager.settle() != order.amountIn) revert UnexpectedBalanceChange();
        }

        address recipient = order.bridge ? address(this) : order.recipient;
        uint256 balanceBefore = output.balanceOf(recipient);
        poolManager.take(output, recipient, amountOut);
        if (output.balanceOf(recipient) != balanceBefore + amountOut) revert UnexpectedBalanceChange();
        return abi.encode(uint256(amountOut));
    }

    function _bridge(Currency output, address recipient, uint256 amount, uint32 gasLimit) private {
        if (output.isAddressZero()) {
            standardBridge.bridgeETHTo{value: amount}(recipient, gasLimit, "");
            return;
        }

        ERC20 token = ERC20(Currency.unwrap(output));
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeApprove(address(standardBridge), amount);
        standardBridge.bridgeERC20To(localBridgeToken, remoteBridgeToken, recipient, amount, gasLimit, "");
        token.safeApprove(address(standardBridge), 0);
        if (token.balanceOf(address(this)) != balanceBefore - amount) revert UnexpectedBalanceChange();
    }
}
