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
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {console} from "forge-std/console.sol";
import {Vm, VmSafe} from "forge-std/vm.sol";

import {HookTest} from "./utils/HookTest.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

import {PegStabilityHook} from "./../src/PegStabilityHook.sol";

/**
 * @title PegStability Hook tests
 */
contract PegStabilityHookTest is HookTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    PegStabilityHook pegHook;
    uint256 exchangeRate = 955359601782882392;
    uint24 maxFee = 10_000; // 1%
    uint24 minFee = 100; // 0.01%

    VmSafe vmSafe = VmSafe(VM_ADDRESS);

    function setUp() public {
        deployArtifactsAndLabel();
        deployPoolDonateTest(); // used as a helper to donate currencies
        deployCurrencyPair();
        deployHookAndFeeds("PegStabilityHook");
        pegHook = PegStabilityHook(address(hookContract));
        pegHook.setExchangeRate(exchangeRate);
        console.log("PegStabilityHook deloyed to: ", vm.toString(address(pegHook)));
        deployPool();
        console.log("PegStabilityHook liquidity before increase of Liquidity: ", positionManager.getPositionLiquidity(tokenId));
        positionManager.increaseLiquidity(
            tokenId, 9_900e18, 2 ** 100, 2 ** 100, block.timestamp, Constants.ZERO_BYTES
        );
        console.log("PegStabilityHook liquidity after increase of Liquidity: ", positionManager.getPositionLiquidity(tokenId));
    }

    // helper
    function getSwapFeeFromEvent(VmSafe.Log[] memory recordedLogs) internal pure returns (uint24 fee) {
          bytes32 SWAP_EVENT_SIGNATURE =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
        for (uint256 i; i < recordedLogs.length; i++) {
            if (recordedLogs[i].topics[0] == SWAP_EVENT_SIGNATURE) {
                (,,,,, fee) = abi.decode(recordedLogs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                break;
            }
        }
    }

    // helper
    function assertSwapFee(VmSafe.Log[] memory recordedLogs, uint24 expectedFee) internal pure {
        vm.assertEq(getSwapFeeFromEvent(recordedLogs), expectedFee);
    }

    function test_fuzz_swap(bool zeroForOne, bool exactIn) public {
        int256 amountSpecified = exactIn ? -int256(1e18) : int256(1e18);
        uint256 msgValue = zeroForOne ? 2e18 : 0;

        BalanceDelta result = swapRouter.swap({
            amountSpecified: amountSpecified,
            amountLimit: amountSpecified < 0 ? 0 : 2 ** 255,
            zeroForOne: zeroForOne,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        if (zeroForOne) {
            exactIn
                ? assertEq(int256(result.amount0()), amountSpecified)
                : assertLt(int256(result.amount0()), amountSpecified);
            exactIn
                ? assertGt(int256(result.amount1()), 0)
                : assertEq(int256(result.amount1()), amountSpecified);
        } else {
            exactIn
                ? assertEq(int256(result.amount1()), amountSpecified)
                : assertLt(int256(result.amount1()), amountSpecified);
            exactIn
                ? assertGt(int256(result.amount0()), 0)
                : assertEq(int256(result.amount0()), amountSpecified);
        }
    }

    /// @dev swaps moving away from peg are charged a high fee
    function test_fuzz_high_fee(bool zeroForOne) public {
        vm.recordLogs();
        BalanceDelta ref = swapRouter.swap({
            amountSpecified: -int256(0.1e18),
            amountLimit: 0,
            zeroForOne: zeroForOne,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        VmSafe.Log[] memory recordedLogs = vmSafe.getRecordedLogs();
        // assertSwapFee(recordedLogs, minFee);

        // move the pool price to off peg
        swapRouter.swap({
            amountSpecified: -int256(1000e18),
            amountLimit: 0,
            zeroForOne: zeroForOne,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        // move the pool price away from peg
        vm.recordLogs();
        BalanceDelta highFeeSwap = swapRouter.swap({
            amountSpecified: -int256(0.1e18),
            amountLimit: 0,
            zeroForOne: zeroForOne,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        recordedLogs = vmSafe.getRecordedLogs();
        assertSwapFee(recordedLogs, zeroForOne ? minFee : maxFee);

        // output of the second swap is much less
        // highFeeSwap + offset < ref
        zeroForOne
            ? assertLt(highFeeSwap.amount1() + int128(0.001e18), ref.amount1())
            : assertLt(highFeeSwap.amount0() + int128(0.001e18), ref.amount0());
    }

    /// @dev swaps moving towards peg are charged a low fee
    function test_fuzz_low_fee(bool zeroForOne) public {
        // move the pool price to off peg
        swapRouter.swap({
            amountSpecified: -int256(1000e18),
            amountLimit: 0,
            zeroForOne: !zeroForOne,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        // move the pool price away from peg
        vm.recordLogs();
         BalanceDelta highFeeSwap = swapRouter.swap({
            amountSpecified: -int256(0.1e18),
            amountLimit: 0,
            zeroForOne: !zeroForOne,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
        VmSafe.Log[] memory recordedLogs = vmSafe.getRecordedLogs();
        uint24 higherFee = getSwapFeeFromEvent(recordedLogs);

        // swap towards the peg
        vm.recordLogs();
          BalanceDelta lowFeeSwap = swapRouter.swap({
            amountSpecified: -int256(0.1e18),
            amountLimit: 0,
            zeroForOne: zeroForOne,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        recordedLogs = vmSafe.getRecordedLogs();
        uint24 lowerFee = getSwapFeeFromEvent(recordedLogs);
        if (zeroForOne) {
            assertGt(higherFee, lowerFee);
            assertEq(lowerFee, minFee); // minFee
        } else {
            assertEq(lowerFee, minFee); // minFee
            assertEq(higherFee, minFee); // minFee
        }

        // output of the second swap is much higher
        // lowFeeSwap > highFeeSwap
        zeroForOne
            ? assertGt(lowFeeSwap.amount1(), highFeeSwap.amount1())
            : assertGt(lowFeeSwap.amount0(), highFeeSwap.amount0());
    }

    function test_fuzz_linear_fee(uint256 amount) public {
        vm.assume(0.5e18 < amount && amount <= 48.75e18);
        // move the pool price to off peg
                swapRouter.swap({
            amountSpecified: -int256(amount),
            amountLimit: 0,
            zeroForOne: false,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        (uint160 poolSqrtPriceX96, , , ) = poolManager.getSlot0(poolKey.toId());
        
        ///
        // AbsPrecentageDiffWad calculation
        ///

        uint160 Q96 = 2 ** 96;
        uint256 Q192 = 2 ** 192;
        uint256 _divX96 = (uint256(poolSqrtPriceX96) * uint256(Q96)) / uint256(uint160(FixedPointMathLib.sqrt(exchangeRate) * (2 ** 96) / 1e9));


        uint256 _percentageDiffWad = ((_divX96 ** 2) * 1e18) / Q192;
        uint256 absPercentageDiffWad = (1e18 < _percentageDiffWad) ? _percentageDiffWad - 1e18 : 1e18 - _percentageDiffWad;

        ///
        //
        ///

        uint24 expectedFee = uint24(absPercentageDiffWad / 1e12);
        if (expectedFee < minFee) {
            // if % depeg is less than min fee %. charge minFee
            expectedFee = minFee;
        } else if (expectedFee > maxFee) {
            // if % depeg is more than max fee %. charge maxFee
            expectedFee = maxFee;
        }
        // move the pool price away from peg
        vm.recordLogs();
                  swapRouter.swap({
            amountSpecified: -int256(0.1e18),
            amountLimit: 0,
            zeroForOne: false,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
        VmSafe.Log[] memory recordedLogs = vmSafe.getRecordedLogs();
        uint24 swapFee = getSwapFeeFromEvent(recordedLogs);
        assertEq(swapFee, expectedFee);
    }
}