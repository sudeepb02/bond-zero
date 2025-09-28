// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

/**
 * @title Counter
 * @author BondZero Protocol
 * @notice Example Uniswap v4 hook that counts various pool operations
 * @dev Simple demonstration hook that tracks the number of swaps and liquidity operations
 *      Used for testing and reference - not part of the main BondZero protocol
 */
contract Counter is BaseHook {
    using PoolIdLibrary for PoolKey;

    /// @notice Counter for beforeSwap hook calls per pool
    /// @dev State variables are unique to each pool ID for multi-pool support
    mapping(PoolId => uint256 count) public beforeSwapCount;

    /// @notice Counter for afterSwap hook calls per pool
    mapping(PoolId => uint256 count) public afterSwapCount;

    /// @notice Counter for beforeAddLiquidity hook calls per pool
    mapping(PoolId => uint256 count) public beforeAddLiquidityCount;

    /// @notice Counter for beforeRemoveLiquidity hook calls per pool
    mapping(PoolId => uint256 count) public beforeRemoveLiquidityCount;

    /**
     * @notice Constructor for Counter hook
     * @param _poolManager Address of the Uniswap v4 PoolManager contract
     */
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    /**
     * @notice Defines which hook functions this contract implements
     * @return Hooks.Permissions struct specifying enabled hook functions
     */
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
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

    /**
     * @notice Hook called before swap execution
     * @dev Increments the beforeSwap counter for the pool and returns zero delta
     * @param key Pool key identifying the pool
     * @return selector Function selector for beforeSwap
     * @return BeforeSwapDelta Zero delta (no token amounts modified)
     * @return uint24 Zero (no fee override)
     */
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        beforeSwapCount[key.toId()]++;
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /**
     * @notice Hook called after swap execution
     * @dev Increments the afterSwap counter for the pool
     * @param key Pool key identifying the pool
     * @return selector Function selector for afterSwap
     * @return int128 Zero (no additional fees)
     */
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        afterSwapCount[key.toId()]++;
        return (BaseHook.afterSwap.selector, 0);
    }

    /**
     * @notice Hook called before liquidity addition
     * @dev Increments the beforeAddLiquidity counter for the pool
     * @param key Pool key identifying the pool
     * @return selector Function selector for beforeAddLiquidity
     */
    function _beforeAddLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        internal
        override
        returns (bytes4)
    {
        beforeAddLiquidityCount[key.toId()]++;
        return BaseHook.beforeAddLiquidity.selector;
    }

    /**
     * @notice Hook called before liquidity removal
     * @dev Increments the beforeRemoveLiquidity counter for the pool
     * @param key Pool key identifying the pool
     * @return selector Function selector for beforeRemoveLiquidity
     */
    function _beforeRemoveLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        internal
        override
        returns (bytes4)
    {
        beforeRemoveLiquidityCount[key.toId()]++;
        return BaseHook.beforeRemoveLiquidity.selector;
    }
}
