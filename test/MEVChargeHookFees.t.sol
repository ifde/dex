// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "lib/v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "lib/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId} from "lib/v4-core/src/types/PoolId.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {StateLibrary} from "lib/v4-core/src/libraries/StateLibrary.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {console} from "forge-std/console.sol";

import {Test} from "forge-std/Test.sol";

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IPoolManager, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {MockV3Aggregator} from "@chainlink/local/src/data-feeds/MockV3Aggregator.sol";
import {AggregatorV2V3Interface} from "@chainlink/local/src/data-feeds/interfaces/AggregatorV2V3Interface.sol";

import {BaseScript} from "../script/base/BaseScript.sol";
import {LiquidityHelpers} from "../script/base/LiquidityHelpers.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";

import {CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {HookTest} from "./utils/HookTest.sol";

/**
 * @title MEVChargeHookFeesTest
 * @notice Donation and impact-fee behavior tests.
 */
contract MEVChargeHookFeesTest is HookTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    event FeeSettled(PoolId indexed poolId, address indexed payer, uint256 amountSettled);

    function setUp() public {
        deployArtifactsAndLabel();

        deployCurrencyPair();

        deployHookAndFeeds("MEVChargeHook");

        deployPool();
    }

    function test_NormalPurchase() public {
        positionManager.increaseLiquidity(
            tokenId, 1e18, token0Amount + 1, token1Amount + 1, block.timestamp, Constants.ZERO_BYTES
        );
        positionManager.increaseLiquidity(
            noHookTokenId, 1e18, token0Amount + 1, token1Amount + 1, block.timestamp, Constants.ZERO_BYTES
        );

        MockERC20(Currency.unwrap(currency0)).mint(address(this), 1e20);
        MockERC20(Currency.unwrap(currency1)).mint(address(this), 1e20);

        vm.warp(block.timestamp + hookContract.cooldownSeconds() + 1);
        uint160 sqrtPriceLimit = uint160((uint256(Constants.SQRT_PRICE_1_1) * 1005) / 1000);

        bytes memory hookData = "";
        BalanceDelta swapResultHook = swapRouter.swap({
            amountSpecified: 1e16,
            amountLimit: token1Amount,
            zeroForOne: false,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
        BalanceDelta swapResultNoHook = swapRouter.swap({
            amountSpecified: 1e16,
            amountLimit: token1Amount,
            zeroForOne: false,
            poolKey: noHookKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        console.log("Hook Swap Amount 1: ", BalanceDeltaLibrary.amount0(swapResultHook));
        assertEq(BalanceDeltaLibrary.amount0(swapResultHook), BalanceDeltaLibrary.amount0(swapResultNoHook));
        assertEq(BalanceDeltaLibrary.amount1(swapResultHook), BalanceDeltaLibrary.amount1(swapResultNoHook));
    }
}
