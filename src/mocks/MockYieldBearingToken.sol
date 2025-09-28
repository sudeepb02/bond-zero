// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/**
 * @title MockYieldBearingToken
 * @author BondZero Protocol
 * @notice Mock implementation of a yield-bearing token for testing bond market functionality
 * @dev Simulates yield generation by automatically updating exchange rate based on APR and time
 *      Used to test BondZero protocol without needing real yield-bearing assets like wstETH
 *      Implements ERC4626-like vault functionality with configurable APR
 */
contract MockYieldBearingToken is ERC20, Ownable {
    /// @notice The underlying asset token (e.g., USDC, DAI, ETH)
    ERC20 public immutable asset;

    /// @notice Exchange rate from asset to yield bearing token (scaled by 1e18)
    /// @dev Initially 1:1, but increases over time based on APR to simulate yield
    uint256 public exchangeRate = 1e18;

    /// @notice Annual Percentage Rate in basis points (e.g., 1000 = 10%)
    uint256 public immutable aprBasisPoints;

    /// @notice Timestamp when the contract was deployed (start of yield accrual)
    uint256 public immutable deploymentTime;

    /// @notice Last time the exchange rate was updated
    /// @dev Used to calculate time-based yield accrual
    uint256 public lastUpdateTime;

    /// @notice Total amount of underlying assets deposited in the contract
    uint256 public totalAssets;

    /// @notice Emitted when yield is accrued and exchange rate is updated
    event YieldAccrued(uint256 newExchangeRate, uint256 yieldAmount);

    /// @notice Emitted when user deposits assets and receives shares
    event Deposited(address indexed user, uint256 assets, uint256 shares);

    /// @notice Emitted when user withdraws assets by burning shares
    event Withdrawn(address indexed user, uint256 assets, uint256 shares);

    /**
     * @notice Constructs a new MockYieldBearingToken with specified parameters
     * @param _name Token name (e.g., "Mock Wrapped Staked ETH")
     * @param _symbol Token symbol (e.g., "mwstETH")
     * @param _asset Address of the underlying asset token
     * @param _aprBasisPoints Annual percentage rate in basis points
     */
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
     * @notice Deposit underlying assets and mint yield bearing tokens
     * @dev Updates exchange rate before calculating shares to ensure accurate conversion
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
     * @notice Withdraw underlying assets by burning yield bearing tokens
     * @dev Updates exchange rate before calculating assets to ensure accurate conversion
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
     * @notice Internal function to update exchange rate based on time elapsed and APR
     * @dev Uses compound interest calculation: rate = rate * (1 + APR * timeElapsed / secondsInYear)
     *      Mints additional underlying assets to back the accrued yield
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
            // Calculate the additional assets needed to back the yield
            uint256 totalSharesOutstanding = totalSupply();
            if (totalSharesOutstanding > 0) {
                uint256 newTotalAssets = totalSharesOutstanding * exchangeRate / 1e18;
                uint256 yieldAssets = newTotalAssets - totalAssets;

                if (yieldAssets > 0) {
                    // Mint additional underlying asset tokens to back the yield
                    // Cast to MockERC20 to access mint function
                    MockERC20(address(asset)).mint(address(this), yieldAssets);
                    totalAssets = newTotalAssets;
                }
            }

            uint256 yieldAmount = totalSharesOutstanding * (exchangeRate - oldRate) / 1e18;
            emit YieldAccrued(exchangeRate, yieldAmount);
        }
    }

    /**
     * @notice Manually update the exchange rate (for testing purposes)
     * @dev Triggers time-based yield accrual calculation and state update
     */
    function updateExchangeRate() external {
        _updateExchangeRate();
    }

    /**
     * @notice Simulate yield accrual by directly setting the exchange rate
     * @dev Owner-only function for testing scenarios with specific yield amounts
     * @param newRate New exchange rate (scaled by 1e18)
     */
    function accrueYield(uint256 newRate) external onlyOwner {
        require(newRate >= exchangeRate, "Rate cannot decrease");

        uint256 oldRate = exchangeRate;
        exchangeRate = newRate;
        lastUpdateTime = block.timestamp;

        // Calculate the additional assets needed to back the yield
        uint256 totalSharesOutstanding = totalSupply();
        if (totalSharesOutstanding > 0 && newRate > oldRate) {
            uint256 newTotalAssets = totalSharesOutstanding * newRate / 1e18;
            uint256 yieldAssets = newTotalAssets - totalAssets;

            if (yieldAssets > 0) {
                // Mint additional underlying asset tokens to back the yield
                MockERC20(address(asset)).mint(address(this), yieldAssets);
                totalAssets = newTotalAssets;
            }
        }

        // Calculate yield amount based on total supply
        uint256 yieldAmount = totalSharesOutstanding * (newRate - oldRate) / 1e18;

        emit YieldAccrued(newRate, yieldAmount);
    }
    /**
     * @notice Convert asset amount to shares based on current exchange rate
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
     * @notice Convert shares to asset amount based on current exchange rate
     * @param shares Amount of yield bearing tokens
     * @return assets Equivalent amount of underlying assets
     */
    function convertToAssets(uint256 shares) public view returns (uint256 assets) {
        uint256 currentRate = _getCurrentExchangeRate();
        return shares * currentRate / 1e18;
    }

    /**
     * @notice Get the current exchange rate without updating state (view function)
     * @dev Calculates what the exchange rate would be if updated now
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
     * @notice Get the current value of total assets including accrued yield
     * @return Total value of assets in the contract
     */
    function totalAssetsWithYield() external view returns (uint256) {
        return convertToAssets(totalSupply());
    }

    /**
     * @notice Mint tokens directly (for testing setup)
     * @dev Owner-only function to mint tokens without depositing assets
     * @param to Address to mint tokens to
     * @param amount Amount of tokens to mint
     */
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /**
     * @notice Get the current exchange rate (includes time-based accrual)
     * @return Current exchange rate scaled by 1e18
     */
    function getCurrentExchangeRate() external view returns (uint256) {
        return _getCurrentExchangeRate();
    }

    /**
     * @notice Get the configured APR
     * @return APR in basis points (e.g., 1000 = 10%)
     */
    function getAPR() external view returns (uint256) {
        return aprBasisPoints;
    }

    /**
     * @notice Get time since last exchange rate update
     * @return Time elapsed in seconds since last update
     */
    function getTimeSinceLastUpdate() external view returns (uint256) {
        return block.timestamp - lastUpdateTime;
    }
}
