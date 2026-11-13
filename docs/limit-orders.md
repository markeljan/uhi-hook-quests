# Limit order hook lab

`LimitOrderHook` implements a deliberately bounded take-profit mechanism on a real Uniswap v4 `PoolManager`.

- An owner escrows one ERC20 input amount and chooses a recipient.
- A `zeroForOne` order becomes executable when the pool tick reaches or exceeds its trigger. A `oneForZero` order becomes executable when the tick reaches or falls below its trigger.
- The tick prices currency0 in currency1. A rising tick is therefore a take-profit trigger for selling currency0, while a falling tick is a take-profit trigger for selling currency1.
- The trigger must be inside TickMath's bounds. A zero-for-one price limit must be below the trigger price, while a one-for-zero limit must be above it. This permits a limit between the placement price and trigger because it points in the correct direction once execution becomes eligible.
- Any address may execute a crossed order. Execution is an exact-input PoolManager swap with the order's stored `sqrtPriceLimitX96`.
- The entire input must fill and the output must satisfy `minAmountOut`. Failure reverts atomically, preserving the order and escrow.
- The PoolManager pays output directly to the recipient. The owner may cancel an open or expired order and recover all escrow.
- Placement checks the hook's balance increase and rejects fee-on-transfer input that delivers less than the requested escrow.

The lab is ERC20/ERC20-only. It executes one order per keeper call and has no keeper reward, batching, native-currency custody, partial fills, order shares, or upgrade/admin surface.

For every external pool swap, `PoolPriceObserved` emits the pool id, resulting sqrt price, and tick once. A keeper can use this bounded callback signal to discover crossed orders. Execution remains a separate keeper call with no callback loop. Uniswap v4 skips this hook callback when the hook itself initiates an order swap.

## Difference from the course design

The course's take-profit example groups orders at usable ticks and represents proportional claims with ERC-1155 balances. It scans crossed ranges from `afterSwap` and may execute several pending groups.

This lab keeps each order independent. The `afterSwap` callback reports the latest tick, and a keeper explicitly executes a crossed order. Keeping execution outside the callback avoids recursive execution and makes each order's custody, cancellation, price limit, minimum output, and recipient settlement directly testable.
