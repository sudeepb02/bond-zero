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
}
