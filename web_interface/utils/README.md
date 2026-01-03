# Constructor of Dynamic Fees for Decentralized Exchanges (DEX)

## How to get started 

1. Install dependencies (if you don't have the `\lib` folder already)

```
bash init.sh
```

Or if you already have a ZIP file with `/lib` folder, just initialize git

```
git init
git add .
git commit -m "Init"
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
- HookName (see `/src` folder for the name)
- FeedAddress0 (Chainlink)
- FeedAddress1 (Chainlink)

5. Run tests 

First, create a Python virtual environment and install dependencies

```
python -m venv .venv 
source ./.venv/bin/activate # Windows: .venv\Scripts\Activate.ps1
pip install -r requirements.txt
```

Then upload historical market data from Binance:

```
python fetch_binance_data.py
```

Then run tests

```
forge -vvvv test
```

6. Enjoy

7. You can make changes to the files

8. And also feel free to create any additional tests / sripts




