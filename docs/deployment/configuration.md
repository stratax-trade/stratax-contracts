# Configuration Guide

This guide covers configuring the Stratax protocol after deployment.

## Initial Configuration

### 1. Oracle Price Feeds

Add Chainlink price feeds for all supported tokens:

```solidity
IStrataxOracle oracle = IStrataxOracle(ORACLE_ADDRESS);

// Add price feeds
oracle.setPriceFeed(WETH, WETH_USD_FEED);
oracle.setPriceFeed(WBTC, WBTC_USD_FEED);
oracle.setPriceFeed(USDC, USDC_USD_FEED);
oracle.setPriceFeed(DAI, DAI_USD_FEED);
oracle.setPriceFeed(USDT, USDT_USD_FEED);
```

**Mainnet Chainlink Feeds**:

```
WETH/USD: 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419
WBTC/USD: 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c
USDC/USD: 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6
DAI/USD: 0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9
USDT/USD: 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D
```

### 2. Protocol Fees

Set initial protocol fee (if not set in constructor):

```solidity
IFeeCollector feeCollector = IFeeCollector(FEE_COLLECTOR);
feeCollector.setStrataxFee(30);  // 0.30% (30 basis points)
```

**Recommended**: 20-50 bps (0.20% - 0.50%)

### 3. Safety Parameters

Configure default safety parameters in StrataxPositionNft:

```solidity
// Set during deployment, but can verify:
borrowSafetyMargin = 9900;  // 99% of max LTV
maxLeverageOffset = 75;     // 0.75%
```

These become defaults for all new positions.

## Per-Position Configuration

### Adjust Borrow Safety Margin

For individual positions (owner only):

```solidity
IStratax stratax = IStratax(positionContract);

// More conservative (98% of max LTV)
stratax.updateBorrowSafetyMargin(9800);

// Less conservative (99.5% of max LTV)
stratax.updateBorrowSafetyMargin(9950);
```

**Warning**: Lower values = higher max leverage but higher liquidation risk

### Adjust Max Leverage Offset

```solidity
// More conservative offset (1%)
stratax.updateMaxLeverageOffset(100);

// Less conservative (0.5%)
stratax.updateMaxLeverageOffset(50);
```

**Maximum allowed**: 500 (5%)

### Update 1inch Router

If 1inch deploys new router:

```solidity
stratax.update1InchRouter(NEW_ROUTER_ADDRESS);
```

### Update Flash Loan Fee

Sync with current Aave fee:

```solidity
stratax.updateFlashLoanFee();
```

Call periodically or when Aave changes fees.

## Monitoring & Maintenance

### Price Feed Monitoring

Set up monitoring for:

```javascript
// Check price feed freshness
const roundData = await priceFeed.latestRoundData();
const staleness = Date.now() / 1000 - roundData.updatedAt;

if (staleness > 3600) {
  // 1 hour
  console.warn("Price feed stale!");
}
```

### Health Factor Monitoring

Monitor positions approaching liquidation:

```javascript
const healthFactor = await aavePool.getUserAccountData(positionAddress);

if (healthFactor < 1.2e18) {
  alert("Position at risk!");
}
```

### Fee Collection

Regularly collect accumulated fees:

```solidity
IFeeCollector feeCollector = IFeeCollector(FEE_COLLECTOR);

// Withdraw WETH fees
feeCollector.withdrawFees(WETH, amount);

// Withdraw USDC fees
feeCollector.withdrawFees(USDC, amount);
```

## Multi-Sig Configuration

### Transfer Ownership

After deployment, transfer to multi-sig:

```solidity
// FeeCollector
IFeeCollector(FEE_COLLECTOR).transferOwnership(MULTISIG);

// StrataxOracle
IStrataxOracle(ORACLE).transferOwnership(MULTISIG);

// StrataxPositionNft
IStrataxPositionNft(NFT).transferOwnership(MULTISIG);

// Beacon (for upgrades)
IUpgradeableBeacon(BEACON).transferOwnership(MULTISIG);
```

### Recommended Multi-Sig

- **Members**: 3-7 trusted parties
- **Threshold**: 3/5 or 4/7
- **Platform**: Gnosis Safe
- **Network**: Same as deployment

## Advanced Configuration

### Custom Price Feeds

Add custom or alternative price sources:

```solidity
// If token doesn't have Chainlink feed
oracle.setPriceFeed(
    CUSTOM_TOKEN,
    CUSTOM_FEED_ADDRESS  // Must implement AggregatorV3Interface
);
```

### Emergency Pause (If Implemented)

```solidity
// Pause new positions
nft.pause();

// Unpause
nft.unpause();
```

_Note: Existing positions remain operable_

### Blacklist Tokens (If Needed)

Prevent certain token pairs:

```solidity
// Example: Prevent using high-risk token as collateral
nft.setTokenBlacklist(RISKY_TOKEN, true);
```

_Note: This would require custom implementation_

