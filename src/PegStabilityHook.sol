// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console} from "forge-std/console.sol";

import {Currency} from "v4-core/src/types/Currency.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {BaseOverrideFee} from "@openzeppelin/uniswap-hooks/src/fee/BaseOverrideFee.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {AggregatorV2V3Interface} from "@chainlink/local/src/data-feeds/interfaces/AggregatorV2V3Interface.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title PegStabilityHook
/// @notice A hook to keep DEX price B above CEX price B (pegging token B)
/// Idea: if token B is bought from the pool (so its price increases) or DEX price B is already more than CEX price B
/// Then we stimulate swaps by keeping the minimum fee
/// On the other hand, Fee = percentage difference between Pool Price and CEX Price
contract PegStabilityHook is BaseOverrideFee, Ownable {
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;

    IPoolManager private immutable _poolManager;

    // Price feeds
    AggregatorV2V3Interface private immutable _token0UsdtFeed;
    AggregatorV2V3Interface private immutable _token1UsdtFeed;

    // token B / token A exchange rate
    uint256 private exchangeRate = 0;

    // Constants
    uint24 public MAX_FEE_BPS = 10_000; // 1% max fee allowed, 1% = 10_000
    uint24 public MIN_FEE_BPS = 100; // 0.01% mix fee allowed

    // Errors
    // @dev error when Invalid zero input params
    error InvalidZeroInput();

    /// @dev Error when custom max fee overflow
    error InvalidMaxFee();

    /// @dev Error when min fee overflow
    error InvalidMinFee();

    /// @dev Error when Invalid Currency in Pool
    error InvalidPoolCurrency();

    constructor(
        IPoolManager poolManager,
        AggregatorV2V3Interface token0UsdtFeed,
        AggregatorV2V3Interface token1UsdtFeed
    ) BaseOverrideFee() Ownable(msg.sender) {
        _poolManager = poolManager;
        _token0UsdtFeed = token0UsdtFeed;
        _token1UsdtFeed = token1UsdtFeed;
    }

    function poolManager() public view override returns (IPoolManager) {
        return _poolManager;
    }

    function setExchangeRate(uint256 rate) external onlyOwner {
        exchangeRate = rate;
    }

    function setFee(uint24 _fee, PoolKey calldata key) external onlyOwner {
        MAX_FEE_BPS = _fee;
    }

    function setMinFee(uint24 _fee, PoolKey calldata key) external onlyOwner {
        MIN_FEE_BPS = _fee;
    }

    function getFee(address caller, PoolKey calldata key, SwapParams calldata params, bytes calldata data)
        external
        returns (uint24)
    {
        return _getFee(caller, key, params, data);
    }

    function _getFee(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        virtual
        override
        returns (uint24)
    {
        (uint160 sqrtPriceX96,,,) = _poolManager.getSlot0(key.toId());
        return _calculateFee(key.currency0, key.currency1, params.zeroForOne, sqrtPriceX96, _getSqrtPriceRatioX96());
    }

    // Helper to get current token0/token1 price ratio from feeds
    function _getSqrtPriceRatioX96() private view returns (uint160) {
        if (exchangeRate != 0) {
            return uint160(FixedPointMathLib.sqrt(exchangeRate) * (2 ** 96) / 1e9);
        }

        (, int256 token0Price,,,) = _token0UsdtFeed.latestRoundData();
        (, int256 token1Price,,,) = _token1UsdtFeed.latestRoundData();
        require(token0Price > 0 && token1Price > 0, "Invalid price data");
        // Ratio = (token0/USD) / (token1/USD), scaled by 1e18 for precision
        uint256 ratioWad = uint256(token1Price * 1e18 / token0Price);

        uint160 result = uint160(FixedPointMathLib.sqrt(ratioWad) * uint256(2 ** 96) / uint256(1e9));

        console.log("PegStabilityHook. SQRT X96 Price Ratio: ", result);

        return result;
    }

    /// @dev

    /**
     * @notice  Calculates the price for a swap
     * @dev     Fee = percentage difference between pool price and reference price
     *          i.e. if pool price is off by 0.05% the fee is 0.05%
     * @param   zeroForOne  True if buying token B, false if selling token B
     * @param   poolSqrtPriceX96  Current pool price
     * @param   referenceSqrtPriceX96  Reference price obtained from the rate provider
     * @return  uint24  Fee charged to the user - fee in pips, i.e. 3000 = 0.3%
     */
    function _calculateFee(
        Currency,
        Currency,
        bool zeroForOne,
        uint160 poolSqrtPriceX96,
        uint160 referenceSqrtPriceX96
    ) internal view returns (uint24) {
        // Pool price of token B is greater than CEX price of token B (which is the same is DEX price A < CEX price A)
        // OR we buy token B so its price increases
        if (zeroForOne || poolSqrtPriceX96 < referenceSqrtPriceX96) {
            return MIN_FEE_BPS; // minFee bip
        }

        // computes the absolute percentage difference between the pool price and the reference price
        // i.e. 0.005e18 = 0.50% difference between pool price and reference price
        uint256 absPercentageDiffWad = absPercentageDifferenceWad(uint160(poolSqrtPriceX96), referenceSqrtPriceX96);

        // console.log("PegStabilityHook. absPercentageDiffWad: ", absPercentageDiffWad);

        // convert percentage WAD to pips, i.e. 0.05e18 = 5% = 50_000
        uint24 fee = uint24(absPercentageDiffWad / 1e12);
        if (fee < MIN_FEE_BPS) {
            // if % depeg is less than min fee %. charge minFee
            fee = MIN_FEE_BPS;
        } else if (fee > MAX_FEE_BPS) {
            // if % depeg is more than max fee %. charge maxFee
            fee = MAX_FEE_BPS;
        }
        return fee;
    }

    /// @notice Calculates the absolute percentage difference between two sqrt prices in WAD units
    /// @dev 0.05e18 = 5%, for 95 vs 100 or 105 vs 100
    /// @param sqrtPriceX96 sqrt(p) * 2 ^ 96
    /// @param denominatorX96 sqrt(d) * 2 ^ 96
    /// @return The percentage difference in WAD units
    function absPercentageDifferenceWad(uint160 sqrtPriceX96, uint160 denominatorX96) internal pure returns (uint256) {
        uint160 Q96 = 2 ** 96;
        uint256 Q192 = 2 ** 192;
        // Calculate sqrt(p / d) * 2 ^ 96
        uint256 _divX96 = (uint256(sqrtPriceX96) * uint256(Q96)) / uint256(denominatorX96);

        // console.log("PegStabilityHook. _divX96 = ", _divX96);

        // convert to WAD
        uint256 _percentageDiffWad = Math.mulDiv(_divX96 ** 2, 1e18, Q192);
        // console.log("PegStabilityHook. _percentageDiffWad = ", _percentageDiffWad);
        return (1e18 < _percentageDiffWad) ? _percentageDiffWad - 1e18 : 1e18 - _percentageDiffWad;
    }
}
