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
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";

contract BondZeroHook is BaseHook, Ownable, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;

    uint24 public constant MIN_FEE = 500; // 0.05%
    uint24 public constant MAX_FEE = 3000; // 0.30%
    uint24 public constant INITIAL_POOL_FEE = 500; // 0.05% initial fee

    BondZeroMaster public immutable bondZeroMaster;

    // Mapping from Uniswap pool ID to market ID
    mapping(PoolId => bytes32) internal poolToMarketId;

    // Callback data structure for unlock operations
    struct CallbackData {
        uint256 amountEach; // Amount of each token to add as liquidity
        Currency currency0;
        Currency currency1;
        address sender;
    }

    error AddLiquidityThroughHook(); // Error when someone tries adding liquidity directly to PoolManager

    event PoolMarketMappingSet(PoolId indexed poolId, bytes32 indexed marketId);

    constructor(IPoolManager _poolManager, BondZeroMaster _bondZeroMaster) BaseHook(_poolManager) Ownable(msg.sender) {
        bondZeroMaster = _bondZeroMaster;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: true, // Disable adding liquidity through PoolManager
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true, // Allow beforeSwap to return custom delta
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
    ///////////////////////  Liquidity /////////////////////
    ////////////////////////////////////////////////////////

    // Disable adding liquidity through the PoolManager
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert AddLiquidityThroughHook();
    }

    // Custom add liquidity function - following CSMM pattern
    function addLiquidity(PoolKey calldata key, uint256 amountEach) external {
        poolManager.unlock(abi.encode(CallbackData(amountEach, key.currency0, key.currency1, msg.sender)));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(poolManager), "!pool manager");
        CallbackData memory callbackData = abi.decode(data, (CallbackData));

        // Settle `amountEach` of each currency from the sender
        // i.e. Create a debit of `amountEach` of each currency with the Pool Manager
        callbackData.currency0.settle(
            poolManager,
            callbackData.sender,
            callbackData.amountEach,
            false // `burn` = `false` i.e. we're transferring tokens, not burning ERC-6909 claim tokens
        );
        callbackData.currency1.settle(poolManager, callbackData.sender, callbackData.amountEach, false);

        // Get back ERC-6909 claim tokens for `amountEach` of each currency
        // to create a credit that balances out the debit
        callbackData.currency0.take(
            poolManager,
            address(this),
            callbackData.amountEach,
            true // true = mint claim tokens for the hook
        );
        callbackData.currency1.take(poolManager, address(this), callbackData.amountEach, true);

        return "";
    }

    // Helper function to check claim token balances
    function getClaimTokenBalance(Currency currency) external view returns (uint256) {
        uint256 currencyId = CurrencyLibrary.toId(currency);
        return poolManager.balanceOf(address(this), currencyId);
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
        // For expired markets, redeem PT tokens 1:1 for YBT through BondZeroMaster

        // Check for potential overflow before casting
        require(params.amountSpecified != 0, "zero");
        require(
            params.amountSpecified >= type(int128).min && params.amountSpecified <= type(int128).max,
            "int128 amount overflow"
        );

        uint256 amountInOutPositive =
            params.amountSpecified > 0 ? uint256(params.amountSpecified) : uint256(-params.amountSpecified);

        // Determine which currency is PT and which is YBT
        Currency ptCurrency;
        Currency ybtCurrency;
        bool isPTCurrency0;

        if (Currency.unwrap(key.currency0) == market.principalToken) {
            ptCurrency = key.currency0;
            ybtCurrency = key.currency1;
            isPTCurrency0 = true;
            require(Currency.unwrap(key.currency1) == market.yieldBearingToken, "invalid YBT");
        } else if (Currency.unwrap(key.currency1) == market.principalToken) {
            ptCurrency = key.currency1;
            ybtCurrency = key.currency0;
            isPTCurrency0 = false;
            require(Currency.unwrap(key.currency0) == market.yieldBearingToken, "invalid YBT");
        } else {
            revert("invalid market mapping");
        }

        // Check if user is trying to swap PT for YBT (the only allowed direction for expired markets)
        bool isSwappingPTForYBT = (isPTCurrency0 && params.zeroForOne) || (!isPTCurrency0 && !params.zeroForOne);
        require(isSwappingPTForYBT, "can only swap PT for YBT when expired");

        // BeforeSwapDelta format: (specifiedCurrency, unspecifiedCurrency)
        // For 1:1 swaps, we set deltaSpecified = -amountSpecified, deltaUnspecified = +amountSpecified
        BeforeSwapDelta beforeSwapDelta = toBeforeSwapDelta(
            int128(-params.amountSpecified), // Consume the specified amount (PT)
            int128(params.amountSpecified) // Provide the unspecified amount (YBT) at 1:1 ratio
        );

        // Take PT tokens from user via pool manager
        ptCurrency.take(poolManager, address(this), amountInOutPositive, false);

        // Get the actual PT token contract and approve BondZeroMaster if needed
        IERC20 ptToken = IERC20(Currency.unwrap(ptCurrency));
        if (ptToken.allowance(address(this), address(bondZeroMaster)) < amountInOutPositive) {
            ptToken.approve(address(bondZeroMaster), type(uint256).max);
        }

        // Get current YBT balance before redemption
        IERC20 ybtToken = IERC20(Currency.unwrap(ybtCurrency));
        uint256 ybtBalanceBefore = ybtToken.balanceOf(address(this));

        // Redeem PT tokens for YBT through BondZeroMaster
        bytes32 marketId = poolToMarketId[key.toId()];
        bondZeroMaster.redeemPtAndYt(marketId, amountInOutPositive);

        // Verify we received the expected amount of YBT
        uint256 ybtBalanceAfter = ybtToken.balanceOf(address(this));
        uint256 ybtReceived = ybtBalanceAfter - ybtBalanceBefore;
        require(ybtReceived >= amountInOutPositive, "redemption failed");

        // Approve pool manager to take the YBT tokens if needed
        if (ybtToken.allowance(address(this), address(poolManager)) < amountInOutPositive) {
            ybtToken.approve(address(poolManager), type(uint256).max);
        }

        // Settle YBT tokens to user via pool manager
        ybtCurrency.settle(poolManager, address(this), amountInOutPositive, false);

        return (BaseHook.beforeSwap.selector, beforeSwapDelta, 0);
    }

    /// @notice Helper function to determine input/output currencies and amount for the swap
    function _getInputOutputAndAmount(PoolKey calldata key, SwapParams calldata params)
        internal
        pure
        returns (Currency input, Currency output, uint256 amount)
    {
        (input, output) = params.zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        amount = params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
    }
}
