pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {MockV3Aggregator} from "@chainlink/local/src/data-feeds/MockV3Aggregator.sol";
import {AggregatorV2V3Interface} from "@chainlink/local/src/data-feeds/interfaces/AggregatorV2V3Interface.sol";

import {LiquidityHelpers} from "./base/LiquidityHelpers.sol";
import {HookHelpers} from "./base/HookHelpers.sol";
import {BaseScript} from "./base/BaseScript.sol";

contract DeployHookAndCreatePool is BaseScript, HookHelpers, LiquidityHelpers {
    PoolKey poolKey;
    uint256 tokenId;
    PoolId poolId;

    /////////////////////////////////////
    // --- Configure These ---
    /////////////////////////////////////

    int24 tickSpacing = 60;
    uint160 startingPrice = Constants.SQRT_PRICE_1_1;

    // --- liquidity position configuration --- //
    uint256 public token0Amount = 100e18;
    uint256 public token1Amount = 100e18;

    function run(
        string memory hookName,
        string memory feed0,
        string memory feed1,
        string memory tokenStr0,
        string memory tokenStr1
    ) external {
        // deploy a hook
        deployHook(hookName, feed0, feed1);

        // -------------

        // Use token addresses if provided
        address token0Addr = stringToAddress(tokenStr0);
        address token1Addr = stringToAddress(tokenStr1);

        if (token0Addr != address(0)) {
            token0 = IERC20(token0Addr);
        }

        if (token1Addr != address(0)) {
            token1 = IERC20(token1Addr);
        }

        // -------------

        // Create the pool with DYNAMIC FEE
        (currency0, currency1) = getCurrencies();
        poolKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing, IHooks(hookContract));
        poolId = poolKey.toId();

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
    }
}
