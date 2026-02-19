# Constants & Parameters

This document details all constants and configurable parameters used in the Stratax protocol.

## Precision Constants

All precision constants use 4 decimal places (basis points):

### StrataxCalculations Library

```solidity
// Basis points precision for flash loan fees
uint256 public constant FLASHLOAN_FEE_PREC = 10_000;  // 10000 = 100%

// Price feed precision (Chainlink standard)
uint256 public constant PRICE_FEED_PREC = 1e8;  // 8 decimals

// LTV precision in basis points
uint256 public constant LTV_PRECISION = 10_000;  // 10000 = 100%

// Leverage precision
uint256 public constant LEVERAGE_PRECISION = 10_000;  // 10000 = 1x leverage

// Borrow safety margin precision
uint256 public constant BORROW_SAFETY_PRECISION = 10_000;  // 10000 = 100%

// Max leverage offset precision
uint256 public constant MAX_LEVERAGE_OFFSET_PRECISION = 10_000;  // 10000 = 100%

// Base collateral for calculations
uint256 public constant BASE_COLLATERAL = 1e18;  // 1 unit with 18 decimals
```

### Example Values

| Constant           | Value | Meaning             |
| ------------------ | ----- | ------------------- |
| FLASHLOAN_FEE_PREC | 10000 | 100% = 10000 bps    |
| LTV_PRECISION      | 10000 | 80% LTV = 8000      |
| LEVERAGE_PRECISION | 10000 | 3x leverage = 30000 |

## Stratax Contract

### Aave Constants

```solidity
// Aave variable debt interest rate mode
uint256 public constant VARIABLE_DEBT = 2;
```

### Configurable Parameters

```solidity
// Safety margin for borrow calculations (default: 99% of max LTV)
uint256 public borrowSafetyMargin = 9900;

// Offset from max leverage (default: 0.75%)
uint256 public maxLeverageOffset = 75;

// Flash loan fee in basis points (fetched from Aave)
uint256 public flashLoanFeeBps;  // Typically 5 (0.05%)
```

## StrataxPositionNft Contract

### Token ID Management

```solidity
// Counter for token IDs
uint256 private _nextTokenId = 1;
```

### Initialization Parameters

```solidity
struct StrataxInit {
    address aavePool;
    address aaveDataProvider;
    address oneInchRouter;
    address strataxOracle;
    address feeCollector;
    address beacon;
    uint256 borrowSafetyMargin;    // Default: 9900
    uint256 maxLeverageOffset;     // Default: 75
}
```

## FeeCollector Contract

### Fee Parameters

```solidity
// Protocol fee in basis points
uint256 public strataxFee;  // e.g., 50 = 0.50%
```

Default values:

- **Recommended**: 15-50 bps (0.15% - 0.50%)
- **Maximum**: Consider capping at 100 bps (1.00%)

## Leverage Limits

### Theoretical Maximum Leverage

Based on asset LTV:

| LTV | Max Theoretical Leverage |
| --- | ------------------------ |
| 50% | 2.0x                     |
| 60% | 2.5x                     |
| 70% | 3.33x                    |
| 75% | 4.0x                     |
| 80% | 5.0x                     |
| 85% | 6.67x                    |

### Practical Maximum Leverage

After accounting for fees and safety margins:

| Asset | LTV | Safety Margin | Achievable Leverage |
| ----- | --- | ------------- | ------------------- |
| WETH  | 80% | 99% + offset  | ~4.6x               |
| WBTC  | 70% | 99% + offset  | ~3.1x               |
| USDC  | 80% | 99% + offset  | ~4.6x               |
| DAI   | 75% | 99% + offset  | ~3.8x               |

_Actual values depend on current fees and safety parameters_

## Safety Parameters

### Borrow Safety Margin

Reduces effective LTV to prevent immediate liquidation risk:

```
effectiveLtv = ltv × borrowSafetyMargin / PRECISION
```

Examples:

- `borrowSafetyMargin = 9900` (99%): If LTV = 80%, effective = 79.2%
- `borrowSafetyMargin = 9500` (95%): If LTV = 80%, effective = 76%

**Recommended values**: 9800 - 9950 (98% - 99.5%)

### Max Leverage Offset

Additional buffer for slippage protection:

```
finalEffectiveLtv = ltv × (borrowSafetyMargin - maxLeverageOffset) / PRECISION
```

