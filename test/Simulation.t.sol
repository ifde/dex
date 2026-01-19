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
        uint256 feeAmount;
        bool zeroForOne;
        int256 priceA8;
        int256 priceB8;
    }

    SwapData[] public swapHistory;

    uint256 internal constant MAX_TRADES = 200;

    function setUp() public {
        deployArtifactsAndLabel();
        deployCurrencyPair();
    }

    function testSimulateTradesFromCSV() public {
        deployHookAndFeeds("BAHook");
        deployPool();

        console.log("\nHook:", address(hookContract));
        console.logBytes32(PoolId.unwrap(poolKey.toId()));
        console.log("Token0:", Currency.unwrap(poolKey.currency0));
        console.log("Token1:", Currency.unwrap(poolKey.currency1));

        string memory path = string.concat(vm.projectRoot(), "/trades_processed_new.csv");
        string memory csv = vm.readFile(path);
        console.log("Reading trades from:", path);

        _simulateTrades(csv);
        _printSummary(csv);
    }

    function _simulateTrades(string memory csv) internal {
        uint256 lines = _countLines(csv);
        if (lines <= 1) return; // header only
        uint256 tradeLines = lines - 1;
        uint256 maxTrades = tradeLines > MAX_TRADES ? MAX_TRADES : tradeLines;

        for (uint256 i = 1; i <= maxTrades; i++) {
            _processTradeLineCSV(csv, i);
            vm.roll(block.number + 1);
        }
    }

    function _processTradeLineCSV(string memory csv, uint256 lineNum) internal {
        // CSV: direction,amount_in,price_a_usd,price_b_usd
        (string memory direction, string memory amountStr, string memory priceAStr, string memory priceBStr) =
            _readCsvLine(csv, lineNum);

        if (bytes(direction).length == 0 || bytes(amountStr).length == 0) return;

        bool zeroForOne = keccak256(bytes(direction)) == keccak256(bytes("A_TO_B"));

        // amount_in to 1e18
        uint256 amountIn = _parseDecimal(amountStr, 18);
        if (amountIn == 0) return;

        // prices to 8 decimals and update feeds
        int256 priceAB = int256(_parseDecimal(priceAStr, 8));
        int256 priceBA = int256(_parseDecimal(priceBStr, 8));

        if (priceAB > 0) {
            try priceFeed0.updateAnswer(priceAB) {
                priceUpdates++;
            } catch {}
        }
        if (priceBA > 0) {
            try priceFeed1.updateAnswer(priceBA) {
                priceUpdates++;
            } catch {}
        }

        _executeSwapExact(amountIn, zeroForOne, priceAB, priceBA);
    }

    // Do swaps like in testHook.t.sol using the router helper
    function _executeSwapExact(uint256 amountIn, bool zeroForOne, int256 priceA8, int256 priceB8) internal {
        uint24 currentFee = hookContract.getFee(
            address(this),
            poolKey,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: int256(amountIn), sqrtPriceLimitX96: 0}),
            ""
        );

        // Logs

        uint256 bal0Before = currency0.balanceOf(address(this));
        uint256 bal1Before = currency1.balanceOf(address(this));

        console.log("---------\n amountIn ", amountIn);
        console.log("zeroForOne ", zeroForOne);
        console.log("receiver ", address(this));

        uint256 balance0 = currency0.balanceOf(address(this));
        uint256 balance1 = currency1.balanceOf(address(this));

        console.log("Balance 0: ", balance0, " Balance 1: ", balance1);
        console.log("Liquidity:", poolManager.getPositionLiquidity(poolKey.toId(), bytes32(tokenId)));
        console.log("getLiquidity: ", poolManager.getLiquidity(poolKey.toId()));
        console.log("\n--------");

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

        uint256 feeAmt;
        if (zeroForOne) {
            uint256 actualIn = bal0Before > bal0After ? bal0Before - bal0After : 0;
            feeAmt = (actualIn * currentFee) / 10000;
        } else {
            uint256 actualIn = bal1Before > bal1After ? bal1Before - bal1After : 0;
            feeAmt = (actualIn * currentFee) / 10000;
        }

        // Mint extra tokens to replenish balance (simulate infinite supply for testing)
        if (zeroForOne) {
            MockERC20(address(Currency.unwrap(currency0))).mint(address(this), amountIn * 2); // Mint double the input amount for token0
        } else {
            MockERC20(address(Currency.unwrap(currency1))).mint(address(this), amountIn * 2); // Mint double the input amount for token1
        }

        totalSwaps++;
        totalVolume += amountIn;
        totalFeesCollected += feeAmt;
    }

    // CSV helpers
    function _readCsvLine(string memory csv, uint256 lineNum)
        internal
        pure
        returns (string memory, string memory, string memory, string memory)
    {
        bytes memory data = bytes(csv);

        uint256 currentLine = 0;
        uint256 start = 0;
        for (uint256 i = 0; i < data.length; i++) {
            if (data[i] == "\n") {
                currentLine++;
                if (currentLine == lineNum) {
                    start = i + 1;
                    break;
                }
            }
        }
        if (currentLine != lineNum) return ("", "", "", "");

        string[4] memory fields;
        uint256 field = 0;
        uint256 fieldStart = start;

        for (uint256 i = start; i <= data.length; i++) {
            bool isEnd = i == data.length || data[i] == "\n";
            bool isComma = !isEnd && data[i] == ",";
            if (isComma || isEnd) {
                bytes memory fieldBytes = new bytes(i - fieldStart);
                for (uint256 j = 0; j < fieldBytes.length; j++) {
                    fieldBytes[j] = data[fieldStart + j];
                }
                fields[field] = string(fieldBytes);
                field++;
                fieldStart = i + 1;
                if (isEnd || field == 4) break;
            }
        }

        if (field < 4) return ("", "", "", "");
        return (fields[0], fields[1], fields[2], fields[3]);
    }

    function _parseDecimal(string memory s, uint256 targetDecimals) internal pure returns (uint256) {
        bytes memory b = bytes(s);
        uint256 result = 0;
        uint256 decimals = 0;
        bool hasDecimal = false;

        for (uint256 i = 0; i < b.length; i++) {
            uint8 c = uint8(b[i]);
            if (c == 46) {
                // '.'
                hasDecimal = true;
                continue;
            }
            if (c >= 48 && c <= 57) {
                result = result * 10 + (c - 48);
                if (hasDecimal) decimals++;
            }
        }

        if (decimals < targetDecimals) result *= 10 ** (targetDecimals - decimals);
        else if (decimals > targetDecimals) result /= 10 ** (decimals - targetDecimals);

        return result;
    }

    function _countLines(string memory csv) internal pure returns (uint256) {
        bytes memory b = bytes(csv);
        uint256 count = 1;
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] == "\n") count++;
        }
        return count;
    }

    // Lifetime fees helper (Q128 = 2^128)
    function calculateLifetimeFeesV4(
        uint256 liquidity,
        uint256 feeGrowthInside0Current,
        uint256 feeGrowthInside1Current
    ) public pure returns (uint256 token0LifetimeFees, uint256 token1LifetimeFees) {
        uint256 Q128 = 2 ** 128;
        token0LifetimeFees = (feeGrowthInside0Current * liquidity) / Q128;
        token1LifetimeFees = (feeGrowthInside1Current * liquidity) / Q128;
    }

    function _printSummary(string memory csv) internal view {
        console.log("\n=== SUMMARY ===");
        console.log("Swaps:", totalSwaps);
        console.log("Volume:", totalVolume);
        console.log("Fees:", totalFeesCollected);
        console.log("Price updates:", priceUpdates);
        uint256 n = swapHistory.length;
        uint256 start = n > 6 ? n - 6 : 0;
        for (uint256 i = start; i < n; i++) {
            SwapData memory s = swapHistory[i];
            console.log(
                string.concat(
                    "Swap #",
                    vm.toString(s.swapNumber),
                    " ",
                    s.zeroForOne ? "A->B" : "B->A",
                    " in=",
                    vm.toString(s.amountIn),
                    " fee=",
                    vm.toString(s.feeAmount)
                )
            );
        }

        int24 tickLower = truncateTickSpacing(TickMath.MIN_TICK, tickSpacing);
        int24 tickUpper = truncateTickSpacing(TickMath.MAX_TICK, tickSpacing);

        // Get position liquidity (assuming tokenId is set)
        bytes32 positionId = keccak256(abi.encodePacked(address(this), tickLower, tickUpper));
        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
            poolManager.getFeeGrowthInside(poolId, tickLower, tickUpper);

        uint128 liquidity = poolManager.getLiquidity(poolId);

        uint256 Q128 = 2 ** 128;
        uint256 totalFeesToken0 = (feeGrowthInside0X128 * liquidity) / Q128;
        uint256 totalFeesToken1 = (feeGrowthInside1X128 * liquidity) / Q128;

        // console.log("Liquidity to print: ", feeGrowthInside0X128);

        console.log("Total Fees Gained - Token0:", totalFeesToken0, "Token1:", totalFeesToken1);

        // Get latest prices
        (, int256 ethPrice,,,) = priceFeed0.latestRoundData();
        (, int256 shibPrice,,,) = priceFeed1.latestRoundData();

        uint256 ethPriceUint = uint256(ethPrice);
        uint256 shibPriceUint = uint256(shibPrice);

        // Convert fees to USD
        uint256 usdFeesToken0 = (totalFeesToken0 * ethPriceUint) / (10 ** 26);
        uint256 usdFeesToken1 = (totalFeesToken1 * shibPriceUint) / (10 ** 26);
        uint256 totalFeesUSD = usdFeesToken0 + usdFeesToken1;

        console.log("Total Fees in USD:", totalFeesUSD);

        // Get first prices
        (,, string memory priceAStr, string memory priceBStr) = _readCsvLine(csv, 1);
        uint256 priceAB = _parseDecimal(priceAStr, 8);
        uint256 priceBA = _parseDecimal(priceBStr, 8);

        // Initial amounts and USD values
        uint256 initialToken0 = token0Amount; // 100e18
        uint256 initialToken1 = token1Amount; // 100e18
        uint256 initialUSD0 = (initialToken0 * priceAB) / (10 ** 26);
        uint256 initialUSD1 = (initialToken1 * priceBA) / (10 ** 26);
        uint256 initialTotalUSD = initialUSD0 + initialUSD1;

        console.log("Initial Token0:", initialToken0, "USD:", initialUSD0);
        console.log("Initial Token1:", initialToken1, "USD:", initialUSD1);
        console.log("Initial Total USD:", initialTotalUSD);

        // Final amounts and USD values
        uint128 positionLiquidity = poolManager.getLiquidity(poolId);
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        (uint256 finalToken0, uint256 finalToken1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            positionLiquidity
        );
        uint256 finalUSD0 = (finalToken0 * ethPriceUint) / (10 ** 26);
        uint256 finalUSD1 = (finalToken1 * shibPriceUint) / (10 ** 26);
        uint256 finalTotalUSD = finalUSD0 + finalUSD1;

        console.log("Final Token0:", finalToken0, "USD:", finalUSD0);
        console.log("Final Token1:", finalToken1, "USD:", finalUSD1);
        console.log("Final Total USD:", finalTotalUSD);

        // Calculating the IL
        uint256 holdingValue =
            (initialToken0 * ethPriceUint) / (10 ** 26) + (initialToken1 * shibPriceUint) / (10 ** 26);
        uint256 impermanentLoss = holdingValue > finalTotalUSD ? holdingValue - finalTotalUSD : 0;

        console.log("Holding Value at Final Prices:", holdingValue);
        console.log("LP Value at Final Prices:", finalTotalUSD);
        console.log("Impermanent Loss (USD):", impermanentLoss);

        int256 effectiveIL = int256(impermanentLoss) - int256(totalFeesUSD);
        console.log("Effective Impermanent Loss (after fees):", effectiveIL);
        if (effectiveIL <= 0) {
            console.log("Gain from fees covering IL:", uint256(-effectiveIL));
        } else {
            console.log("Net Loss:", uint256(effectiveIL));
        }

        console.log("=== END ===\n");
    }
}
