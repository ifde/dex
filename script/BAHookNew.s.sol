pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";

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
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BAHook} from "../src/BAHookNew.sol";

import {MockV3Aggregator} from "@chainlink/local/src/data-feeds/MockV3Aggregator.sol";
import {AggregatorV2V3Interface} from "@chainlink/local/src/data-feeds/interfaces/AggregatorV2V3Interface.sol";

import {BaseScript} from "./base/BaseScript.sol";
import {LiquidityHelpers} from "./base/LiquidityHelpers.sol";
import {Deployers} from "../test/utils/Deployers.sol";

import {EasyPosm} from "../test/utils/libraries/EasyPosm.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

contract DeployBAHookScript is BaseScript, LiquidityHelpers {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    BAHook hook;
    MockV3Aggregator ethFeed;
    MockV3Aggregator shibFeed;
    PoolKey poolKey;
    uint256 tokenId;
    PoolId poolId;

    /////////////////////////////////////
    // --- Configure These ---
    /////////////////////////////////////

    int24 tickSpacing = 60;
    uint160 startingPrice;

    // --- liquidity position configuration --- //
    uint256 public token0Amount = 100e18;
    uint256 public token1Amount = 100e18;

    function run() external {
        // (currency0, currency1) = deployCurrencyPair();

        // Deploy MockV3Aggregators (8 decimals, initial prices)
        ethFeed = new MockV3Aggregator(8, 300000000000); // $3000 ETH
        shibFeed = new MockV3Aggregator(8, 30000000); // $0.03 SHIB

        // Deploy BAHook
        uint160 flags =
            uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG) ^ (0x4444 << 144);

        AggregatorV2V3Interface addr1 = AggregatorV2V3Interface(ethFeed);
        AggregatorV2V3Interface addr2 = AggregatorV2V3Interface(shibFeed);

        bytes memory constructorArgs =
            abi.encode(poolManager, AggregatorV2V3Interface(ethFeed), AggregatorV2V3Interface(shibFeed));
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(BAHook).creationCode, constructorArgs);

        // Deploy the hook using CREATE2
        vm.startBroadcast();
        hook = new BAHook{salt: salt}(poolManager, AggregatorV2V3Interface(ethFeed), AggregatorV2V3Interface(shibFeed));
        vm.stopBroadcast();

        require(address(hook) == hookAddress, "DeployHookScript: Hook Address Mismatch");

        // -------------

        // Create the pool with DYNAMIC FEE (important!)
        poolKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        poolId = poolKey.toId();

        startingPrice = Constants.SQRT_PRICE_1_1; // Starting price, sqrtPriceX96; floor(sqrt(1) * 2^96)

        int24 currentTick = TickMath.getTickAtSqrtPrice(startingPrice);

        int24 tickLower = truncateTickSpacing((currentTick - 750 * tickSpacing), tickSpacing);
        int24 tickUpper = truncateTickSpacing((currentTick + 750 * tickSpacing), tickSpacing);

        // Converts token amounts to liquidity units
        // i.e. "This is my liquidity pool with this range, I have this amounts of money"
        // "And I want the initial price to be this"
        // "What should be the liquidity?"
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            startingPrice,
            TickMath.getSqrtPriceAtTick(tickLower), // if the price is below the tick, you don't earn fees
            TickMath.getSqrtPriceAtTick(tickUpper), // if the price is above the tick, you don't earn fees
            token0Amount,
            token1Amount
        );

        // slippage limits
        uint256 amount0Max = token0Amount + 1; // If at the time of the deposit this is higher, you won't mint
        uint256 amount1Max = token1Amount + 1; // If at the time of the deposit this is higher, you won't mint

        // Provide full-range liquidity to the pool
        /*
        tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);

        uint128 liquidityAmount = 100e18;

        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );
        */

        (bytes memory actions, bytes[] memory params) = _mintLiquidityParams(
            poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, deployerAddress, Constants.ZERO_BYTES
        );

        uint256 valueToPass = currency0.isAddressZero() ? amount0Max : 0;

        vm.startBroadcast();

        tokenApprovals();

        // Initialize the pool - this will trigger afterInitialize and set the dynamic fee
        poolManager.initialize(poolKey, startingPrice);

        // Modify Liquidities
        positionManager.modifyLiquidities{value: valueToPass}(abi.encode(actions, params), block.timestamp + 3600);

        vm.stopBroadcast();

        // Read and simulate market data
        simulateMarketData();
    }

    function simulateMarketData() internal {
        // Read ETH/USDT data
        string memory ethData = vm.readFile("ETHUSDT-1m-2024-04.csv");
        string[] memory ethLines = split(ethData, "\n");

        // Read SHIB/USDT data (assume same length/timestamps)
        string memory shibData = vm.readFile("SHIBUSDT-1m-2024-04.csv");
        string[] memory shibLines = split(shibData, "\n");

        require(ethLines.length == shibLines.length, "Data length mismatch");

        uint256 initialBlock = block.number;

        for (uint256 i = 0; i < ethLines.length; i++) {
            if (bytes(ethLines[i]).length == 0) {
                break;
            }

            // Parse ETH close price (5th field, 0-indexed)
            string[] memory ethFields = split(ethLines[i], ",");
            if (ethFields.length < 5) {
                continue;
            }
            int256 ethClose = parseInt(ethFields[4]);

            // Parse SHIB close price
            string[] memory shibFields = split(shibLines[i], ",");
            if (shibFields.length < 5) {
                continue;
            }
            int256 shibClose = parseInt(shibFields[4]);

            // Update mocks
            ethFeed.updateAnswer(ethClose);
            shibFeed.updateAnswer(shibClose);

            // Roll to next block (simulate 1-minute snapshot)
            vm.roll(initialBlock + i);

            // Log current fees (query hook)
            uint24 feeAB = hook.getFee(
                address(0), poolKey, SwapParams({zeroForOne: true, amountSpecified: 1e18, sqrtPriceLimitX96: 0}), ""
            );
            uint24 feeBA = hook.getFee(
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
