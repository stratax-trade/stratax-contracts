# Staking, Fees, and Managed Vaults

This page describes how protocol fees are split, how stakers earn rewards, and how managed leveraged vaults operate.

## Fee Flow

Protocol fees are collected by position contracts into `FeeCollector` in the token used by each operation.

- Fees are tracked per fee token.
- Owner and staker entitlements are computed from total collected amounts.
- Split ratio is controlled by `stakerRewardsBps`.

The split uses:

- Staker entitlement = `totalCollected * stakerRewardsBps / 10_000`
- Owner entitlement = `totalCollected - staker entitlement`

When staking sync is triggered, pending staker and owner portions are transferred.

## Staking Reward Model

`StrataxStaking` is an ERC4626 vault where the asset is STRATAX.

Staker value accrues from two sources:

1. Multi-token protocol rewards pulled from `FeeCollector`
2. Optional STRATAX emissions streamed over time

### Multi-token reward accounting

The staking contract tracks each reward token with cumulative reward-per-share accounting.

- `accRewardPerShare[token]` tracks distributed rewards per share.
- `userRewardDebt[user][token]` tracks prior accounting checkpoint.
- `userClaimable[user][token]` stores claimable amounts.

This ensures pro-rata reward ownership across mint, deposit, transfer, withdraw, and redeem flows.

### Emission streaming

Owner can fund emission reserves and set `strataxEmissionRatePerSecond`.

- Reserved emission is excluded from `totalAssets()` until emitted.
- Emissions only accrue when there are stakers.
- Emitted STRATAX increases vault asset value over time.

## Managed Vault Model

`StrataxManagedVault` wraps a single underlying Stratax position in an ERC4626 vault.

- Users deposit collateral token and receive vault shares.
- A manager role controls leverage operations.
- Target leverage uses 4-decimal precision (`10000 = 1x`, `30000 = 3x`).

### Rebalancing operations

Manager can:

- Increase leverage toward target: `increaseLeverageToTarget(...)`
- Unwind specific amount: `unwindPosition(...)`
- Unwind down to target: `unwindPositionToTarget(...)`

### Liquidity and withdrawal queue

Withdraw/redeem uses idle collateral if available. If idle collateral is insufficient, users can queue withdrawals:

- `requestWithdrawal(shares, receiver)` burns shares and enqueues request.
- `processWithdrawalQueue(maxRequests)` processes requests FIFO when idle collateral is available.
- `cancelWithdrawalRequest(requestId)` restores shares for unprocessed requests.

## Deployment Pattern

Managed vaults are deployed with beacon proxies using `StrataxDeployer_Aave_1Inch`.

Two deployment paths are supported:

1. Deploy vault for an existing Stratax proxy.
2. Mint position + deploy vault + transfer position NFT to vault in one call.

## Roles and Controls

- `FeeCollector owner`: sets `stakerRewardsBps` and staking contract.
- `StrataxStaking owner`: sets emission rate, funds emissions, updates fee collector.
- `Managed vault manager`: controls leverage and queue processing, pause/deactivate.

## Related Pages

- [StrataxStaking](../contracts/stratax-staking.md)
- [StrataxManagedVault](../contracts/stratax-managed-vault.md)
- [Token Sale](../contracts/stratax-token-sale.md)
- [Configuration](../deployment/configuration.md)
