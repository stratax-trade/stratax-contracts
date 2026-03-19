# Token Sale Guide

This guide explains how buyers participate in STRATAX token sale rounds.

## Prerequisites

- A whitelisted payment token (for example WETH/USDC)
- Token approval to `StrataxTokenSale`
- Wallet gas for transaction fees

## Step 1: Check Quote

Use `quote(paymentToken, paymentAmount)` to estimate output.

The quote uses:

- Pyth token/USD price
- Decimal normalization to USD 8 decimals
- Current `strataxPriceUsd`

## Step 2: Buy Tokens

Call:

```solidity
buy(paymentToken, paymentAmount, minStrataxOut, pythUpdateData)
```

Tips:

- Set `minStrataxOut` to protect against price drift
- If oracle update data is required, include valid `pythUpdateData` and fee value

## Step 3: Understand Unlock + Vesting

On successful purchase:

- 25% is unlocked immediately
- 75% vests linearly over 270 days

## Step 4: Claim Vested Tokens

Call:

```solidity
claimVestedTokens();
```

as vesting accrues.

## Common Issues

- `Payment token not whitelisted`: token not enabled by owner
- `Slippage: insufficient STRATAX out`: `minStrataxOut` too high
- stale price errors: oracle data older than configured max age

## Related Pages

- [StrataxTokenSale](../contracts/stratax-token-sale.md)
- [Configuration](../deployment/configuration.md)
