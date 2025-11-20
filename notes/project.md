# Project Outline 

### There's a hook contract in `src/`
For example, `BAHook.sol`

It inherits from a `BaseOverrideFee` and also implements custom functions that are usefuls for tests
In order to access this custom functions we create a `IHooksExtended.sol` interface

### There're scripts in `script/`

#### Deploy Hook script `deployHook.s.sol`

Run using:  
`forge script script/DeployHook.s.sol BAHook 0 0 --rpc-url http://localhost:8545 --broadcast`.  
`params: <FeedAddress0, FeedAddress1>`

This script inherits from the `HookHelpers` contract

`HookHelpers` has these fields:
- priceFeed0, priceFeed1 - the price feeds contracts that are needed for dynamic fee hooks to get CEX prices
It has function `deployFeeds()` that automatically create mock feeds
This function is called in a constructor
It also have a function `deployHook()` which deploys a hook (it uses the given name of the hook and looks if it matches one of the imported hooks)

The `HookHelpers` contract itself inherits from `BaseScript` contract
`BaseScript` has these fields:
- tokens
- currencies (which are just token wrappers)
It also creates mock tokens in the constructor

The `BaseScript` contract is inherited from `Deployers` contract
`Deployers` has these fields:
- permit2
- poolManager
- positionManager
- swapRouter
Those are the aftifacts neccessary for pool and hook deployments
The contract has functions to set up these fields
Note: It doesn't have a constructor (because we want to use this contract as a utility)
If we are on the local blockchain (block.chainid = 31337) then those artifacts are also created
In the actual blockchain they are already deployed by Uniswap so just the addresses are used

`BaseScript` constructor calls the `deployArtifacts()` function from `Deployers` contract

-------

So in this inheritance chain we created all the artifacts for the contract

The `deployHook` script also accepts the feed addresses as parameters 
If they are provided, it replaces the mock feeds with these ones

#### Deploy Hook and Create Pool script `deployHookAndCreatePool.s.sol`

Run using:  
`forge script script/deployHookAndCreatePool.s.sol BAHook 0 0 0 0 --rpc-url http://localhost:8545 --broadcast`.  
`params: <FeedAddress0, FeedAddress1, tokenAddress0, tokenAddress1>`

Works in a similar way and also deploys a pool with some liquidity
(those deploys are broadcasted on the network provided to forge)

### There are tests in `test/`

#### Hook test in `testHook.t.sol`

Run using 
`forge test -vvv --match-path test/testHook.t.sol`

This contract `BaseHookTest` inherits from `utils/HookTest.sol` contract

`HookTest` contract has the fields:
- currencies
- pool Id
- Hook feeds
- Hooks address
It has functions to deploy all of that

`HookTest` inherits from `BaseTest`
`BaseTest` is just a helper contract that inherits from `Deployers`
`Deployers` is the same utility contract used in scripts to deploy all the artifacts


`testHook` deployes everything and then runs tests 

The mock tokens are minted to the testing contract (it will act as a trader who interacts with a liquidity pool). Liquidity pool also belongs to this contract

- It downloads trading data and simulates transactions. 

- It gives the metrics for the liquidity pool

Note: all the deploymets are in internal forge local blockchain and are used just for tests









