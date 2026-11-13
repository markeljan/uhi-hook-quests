# Gas-price dynamic fee lab

`DynamicGasFeeHook` overrides the LP fee on every swap in a dynamic-fee pool. The fee is `minimumFee` at or below `floorGasPrice`, `maximumFee` at or above `ceilingGasPrice`, and increases linearly between those points.

The limits are deliberate. The maximum fee cannot exceed Uniswap v4's protocol maximum, and gas prices above the configured ceiling cannot raise the fee further. The hook rejects static-fee pools.

This is a learning implementation. `tx.gasprice` is a transaction input that users and private order flow can influence. A production policy should consider a manipulation-resistant gas oracle or a time-weighted signal, governance and emergency controls, pool-specific calibration, monitoring, and independent security review.
