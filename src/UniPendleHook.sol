// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

import {IStandardizedYield} from "@pendle/core-v2/contracts/interfaces/IStandardizedYield.sol";
import {IPPrincipalToken} from "@pendle/core-v2/contracts/interfaces/IPPrincipalToken.sol";
import {IPYieldToken} from "@pendle/core-v2/contracts/interfaces/IPYieldToken.sol";

contract UniPendleHook is BaseHook {
    using PoolIdLibrary for PoolKey;

    struct PendleMarketState {
        int256 totalPt;
        int256 totalSy;
        int256 totalLp;
        address treasury;
        /// immutable variables ///
        int256 scalarRoot;
        uint256 expiry;
        /// fee data ///
        uint256 lnFeeRateRoot;
        uint256 reserveFeePercent; // base 100
        /// last trade data ///
        uint256 lastLnImpliedRate;
    }

    struct PendleMarketPreCompute {
        int256 rateScalar;
        int256 totalAsset;
        int256 rateAnchor;
        int256 feeRate;
    }

    struct PendleMarketV3 {
        IStandardizedYield SY;
        IPPrincipalToken PT;
        IPYieldToken YT;
        uint256 expiry;
        int256 scalarRoot;
        int256 initialAnchor;
        uint80 lnFeeRateRoot;
    }

    // struct PendleMarketStorage {
    //     int128 totalPt;
    //     int128 totalSy;
    //     // 1 SLOT = 256 bits
    //     uint96 lastLnImpliedRate;
    //     uint16 observationIndex;
    //     uint16 observationCardinality;
    //     uint16 observationCardinalityNext;
    // }
    // // 1 SLOT = 144 bits

    struct InitData {
        address ptAddress;
        int256 scalarRoot;
        int256 initialAnchor;
        uint80 lnFeeRateRoot;
    }

    mapping(PoolId => PendleMarketState) public pendleMarketState;
    mapping(PoolId => PendleMarketPreCompute) public pendleMarketPreCompute;
    mapping(PoolId => PendleMarketV3) public pendleMarketV3;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: true,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: true,
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

    ////////////////////////////////////////////////////////
    ///////////////// Initialization Hooks /////////////////
    ////////////////////////////////////////////////////////

    function afterInitialize(
        address sender,
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        int24 tick,
        bytes calldata data
    ) external override onlyPoolManager returns (bytes4) {
        InitData memory decodedData = abi.decode(data, (InitData));

        PendleMarketV3 storage pendleMarket = pendleMarketV3[key.toId()];
        require(address(pendleMarket.PT) != address(0), "already initialized");

        IPPrincipalToken PT_ = IPPrincipalToken(decodedData.ptAddress);
        pendleMarket.PT = PT_;
        pendleMarket.SY = IStandardizedYield(PT_.SY());
        pendleMarket.YT = IPYieldToken(PT_.YT());

        // Observation cardinality not required for oracle

        if (decodedData.scalarRoot <= 0) revert("MarketScalarRootBelowZero");

        pendleMarket.scalarRoot = decodedData.scalarRoot;
        pendleMarket.initialAnchor = decodedData.initialAnchor;
        pendleMarket.lnFeeRateRoot = decodedData.lnFeeRateRoot;
        pendleMarket.expiry = PT_.expiry();

        return BaseHook.afterInitialize.selector;
    }

    ////////////////////////////////////////////////////////
    //////////////////// Liquidity Hooks ///////////////////
    ////////////////////////////////////////////////////////

    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        override
        returns (bytes4)
    {
        return BaseHook.beforeAddLiquidity.selector;
    }

    function _afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        return (BaseHook.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function _beforeRemoveLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        internal
        override
        returns (bytes4)
    {
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    function _afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        return (BaseHook.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    ////////////////////////////////////////////////////////
    /////////////////////// Swap Hooks /////////////////////
    ////////////////////////////////////////////////////////

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        return (BaseHook.afterSwap.selector, 0);
    }

    ////////////////////////////////////////////////////////
    /////////////////// Helper functions ///////////////////
    ////////////////////////////////////////////////////////
}
