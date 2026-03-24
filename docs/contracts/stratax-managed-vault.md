# StrataxManagedVault

`StrataxManagedVault` is an upgradeable ERC4626 vault that wraps one Stratax leveraged position and exposes pooled share ownership.

## Highlights

- ERC4626 share token over collateral asset
- Manager-controlled leverage lifecycle
- Target leverage rebalancing
- FIFO withdrawal queue when idle liquidity is low
- Pause and deactivate controls

## Core Model

- Underlying managed object: one `Stratax` proxy position
- Vault asset: position collateral token
- Role model:
  - Users: deposit/redeem shares
  - Manager: rebalance leverage and process queue

## Total Asset Accounting

`totalAssets()` includes:

1. Idle collateral in vault balance
2. Underlying position net USD value converted into collateral units via oracle

This allows share price to reflect both idle funds and deployed leveraged exposure.

## Manager Functions

- `setManager(newManager)`
- `setTargetLeverage(newTargetLeverage)`
- `setPause(isPaused)`
- `deactivate()`
- `increaseLeverageToTarget(oneInchSwapData, minReturnAmount)`
- `unwindPosition(debtToRepay, oneInchSwapData, minReturnAmount)`
- `unwindPositionToTarget(oneInchSwapData, minReturnAmount)`
- `processWithdrawalQueue(maxRequests)`

## Withdraw Queue

When immediate idle collateral is insufficient, users can request queued withdrawal:

- `requestWithdrawal(shares, receiver)` burns shares and creates a queue entry
- `processWithdrawalQueue(maxRequests)` processes FIFO entries using available idle collateral
- `cancelWithdrawalRequest(requestId)` restores shares for unprocessed request

## Deployment

Use `StrataxDeployer_Aave_1Inch` for Aave + 1inch beacon-proxy deployment:

- `deployVault(...)` for existing Stratax position
- `mintPositionAndDeployVault(...)` to mint position and vault in one transaction

## Operational Notes

- Target leverage precision is 1e4 (`10000 = 1x`)
- Rebalance methods require valid 1inch swap data
- Deactivation enforces paused state for active operations

## Related Pages

- [Managed Vault Guide](../guides/managed-vault.md)
- [Staking, Fees, and Managed Vaults](../architecture/staking-fees-managed-vaults.md)
