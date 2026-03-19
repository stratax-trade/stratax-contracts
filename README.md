# Stratax Protocol

> Decentralized leveraged positions powered by Aave V3 and 1inch

Stratax enables users to create leveraged long or short positions on crypto assets with up to ~5x leverage, represented as transferable NFTs.

[![GitBook](https://img.shields.io/badge/Docs-GitBook-blue)](https://stratax.gitbook.io/stratax-docs/) <!-- Add GitBook URL -->
[![License](https://img.shields.io/badge/License-UNLICENSED-red)]()

## Links

- **Website**: [stratax.trade](https://stratax.trade) <!-- Add website URL -->
- **Documentation**: [GitBook Docs](https://stratax.gitbook.io/stratax-docs/)
- **Twitter**: [Twitter @strata_trade](https://x.com/stratax_trade)
- **Discord**: [Discord](https://discord.gg/ekdnKGKGnq)

## Features

### Leveraged Trading

- 🎯 **Leveraged Positions** - Up to 5x leverage based on asset LTV
- 💸 **Flash Loan Powered** - Capital efficient using Aave flash loans
- 🎨 **NFT-Based** - Each position is an ERC-721 token
- 🔄 **Flexible Management** - Add collateral, borrow, repay, or partially close
- 🛡️ **Safety Margins** - Built-in protection against liquidation
- 📊 **Real-Time Metrics** - Current leverage, health factor, and position value

### Token Sale

- 💰 **Multi-Token Payments** - Accept multiple whitelisted ERC20 tokens
- 📈 **Pyth Price Feed Integration** - Real-time, accurate token pricing
- 🔢 **Decimal-Agnostic Pricing** - Support price feeds with any decimal precision (2-18 decimals)
- 📅 **Flexible Vesting** - 25% immediate unlock + 75% linear vesting over 270 days
- 🎁 **Manual Vesting Schedules** - Custom vesting schedules for allocations
- 🔒 **Slippage Protection** - Minimum output enforcement during purchases

### Staking & Fee Distribution

- 🏦 **ERC4626 STRATAX Staking Vault** - Stake STRATAX and receive stSTRATAX shares
- 💎 **Multi-Token Rewards** - Earn protocol fees in the original fee tokens collected by the protocol
- ⚖️ **Configurable Fee Split** - Owner sets staker share via `stakerRewardsBps` in `FeeCollector`
- 🔄 **Pull-Based Sync** - Staking vault pulls staker allocations from `FeeCollector` and accounts per token
- 🌊 **Emission Yield Stream** - Optional STRATAX emissions streamed over time into vault assets

### Managed Vaults

- 🧠 **Manager-Controlled Leverage** - A designated manager operates leverage on one underlying Stratax position
- 📦 **ERC4626 Wrapper** - Users deposit collateral token and receive transferable vault shares
- 🎯 **Target-Leverage Rebalancing** - Manager can increase leverage to target or unwind down to target
- 🚦 **Pause/Deactivate Controls** - Manager can pause operations or permanently deactivate vault actions
- 🧾 **FIFO Withdraw Queue** - Share holders can queue withdrawals when idle collateral is temporarily insufficient

## How It Works

### Leveraged Long Position Example

1. User provides collateral (e.g., USDC)
2. Flash loan additional collateral
3. Supply all collateral to Aave
4. Borrow debt token (e.g., ETH)
5. Swap debt token → collateral via 1inch
6. Repay flash loan
7. Result: Leveraged long position on ETH

### Leveraged Short Position Example

Reverse the tokens: Collateral = ETH, Borrow = USDC

### Token Sale Flow

1. **Buy**: User purchases STRATAX with whitelisted payment token (e.g., USDC, ETH)
2. **Price Determination**: Pyth feeds provide real-time prices for payment tokens
3. **Decimal Normalization**: System handles price feeds with any decimal precision
4. **Immediate Unlock**: 25% of purchased tokens unlocked at TGE
5. **Linear Vesting**: Remaining 75% vests linearly over 270 days (9 months)
6. **Claim Vested**: Users claim earned vesting allocation anytime after TGE

### Staking & Fee Distribution Flow

1. **Fee Collection**: Position contracts transfer protocol fees into `FeeCollector` in fee-token units
2. **Split Calculation**: `FeeCollector` splits each tracked fee token between owner and stakers via `stakerRewardsBps`
3. **Reward Sync**: `StrataxStaking` calls `collectStakerRewardsForAllAssets()` and receives staker portions
4. **Pro-Rata Accounting**: Rewards are distributed per share using cumulative reward-per-share accounting
5. **Claim**: Stakers claim one token or all token rewards via `claimReward` / `claimAllRewards`

### Managed Vault Flow

1. **Setup**: Deploy vault for a specific Stratax position proxy (or mint position + deploy in one call)
2. **Deposit**: Users deposit collateral token and receive ERC4626 vault shares
3. **Manager Actions**: Manager increases leverage, partially unwinds, or rebalances to target leverage
4. **Accounting**: Vault total assets track idle collateral + underlying position value
5. **Exit**: Users redeem directly when idle liquidity exists, or request queued withdrawals

## Architecture

### Leveraged Position System

```
User
 └─→ StrataxPositionNft (Factory)
      └─→ Stratax Beacon Proxy (Per Position)
           ├─→ Aave V3 Pool
           ├─→ 1inch Router
           ├─→ StrataxOracle
           └─→ FeeCollector
```

### Token Sale System

```
Buyer
 └─→ StrataxTokenSale (UUPS Proxy)
      ├─→ Pyth Protocol (Price Feeds)
      ├─→ Whitelisted Payment Tokens
      └─→ STRATAX Token (ERC20)
```

### Staking & Fee System

```
Trader Activity
 └─→ Stratax Positions
     └─→ FeeCollector
         ├─→ Owner Fee Share
         └─→ Staker Fee Share
             └─→ StrataxStaking (ERC4626)
                 └─→ Stakers claim multi-token rewards
```

### Managed Vault System

```
Users
 └─→ StrataxManagedVault (ERC4626 Beacon Proxy)
     ├─→ Manager (leverage operations)
     ├─→ Underlying Stratax Position
     └─→ Withdrawal Queue (FIFO)
```

**Core Contracts:**

- `StrataxPositionNft.sol` - NFT factory for creating leveraged positions
- `Stratax.sol` - Core position logic (beacon proxy implementation)
- `StrataxTokenSale.sol` - Token sale with USD pricing and vesting
- `StrataxStaking.sol` - ERC4626 STRATAX staking vault with multi-token reward accounting
- `FeeCollector.sol` - Protocol fee collection and owner/staker fee split distribution
- `StrataxManagedVault.sol` - Manager-operated ERC4626 vault for one leveraged Stratax position
- `StrataxManagedVaultDeployer.sol` - Beacon deployer for managed vaults and one-call position+vault deploys
- `StrataxOracle.sol` - Chainlink price feed aggregator (for position pricing)
- `StrataxCalculations.sol` - Pure calculation library

## Quick Start

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Node.js (optional for scripts)

### Installation

```bash
# Clone repository
git clone <repository-url>
cd contracts

# Install dependencies
forge install

# Build contracts
forge build
```

### Testing

```bash
# Run unit tests
forge test

# Run fork tests (requires RPC URL in .env)
forge test --fork-url $MAINNET_RPC_URL

# Run specific test contract
forge test test/fork/StrataxTokenSale.t.sol

# Run with gas report
forge test --gas-report

# Run tests matching a pattern
forge test --match-test "test_NormalizePriceWith"
```

**Token Sale Tests**: Includes comprehensive tests for price feeds with 2-18 decimals, ensuring robust normalization across different oracle precisions.

### Environment Setup

Create `.env` file:

```bash
MAINNET_RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY
PRIVATE_KEY=your_private_key
ETHERSCAN_API_KEY=your_etherscan_key
```

## Deployment

```bash
# Deploy full system to mainnet
forge script script/DeployStrataxSystem.s.sol \
    --rpc-url $MAINNET_RPC_URL \
    --private-key $PRIVATE_KEY \
    --broadcast \
    --verify

# Deploy to testnet
forge script script/DeployStrataxSystem.s.sol \
    --rpc-url $SEPOLIA_RPC_URL \
    --private-key $PRIVATE_KEY \
    --broadcast
```

See [Deployment Guide](docs/deployment/deployment-guide.md) for details.

### Token Sale Configuration

After deployment, configure the token sale:

```solidity
// Whitelist payment tokens with Pyth price feeds
sale.whitelistPaymentToken(USDC, pythUsdcPriceFeed, 7 days);
sale.whitelistPaymentToken(WETH, pythEthPriceFeed, 7 days);

// Create bulk vesting schedules
address[] memory beneficiaries = [...];
uint256[] memory amounts = [...];
uint64[] memory startTimestamps = [...];
uint64[] memory durations = [...];

sale.createManualVestings(beneficiaries, amounts, startTimestamps, durations);

// Update STRATAX price (in USD with 8 decimals)
sale.setStrataxPriceUsd(20_000_000); // $0.20
```

**Key Configuration Points:**

- **Payment Tokens**: Whitelist supported tokens and their Pyth price feed IDs
- **Max Price Age**: Set maximum acceptable price staleness (e.g., 7 days)
- **STRATAX Price**: Configure sale price in USD with 8-decimal precision
- **Vesting Schedules**: Create custom vesting for team, strategic investors, etc.

### Staking & Fee Split Configuration

After deploying `FeeCollector` and `StrataxStaking`, wire fee distribution:

```solidity
// Set staking contract allowed to collect staker rewards
feeCollector.setStakingContract(address(staking));

// Configure staker share of protocol fees (example: 7000 = 70%)
feeCollector.setStakerRewardsBps(7000);

// Optional STRATAX emissions
staking.setStrataxEmissionRatePerSecond(emissionRate);
staking.fundStrataxEmissions(emissionReserveAmount);
```

### Managed Vault Configuration

Managed vaults are manager-operated and deployed via beacon proxies:

```solidity
// Deploy a vault for an existing Stratax position
address vault = deployer.deployVault(
    strataxProxy,
    manager,
    "Managed ETH Vault",
    "mvETH",
    30000 // 3.0x target leverage, precision=1e4
);
```

Operational notes:

- Manager-only methods control target leverage, pausing, and unwind/rebalance operations
- Withdrawal queue is FIFO and processed by manager when idle collateral is available
- `deactivate()` permanently disables active vault operation paths and enforces paused state

## Documentation

Comprehensive documentation available in the [docs/](docs/) folder:

- [Architecture Overview](docs/architecture/overview.md)
- [Leverage Mechanics](docs/architecture/leverage-mechanics.md)
- [Flash Loan Flow](docs/architecture/flashloan-flow.md)
- [Opening a Position](docs/guides/opening-position.md)
- [Contract Reference](docs/contracts/stratax.md)
- [Deployment Guide](docs/deployment/deployment-guide.md)

## Security

### Position Protocol

- Built with OpenZeppelin upgradeable contracts
- Reentrancy protection on all external calls
- Slippage protection on swaps
- Health factor validation
- Owner-only position management

### Token Sale

- UUPS upgradeable pattern with owner-only upgrades
- Reentrancy protection on purchase and claim functions
- Slippage protection via minimum output enforcement
- Price feed staleness validation
- Decimal-precision independent pricing (handles 2-18 decimals)
- Safe arithmetic with OpenZeppelin SafeERC20

### Staking & Managed Vaults

- Staking rewards use per-token cumulative accounting with explicit claim paths
- Fee split is transparent and configurable via `stakerRewardsBps`
- Managed vault leverage controls are restricted to designated manager role
- Vault supports pause/deactivate risk controls and queued withdrawals for liquidity management

**Audits**: [Coming Soon]() <!-- Add audit report link -->

## Contributing

Contributions welcome! Please open an issue or PR.

## License

UNLICENSED - See [LICENSE](LICENSE) for details.

## Acknowledgments

Built with:

- [Aave V3](https://aave.com/) - Lending protocol & flash loans
- [1inch](https://1inch.io/) - DEX aggregation
- [Chainlink](https://chain.link/) - Position oracle pricing
- [Pyth](https://pyth.network/) - Token sale price feeds
- [OpenZeppelin](https://openzeppelin.com/) - Secure contract libraries
- [Foundry](https://getfoundry.sh/) - Development framework
