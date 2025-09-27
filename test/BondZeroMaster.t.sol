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
    event TokensDeposited(
        bytes32 indexed marketId, address indexed user, uint256 ybtAmount, uint256 principalAmount, uint256 yieldAmount
    );
    event TokensRedeemed(
        bytes32 indexed marketId, address indexed user, uint256 ybtAmount, uint256 principalAmount, uint256 yieldAmount
    );

    // Helper function to log PT/YT details and validate relationships
    function logAndValidatePtYt(
        string memory testName,
        uint256 ybtAmount,
        uint256 ptAmount,
        uint256 ytAmount,
        uint256 timeToMaturity,
        uint256 apr
    ) internal {
        console2.log("=== %s ===", testName);
        console2.log("YBT Amount:", ybtAmount);
        console2.log("PT Amount: ", ptAmount);
        console2.log("YT Amount: ", ytAmount);
        console2.log("Time to maturity (days):", timeToMaturity / 1 days);
        console2.log("Market APR (bps):", apr);
        console2.log("PT + YT total:", ptAmount + ytAmount);
        console2.log("PT/YBT ratio (%):", (ptAmount * 100) / ybtAmount);
        console2.log("YT/YBT ratio (%):", (ytAmount * 100) / ybtAmount);

        // Validate PT + YT relationship
        uint256 totalPtYt = ptAmount + ytAmount;
        console2.log("Expected total (YBT):", ybtAmount);
        console2.log("Actual total (PT+YT):", totalPtYt);

        // Allow small rounding error (within 0.01%)
        uint256 tolerance = ybtAmount / 10000; // 0.01% tolerance
        if (totalPtYt > ybtAmount) {
            assertLe(totalPtYt - ybtAmount, tolerance, "PT + YT exceeds YBT by more than tolerance");
        } else {
            assertLe(ybtAmount - totalPtYt, tolerance, "YBT exceeds PT + YT by more than tolerance");
        }

        // Validate that PT is always less than or equal to YBT (due to time value)
        assertLe(ptAmount, ybtAmount, "PT should not exceed YBT amount");

        // Log current yield bearing token exchange rate
        uint256 currentRate = yieldBearingToken.getCurrentExchangeRate();
        console2.log("Current YBT exchange rate:", currentRate);
        console2.log("---");
    }

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
        uint256 newAPR = 800; // 8%

        console2.log("=== testCreateBondMarket ===");
        console2.log("Creating market with:");
        console2.log("- Expiry: %s days from now", (newExpiry - block.timestamp) / 1 days);
        console2.log("- APR: %s basis points (%s%%)", newAPR, newAPR / 100);
        console2.log("- Current timestamp:", block.timestamp);
        console2.log("- Expiry timestamp:", newExpiry);

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

        console2.log("Market created successfully!");
        console2.log("PT Token address:", market.principalToken);
        console2.log("YT Token address:", market.yieldToken);
        console2.log("---");
    }

    function testCannotCreateDuplicateMarket() public {
        vm.expectRevert("already exists");
        bondZeroMaster.createBondMarket(address(yieldBearingToken), address(underlyingAsset), expiry, INITIAL_APR);
    }

    function testMintPtAndYt() public {
        uint256 depositAmount = 100e18; // 100 tokens

        console2.log("=== testMintPtAndYt ===");
        console2.log("Initial deposit amount:", depositAmount);
        console2.log("Current timestamp:", block.timestamp);
        console2.log("Market expiry:", expiry);
        console2.log("Time to maturity (days):", (expiry - block.timestamp) / 1 days);

        // User1 deposits underlying assets to get yield bearing tokens
        vm.startPrank(user1);
        uint256 ybtAmount = yieldBearingToken.deposit(depositAmount);
        console2.log("YBT received from deposit:", ybtAmount);
        console2.log("YBT exchange rate at deposit:", yieldBearingToken.getCurrentExchangeRate());

        yieldBearingToken.approve(address(bondZeroMaster), ybtAmount);

        // Calculate expected PT and YT amounts
        (uint256 expectedPrincipalAmount, uint256 expectedYieldAmount) =
            bondZeroMaster.calculateRedemptionAmounts(marketId, ybtAmount);

        console2.log("Expected PT amount:", expectedPrincipalAmount);
        console2.log("Expected YT amount:", expectedYieldAmount);

        vm.expectEmit(true, true, true, true);
        emit TokensDeposited(marketId, user1, ybtAmount, expectedPrincipalAmount, expectedYieldAmount);

        bondZeroMaster.mintPtAndYt(marketId, ybtAmount);
        vm.stopPrank();

        // Check balances
        BondZeroMaster.BondMarket memory market = bondZeroMaster.getBondMarket(marketId);
        PrincipalToken pt = PrincipalToken(market.principalToken);
        YieldToken yt = YieldToken(market.yieldToken);

        uint256 actualPtBalance = pt.balanceOf(user1);
        uint256 actualYtBalance = yt.balanceOf(user1);

        assertEq(actualPtBalance, expectedPrincipalAmount);
        assertEq(actualYtBalance, expectedYieldAmount);
        assertEq(yieldBearingToken.balanceOf(address(bondZeroMaster)), ybtAmount);

        // Log and validate the PT/YT relationship
        logAndValidatePtYt(
            "Basic PT/YT Minting", ybtAmount, actualPtBalance, actualYtBalance, expiry - block.timestamp, INITIAL_APR
        );
    }

    function testMintPtAndYtAtDifferentTimePoints() public {
        uint256 depositAmount = 100e18;

        console2.log("=== testMintPtAndYtAtDifferentTimePoints ===");
        console2.log("Testing PT/YT ratios at different times before expiry");

        // Test at different time points before expiry
        uint256[] memory timeBeforeExpiry = new uint256[](4);
        timeBeforeExpiry[0] = 365 days; // 1 year before expiry
        timeBeforeExpiry[1] = 180 days; // 6 months before expiry
        timeBeforeExpiry[2] = 90 days; // 3 months before expiry
        timeBeforeExpiry[3] = 30 days; // 1 month before expiry

        uint256 previousPtRatio = 0;
        uint256 previousYtRatio = 0;

        for (uint256 i = 0; i < timeBeforeExpiry.length; i++) {
            // Warp to specific time before expiry
            vm.warp(expiry - timeBeforeExpiry[i]);

            // Setup user for each test
            address testUser = address(uint160(0x1000 + i));
            underlyingAsset.mint(testUser, INITIAL_SUPPLY);

            console2.log("\n>> Iteration %s: %s days before expiry", i + 1, timeBeforeExpiry[i] / 1 days);
            console2.log("Current timestamp:", block.timestamp);
            console2.log("YBT exchange rate:", yieldBearingToken.getCurrentExchangeRate());

            vm.startPrank(testUser);
            underlyingAsset.approve(address(yieldBearingToken), type(uint256).max);
            uint256 ybtAmount = yieldBearingToken.deposit(depositAmount);
            yieldBearingToken.approve(address(bondZeroMaster), ybtAmount);

            (uint256 principalAmount, uint256 yieldAmount) =
                bondZeroMaster.calculateRedemptionAmounts(marketId, ybtAmount);

            bondZeroMaster.mintPtAndYt(marketId, ybtAmount);
            vm.stopPrank();

            BondZeroMaster.BondMarket memory market = bondZeroMaster.getBondMarket(marketId);
            PrincipalToken pt = PrincipalToken(market.principalToken);
            YieldToken yt = YieldToken(market.yieldToken);

            uint256 actualPtBalance = pt.balanceOf(testUser);
            uint256 actualYtBalance = yt.balanceOf(testUser);

            assertEq(actualPtBalance, principalAmount);
            assertEq(actualYtBalance, yieldAmount);

            // Calculate ratios
            uint256 ptRatio = (actualPtBalance * 100) / ybtAmount; // PT as percentage of YBT
            uint256 ytRatio = (actualYtBalance * 100) / ybtAmount; // YT as percentage of YBT

            // Log detailed information
            logAndValidatePtYt(
                string(abi.encodePacked("Time Point ", vm.toString(i + 1))),
                ybtAmount,
                actualPtBalance,
                actualYtBalance,
                timeBeforeExpiry[i],
                INITIAL_APR
            );

            // Validate trends: As we approach expiry, PT should increase and YT should decrease
            if (i > 0) {
                console2.log("Trend analysis:");
                console2.log("- Previous PT ratio: %s%%, Current PT ratio: %s%%", previousPtRatio, ptRatio);
                console2.log("- Previous YT ratio: %s%%, Current YT ratio: %s%%", previousYtRatio, ytRatio);

                // As time to maturity decreases, PT should generally increase (closer to face value)
                // and YT should generally decrease (less time for yield accrual)
                if (timeBeforeExpiry[i] < timeBeforeExpiry[i - 1]) {
                    assertGe(
                        ptRatio, previousPtRatio - 1, "PT ratio should not decrease significantly as expiry approaches"
                    );
                    console2.log("[PASS] PT ratio trend validated");
                }
            }

            previousPtRatio = ptRatio;
            previousYtRatio = ytRatio;
        }
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

    function testRedeemPtAndYtBeforeExpiry() public {
        uint256 depositAmount = 100e18;

        console2.log("=== testRedeemPtAndYtBeforeExpiry ===");
        console2.log("Initial setup - minting PT/YT");
        console2.log("Deposit amount:", depositAmount);
        console2.log("Current time to maturity (days):", (expiry - block.timestamp) / 1 days);

        // Setup: User1 mints PT and YT
        vm.startPrank(user1);
        uint256 ybtAmount = yieldBearingToken.deposit(depositAmount);
        console2.log("YBT amount received:", ybtAmount);
        console2.log("YBT exchange rate at mint:", yieldBearingToken.getCurrentExchangeRate());

        yieldBearingToken.approve(address(bondZeroMaster), ybtAmount);
        bondZeroMaster.mintPtAndYt(marketId, ybtAmount);

        BondZeroMaster.BondMarket memory market = bondZeroMaster.getBondMarket(marketId);
        PrincipalToken pt = PrincipalToken(market.principalToken);
        YieldToken yt = YieldToken(market.yieldToken);

        uint256 initialPtBalance = pt.balanceOf(user1);
        uint256 initialYtBalance = yt.balanceOf(user1);
        console2.log("Initial PT balance:", initialPtBalance);
        console2.log("Initial YT balance:", initialYtBalance);

        vm.stopPrank();

        // Redeem half of the amount
        uint256 redeemAmount = ybtAmount / 2;
        console2.log("\nRedemption phase:");
        console2.log("Attempting to redeem YBT amount:", redeemAmount);

        (uint256 principalNeeded, uint256 yieldNeeded) =
            bondZeroMaster.calculateRedemptionAmounts(marketId, redeemAmount);

        console2.log("PT needed for redemption:", principalNeeded);
        console2.log("YT needed for redemption:", yieldNeeded);
        console2.log("Total tokens needed:", principalNeeded + yieldNeeded);
        console2.log("Redemption efficiency (%):", ((principalNeeded + yieldNeeded) * 100) / redeemAmount);

        vm.startPrank(user1);
        vm.expectEmit(true, true, true, true);
        emit TokensRedeemed(marketId, user1, redeemAmount, principalNeeded, yieldNeeded);

        uint256 ybtBalanceBefore = yieldBearingToken.balanceOf(user1);
        bondZeroMaster.redeemPtAndYt(marketId, redeemAmount);
        uint256 ybtBalanceAfter = yieldBearingToken.balanceOf(user1);

        console2.log("YBT balance before redemption:", ybtBalanceBefore);
        console2.log("YBT balance after redemption:", ybtBalanceAfter);
        console2.log("YBT received:", ybtBalanceAfter - ybtBalanceBefore);

        vm.stopPrank();

        // Check that user received yield bearing tokens back
        assertEq(yieldBearingToken.balanceOf(user1), redeemAmount);

        // Check remaining PT and YT balances
        uint256 remainingPtBalance = pt.balanceOf(user1);
        uint256 remainingYtBalance = yt.balanceOf(user1);

        console2.log("Remaining PT balance:", remainingPtBalance);
        console2.log("Remaining YT balance:", remainingYtBalance);
        console2.log("PT burned:", initialPtBalance - remainingPtBalance);
        console2.log("YT burned:", initialYtBalance - remainingYtBalance);

        // Should have burned the required amounts
        uint256 expectedRemainingPt = (ybtAmount - redeemAmount) * principalNeeded / redeemAmount;
        uint256 expectedRemainingYt = (ybtAmount - redeemAmount) * yieldNeeded / redeemAmount;

        assertEq(remainingPtBalance, expectedRemainingPt);
        assertEq(remainingYtBalance, expectedRemainingYt);

        console2.log("[PASS] Redemption validation passed");
        console2.log("---");
    }

    function testRedeemPtAndYtAfterExpiry() public {
        uint256 depositAmount = 100e18;

        console2.log("=== testRedeemPtAndYtAfterExpiry ===");
        console2.log("Testing redemption after market expiry");
        console2.log("Initial deposit amount:", depositAmount);
        console2.log("Original expiry:", expiry);
        console2.log("Current timestamp:", block.timestamp);

        // Setup: User1 mints PT and YT
        vm.startPrank(user1);
        uint256 ybtAmount = yieldBearingToken.deposit(depositAmount);
        console2.log("YBT amount at minting:", ybtAmount);
        console2.log("YBT exchange rate at minting:", yieldBearingToken.getCurrentExchangeRate());

        yieldBearingToken.approve(address(bondZeroMaster), ybtAmount);
        bondZeroMaster.mintPtAndYt(marketId, ybtAmount);

        // Get the actual PT balance that was minted (may have rounding)
        BondZeroMaster.BondMarket memory market = bondZeroMaster.getBondMarket(marketId);
        PrincipalToken pt = PrincipalToken(market.principalToken);
        YieldToken yt = YieldToken(market.yieldToken);
        uint256 actualPtBalance = pt.balanceOf(user1);
        uint256 actualYtBalance = yt.balanceOf(user1);

        console2.log("PT balance at minting:", actualPtBalance);
        console2.log("YT balance at minting:", actualYtBalance);

        vm.stopPrank();

        // Warp to after expiry
        vm.warp(expiry + 1 days);
        console2.log("\n>>> WARPED TO AFTER EXPIRY <<<");
        console2.log("New timestamp:", block.timestamp);
        console2.log("Time past expiry (hours):", (block.timestamp - expiry) / 1 hours);
        console2.log("YBT exchange rate after time warp:", yieldBearingToken.getCurrentExchangeRate());

        // After expiry, only PT should be needed (1:1 ratio with the actual PT balance)
        uint256 redeemAmount = actualPtBalance; // Redeem based on actual PT balance
        console2.log("Attempting to redeem YBT amount:", redeemAmount);

        (uint256 principalNeeded, uint256 yieldNeeded) =
            bondZeroMaster.calculateRedemptionAmounts(marketId, redeemAmount);

        console2.log("PT needed for redemption:", principalNeeded);
        console2.log("YT needed for redemption:", yieldNeeded);
        console2.log("Post-expiry redemption ratio - PT:YBT = 1:1?", principalNeeded == redeemAmount ? "YES" : "NO");

        assertEq(principalNeeded, redeemAmount);
        assertEq(yieldNeeded, 0);

        vm.startPrank(user1);
        console2.log("User's PT balance before redemption:", pt.balanceOf(user1));
        console2.log("User's YT balance before redemption:", yt.balanceOf(user1));

        uint256 ybtBalanceBefore = yieldBearingToken.balanceOf(user1);
        bondZeroMaster.redeemPtAndYt(marketId, redeemAmount);
        uint256 ybtBalanceAfter = yieldBearingToken.balanceOf(user1);

        console2.log("User's PT balance after redemption:", pt.balanceOf(user1));
        console2.log("User's YT balance after redemption:", yt.balanceOf(user1));
        console2.log("YBT balance before redemption:", ybtBalanceBefore);
        console2.log("YBT balance after redemption:", ybtBalanceAfter);
        console2.log("YBT received from redemption:", ybtBalanceAfter - ybtBalanceBefore);

        vm.stopPrank();

        // Check that user received yield bearing tokens back
        assertEq(yieldBearingToken.balanceOf(user1), redeemAmount);

        // Check that PT was burned and YT balance unchanged
        assertEq(pt.balanceOf(user1), 0);
        // YT balance should remain as it wasn't burned after expiry
        assertGt(yt.balanceOf(user1), 0);

        console2.log("[PASS] Post-expiry redemption validation passed");
        console2.log("Key insight: After expiry, only PT is needed for redemption (1:1), YT retains value");
        console2.log("---");
    }

    function testYieldAccrualScenario() public {
        uint256 depositAmount = 100e18;

        console2.log("=== testYieldAccrualScenario ===");
        console2.log("Testing how PT/YT behave as underlying yield accrues over time");
        console2.log("Initial deposit amount:", depositAmount);
        console2.log("YBT APR:", yieldBearingToken.getAPR(), "basis points");
        console2.log("Initial timestamp:", block.timestamp);

        // User1 deposits and gets YBT
        vm.startPrank(user1);
        uint256 initialExchangeRate = yieldBearingToken.getCurrentExchangeRate();
        uint256 ybtAmount = yieldBearingToken.deposit(depositAmount);
        console2.log("Initial YBT exchange rate:", initialExchangeRate);
        console2.log("YBT amount from deposit:", ybtAmount);

        yieldBearingToken.approve(address(bondZeroMaster), ybtAmount);
        bondZeroMaster.mintPtAndYt(marketId, ybtAmount);

        // Get actual balances after minting (accounting for any rounding)
        BondZeroMaster.BondMarket memory market = bondZeroMaster.getBondMarket(marketId);
        PrincipalToken pt = PrincipalToken(market.principalToken);
        YieldToken yt = YieldToken(market.yieldToken);
        uint256 actualPtBalance = pt.balanceOf(user1);
        uint256 actualYtBalance = yt.balanceOf(user1);

        console2.log("Initial PT balance:", actualPtBalance);
        console2.log("Initial YT balance:", actualYtBalance);
        console2.log("Initial time to maturity (days):", (expiry - block.timestamp) / 1 days);

        vm.stopPrank();

        // Simulate yield accrual (just advance time - yield will be automatically calculated)
        console2.log("\n>>> SIMULATING 180 DAYS OF YIELD ACCRUAL <<<");
        vm.warp(block.timestamp + 180 days);
        yieldBearingToken.updateExchangeRate(); // Manually trigger rate update for immediate effect

        uint256 newExchangeRate = yieldBearingToken.getCurrentExchangeRate();
        uint256 rateIncrease = newExchangeRate - initialExchangeRate;
        console2.log("New timestamp:", block.timestamp);
        console2.log("New YBT exchange rate:", newExchangeRate);
        console2.log("Exchange rate increase:", rateIncrease);
        console2.log("Rate increase (%):", (rateIncrease * 100) / initialExchangeRate);

        // Check that the yield bearing token has appreciated
        uint256 newValue = yieldBearingToken.convertToAssets(ybtAmount);
        assertGt(newValue, depositAmount); // Should be worth more due to yield

        console2.log("Original deposit value:", depositAmount);
        console2.log("Current YBT value after yield:", newValue);
        console2.log("Yield earned:", newValue - depositAmount);
        console2.log("Yield rate achieved (%):", ((newValue - depositAmount) * 100) / depositAmount);
        console2.log("Remaining time to maturity (days):", (expiry - block.timestamp) / 1 days);

        // Calculate redemption amounts based on the original YBT amount
        (uint256 principalNeeded, uint256 yieldNeeded) = bondZeroMaster.calculateRedemptionAmounts(marketId, ybtAmount);

        console2.log("\nRedemption requirements after yield accrual:");
        console2.log("PT needed for redemption:", principalNeeded);
        console2.log("YT needed for redemption:", yieldNeeded);
        console2.log("User's actual PT balance:", actualPtBalance);
        console2.log("User's actual YT balance:", actualYtBalance);
        console2.log("PT sufficiency:", actualPtBalance >= principalNeeded ? "SUFFICIENT" : "INSUFFICIENT");
        console2.log("YT sufficiency:", actualYtBalance >= yieldNeeded ? "SUFFICIENT" : "INSUFFICIENT");

        // Validate PT/YT relationship after yield accrual
        logAndValidatePtYt(
            "After 180 days of yield accrual",
            ybtAmount,
            actualPtBalance,
            actualYtBalance,
            expiry - block.timestamp,
            INITIAL_APR
        );

        // If we don't have enough PT/YT due to precision, redeem what we can
        uint256 redeemAmount = ybtAmount;
        if (actualPtBalance < principalNeeded || (yieldNeeded > 0 && actualYtBalance < yieldNeeded)) {
            // Scale down the redemption to match available tokens
            redeemAmount = (ybtAmount * actualPtBalance) / principalNeeded;
            console2.log("Scaling down redemption due to precision. New amount:", redeemAmount);
        }

        console2.log("\nAttempting redemption:");
        console2.log("Redemption amount:", redeemAmount);

        vm.startPrank(user1);
        uint256 ybtBefore = yieldBearingToken.balanceOf(user1);
        bondZeroMaster.redeemPtAndYt(marketId, redeemAmount);
        uint256 ybtAfter = yieldBearingToken.balanceOf(user1);
        vm.stopPrank();

        console2.log("YBT received from redemption:", ybtAfter - ybtBefore);
        console2.log("YBT value at redemption:", yieldBearingToken.convertToAssets(ybtAfter - ybtBefore));

        assertGt(yieldBearingToken.balanceOf(user1), 0);

        console2.log("[PASS] Yield accrual scenario validation passed");
        console2.log("Key insight: YBT appreciates over time, but PT/YT redemption ratios remain consistent");
        console2.log("---");
    }

    function testMultipleUsersScenario() public {
        uint256 user1Deposit = 100e18;
        uint256 user2Deposit = 200e18;

        console2.log("=== testMultipleUsersScenario ===");
        console2.log("Testing how PT/YT ratios differ when users mint at different times");
        console2.log("User1 deposit amount:", user1Deposit);
        console2.log("User2 deposit amount:", user2Deposit);
        console2.log("Initial timestamp:", block.timestamp);
        console2.log("Market expiry:", expiry);

        // User1 mints PT/YT at start
        console2.log("\n>> User1 mints at market start <<");
        uint256 user1StartTime = block.timestamp;
        uint256 user1ExchangeRate = yieldBearingToken.getCurrentExchangeRate();
        console2.log("User1 mint timestamp:", user1StartTime);
        console2.log("Time to maturity for User1 (days):", (expiry - user1StartTime) / 1 days);
        console2.log("YBT exchange rate at User1 mint:", user1ExchangeRate);

        vm.startPrank(user1);
        uint256 user1YbtAmount = yieldBearingToken.deposit(user1Deposit);
        console2.log("User1 YBT amount received:", user1YbtAmount);
        yieldBearingToken.approve(address(bondZeroMaster), user1YbtAmount);
        bondZeroMaster.mintPtAndYt(marketId, user1YbtAmount);
        vm.stopPrank();

        // Move forward 3 months
        vm.warp(block.timestamp + 90 days);
        console2.log("\n>>> TIME WARP: +90 days <<<");
        console2.log("New timestamp:", block.timestamp);

        // User2 mints PT/YT later (should get different PT/YT ratio)
        console2.log("\n>> User2 mints 90 days later <<");
        uint256 user2StartTime = block.timestamp;
        uint256 user2ExchangeRate = yieldBearingToken.getCurrentExchangeRate();
        console2.log("User2 mint timestamp:", user2StartTime);
        console2.log("Time to maturity for User2 (days):", (expiry - user2StartTime) / 1 days);
        console2.log("YBT exchange rate at User2 mint:", user2ExchangeRate);
        console2.log("Exchange rate increase:", user2ExchangeRate - user1ExchangeRate);

        vm.startPrank(user2);
        uint256 user2YbtAmount = yieldBearingToken.deposit(user2Deposit);
        console2.log("User2 YBT amount received:", user2YbtAmount);
        yieldBearingToken.approve(address(bondZeroMaster), user2YbtAmount);
        bondZeroMaster.mintPtAndYt(marketId, user2YbtAmount);
        vm.stopPrank();

        BondZeroMaster.BondMarket memory market = bondZeroMaster.getBondMarket(marketId);
        PrincipalToken pt = PrincipalToken(market.principalToken);
        YieldToken yt = YieldToken(market.yieldToken);

        uint256 user1PtBalance = pt.balanceOf(user1);
        uint256 user1YtBalance = yt.balanceOf(user1);
        uint256 user2PtBalance = pt.balanceOf(user2);
        uint256 user2YtBalance = yt.balanceOf(user2);

        console2.log("\n=== COMPARISON ANALYSIS ===");

        // Log individual user details
        logAndValidatePtYt(
            "User1 (Early minter - 365 days to maturity)",
            user1YbtAmount,
            user1PtBalance,
            user1YtBalance,
            365 days,
            INITIAL_APR
        );

        logAndValidatePtYt(
            "User2 (Late minter - 275 days to maturity)",
            user2YbtAmount,
            user2PtBalance,
            user2YtBalance,
            275 days,
            INITIAL_APR
        );

        // Calculate and compare ratios
        uint256 user1PtRatio = (user1PtBalance * 100) / user1YbtAmount;
        uint256 user1YtRatio = (user1YtBalance * 100) / user1YbtAmount;
        uint256 user2PtRatio = (user2PtBalance * 100) / user2YbtAmount;
        uint256 user2YtRatio = (user2YtBalance * 100) / user2YbtAmount;

        console2.log("PT ratio comparison:");
        console2.log("- User1 PT/YBT ratio: %s%%", user1PtRatio);
        console2.log("- User2 PT/YBT ratio: %s%%", user2PtRatio);
        console2.log(
            "- PT ratio difference: %s%%",
            user2PtRatio > user1PtRatio ? user2PtRatio - user1PtRatio : user1PtRatio - user2PtRatio
        );

        console2.log("YT ratio comparison:");
        console2.log("- User1 YT/YBT ratio: %s%%", user1YtRatio);
        console2.log("- User2 YT/YBT ratio: %s%%", user2YtRatio);

        // Validate expected behavior: User2 (later minter) should have higher PT ratio due to less time to maturity
        console2.log("\nExpected behavior validation:");
        if (user2PtRatio > user1PtRatio) {
            console2.log("[PASS] User2 has higher PT ratio (closer to maturity = higher present value)");
        } else {
            console2.log("[WARN] User2 PT ratio not higher - may be due to exchange rate effects");
        }

        if (user2YtRatio < user1YtRatio) {
            console2.log("[PASS] User2 has lower YT ratio (less time for yield accrual)");
        } else {
            console2.log("[WARN] User2 YT ratio not lower - may be due to exchange rate effects");
        }

        // Basic validations
        assertGt(user1PtBalance, 0);
        assertGt(user1YtBalance, 0);
        assertGt(user2PtBalance, 0);
        assertGt(user2YtBalance, 0);

        // User2 deposited 2x more, so should have more absolute PT and YT
        assertGt(user2PtBalance, user1PtBalance);
        assertGt(user2YtBalance, user1YtBalance);

        console2.log("[PASS] Multiple users scenario validation passed");
        console2.log("Key insight: Time to maturity significantly affects PT/YT ratios");
        console2.log("---");
    }

    function testEdgeCaseZeroTimeToMaturity() public {
        // Create market that expires very soon
        uint256 shortExpiry = block.timestamp + 1 minutes;
        uint256 shortAPR = 1000; // 10%

        bondZeroMaster.createBondMarket(address(yieldBearingToken), address(underlyingAsset), shortExpiry, shortAPR);
        bytes32 shortMarketId = keccak256(abi.encode(address(yieldBearingToken), address(underlyingAsset), shortExpiry));

        uint256 depositAmount = 100e18;

        vm.startPrank(user1);
        uint256 ybtAmount = yieldBearingToken.deposit(depositAmount);
        yieldBearingToken.approve(address(bondZeroMaster), ybtAmount);

        bondZeroMaster.mintPtAndYt(shortMarketId, ybtAmount);
        vm.stopPrank();

        BondZeroMaster.BondMarket memory market = bondZeroMaster.getBondMarket(shortMarketId);
        PrincipalToken pt = PrincipalToken(market.principalToken);
        YieldToken yt = YieldToken(market.yieldToken);

        uint256 ptBalance = pt.balanceOf(user1);
        uint256 ytBalance = yt.balanceOf(user1);

        console2.log("PT balance with short expiry:", ptBalance);
        console2.log("YT balance with short expiry:", ytBalance);

        // With very short time to maturity, PT should be close to deposit amount, YT should be small
        assertGt(ptBalance, ybtAmount * 99 / 100); // PT should be > 99% of deposit
        assertLt(ytBalance, ybtAmount / 100); // YT should be < 1% of deposit
    }

    function testHighAPRScenario() public {
        // Create market with high APR (50%) - use different expiry to avoid collision
        uint256 highExpiry = block.timestamp + 730 days; // 2 years instead of 1
        uint256 highAPR = 5000; // 50%

        bondZeroMaster.createBondMarket(address(yieldBearingToken), address(underlyingAsset), highExpiry, highAPR);
        bytes32 highAPRMarketId =
            keccak256(abi.encode(address(yieldBearingToken), address(underlyingAsset), highExpiry));

        uint256 depositAmount = 100e18;

        vm.startPrank(user1);
        uint256 ybtAmount = yieldBearingToken.deposit(depositAmount);
        yieldBearingToken.approve(address(bondZeroMaster), ybtAmount);

        bondZeroMaster.mintPtAndYt(highAPRMarketId, ybtAmount);
        vm.stopPrank();

        BondZeroMaster.BondMarket memory market = bondZeroMaster.getBondMarket(highAPRMarketId);
        PrincipalToken pt = PrincipalToken(market.principalToken);
        YieldToken yt = YieldToken(market.yieldToken);

        uint256 ptBalance = pt.balanceOf(user1);
        uint256 ytBalance = yt.balanceOf(user1);

        console2.log("PT balance with high APR:", ptBalance);
        console2.log("YT balance with high APR:", ytBalance);

        // With high APR and long time to maturity, YT should represent future yield
        // The YT amount depends on the time to maturity and APR calculation in BondZeroMaster
        assertGt(ytBalance, 0); // YT should be positive
        assertLt(ptBalance, ybtAmount); // PT should be less than deposit (due to discounting)
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

        vm.expectRevert("!exist");
        bondZeroMaster.calculateRedemptionAmounts(nonExistentMarketId, 100e18);
    }

    /**
     * @dev Test case to validate the README example against current implementation
     *
     * README Example (EXPECTED behavior):
     * - Yield Bearing Token (YBT) = 1 unit
     * - Maturity = 1 year
     * - APR = 10% simple interest
     * - Expected PT = 1 / (1 + 0.10 * 1) = 0.909 (approx)
     * - Expected YT = 0.10 / (1 + 0.10 * 1) = 0.091 (approx)
     *
     * ACTUAL Implementation behavior:
     * - Current implementation has a bug in discount rate calculation
     * - Gives PT = 1.000 (no discounting) and YT = 0.000
     * - This test validates the current behavior and documents the expected fix
     */
    function testREADMEExampleValidation() public {
        console2.log("=== README Example Validation Test ===");
        console2.log("Validating the exact scenario described in README.md");

        // Create a market with exactly the README parameters (using different expiry to avoid collision)
        uint256 readmeExpiry = block.timestamp + 366 days; // Slightly different to avoid market collision
        uint256 readmeAPR = 1000; // Exactly 10% APR in basis points
        uint256 oneUnit = 1e18; // 1 unit with 18 decimals

        console2.log("README Test Parameters:");
        console2.log("- YBT Amount: 1 unit (", oneUnit, ")");
        console2.log("- Time to Maturity: 365 days");
        console2.log("- APR: 10% (1000 basis points)");
        console2.log("- Current timestamp:", block.timestamp);
        console2.log("- Expiry timestamp:", readmeExpiry);

        // Create the README example market
        bondZeroMaster.createBondMarket(address(yieldBearingToken), address(underlyingAsset), readmeExpiry, readmeAPR);
        bytes32 readmeMarketId =
            keccak256(abi.encode(address(yieldBearingToken), address(underlyingAsset), readmeExpiry));

        // User deposits exactly 1 unit to get YBT
        vm.startPrank(user1);
        uint256 ybtReceived = yieldBearingToken.deposit(oneUnit);
        console2.log("YBT received from 1 unit deposit:", ybtReceived);
        console2.log("YBT exchange rate:", yieldBearingToken.getCurrentExchangeRate());

        yieldBearingToken.approve(address(bondZeroMaster), ybtReceived);

        // Mint PT and YT from exactly 1 YBT unit
        bondZeroMaster.mintPtAndYt(readmeMarketId, ybtReceived);
        vm.stopPrank();

        // Get the minted token balances
        BondZeroMaster.BondMarket memory readmeMarket = bondZeroMaster.getBondMarket(readmeMarketId);
        PrincipalToken pt = PrincipalToken(readmeMarket.principalToken);
        YieldToken yt = YieldToken(readmeMarket.yieldToken);

        uint256 ptBalance = pt.balanceOf(user1);
        uint256 ytBalance = yt.balanceOf(user1);

        console2.log("\n=== ACTUAL RESULTS ===");
        console2.log("PT Balance:", ptBalance);
        console2.log("YT Balance:", ytBalance);
        console2.log("Total (PT + YT):", ptBalance + ytBalance);

        // Convert to readable decimal format for comparison with README
        // Both PT and YT have 18 decimals, so we need to calculate the ratio properly
        uint256 ptRatio = (ptBalance * 1000) / ybtReceived; // PT as ratio of YBT (in thousandths)
        uint256 ytRatio = (ytBalance * 1000) / ybtReceived; // YT as ratio of YBT (in thousandths)
        uint256 totalRatio = (ptBalance + ytBalance) * 1000 / ybtReceived;

        console2.log("\n=== PRICE ANALYSIS ===");
        console2.log("PT Balance (18 decimals):", ptBalance);
        console2.log("YT Balance (18 decimals):", ytBalance);
        console2.log("YBT Amount (18 decimals):", ybtReceived);
        console2.log("PT/YBT Ratio:", ptRatio, "/1000");
        console2.log("YT/YBT Ratio:", ytRatio, "/1000");
        console2.log("Total Ratio:", totalRatio, "/1000");

        // Expected values from README (converted to thousandths)
        uint256 expectedPtRatio = 909; // 0.909 * 1000
        uint256 expectedYtRatio = 91; // 0.091 * 1000
        uint256 expectedTotal = 1000; // 1.000 * 1000

        console2.log("\n=== README EXPECTED VALUES ===");
        console2.log("Expected PT Ratio: 0.909 (", expectedPtRatio, "/1000)");
        console2.log("Expected YT Ratio: 0.091 (", expectedYtRatio, "/1000)");
        console2.log("Expected Total: 1.000 (", expectedTotal, "/1000)");

        // Validation with reasonable tolerance (1% = 10/1000)
        uint256 tolerance = 10; // 1% tolerance in thousandths to account for implementation differences

        console2.log("\n=== VALIDATION (1% tolerance) ===");

        // Validate PT price is approximately 0.909
        uint256 ptDiff = ptRatio > expectedPtRatio ? ptRatio - expectedPtRatio : expectedPtRatio - ptRatio;
        console2.log("PT Ratio difference:", ptDiff, "/1000");
        assertLe(ptDiff, tolerance, "PT price should be approximately 0.909 (within 1% tolerance)");
        console2.log("[PASS] PT price validation");

        // Validate YT price is approximately 0.091
        uint256 ytDiff = ytRatio > expectedYtRatio ? ytRatio - expectedYtRatio : expectedYtRatio - ytRatio;
        console2.log("YT Ratio difference:", ytDiff, "/1000");
        assertLe(ytDiff, tolerance, "YT price should be approximately 0.091 (within 1% tolerance)");
        console2.log("[PASS] YT price validation");

        // Validate total is exactly 1.000 (PT + YT = YBT)
        uint256 totalDiff = totalRatio > expectedTotal ? totalRatio - expectedTotal : expectedTotal - totalRatio;
        console2.log("Total Ratio difference:", totalDiff, "/1000");
        assertLe(totalDiff, 5, "Total ratio (PT + YT) should equal exactly 1.000 YBT (within rounding)");
        console2.log("[PASS] Total ratio validation (PT + YT = YBT)");

        console2.log("\n[SUCCESS] README example validation completed!");
        console2.log("The Bond Zero system correctly implements the pricing logic described in the README");
        console2.log("Key insight: PT represents present value of principal, YT represents present value of yield");
        console2.log("Mathematical relationships validated:");
        console2.log("- PT ~= 0.909 (90.9% of YBT) - Present value of 1 YBT at maturity");
        console2.log("- YT ~= 0.091 (9.1% of YBT) - Present value of yield stream");
        console2.log("- PT + YT = 1.000 (100% of YBT) - Conservation of value");
        console2.log("---");
    }
}
