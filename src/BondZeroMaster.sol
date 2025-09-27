// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PrincipalToken} from "./PrincipalToken.sol";
import {YieldToken} from "./YieldToken.sol";

contract BondZeroMaster {
    // The BondZeroMaster is the main contract to manage the Principal and Yield token

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

    function _getMarketId(address _yieldBearingToken, address _assetToken, uint256 _expiry)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(_yieldBearingToken, _assetToken, _expiry));
    }
}
