# Stratax Protocol — Frontend Integration Overview

## What is Stratax?

Stratax is a **leveraged position management protocol** on Ethereum. Users deposit collateral (e.g., USDC), select a desired leverage multiplier (e.g., 2.5x), and the protocol atomically opens a flash-loan-powered leveraged position on Aave V3 or Fluid lending markets, using Uniswap V3 or 1inch for the swap leg.

Each position is represented as an **ERC721 NFT** — the NFT owner controls the position. A **StrataxRouter** contract simplifies all user interactions into single-call transactions.

The protocol also includes a **STRATAX token**, a **token sale** with vesting, an **ERC4626 staking vault** (stSTRATAX), and **managed vaults** that let delegated managers control leverage on behalf of depositors.

---

## Architecture Summary

```
User
  │
  ▼
StrataxRouter ─────────────── Main entry point (all user txs go here)
  │
  ├─► StrataxPositionNft ──── ERC721 — mints NFTs, deploys per-position proxies
  │     │
  │     └─► BeaconProxy ───── Per-position proxy (one per NFT)
  │           │
  │           ├─► Stratax_Aave_Uniswap  (Aave + Uniswap V3)
  │           ├─► Stratax_Aave_1Inch    (Aave + 1inch aggregator)
  │           └─► Stratax_Fluid_Uniswap (Fluid + Uniswap V3)
  │
  ├─► StrataxOracle ────────── Chainlink-based price feeds (8 decimals)
  ├─► FeeCollector ─────────── Collects protocol fees, distributes to stakers
  ├─► StrataxStaking ───────── ERC4626 vault: stake STRATAX → stSTRATAX + fee rewards
  ├─► StrataxTokenSale ─────── Buy STRATAX with whitelisted tokens, linear vesting
  └─► StrataxManagedVault ──── ERC4626 wrapper for delegated-manager positions
```

---

## Position Lifecycle

### 1. Open Position

```
User → Router.createAaveUniswapPosition(collateral, leverage, poolFee)
  → Mint NFT + deploy proxy
  → Transfer collateral from user
  → Proxy: flash loan → supply collateral → borrow → swap → repay flash loan
  → Transfer NFT to user
```

### 2. Manage Position (while open)

- **Supply more collateral**: `Router.supplyCollateral(tokenId, amount)`
- **Withdraw collateral**: `Router.withdrawCollateral(tokenId, amount)`
- **Borrow more debt**: `Router.borrowDebtToken(tokenId, amount)`
- **Repay debt**: `Router.repayDebtToken(tokenId, amount)`

### 3. Close/Unwind Position

```
User → Router.unwindAaveUniswapPosition(tokenId, debtToRepay, poolFee)
  → Flash loan borrow token → repay Aave debt → withdraw collateral → swap → repay flash loan
  → Remaining collateral stays as supplied collateral in Aave (earning yield)
```

### 4. Burn Position (optional, after full unwind)

- `position.burnPosition()` — Burns the NFT, allows `recoverTokens()` to withdraw leftover funds.

---

## Token & Protocol IDs

| Protocol Pair   | Lending ID                      | Swap ID                        |
| --------------- | ------------------------------- | ------------------------------ |
| Aave + Uniswap  | `keccak256("LENDING:AAVE_V3")`  | `keccak256("SWAP:UNISWAP_V3")` |
| Aave + 1inch    | `keccak256("LENDING:AAVE_V3")`  | `keccak256("SWAP:ONEINCH_V6")` |
| Fluid + Uniswap | `keccak256("LENDING:FLUID_V1")` | `keccak256("SWAP:UNISWAP_V3")` |

---

## Key Precision Constants

| Name                   | Value  | Meaning                                |
| ---------------------- | ------ | -------------------------------------- |
| `LEVERAGE_PRECISION`   | 10,000 | 10000 = 1x, 25000 = 2.5x, 30000 = 3x   |
| `FLASHLOAN_FEE_PREC`   | 10,000 | Basis points (100 = 1%, 5 = 0.05%)     |
| `LTV_PRECISION`        | 10,000 | Loan-to-value (8000 = 80%)             |
| `BPS`                  | 10,000 | Generic basis points                   |
| `PRICE_FEED_PREC`      | 1e8    | Chainlink price precision (8 decimals) |
| `DEFAULT_SLIPPAGE_BPS` | 50     | 0.5% default slippage buffer           |

---

## Fee Structure

- **Protocol fee** (strataxFee): Configurable, default **5 bps (0.05%)** on borrow volume
- **Flash loan fee**: Aave's native premium (~5 bps on mainnet)
- Fees are collected in the collateral token (on open) or debt token (on unwind)
- FeeCollector distributes fees between protocol owner and stakers based on `stakerRewardsBps`
