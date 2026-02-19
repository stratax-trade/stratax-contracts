# Flash Loan Flow

This document details the flash loan execution flow for opening and closing leveraged positions.

## What is a Flash Loan?

A flash loan is an uncollateralized loan that must be borrowed and repaid within the same transaction. If the loan cannot be repaid, the entire transaction reverts.

Stratax uses Aave V3 flash loans to:

- ✅ Create leveraged positions without requiring large capital
- ✅ Close positions atomically
- ✅ Ensure capital efficiency
- ✅ Minimize user risk

## Opening Position Flow

### High-Level Process

```
User → Stratax.createLeveragedPosition()
  ↓
Request flash loan from Aave
  ↓
Aave transfers flash loan to Stratax
  ↓
Stratax.executeOperation() callback
  ↓
[Position creation logic]
  ↓
Repay flash loan + fee
  ↓
Transaction complete
```

### Detailed Step-by-Step

#### 1. User Initiates Position

```solidity
stratax.createLeveragedPosition(
    flashLoanAmount,    // e.g., 2 ETH
    collateralAmount,   // e.g., 1 ETH (user's)
    borrowAmount,       // e.g., $6000 USDC
    oneInchSwapData,
    minReturnAmount
);
```

#### 2. User Collateral Transfer

```solidity
// Transfer user's collateral to contract
IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), collateralAmount);
```

#### 3. Flash Loan Request

```solidity
// Encode parameters
bytes memory params = abi.encode(OperationType.OPEN, msg.sender, flashParams);

// Request flash loan
aavePool.flashLoanSimple(
    address(this),        // receiver
    collateralToken,      // asset to borrow (e.g., WETH)
    flashLoanAmount,      // amount to borrow
    params,               // callback data
    0                     // referral code
);
```

#### 4. Aave Transfers Flash Loan

Aave sends `flashLoanAmount` of collateral token to the Stratax contract.

**Contract Balance**: `userCollateral + flashLoanAmount`

#### 5. Execute Operation Callback

Aave calls back to `executeOperation()`:

```solidity
function executeOperation(
    address asset,
    uint256 amount,        // flash loan amount
    uint256 premium,       // flash loan fee
    address initiator,
    bytes calldata params
) external returns (bool)
```

#### 6. Pay Stratax Fee

```solidity
// Calculate protocol fee
uint256 strataxFee = (amount × strataxFeeBps × leverage) / (FEE_PREC × LEVERAGE_PREC);

// Transfer to fee collector
IERC20(asset).approve(feeCollector, strataxFee);
IFeeCollector(feeCollector).collectFees(asset, strataxFee);
```

**Contract Balance**: `userCollateral + flashLoanAmount - strataxFee`

#### 7. Supply Collateral to Aave

```solidity
uint256 totalCollateral = userCollateral + flashLoanAmount - strataxFee;
IERC20(asset).approve(address(aavePool), totalCollateral);
aavePool.supply(asset, totalCollateral, address(this), 0);
```

**Aave Position**: `totalCollateral` supplied

#### 8. Borrow Debt Token

```solidity
aavePool.borrow(
    borrowToken,          // e.g., USDC
    borrowAmount,
    VARIABLE_DEBT,        // interest rate mode
    0,                    // referral code
    address(this)         // onBehalfOf
);
```

**Contract Balance**: `borrowAmount` of debt token (e.g., USDC)

#### 9. Swap Debt Token to Collateral

```solidity
IERC20(borrowToken).approve(address(oneInchRouter), borrowAmount);

// Execute 1inch swap
(bool success, bytes memory result) = oneInchRouter.call(oneInchSwapData);
uint256 returnAmount = abi.decode(result, (uint256));
```

**Contract Balance**: `returnAmount` of collateral token

#### 10. Repay Flash Loan

```solidity
uint256 totalDebt = amount + premium;  // flash loan + fee
IERC20(asset).approve(address(aavePool), totalDebt);
```

