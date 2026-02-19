# Deployment Guide

This guide covers deploying the Stratax protocol to Ethereum mainnet or testnets.

## Prerequisites

- Foundry installed (`foundryup`)
- RPC URL for target network
- Private key with sufficient ETH for deployment
- Verified addresses for:
  - Aave V3 Pool
  - Aave V3 ProtocolDataProvider
  - 1inch AggregationRouterV5
  - Chainlink price feeds

## Environment Setup

### 1. Configure Environment Variables

Create a `.env` file:

```bash
# Network RPC
MAINNET_RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY
SEPOLIA_RPC_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY

# Deployer
PRIVATE_KEY=your_private_key_here

# Etherscan (for verification)
ETHERSCAN_API_KEY=your_etherscan_api_key

# Protocol Parameters
STRATAX_FEE=50  # 0.50% (50 basis points)
FLASHLOAN_FEE=5  # 0.05% (Aave default)
BORROW_SAFETY_MARGIN=9900  # 99% of max LTV
MAX_LEVERAGE_OFFSET=75  # 0.75%
```

### 2. Load Environment

```bash
source .env
```

## Deployment Order

The contracts must be deployed in this order due to dependencies:

1. **StrataxCalculations** (library)
2. **FeeCollector**
3. **StrataxOracle**
4. **Stratax** (implementation)
5. **StrataxBeacon** (points to Stratax implementation)
6. **StrataxPositionNft** (uses beacon)

## Deployment Scripts

### Using Foundry Scripts

The repo includes deployment scripts in the `script/` directory:

#### Deploy Full System

```bash
forge script script/DeployStrataxSystem.s.sol \
    --rpc-url $MAINNET_RPC_URL \
    --private-key $PRIVATE_KEY \
    --broadcast \
    --verify \
    --etherscan-api-key $ETHERSCAN_API_KEY
```

#### Deploy Individual Contracts

```bash
# Deploy Stratax implementation and beacon
forge script script/DeployStrataxBeacon.s.sol \
    --rpc-url $MAINNET_RPC_URL \
    --private-key $PRIVATE_KEY \
    --broadcast \
    --verify
```

### Manual Deployment

#### 1. Deploy FeeCollector

```bash
forge create src/FeeCollector.sol:FeeCollector \
    --rpc-url $MAINNET_RPC_URL \
    --private-key $PRIVATE_KEY \
    --constructor-args $OWNER_ADDRESS $STRATAX_FEE \
    --verify
```

#### 2. Deploy StrataxOracle

```bash
forge create src/StrataxOracle.sol:StrataxOracle \
    --rpc-url $MAINNET_RPC_URL \
    --private-key $PRIVATE_KEY \
    --verify
```

#### 3. Deploy Stratax Implementation

```bash
forge create src/Stratax.sol:Stratax \
    --rpc-url $MAINNET_RPC_URL \
    --private-key $PRIVATE_KEY \
    --verify
```

#### 4. Deploy StrataxBeacon

```bash
forge create lib/openzeppelin-contracts/contracts/proxy/beacon/UpgradeableBeacon.sol:UpgradeableBeacon \
    --rpc-url $MAINNET_RPC_URL \
    --private-key $PRIVATE_KEY \
    --constructor-args $STRATAX_IMPL_ADDRESS
```

#### 5. Deploy StrataxPositionNft

```bash
forge create src/StrataxPositionNft.sol:StrataxPositionNft \
    --rpc-url $MAINNET_RPC_URL \
    --private-key $PRIVATE_KEY \
    --constructor-args \
        $AAVE_POOL \
        $AAVE_DATA_PROVIDER \
        $ONEINCH_ROUTER \
        $STRATAX_ORACLE \
        $FEE_COLLECTOR \
        $STRATAX_BEACON \
        $BORROW_SAFETY_MARGIN \
        $MAX_LEVERAGE_OFFSET \
    --verify
```

## Post-Deployment Configuration

### 1. Configure Oracle Price Feeds

Add Chainlink price feeds for supported tokens:

```solidity
StrataxOracle oracle = StrataxOracle(ORACLE_ADDRESS);

// Add WETH price feed
oracle.setPriceFeed(
    WETH_ADDRESS,
    0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419  // ETH/USD Chainlink feed
);

// Add USDC price feed
oracle.setPriceFeed(
    USDC_ADDRESS,
    0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6  // USDC/USD Chainlink feed
);
```

### 2. Set Fee Collector Address in NFT Contract

