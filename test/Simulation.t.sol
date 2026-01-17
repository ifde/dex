// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {MockV3Aggregator} from "@chainlink/local/src/data-feeds/MockV3Aggregator.sol";
import {AggregatorV2V3Interface} from "@chainlink/local/src/data-feeds/interfaces/AggregatorV2V3Interface.sol";

import {HookTest} from "./utils/HookTest.sol";
import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

contract SimulateTradesTest is Test, HookTest {
    using EasyPosm for IPositionManager;
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
        uint256 amountOut;
        uint256 feeAmount;
        uint24 feeRate;
        bool zeroForOne;
        int256 priceA;
        int256 priceB;
    }

    SwapData[] public swapHistory;

    uint256 internal constant MAX_TRADES = 500; // cap to stay within gas

    function setUp() public {
        deployArtifactsAndLabel();
        deployCurrencyPair();
    }

    function testSimulateTradesFromJSON() public {
        deployHookAndFeeds("BAHook");
        deployPool();

        console.log("\n=== Starting Trade Simulation ===");
        console.log("Hook:", address(hookContract));
        console.logBytes32(PoolId.unwrap(poolKey.toId()));
        console.log("Token0:", Currency.unwrap(poolKey.currency0));
        console.log("Token1:", Currency.unwrap(poolKey.currency1));

        string memory path = string.concat(vm.projectRoot(), "/trades_processed.csv");
        string memory csv = vm.readFile(path);
        console.log("Reading trades from:", path);

        _simulateTrades(csv);
        _printSummary();
    }

    function _simulateTrades(string memory csv) internal {
        uint256 lines = _countLines(csv);
        if (lines <= 1) return; // only header
        uint256 tradeLines = lines - 1;
        uint256 maxTrades = tradeLines > MAX_TRADES ? MAX_TRADES : tradeLines;

        for (uint256 i = 1; i <= maxTrades; i++) {
            _processTradeLineCSV(csv, i);
            if (i % 100 == 0) console.log("Processed", i, "trades...");
            vm.roll(block.number + 1);
        }
    }

    function _processTradeLineCSV(string memory csv, uint256 lineNum) internal {
        // line format: direction,amount_in,price_a_usd,price_b_usd
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
        if (currentLine != lineNum) return;

        string memory direction;
        uint256 amountIn;
        int256 priceA;
        int256 priceB;

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
                string memory val = string(fieldBytes);

                if (field == 0) {
                    direction = val;
                } else if (field == 1) {
                    amountIn = _stringToUint(val);
                } else if (field == 2) {
                    priceA = int256(_stringToUint(val));
                } else if (field == 3) {
                    priceB = int256(_stringToUint(val));
                }

                field++;
                fieldStart = i + 1;
                if (isEnd) break;
            }
        }

        if (bytes(direction).length == 0 || amountIn == 0) return;
        bool zeroForOne = keccak256(bytes(direction)) == keccak256(bytes("A_TO_B"));

        // update price feeds (Chainlink 8 decimals -> multiply by 1e6 since prices have 2 decimals)
        if (priceA > 0) {
            int256 clA = priceA * int256(1e10);
            try priceFeed0.updateAnswer(clA) {
                priceUpdates++;
            } catch {}
        }
        if (priceB > 0) {
            int256 clB = priceB * int256(1e10);
            try priceFeed1.updateAnswer(clB) {
                priceUpdates++;
            } catch {}
        }

        _executeSwap(amountIn, zeroForOne, priceA, priceB);
    }

    function _stringToUint(string memory s) internal pure returns (uint256) {
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

        if (decimals < 18) result *= 10 ** (18 - decimals);
        else if (decimals > 18) result /= 10 ** (decimals - 18);

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

    function _executeSwap(uint256 amountIn, bool zeroForOne, int256 priceA, int256 priceB) internal {
        uint24 currentFee;
        try hookContract.getFee(
            address(this),
            poolKey,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: int256(amountIn), sqrtPriceLimitX96: 0}),
            ""
        ) returns (
            uint24 fee
        ) {
            currentFee = fee;
        } catch {
            currentFee = 3000; // 0.3%
        }

        uint256 bal0Before = currency0.balanceOf(address(this));
        uint256 bal1Before = currency1.balanceOf(address(this));

        try swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        }) returns (
            BalanceDelta
        ) {
            uint256 bal0After = currency0.balanceOf(address(this));
            uint256 bal1After = currency1.balanceOf(address(this));

            uint256 amountOut;
            uint256 feeAmt;
            if (zeroForOne) {
                uint256 actualIn = bal0Before - bal0After;
                amountOut = bal1After - bal1Before;
                feeAmt = (actualIn * currentFee) / 1_000_000;
            } else {
                uint256 actualIn = bal1Before - bal1After;
                amountOut = bal0After - bal0Before;
                feeAmt = (actualIn * currentFee) / 1_000_000;
            }

            totalSwaps++;
            totalVolume += amountIn;
            totalFeesCollected += feeAmt;

            swapHistory.push(
                SwapData({
                    swapNumber: totalSwaps,
                    amountIn: amountIn,
                    amountOut: amountOut,
                    feeAmount: feeAmt,
                    feeRate: currentFee,
                    zeroForOne: zeroForOne,
                    priceA: priceA,
                    priceB: priceB
                })
            );
        } catch Error(string memory reason) {
            console.log("Swap failed:", reason);
        } catch {
            console.log("Swap failed: unknown error");
        }
    }

    function _printSummary() internal view {
        console.log("\n=== SIMULATION SUMMARY ===");
        console.log("Total swaps:", totalSwaps);
        console.log("Total volume:", totalVolume);
        console.log("Total fees:", totalFeesCollected);
        console.log("Price updates:", priceUpdates);
        if (totalSwaps > 0) {
            console.log("Avg fee:", totalFeesCollected / totalSwaps);
            console.log("Avg volume:", totalVolume / totalSwaps);
        }
        uint256 start = swapHistory.length > 10 ? swapHistory.length - 10 : 0;
        for (uint256 i = start; i < swapHistory.length; i++) {
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
        console.log("=== END SUMMARY ===\n");
    }

    function getTotalFeesFromPool() public view returns (uint256 fee0, uint256 fee1) {
        return (totalFeesCollected, 0);
    }
}
