# Stratax Protocol Documentation

Welcome to the Stratax Protocol documentation.

Stratax includes three core product surfaces:

- Leveraged position infrastructure built on Aave V3 + 1inch
- Token sale infrastructure with Pyth-based pricing and vesting
- Staking and managed vault infrastructure for fee sharing and delegated leverage management

## What is Stratax?

Stratax allows users to open leveraged positions (up to ~5x depending on asset LTV), participate in STRATAX token sale rounds, and stake for protocol fee rewards.

The leveraged position system combines:

- **Aave V3**: For collateral supply, borrowing, and flash loans
- **1inch**: For efficient token swaps
- **NFT Positions**: Each position is represented as an NFT for easy transferability

Additional protocol systems include:

- **Pyth**: Real-time token sale payment pricing
- **ERC4626 Staking**: STRATAX staking with multi-token reward accounting
- **Managed Vaults**: Manager-operated leveraged position wrappers for pooled users

## Key Features

- 🎯 **Leveraged Positions**: Open long or short positions with customizable leverage
- 🔄 **Flash Loan Powered**: Efficient position creation using Aave flash loans
- 🎨 **NFT-Based**: Each position is an ERC-721 token that can be transferred
- 🛡️ **Safety Margins**: Built-in safety mechanisms to prevent liquidation
- 📊 **Position Management**: Adjust leverage, add collateral, or partially close positions
- 💰 **Fee Structure**: Transparent protocol fees for position operations
- 🪙 **Token Sale**: Whitelisted payment tokens, Pyth pricing, TGE + linear vesting
- 🏦 **Staking Rewards**: Multi-token protocol fee distribution to stakers
- 🧠 **Managed Vaults**: ERC4626 vault shares for manager-operated leveraged positions

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

### Token Sale

1. User pays with a whitelisted token (for example WETH or USDC)
2. Contract fetches token/USD price from Pyth
3. Price is normalized to 8 decimals (supports non-8 feed precision)
4. STRATAX output is calculated from USD value and sale price
5. 25% is unlocked immediately, 75% is vested linearly over 270 days

### Staking and Fee Distribution

1. Fees are collected in `FeeCollector` in their native token units
2. `FeeCollector` splits each tracked token between owner and stakers using `stakerRewardsBps`
3. `StrataxStaking` pulls staker-side rewards and tracks them per share
4. Stakers claim one or all reward tokens via claim functions

### Managed Vaults

1. A managed vault is deployed for one underlying Stratax position
2. Users deposit collateral into an ERC4626 vault and receive shares
3. Manager increases leverage, unwinds, or rebalances toward target leverage
4. Users redeem directly when liquid, or queue FIFO withdrawals when needed

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

┌─────────────────────┐
│ StrataxTokenSale    │ ← Token sale contract (UUPS)
└─────────┬───────────┘
          ├─→ Pyth Price Feeds
          └─→ Payment Tokens

┌─────────────────────┐
│ StrataxStaking      │ ← ERC4626 staking vault
└─────────┬───────────┘
          └─→ FeeCollector (staker reward pull)

┌─────────────────────┐
│ StrataxManagedVault │ ← ERC4626 managed leverage vault
└─────────┬───────────┘
          └─→ Stratax Position Proxy
```

## Quick Start

To understand how to use the protocol, start with:

- [Opening a Position](guides/opening-position.md)
- [Token Sale](guides/token-sale.md)
- [Staking & Rewards](guides/staking-rewards.md)
- [Managed Vaults](guides/managed-vault.md)

## Contract Documentation

- [Stratax Contract](contracts/stratax.md) - Core position logic
- [StrataxTokenSale](contracts/stratax-token-sale.md) - Token sale pricing and vesting
- [StrataxStaking](contracts/stratax-staking.md) - ERC4626 staking and fee reward claims
- [StrataxManagedVault](contracts/stratax-managed-vault.md) - Managed leveraged vault

## Safety & Risk

- Positions are subject to Aave liquidation if health factor drops below 1.0
- Protocol includes safety margins to maintain healthy positions
- Leverage is capped based on asset LTV parameters
- Slippage protection on all swaps via 1inch

## Developer Resources

- [Deployment Guide](deployment/deployment-guide.md)
- [Configuration](deployment/configuration.md)
- [Architecture Overview](architecture/overview.md)

## License

UNLICENSED.

## Support

For support and updates:

- [Website](https://stratax.trade)
- [Docs](https://stratax.gitbook.io/stratax-docs/)
- [Twitter](https://x.com/stratax_trade)
- [Discord](https://discord.gg/ekdnKGKGnq)