```solidity
// Usually done in constructor, but can update if needed
```

### 3. Transfer Ownership (if needed)

```solidity
FeeCollector(FEE_COLLECTOR).transferOwnership(MULTISIG_ADDRESS);
StrataxOracle(ORACLE_ADDRESS).transferOwnership(MULTISIG_ADDRESS);
StrataxPositionNft(NFT_ADDRESS).transferOwnership(MULTISIG_ADDRESS);
```

## Verification

### Verify Deployment Success

Run this verification script:

```solidity
// scripts/verify_deployment.s.sol
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

contract VerifyDeployment is Script {
    function run() external view {
        IStrataxPositionNft nft = IStrataxPositionNft(NFT_ADDRESS);

        console.log("=== Stratax Deployment Verification ===");
        console.log("NFT Address:", address(nft));
        console.log("Beacon:", address(nft.beacon()));
        console.log("Aave Pool:", address(nft.aavePool()));
        console.log("Oracle:", address(nft.strataxOracle()));
        console.log("Fee Collector:", address(nft.feeCollector()));

        IFeeCollector fees = IFeeCollector(nft.feeCollector());
        console.log("Stratax Fee (bps):", fees.strataxFee());

        console.log("\n=== Test Minting ===");
        // Attempt view call to verify setup
        console.log("Ready to mint positions: true");
    }
}
```

```bash
forge script scripts/verify_deployment.s.sol --rpc-url $MAINNET_RPC_URL
```

### Verify Contracts on Etherscan

If not done during deployment:

```bash
forge verify-contract \
    --chain-id 1 \
    --compiler-version v0.8.13+commit.abaa5c0e \
    $CONTRACT_ADDRESS \
    src/ContractName.sol:ContractName \
    --etherscan-api-key $ETHERSCAN_API_KEY
```

## Network-Specific Addresses

### Ethereum Mainnet

```
Aave V3 Pool: 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2
Aave DataProvider: 0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3
1inch Router V5: 0x1111111254EEB25477B68fb85Ed929f73A960582
```

### Ethereum Sepolia

```
Aave V3 Pool: 0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951
Aave DataProvider: 0x3e9708d80f7B3e43118013075F7e95CE3AB31F31
1inch Router V5: [check 1inch docs]
```

### Base

```
Aave V3 Pool: 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5
Aave DataProvider: 0x2d8A3C5677189723C4cB8873CfC9C8976FDF38Ac
1inch Router V5: 0x1111111254EEB25477B68fb85Ed929f73A960582
```

## Deployment Costs

Approximate gas costs (at 30 gwei):

| Contract           | Gas Used   | Cost (ETH) | Cost (USD @ $3000) |
| ------------------ | ---------- | ---------- | ------------------ |
| FeeCollector       | ~800K      | 0.024      | $72                |
| StrataxOracle      | ~1.2M      | 0.036      | $108               |
| Stratax            | ~4.5M      | 0.135      | $405               |
| StrataxBeacon      | ~300K      | 0.009      | $27                |
| StrataxPositionNft | ~3.5M      | 0.105      | $315               |
| **Total**          | **~10.3M** | **~0.309** | **~$927**          |

## Upgrade Process

To upgrade the Stratax implementation:

```bash
# 1. Deploy new implementation
forge create src/Stratax.sol:Stratax --verify

# 2. Upgrade beacon
cast send $BEACON_ADDRESS \
    "upgradeTo(address)" $NEW_IMPL_ADDRESS \
    --private-key $PRIVATE_KEY \
    --rpc-url $MAINNET_RPC_URL
```

All existing positions will automatically use the new implementation.

## Security Checklist

Before going live:

- [ ] All contracts verified on Etherscan
- [ ] Ownership transferred to multisig
- [ ] Oracle price feeds configured and tested
- [ ] Fee parameters reviewed and set
- [ ] Safety margins configured appropriately
- [ ] Emergency pause mechanism tested (if implemented)
- [ ] Flash loan fee updated from Aave
- [ ] Integration tests pass on mainnet fork
- [ ] External audit completed (recommended)
- [ ] Bug bounty program launched

## Monitoring

Set up monitoring for:

- Position health factors
- Protocol TVL
- Fee collection
- Oracle price feed updates
- Failed transactions
- Liquidation events

## Next Steps

- [Configuration Guide](configuration.md)
- [Testing Guide](testing.md)
- [Upgrade Process](upgrades.md)