Aave automatically pulls `totalDebt` from the contract.

**Required**: `returnAmount >= totalDebt`

#### 11. Supply Leftover

```solidity
if (returnAmount > totalDebt) {
    uint256 leftover = returnAmount - totalDebt;
    IERC20(asset).approve(address(aavePool), leftover);
    aavePool.supply(asset, leftover, address(this), 0);
}
```

#### 12. Transaction Complete

If all steps succeed, transaction commits. Otherwise, entire transaction reverts.

### Flow Diagram

```
┌─────────────┐
│    User     │
└──────┬──────┘
       │ createLeveragedPosition()
       ↓
┌─────────────┐
│   Stratax   │ ← User's collateral transferred
└──────┬──────┘
       │ flashLoanSimple()
       ↓
┌─────────────┐
│ Aave Pool   │ ← Flash loan request
└──────┬──────┘
       │ Transfer flash loan
       ↓
┌─────────────┐
│   Stratax   │ ← Now has user + flash loan collateral
└──────┬──────┘
       │ executeOperation() callback
       ├─→ Pay Stratax fee
       ├─→ Supply collateral to Aave
       ├─→ Borrow debt token
       ├─→ Swap via 1inch
       └─→ Repay flash loan

✅ Position created with leverage
```

## Closing Position Flow

### High-Level Process

```
User → Stratax.unwindPosition()
  ↓
Request flash loan of debt token
  ↓
Aave transfers debt token
  ↓
Stratax.executeOperation() callback
  ↓
[Position closing logic]
  ↓
Repay flash loan + fee
  ↓
Transaction complete
```

### Detailed Step-by-Step

#### 1. User Initiates Close

```solidity
stratax.unwindPosition(
    collateralToWithdraw,  // Amount to withdraw from Aave
    debtAmount,             // Debt to repay
    oneInchSwapData,
    minReturnAmount
);
```

#### 2. Flash Loan Request (Debt Token)

```solidity
bytes memory params = abi.encode(OperationType.UNWIND, msg.sender, unwindParams);

aavePool.flashLoanSimple(
    address(this),
    borrowToken,           // Flash loan DEBT token (e.g., USDC)
    debtAmount,
    params,
    0
);
```

#### 3. Aave Transfers Flash Loan

Aave sends `debtAmount` of borrow token to Stratax.

**Contract Balance**: `debtAmount` of debt token

#### 4. Execute Operation Callback

#### 5. Repay Aave Debt

```solidity
IERC20(debtToken).approve(address(aavePool), debtAmount);
aavePool.repay(
    debtToken,
    debtAmount,
    VARIABLE_DEBT,
    address(this)
);
```

**Aave Position**: Debt reduced by `debtAmount`

#### 6. Withdraw Collateral

```solidity
uint256 withdrawnAmount = aavePool.withdraw(
    collateralToken,
    collateralToWithdraw,
    address(this)
);
```

**Contract Balance**: `withdrawnAmount` of collateral token

#### 7. Calculate Stratax Fee

```solidity
uint256 strataxFee = (debtAmount × strataxFeeBps) / FEE_PREC;
uint256 feeInCollateral = convertToCollateral(strataxFee);
```

#### 8. Swap Collateral to Debt Token

```solidity
uint256 amountToSwap = withdrawnAmount - feeInCollateral;
IERC20(collateralToken).approve(address(oneInchRouter), amountToSwap);

// Execute swap
uint256 returnAmount = oneInchRouter.call(oneInchSwapData);
```

**Contract Balance**: `returnAmount` of debt token

#### 9. Pay Stratax Fee

```solidity
IERC20(collateralToken).approve(feeCollector, feeInCollateral);
IFeeCollector(feeCollector).collectFees(collateralToken, feeInCollateral);
```

#### 10. Repay Flash Loan

```solidity
uint256 totalDebt = debtAmount + premium;
IERC20(debtToken).approve(address(aavePool), totalDebt);
```

**Required**: `returnAmount >= totalDebt`

