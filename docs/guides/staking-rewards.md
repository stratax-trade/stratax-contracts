# Staking & Rewards Guide

This guide explains how STRATAX staking works and how stakers receive protocol fee rewards.

## What You Receive

When you stake STRATAX in `StrataxStaking`, you receive `stSTRATAX` vault shares.

Rewards can come from:

- Protocol fee tokens distributed via `FeeCollector`
- Optional STRATAX emissions funded by owner

## Stake

Use ERC4626 methods:

- `deposit(assets, receiver)`
- `mint(shares, receiver)`

## Unstake

Use:

- `withdraw(assets, receiver, owner)`
- `redeem(shares, receiver, owner)`

## Claim Rewards

- Claim one token: `claimReward(token)`
- Claim all tracked tokens: `claimAllRewards()`

To check pending rewards:

```solidity
pendingReward(account, token)
```

## How Fee Split Works

`FeeCollector` stores total collected fees by token and splits them by `stakerRewardsBps`.

- Staker side is sent to `StrataxStaking`
- Owner side is sent to protocol owner

## Operational Notes

- Reward accounting is share-based and pro-rata
- Reward sync can happen on staking state changes and explicit sync calls
- If no stakers exist, pending rewards are preserved until distribution is possible

## Related Pages

- [StrataxStaking](../contracts/stratax-staking.md)
- [Staking, Fees, and Managed Vaults](../architecture/staking-fees-managed-vaults.md)
