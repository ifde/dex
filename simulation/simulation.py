#!/usr/bin/env python3
import json
import subprocess
import sys
import time
import re
from web3 import Web3
from eth_account import Account
from pathlib import Path

# Configuration
RPC_URL = "http://localhost:8545"
TRADES_JSON = "trades.json"
PRIVATE_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"  # anvil default

# Mock V3 Aggregator ABI
MOCK_V3_AGGREGATOR_ABI = [
    {
        "inputs": [{"internalType": "int256", "name": "_answer", "type": "int256"}],
        "name": "updateAnswer",
        "outputs": [],
        "stateMutability": "nonpayable",
        "type": "function"
    },
    {
        "inputs": [],
        "name": "latestAnswer",
        "outputs": [{"internalType": "int256", "name": "", "type": "int256"}],
        "stateMutability": "view",
        "type": "function"
    },
    {
        "inputs": [],
        "name": "decimals",
        "outputs": [{"internalType": "uint8", "name": "", "type": "uint8"}],
        "stateMutability": "view",
        "type": "function"
    }
]

class TradeSimulator:
    def __init__(self, trades_json_path=TRADES_JSON):
        """Initialize the trade simulator"""
        self.w3 = Web3(Web3.HTTPProvider(RPC_URL))
        
        if not self.w3.is_connected():
            raise Exception(f"Failed to connect to {RPC_URL}")
        
        self.account = Account.from_key(PRIVATE_KEY)
        self.trades_json_path = trades_json_path
        
        # Contracts will be initialized after deployment
        self.price_feed0_contract = None
        self.price_feed1_contract = None
        self.hook_contract = None
        self.price_feed0_addr = None
        self.price_feed1_addr = None
        self.hook_addr = None
        
        # Statistics
        self.total_swaps = 0
        self.total_volume = 0
        self.total_fees = 0
        self.price_feed_updates = 0
        
        print(f"Connected to {RPC_URL}")
        print(f"Account: {self.account.address}\n")
    
    def load_trades(self):
        """Load trades from JSON file"""
        with open(self.trades_json_path) as f:
            return json.load(f)
    
    def deploy_price_feeds(self):
        """Deploy price feeds using init_price_feeds.py"""
        print("=" * 60)
        print("Step 1: Deploying Price Feeds")
        print("=" * 60)
        
        result = subprocess.run(
            ["python", "simulation/init_price_feeds.py"],
            capture_output=True,
            text=True
        )
        
        if result.returncode != 0:
            print("Error deploying price feeds:")
            print(result.stderr)
            sys.exit(1)
        
        print(result.stdout)
        
        # Extract price feed addresses from output
        addresses = self.extract_addresses_from_output(result.stdout)
        
        self.price_feed0_addr = addresses.get('ETH/USD')
        self.price_feed1_addr = addresses.get('SHIB/USD')
        
        if not self.price_feed0_addr or not self.price_feed1_addr:
            print("Error: Could not extract price feed addresses")
            sys.exit(1)
        
        print(f"\nPrice feeds deployed:")
        print(f"  ETH/USD: {self.price_feed0_addr}")
        print(f"  SHIB/USD: {self.price_feed1_addr}\n")
        
        # Initialize price feed contracts
        self.price_feed0_contract = self.w3.eth.contract(
            address=Web3.to_checksum_address(self.price_feed0_addr),
            abi=MOCK_V3_AGGREGATOR_ABI
        )
        self.price_feed1_contract = self.w3.eth.contract(
            address=Web3.to_checksum_address(self.price_feed1_addr),
            abi=MOCK_V3_AGGREGATOR_ABI
        )
        
        return self.price_feed0_addr, self.price_feed1_addr
    
    def deploy_hook(self):
        """Deploy hook contract using forge script"""
        print("=" * 60)
        print("Step 2: Deploying Hook Contract")
        print("=" * 60)
        
        cmd = [
            "forge",
            "script",
            "script/DeployHook.s.sol",
            "BAHook",
            self.price_feed0_addr,
            self.price_feed1_addr,
            "--rpc-url",
            RPC_URL,
            "--broadcast",
            "--private-key",
            PRIVATE_KEY
        ]
        
        print(f"Executing: {' '.join(cmd[:-2])} --private-key [REDACTED]\n")
        
        result = subprocess.run(cmd, capture_output=True, text=True)
        
        if result.returncode != 0:
            print("Error deploying hook:")
            print(result.stderr)
            sys.exit(1)
        
        print(result.stdout)
        
        # Extract hook address from output
        hook_addr = self.extract_hook_address(result.stdout)
        
        if not hook_addr:
            print("Error: Could not extract hook address from deployment output")
            print("Make sure DeployHook.s.sol logs the hook address")
            sys.exit(1)
        
        self.hook_addr = hook_addr
        
        print(f"\nHook deployed: {self.hook_addr}\n")
        
        return self.hook_addr
    
    def extract_addresses_from_output(self, output):
        """Extract deployed contract addresses from script output"""
        addresses = {}
        
        # Look for "ETH/USD: 0x..."
        eth_match = re.search(r'ETH/USD:\s+(0x[a-fA-F0-9]{40})', output)
        if eth_match:
            addresses['ETH/USD'] = eth_match.group(1)
        
        # Look for "SHIB/USD: 0x..."
        shib_match = re.search(r'SHIB/USD:\s+(0x[a-fA-F0-9]{40})', output)
        if shib_match:
            addresses['SHIB/USD'] = shib_match.group(1)
        
        return addresses
    
    def extract_hook_address(self, output):
        """Extract hook address from deployment output"""
        # Look for "BAHook deployed at: 0x..." or similar patterns
        patterns = [
            r'BAHook\s+deployed at:\s+(0x[a-fA-F0-9]{40})',
            r'deployed at:\s+(0x[a-fA-F0-9]{40})',
            r'Hook:\s+(0x[a-fA-F0-9]{40})',
        ]
        
        for pattern in patterns:
            match = re.search(pattern, output)
            if match:
                return match.group(1)
        
        return None
    
    def update_price_feeds(self, price_a, price_b):
        """Update price feeds with new market prices via blockchain transactions"""
        try:
            # Convert prices to Chainlink format (8 decimals)
            price_a_int = int(price_a * 1e8)
            price_b_int = int(price_b * 1e8)
            
            print(f"  - Updating price feeds: A=${price_a:.4f}, B=${price_b:.6f}")
            
            # Get current nonce
            nonce = self.w3.eth.get_transaction_count(self.account.address)
            
            # Prepare update for price feed 0
            tx0 = self.price_feed0_contract.functions.updateAnswer(
                price_a_int
            ).build_transaction({
                'from': self.account.address,
                'nonce': nonce,
                'gas': 100000,
                'gasPrice': self.w3.eth.gas_price,
            })
            
            # Sign and send transaction for feed 0
            signed_tx0 = self.w3.eth.account.sign_transaction(tx0, PRIVATE_KEY)
            tx_hash0 = self.w3.eth.send_raw_transaction(signed_tx0.raw_transaction)
            
            # Prepare update for price feed 1
            tx1 = self.price_feed1_contract.functions.updateAnswer(
                price_b_int
            ).build_transaction({
                'from': self.account.address,
                'nonce': nonce + 1,
                'gas': 100000,
                'gasPrice': self.w3.eth.gas_price,
            })
            
            # Sign and send transaction for feed 1
            signed_tx1 = self.w3.eth.account.sign_transaction(tx1, PRIVATE_KEY)
            tx_hash1 = self.w3.eth.send_raw_transaction(signed_tx1.raw_transaction)
            
            # Wait for transactions to be mined
            receipt0 = self.w3.eth.wait_for_transaction_receipt(tx_hash0, timeout=30)
            receipt1 = self.w3.eth.wait_for_transaction_receipt(tx_hash1, timeout=30)
            
            if receipt0['status'] == 1 and receipt1['status'] == 1:
                self.price_feed_updates += 2
                print(f"    Price feeds updated")
                return True
            else:
                print(f"    Transaction failed")
                return False
                
        except Exception as e:
            print(f"    Error updating price feeds: {e}")
            return False
    
    def execute_trade(self, trade, index):
        """Execute a single trade based on trade data"""
        if index % 100 == 0 and index > 0:
            print(f"\n[Processing trade {index:,}...]")
        
        direction = trade.get("direction")
        amount_in = trade.get("amount_in", 0)
        price_a = trade.get("price_a_usd", 0)
        price_b = trade.get("price_b_usd", 0)
        
        # Validate trade data
        if not direction or amount_in == 0:
            return False
        
        if direction not in ["A_TO_B", "B_TO_A"]:
            return False
        
        # Update price feeds if available
        if price_a > 0 and price_b > 0:
            self.update_price_feeds(price_a, price_b)
        
        # Track statistics
        self.total_swaps += 1
        self.total_volume += amount_in
        
        # In production, execute actual swap transaction here
        # For now, we're just updating price feeds based on market data
        
        return True
    
    def simulate(self):
        """Run the complete trade simulation"""
        # Deploy price feeds
        self.deploy_price_feeds()
        
        # Deploy hook contract
        self.deploy_hook()
        
        # Load and simulate trades
        print("=" * 60)
        print("Step 3: Running Trade Simulation")
        print("=" * 60)
        
        trades = self.load_trades()
        
        print(f"\nLoaded {len(trades):,} trades from {self.trades_json_path}")
        print(f"Starting simulation...\n")
        
        start_time = time.time()
        
        for i, trade in enumerate(trades):
            # Skip incomplete trade records
            if not trade.get("amount_in") or not trade.get("direction"):
                continue
            
            try:
                self.execute_trade(trade, i)
                
                # Small delay to prevent rate limiting
                if i % 10 == 0 and i > 0:
                    time.sleep(0.05)
                    
            except Exception as e:
                print(f"  - Trade {i} failed: {e}")
        
        elapsed = time.time() - start_time
        self.print_summary(elapsed)
    
    def print_summary(self, elapsed_time):
        """Print simulation summary"""
        print(f"\n{'='*60}")
        print(f"TRADE SIMULATION SUMMARY")
        print(f"{'='*60}")
        print(f"Total trades: {self.total_swaps:,}")
        print(f"Total volume: {self.total_volume:,.2f}")
        print(f"Price feed updates: {self.price_feed_updates}")
        print(f"Elapsed time: {elapsed_time:.2f}s")
        if self.total_swaps > 0:
            print(f"Avg time per trade: {elapsed_time/self.total_swaps*1000:.2f}ms")
        print(f"\nDeployed contracts:")
        print(f"  Hook: {self.hook_addr}")
        print(f"  Price Feed 0: {self.price_feed0_addr}")
        print(f"  Price Feed 1: {self.price_feed1_addr}")
        print(f"{'='*60}\n")

def main():
    """Main entry point"""
    try:
        simulator = TradeSimulator()
        simulator.simulate()
    except Exception as e:
        print(f"\nFatal error: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()