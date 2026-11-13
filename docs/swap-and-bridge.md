# Swap and bridge lab

`SwapAndBridgeRouter` executes one exact-input Uniswap v4 swap against `PoolManager`. It checks the caller's deadline, price limit, full input fill, and minimum output. It then pays the chosen recipient on the source chain or calls the Optimism Standard Bridge to initiate an ETH or ERC20 transfer to that recipient on the destination chain. The ERC20 path uses one configured local/remote token pair and clears the bridge allowance after the call.

The local test suite covers both bridge asset types, a swap without bridging, incorrect native input, an expired order, insufficient output, a partial fill at the price limit, an unsupported token, and rollback when the bridge reverts.

## Verify the official bridge on a local fork

```sh
SEPOLIA_RPC_URL=https://ethereum-sepolia-rpc.publicnode.com \
  forge test --match-contract SwapAndBridgeRouterForkTest --no-storage-caching -vv
```

The fork suite uses the real [OP Sepolia L1 Standard Bridge proxy](https://github.com/ethereum-optimism/superchain-registry/blob/main/superchain/configs/sepolia/op.toml) and the OUTb token pair from the [Atrium lesson](https://learn.atrium.academy/course/4b6c25df-f4c8-4b92-ab38-a930284d237e/periphery/periphery). It verifies the source-chain initiation events and the ERC20 bridge's receipt of funds. Use `SEPOLIA_FORK_BLOCK` with an archive-capable RPC to fix the fork at a historical block. With a public RPC, leaving the block unset allows the test to use the latest state. Fork calls are local simulations. Destination-chain relay and finalization require a separate live integration.

Only standard ERC20 and native ETH paths are supported. The operator must configure the official bridge and a verified token pair for the target chain. A successful source-chain call does not guarantee destination finalization.
