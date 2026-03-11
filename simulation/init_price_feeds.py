import json
import subprocess
import sys
from pathlib import Path

def get_initial_prices_from_trades():
    """Extract initial prices from trades.json"""
    trades_path = Path("trades.json")
    
    if not trades_path.exists():
        print("Error: trades.json not found")
        sys.exit(1)
    
    with open(trades_path) as f:
        trades = json.load(f)
    
    # Find first trade with price data
    for trade in trades:
        if isinstance(trade, dict) and "price_a_usd" in trade and "price_b_usd" in trade:
            price_a = trade["price_a_usd"]
            price_b = trade["price_b_usd"]
            
            if price_a > 0 and price_b > 0:
                return price_a, price_b
    
    print("Error: No valid price data found in trades.json")
    sys.exit(1)

def convert_to_chainlink_format(price_usd):
    """Convert USD price to Chainlink format (8 decimals)"""
    return int(price_usd * 1e8)

def deploy_price_feeds(price_a_usd, price_b_usd):
    """Deploy price feeds with initial prices via Solidity script"""
    
    price_a_chainlink = convert_to_chainlink_format(price_a_usd)
    price_b_chainlink = convert_to_chainlink_format(price_b_usd)
    
    print(f"\n📊 Deploying Price Feeds")
    print(f"   ETH/USD: ${price_a_usd} → {price_a_chainlink}")
    print(f"   SHIB/USD: ${price_b_usd} → {price_b_chainlink}")
    
    # Create temporary Solidity script with constructor arguments
    script_content = f"""// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {{Script}} from "forge-std/Script.sol";
import {{console}} from "forge-std/console.sol";
import {{MockV3Aggregator}} from "@chainlink/local/src/data-feeds/MockV3Aggregator.sol";

contract DeployPriceFeedsInit is Script {{
    int256 constant INITIAL_ETH_PRICE = {price_a_chainlink};
    int256 constant INITIAL_SHIB_PRICE = {price_b_chainlink};

    MockV3Aggregator public priceFeed0;
    MockV3Aggregator public priceFeed1;

    function run() public {{
        vm.startBroadcast();

        priceFeed0 = new MockV3Aggregator(8, INITIAL_ETH_PRICE);
        console.log("ETH/USD Price Feed deployed at:", address(priceFeed0));
        console.log("Initial price: $", uint256(INITIAL_ETH_PRICE) / 1e8);

        priceFeed1 = new MockV3Aggregator(8, INITIAL_SHIB_PRICE);
        console.log("SHIB/USD Price Feed deployed at:", address(priceFeed1));
        console.log("Initial price: $", uint256(INITIAL_SHIB_PRICE) / 1e8);

        vm.stopBroadcast();

        console.log("\\n=== Price Feeds Deployed ===");
        console.log("ETH/USD:", address(priceFeed0));
        console.log("SHIB/USD:", address(priceFeed1));
    }}
}}
"""
    
    temp_script = Path("script/DeployPriceFeedsInit.s.sol")
    temp_script.write_text(script_content)
    
    # Execute forge script
    cmd = [
        "forge",
        "script",
        str(temp_script),
        "--rpc-url",
        "http://localhost:8545",
    ]
    
    result = subprocess.run(cmd, capture_output=False)
    
    if result.returncode != 0:
        print("Error: Failed to deploy price feeds")
        sys.exit(1)
    
    print("Price feeds deployed successfully")
    
    # Cleanup temp script
    temp_script.unlink()

def main():
    
    price_a, price_b = get_initial_prices_from_trades()
    print(f"✓ Found initial prices: ETH=${price_a}, SHIB=${price_b}")
    
    deploy_price_feeds(price_a, price_b)

if __name__ == "__main__":
    main()