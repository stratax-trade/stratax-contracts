# Leverage Mechanics

This document explains how leverage is calculated and achieved in the Stratax protocol.

## Understanding Leverage

Leverage amplifies both gains and losses on an asset's price movement. In Stratax, leverage is achieved by:

1. Supplying collateral to Aave
2. Borrowing against that collateral
3. Swapping borrowed assets back to collateral
4. Supplying the additional collateral

This process repeats (via flash loans) until the desired leverage is reached.

## Leverage Formula

The basic leverage formula is:

```
Leverage = Total Collateral Value / Equity
Where: Equity = Total Collateral Value - Total Debt Value
```

### Example

- Initial collateral: $1,000 USDC
- Borrow: $1,500 USDC-worth of ETH
- Swap ETH → USDC: receive ~$1,500 USDC
- Total collateral: $2,500 USDC
- Debt: $1,500
- Equity: $2,500 - $1,500 = $1,000
- **Leverage: $2,500 / $1,000 = 2.5x**

## Maximum Theoretical Leverage

Maximum leverage is determined by the asset's Loan-to-Value (LTV) ratio on Aave:

```
Max Leverage = 1 / (1 - LTV)
```

Examples:

- LTV = 80% (0.8): Max leverage = 1 / (1 - 0.8) = 5x
- LTV = 75% (0.75): Max leverage = 1 / (1 - 0.75) = 4x
- LTV = 50% (0.5): Max leverage = 1 / (1 - 0.5) = 2x

## Practical Maximum Leverage

In practice, achievable leverage is lower due to:

### 1. Borrow Safety Margin

Default: 99% of max LTV

- Prevents positions from starting near liquidation
- Provides buffer for interest accrual
- Accounts for price volatility

### 2. Flash Loan Fees

Aave charges a flash loan fee (typically 0.05%):

```
Fee = Flash Loan Amount × 0.0005
```

### 3. Protocol Fees

Stratax charges a fee based on the position size and leverage:

```
Fee = Flash Loan Amount × Stratax Fee × (Leverage / Precision)
```

### 4. Max Leverage Offset

Additional safety buffer (default 0.75% or 75 basis points):

- Accounts for slippage in swaps
- Prevents reversion at max leverage
- Adjustable per position

## Effective LTV Calculation

The effective LTV used in leverage calculations:

```solidity
effectiveLtv = ltv × (borrowSafetyMargin - maxLeverageOffset) / PRECISION
```

Example with 80% LTV:

```
effectiveLtv = 8000 × (9900 - 75) / 10000 = 7860 (78.6%)
```

This reduces max leverage from 5x to approximately 4.67x.

## Leverage Calculation Process

When opening a position with desired leverage L:

### Step 1: Calculate Borrowed Amount

```
borrowAmount = collateralAmount × (L - 1)
```

### Step 2: Calculate Flash Loan Amount

The flash loan must account for:

- The borrowed amount
- Flash loan fees
- Protocol fees

Using quadratic formula (see StrataxCalculations.sol):

```
flashLoanAmount = borrowed amount solving for:
  collateral + flashLoan - fees = achievable with LTV constraints
```

### Step 3: Verify Safety

Check that the position remains healthy:

```
totalDebt = borrowed + flashLoanFee
maxBorrow = (effectiveCollateral × effectiveLtv) / PRECISION
require(totalDebt <= maxBorrow)
```

## Binary Search for Max Leverage

To find the actual maximum achievable leverage, the protocol uses binary search:

1. Start with range: [1x, theoretical max]
2. Try midpoint leverage
3. Check if it's achievable with fees
4. Adjust range based on result
5. Repeat until converged

This is implemented in `getMaxAchievableLeverageBinary()`.

## Real-Time Leverage

The current leverage of an open position can be calculated at any time:

```solidity
function getCurrentLeverage() public view returns (uint256) {
    collateralValue = aTokenBalance × collateralPrice
    debtValue = debtTokenBalance × debtPrice
    equity = collateralValue - debtValue

    return (collateralValue × PRECISION) / equity
}
```

This accounts for:

- Accumulated interest on debt
- Accrued interest on collateral
- Price changes since opening

## Leverage Adjustment

Users can adjust leverage through:

### Increasing Leverage

1. **Borrow more** - Increases debt, increases leverage
2. **Withdraw collateral** - Decreases equity, increases leverage (risky)

### Decreasing Leverage

1. **Repay debt** - Decreases debt, decreases leverage
2. **Supply collateral** - Increases equity, decreases leverage (safer)

### Partial Close

Reduces position proportionally while maintaining similar leverage ratio.

## Precision and Constants

All leverage calculations use 4 decimal precision:

- `LEVERAGE_PRECISION = 10000`
- 1.0x = 10000
- 2.5x = 25000
- 5.0x = 50000

Related constants:

- `LTV_PRECISION = 10000` (basis points)
- `BORROW_SAFETY_PRECISION = 10000`
- `FLASHLOAN_FEE_PREC = 10000`

## Risk Considerations

### Over-Leveraging Risks

- Higher liquidation risk
- Greater sensitivity to price movements
- Higher interest costs
- Larger slippage impact

### Safety Best Practices

1. Start with lower leverage (2-3x)
2. Monitor health factor regularly
3. Maintain buffer above minimum
4. Consider adding collateral proactively
5. Understand liquidation thresholds

## Examples

### Long ETH at 3x Leverage

```
Initial: 10 ETH ($20,000)
Borrow: $40,000 USDC
Swap: $40,000 USDC → 20 ETH
Total: 30 ETH collateral, $40,000 debt
Leverage: 3x
```

**If ETH +10%**:

- Collateral: 30 ETH = $66,000
- Debt: $40,000
- Profit: $6,000 (30% on $20,000 equity)

**If ETH -10%**:

- Collateral: 30 ETH = $54,000
- Debt: $40,000
- Loss: $6,000 (-30% on $20,000 equity)

## Next Steps

- [Flash Loan Flow](flashloan-flow.md) - How flash loans execute leverage
- [Health Factor](../guides/health-factor.md) - Understanding liquidation risk
- [StrataxCalculations](../contracts/stratax-calculations.md) - Math implementation
