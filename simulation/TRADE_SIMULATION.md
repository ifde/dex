# Trade Simulation Guide

This guide explains how to deploy contracts and simulate trades using the market data from `trades.json`.

## Prerequisites

- Anvil running locally on `http://localhost:8545`
- Foundry installed
- Python 3.8+ with web3.py installed

## Step-by-Step Workflow

### 1. Start Anvil (if not already running)

```bash
anvil
```

This will start a local Ethereum node with default accounts. Note the private keys provided.

### 2. Deploy Price Feeds

Deploy the Chainlink MockV3Aggregator contracts for price feeds:

```bash
forge script script/DeployPriceFeeds.s.sol --rpc-url http://localhost:8545 --broadcast
```

**Output example:**
```
ETH/USD: 0x5FbDB2315678afccb333f8a9c809d3534d4eadba
SHIB/USD: 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512
```

### 3. Deploy the Hook Contract

Deploy your hook contract (e.g., BAHook):

```bash
forge script script/DeployHook.s.sol BAHook 0 0 --rpc-url http://localhost:8545 --broadcast
```

**Output example:**
```
BAHook deployed at: 0x9fE46736679d2D9a28f38E1B37d0daF5d5d5E5e
```

### 4. Deploy the Pool (if using a separate deployment script)

If you have a pool deployment script:

```bash
forge script script/CreatePoolAndAddLiquidity.s.sol --rpc-url http://localhost:8545 --broadcast
```

### 5. Run Trade Simulation

Once all contracts are deployed, simulate the trades from `trades.json`:

```bash
python scripts/simulate_trades.py \
  0x9fE46736679d2D9a28f38E1B37d0daF5d5d5E5e \
  0x<TOKEN0_ADDRESS> \
  0x<TOKEN1_ADDRESS> \
  0x<POOL_MANAGER_ADDRESS> \
  0x5FbDB2315678afccb333f8a9c809d3534d4eadba \
  0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512
```

Replace the addresses with the actual deployed contract addresses from steps 2-4.

## How It Works

### Price Feed Updates

The simulation script automatically updates price feeds based on market data in `trades.json`:

```python
def update_price_feeds(self, price_a, price_b):
    """Update price feeds with new market prices via blockchain transactions"""
    
    # Convert prices to Chainlink format (8 decimals)
    price_a_int = int(price_a)
    price_b_int = int(price_b)
    
    # Call updateAnswer on both price feeds
    # Transactions are signed and sent to the blockchain
```

Each trade updates both price feeds with:
- **Price A**: ETH/USD price from the trade data
- **Price B**: SHIB/USD price from the trade data

### Trade Simulation

For each trade in `trades.json`:
1. Extract trade parameters (direction, amount, prices)
2. Update price feeds on-chain
3. (In production) Execute swap transaction through hook
4. Track fees and volume

### Statistics Tracked

- **Total trades**: Number of trades executed
- **Total volume**: Sum of all trade amounts
- **Price feed updates**: Number of successful blockchain updates
- **Elapsed time**: Total simulation duration

## Example Output

```
============================================================
Loaded 17,906 trades from trades.json
============================================================

[Trade 0] Processing...
  → Updating price feeds: A=$3276.71, B=$94815.94
    ✓ Price feeds updated (tx: 0x1234abcd..., 0x5678efgh...)
  ✓ Trade 1: A_TO_B amount=572.22

[Trade 100] Processing...
  → Updating price feeds: A=$3277.15, B=$94889.23
    ✓ Price feeds updated (tx: 0x9abc1234..., 0xdef56789...)
  ✓ Trade 101: A_TO_B amount=658.05

============================================================
TRADE SIMULATION SUMMARY
============================================================
Total trades: 17,906
Total volume: 8,234,567.89
Price feed updates: 35,812
Elapsed time: 145.32s
Avg time per trade: 8.13ms
============================================================
```

## Troubleshooting

### Connection Error
```
Error: Failed to connect to http://localhost:8545
```
**Solution**: Make sure Anvil is running with `anvil`

### Invalid Address
```
ValueError: invalid checksum address
```
**Solution**: Ensure all addresses are in valid Ethereum format (0x...)

### Transaction Reverted
```
Error: Transaction failed
```
**Solution**: 
- Check that price feeds are correctly deployed
- Verify contract addresses are correct
- Ensure account has sufficient balance

### Gas Issues
```
Error: Out of gas
```
**Solution**: Increase gas limit in transaction parameters (currently set to 100,000)

## Advanced Configuration

### Modifying Initial Prices

Edit `script/DeployPriceFeeds.s.sol`:

```solidity
int256 constant INITIAL_ETH_PRICE = 300000000000; // Change this value
int256 constant INITIAL_SHIB_PRICE = 3000000;     // Change this value
```

### Using Different Anvil Accounts

Modify `PRIVATE_KEY` in `scripts/simulate_trades.py`:

```python
# Replace with a different account from anvil
PRIVATE_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
```

### Custom RPC URL

Modify `RPC_URL` in `scripts/simulate_trades.py`:

```python
RPC_URL = "http://localhost:8545"  # Change this if using different RPC
```

## Next Steps

1. **Integrate actual swaps**: Modify `simulate_trades.py` to call the swap router for each trade
2. **Fee tracking**: Add logic to query and track fees from the hook contract
3. **Data export**: Save simulation results to CSV or database
4. **Visualization**: Create charts to analyze fee collection patterns

## File Locations

- `script/DeployPriceFeeds.s.sol` - Price feed deployment
- `scripts/simulate_trades.py` - Python trade simulation
- `trades.json` - Market data for simulation
- `script/DeployHook.s.sol` - Hook deployment
