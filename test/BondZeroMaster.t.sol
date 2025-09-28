// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {BondZeroMaster} from "../src/BondZeroMaster.sol";
import {PrincipalToken} from "../src/PrincipalToken.sol";
import {YieldToken} from "../src/YieldToken.sol";
import {MockYieldBearingToken} from "../src/mocks/MockYieldBearingToken.sol";

contract BondZeroMasterTest is Test {
    BondZeroMaster public bondZeroMaster;
    MockERC20 public underlyingAsset;
    MockYieldBearingToken public yieldBearingToken;

    address public user1 = address(0x1);
    address public user2 = address(0x2);

    uint256 public constant INITIAL_SUPPLY = 1000000e18; // 1M tokens
    uint256 public constant INITIAL_APR = 1000; // 10% APR (in basis points: 1000 = 10%)
    uint256 public expiry;
    bytes32 public marketId;

    // Events
    event MarketCreated(
        bytes32 indexed marketId, address indexed yieldBearingToken, address indexed assetToken, uint256 expiry
    );
    event TokensDeposited(bytes32 indexed marketId, address indexed user, uint256 ybtAmount);
    event TokensRedeemed(bytes32 indexed marketId, address indexed user, uint256 ybtAmount);

    function setUp() public {
        // Deploy contracts
        bondZeroMaster = new BondZeroMaster();
        underlyingAsset = new MockERC20("USD Coin", "USDC", 18);
        yieldBearingToken = new MockYieldBearingToken("Staked USDC", "sUSDC", address(underlyingAsset), 1000); // 10% APR

        // Set expiry to 1 year from now
        expiry = block.timestamp + 365 days; // Setup initial balances
        underlyingAsset.mint(address(this), INITIAL_SUPPLY);
        underlyingAsset.mint(user1, INITIAL_SUPPLY);
        underlyingAsset.mint(user2, INITIAL_SUPPLY);

        // Allow yield bearing token to spend underlying assets
        underlyingAsset.approve(address(yieldBearingToken), type(uint256).max);

        vm.prank(user1);
        underlyingAsset.approve(address(yieldBearingToken), type(uint256).max);

        vm.prank(user2);
        underlyingAsset.approve(address(yieldBearingToken), type(uint256).max);

        // Create market
        bondZeroMaster.createBondMarket(address(yieldBearingToken), address(underlyingAsset), expiry, INITIAL_APR);
        marketId = keccak256(abi.encode(address(yieldBearingToken), address(underlyingAsset), expiry));
    }

    function testCreateBondMarket() public {
        uint256 newExpiry = block.timestamp + 180 days;
        uint256 newAPR = 800;

        vm.expectEmit(true, true, true, true);
        emit MarketCreated(
            keccak256(abi.encode(address(yieldBearingToken), address(underlyingAsset), newExpiry)),
            address(yieldBearingToken),
            address(underlyingAsset),
            newExpiry
        );

        bondZeroMaster.createBondMarket(address(yieldBearingToken), address(underlyingAsset), newExpiry, newAPR);

        BondZeroMaster.BondMarket memory market =
            bondZeroMaster.getBondMarket(address(yieldBearingToken), address(underlyingAsset), newExpiry);
        assertEq(market.yieldBearingToken, address(yieldBearingToken));
        assertEq(market.assetToken, address(underlyingAsset));
        assertEq(market.expiry, newExpiry);
        assertEq(market.initialApr, newAPR);
        assertFalse(market.principalToken == address(0));
        assertFalse(market.yieldToken == address(0));
    }

    function testCannotCreateDuplicateMarket() public {
        vm.expectRevert("already exists");
        bondZeroMaster.createBondMarket(address(yieldBearingToken), address(underlyingAsset), expiry, INITIAL_APR);
    }

    function testMintPtAndYt() public {
        uint256 depositAmount = 100e18;

        vm.startPrank(user1);
        uint256 ybtAmount = yieldBearingToken.deposit(depositAmount);
        yieldBearingToken.approve(address(bondZeroMaster), ybtAmount);

        bondZeroMaster.mintPtAndYt(marketId, ybtAmount);
        vm.stopPrank();

        BondZeroMaster.BondMarket memory market = bondZeroMaster.getBondMarket(marketId);
        PrincipalToken pt = PrincipalToken(market.principalToken);
        YieldToken yt = YieldToken(market.yieldToken);

        uint256 ptBalance = pt.balanceOf(user1);
        uint256 ytBalance = yt.balanceOf(user1);

        // Check that the value of PT + value of YT equals the deposited YBT
        uint256 ptPrice = bondZeroMaster.getPtPriceInYbt(marketId);
        uint256 ytPrice = bondZeroMaster.getYtPriceInYbt(marketId);
        uint256 ptValue = ptBalance * ptPrice / 1e18;
        uint256 ytValue = ytBalance * ytPrice / 1e18;
        assertEq(ptValue + ytValue, ybtAmount);

        assertEq(yieldBearingToken.balanceOf(address(bondZeroMaster)), ybtAmount);
    }

    function testCannotMintAfterExpiry() public {
        vm.warp(expiry + 1);

        uint256 depositAmount = 100e18;

        vm.startPrank(user1);
        uint256 ybtAmount = yieldBearingToken.deposit(depositAmount);
        yieldBearingToken.approve(address(bondZeroMaster), ybtAmount);

        vm.expectRevert("expired");
        bondZeroMaster.mintPtAndYt(marketId, ybtAmount);
        vm.stopPrank();
    }

    function testRedeemPtAndYt() public {
        uint256 depositAmount = 100e18;

        vm.startPrank(user1);
        uint256 ybtAmount = yieldBearingToken.deposit(depositAmount);
        yieldBearingToken.approve(address(bondZeroMaster), ybtAmount);
        bondZeroMaster.mintPtAndYt(marketId, ybtAmount);

        BondZeroMaster.BondMarket memory market = bondZeroMaster.getBondMarket(marketId);
        PrincipalToken pt = PrincipalToken(market.principalToken);
        YieldToken yt = YieldToken(market.yieldToken);

        uint256 initialPtBalance = pt.balanceOf(user1);
        uint256 initialYtBalance = yt.balanceOf(user1);

        uint256 initialPtValue = bondZeroMaster.getPtPriceInYbt(marketId) * initialPtBalance / 1e18;
        uint256 initialYtValue = bondZeroMaster.getYtPriceInYbt(marketId) * initialYtBalance / 1e18;

        skip(30 days);

        uint256 currentPtValue = bondZeroMaster.getPtPriceInYbt(marketId) * initialPtBalance / 1e18;
        uint256 currentYtValue = bondZeroMaster.getYtPriceInYbt(marketId) * initialYtBalance / 1e18;

        assertGt(currentPtValue, initialPtValue, "PT value should increase over time");
        assertLt(currentYtValue, initialYtValue, "YT value should decrease over time");

        uint256 redeemAmount = ybtAmount / 2;

        vm.expectEmit(true, true, true, true);
        emit TokensRedeemed(marketId, user1, redeemAmount);

        uint256 ybtBalanceBefore = yieldBearingToken.balanceOf(user1);
        bondZeroMaster.redeemPtAndYt(marketId, redeemAmount);
        uint256 ybtBalanceAfter = yieldBearingToken.balanceOf(user1);

        vm.stopPrank();

        // Core test: Redemption returns the correct amount of YBT
        assertEq(ybtBalanceAfter - ybtBalanceBefore, redeemAmount);

        // Verify PT and YT were burned as calculated
        uint256 remainingPtBalance = pt.balanceOf(user1);
        uint256 remainingYtBalance = yt.balanceOf(user1);

        assertEq(remainingPtBalance, initialPtBalance - redeemAmount);
        assertEq(remainingYtBalance, initialYtBalance - redeemAmount);
    }

    function testRedeemPtAndYtAfterExpiry() public {
        uint256 depositAmount = 100e18;

        vm.startPrank(user1);
        uint256 ybtAmount = yieldBearingToken.deposit(depositAmount);
        yieldBearingToken.approve(address(bondZeroMaster), ybtAmount);
        bondZeroMaster.mintPtAndYt(marketId, ybtAmount);

        BondZeroMaster.BondMarket memory market = bondZeroMaster.getBondMarket(marketId);
        PrincipalToken pt = PrincipalToken(market.principalToken);
        YieldToken yt = YieldToken(market.yieldToken);

        vm.stopPrank();

        vm.warp(expiry + 1);

        uint256 redeemAmount = ybtAmount;
        uint256 principalNeeded = redeemAmount;
        uint256 yieldNeeded = 0;

        vm.startPrank(user1);
        uint256 ybtBalanceBefore = yieldBearingToken.balanceOf(user1);
        bondZeroMaster.redeemPtAndYt(marketId, redeemAmount);
        uint256 ybtBalanceAfter = yieldBearingToken.balanceOf(user1);
        vm.stopPrank();

        assertEq(ybtBalanceAfter - ybtBalanceBefore, redeemAmount);
        assertEq(pt.balanceOf(user1), 0);
        assertGt(yt.balanceOf(user1), 0);
    }

    function testInsufficientBalanceRevert() public {
        uint256 depositAmount = 100e18;

        vm.startPrank(user1);
        uint256 ybtAmount = yieldBearingToken.deposit(depositAmount);
        yieldBearingToken.approve(address(bondZeroMaster), ybtAmount);
        bondZeroMaster.mintPtAndYt(marketId, ybtAmount);

        // Try to redeem more than deposited
        uint256 excessiveRedeemAmount = ybtAmount * 2;

        vm.expectRevert();
        bondZeroMaster.redeemPtAndYt(marketId, excessiveRedeemAmount);
        vm.stopPrank();
    }

    function testMarketDoesNotExistRevert() public {
        bytes32 nonExistentMarketId = keccak256("nonexistent");

        vm.expectRevert("!exist");
        bondZeroMaster.mintPtAndYt(nonExistentMarketId, 100e18);

        vm.expectRevert("!exist");
        bondZeroMaster.redeemPtAndYt(nonExistentMarketId, 100e18);
    }

    /**
     * @dev Complete end-to-end test case covering the full user journey: via BondZeroMaster
     * 1. User receives underlying assets (USDC)
     * 2. User deposits USDC to get yield-bearing tokens (sUSDC)
     * 3. User deposits sUSDC to BondZeroMaster to mint PT and YT
     * 4. Time progresses, yield accrues
     * 5. Market expires
     * 6. User redeems PT tokens for the underlying yield-bearing tokens after expiry
     */
    function testFullUserJourneyBondZeroMaster() public {
        // === STEP 1: Setup user with initial assets ===
        address testUser = address(0x999);
        uint256 initialAssetAmount = 1000e18; // 1000 USDC

        // Give user initial underlying assets
        underlyingAsset.mint(testUser, initialAssetAmount);

        // Verify user has underlying assets
        assertEq(underlyingAsset.balanceOf(testUser), initialAssetAmount, "User should have initial USDC");

        vm.startPrank(testUser);

        // === STEP 2: User mints yield-bearing tokens ===
        console2.log("=== STEP 2: Minting Yield-Bearing Tokens ===");

        // Approve and deposit underlying assets to get yield-bearing tokens
        underlyingAsset.approve(address(yieldBearingToken), initialAssetAmount);
        uint256 ybtMinted = yieldBearingToken.deposit(initialAssetAmount);

        uint256 userYbtBalance = yieldBearingToken.balanceOf(testUser);
        console2.log("User YBT balance after deposit:", userYbtBalance);
        console2.log("YBT minted amount:", ybtMinted);

        // Verify user received YBT tokens
        assertEq(userYbtBalance, ybtMinted, "User should have received YBT tokens");
        assertGt(ybtMinted, 0, "Should have minted some YBT tokens");

        // === STEP 3: User deposits to bond market and mints PT/YT ===
        console2.log("=== STEP 3: Depositing to Bond Market ===");

        uint256 depositAmount = ybtMinted; // Deposit all YBT tokens

        // Approve BondZeroMaster to spend YBT
        yieldBearingToken.approve(address(bondZeroMaster), depositAmount);

        // Get market info before minting
        BondZeroMaster.BondMarket memory market = bondZeroMaster.getBondMarket(marketId);
        PrincipalToken pt = PrincipalToken(market.principalToken);
        YieldToken yt = YieldToken(market.yieldToken);

        // Record initial balances
        uint256 initialPtBalance = pt.balanceOf(testUser);
        uint256 initialYtBalance = yt.balanceOf(testUser);

        // Get initial prices
        uint256 initialPtPrice = bondZeroMaster.getPtPriceInYbt(marketId);
        uint256 initialYtPrice = bondZeroMaster.getYtPriceInYbt(marketId);

        console2.log("Initial PT price:", initialPtPrice);
        console2.log("Initial YT price:", initialYtPrice);
        console2.log("Initial PT + YT price:", initialPtPrice + initialYtPrice);

        // Expect TokensDeposited event
        vm.expectEmit(true, true, false, true);
        emit TokensDeposited(marketId, testUser, depositAmount);

        // Mint PT and YT tokens
        bondZeroMaster.mintPtAndYt(marketId, depositAmount);

        // Verify PT and YT were minted
        uint256 ptBalance = pt.balanceOf(testUser);
        uint256 ytBalance = yt.balanceOf(testUser);

        console2.log("PT balance after minting:", ptBalance);
        console2.log("YT balance after minting:", ytBalance);

        assertEq(ptBalance, initialPtBalance + depositAmount, "Should have minted PT tokens equal to deposit");
        assertEq(ytBalance, initialYtBalance + depositAmount, "Should have minted YT tokens equal to deposit");
        assertEq(yieldBearingToken.balanceOf(testUser), 0, "User should have no YBT left");
        assertEq(yieldBearingToken.balanceOf(address(bondZeroMaster)), depositAmount, "BondZeroMaster should hold YBT");

        // Verify PT + YT value equals deposited amount
        uint256 ptValue = ptBalance * initialPtPrice / 1e18;
        uint256 ytValue = ytBalance * initialYtPrice / 1e18;
        assertEq(ptValue + ytValue, depositAmount, "PT + YT value should equal deposited YBT");

        // === STEP 4: Time progression and yield accrual ===
        console2.log("=== STEP 4: Time Progression and Yield Accrual ===");

        // Move time forward by 6 months
        uint256 timeSkip = 180 days;
        skip(timeSkip);

        // Check price evolution
        uint256 midPtPrice = bondZeroMaster.getPtPriceInYbt(marketId);
        uint256 midYtPrice = bondZeroMaster.getYtPriceInYbt(marketId);

        console2.log("PT price after 6 months:", midPtPrice);
        console2.log("YT price after 6 months:", midYtPrice);

        // PT price should increase (approaching 1 as maturity approaches)
        assertGt(midPtPrice, initialPtPrice, "PT price should increase over time");
        // YT price should decrease (approaching 0 as maturity approaches)
        assertLt(midYtPrice, initialYtPrice, "YT price should decrease over time");
        // Sum should still equal 1 YBT
        assertEq(midPtPrice + midYtPrice, 1e18, "PT + YT price should always equal 1 YBT");

        // === STEP 5: Market expiry ===
        console2.log("=== STEP 5: Market Expiry ===");

        // Move to expiry time
        vm.warp(expiry + 1);

        uint256 expiredPtPrice = bondZeroMaster.getPtPriceInYbt(marketId);
        uint256 expiredYtPrice = bondZeroMaster.getYtPriceInYbt(marketId);

        console2.log("PT price after expiry:", expiredPtPrice);
        console2.log("YT price after expiry:", expiredYtPrice);

        // After expiry, PT should be worth 1 YBT and YT should be worthless
        assertEq(expiredPtPrice, 1e18, "PT should be worth 1 YBT after expiry");
        assertEq(expiredYtPrice, 0, "YT should be worthless after expiry");

        // === STEP 6: Redemption after expiry ===
        console2.log("=== STEP 6: Redemption After Expiry ===");

        uint256 redeemAmount = depositAmount; // Redeem all deposited amount

        // Record balances before redemption
        uint256 ybtBalanceBefore = yieldBearingToken.balanceOf(testUser);
        uint256 ptBalanceBefore = pt.balanceOf(testUser);
        uint256 ytBalanceBefore = yt.balanceOf(testUser);

        console2.log("YBT balance before redemption:", ybtBalanceBefore);
        console2.log("PT balance before redemption:", ptBalanceBefore);
        console2.log("YT balance before redemption:", ytBalanceBefore);

        // Expect TokensRedeemed event
        vm.expectEmit(true, true, false, true);
        emit TokensRedeemed(marketId, testUser, redeemAmount);

        // Redeem PT (and potentially YT) for YBT after expiry
        bondZeroMaster.redeemPtAndYt(marketId, redeemAmount);

        // Record balances after redemption
        uint256 ybtBalanceAfter = yieldBearingToken.balanceOf(testUser);
        uint256 ptBalanceAfter = pt.balanceOf(testUser);
        uint256 ytBalanceAfter = yt.balanceOf(testUser);

        console2.log("YBT balance after redemption:", ybtBalanceAfter);
        console2.log("PT balance after redemption:", ptBalanceAfter);
        console2.log("YT balance after redemption:", ytBalanceAfter);

        // === FINAL VERIFICATIONS ===
        console2.log("=== FINAL VERIFICATIONS ===");

        // User should have received YBT back
        assertEq(ybtBalanceAfter - ybtBalanceBefore, redeemAmount, "User should receive YBT equal to redeemed amount");

        // PT should be burned (only PT is needed after expiry)
        assertEq(ptBalanceBefore - ptBalanceAfter, redeemAmount, "PT should be burned equal to redeemed amount");

        // YT should remain unchanged (not needed for redemption after expiry)
        assertEq(ytBalanceAfter, ytBalanceBefore, "YT balance should remain unchanged after expiry redemption");

        // User should have gotten back their original YBT amount
        assertEq(ybtBalanceAfter, depositAmount, "User should have original deposited YBT amount");

        vm.stopPrank();

        // === STEP 7: Optional - User can convert YBT back to underlying assets ===
        console2.log("=== STEP 7: Converting YBT back to underlying assets ===");

        vm.prank(testUser);
        uint256 assetsReceived = yieldBearingToken.withdraw(ybtBalanceAfter);

        uint256 finalAssetBalance = underlyingAsset.balanceOf(testUser);

        console2.log("Assets received from YBT withdrawal:", assetsReceived);
        console2.log("Final user asset balance:", finalAssetBalance);

        // User should have received at least their initial amount (potentially more due to yield)
        assertGe(finalAssetBalance, initialAssetAmount, "User should have at least initial asset amount");
        assertEq(finalAssetBalance, assetsReceived, "Final balance should equal withdrawn assets");

        console2.log("=== USER JOURNEY COMPLETED SUCCESSFULLY ===");
        console2.log(
            "Total yield earned:", finalAssetBalance > initialAssetAmount ? finalAssetBalance - initialAssetAmount : 0
        );
    }
}
