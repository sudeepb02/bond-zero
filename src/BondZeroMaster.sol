// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PrincipalToken} from "./PrincipalToken.sol";
import {YieldToken} from "./YieldToken.sol";

/**
 * @title BondZeroMaster
 * @author BondZero Protocol
 * @notice Core contract managing bond markets and Principal/Yield token operations
 * @dev Handles creation, minting, redemption of PT/YT pairs for yield-bearing assets
 *      Integrates with Uniswap v4 via BondZeroHook for seamless trading and redemption
 */
contract BondZeroMaster {
    using SafeERC20 for IERC20;

    /**
     * @notice Bond market structure containing all market-specific information
     * @dev Used to track all parameters for a specific PT/YT pair market
     */
    struct BondMarket {
        address yieldBearingToken; /// @dev Underlying yield-bearing token (e.g., wstETH)
        address assetToken; /// @dev Base asset token (e.g., stETH)
        address principalToken; /// @dev Principal token address (e.g., ZPT-wstETH)
        address yieldToken; /// @dev Yield token address (e.g., ZYT-wstETH)
        uint256 expiry; /// @dev Timestamp when the market expires
        uint256 initialApr; /// @dev Initial APR when creating the market (in basis points)
        uint256 creationTimestamp; /// @dev Timestamp when the market was created
    }

    /// @notice Maps market ID to bond market information
    /// @dev Market ID is computed from yieldBearingToken, assetToken, and expiry
    mapping(bytes32 marketId => BondMarket) bondMarkets;

    /// @notice Emitted when a new bond market is created
    event MarketCreated(
        bytes32 indexed marketId, address indexed yieldBearingToken, address indexed assetToken, uint256 expiry
    );
    
    /// @notice Emitted when user deposits YBT to mint PT/YT tokens
    event TokensDeposited(bytes32 indexed marketId, address indexed user, uint256 ybtAmount);
    
    /// @notice Emitted when user redeems PT/YT tokens for YBT
    event TokensRedeemed(bytes32 indexed marketId, address indexed user, uint256 ybtAmount);

    /// @notice Contract constructor - no initialization required
    constructor() {}

    /**
     * @notice Creates a new bond market for the given parameters
     * @dev Deploys new PT and YT token contracts and stores market information
     * @param _yieldBearingToken Address of the yield-bearing token (e.g., wstETH)
     * @param _assetToken Address of the underlying asset token (e.g., stETH)
     * @param _expiry Expiration timestamp for the market
     * @param _initialApr Initial APR in basis points (e.g., 1000 = 10%)
     */
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

    /**
     * @notice Mints PT and YT tokens by depositing yield-bearing tokens
     * @dev User deposits YBT and receives 1:1 amounts of PT and YT tokens
     * @param _marketId Unique identifier for the bond market
     * @param _amount Amount of yield-bearing tokens to deposit
     */
    function mintPtAndYt(bytes32 _marketId, uint256 _amount) external {
        BondMarket memory market = bondMarkets[_marketId];
        require(market.yieldBearingToken != address(0), "!exist");
        require(block.timestamp < market.expiry, "expired");

        // Transfer yield bearing token from user to contract
        IERC20(market.yieldBearingToken).safeTransferFrom(msg.sender, address(this), _amount);

        // Mint 1:1 PT and YT tokens to user
        PrincipalToken(market.principalToken).mint(msg.sender, _amount);
        YieldToken(market.yieldToken).mint(msg.sender, _amount);

        emit TokensDeposited(_marketId, msg.sender, _amount);
    }

    /**
     * @notice Retrieves bond market information by token addresses and expiry
     * @param _yieldBearingToken Address of the yield-bearing token
     * @param _assetToken Address of the underlying asset token
     * @param _expiry Expiration timestamp for the market
     * @return BondMarket struct containing market information
     */
    function getBondMarket(address _yieldBearingToken, address _assetToken, uint256 _expiry)
        external
        view
        returns (BondMarket memory)
    {
        bytes32 marketId = _getMarketId(_yieldBearingToken, _assetToken, _expiry);
        return bondMarkets[marketId];
    }

    /**
     * @notice Retrieves bond market information by market ID
     * @param _marketId Unique identifier for the bond market
     * @return BondMarket struct containing market information
     */
    function getBondMarket(bytes32 _marketId) external view returns (BondMarket memory) {
        return bondMarkets[_marketId];
    }

    /**
     * @notice Calculates the current price of PT tokens in terms of YBT
     * @dev Price calculation based on time to maturity and initial APR
     * @param _marketId Unique identifier for the bond market
     * @return PT price in 1e18 precision (1e18 = 1 YBT)
     */
    function getPtPriceInYbt(bytes32 _marketId) external view returns (uint256) {
        BondMarket memory market = bondMarkets[_marketId];
        require(market.yieldBearingToken != address(0), "!exist");

        if (block.timestamp >= market.expiry) {
            return 1e18; // At or after expiry, PT is worth exactly 1 YBT
        }

        uint256 timeToMaturity = market.expiry - block.timestamp;
        return _calculatePtPrice(market.initialApr, timeToMaturity);
    }

    /**
     * @notice Calculates the current price of YT tokens in terms of YBT
     * @dev YT price = 1 YBT - PT price, becomes 0 after expiry
     * @param _marketId Unique identifier for the bond market
     * @return YT price in 1e18 precision (1e18 = 1 YBT)
     */
    function getYtPriceInYbt(bytes32 _marketId) external view returns (uint256) {
        BondMarket memory market = bondMarkets[_marketId];
        require(market.yieldBearingToken != address(0), "!exist");

        if (block.timestamp >= market.expiry) {
            return 0; // After expiry, YT is worthless
        }

        uint256 ptPrice = _calculatePtPrice(market.initialApr, market.expiry - block.timestamp);
        return 1e18 - ptPrice; // YT price = 1 YBT - PT price
    }

    /**
     * @notice Calculates PT price using present value formula
     * @dev Uses formula: PT_price = 1 / (1 + r*t) where r is APR and t is time to maturity
     * @param aprBps Annual percentage rate in basis points (e.g., 1000 = 10%)
     * @param timeToMaturity Time remaining until expiry in seconds
     * @return PT price in 1e18 precision
     */
    function _calculatePtPrice(uint256 aprBps, uint256 timeToMaturity) internal pure returns (uint256) {
        if (timeToMaturity == 0) return 1e18; // At maturity, PT = 1

        // Convert APR from basis points to 1e18 fixed-point decimal
        // aprBps is in basis points (e.g., 1000 = 10%)
        // Convert to 1e18 fixed-point decimal: r = aprBps / 10000
        // => multiply by 1e18 / 10000 = 1e14
        uint256 r = aprBps * 1e14; // 1e18-scaled rate

        // Convert time to maturity from seconds to years (1e18-scaled)
        uint256 t = (timeToMaturity * 1e18) / 365 days;

        // Calculate r * t (1e18-scaled)
        uint256 rt = (r * t) / 1e18;

        // Calculate denominator = 1 + r*t
        uint256 denom = 1e18 + rt;

        // Calculate PT price = 1 / (1 + r*t)
        uint256 ptPrice = (1e18 * 1e18) / denom;

        return ptPrice;
    }

    /**
     * @notice Redeems PT (and optionally YT) tokens for underlying YBT
     * @dev Before expiry: requires both PT and YT tokens (1:1:1 ratio)
     *      After expiry: requires only PT tokens (1:1 ratio)
     * @param _marketId Unique identifier for the bond market
     * @param _yieldBearingAmount Amount of YBT to redeem
     */
    function redeemPtAndYt(bytes32 _marketId, uint256 _yieldBearingAmount) external {
        BondMarket memory market = bondMarkets[_marketId];
        require(market.yieldBearingToken != address(0), "!exist");

        uint256 principalTokensNeeded = _yieldBearingAmount;
        uint256 yieldTokensNeeded;

        // Determine redemption requirements based on expiry status
        if (block.timestamp >= market.expiry) {
            // After expiry: only PT tokens needed (PT -> YBT 1:1)
            principalTokensNeeded = _yieldBearingAmount;
            yieldTokensNeeded = 0;
        } else {
            // Before expiry: both PT and YT tokens needed (PT + YT -> YBT 1:1:1)
            yieldTokensNeeded = _yieldBearingAmount;
            YieldToken(market.yieldToken).burn(msg.sender, yieldTokensNeeded);
        }

        // Always burn the required principal tokens
        PrincipalToken(market.principalToken).burn(msg.sender, principalTokensNeeded);

        // Transfer yield bearing tokens to user
        IERC20(market.yieldBearingToken).safeTransfer(msg.sender, _yieldBearingAmount);

        emit TokensRedeemed(_marketId, msg.sender, _yieldBearingAmount);
    }

    /**
     * @notice Generates a unique market ID for the given parameters
     * @dev Uses keccak256 hash of encoded parameters for deterministic ID generation
     * @param _yieldBearingToken Address of the yield-bearing token
     * @param _assetToken Address of the underlying asset token
     * @param _expiry Expiration timestamp for the market
     * @return Unique bytes32 market identifier
     */
    function _getMarketId(address _yieldBearingToken, address _assetToken, uint256 _expiry)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(_yieldBearingToken, _assetToken, _expiry));
    }
}
