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

/**
 * @title BondZeroHook
 * @author BondZero Protocol
 * @notice Uniswap v4 hook that enables seamless PT/YBT trading and automatic redemption for expired bond markets
 * @dev This hook integrates bond markets with Uniswap v4 AMM, providing:
 *      - Custom liquidity management using ERC-6909 claim tokens (CSMM pattern)
 *      - 1:1 PT -> YBT redemption through BondZeroMaster for expired markets
 *      - Prevention of YBT -> PT swaps when markets are expired
 */
contract BondZeroHook is BaseHook, Ownable, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;

    /// @notice Minimum fee that can be set for a pool (0.05%)
    uint24 public constant MIN_FEE = 500;

    /// @notice Maximum fee that can be set for a pool (0.30%)
    uint24 public constant MAX_FEE = 3000;

    /// @notice Initial fee set when pools are created (0.05%)
    uint24 public constant INITIAL_POOL_FEE = 500;

    /// @notice Reference to the BondZeroMaster contract for bond market operations
    BondZeroMaster public immutable bondZeroMaster;

    /// @notice Mapping from Uniswap pool ID to bond market ID for PT/YBT pairs
    mapping(PoolId => bytes32) internal poolToMarketId;

    /**
     * @notice Data structure used for unlock callback operations during liquidity provision
     * @param amountEach Amount of each token to add as liquidity to the hook
     * @param currency0 First currency in the pool pair
     * @param currency1 Second currency in the pool pair
     * @param sender Address providing the liquidity
     */
    struct CallbackData {
        uint256 amountEach;
        Currency currency0;
        Currency currency1;
        address sender;
    }

    /// @notice Thrown when someone attempts to add liquidity directly through PoolManager
    error AddLiquidityThroughHook();

    /**
     * @notice Emitted when a pool is mapped to a bond market
     * @param poolId The ID of the Uniswap v4 pool
     * @param marketId The ID of the corresponding bond market
     */
    event PoolMarketMappingSet(PoolId indexed poolId, bytes32 indexed marketId);

    /**
     * @notice Initializes the BondZeroHook with required dependencies
     * @param _poolManager The Uniswap v4 PoolManager contract
     * @param _bondZeroMaster The BondZeroMaster contract for bond market operations
     */
    constructor(IPoolManager _poolManager, BondZeroMaster _bondZeroMaster) BaseHook(_poolManager) Ownable(msg.sender) {
        bondZeroMaster = _bondZeroMaster;
    }

    /**
     * @notice Specifies which hook functions this contract implements
     * @return Hooks.Permissions struct defining enabled hook permissions
     * @dev Enables: afterInitialize, beforeAddLiquidity, beforeSwap, beforeSwapReturnDelta
     */
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

    /**
     * @notice Maps a Uniswap v4 pool to a specific bond market
     * @param poolKey The pool key identifying the Uniswap v4 pool
     * @param marketId The ID of the bond market to associate with this pool
     * @dev Only owner can call this function. Validates that the market exists before mapping.
     */
    function setPoolMarketMapping(PoolKey calldata poolKey, bytes32 marketId) external onlyOwner {
        PoolId poolId = poolKey.toId();

        // Verify that the market exists in BondZeroMaster
        BondZeroMaster.BondMarket memory market = bondZeroMaster.getBondMarket(marketId);
        require(market.yieldBearingToken != address(0), "invalid market");

        poolToMarketId[poolId] = marketId;
        emit PoolMarketMappingSet(poolId, marketId);
    }

    /**
     * @notice Retrieves the market ID associated with a given pool
     * @param poolKey The pool key to look up
     * @return The bond market ID associated with the pool, or bytes32(0) if none
     */
    function getMarketIdForPool(PoolKey calldata poolKey) external view returns (bytes32) {
        return poolToMarketId[poolKey.toId()];
    }

    /**
     * @notice Retrieves the complete bond market data for a given pool
     * @param poolKey The pool key to look up
     * @return BondMarket struct containing all market information
     * @dev Reverts if no market is associated with the pool
     */
    function getBondMarketForPool(PoolKey calldata poolKey) external view returns (BondZeroMaster.BondMarket memory) {
        bytes32 marketId = poolToMarketId[poolKey.toId()];
        require(marketId != bytes32(0), "invalid market");
        return bondZeroMaster.getBondMarket(marketId);
    }

    ////////////////////////////////////////////////////////
    ///////////////////////  Liquidity /////////////////////
    ////////////////////////////////////////////////////////

    /**
     * @notice Hook to disable adding liquidity through the default PoolManager mechanism
     * @dev Always reverts to force users to use the hook's custom addLiquidity function
     * @return bytes4 Hook function selector (never reached due to revert)
     */
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert AddLiquidityThroughHook();
    }

    /**
     * @notice Custom liquidity provision function following CSMM pattern
     * @param key The pool key identifying the target pool
     * @param amountEach Amount of each token (PT and YBT) to provide as liquidity
     * @dev Uses unlock mechanism to atomically handle token transfers and claim token minting
     */
    function addLiquidity(PoolKey calldata key, uint256 amountEach) external {
        poolManager.unlock(abi.encode(CallbackData(amountEach, key.currency0, key.currency1, msg.sender)));
    }

    /**
     * @notice Callback function executed during liquidity provision via unlock mechanism
     * @param data Encoded CallbackData containing liquidity provision parameters
     * @return bytes Empty bytes (callback requires return value)
     * @dev Transfers tokens from user to PoolManager and mints ERC-6909 claim tokens to hook
     */
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(poolManager), "!pool manager");
        CallbackData memory callbackData = abi.decode(data, (CallbackData));

        // Settle `amountEach` of each currency from the sender to create debits with PoolManager
        callbackData.currency0.settle(
            poolManager,
            callbackData.sender,
            callbackData.amountEach,
            false // `burn` = `false` i.e. we're transferring tokens, not burning ERC-6909 claim tokens
        );
        callbackData.currency1.settle(poolManager, callbackData.sender, callbackData.amountEach, false);

        // Mint ERC-6909 claim tokens to the hook to balance out the debits
        // These claim tokens represent the hook's ownership of the deposited tokens
        callbackData.currency0.take(
            poolManager,
            address(this),
            callbackData.amountEach,
            true // true = mint claim tokens for the hook
        );
        callbackData.currency1.take(poolManager, address(this), callbackData.amountEach, true);

        return "";
    }

    /**
     * @notice Helper function to check the hook's claim token balance for a specific currency
     * @param currency The currency to check the balance for
     * @return uint256 The amount of ERC-6909 claim tokens the hook owns for the currency
     */
    function getClaimTokenBalance(Currency currency) external view returns (uint256) {
        uint256 currencyId = CurrencyLibrary.toId(currency);
        return poolManager.balanceOf(address(this), currencyId);
    }

    ////////////////////////////////////////////////////////
    ///////////////////////  Hooks /////////////////////////
    ////////////////////////////////////////////////////////

    /**
     * @notice Hook called after pool initialization to set initial parameters
     * @param key The pool key for the newly initialized pool
     * @return bytes4 The function selector to confirm successful execution
     * @dev Sets the initial LP fee for the pool
     */
    function _afterInitialize(address, PoolKey calldata key, uint160, int24) internal override returns (bytes4) {
        poolManager.updateDynamicLPFee(key, INITIAL_POOL_FEE);
        return BaseHook.afterInitialize.selector;
    }

    /**
     * @notice Main hook logic executed before each swap
     * @param key The pool key identifying the pool being swapped in
     * @param params The swap parameters (direction, amount, limits)
     * @return bytes4 Function selector for successful execution
     * @return BeforeSwapDelta Custom delta for expired markets, ZERO_DELTA for active markets
     * @return uint24 Fee override (0 = no override)
     * @dev For expired markets, redirects to special 1:1 redemption logic
     */
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        bytes32 marketId = poolToMarketId[poolId];

        // Skip hook logic if no market is associated with this pool
        if (marketId == bytes32(0)) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        BondZeroMaster.BondMarket memory market = bondZeroMaster.getBondMarket(marketId);
        require(market.yieldBearingToken != address(0), "invalid market");

        // Handle expired markets with automatic PT redemption through BondZeroMaster
        if (market.expiry <= block.timestamp) {
            return _handleExpiredMarketSwap(key, params, market);
        }

        // For active markets, allow normal AMM trading without hook intervention
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /**
     * @notice Handles swaps for expired bond markets by facilitating PT redemption
     * @param key The pool key identifying the pool
     * @param params The swap parameters
     * @param market The bond market data
     * @return bytes4 Function selector for successful execution
     * @return BeforeSwapDelta Custom delta implementing 1:1 PT->YBT redemption
     * @return uint24 Fee override (0 = no override)
     * @dev Only allows PT->YBT swaps, rejects YBT->PT. Redeems PT via BondZeroMaster.
     */
    function _handleExpiredMarketSwap(
        PoolKey calldata key,
        SwapParams calldata params,
        BondZeroMaster.BondMarket memory market
    ) internal returns (bytes4, BeforeSwapDelta, uint24) {
        // Validate swap amount to prevent overflow when casting to int128
        require(params.amountSpecified != 0, "zero");
        require(
            params.amountSpecified >= type(int128).min && params.amountSpecified <= type(int128).max,
            "int128 amount overflow"
        );

        uint256 amountInOutPositive =
            params.amountSpecified > 0 ? uint256(params.amountSpecified) : uint256(-params.amountSpecified);

        // Identify which currency corresponds to PT and YBT based on market configuration
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

        // Enforce security rule: only allow PT->YBT swaps for expired markets
        bool isSwappingPTForYBT = (isPTCurrency0 && params.zeroForOne) || (!isPTCurrency0 && !params.zeroForOne);
        require(isSwappingPTForYBT, "can only swap PT for YBT when expired");

        // Create BeforeSwapDelta for 1:1 redemption (consume PT amount, provide equal YBT amount)
        BeforeSwapDelta beforeSwapDelta = toBeforeSwapDelta(
            int128(-params.amountSpecified), // Consume the specified amount (PT)
            int128(params.amountSpecified) // Provide the unspecified amount (YBT) at 1:1 ratio
        );

        // Step 1: Take PT tokens from user via PoolManager
        ptCurrency.take(poolManager, address(this), amountInOutPositive, false);

        // Step 2: Ensure hook has approval to spend PT tokens with BondZeroMaster
        IERC20 ptToken = IERC20(Currency.unwrap(ptCurrency));
        if (ptToken.allowance(address(this), address(bondZeroMaster)) < amountInOutPositive) {
            ptToken.approve(address(bondZeroMaster), type(uint256).max);
        }

        // Step 3: Track YBT balance before redemption to verify correct amount received
        IERC20 ybtToken = IERC20(Currency.unwrap(ybtCurrency));
        uint256 ybtBalanceBefore = ybtToken.balanceOf(address(this));

        // Step 4: Execute PT redemption through BondZeroMaster (PT burned, YBT received)
        bytes32 marketId = poolToMarketId[key.toId()];
        bondZeroMaster.redeemPtAndYt(marketId, amountInOutPositive);

        // Step 5: Verify redemption was successful and we received expected YBT amount
        uint256 ybtBalanceAfter = ybtToken.balanceOf(address(this));
        uint256 ybtReceived = ybtBalanceAfter - ybtBalanceBefore;
        require(ybtReceived >= amountInOutPositive, "redemption failed");

        // Step 6: Ensure hook has approval to transfer YBT tokens to PoolManager
        if (ybtToken.allowance(address(this), address(poolManager)) < amountInOutPositive) {
            ybtToken.approve(address(poolManager), type(uint256).max);
        }

        // Step 7: Transfer YBT tokens to user via PoolManager settlement
        ybtCurrency.settle(poolManager, address(this), amountInOutPositive, false);

        return (BaseHook.beforeSwap.selector, beforeSwapDelta, 0);
    }

    /**
     * @notice Helper function to extract swap direction and amounts from swap parameters
     * @param key The pool key containing currency information
     * @param params The swap parameters
     * @return input The input currency for the swap
     * @return output The output currency for the swap
     * @return amount The absolute amount being swapped
     * @dev Converts negative amountSpecified to positive for easier processing
     */
    function _getInputOutputAndAmount(PoolKey calldata key, SwapParams calldata params)
        internal
        pure
        returns (Currency input, Currency output, uint256 amount)
    {
        (input, output) = params.zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        amount = params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
    }
}
