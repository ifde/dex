// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {console} from "forge-std/console.sol";
import {Test} from "forge-std/Test.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {MockV3Aggregator} from "@chainlink/local/src/data-feeds/MockV3Aggregator.sol";

import {HookTest} from "./utils/HookTest.sol";

contract SimulateTradesTest is Test, HookTest {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    uint256 public totalSwaps;
    uint256 public totalVolume;
    uint256 public totalFeesCollected;
    uint256 public priceUpdates;

    struct SwapData {
        uint256 swapNumber;
        uint256 amountIn;
        bool zeroForOne;
        int256 priceAB;
        int256 priceBA;
    }

    SwapData[] public swapHistory;

    // Ported from Python: User sim structs
    struct InformedUserSim {
        uint256 maxTradeFraction; // 15%
        uint256 sensitivity; // 75%
        uint256 minPriceGap; // 0.05%
    }

    struct UninformedUserSim {
        uint256 meanTradeFraction; // 1%
        uint256 stdTradeFraction; // 0.5%
        uint256 probAToB; // 50%
    }

    // Simulation state
    InformedUserSim informedUserSim;
    UninformedUserSim uninformedUserSim;
    uint256 uninformedTradeProbability = 100; // 100% for simplicity
    uint256 numUninformedUsers = 2;

    // Initial prices for summary
    uint256 initialPriceA;
    uint256 initialPriceB;

    function setUp() public {
        deployArtifactsAndLabel();
        deployCurrencyPair();
        deployHookAndFeeds("BAHook");
        deployPool();

        // Store initial prices
        (, int256 priceA,,,) = priceFeed0.latestRoundData();
        (, int256 priceB,,,) = priceFeed1.latestRoundData();
        initialPriceA = uint256(priceA);
        initialPriceB = uint256(priceB);

        // Initialize users (matching Python)
        informedUserSim = InformedUserSim({maxTradeFraction: 150, sensitivity: 750, minPriceGap: 5});
        uninformedUserSim = UninformedUserSim({meanTradeFraction: 10, stdTradeFraction: 5, probAToB: 50});
    }

    function testSimulateTradesFromCSVs() public {
        console.log("\nHook:", address(hookContract));
        console.logBytes32(PoolId.unwrap(poolKey.toId()));
        console.log("Token0:", Currency.unwrap(poolKey.currency0));
        console.log("Token1:", Currency.unwrap(poolKey.currency1));

        _simulateFromCSVs();
        _printSummary();
    }

    function _simulateFromCSVs() internal {
        // Read ETH/USDT CSV
        string memory root = vm.projectRoot();
        string memory ethPath = string.concat(root, "/ETHUSDT-1m-latest.csv");
        string memory ethData = vm.readFile(ethPath);
        string[] memory ethLines = _split(ethData, "\n");

        // Read SHIB/USDT CSV
        string memory shibPath = string.concat(root, "/SHIBUSDT-1m-latest.csv");
        string memory shibData = vm.readFile(shibPath);
        string[] memory shibLines = _split(shibData, "\n");

        require(ethLines.length == shibLines.length, "CSV length mismatch");

        uint256 initialBlock = block.number;

        for (uint256 i = 1; i < ethLines.length; i++) {
            if (bytes(ethLines[i]).length == 0) {
                break;
            }

            // Parse ETH close price (5th field, 0-indexed)
            string[] memory ethFields = _split(ethLines[i], ",");
            int256 ethClose = _parseInt(ethFields[4]);

            // Parse SHIB close price
            string[] memory shibFields = _split(shibLines[i], ",");
            int256 shibClose = _parseInt(shibFields[4]);

            // Update mocks
            priceFeed0.updateAnswer(ethClose);
            priceFeed1.updateAnswer(shibClose);
            priceUpdates += 2;

            // Roll to next block
            vm.roll(initialBlock + i);

            uint256 priceAUint = uint256(ethClose);
            uint256 priceBUint = uint256(shibClose);

            // Process uninformed trades (like Python's loop)
            for (uint256 j = 0; j < numUninformedUsers; j++) {
                if (_trade(uninformedTradeProbability)) {
                    (bool direction, uint256 amount) = _getUninformedUserAction(priceAUint, priceBUint);
                    if (amount > 0) {
                        _processDeal(direction, amount, ethClose, shibClose);
                    }
                }
            }

            // Process informed trade
            (bool direction, uint256 amount) = _getInformedUserAction(priceAUint, priceBUint);
            if (amount > 0) {
                _processDeal(direction, amount, ethClose, shibClose);
            }
        }
    }

    function _getInformedUserAction(uint256 priceA, uint256 priceB)
        internal
        view
        returns (bool zeroForOne, uint256 amountIn)
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        uint256 priceX96 = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) >> 96;
        uint256 pPool = priceX96;
        uint256 pExt = (priceA * 1e18) / priceB;
        if (pExt == 0) return (false, 0);

        uint256 gap = (pExt > pPool) ? ((pExt - pPool) * 10000) / pPool : ((pPool - pExt) * 10000) / pPool;
        if (gap < informedUserSim.minPriceGap) return (false, 0);

        uint128 totalLiquidity = poolManager.getLiquidity(poolId);
        uint256 maxIn = (uint256(totalLiquidity) * informedUserSim.maxTradeFraction) / 1000;
        uint256 inAmount = (maxIn * informedUserSim.sensitivity * gap) / (1000 * 10000);
        inAmount = inAmount > 1000e18 ? 1000e18 : inAmount;
        return (pExt > pPool, inAmount);
    }

    function _getUninformedUserAction(uint256 priceA, uint256 priceB)
        internal
        view
        returns (bool zeroForOne, uint256 amountIn)
    {
        uint256 frac = _randomNormal(uninformedUserSim.meanTradeFraction, uninformedUserSim.stdTradeFraction);
        if (frac < 1) return (false, 0);
        bool aToB = _randomBool(uninformedUserSim.probAToB);

        uint128 totalLiquidity = poolManager.getLiquidity(poolId);
        uint256 maxIn = (uint256(totalLiquidity) * frac) / 10000;
        uint256 inAmount = maxIn > 1000e18 ? 1000e18 : maxIn;
        return (aToB, inAmount);
    }

    function _processDeal(bool zeroForOne, uint256 amountIn, int256 priceAB, int256 priceBA) internal {
        uint24 currentFee = hookContract.getFee(
            address(this),
            poolKey,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: int256(amountIn), sqrtPriceLimitX96: 0}),
            ""
        );

        uint256 bal0Before = currency0.balanceOf(address(this));
        uint256 bal1Before = currency1.balanceOf(address(this));

        // console.log("---------\n amountIn ", amountIn);
        // console.log("zeroForOne ", zeroForOne);

        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        uint256 bal0After = currency0.balanceOf(address(this));
        uint256 bal1After = currency1.balanceOf(address(this));

        if (zeroForOne) {
            MockERC20(address(Currency.unwrap(currency0))).mint(address(this), amountIn * 2);
        } else {
            MockERC20(address(Currency.unwrap(currency1))).mint(address(this), amountIn * 2);
        }

        totalSwaps++;
        totalVolume += amountIn;
        swapHistory.push(SwapData(totalSwaps, amountIn, zeroForOne, priceAB, priceBA));
    }

    function _trade(uint256 probability) internal view returns (bool) {
        return _randomBool(probability);
    }

    function _randomBool(uint256 probability) internal view returns (bool) {
        return uint256(keccak256(abi.encodePacked(blockhash(block.number - 1), block.timestamp))) % 100 < probability;
    }

    function _randomNormal(uint256 mean, uint256 std) internal view returns (uint256) {
        uint256 rand = uint256(keccak256(abi.encodePacked(blockhash(block.number - 1), block.timestamp))) % 1000;
        return mean + (rand > 500 ? std : 0);
    }

    // Helpers from example
    function _split(string memory str, string memory delim) internal pure returns (string[] memory) {
        uint256 count = 1;
        for (uint256 i = 0; i < bytes(str).length; i++) {
            if (bytes(str)[i] == bytes(delim)[0]) count++;
        }
        string[] memory parts = new string[](count);
        uint256 partIndex = 0;
        uint256 start = 0;
        for (uint256 i = 0; i < bytes(str).length; i++) {
            if (bytes(str)[i] == bytes(delim)[0]) {
                parts[partIndex] = _substring(str, start, i);
                partIndex++;
                start = i + 1;
            }
        }
        parts[partIndex] = _substring(str, start, bytes(str).length);
        return parts;
    }

    function _substring(string memory str, uint256 start, uint256 end) internal pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        bytes memory result = new bytes(end - start);
        for (uint256 i = start; i < end; i++) {
            result[i - start] = strBytes[i];
        }
        return string(result);
    }

    // Integers are multiplied by 10^8
    function _parseInt(string memory str) internal pure returns (int256) {
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
        while (decimals < 8) {
            result *= 10;
            decimals++;
        }
        return result;
    }

    function _printSummary() internal view {
        console.log("\n=== SUMMARY ===");
        console.log("Swaps:", totalSwaps);
        console.log("Volume:", totalVolume);
        console.log("Fees:", totalFeesCollected);
        uint256 n = swapHistory.length;
        uint256 start = n > 6 ? n - 6 : 0;
        for (uint256 i = 0; i < n; i++) {
            SwapData memory s = swapHistory[i];
            console.log(
                string.concat(
                    "Swap #",
                    vm.toString(s.swapNumber),
                    " ",
                    s.zeroForOne ? "A->B" : "B->A",
                    " in=",
                    vm.toString(s.amountIn),
                    " priceAB=",
                    vm.toString(s.priceAB),
                    " priceBA=",
                    vm.toString(s.priceBA)
                )
            );
        }

        int24 tickLower = truncateTickSpacing(TickMath.MIN_TICK, tickSpacing);
        int24 tickUpper = truncateTickSpacing(TickMath.MAX_TICK, tickSpacing);

        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
            poolManager.getFeeGrowthInside(poolId, tickLower, tickUpper);

        uint128 liquidity = poolManager.getLiquidity(poolId);

        uint256 Q128 = 2 ** 128;
        uint256 totalFeesToken0 = (feeGrowthInside0X128 * liquidity) / Q128;
        uint256 totalFeesToken1 = (feeGrowthInside1X128 * liquidity) / Q128;

        console.log("Total Fees Gained - Token0:", totalFeesToken0, "Token1:", totalFeesToken1);

        (, int256 ethPrice,,,) = priceFeed0.latestRoundData();
        (, int256 shibPrice,,,) = priceFeed1.latestRoundData();

        uint256 ethPriceUint = uint256(ethPrice);
        uint256 shibPriceUint = uint256(shibPrice);

        uint256 usdFeesToken0 = (totalFeesToken0 * ethPriceUint) / (10 ** 26);
        uint256 usdFeesToken1 = (totalFeesToken1 * shibPriceUint) / (10 ** 26);
        uint256 totalFeesUSD = usdFeesToken0 + usdFeesToken1;

        console.log("Total Fees in USD:", totalFeesUSD);

        uint256 initialToken0 = token0Amount;
        uint256 initialToken1 = token1Amount;
        uint256 initialUSD0 = (initialToken0 * initialPriceA) / (10 ** 26);
        uint256 initialUSD1 = (initialToken1 * initialPriceB) / (10 ** 26);
        uint256 initialTotalUSD = initialUSD0 + initialUSD1;

        console.log("Initial Token0:", initialToken0, "USD:", initialUSD0);
        console.log("Initial Token1:", initialToken1, "USD:", initialUSD1);
        console.log("Initial Total USD:", initialTotalUSD);

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        (uint256 finalToken0, uint256 finalToken1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), liquidity
        );
        uint256 finalUSD0 = (finalToken0 * ethPriceUint) / (10 ** 26);
        uint256 finalUSD1 = (finalToken1 * shibPriceUint) / (10 ** 26);
        uint256 finalTotalUSD = finalUSD0 + finalUSD1;

        console.log("Final Token0:", finalToken0, "USD:", finalUSD0);
        console.log("Final Token1:", finalToken1, "USD:", finalUSD1);
        console.log("Final Total USD:", finalTotalUSD);

        uint256 holdingValue =
            (initialToken0 * ethPriceUint) / (10 ** 26) + (initialToken1 * shibPriceUint) / (10 ** 26);
        uint256 impermanentLoss = holdingValue > finalTotalUSD ? holdingValue - finalTotalUSD : 0;

        console.log("Holding Value at Final Prices USD:", holdingValue);
        console.log("LP Value at Final Prices USD:", finalTotalUSD);
        console.log("Impermanent Loss USD:", impermanentLoss);

        int256 effectiveIL = int256(impermanentLoss) - int256(totalFeesUSD);
        console.log("Effective Impermanent Loss (after fees) USD:", effectiveIL);
        if (effectiveIL <= 0) {
            console.log("Gain from fees covering IL:", uint256(-effectiveIL));
        } else {
            console.log("Net Loss:", uint256(effectiveIL));
        }

        console.log("=== END ===\n");
    }
}
