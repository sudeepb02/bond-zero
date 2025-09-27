// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MockYieldBearingToken
 * @dev A mock implementation of a yield-bearing token for testing purposes
 * This contract simulates yield generation by automatically updating exchange rate based on APR and time
 */
contract MockYieldBearingToken is ERC20, Ownable {
    // The underlying asset token (e.g., USDC, DAI)
    ERC20 public immutable asset;

    // Exchange rate from asset to yield bearing token (scaled by 1e18)
    // Initially 1:1, but increases over time based on APR
    uint256 public exchangeRate = 1e18;

    // Annual Percentage Rate in basis points (e.g., 1000 = 10%)
    uint256 public immutable aprBasisPoints;

    // Timestamp when the contract was deployed (start of yield accrual)
    uint256 public immutable deploymentTime;

    // Last time the exchange rate was updated
    uint256 public lastUpdateTime;

    // Total amount of underlying assets deposited
    uint256 public totalAssets;

    event YieldAccrued(uint256 newExchangeRate, uint256 yieldAmount);
    event Deposited(address indexed user, uint256 assets, uint256 shares);
    event Withdrawn(address indexed user, uint256 assets, uint256 shares);

    constructor(string memory _name, string memory _symbol, address _asset, uint256 _aprBasisPoints)
        ERC20(_name, _symbol)
        Ownable(msg.sender)
    {
        asset = ERC20(_asset);
        aprBasisPoints = _aprBasisPoints;
        deploymentTime = block.timestamp;
        lastUpdateTime = block.timestamp;
    }

    /**
     * @dev Deposit underlying assets and mint yield bearing tokens
     * @param assets Amount of underlying assets to deposit
     * @return shares Amount of yield bearing tokens minted
     */
    function deposit(uint256 assets) external returns (uint256 shares) {
        require(assets > 0, "Zero assets");

        // Update exchange rate before calculating shares
        _updateExchangeRate();

        shares = convertToShares(assets);
        totalAssets += assets;

        asset.transferFrom(msg.sender, address(this), assets);
        _mint(msg.sender, shares);

        emit Deposited(msg.sender, assets, shares);
    }

    /**
     * @dev Withdraw underlying assets by burning yield bearing tokens
     * @param shares Amount of yield bearing tokens to burn
     * @return assets Amount of underlying assets withdrawn
     */
    function withdraw(uint256 shares) external returns (uint256 assets) {
        require(shares > 0, "Zero shares");
        require(balanceOf(msg.sender) >= shares, "Insufficient balance");

        // Update exchange rate before calculating assets
        _updateExchangeRate();

        assets = convertToAssets(shares);
        totalAssets -= assets;

        _burn(msg.sender, shares);
        asset.transfer(msg.sender, assets);

        emit Withdrawn(msg.sender, assets, shares);
    }

    /**
     * @dev Internal function to update exchange rate based on time elapsed and APR
     */
    function _updateExchangeRate() internal {
        if (block.timestamp <= lastUpdateTime) {
            return; // No time has passed
        }

        uint256 timeElapsed = block.timestamp - lastUpdateTime;
        uint256 oldRate = exchangeRate;

        // Calculate new exchange rate: rate = rate * (1 + APR * timeElapsed / secondsInYear)
        // Use compound interest formula for more accurate calculation
        uint256 secondsInYear = 365 days;
        uint256 rateIncrease = (exchangeRate * aprBasisPoints * timeElapsed) / (10000 * secondsInYear);

        exchangeRate += rateIncrease;
        lastUpdateTime = block.timestamp;

        if (exchangeRate > oldRate) {
            uint256 yieldAmount = totalSupply() * (exchangeRate - oldRate) / 1e18;
            emit YieldAccrued(exchangeRate, yieldAmount);
        }
    }

    /**
     * @dev Manually update the exchange rate (for testing purposes)
     */
    function updateExchangeRate() external {
        _updateExchangeRate();
    }

    /**
     * @dev Simulate yield accrual by updating the exchange rate
     * @param newRate New exchange rate (scaled by 1e18)
     */
    function accrueYield(uint256 newRate) external onlyOwner {
        require(newRate >= exchangeRate, "Rate cannot decrease");

        uint256 oldRate = exchangeRate;
        exchangeRate = newRate;
        lastUpdateTime = block.timestamp;

        // Calculate yield amount based on total supply
        uint256 yieldAmount = totalSupply() * (newRate - oldRate) / 1e18;

        emit YieldAccrued(newRate, yieldAmount);
    }
    /**
     * @dev Convert asset amount to shares based on current exchange rate
     * @param assets Amount of underlying assets
     * @return shares Equivalent amount of yield bearing tokens
     */

    function convertToShares(uint256 assets) public view returns (uint256 shares) {
        uint256 currentRate = _getCurrentExchangeRate();
        if (totalSupply() == 0) {
            return assets;
        }
        return assets * 1e18 / currentRate;
    }

    /**
     * @dev Convert shares to asset amount based on current exchange rate
     * @param shares Amount of yield bearing tokens
     * @return assets Equivalent amount of underlying assets
     */
    function convertToAssets(uint256 shares) public view returns (uint256 assets) {
        uint256 currentRate = _getCurrentExchangeRate();
        return shares * currentRate / 1e18;
    }

    /**
     * @dev Get the current exchange rate without updating state (view function)
     * @return Current exchange rate based on time elapsed
     */
    function _getCurrentExchangeRate() internal view returns (uint256) {
        if (block.timestamp <= lastUpdateTime) {
            return exchangeRate;
        }

        uint256 timeElapsed = block.timestamp - lastUpdateTime;
        uint256 secondsInYear = 365 days;
        uint256 rateIncrease = (exchangeRate * aprBasisPoints * timeElapsed) / (10000 * secondsInYear);

        return exchangeRate + rateIncrease;
    }

    /**
     * @dev Get the current value of total assets including accrued yield
     * @return Total value of assets in the contract
     */
    function totalAssetsWithYield() external view returns (uint256) {
        return convertToAssets(totalSupply());
    }

    /**
     * @dev Mint tokens directly (for testing setup)
     * @param to Address to mint tokens to
     * @param amount Amount of tokens to mint
     */
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /**
     * @dev Get the current exchange rate (includes time-based accrual)
     * @return Current exchange rate
     */
    function getCurrentExchangeRate() external view returns (uint256) {
        return _getCurrentExchangeRate();
    }

    /**
     * @dev Get the configured APR
     * @return APR in basis points
     */
    function getAPR() external view returns (uint256) {
        return aprBasisPoints;
    }

    /**
     * @dev Get time since last update
     * @return Time elapsed in seconds
     */
    function getTimeSinceLastUpdate() external view returns (uint256) {
        return block.timestamp - lastUpdateTime;
    }
}
