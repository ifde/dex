pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";

import {Test} from "forge-std/Test.sol";

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IPoolManager, SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {MockV3Aggregator} from "@chainlink/local/src/data-feeds/MockV3Aggregator.sol";
import {AggregatorV2V3Interface} from "@chainlink/local/src/data-feeds/interfaces/AggregatorV2V3Interface.sol";

import {BaseScript} from "../script/base/BaseScript.sol";
import {LiquidityHelpers} from "../script/base/LiquidityHelpers.sol";

import {BaseTest} from "./utils/BaseTest.sol";
import {EasyPosm} from "./utils/libraries/EasyPosm.sol";

import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {HookConstants} from "./utils/libraries/HookConstants.sol";

import {MockV3Aggregator} from "@chainlink/local/src/data-feeds/MockV3Aggregator.sol";
import {AggregatorV2V3Interface} from "@chainlink/local/src/data-feeds/interfaces/AggregatorV2V3Interface.sol";

import {HookTest} from "./utils/HookTest.sol";

contract BaseHookTest is Test, HookTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    string[] public fixtureHookNames = HookConstants.getHookNames();

    function tableHooksTest(string memory hookNames) public {
        console.log(hookNames);
        deployHookAndFeeds(hookNames);

        deployPool();

        _testMarketData();
    }

    function setUp() public {
        deployArtifactsAndLabel();

        deployCurrencyPair();
    }

    // Read and simulate market data
    function _testMarketData() public {
        hookContract.setFee(3001, poolKey);

        uint24 feeAB = hookContract.getFee(
            address(0), poolKey, SwapParams({zeroForOne: true, amountSpecified: 1e18, sqrtPriceLimitX96: 0}), ""
        );
        uint24 feeBA = hookContract.getFee(
            address(0), poolKey, SwapParams({zeroForOne: false, amountSpecified: 1e18, sqrtPriceLimitX96: 0}), ""
        );

        console.log(
            string(abi.encodePacked("Initial Fees |", " FeeAB: ", vm.toString(feeAB), " FeeBA: ", vm.toString(feeBA)))
        );

        // Simulation parameters
        uint256 puu = 100; // Probability for uninformed users (10% = 100/1000)
        uint256 m = 0.01e18; // Mean fraction for uninformed amounts (1%)
        uint256 sigma = 0.005e18; // Std dev for uninformed amounts (0.5%)

        // Approximate initial pool reserves (x for token0/ETH, y for token1/SHIB)
        uint256 x = token0Amount; // Initial ETH reserve
        uint256 y = token1Amount; // Initial SHIB reserve

        // Read ETH/USDT data
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/ETHUSDT-1m-2024-04.csv");

        string memory ethData = vm.readFile(path);
        string[] memory ethLines = split(ethData, "\n");

        console.log("Path to the ETH/USDT Feed", path);

        root = vm.projectRoot();
        path = string.concat(root, "/SHIBUSDT-1m-2024-04.csv");

        // Read SHIB/USDT data (assume same length/timestamps)
        string memory shibData = vm.readFile(path);
        string[] memory shibLines = split(shibData, "\n");

        require(ethLines.length == shibLines.length, "Data length mismatch");

        uint256 initialBlock = block.number;

        for (uint256 i = 0; i < ethLines.length; i++) {
            if (bytes(ethLines[i]).length == 0) {
                break;
            }

            // Parse ETH close price (5th field, 0-indexed)
            string[] memory ethFields = split(ethLines[i], ",");
            int256 ethClose = parseInt(ethFields[4]);

            // Parse SHIB close price
            string[] memory shibFields = split(shibLines[i], ",");
            int256 shibClose = parseInt(shibFields[4]);

            // Update mocks
            priceFeed0.updateAnswer(ethClose);
            priceFeed1.updateAnswer(shibClose);

            // Roll to next block (simulate 1-minute snapshot)
            vm.roll(initialBlock + i);

            uint256 amountIn = 1e18;
            BalanceDelta swapDelta1 = swapRouter.swapExactTokensForTokens({
                amountIn: amountIn,
                amountOutMin: 0,
                zeroForOne: true,
                poolKey: poolKey,
                hookData: Constants.ZERO_BYTES,
                receiver: address(this),
                deadline: block.timestamp + 1
            });

            // Log current fees (query hook)
            uint24 feeAB = hookContract.getFee(
                address(0), poolKey, SwapParams({zeroForOne: true, amountSpecified: 1e18, sqrtPriceLimitX96: 0}), ""
            );
            uint24 feeBA = hookContract.getFee(
                address(0), poolKey, SwapParams({zeroForOne: false, amountSpecified: 1e18, sqrtPriceLimitX96: 0}), ""
            );

            string memory logMessage = string(
                abi.encodePacked(
                    "Block ", vm.toString(block.number), " FeeAB: ", vm.toString(feeAB), " FeeBA: ", vm.toString(feeBA)
                )
            );
            console.log(logMessage);
        }
    }

    // Helpers for sqrt, log, cos (implement or use approximations; placeholders)
    function sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }

    // Simple string splitting (by delimiter)
    function split(string memory str, string memory delim) internal pure returns (string[] memory) {
        uint256 count = 1;
        for (uint256 i = 0; i < bytes(str).length; i++) {
            if (bytes(str)[i] == bytes(delim)[0]) count++;
        }
        string[] memory parts = new string[](count);
        uint256 partIndex = 0;
        uint256 start = 0;
        for (uint256 i = 0; i < bytes(str).length; i++) {
            if (bytes(str)[i] == bytes(delim)[0]) {
                parts[partIndex] = substring(str, start, i);
                partIndex++;
                start = i + 1;
            }
        }
        parts[partIndex] = substring(str, start, bytes(str).length);
        return parts;
    }

    function substring(string memory str, uint256 start, uint256 end) internal pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        bytes memory result = new bytes(end - start);
        for (uint256 i = start; i < end; i++) {
            result[i - start] = strBytes[i];
        }
        return string(result);
    }

    // Simple int parsing (assumes positive floats like "4.15540000")
    function parseInt(string memory str) internal pure returns (int256) {
        bytes memory b = bytes(str);
        int256 result = 0;
        bool decimal = false;
        uint256 decimals = 0;
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] == ".") {
                decimal = true;
            } else {
                result = result * 10 + int256(uint256(uint8(b[i])) - 48);
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