#### 11. Handle Leftover

```solidity
if (returnAmount > totalDebt) {
    uint256 leftover = returnAmount - totalDebt;
    // Supply back to Aave or send to user
    aavePool.supply(debtToken, leftover, address(this), 0);
}
```

#### 12. Transaction Complete

Position is now closed (or partially closed).

### Flow Diagram

```
┌─────────────┐
│    User     │
└──────┬──────┘
       │ unwindPosition()
       ↓
┌─────────────┐
│   Stratax   │
└──────┬──────┘
       │ flashLoanSimple(DEBT_TOKEN)
       ↓
┌─────────────┐
│ Aave Pool   │ ← Flash loan request
└──────┬──────┘
       │ Transfer debt token
       ↓
┌─────────────┐
│   Stratax   │ ← Has debt token from flash loan
└──────┬──────┘
       │ executeOperation() callback
       ├─→ Repay Aave debt
       ├─→ Withdraw collateral
       ├─→ Swap collateral → debt token
       ├─→ Pay Stratax fee
       └─→ Repay flash loan

✅ Position closed, collateral returned
```

## Flash Loan Fees

### Aave Flash Loan Fee

- **Current**: 0.05% (5 basis points)
- **Calculation**: `fee = flashLoanAmount × 0.0005`
- **Paid in**: Asset being flash loaned
- **Updates**: Can change via Aave governance

Example:

- Flash loan: 10 ETH
- Fee: 10 × 0.0005 = 0.005 ETH
- Must repay: 10.005 ETH

### Total Cost Calculation

For opening position:

```
Total Flash Loan Debt = flashLoanAmount × (1 + aaveFee)
Stratax Fee = flashLoanAmount × strataxFeeBps × leverage / (FEE_PREC × LEVERAGE_PREC)
Total Cost = Aave Fee + Stratax Fee + 1inch Slippage
```

For closing position:

```
Total Flash Loan Debt = debtAmount × (1 + aaveFee)
Stratax Fee = debtAmount × strataxFeeBps / FEE_PREC
Total Cost = Aave Fee + Stratax Fee + 1inch Slippage
```

## Error Scenarios

### Insufficient Return from Swap

```solidity
require(returnAmount >= minReturnAmount, "Insufficient return amount from swap");
```

**Cause**: Slippage exceeded tolerance
**Solution**: Increase slippage tolerance or wait for better conditions

### Cannot Repay Flash Loan

```solidity
require(returnAmount >= totalDebt, "Insufficient funds to repay flash loan");
```

**Cause**: Swap didn't return enough to cover flash loan + fee
**Solution**: Adjust leverage, increase slippage, or add more collateral

### Flash Loan Reverts

If any step fails, Aave reverts the entire transaction, including the flash loan.

**Result**: No state changes, user only pays gas fees

## Security Considerations

### Callback Validation

```solidity
require(msg.sender == address(aavePool), "Caller must be Aave Pool");
require(_initiator == address(this), "Initiator must be this contract");
```

Prevents unauthorized flash loan callbacks.

### Reentrancy Protection

```solidity
function executeOperation(...) external nonReentrant returns (bool)
```

Prevents reentrancy attacks during callback execution.

### Atomic Execution

All steps execute atomically:

- Either entire operation succeeds
- Or entire transaction reverts

No partial state changes possible.

## Gas Optimization

### Single Flash Loan

Uses Aave's `flashLoanSimple()` for single asset:

- More gas efficient than multi-asset `flashLoan()`
- Simpler callback logic

### Approval Management

Uses `forceApprove()` for efficient allowance:

- Handles tokens with quirky approval logic
- Resets to exact amount needed

### Minimal Storage

Flash loan operations use memory, not storage:

- Lower gas costs
- No permanent state changes during execution

## Next Steps

- [Leverage Mechanics](leverage-mechanics.md)
- [Opening Position Guide](../guides/opening-position.md)
- [Stratax Contract](../contracts/stratax.md)
