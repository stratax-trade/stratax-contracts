# Managed Vault Guide

This guide explains user and manager workflows for `StrataxManagedVault`.

## Concepts

A managed vault is an ERC4626 wrapper over a single leveraged Stratax position.

- Users hold vault shares
- Manager executes leverage operations
- Vault tracks combined idle collateral and deployed position value

## User Workflow

### Deposit

Users deposit collateral token and receive shares:

```solidity
deposit(assets, receiver)
```

### Redeem/Withdraw

If idle collateral is available, users can withdraw/redeem directly.

If not, users should queue a withdrawal request.

### Queue Withdrawal

```solidity
requestWithdrawal(shares, receiver)
```

This burns shares and creates a FIFO queue entry.

Users can cancel unprocessed requests with:

```solidity
cancelWithdrawalRequest(requestId)
```

## Manager Workflow

Manager can:

- Set target leverage
- Increase leverage toward target
- Unwind partially or to target
- Pause/deactivate vault
- Process queued withdrawals

Queue processing:

```solidity
processWithdrawalQueue(maxRequests)
```

## Safety and Operations

- Rebalance methods require valid 1inch swap data
- Paused/deactivated states restrict active vault operations
- Queue processing depends on available idle collateral

## Related Pages

- [StrataxManagedVault](../contracts/stratax-managed-vault.md)
- [Staking, Fees, and Managed Vaults](../architecture/staking-fees-managed-vaults.md)
