# Gas-price dynamic fee lab

`DynamicGasFeeHook` maintains a separate exponentially smoothed gas-price reference for every pool. The hook accepts dynamic-fee pools. A pool's first successful swap with a positive gas price establishes its baseline at the neutral fee. Later swaps compare their bounded `tx.gasprice` with the reference that existed before the swap:

- More than 10% above the prior average: charge `minimumFee`.
- More than 10% below the prior average: charge `maximumFee`.
- Inside the band, including the exact boundaries: charge `neutralFee`.

The hook returns the fee override from `beforeSwap`, then updates only that pool's reference in `afterSwap`. The smoothing weight is configurable in basis points. Samples are capped at `maximumTrackedGasPrice`, differences are taken before multiplication, and `FullMath.mulDiv` applies the weight without an overflowing `gasPrice * weight` intermediate. Fee configuration is explicitly ordered and capped by Uniswap v4's maximum LP fee.

Tests execute real `PoolManager` swaps in both directions and cover first-swap baseline establishment, both sides of the deviation band, neutral boundary behavior, capped exponential smoothing, fee bounds, and isolation between two pool IDs.

This is a learning implementation. `tx.gasprice` is transaction metadata that users, builders, and private order flow can influence; a moving average does not make it a manipulation-resistant oracle. A production policy would need economic analysis of the desired fee direction, governance and emergency controls, calibrated smoothing and caps, monitoring, and independent security review.
