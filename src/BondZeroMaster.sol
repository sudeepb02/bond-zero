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
        address yieldBearingToken; // For ex: sUSDe
        address assetToken; // For ex: USDe
        address principalToken; // For ex: ZPT-sUSDe
        address yieldToken; // For ex: ZYT-sUSDe
        uint256 expiry; // Timestamp when the market expires
        uint256 initialApr; // Initial APR when creating the market
    }

    mapping(bytes32 marketId => BondMarket) bondMarkets;

    event MarketCreated(
        bytes32 indexed marketId, address indexed yieldBearingToken, address indexed assetToken, uint256 expiry
    );
    event TokensDeposited(
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
            _calculateTokenAmounts(_amount, market.initialApr, timeToMaturity);

        // Mint principal tokens (1:1 with underlying asset value)
        PrincipalToken(market.principalToken).mint(msg.sender, principalAmount);

        // Mint yield tokens (representing future yield)
        YieldToken(market.yieldToken).mint(msg.sender, yieldAmount);

        emit TokensDeposited(_marketId, msg.sender, _amount, principalAmount, yieldAmount);
    }

    function _calculateTokenAmounts(uint256 _amount, uint256 _initialApr, uint256 _timeToMaturity)
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

    function _getMarketId(address _yieldBearingToken, address _assetToken, uint256 _expiry)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(_yieldBearingToken, _assetToken, _expiry));
    }
}
