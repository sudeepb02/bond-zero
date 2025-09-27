// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

import {BondZeroMaster} from "./BondZeroMaster.sol";

contract BondZeroHook is BaseHook, Ownable {
    using PoolIdLibrary for PoolKey;

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

        // If makret is not set with pool, skip hook logic
        if (marketId == bytes32(0)) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        BondZeroMaster.BondMarket memory market = bondZeroMaster.getBondMarket(marketId);
        require(market.yieldBearingToken != address(0), "invalid market");

        // @todo handle for expired markets, else continue with existing logic
        if (market.expiry < block.timestamp) {}

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}
