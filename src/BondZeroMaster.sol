// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PrincipalToken} from "./PrincipalToken.sol";
import {YieldToken} from "./YieldToken.sol";

// The BondZeroMaster is the main contract to manage the Principal and Yield token
contract BondZeroMaster {
    using SafeERC20 for IERC20;

    struct BondMarket {
        address yieldBearingToken; // For ex: wstETH
        address assetToken; // For ex: stETH
        address principalToken; // For ex: ZPT-wstETH
        address yieldToken; // For ex: ZYT-wstETH
        uint256 expiry; // Timestamp when the market expires
        uint256 initialApr; // Initial APR when creating the market
        uint256 creationTimestamp; // Timestamp when the market was created with the initial APR
    }

    mapping(bytes32 marketId => BondMarket) bondMarkets;

    event MarketCreated(
        bytes32 indexed marketId, address indexed yieldBearingToken, address indexed assetToken, uint256 expiry
    );
    event TokensDeposited(
        bytes32 indexed marketId, address indexed user, uint256 ybtAmount, uint256 principalAmount, uint256 yieldAmount
    );
    event TokensRedeemed(
        bytes32 indexed marketId, address indexed user, uint256 ybtAmount, uint256 principalAmount, uint256 yieldAmount
    );

    constructor() {}

    function createBondMarket(address _yieldBearingToken, address _assetToken, uint256 _expiry, uint256 _initialApr)
        external
    {
        bytes32 marketId = _getMarketId(_yieldBearingToken, _assetToken, _expiry);
        BondMarket memory market = bondMarkets[marketId];
        if (market.yieldBearingToken != address(0)) revert("already exists");

        market.yieldBearingToken = _yieldBearingToken;
        market.assetToken = _assetToken;

        string memory yieldTokenName = IERC20Metadata(_yieldBearingToken).name();
        string memory yieldTokenSymbol = IERC20Metadata(_yieldBearingToken).symbol();

        market.principalToken = address(
            new PrincipalToken(string.concat("Bond Zero ", yieldTokenName), string.concat("ZPT", yieldTokenSymbol))
        );

        market.yieldToken =
            address(new YieldToken(string.concat("Bond Zero ", yieldTokenName), string.concat("ZYT", yieldTokenSymbol)));

        market.expiry = _expiry;
        market.initialApr = _initialApr;
        market.creationTimestamp = block.timestamp;

        bondMarkets[marketId] = market;
        emit MarketCreated(marketId, _yieldBearingToken, _assetToken, _expiry);
    }

    function mintPtAndYt(bytes32 _marketId, uint256 _amount) external {
        BondMarket memory market = bondMarkets[_marketId];
        require(market.yieldBearingToken != address(0), "!exist");
        require(block.timestamp < market.expiry, "expired");

        // Transfer yield bearing token from user to contract
        IERC20(market.yieldBearingToken).safeTransferFrom(msg.sender, address(this), _amount);

        // Calculate time to maturity in seconds
        uint256 timeToMaturity = market.expiry - block.timestamp;

        // Calculate principal and yield amounts
        (uint256 principalAmount, uint256 yieldAmount) =
            _calculatePtAndYtFromYieldBearing(_amount, market.initialApr, timeToMaturity);

        // Mint principal tokens (1:1 with underlying asset value)
        PrincipalToken(market.principalToken).mint(msg.sender, principalAmount);

        // Mint yield tokens (representing future yield)
        YieldToken(market.yieldToken).mint(msg.sender, yieldAmount);

        emit TokensDeposited(_marketId, msg.sender, _amount, principalAmount, yieldAmount);
    }

    function _calculatePtAndYtFromYieldBearing(uint256 _amount, uint256 _initialApr, uint256 _timeToMaturity)
        internal
        pure
        returns (uint256 principalAmount, uint256 yieldAmount)
    {
        // Calculate the present value of the yield bearing token
        // Formula: PV = FV / (1 + r * t / 365 days)
        // Where r is APR (as percentage), t is time to maturity in seconds

        uint256 annualizedTime = _timeToMaturity * 1e18 / 365 days; // Time as fraction of year (18 decimals)
        uint256 discountRate = _initialApr * annualizedTime / 100 / 1e18; // APR percentage applied for time period

        // Principal amount is the present value of the deposit
        principalAmount = _amount * 1e18 / (1e18 + discountRate);

        // Yield amount represents the expected yield until maturity
        yieldAmount = _amount - principalAmount;
    }

    function getBondMarket(address _yieldBearingToken, address _assetToken, uint256 _expiry)
        external
        view
        returns (BondMarket memory)
    {
        bytes32 marketId = _getMarketId(_yieldBearingToken, _assetToken, _expiry);
        return bondMarkets[marketId];
    }

    function getBondMarket(bytes32 _marketId) external view returns (BondMarket memory) {
        return bondMarkets[_marketId];
    }

    function calculateRedemptionAmounts(bytes32 _marketId, uint256 _yieldBearingAmount)
        external
        view
        returns (uint256 principalTokensNeeded, uint256 yieldTokensNeeded)
    {
        BondMarket memory market = bondMarkets[_marketId];
        require(market.yieldBearingToken != address(0), "!exist");

        // If market has expired, only principal tokens are needed (1:1 ratio)
        if (block.timestamp >= market.expiry) {
            return (_yieldBearingAmount, 0);
        }

        // Calculate time to maturity in seconds
        uint256 timeToMaturity = market.expiry - block.timestamp;

        // Calculate the required PT and YT amounts to redeem the yield bearing tokens
        (principalTokensNeeded, yieldTokensNeeded) =
            _calculatePtAndYtFromYieldBearing(_yieldBearingAmount, market.initialApr, timeToMaturity);
    }

    function redeemPtAndYt(bytes32 _marketId, uint256 _yieldBearingAmount) external {
        BondMarket memory market = bondMarkets[_marketId];
        require(market.yieldBearingToken != address(0), "!exist");

        uint256 principalTokensNeeded;
        uint256 yieldTokensNeeded;

        // If market has expired, only principal tokens are needed
        if (block.timestamp >= market.expiry) {
            principalTokensNeeded = _yieldBearingAmount;
            yieldTokensNeeded = 0;
        } else {
            // Calculate the required PT and YT amounts
            (principalTokensNeeded, yieldTokensNeeded) = _calculatePtAndYtFromYieldBearing(
                _yieldBearingAmount, market.initialApr, market.expiry - block.timestamp
            );
        }

        // Burn the required principal tokens
        if (principalTokensNeeded > 0) {
            PrincipalToken(market.principalToken).burn(msg.sender, principalTokensNeeded);
        }

        // Burn the required yield tokens (only if market hasn't expired)
        if (yieldTokensNeeded > 0) {
            YieldToken(market.yieldToken).burn(msg.sender, yieldTokensNeeded);
        }

        // Transfer yield bearing tokens to user
        IERC20(market.yieldBearingToken).safeTransfer(msg.sender, _yieldBearingAmount);

        emit TokensRedeemed(_marketId, msg.sender, _yieldBearingAmount, principalTokensNeeded, yieldTokensNeeded);
    }

    function _getMarketId(address _yieldBearingToken, address _assetToken, uint256 _expiry)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(_yieldBearingToken, _assetToken, _expiry));
    }
}
