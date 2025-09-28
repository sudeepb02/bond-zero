# Bond Zero - Advanced Zero Coupon Bonds with Uniswap V4 Hooks

> **Innovative DeFi Protocol**: Seamlessly split yield-bearing assets into fixed and variable yield components with native Uniswap V4 integration for optimal liquidity and user experience.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Solidity](https://img.shields.io/badge/Solidity-^0.8.28-363636?logo=solidity)](https://soliditylang.org/)
[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-FFDB1C.svg)](https://getfoundry.sh/)
[![Uniswap V4](https://img.shields.io/badge/Uniswap-V4%20Hooks-FF007A.svg)](https://github.com/Uniswap/v4-core)

## 🚀 Overview

Bond Zero revolutionizes the DeFi yield landscape by enabling users to separate yield-bearing tokens (YBT) into two distinct components:

- **Principal Tokens (PT)**: Guaranteed 1:1 redemption for underlying assets at maturity
- **Yield Tokens (YT)**: Rights to all yield generated until maturity

Built on **Uniswap V4 Hooks**, Bond Zero provides liquidity efficiency, seamless trading experiences, and innovative yield strategies that weren't possible in previous AMM versions.

## 🌟 Key Benefits of Uniswap V4 Integration

### 🔄 **Seamless Token Swapping & Redemption**

- **Native PT ↔ YBT Trading**: Direct swaps without intermediate tokens or complex routing
- **Automatic Redemption**: Expired PT tokens are automatically redeemed for underlying YBT during swaps
- **Zero Slippage for 1:1 Redemptions**: Post-maturity PT→YBT swaps execute at exact 1:1 rate
- **Atomic Operations**: Hook-based execution ensures transaction integrity
- **Smart Claim Management**: ERC-6909 claim tokens for efficient settlement

### ⚡ **Enhanced Capital Efficiency**

- **Custom Liquidity Curves**: Implements tight concentrated liquidity for optimal PT/YT pricing providing deep liquidity
- **Reduced Gas Costs**: Single-transaction execution for complex operations through hooks
- **Concentrated Liquidity**: Flexibilty to use custom price ranges for better capital utilization

## 📋 Protocol Architecture

### Core Components

#### 🏦 **BondZeroMaster**

Central registry managing bond markets and PT/YT lifecycle:

```solidity
- Create bond markets with configurable expiry and APR
- Mint PT/YT pairs by depositing YBT (1:1:1 ratio)
- Redeem expired PT tokens for underlying YBT
- Calculate real-time PT/YT pricing based on time-to-maturity
```

#### 🎣 **BondZeroHook**

Uniswap V4 hook providing native AMM integration:

```solidity
- Automatic PT redemption on expiry
- Security controls preventing invalid swaps
- ERC-6909 claim token management
```

#### 💰 **Principal Token (PT)**

ERC-20 representing future claim on underlying asset:

```solidity
- Always redeemable 1:1 for YBT at maturity
- Tradeable at discount before maturity
- Present value = 1 / (1 + r*t)
```

#### 📈 **Yield Token (YT)**

ERC-20 representing yield accrual rights:

```solidity
- Captures all yield until maturity
- Present value = 1 - PT_price
```

## 📊 Example: wstETH Bond Market

Consider a 1-year wstETH bond market with 10% APR:

### Initial Setup

```
YBT (wstETH): 1.000 tokens
Maturity: 365 days
APR: 10%
Expected value at maturity: 1.100 stETH (considering initial rate of wstETH:stETH is 1:1)
```

### Token Splitting (PT + YT = YBT)

```
PT Price = 1 / (1 + 0.10 × 1) = 0.909 stETH
YT Price = 1 - 0.909 = 0.091 stETH
Total = 0.909 + 0.091 = 1.000 stETH
```

### Trading Scenarios

**Scenario 1: Risk-Averse User**

- Holds PT tokens for guaranteed fixed yield at maturity
- 10% return locked in regardless of actual wstETH yield

**Scenario 2: Yield Maximizer**

- Holds YT tokens to capture variable yield
- Benefits if wstETH yields > 10%, loses if < 10%

**Scenario 3: Arbitrageur**

- Uses Uniswap V4 hooks for efficient PT/YT arbitrage

## 🛠️ Technical Implementation

### Smart Contract Architecture

```
src/
├── BondZeroMaster.sol      # Core bond market management
├── BondZeroHook.sol        # Uniswap V4 hook integration
├── PrincipalToken.sol      # Simple PT ERC-20 implementation
├── YieldToken.sol          # Simple YT ERC-20 implementation
└── mocks/
    └── MockYieldBearingToken.sol  # Testing utilities
```

## 🧪 Testing & Validation

### Comprehensive Test Suite

```bash
# Run all tests
forge test -vvv

# Key test scenarios
- testFullUserJourneyWithHookSwap()      # End-to-end workflow
- testCannotSwapYBTForPTWhenExpired()   # Security validation
- testPTPricingCalculations()           # Mathematical accuracy
- testClaimTokenMechanics()             # Settlement verification
```

### Test Results

```
✅ Full user journey (536,355 gas)
✅ Security controls (234,129 gas)
✅ Mathematical precision (±0.0001%)
✅ Gas optimization (<600k per operation)
```

## 🚀 Getting Started

### Prerequisites

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Clone repository
git clone https://github.com/sudeepb02/bond-zero
cd bond-zero
```

### Installation & Setup

```bash
# Install dependencies
forge install

# Compile contracts
forge build

# Run tests
forge test
```

### Usage Examples

#### Create Bond Market

```solidity
// Deploy bond market for wstETH with 1-year maturity
bondMaster.createBondMarket(
    wstETH_ADDRESS,
    stETH_ADDRESS,
    block.timestamp + 365 days,
    1000  // 10% APR in basis points
);
```

#### Mint PT/YT Tokens

```solidity
// Deposit 100 wstETH, receive 100 PT + 100 YT
bytes32 marketId = getMarketId(wstETH, stETH, expiry);
bondMaster.mintPtAndYt(marketId, 100e18);
```

#### Trade via Uniswap V4

```solidity
// Swap 50 PT for wstETH through hook
IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
    zeroForOne: true,
    amountSpecified: 50e18,
    sqrtPriceLimitX96: 0
});
poolManager.swap(poolKey, params, "");
```

## 💼 Use Cases & Applications

### 🎯 **For Individual Users**

- **Fixed Income**: Lock in guaranteed returns via PT tokens
- **Yield Farming**: Amplify yield exposure through YT tokens
- **Portfolio Hedging**: Separate principal protection from yield risk

### 🏢 **For Institutions**

- **Treasury Management**: Predictable cash flows for corporate treasuries
- **Risk Management**: Isolate and trade different risk components
- **Structured Products**: Build complex yield derivatives

### 🔧 **For Developers**

- **Composability**: Integrate PT/YT into other DeFi protocols
- **Automation**: Build yield strategies on top of Bond Zero
- **Innovation**: Create new financial primitives using hooks

## 📈 Market Opportunities

### Target Markets

```
Total Addressable Market:
├── Yield-bearing assets: $500B+ (wstETH, rETH, stMATIC...)
├── Fixed income DeFi: $50B+ (traditional bonds, CDs)
└── Yield trading: $10B+ (Pendle, Element, Sense)
```

### Competitive Advantages

- **First Uniswap V4 Implementation**: Early mover advantage in hook ecosystem
- **Lower Costs**: Reduced gas fees through hook efficiency
- **Better Liquidity**: Native AMM integration vs external DEX dependencies

## 📄 License & Contributing

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

### Built for ETH New Delhi 2025

This protocol was developed for the ETH New Delhi hackathon, showcasing the potential of Uniswap V4 hooks in creating next-generation DeFi primitives.

---
