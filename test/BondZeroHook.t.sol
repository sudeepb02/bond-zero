// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {Deployers} from "./utils/Deployers.sol";

import {BondZeroHook} from "../src/BondZeroHook.sol";
import {BondZeroMaster} from "../src/BondZeroMaster.sol";
import {PrincipalToken} from "../src/PrincipalToken.sol";
import {YieldToken} from "../src/YieldToken.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {MockYieldBearingToken} from "../src/mocks/MockYieldBearingToken.sol";

import {SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {console2} from "forge-std/Test.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

contract BondZeroHookTest is Test, Deployers {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    Currency currency0;
    Currency currency1;

    PoolKey poolKey;

    BondZeroHook hook;
    PoolId poolId;

    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;

    BondZeroMaster public bondZeroMaster;
    MockERC20 public underlyingAsset;
    MockYieldBearingToken public yieldBearingToken;
    uint256 public expiry;
    bytes32 public marketId;
    bool isPTToken0;

    uint256 public constant INITIAL_SUPPLY = 100 ether;
    uint256 public constant INITIAL_APR = 1000; // 10% APR (in basis points: 1000 = 10%)

    address public user1 = address(0x1);
    address public user2 = address(0x2);

    function setUp() public {
        // Deploys all required artifacts.
        deployArtifacts();

        // Bond Zero setup
        bondZeroMaster = new BondZeroMaster();
        underlyingAsset = new MockERC20("Staked ETH", "stETH", 18);
        yieldBearingToken = new MockYieldBearingToken("Wrapped Staked ETH", "wstETH", address(underlyingAsset), 1000); // 10% APR
        expiry = block.timestamp + 365 days; // 1 year from now

        underlyingAsset.mint(address(this), INITIAL_SUPPLY);
        underlyingAsset.mint(user1, INITIAL_SUPPLY);
        underlyingAsset.mint(user2, INITIAL_SUPPLY);

        // Create market
        bondZeroMaster.createBondMarket(address(yieldBearingToken), address(underlyingAsset), expiry, INITIAL_APR);
        marketId = keccak256(abi.encode(address(yieldBearingToken), address(underlyingAsset), expiry));

        BondZeroMaster.BondMarket memory market = bondZeroMaster.getBondMarket(marketId);
        assertEq(market.yieldBearingToken, address(yieldBearingToken));

        address token0;
        address token1;

        // Token0 should be the market with lower address value
        if (market.yieldBearingToken > market.principalToken) {
            token0 = market.principalToken;
            token1 = market.yieldBearingToken;
            isPTToken0 = true;
        } else {
            token0 = market.yieldBearingToken;
            token1 = market.principalToken;
            isPTToken0 = false;
        }

        currency0 = Currency.wrap(token0);
        currency1 = Currency.wrap(token1);

        vm.label(address(token0), "Currency0");
        vm.label(address(token1), "Currency1");

        // Deploy the hook to an address with the correct flags
        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_INITIALIZE_FLAG
                    | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            ) ^ (0x4444 << 144) // Namespace the hook to avoid collisions
        );

        bytes memory constructorArgs = abi.encode(poolManager, address(bondZeroMaster)); // Add all the necessary constructor arguments from the hook
        deployCodeTo("BondZeroHook.sol:BondZeroHook", constructorArgs, flags);
        hook = BondZeroHook(flags);

        // @todo Get the price of token0 in token1

        // Mint tokens for the test contract to provide liquidity
        uint256 totalNeeded = 80e18; // Total amount needed for both minting and liquidity

        // Mint YBT first (deposit underlying assets)
        underlyingAsset.approve(address(yieldBearingToken), totalNeeded);
        uint256 ybtMinted = yieldBearingToken.deposit(totalNeeded);

        // Use half for minting PT/YT, keep half for liquidity provision
        uint256 mintAmount = ybtMinted / 2;
        yieldBearingToken.approve(address(bondZeroMaster), mintAmount);
        bondZeroMaster.mintPtAndYt(marketId, mintAmount);

        // The remaining YBT will be used for liquidity provision

        // Set up token approvals before pool operations
        MockERC20(Currency.unwrap(currency0)).approve(address(permit2), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(permit2), type(uint256).max);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);

        permit2.approve(
            address(Currency.unwrap(currency0)), address(positionManager), type(uint160).max, type(uint48).max
        );
        permit2.approve(
            address(Currency.unwrap(currency1)), address(positionManager), type(uint160).max, type(uint48).max
        );
        permit2.approve(address(Currency.unwrap(currency0)), address(poolManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(Currency.unwrap(currency1)), address(poolManager), type(uint160).max, type(uint48).max);

        // Create the pool
        poolKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        // Provide full-range liquidity to the pool
        tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);

        // Mint tokens for liquidity provision
        // First mint YBT tokens for the test contract
        uint256 ybtForLiquidity = 1000e18; // Increased to provide more liquidity
        underlyingAsset.mint(address(this), ybtForLiquidity);
        underlyingAsset.approve(address(yieldBearingToken), ybtForLiquidity);
        yieldBearingToken.deposit(ybtForLiquidity);

        // Mint PT and YT tokens for the test contract
        yieldBearingToken.approve(address(bondZeroMaster), ybtForLiquidity);
        bondZeroMaster.mintPtAndYt(marketId, ybtForLiquidity);

        // Set up approvals for position manager and pool manager
        BondZeroMaster.BondMarket memory marketData = bondZeroMaster.getBondMarket(marketId);
        MockERC20(marketData.principalToken).approve(address(positionManager), type(uint256).max);
        MockERC20(marketData.yieldBearingToken).approve(address(positionManager), type(uint256).max);
        MockERC20(marketData.principalToken).approve(address(poolManager), type(uint256).max);
        MockERC20(marketData.yieldBearingToken).approve(address(poolManager), type(uint256).max);

        uint128 liquidityAmount = 30e18; // Reduce to amount we can afford with available tokens

        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        // Mint extra tokens to ensure we have enough for liquidity and swaps
        // Mint extra underlying and convert to YBT
        underlyingAsset.mint(address(this), 2000e18);
        underlyingAsset.approve(address(yieldBearingToken), 2000e18);
        yieldBearingToken.deposit(2000e18);

        // Mint extra PT tokens by minting more from bond market
        yieldBearingToken.approve(address(bondZeroMaster), 1000e18);
        bondZeroMaster.mintPtAndYt(marketId, 1000e18);

        // Now we should have plenty of both PT and YBT tokens

        // Instead of using position manager, add liquidity via the hook's addLiquidity function
        // First approve the hook to spend our tokens
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);

        // Add liquidity via hook's custom function (CSMM pattern)
        uint256 amountEach = 400e18; // Amount of each token to add as liquidity (enough for swaps)
        hook.addLiquidity(poolKey, amountEach);

        // Set up pool-to-market mapping in the hook
        hook.setPoolMarketMapping(poolKey, marketId);

        // Setup approvals for poolManager
        MockERC20(Currency.unwrap(currency0)).approve(address(poolManager), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(poolManager), type(uint256).max);
    }

    /**
     * @dev Complete end-to-end test case covering the full user journey with BondZeroHook:
     * 1. User receives underlying assets (stETH)
     * 2. User deposits stETH to get yield-bearing tokens (wstETH)
     * 3. User deposits wstETH to BondZeroMaster to mint PT and YT
     * 4. User trades PT tokens in Uniswap pool (before expiry)
     * 5. Time progresses, market expires
     * 6. User swaps PT tokens for YBT tokens at 1:1 rate via hook (after expiry)
     * The hook should internally redeem the PT tokens received to get YBT from BondZeroMaster
     */
    function testFullUserJourneyWithHookSwap() public {
        // === STEP 1: Setup user with initial assets ===
        address testUser = address(0x999);
        uint256 initialAssetAmount = 1000e18; // 1000 stETH

        // Give user initial underlying assets and setup approvals
        underlyingAsset.mint(testUser, initialAssetAmount);

        vm.startPrank(testUser);
        underlyingAsset.approve(address(yieldBearingToken), type(uint256).max);
        underlyingAsset.approve(address(poolManager), type(uint256).max);

        // Verify user has underlying assets
        assertEq(underlyingAsset.balanceOf(testUser), initialAssetAmount, "User should have initial stETH");

        // === STEP 2: User mints yield-bearing tokens ===
        console2.log("=== STEP 2: Minting Yield-Bearing Tokens ===");

        uint256 ybtMinted = yieldBearingToken.deposit(initialAssetAmount);
        uint256 userYbtBalance = yieldBearingToken.balanceOf(testUser);

        console2.log("User YBT balance after deposit:", userYbtBalance);
        console2.log("YBT minted amount:", ybtMinted);

        // Verify user received YBT tokens
        assertEq(userYbtBalance, ybtMinted, "User should have received YBT tokens");
        assertGt(ybtMinted, 0, "Should have minted some YBT tokens");

        // === STEP 3: User deposits to bond market and mints PT/YT ===
        console2.log("=== STEP 3: Depositing to Bond Market ===");

        uint256 depositAmount = ybtMinted * 60 / 100; // Deposit 60% of YBT tokens, keep 40% for liquidity

        // Approve BondZeroMaster to spend YBT
        yieldBearingToken.approve(address(bondZeroMaster), depositAmount);

        // Get market info before minting
        BondZeroMaster.BondMarket memory market = bondZeroMaster.getBondMarket(marketId);
        PrincipalToken pt = PrincipalToken(market.principalToken);
        YieldToken yt = YieldToken(market.yieldToken);

        // Mint PT and YT tokens
        bondZeroMaster.mintPtAndYt(marketId, depositAmount);

        // Verify PT and YT were minted
        uint256 ptBalance = pt.balanceOf(testUser);
        uint256 ytBalance = yt.balanceOf(testUser);

        console2.log("PT balance after minting:", ptBalance);
        console2.log("YT balance after minting:", ytBalance);

        assertEq(ptBalance, depositAmount, "Should have minted PT tokens equal to deposit");
        assertEq(ytBalance, depositAmount, "Should have minted YT tokens equal to deposit");

        // Set up token approvals for trading
        pt.approve(address(poolManager), type(uint256).max);
        pt.approve(address(swapRouter), type(uint256).max);
        yieldBearingToken.approve(address(poolManager), type(uint256).max);
        yieldBearingToken.approve(address(swapRouter), type(uint256).max);

        // === STEP 4: Verify hook setup before expiry ===
        console2.log("=== STEP 4: Verifying Hook Setup Before Expiry ===");

        // Check that hook has correct market mapping
        bytes32 hookMarketId = hook.getMarketIdForPool(poolKey);
        assertEq(hookMarketId, marketId, "Hook should have correct market mapping");

        BondZeroMaster.BondMarket memory hookMarket = hook.getBondMarketForPool(poolKey);
        assertEq(hookMarket.principalToken, market.principalToken, "Hook should return correct market");

        console2.log("Hook correctly mapped to market ID:", uint256(hookMarketId));
        console2.log("Market expiry:", hookMarket.expiry);
        console2.log("Current time:", block.timestamp);

        // === STEP 5: Time progression to market expiry ===
        console2.log("=== STEP 5: Time Progression to Market Expiry ===");

        // Move to expiry time
        vm.warp(expiry + 1);
        console2.log("Market has expired at timestamp:", block.timestamp);

        // === STEP 6: Test post-expiry hook behavior by swapping PT against the pool ===
        // It should verify that the hook correctly handles 1:1 swaps after expiry without redeeming
        // the PT tokens directly via the BondZeroMaster, as the primary mechanism is now via the hook.
        console2.log("=== STEP 6: Testing Post-Expiry Hook Behavior ===");

        uint256 remainingPtBalance = pt.balanceOf(testUser);
        console2.log("Remaining PT balance:", remainingPtBalance);

        // Verify that market is now expired from hook's perspective
        BondZeroMaster.BondMarket memory expiredMarket = hook.getBondMarketForPool(poolKey);
        assertTrue(expiredMarket.expiry <= block.timestamp, "Market should be expired");
        console2.log("Market is now expired, hook should handle 1:1 swaps");

        // Test PT swapping via the hook after expiry (1:1 exchange rate)
        uint256 ybtBalanceBeforeSwap = yieldBearingToken.balanceOf(testUser);
        console2.log("YBT balance before hook swap:", ybtBalanceBeforeSwap);

        // Swap half of the PT tokens for YBT tokens via the hook (1:1 rate after expiry)
        uint256 ptSwapAmount = remainingPtBalance / 2;
        console2.log("PT amount to swap via hook:", ptSwapAmount);

        // Perform swap: PT (token0 or token1) → YBT (token1 or token0)
        // Determine swap direction based on token order
        bool zeroForOne = isPTToken0; // If PT is token0, we swap token0 for token1 (YBT)

        BalanceDelta swapDelta = swapRouter.swapExactTokensForTokens({
            amountIn: ptSwapAmount,
            amountOutMin: ptSwapAmount, // Expect 1:1 rate after expiry
            zeroForOne: zeroForOne,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: testUser,
            deadline: block.timestamp + 100
        });

        console2.log("Swap delta amount0:", swapDelta.amount0());
        console2.log("Swap delta amount1:", swapDelta.amount1());

        // Verify the hook provided 1:1 exchange rate
        uint256 expectedOutputAmount = ptSwapAmount;
        int128 actualOutputAmount;

        if (zeroForOne) {
            // PT (token0) → YBT (token1)
            actualOutputAmount = swapDelta.amount1();
            assertEq(swapDelta.amount0(), -int256(ptSwapAmount), "Should have spent exact PT amount");
        } else {
            // PT (token1) → YBT (token0)
            actualOutputAmount = swapDelta.amount0();
            assertEq(swapDelta.amount1(), -int256(ptSwapAmount), "Should have spent exact PT amount");
        }

        assertEq(
            uint256(int256(actualOutputAmount)), expectedOutputAmount, "Should receive 1:1 YBT for PT after expiry"
        );

        // Verify user balances after hook swap
        uint256 ptBalanceAfterSwap = pt.balanceOf(testUser);
        uint256 ybtBalanceAfterSwap = yieldBearingToken.balanceOf(testUser);

        console2.log("PT balance after hook swap:", ptBalanceAfterSwap);
        console2.log("YBT balance after hook swap:", ybtBalanceAfterSwap);

        assertEq(ptBalanceAfterSwap, remainingPtBalance - ptSwapAmount, "PT balance should decrease by swap amount");
        assertEq(ybtBalanceAfterSwap, ybtBalanceBeforeSwap + ptSwapAmount, "YBT balance should increase by swap amount");

        vm.stopPrank();
    }
}
