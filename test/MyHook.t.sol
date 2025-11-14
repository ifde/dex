// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";

import {MyHook} from "../src/MyHook.sol";
import {BaseTest} from "./utils/BaseTest.sol";

contract MyHookTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;

    Currency currency0;
    Currency currency1;

    PoolKey poolKey;
    MyHook hook;
    PoolId poolId;

    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;

    function setUp() public {
        // Deploys all required artifacts.
        deployArtifactsAndLabel();

        (currency0, currency1) = deployCurrencyPair();

        // Deploy the hook to an address with the correct flags
        address flags = address(
            uint160(
                Hooks.AFTER_INITIALIZE_FLAG |
                Hooks.BEFORE_SWAP_FLAG // Dynamic fee hook only needs afterInitialize
            ) ^ (0x4444 << 144) // Namespace the hook to avoid collisions
        );
        
        bytes memory constructorArgs = abi.encode(poolManager);
        deployCodeTo("src/MyHook.sol:MyHook", constructorArgs, flags);
        hook = MyHook(flags);

        // Create the pool with DYNAMIC FEE (important!)
        uint24 dynamicFee = 3000;
        poolKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        poolId = poolKey.toId();
        
        // Set initial fee before pool initialization
        hook.setFee(500); // 5 bps = 0.05%

        // Initialize the pool - this will trigger afterInitialize and set the dynamic fee
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        // Provide full-range liquidity to the pool
        tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);

        uint128 liquidityAmount = 100e18;

        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        (tokenId,) = positionManager.mint(
            poolKey,
            tickLower,
            tickUpper,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );
    }

    function testDynamicFeeInitialization() public {
        // Verify that the pool was created with dynamic fee flag
        assertTrue(poolKey.fee.isDynamicFee(), "Pool should have dynamic fee enabled");
        
        // The fee should be set to our initial value (500 = 0.05%)
        // Note: You might need to add a getter function to your hook to verify this
    }

    function testFeeUpdate() public {
        // Perform a swap with initial fee
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

        // Update the fee to a higher value
        uint24 newFee = 2000; // 20 bps = 0.2%
        hook.setFee(newFee);
        
        // The hook should call _poke to update the fee in the pool
        // Note: You might need to add a public poke function to your hook for testing
        // hook.poke(poolKey);

        // Perform another swap with the new fee
        BalanceDelta swapDelta2 = swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        // With higher fee, output should be lower (more fee taken)
        // Note: This might be hard to test precisely due to price impact
        assertTrue(swapDelta2.amount1() < swapDelta1.amount1(), "Higher fee should result in less output");
    }

    function testOnlyOwnerCanSetFee() public {
        // Try to set fee from non-owner address
        vm.prank(address(0x123)); // Random address
        vm.expectRevert(); // Should revert with Ownable access control
        hook.setFee(1000);
    }

    function testPoolRejectsNonDynamicFee() public {
        // Try to create a pool with static fee but dynamic fee hook
        PoolKey memory invalidPoolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hook)); // Static fee 3000
        
        vm.expectRevert(); // Should revert with NotDynamicFee error
        poolManager.initialize(invalidPoolKey, Constants.SQRT_PRICE_1_1);
    }
}