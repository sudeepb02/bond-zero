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
    event TokensDeposited(bytes32 indexed marketId, address indexed user, uint256 ybtAmount);
    event TokensRedeemed(bytes32 indexed marketId, address indexed user, uint256 ybtAmount);

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

        PrincipalToken(market.principalToken).mint(msg.sender, _amount);
        YieldToken(market.yieldToken).mint(msg.sender, _amount);

        emit TokensDeposited(_marketId, msg.sender, _amount);
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

    function getPtPriceInYbt(bytes32 _marketId) external view returns (uint256) {
        BondMarket memory market = bondMarkets[_marketId];
        require(market.yieldBearingToken != address(0), "!exist");

        if (block.timestamp >= market.expiry) {
            return 1e18; // At or after expiry, PT is worth 1 YBT
        }

        uint256 timeToMaturity = market.expiry - block.timestamp;
        return _calculatePtPrice(market.initialApr, timeToMaturity);
    }

    function getYtPriceInYbt(bytes32 _marketId) external view returns (uint256) {
        BondMarket memory market = bondMarkets[_marketId];
        require(market.yieldBearingToken != address(0), "!exist");

        if (block.timestamp >= market.expiry) {
            return 0; // After expiry, YT is worthless
        }

        uint256 ptPrice = _calculatePtPrice(market.initialApr, market.expiry - block.timestamp);
        return 1e18 - ptPrice; // YT price = 1 YBT - PT price
    }

    function _calculatePtPrice(uint256 aprBps, uint256 timeToMaturity) internal pure returns (uint256) {
        if (timeToMaturity == 0) return 1e18; // At maturity, PT = 1

        // aprBps is in basis points (e.g., 1000 = 10%)
        // Convert to 1e18 fixed-point decimal: r = aprBps / 10000
        // => multiply by 1e18 / 10000 = 1e14
        uint256 r = aprBps * 1e14; // 1e18-scaled rate

        // Time to maturity in years (1e18-scaled)
        uint256 t = (timeToMaturity * 1e18) / 365 days;

        // r * t (1e18-scaled)
        uint256 rt = (r * t) / 1e18;

        // denominator = 1 + r*t
        uint256 denom = 1e18 + rt;

        // PT price = 1 / (1 + r*t)
        uint256 ptPrice = (1e18 * 1e18) / denom;

        return ptPrice;
    }

    function redeemPtAndYt(bytes32 _marketId, uint256 _yieldBearingAmount) external {
        BondMarket memory market = bondMarkets[_marketId];
        require(market.yieldBearingToken != address(0), "!exist");

        uint256 principalTokensNeeded = _yieldBearingAmount;
        uint256 yieldTokensNeeded;

        // If market has expired, only principal tokens are needed
        if (block.timestamp >= market.expiry) {
            principalTokensNeeded = _yieldBearingAmount;
            yieldTokensNeeded = 0;
        } else {
            yieldTokensNeeded = _yieldBearingAmount;
            YieldToken(market.yieldToken).burn(msg.sender, yieldTokensNeeded);
        }

        // Burn the required principal tokens
        PrincipalToken(market.principalToken).burn(msg.sender, principalTokensNeeded);

        // Transfer yield bearing tokens to user
        IERC20(market.yieldBearingToken).safeTransfer(msg.sender, _yieldBearingAmount);

        emit TokensRedeemed(_marketId, msg.sender, _yieldBearingAmount);
    }

    function _getMarketId(address _yieldBearingToken, address _assetToken, uint256 _expiry)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(_yieldBearingToken, _assetToken, _expiry));
    }
}
