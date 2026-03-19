# StrataxStaking

`StrataxStaking` is an ERC4626 staking vault for STRATAX with multi-token protocol-fee rewards.

## Highlights

- ERC4626 share model (`stSTRATAX`)
- Reward claims in multiple fee tokens
- Pull-based reward sync from `FeeCollector`
- Optional STRATAX emission stream

## Reward Sources

1. Protocol fee rewards transferred from `FeeCollector`
2. STRATAX emission reserve streamed over time

## Fee Distribution Integration

`StrataxStaking` calls:

```solidity
collectStakerRewardsForAllAssets();
```

on the configured `FeeCollector`, which transfers current staker-side token balances for tracked fee assets.

## User Actions

- Stake: `deposit(...)` / `mint(...)`
- Unstake: `withdraw(...)` / `redeem(...)`
- Claim rewards:
  - `claimReward(token)`
  - `claimAllRewards()`

## Reward Accounting Model

For each reward token:

- `accRewardPerShare[token]`: cumulative reward per share
- `userRewardDebt[user][token]`: user checkpoint
- `userClaimable[user][token]`: accrued claimable amount

This pattern supports fair pro-rata claims across share balance changes.

## Emission Model

Owner can:

- Set `strataxEmissionRatePerSecond`
- Fund reserve with `fundStrataxEmissions(amount)`

Emission reserve remains excluded from `totalAssets()` until accrued, preventing premature dilution.

## Admin Functions

- `setFeeCollector(address)`
- `setStrataxEmissionRatePerSecond(uint256)`
- `fundStrataxEmissions(uint256)`

## Security Notes

- Non-reentrancy on stake/unstake/claim/sync paths
- Reward sync is processed before share-balance updates to preserve accounting fairness

## Related Pages

- [Staking & Rewards Guide](../guides/staking-rewards.md)
- [Staking, Fees, and Managed Vaults](../architecture/staking-fees-managed-vaults.md)
