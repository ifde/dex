### How to run program

`anvil --fork-url <YOUR_RPC_URL>` - create a local anvil chain

```
forge script script/BAHookNew.s.sol \
    --rpc-url http://localhost:8545 \
    --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
    --broadcast
```

`running a deploy Hook Script`
`params: <HookName, FeedAddress0, FeedAddress1>`
```
forge script script/DeployHook.s.sol BAHook 0 0 --rpc-url http://localhost:8545 --broadcast
```

```
forge script script/DeployHook.s.sol MEVChargeHook 0 0 --rpc-url http://localhost:8545 --broadcast
```

`running a deploy Hook and Create Pool Script`
`params: <FeedAddress0, FeedAddress1, tokenAddress0, tokenAddress1>`
```
forge script script/deployHookAndCreatePool.s.sol BAHook 0 0 0 0 --rpc-url http://localhost:8545 --broadcast
```

`Usual testing`
```
forge test -vvvv --match-path test/testHook.t.sol
```

Test specific for `MEVChargeHook`
```
forge test -vvvv --match-path test/MEVChargeHookFees.t.sol --match-test test_NormalPurchase
```

