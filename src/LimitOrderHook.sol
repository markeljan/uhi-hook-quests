// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";

import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title LimitOrderHook
/// @notice Escrows exact-input take-profit orders and executes them against a real Uniswap v4 pool.
/// @dev This intentionally handles one order per execution. Anyone may execute a crossed order, while the stored
///      sqrt-price limit and minimum output protect the owner from adverse execution. Only ERC20/ERC20 pools are
///      supported so cancellation and PoolManager settlement have one unambiguous custody path.
contract LimitOrderHook is BaseHook, IUnlockCallback {
    using CurrencyLibrary for Currency;
    using SafeTransferLib for ERC20;
    using StateLibrary for IPoolManager;

    struct Order {
        address owner;
        address recipient;
        PoolKey key;
        uint128 amountIn;
        uint128 minAmountOut;
        int24 triggerTick;
        uint160 sqrtPriceLimitX96;
        uint64 deadline;
        bool zeroForOne;
    }

    uint256 public nextOrderId = 1;
    mapping(uint256 orderId => Order) private _orders;

    uint256 private _lockState = 1;

    event OrderPlaced(
        uint256 indexed orderId,
        address indexed owner,
        address indexed recipient,
        bool zeroForOne,
        uint128 amountIn,
        uint128 minAmountOut,
        int24 triggerTick,
        uint160 sqrtPriceLimitX96,
        uint64 deadline
    );
    event OrderExecuted(uint256 indexed orderId, address indexed executor, uint128 amountIn, uint128 amountOut);
    event OrderCancelled(uint256 indexed orderId, address indexed owner, uint128 amountIn);
    event PoolPriceObserved(PoolId indexed poolId, uint160 sqrtPriceX96, int24 tick);

    error DeadlineNotInFuture();
    error EscrowAmountMismatch(uint256 received, uint256 expected);
    error InvalidAmount();
    error InvalidPool();
    error InvalidPriceLimit();
    error InvalidRecipient();
    error InvalidTrigger(int24 currentTick, int24 triggerTick);
    error MinimumOutputNotMet(uint128 amountOut, uint128 minAmountOut);
    error NativeCurrencyUnsupported();
    error NotOrderOwner();
    error OrderExpired();
    error OrderNotFound();
    error OrderNotTriggered(int24 currentTick, int24 triggerTick);
    error PartialFill(uint128 amountInUsed, uint128 amountInRequired);
    error Reentrancy();
    error TriggerOutOfBounds();
    error UnexpectedSwapDelta();

    constructor(IPoolManager manager) BaseHook(manager) {}

    modifier nonReentrant() {
        if (_lockState != 1) revert Reentrancy();
        _lockState = 2;
        _;
        _lockState = 1;
    }

    /// @dev The hook is attached to the pool through the afterSwap flag. The callback is deliberately passive:
    ///      keeper execution is explicit, bounded, and cannot make an unrelated user's swap pay for an order.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions.afterSwap = true;
    }

    /// @notice Escrow an exact-input order that becomes executable after the pool crosses `triggerTick`.
    /// @dev `zeroForOne` orders trigger at or above the tick. `oneForZero` orders trigger at or below it.
    function placeOrder(
        PoolKey calldata key,
        bool zeroForOne,
        uint128 amountIn,
        uint128 minAmountOut,
        int24 triggerTick,
        uint160 sqrtPriceLimitX96,
        uint64 deadline,
        address recipient
    ) external nonReentrant returns (uint256 orderId) {
        if (address(key.hooks) != address(this)) revert InvalidPool();
        if (key.currency0.isAddressZero() || key.currency1.isAddressZero()) revert NativeCurrencyUnsupported();
        if (amountIn == 0 || amountIn > uint128(type(int128).max) || minAmountOut == 0) revert InvalidAmount();
        if (deadline <= block.timestamp) revert DeadlineNotInFuture();
        if (recipient == address(0)) revert InvalidRecipient();

        _validateTriggerAndLimit(key, zeroForOne, triggerTick, sqrtPriceLimitX96);
        Currency inputCurrency = zeroForOne ? key.currency0 : key.currency1;
        _takeExactEscrow(inputCurrency, amountIn);

        orderId = nextOrderId++;
        Order storage order = _orders[orderId];
        order.owner = msg.sender;
        order.recipient = recipient;
        order.key = key;
        order.amountIn = amountIn;
        order.minAmountOut = minAmountOut;
        order.triggerTick = triggerTick;
        order.sqrtPriceLimitX96 = sqrtPriceLimitX96;
        order.deadline = deadline;
        order.zeroForOne = zeroForOne;

        emit OrderPlaced(
            orderId, msg.sender, recipient, zeroForOne, amountIn, minAmountOut, triggerTick, sqrtPriceLimitX96, deadline
        );
    }

    /// @notice Execute a crossed order. The executor need not be the owner.
    /// @return amountOut Amount paid directly from the PoolManager to the order recipient.
    function executeOrder(uint256 orderId) external nonReentrant returns (uint128 amountOut) {
        Order memory order = _orders[orderId];
        if (order.owner == address(0)) revert OrderNotFound();
        if (block.timestamp > order.deadline) revert OrderExpired();

        (, int24 currentTick,,) = poolManager.getSlot0(order.key.toId());
        bool crossed = order.zeroForOne ? currentTick >= order.triggerTick : currentTick <= order.triggerTick;
        if (!crossed) revert OrderNotTriggered(currentTick, order.triggerTick);

        // Delete before the external manager call. Any failure reverts the deletion and preserves custody.
        delete _orders[orderId];
        amountOut = abi.decode(poolManager.unlock(abi.encode(order)), (uint128));

        emit OrderExecuted(orderId, msg.sender, order.amountIn, amountOut);
    }

    /// @notice Cancel an open order and refund all escrowed input to its owner.
    function cancelOrder(uint256 orderId) external nonReentrant {
        Order memory order = _orders[orderId];
        if (order.owner == address(0)) revert OrderNotFound();
        if (msg.sender != order.owner) revert NotOrderOwner();

        delete _orders[orderId];
        Currency inputCurrency = order.zeroForOne ? order.key.currency0 : order.key.currency1;
        inputCurrency.transfer(order.owner, order.amountIn);

        emit OrderCancelled(orderId, order.owner, order.amountIn);
    }

    function getOrder(uint256 orderId) external view returns (Order memory) {
        return _orders[orderId];
    }

    function isTriggered(uint256 orderId) external view returns (bool) {
        Order storage order = _orders[orderId];
        if (order.owner == address(0)) revert OrderNotFound();
        (, int24 currentTick,,) = poolManager.getSlot0(order.key.toId());
        return order.zeroForOne ? currentTick >= order.triggerTick : currentTick <= order.triggerTick;
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        Order memory order = abi.decode(data, (Order));

        BalanceDelta delta = poolManager.swap(
            order.key,
            SwapParams({
                zeroForOne: order.zeroForOne,
                amountSpecified: -int256(uint256(order.amountIn)),
                sqrtPriceLimitX96: order.sqrtPriceLimitX96
            }),
            bytes("")
        );

        int128 inputDelta = order.zeroForOne ? delta.amount0() : delta.amount1();
        int128 outputDelta = order.zeroForOne ? delta.amount1() : delta.amount0();
        if (inputDelta >= 0 || outputDelta <= 0) revert UnexpectedSwapDelta();

        uint128 amountInUsed = uint128(uint256(-int256(inputDelta)));
        uint128 amountOut = uint128(uint256(int256(outputDelta)));
        if (amountInUsed != order.amountIn) revert PartialFill(amountInUsed, order.amountIn);
        if (amountOut < order.minAmountOut) revert MinimumOutputNotMet(amountOut, order.minAmountOut);

        Currency inputCurrency = order.zeroForOne ? order.key.currency0 : order.key.currency1;
        Currency outputCurrency = order.zeroForOne ? order.key.currency1 : order.key.currency0;

        poolManager.sync(inputCurrency);
        inputCurrency.transfer(address(poolManager), amountInUsed);
        poolManager.settle();
        poolManager.take(outputCurrency, order.recipient, amountOut);

        return abi.encode(amountOut);
    }

    function _validateTriggerAndLimit(
        PoolKey calldata key,
        bool zeroForOne,
        int24 triggerTick,
        uint160 sqrtPriceLimitX96
    ) internal view {
        (uint160 currentSqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(key.toId());
        if (currentSqrtPriceX96 == 0) revert InvalidPool();
        if (triggerTick < TickMath.MIN_TICK || triggerTick > TickMath.MAX_TICK) revert TriggerOutOfBounds();
        uint160 triggerSqrtPriceX96 = TickMath.getSqrtPriceAtTick(triggerTick);

        if (zeroForOne) {
            if (triggerTick <= currentTick) revert InvalidTrigger(currentTick, triggerTick);
            // Execution starts at or above the trigger, so any lower limit is valid even when it is above today's price.
            if (sqrtPriceLimitX96 <= TickMath.MIN_SQRT_PRICE || sqrtPriceLimitX96 >= triggerSqrtPriceX96) {
                revert InvalidPriceLimit();
            }
        } else {
            if (triggerTick >= currentTick) revert InvalidTrigger(currentTick, triggerTick);
            // Execution starts at or below the trigger, so any higher limit is valid even when it is below today's price.
            if (sqrtPriceLimitX96 >= TickMath.MAX_SQRT_PRICE || sqrtPriceLimitX96 <= triggerSqrtPriceX96) {
                revert InvalidPriceLimit();
            }
        }
    }

    function _takeExactEscrow(Currency inputCurrency, uint128 amountIn) internal {
        ERC20 inputToken = ERC20(Currency.unwrap(inputCurrency));
        uint256 balanceBefore = inputToken.balanceOf(address(this));
        inputToken.safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 balanceAfter = inputToken.balanceOf(address(this));
        uint256 received = balanceAfter >= balanceBefore ? balanceAfter - balanceBefore : 0;
        if (received != amountIn) revert EscrowAmountMismatch(received, amountIn);
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(key.toId());
        emit PoolPriceObserved(key.toId(), sqrtPriceX96, tick);
        return (this.afterSwap.selector, 0);
    }
}
