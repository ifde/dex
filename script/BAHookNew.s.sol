pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BAHook} from "../src/BAHook.sol";

import {MockV3Aggregator} from "@chainlink/local/src/data-feeds/MockV3Aggregator.sol";
import {AggregatorV2V3Interface} from "@chainlink/local/src/data-feeds/interfaces/AggregatorV2V3Interface.sol";

import {BaseScript} from "./base/BaseScript.sol";
import {Deployers} from "../test/utils/Deployers.sol";

contract SimulateMarket is BaseScript, Deployers {
    BAHook hook;
    AggregatorV2V3Interface ethFeed;
    AggregatorV2V3Interface shibFeed;
    PoolKey poolKey;
    IPoolManager poolManager;

    function run() external {
        vm.startBroadcast();

        // Deploy Uniswap V4 artifacts (using existing deployers)
        poolManager = IPoolManager(address(manager)); // From Deployers

        (currency0, currency1) = deployCurrencyPair();

        // Deploy MockV3Aggregators (8 decimals, initial prices)
        ethFeed = new MockV3Aggregator(8, 300000000000); // $3000 ETH
        shibFeed = new MockV3Aggregator(8, 30000000); // $0.03 SHIB

        // Deploy BAHook
        address flags = address(
            uint160(
                Hooks.AFTER_INITIALIZE_FLAG |
                Hooks.BEFORE_SWAP_FLAG |
                Hooks.AFTER_SWAP_FLAG
            ) ^ (0x4444 << 144)
        );
        bytes memory initCode = type(BAHook).creationCode;
        address hookAddr = HookMiner.mine(hook, flags, initCode);
        hook = new BAHook(poolManager, address(ethFeed), address(shibFeed));
        require(address(hook) == hookAddr, "Hook address mismatch");

        // Deploy tokens and create pool
        (currency0, currency1) = deployMintAndApprove2Currencies(); // From Deployers
        poolKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hookAddr));
        poolManager.initialize(poolKey, SQRT_PRICE_1_1); // Initial price

        // Provide liquidity (small amount for simulation)
        // ... (use existing liquidity helpers if needed)

        // Read and simulate market data
        simulateMarketData();

        vm.stopBroadcast();
    }

    function simulateMarketData() internal {
        // Read ETH/USDT data
        string memory ethData = vm.readFile("eth_usdt_data.csv");
        string[] memory ethLines = split(ethData, "\n");

        // Read SHIB/USDT data (assume same length/timestamps)
        string memory shibData = vm.readFile("shib_usdt_data.csv");
        string[] memory shibLines = split(shibData, "\n");

        require(ethLines.length == shibLines.length, "Data length mismatch");

        uint256 initialBlock = block.number;

        for (uint i = 1; i < ethLines.length; i++) { // Skip header
            // Parse ETH close price (5th field, 0-indexed)
            string[] memory ethFields = split(ethLines[i], "\t");
            int256 ethClose = parseInt(ethFields[4]);

            // Parse SHIB close price
            string[] memory shibFields = split(shibLines[i], "\t");
            int256 shibClose = parseInt(shibFields[4]);

            // Update mocks
            ethFeed.updateAnswer(ethClose);
            shibFeed.updateAnswer(shibClose);

            // Roll to next block (simulate 1-minute snapshot)
            vm.roll(initialBlock + i);

            // Log current fees (query hook)
            uint24 feeAB = hook.getFee(address(0), poolKey, IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: 1e18,
                sqrtPriceLimitX96: 0
            }), "");
            uint24 feeBA = hook.getFee(address(0), poolKey, IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: 1e18,
                sqrtPriceLimitX96: 0
            }), "");
            console.log("Block", block.number, "FeeAB:", feeAB, "FeeBA:", feeBA);
        }
    }

    // Simple string splitting (by delimiter)
    function split(string memory str, string memory delim) internal pure returns (string[] memory) {
        uint count = 1;
        for (uint i = 0; i < bytes(str).length; i++) {
            if (bytes(str)[i] == bytes(delim)[0]) count++;
        }
        string[] memory parts = new string[](count);
        uint partIndex = 0;
        uint start = 0;
        for (uint i = 0; i < bytes(str).length; i++) {
            if (bytes(str)[i] == bytes(delim)[0]) {
                parts[partIndex] = substring(str, start, i);
                partIndex++;
                start = i + 1;
            }
        }
        parts[partIndex] = substring(str, start, bytes(str).length);
        return parts;
    }

    function substring(string memory str, uint start, uint end) internal pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        bytes memory result = new bytes(end - start);
        for (uint i = start; i < end; i++) {
            result[i - start] = strBytes[i];
        }
        return string(result);
    }

    // Simple int parsing (assumes positive floats like "4.15540000")
    function parseInt(string memory str) internal pure returns (int256) {
        bytes memory b = bytes(str);
        int256 result = 0;
        bool decimal = false;
        uint decimals = 0;
        for (uint i = 0; i < b.length; i++) {
            if (b[i] == ".") {
                decimal = true;
            } else {
                result = result * 10 + int256(uint256(b[i]) - 48);
                if (decimal) decimals++;
            }
        }
        // Scale to 8 decimals (Chainlink standard)
        while (decimals < 8) {
            result *= 10;
            decimals++;
        }
        return result;
    }
}