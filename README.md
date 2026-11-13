# UHI Hook Quests

Four Uniswap v4 Foundry labs for the Atrium Academy Uniswap Hook Incubator. Each exercise has its own contract and tests. The labs use a real local `PoolManager` and share pinned dependencies.

| Quest | Contract | Lab notes |
| --- | --- | --- |
| Dynamic Fees | [DynamicGasFeeHook](src/DynamicGasFeeHook.sol) | [Gas-price fee bounds](docs/dynamic-fees.md) |
| Return Delta Hooks | [FixedPriceCurveHook](src/FixedPriceCurveHook.sol) | [Fixed-price curve and reserve settlement](docs/return-delta.md) |
| Limit Order Hooks | [LimitOrderHook](src/LimitOrderHook.sol) | [Take-profit triggers and execution](docs/limit-orders.md) |
| Swap + Bridge | [SwapAndBridgeRouter](src/SwapAndBridgeRouter.sol) | [Local and Optimism bridge settlement](docs/swap-and-bridge.md) |

The First Hook and First Test quests use the separate [Chart Health Hook project](https://github.com/markeljan/chart-health-hook). The [First Test branch](https://github.com/markeljan/chart-health-hook/tree/uhi-first-test-quest) adds integration tests for its existing deployment.

## Run the labs

Use Foundry 1.7.1 and Git. Foundry installs the pinned Solidity 0.8.26 compiler on the first run.

```sh
git clone --recurse-submodules https://github.com/markeljan/uhi-hook-quests.git
cd uhi-hook-quests
forge fmt --check
forge test --summary
```

The default run works without an RPC. To exercise the official Optimism L1 bridge on a local Sepolia fork, see [the fork test instructions](docs/swap-and-bridge.md#verify-the-official-bridge-on-a-local-fork).

## Scope

The contracts are educational implementations. The dynamic fee uses an input the trader can influence. The fixed-price curve uses dedicated, prefunded inventory with no withdrawal path. The limit-order hook relies on keepers to execute crossed orders. The bridge lab verifies initiation on the source chain. See the individual lab notes before reusing a contract.

The original lab code is MIT licensed. Uniswap, Foundry, and other submodule dependencies retain their respective licenses.
