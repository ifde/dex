// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseOverrideFee} from "@openzeppelin/uniswap-hooks/src/fee/BaseOverrideFee.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

/**
 * @dev A hook implementing Block Adaptive (BA) dynamic fees.
 * - Starts with 30 bps for both directions.
 * - At the end of each block, if price_A / price_B decreased, increase fA→B by 5 bps and decrease fB→A by 5 bps.
 * - Fees are overridden per swap based on direction.
 */
contract BAHook is BaseOverrideFee {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;

    // Constants
    uint24 private constant INITIAL_FEE = 3000; // 30 bps
    uint24 private constant FSTEP = 500; // 5 bps
    uint24 private constant MAX_FEE = 10000; // Cap at 100 bps to prevent excessive fees

    // State per pool
    mapping(PoolId => uint24) public feeAB; // Fee for A → B (zeroForOne = true)
    mapping(PoolId => uint24) public feeBA; // Fee for B → A (zeroForOne = false)
    mapping(PoolId => uint160) public lastSqrtPrice; // Last sqrt price at block start
    mapping(PoolId => uint256) public lastBlock; // Last block number checked

    IPoolManager private immutable _poolManager;

    constructor(IPoolManager poolManager) BaseOverrideFee() {
        _poolManager = poolManager;
    }

    function poolManager() public view override returns (IPoolManager) {
        return _poolManager;
    }

    /**
     * @dev Initialize fees and price tracking for the pool.
     */
    function _afterInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96, int24)
        internal
        override
        returns (bytes4)
    {
        PoolId poolId = key.toId();
        feeAB[poolId] = INITIAL_FEE;
        feeBA[poolId] = INITIAL_FEE;
        lastSqrtPrice[poolId] = sqrtPriceX96;
        lastBlock[poolId] = block.number;
        return this.afterInitialize.selector;
    }

    /**
     * @dev Get the fee for the swap based on direction.
     */
    function _getFee(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        view
        override
        returns (uint24)
    {
        PoolId poolId = key.toId();
        return params.zeroForOne ? feeAB[poolId] : feeBA[poolId];
    }

    function getFee(address a, PoolKey calldata key, SwapParams calldata params,  bytes calldata data) public view returns (uint24) {
        return _getFee(a, key, params, data);
    }

    /**
     * @dev After swap: Check for block end and adjust fees if price decreased.
     */
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();
        (uint160 currentSqrtPrice,,,) = _poolManager.getSlot0(poolId);

        if (block.number > lastBlock[poolId]) {
            // New block: Check if price decreased
            if (currentSqrtPrice < lastSqrtPrice[poolId]) {
                // Price decreased: Adjust fees
                feeAB[poolId] = feeAB[poolId] + FSTEP > MAX_FEE ? MAX_FEE : feeAB[poolId] + FSTEP;
                feeBA[poolId] = feeBA[poolId] > FSTEP ? feeBA[poolId] - FSTEP : 0;
            } else if (currentSqrtPrice > lastSqrtPrice[poolId]) {
                // Price increased
                feeAB[poolId] = feeAB[poolId] > FSTEP ? feeAB[poolId] - FSTEP : 0;
                feeBA[poolId] = feeBA[poolId] + FSTEP > MAX_FEE ? MAX_FEE : feeBA[poolId] + FSTEP;
            }


            lastSqrtPrice[poolId] = currentSqrtPrice;
            lastBlock[poolId] = block.number;
        }

        return (this.afterSwap.selector, 0);
    }

    /**
     * @dev Set hook permissions: afterInitialize, beforeSwap, afterSwap.
     */
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}