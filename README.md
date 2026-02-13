# Constructor of Dynamic Fees for Decentralized Exchanges (DEX) Project

### How to run locally

`python -m venv .venv`

`source ./.venv/bin/activate`

`pip install -r requirements.txt`

```
python ./web_interface/app.py
```

### Run tests

`forge test --gas-limit 100000000000000`    

`forge test --match-path Simulation.t.sol --gas-limit 10000000000 MEVChargeHook`    