## Integration Configuration

### Supported Token Pairs

Document which pairs are officially supported:

```javascript
const supportedPairs = {
  long: [
    { collateral: "WETH", borrow: "USDC" }, // Long ETH
    { collateral: "WBTC", borrow: "USDC" }, // Long BTC
    { collateral: "WETH", borrow: "DAI" }, // Long ETH
  ],
  short: [
    { collateral: "USDC", borrow: "WETH" }, // Short ETH
    { collateral: "USDC", borrow: "WBTC" }, // Short BTC
    { collateral: "DAI", borrow: "WETH" }, // Short ETH
  ],
};
```

### Leverage Limits

Set UI display limits:

```javascript
const leverageLimits = {
  WETH: { min: 1.1, max: 4.5, recommended: 3.0 },
  WBTC: { min: 1.1, max: 3.0, recommended: 2.5 },
  USDC: { min: 1.1, max: 4.5, recommended: 3.0 },
};
```

### Slippage Defaults

Configure default slippage tolerances:

```javascript
const slippageDefaults = {
  normal: 0.5, // 0.5%
  volatile: 1.5, // 1.5%
  conservative: 0.3, // 0.3%
};
```

## Token Sale Configuration

Configure token sale payment assets and pricing:

```solidity
StrataxTokenSale sale = StrataxTokenSale(TOKEN_SALE_ADDRESS);

// Price in USD with 8 decimals (example: $0.20)
sale.setStrataxPriceUsd(20_000_000);

// Whitelist payment tokens with Pyth feed IDs
sale.whitelistPaymentToken(WETH, PYTH_ETH_USD_ID, 7 days);
sale.whitelistPaymentToken(USDC, PYTH_USDC_USD_ID, 7 days);
```

Notes:

- Pyth exponents can vary by feed; sale normalizes all prices to 8 decimals.
- Use conservative max price age values for your operational risk profile.

## Staking and Fee Split Configuration

Wire `FeeCollector` and `StrataxStaking` after deployment:

```solidity
FeeCollector feeCollector = FeeCollector(FEE_COLLECTOR_ADDRESS);
StrataxStaking staking = StrataxStaking(STAKING_ADDRESS);

// Allow staking contract to pull staker-side rewards
feeCollector.setStakingContract(address(staking));

// Example: 70% of protocol fees to stakers
feeCollector.setStakerRewardsBps(7000);

// Optional STRATAX emissions
staking.setStrataxEmissionRatePerSecond(EMISSION_RATE);
staking.fundStrataxEmissions(EMISSION_RESERVE);
```

Operational recommendation:

- Set and monitor `stakerRewardsBps` with governance/multisig controls.

## Managed Vault Configuration

Deploy and initialize managed vaults through the deployer:

```solidity
StrataxManagedVaultDeployer deployer = StrataxManagedVaultDeployer(DEPLOYER_ADDRESS);

address vault = deployer.deployVault(
    STRATAX_POSITION_PROXY,
    MANAGER_ADDRESS,
    "Managed ETH Vault",
    "mvETH",
    30000 // 3x target leverage
);
```

Manager runbook:

- Set target leverage according to strategy constraints.
- Use pause/deactivate controls as emergency response tools.
- Process FIFO withdrawal queue periodically when idle collateral is available.

## Testing Configuration

### Testnet Setup

Use testnet faucets and deployments:

**Sepolia**:

```
Aave Pool: 0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951
WETH: 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9
USDC: [Aave Sepolia USDC]
```

### Fork Testing

Test against mainnet fork:

```bash
# Start local fork
anvil --fork-url $MAINNET_RPC

# Run tests
forge test --fork-url http://localhost:8545
```

## Production Checklist

Before going live:

- [ ] All price feeds configured and tested
- [ ] Protocol fees set appropriately
- [ ] Safety parameters reviewed
- [ ] Ownership transferred to multi-sig
- [ ] Monitoring systems active
- [ ] Emergency procedures documented
- [ ] User documentation complete
- [ ] Integration tests pass
- [ ] Security audit completed
- [ ] Bug bounty program ready

## Updating Configuration

### Via Multi-Sig

Create multi-sig transaction for:

1. **Add Price Feed**

```solidity
oracle.setPriceFeed(newToken, newFeed);
```

2. **Update Protocol Fee**

```solidity
feeCollector.setStrataxFee(newFeeBps);
```

3. **Collect Fees**

```solidity
feeCollector.withdrawFees(token, amount);
```

### Logging Changes

Maintain changelog:

```markdown
## 2024-03-15

- Added LINK price feed
- Updated protocol fee: 30 → 35 bps
- Collected 10 ETH in fees

## 2024-03-01

- Initial deployment
- Set all major price feeds
- Transferred ownership to multi-sig
```

## Next Steps

- [Deployment Guide](deployment-guide.md)
- [Testing Guide](testing.md)
- [Upgrades](upgrades.md)
