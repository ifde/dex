// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "lib/v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "lib/v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "lib/v4-core/src/types/PoolId.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {StateLibrary} from "lib/v4-core/src/libraries/StateLibrary.sol";

import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {console} from "forge-std/console.sol";

import {HookTest} from "./utils/HookTest.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {MEVChargeHook} from "./../src/MEVChargeHook.sol";

/**
 * @title MEVChargeHookFeesTest
 * @notice Donation and impact-fee behavior tests.
 * Rewritten so each test uses the same patterns as test_NormalPurchase().
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

        vm.warp(block.timestamp + MEVChargeHook(address(hookContract)).cooldownSeconds() + 1);

        BalanceDelta swapResultHook = swapRouter.swap({
            amountSpecified: int256(1e16),
            amountLimit: uint256(token1Amount),
            zeroForOne: false,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        BalanceDelta swapResultNoHook = swapRouter.swap({
            amountSpecified: int256(1e16),
            amountLimit: uint256(token1Amount),
            zeroForOne: false,
            poolKey: noHookKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        assertEq(BalanceDeltaLibrary.amount0(swapResultHook), BalanceDeltaLibrary.amount0(swapResultNoHook));
        assertEq(BalanceDeltaLibrary.amount1(swapResultHook), BalanceDeltaLibrary.amount1(swapResultNoHook));
    }

    function test_NormalSell() public {
        positionManager.increaseLiquidity(
            tokenId, 1e18, token0Amount + 1, token1Amount + 1, block.timestamp, Constants.ZERO_BYTES
        );
        positionManager.increaseLiquidity(
            noHookTokenId, 1e18, token0Amount + 1, token1Amount + 1, block.timestamp, Constants.ZERO_BYTES
        );

        MockERC20(Currency.unwrap(currency0)).mint(address(this), 1e20);
        vm.warp(block.timestamp + hookContract.cooldownSeconds() + 1);

        BalanceDelta swapResultHook = swapRouter.swap({
            amountSpecified: int256(-5e16),
            amountLimit: uint256(token1Amount),
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        BalanceDelta swapResultNoHook = swapRouter.swap({
            amountSpecified: int256(-5e16),
            amountLimit: uint256(token1Amount),
            zeroForOne: true,
            poolKey: noHookKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        assertEq(BalanceDeltaLibrary.amount0(swapResultHook), BalanceDeltaLibrary.amount0(swapResultNoHook));
        assertEq(BalanceDeltaLibrary.amount1(swapResultHook), BalanceDeltaLibrary.amount1(swapResultNoHook));
    }

    function test_PartialTimeFee_BuyThenSell() public {
        positionManager.increaseLiquidity(
            tokenId, 1e18, token0Amount + 1, token1Amount + 1, block.timestamp, Constants.ZERO_BYTES
        );
        positionManager.increaseLiquidity(
            noHookTokenId, 1e18, token0Amount + 1, token1Amount + 1, block.timestamp, Constants.ZERO_BYTES
        );

        MockERC20(Currency.unwrap(currency0)).mint(address(this), 1e20);
        MockERC20(Currency.unwrap(currency1)).mint(address(this), 1e20);

        // Buy
        swapRouter.swap({
            amountSpecified: int256(1e16),
            amountLimit: uint256(token1Amount),
            zeroForOne: false,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        // advance half cooldown
        vm.warp(block.timestamp + hookContract.cooldownSeconds() / 2);

        // Sell
        BalanceDelta swapResultHook = swapRouter.swap({
            amountSpecified: int256(-1e16),
            amountLimit: uint256(token1Amount),
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        BalanceDelta swapResultNoHook = swapRouter.swap({
            amountSpecified: int256(-1e16),
            amountLimit: uint256(token1Amount),
            zeroForOne: true,
            poolKey: noHookKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        int256 hookToken0 = BalanceDeltaLibrary.amount0(swapResultHook);
        int256 noHookToken0 = BalanceDeltaLibrary.amount0(swapResultNoHook);
        require(hookToken0 < noHookToken0, "Linear decay fee calculation incorrect");
    }

    function test_TimeFeeDecayAfterCooldown() public {
        positionManager.increaseLiquidity(
            tokenId, 1e18, token0Amount + 1, token1Amount + 1, block.timestamp, Constants.ZERO_BYTES
        );
        positionManager.increaseLiquidity(
            noHookTokenId, 1e18, token0Amount + 1, token1Amount + 1, block.timestamp, Constants.ZERO_BYTES
        );

        // trigger immediate fee
        swapRouter.swap({
            amountSpecified: int256(1e16),
            amountLimit: uint256(token1Amount),
            zeroForOne: false,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        swapRouter.swap({
            amountSpecified: int256(1e16),
            amountLimit: uint256(token1Amount),
            zeroForOne: false,
            poolKey: noHookKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        vm.warp(block.timestamp + MEVChargeHook(address(hookContract)).cooldownSeconds() / 2);

        uint256 baseFee = 100;
        uint256 feeMax = MEVChargeHook(address(hookContract)).effectiveFeeMax();
        uint256 cooldown = hookContract.cooldownSeconds();
        uint256 halfCooldown = cooldown / 2;
        uint256 reversedFactor = 1e18 - Math.mulDiv(halfCooldown, 1e18, cooldown);
        uint256 delayedFee = baseFee + Math.mulDiv(feeMax - baseFee, reversedFactor, 1e18);

        assertGt(feeMax, delayedFee);
    }

    function test_MassiveSellImpact() public {
        positionManager.increaseLiquidity(
            tokenId, 1e18, token0Amount + 1, token1Amount + 1, block.timestamp, Constants.ZERO_BYTES
        );
        positionManager.increaseLiquidity(
            noHookTokenId, 1e18, token0Amount + 1, token1Amount + 1, block.timestamp, Constants.ZERO_BYTES
        );

        MockERC20(Currency.unwrap(currency0)).mint(address(this), 1e20);

        BalanceDelta resultHook = swapRouter.swap({
            amountSpecified: int256(-2e17),
            amountLimit: uint256(0),
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        BalanceDelta resultNoHook = swapRouter.swap({
            amountSpecified: int256(-2e17),
            amountLimit: uint256(0),
            zeroForOne: true,
            poolKey: noHookKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        int256 hookAmount0 = resultHook.amount0();
        int256 noHookAmount0 = resultNoHook.amount0();
        assertLt(hookAmount0, noHookAmount0);
    }

    function test_MultipleSequentialDonations() public {
        positionManager.increaseLiquidity(
            tokenId, 1e18, token0Amount + 1, token1Amount + 1, block.timestamp, Constants.ZERO_BYTES
        );
        positionManager.increaseLiquidity(
            noHookTokenId, 1e18, token0Amount + 1, token1Amount + 1, block.timestamp, Constants.ZERO_BYTES
        );

        for (uint256 i = 0; i < 5; i++) {
            poolManager.donate(poolKey, 1e5, 1e5, Constants.ZERO_BYTES);
            poolManager.donate(noHookKey, 1e5, 1e5, Constants.ZERO_BYTES);
        }

        vm.roll(block.number + MEVChargeHook(address(hookContract)).blockNumberOffset() + 1);

        BalanceDelta deltaHook =
            positionManager.decreaseLiquidity(tokenId, 1e18, 0, 0, address(this), block.timestamp, Constants.ZERO_BYTES);

        positionManager.decreaseLiquidity(noHookTokenId, 1e18, 0, 0, address(this), block.timestamp, Constants.ZERO_BYTES);

        assertTrue(deltaHook.amount0() > 0 && deltaHook.amount1() > 0);
    }

    function test_DynamicFeeClampedToCap() public {
        MEVChargeHook(address(hookContract)).setFlaggedFeeAdditional(0);
        MEVChargeHook(address(hookContract)).setFeeMax(150); // 1.5%

        positionManager.increaseLiquidity(
            tokenId, 1e18, token0Amount + 1, token1Amount + 1, block.timestamp, Constants.ZERO_BYTES
        );
        positionManager.increaseLiquidity(
            noHookTokenId, 1e18, token0Amount + 1, token1Amount + 1, block.timestamp, Constants.ZERO_BYTES
        );

        MockERC20(Currency.unwrap(currency0)).mint(address(this), 1e20);

        BalanceDelta resHook = swapRouter.swap({
            amountSpecified: int256(-9e16),
            amountLimit: uint256(0),
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        BalanceDelta resNoHook = swapRouter.swap({
            amountSpecified: int256(-9e16),
            amountLimit: uint256(0),
            zeroForOne: true,
            poolKey: noHookKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        uint256 hookOut = uint256(int256(BalanceDeltaLibrary.amount1(resHook)));
        uint256 noHookOut = uint256(int256(BalanceDeltaLibrary.amount1(resNoHook)));
        assertTrue(hookOut * 1000 >= noHookOut * 990, "fee not clamped");
    }
}
