# StrataxTokenSale

`StrataxTokenSale` is an upgradeable token sale contract that prices STRATAX in USD and accepts whitelisted payment tokens.

## Highlights

- UUPS upgradeable
- Pyth price feed integration
- Decimal-agnostic price normalization to USD 8 decimals
- 25% immediate unlock at purchase
- 75% linear vesting over 270 days
- Manual vesting schedule support

## Core Parameters

- `strataxPriceUsd`: STRATAX price in USD with 8 decimals
- `PUBLIC_SALE_TGE_BPS = 2500` (25%)
- `PUBLIC_SALE_VESTING_DURATION = 270 days`
- `PUBLIC_SALE_ALLOCATION_BPS = 2000` (20% of tokenomics supply cap)

## Payment Tokens

Owner whitelists payment tokens with:

- Token address
- Pyth price feed ID
- Max price age

```solidity
sale.whitelistPaymentToken(token, pythPriceId, maxPriceAge);
```

## Purchase Flow

1. Validate sale state and payment token whitelist
2. Optionally update Pyth feeds
3. Read payment token price from Pyth
4. Normalize Pyth `(price, expo)` to USD 8 decimals
5. Compute STRATAX output from payment amount and `strataxPriceUsd`
6. Transfer payment token to recipient
7. Transfer immediate unlock portion to buyer
8. Record vested allocation for future claims

## Decimal-Agnostic Price Normalization

Pyth feeds may use different exponents (for example `-6`, `-8`, `-18`).

The sale normalizes all prices to USD 8 decimals before quote/buy logic so mixed feed precisions produce consistent behavior.

## Vesting

### Public sale vesting

- Immediate: 25%
- Vested: 75% linearly from `saleStartTimestamp`
- Users claim via `claimVestedTokens()`

### Manual vesting

Owner can create one or batch vesting schedules with custom start and duration.

```solidity
sale.createManualVesting(beneficiary, amount, startTimestamp, duration);
sale.createManualVestings(beneficiaries, amounts, startTimestamps, durations);
```

## Admin Functions

- `setStrataxPriceUsd(...)`
- `setPaymentRecipient(...)`
- `setPyth(...)`
- `whitelistPaymentToken(...)`
- `removePaymentToken(...)`
- `pauseSale()` / `unpauseSale()` / `closeSale()`

## Safety Notes

- `buy(...)` includes slippage guard via `minStrataxOut`
- Price staleness enforced by max price age
- Non-reentrant purchase and claim paths

## Related Pages

- [Token Sale Guide](../guides/token-sale.md)
- [Configuration](../deployment/configuration.md)
