# Stratax Protocol

> Decentralized leveraged positions powered by Aave V3 and 1inch

Stratax enables users to create leveraged long or short positions on crypto assets with up to ~5x leverage, represented as transferable NFTs.

[![GitBook](https://img.shields.io/badge/Docs-GitBook-blue)]() <!-- Add GitBook URL -->
[![License](https://img.shields.io/badge/License-UNLICENSED-red)]()

## Links

- **Website**: [Coming Soon]() <!-- Add website URL -->
- **Documentation**: [GitBook Docs](docs/README.md)
- **Twitter**: <!-- Add Twitter handle -->
- **Discord**: <!-- Add Discord invite -->

## Features

- 🎯 **Leveraged Positions** - Up to 5x leverage based on asset LTV
- 💸 **Flash Loan Powered** - Capital efficient using Aave flash loans
- 🎨 **NFT-Based** - Each position is an ERC-721 token
- 🔄 **Flexible Management** - Add collateral, borrow, repay, or partially close
- 🛡️ **Safety Margins** - Built-in protection against liquidation
- 📊 **Real-Time Metrics** - Current leverage, health factor, and position value

## How It Works

### Long Position Example

1. User provides collateral (e.g., USDC)
2. Flash loan additional collateral
3. Supply all collateral to Aave
4. Borrow debt token (e.g., ETH)
5. Swap debt token → collateral via 1inch
6. Repay flash loan
7. Result: Leveraged long position on ETH

### Short Position Example

Reverse the tokens: Collateral = ETH, Borrow = USDC

## Architecture

```
User
 └─→ StrataxPositionNft (Factory)
      └─→ Stratax Beacon Proxy (Per Position)
           ├─→ Aave V3 Pool
           ├─→ 1inch Router
           ├─→ StrataxOracle
           └─→ FeeCollector
```

**Contracts:**

- `StrataxPositionNft.sol` - NFT factory for creating positions
- `Stratax.sol` - Core position logic (beacon proxy)
- `StrataxOracle.sol` - Chainlink price feed aggregator
- `FeeCollector.sol` - Protocol fee management
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

# Run with gas report
forge test --gas-report
```

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

## Documentation

Comprehensive documentation available in the [docs/](docs/) folder:

- [Architecture Overview](docs/architecture/overview.md)
- [Leverage Mechanics](docs/architecture/leverage-mechanics.md)
- [Flash Loan Flow](docs/architecture/flashloan-flow.md)
- [Opening a Position](docs/guides/opening-position.md)
- [Contract Reference](docs/contracts/stratax.md)
- [Deployment Guide](docs/deployment/deployment-guide.md)

## Security

- Built with OpenZeppelin upgradeable contracts
- Reentrancy protection on all external calls
- Slippage protection on swaps
- Health factor validation
- Owner-only position management

**Audits**: [Coming Soon]() <!-- Add audit report link -->

## Contributing

Contributions welcome! Please open an issue or PR.

## License

UNLICENSED - See [LICENSE](LICENSE) for details.

## Acknowledgments

Built with:

- [Aave V3](https://aave.com/)
- [1inch](https://1inch.io/)
- [Chainlink](https://chain.link/)
- [OpenZeppelin](https://openzeppelin.com/)
- [Foundry](https://getfoundry.sh/)
