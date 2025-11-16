# Project Outline 

1. There's a hook contract in `src/`

2. There're scripts in `script/`

- Deploy script that just deployes a hook (no artifacts on a real network)

- The same script that deploys a hook with artifacts (for a test network)

- The script that deployes a hook AND creates a liquidity pool. This script has the currencies for the creation of the liquidity pool. It can also be ran both on a real and test networks

3. There's a test in `test/` (it could also be a script)

- It deploys the hook, artifacts and creates a liquidity pool (with two mock tokens). The mock tokens are minted to the testing contract (it will act as a trader who interacts with a liquidity pool). Liquidity pool also belongs to this contract

- It downloads trading data and simulates transactions. 

- It gives the metrics for the liquidity pool



