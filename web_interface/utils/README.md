# Constructor of Dynamic Fees for Decentralized Exchanges (DEX)

## How to get started 

1. Install dependencies

```
bash init.sh
```

2. Install Foundry and build a project 

```
brew install foundryup
forge build
```

3. Open a new terminal and start a local blockchain 

```
anvil
```

4. Deploy a Hook locally and then broadcast on a real chain (if `--private-key` is provided)

```
forge script script/DeployHook.s.sol BAHook 0 0 --rpc-url http://localhost:8545 --broadcast
```

Parameters:
- HookName
- FeedAddress0 (Chainlink)
- FeedAddress1 (Chainlink)




