// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {MockV3Aggregator} from "@chainlink/local/src/data-feeds/MockV3Aggregator.sol";

contract DeployPriceFeeds is Script {
    // Initial prices
    // ETH: $3000, 8 decimals = 300000000000
    // SHIB: $0.03, 8 decimals = 3000000

    int256 constant INITIAL_ETH_PRICE = 300000000000; // $3000 with 8 decimals
    int256 constant INITIAL_SHIB_PRICE = 3000000; // $0.03 with 8 decimals

    MockV3Aggregator public priceFeed0;
    MockV3Aggregator public priceFeed1;

    function run() public {
        vm.startBroadcast();

        // Deploy ETH/USD price feed (8 decimals)
        priceFeed0 = new MockV3Aggregator(8, INITIAL_ETH_PRICE);
        console.log("ETH/USD Price Feed deployed at:", address(priceFeed0));
        console.log("Initial price: $", uint256(INITIAL_ETH_PRICE) / 1e8);

        // Deploy SHIB/USD price feed (8 decimals)
        priceFeed1 = new MockV3Aggregator(8, INITIAL_SHIB_PRICE);
        console.log("SHIB/USD Price Feed deployed at:", address(priceFeed1));
        console.log("Initial price: $", uint256(INITIAL_SHIB_PRICE) / 1e8);

        vm.stopBroadcast();

        console.log("\n=== Price Feeds Deployed ===");
        console.log("ETH/USD:", address(priceFeed0));
        console.log("SHIB/USD:", address(priceFeed1));
    }
}
