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

    struct PendleTokens {
        IStandardizedYield SY;
        IPPrincipalToken PT;
        IPYieldToken YT;
    }

    mapping(PoolId => PendleMarketState) public pendleMarketState;
    mapping(PoolId => PendleMarketPreCompute) public pendleMarketPreCompute;
    mapping(PoolId => PendleTokens) public pendleTokens;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
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

    function _setPendleTokensForPool(PoolId poolId, address _PT) internal {
        if (address(pendleTokens[poolId].PT) != address(0)) {
            // @todo Replace with custom error
            revert("Pendle tokens already set");
        }

        IPPrincipalToken PT_ = IPPrincipalToken(_PT);
        IStandardizedYield SY_ = IStandardizedYield(PT_.SY());
        IPYieldToken YT_ = IPYieldToken(PT_.YT());

        pendleTokens[poolId].PT = PT_;
        pendleTokens[poolId].SY = SY_;
        pendleTokens[poolId].YT = YT_;
    }
}
