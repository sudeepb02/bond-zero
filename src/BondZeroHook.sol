// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

import {BondZeroMaster} from "./BondZeroMaster.sol";

contract BondZeroHook is BaseHook, Ownable {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    uint24 public constant MIN_FEE = 500; // 0.05%
    uint24 public constant MAX_FEE = 3000; // 0.30%
    uint24 public constant INITIAL_POOL_FEE = 500; // 0.05% initial fee

    BondZeroMaster public immutable bondZeroMaster;

    // Mapping from Uniswap pool ID to market ID
    mapping(PoolId poolId => bytes32 marketId) public poolToMarketId;

    // Events
    event PoolMarketMappingSet(PoolId indexed poolId, bytes32 indexed marketId);

    constructor(IPoolManager _poolManager, BondZeroMaster _bondZeroMaster) BaseHook(_poolManager) Ownable(msg.sender) {
        bondZeroMaster = _bondZeroMaster;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    ////////////////////////////////////////////////////////
    /////////////////// Pool Management ////////////////////
    ////////////////////////////////////////////////////////

    function setPoolMarketMapping(PoolKey calldata poolKey, bytes32 marketId) external onlyOwner {
        PoolId poolId = poolKey.toId();

        // Verify that the market exists in BondZeroMaster
        BondZeroMaster.BondMarket memory market = bondZeroMaster.getBondMarket(marketId);
        require(market.yieldBearingToken != address(0), "invalid market");

        poolToMarketId[poolId] = marketId;
        emit PoolMarketMappingSet(poolId, marketId);
    }

    function getMarketIdForPool(PoolKey calldata poolKey) external view returns (bytes32) {
        return poolToMarketId[poolKey.toId()];
    }

    function getBondMarketForPool(PoolKey calldata poolKey) external view returns (BondZeroMaster.BondMarket memory) {
        bytes32 marketId = poolToMarketId[poolKey.toId()];
        require(marketId != bytes32(0), "invalid market");
        return bondZeroMaster.getBondMarket(marketId);
    }

    ////////////////////////////////////////////////////////
    ///////////////////////  Hooks /////////////////////////
    ////////////////////////////////////////////////////////

    function _afterInitialize(address, PoolKey calldata key, uint160, int24) internal override returns (bytes4) {
        poolManager.updateDynamicLPFee(key, INITIAL_POOL_FEE);
        return BaseHook.afterInitialize.selector;
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        bytes32 marketId = poolToMarketId[poolId];

        // If market is not set with pool, skip hook logic
        if (marketId == bytes32(0)) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        BondZeroMaster.BondMarket memory market = bondZeroMaster.getBondMarket(marketId);
        require(market.yieldBearingToken != address(0), "invalid market");

        // Handle expired markets with 1:1 swap rate between Principal Token and Yield Bearing Token
        if (market.expiry <= block.timestamp) {
            return _handleExpiredMarketSwap(key, params, market);
        }

        // For active markets, continue with normal swap logic
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _handleExpiredMarketSwap(
        PoolKey calldata key,
        SwapParams calldata params,
        BondZeroMaster.BondMarket memory market
    ) internal returns (bytes4, BeforeSwapDelta, uint24) {
        // Determine which currency is the principal token and which is the yield bearing token
        Currency currency0 = key.currency0;
        Currency currency1 = key.currency1;

        address token0 = Currency.unwrap(currency0);
        address token1 = Currency.unwrap(currency1);

        if (token0 == market.principalToken) {
            // token0 is PT, token1 is YBT
            require(token1 == market.yieldBearingToken, "invalid market");
        } else if (token1 == market.principalToken) {
            // token1 is PT, token0 is YBT
            require(token0 == market.yieldBearingToken, "invalid market");
        } else {
            revert("invalid market");
        }

        // intercept the swap and handle it at 1:1 rate exchange rate (for expired markets only)
        // markets having time till maturity trade freely
        if (params.amountSpecified < 0) {
            // Exact input swap
            int128 amountSpecified = int128(params.amountSpecified);

            // For 1:1 rate, set the output amount equals the input amount\
            int128 deltaSpecified = amountSpecified; // receive the input amount
            int128 deltaUnspecified = -amountSpecified; // transfer equal output amount

            BeforeSwapDelta delta = toBeforeSwapDelta(deltaSpecified, deltaUnspecified);
            return (BaseHook.beforeSwap.selector, delta, 0);
        } else {
            // Exact output swap
            int128 amountSpecified = int128(params.amountSpecified);

            // For 1:1 rate, set the input amount equals the output amount
            int128 deltaSpecified = -amountSpecified; // transfer the output amount
            int128 deltaUnspecified = amountSpecified; // receive equal input amount

            BeforeSwapDelta delta = toBeforeSwapDelta(deltaSpecified, deltaUnspecified);
            return (BaseHook.beforeSwap.selector, delta, 0);
        }
    }
}
