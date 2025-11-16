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

import {BaseScript} from "../script/base/BaseScript.sol";
import {LiquidityHelpers} from "../script/base/LiquidityHelpers.sol";

import {BaseTest} from "./utils/BaseTest.sol";
import {EasyPosm} from "./utils/libraries/EasyPosm.sol";

import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

contract BAHookTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    BAHook hook;
    MockV3Aggregator ethFeed;
    MockV3Aggregator shibFeed;
    PoolKey poolKey;

    Currency currency0;
    Currency currency1;

    /////////////////////////////////////
    // --- Configure These ---
    /////////////////////////////////////

    int24 tickSpacing = 60;
    uint160 startingPrice;

    // --- liquidity position configuration --- //
    uint256 public token0Amount = 100e18;
    uint256 public token1Amount = 100e18;

    // range of the position, must be a multiple of tickSpacing
    int24 tickLower;
    int24 tickUpper;
    /////////////////////////////////////

    uint256 tokenId;
    PoolId poolId;

    function setUp() public {
        deployArtifactsAndLabel();

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

        bytes memory constructorArgs = abi.encode(poolManager, AggregatorV2V3Interface(ethFeed), AggregatorV2V3Interface(shibFeed));
        deployCodeTo("BAHookNew.sol:BAHook", constructorArgs, flags);
        hook = BAHook(flags);

        // -------------

        // Create the pool with DYNAMIC FEE (important!)
        poolKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        poolId = poolKey.toId();

        startingPrice = Constants.SQRT_PRICE_1_1; // Starting price, sqrtPriceX96; floor(sqrt(1) * 2^96)

        int24 currentTick = TickMath.getTickAtSqrtPrice(startingPrice);

        int24 tickLower = truncateTickSpacing((currentTick - 750 * tickSpacing), tickSpacing);
        int24 tickUpper = truncateTickSpacing((currentTick + 750 * tickSpacing), tickSpacing);
    
        // Initialize the pool - this will trigger afterInitialize and set the dynamic fee
        poolManager.initialize(poolKey, startingPrice);

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

        (tokenId,) = positionManager.mint(
            poolKey,
            tickLower,
            tickUpper,
            liquidity,
            amount0Max,
            amount1Max,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );
    }

    // Read and simulate market data
    function testMarketData() public {

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

        console.log(path);

        root = vm.projectRoot();
        path = string.concat(root, "/SHIBUSDT-1m-2024-04.csv");

        // Read SHIB/USDT data (assume same length/timestamps)
        string memory shibData = vm.readFile(path);
        string[] memory shibLines = split(shibData, "\n");

        require(ethLines.length == shibLines.length, "Data length mismatch");

        uint256 initialBlock = block.number;

        for (uint i = 0; i < ethLines.length; i++) {
            if (ethLines[i].length == 0) {
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

            // Simulate informed user trade
            simulateInformedTrade(ethClose, shibClose, x, y);

            // Simulate uninformed user trade
            if (vm.randomUint() % 1000 < puu) {
                bool zeroForOne = vm.randomUint() % 2 == 0;
                uint256 fraction = sampleNormal(m, sigma);
                uint256 amountIn = zeroForOne ? (x * fraction) / 1e18 : (y * fraction) / 1e18;
                if (amountIn > 0) {
                    try swapRouter.swapExactTokensForTokens({
                        amountIn: amountIn,
                        amountOutMin: 0,
                        zeroForOne: zeroForOne,
                        poolKey: poolKey,
                        hookData: Constants.ZERO_BYTES,
                        receiver: address(this),
                        deadline: block.timestamp + 1
                    }) {} catch {}
                }
            }

            // Roll to next block (simulate 1-minute snapshot)
            vm.roll(initialBlock + i);

            // Log current fees (query hook)
            uint24 feeAB = hook.getFee(address(0), poolKey, SwapParams({
                zeroForOne: true,
                amountSpecified: 1e18,
                sqrtPriceLimitX96: 0
            }), "");
            uint24 feeBA = hook.getFee(address(0), poolKey, SwapParams({
                zeroForOne: false,
                amountSpecified: 1e18,
                sqrtPriceLimitX96: 0
            }), "");
            
            string memory logMessage = string(abi.encodePacked(
            "Block ", vm.toString(block.number), 
            " FeeAB: ", vm.toString(feeAB),
            " FeeBA: ", vm.toString(feeBA)
            ));
            console.log(logMessage);
        }
    }

    function truncateTickSpacing(int24 tick, int24 tickSpacing) internal pure returns (int24) {
        /// forge-lint: disable-next-line(divide-before-multiply)
        return ((tick / tickSpacing) * tickSpacing);
    }

    // Helper: Simulate informed user trade
    function simulateInformedTrade(int256 ethPrice, int256 shibPrice, uint256 x, uint256 y) internal {
        // pCEX = ethPrice / shibPrice (fixed point, 8 decimals each, so divide by 1e8)
        uint256 pCEX = (uint256(ethPrice) * 1e18) / uint256(shibPrice); // Scale to 18 decimals

        // Get current fee (average for simplicity)
        uint24 feeAB = hook.getFee(address(0), poolKey, SwapParams({zeroForOne: true, amountSpecified: 1e18, sqrtPriceLimitX96: 0}), "");
        uint24 feeBA = hook.getFee(address(0), poolKey, SwapParams({zeroForOne: false, amountSpecified: 1e18, sqrtPriceLimitX96: 0}), "");
        uint256 fee = ((uint256(feeAB) + uint256(feeBA)) / 2) * 1e14; // Fee in 18 decimals (bps * 1e14 for 0.01% to 1e18)

        uint256 oneMinusFee = 1e18 - fee;

        // deltaX* = (sqrt(x * y * (1 - fee) / pCEX) - x) / (1 - fee)
        uint256 xy = (x * y) / 1e18;
        uint256 numerator = (xy * oneMinusFee) / pCEX;
        uint256 sqrtNum = sqrt(numerator); // Approximate sqrt (implement or use library)
        uint256 deltaX = (sqrtNum > x) ? ((sqrtNum - x) * 1e18) / oneMinusFee : 0;

        if (deltaX > 1e16) { // Opportunity threshold
            try swapRouter.swapExactTokensForTokens({
                amountIn: deltaX / 1e18,
                amountOutMin: 0,
                zeroForOne: true,
                poolKey: poolKey,
                hookData: Constants.ZERO_BYTES,
                receiver: address(this),
                deadline: block.timestamp + 1
            }) {} catch {}
        }

        // deltaY* = (x * y / (x + deltaX)) * (1 - fee) - y
        uint256 xPlusDeltaX = x + deltaX;
        uint256 deltaY = ((x * y / xPlusDeltaX) * oneMinusFee / 1e18) - y;

        // deltaY* = (x * y / (x + deltaX)) * (1 - fee) - y
        uint256 xPlusDeltaX = x + deltaX;
        uint256 deltaY = ((x * y / xPlusDeltaX) * oneMinusFee / 1e18) - y;

        if (deltaY > 1e16) {
            try swapRouter.swapExactTokensForTokens({
                amountIn: deltaY / 1e18,
                amountOutMin: 0,
                zeroForOne: false,
                poolKey: poolKey,
                hookData: Constants.ZERO_BYTES,
                receiver: address(this),
                deadline: block.timestamp + 1
            }) {} catch {}
        }
    }

    // Helper: Sample from normal distribution (simplified Box-Muller approximation)
    function sampleNormal(uint256 mean, uint256 stddev) internal returns (uint256) {
        uint256 u1 = vm.randomUint() % 1e18;
        uint256 u2 = vm.randomUint() % 1e18;
        int256 z = int256(sqrt(-2 * log(u1 / 1e18) * 1e18) * cos(2 * 3.1415926535 * u2 / 1e18)); // Approximate
        uint256 sample = uint256(int256(mean) + z * int256(stddev) / 1e18);
        return sample < 0.001e18 ? 0.001e18 : sample > 0.1e18 ? 0.1e18 : sample; // Clamp
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