Examples:

- `maxLeverageOffset = 75` (0.75%): Reduces effective LTV by 0.75%
- `maxLeverageOffset = 100` (1%): Reduces effective LTV by 1%

**Recommended values**: 50 - 150 (0.5% - 1.5%)
**Maximum allowed**: 500 (5%)

## Fee Structure

### Protocol Fees

Stratax protocol fee is calculated as:

```solidity
fee = flashLoanAmount × strataxFee × leverage / (FEE_PREC × LEVERAGE_PREC)
```

This makes fees proportional to both position size and leverage.

#### Examples

For a $10,000 position:

- 2x leverage, 0.30% fee: ~$6 fee
- 3x leverage, 0.30% fee: ~$9 fee
- 5x leverage, 0.30% fee: ~$15 fee

### External Fees

#### Aave Flash Loan Fee

- **Current**: 0.05% (5 basis points)
- **Fetched from**: `aavePool.FLASHLOAN_PREMIUM_TOTAL()`
- **Updates**: Automatically via `updateFlashLoanFee()`

#### 1inch Swap Fees

- **Variable**: Depends on route and liquidity
- **Typical**: 0.1% - 0.5%
- **Protected by**: `minReturnAmount` parameter

## Network-Specific Constants

### Mainnet

```solidity
// Chainlink price feeds (8 decimals)
WETH/USD: 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419
USDC/USD: 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6
WBTC/USD: 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c
DAI/USD: 0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9
```

## Gas Limits

Recommended gas limits for operations:

| Operation           | Gas Limit | Notes                          |
| ------------------- | --------- | ------------------------------ |
| Mint Position       | 500K      | Creates proxy + initialization |
| Open Position       | 1.5M      | Includes flash loan callback   |
| Close Position      | 1.2M      | Includes flash loan callback   |
| Supply Collateral   | 200K      | Simple Aave supply             |
| Withdraw Collateral | 250K      | Aave withdrawal                |
| Borrow              | 300K      | Aave borrow + transfer         |
| Repay               | 300K      | Transfer + Aave repay          |

## Time Constants

### Chainlink Staleness

Price feeds considered stale after:

```solidity
uint256 constant STALE_PRICE_THRESHOLD = 1 hours;
```

_Note: Currently not enforced in StrataxOracle but recommended for production_

## Slippage Tolerances

### Recommended Slippage

| Market Conditions | Slippage  | Use Case                |
| ----------------- | --------- | ----------------------- |
| Normal            | 0.5% - 1% | Standard operations     |
| Volatile          | 1% - 3%   | High volatility periods |
| Low Liquidity     | 2% - 5%   | Smaller cap tokens      |

### Slippage Buffers

Built into calculations:

```solidity
// Unwind operation includes 5% buffer for swap slippage
collateralToWithdraw = (calculated × 1050) / 1000;
```

## Health Factor Thresholds

### Aave Liquidation

- **Threshold**: < 1.0 (subject to liquidation)

### Stratax Recommendations

- **Minimum**: > 1.2 (warning territory)
- **Safe**: > 1.5 (healthy position)
- **Conservative**: > 2.0 (very safe)

## Updating Parameters

### Owner-Updatable

Via contract owner:

- `borrowSafetyMargin` (per position)
- `maxLeverageOffset` (per position)
- `strataxFee` (FeeCollector)
- Oracle price feeds (Oracle)
- 1inch router (per position)

### Automatically Updated

- `flashLoanFeeBps`: Call `updateFlashLoanFee()` to sync with Aave
- Token prices: Fetched on-demand from Chainlink

### Immutable

- Contract addresses (after deployment)
- Collateral/borrow tokens (per position)
- Token decimals (cached at init)
- Precision constants

## Best Practices

1. **Safety Margins**: Keep borrowSafetyMargin ≥ 98% (9800)
2. **Leverage Offset**: Adjust based on market volatility (75-150)
3. **Protocol Fees**: Balance competitiveness vs sustainability (20-50 bps)
4. **Slippage**: Use tighter values in stable conditions, wider in volatile
5. **Health Buffer**: Aim for 1.5+ health factor, never < 1.2

## Next Steps

- [Leverage Mechanics](../architecture/leverage-mechanics.md)
- [Configuration Guide](../deployment/configuration.md)
- [Safety Considerations](../security/considerations.md)
