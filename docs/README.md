# Stratax Protocol Documentation

Welcome to the Stratax Protocol documentation! Stratax is a decentralized leveraged position protocol that enables users to create long or short positions on various crypto assets using Aave V3 and 1inch.

## What is Stratax?

Stratax allows users to open leveraged positions (up to ~5x depending on asset LTV) through an innovative system that combines:

- **Aave V3**: For collateral supply, borrowing, and flash loans
- **1inch**: For efficient token swaps
- **NFT Positions**: Each position is represented as an NFT for easy transferability

## Key Features

- 🎯 **Leveraged Positions**: Open long or short positions with customizable leverage
- 🔄 **Flash Loan Powered**: Efficient position creation using Aave flash loans
- 🎨 **NFT-Based**: Each position is an ERC-721 token that can be transferred
- 🛡️ **Safety Margins**: Built-in safety mechanisms to prevent liquidation
- 📊 **Position Management**: Adjust leverage, add collateral, or partially close positions
- 💰 **Fee Structure**: Transparent protocol fees for position operations

## How It Works

### Opening a Long Position

1. User provides initial collateral (e.g., USDC)
2. System takes a flash loan of additional collateral
3. All collateral is supplied to Aave
4. System borrows debt token from Aave
5. Debt token is swapped back to collateral via 1inch
6. Flash loan is repaid with swap proceeds
7. Result: Leveraged long position on collateral asset

### Closing a Position

1. System takes a flash loan of the debt token
2. Repays all Aave debt
3. Withdraws collateral from Aave
4. Swaps collateral back to debt token via 1inch
5. Repays flash loan
6. Returns remaining collateral to user

## Architecture Overview

```
┌─────────────────┐
│  User Wallet    │
└────────┬────────┘
         │
         ↓
┌─────────────────────┐
│ StrataxPositionNft  │ ← Mints NFT positions
└─────────┬───────────┘
          │
          ↓
┌─────────────────────┐
│   Stratax (Proxy)   │ ← Individual position contract
└─────────┬───────────┘
          │
          ├─→ Aave V3 Pool
          ├─→ 1inch Router
          ├─→ StrataxOracle
          └─→ FeeCollector
```

## Quick Start

To understand how to use the protocol, start with:

- [Opening a Position](guides/opening-position.md)
- [Managing Your Position](guides/managing-positions.md)
- [Closing a Position](guides/closing-position.md)

## Contract Documentation

- [Stratax Contract](contracts/stratax.md) - Core position logic
- [StrataxPositionNft](contracts/stratax-position-nft.md) - NFT management
- [StrataxOracle](contracts/stratax-oracle.md) - Price feeds
- [FeeCollector](contracts/fee-collector.md) - Fee management
- [StrataxCalculations](contracts/stratax-calculations.md) - Math library

## Safety & Risk

- Positions are subject to Aave liquidation if health factor drops below 1.0
- Protocol includes safety margins to maintain healthy positions
- Leverage is capped based on asset LTV parameters
- Slippage protection on all swaps via 1inch

## Developer Resources

- [Deployment Guide](deployment/deployment-guide.md)
- [Integration Guide](guides/integration-guide.md)
- [Testing Guide](deployment/testing.md)

## License

[License information here]

## Support

For questions or support, please [contact information or links].
