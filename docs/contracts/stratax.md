# Stratax Contract

The Stratax contract is the core position management contract that handles all leveraged position operations.

## Overview

Each Stratax contract is deployed as a beacon proxy and represents a single leveraged position. The contract is initialized with:

- Collateral token (e.g., WETH)
- Borrow token (e.g., USDC)
- Owner (NFT holder)

## Key Features

- ✅ Create leveraged positions via flash loans
- ✅ Unwind positions (partial or full)
- ✅ Supply/withdraw collateral
- ✅ Borrow/repay debt
- ✅ Real-time position metrics
- ✅ Upgradeable via beacon pattern

## Contract Address

Each position has its own contract address. Find it via:

```solidity
address positionContract = IStrataxPositionNft(nft).ownerToContracts(owner, index)
```

## State Variables

### Core Configuration

```solidity
// Aave protocol interfaces
IPool public aavePool;
IProtocolDataProvider public aaveDataProvider;
IAggregationRouter public oneInchRouter;

// Token configuration
address public collateralToken;
address public borrowToken;
uint256 public collateralTokenDecimals;
uint256 public borrowTokenDecimals;

// Position management
IStrataxPositionNft public strataxPositionNft;
uint256 public tokenId;

// Safety parameters
uint256 public borrowSafetyMargin;  // Default: 9900 (99%)
uint256 public maxLeverageOffset;   // Default: 75 (0.75%)

// Fee configuration
address public feeCollector;
uint256 public flashLoanFeeBps;
```

## Main Functions

### Opening a Position

#### `createLeveragedPosition`

Opens a new leveraged position or adds to an existing one.

```solidity
function createLeveragedPosition(
    uint256 _flashLoanAmount,
    uint256 _collateralAmount,
    uint256 _borrowAmount,
    bytes calldata _oneInchSwapData,
    uint256 _minReturnAmount
) public onlyOwner
```

**Parameters:**

- `_flashLoanAmount` - Amount to flash loan (from calculateOpenParams)
- `_collateralAmount` - User's collateral to add
- `_borrowAmount` - Amount to borrow from Aave
- `_oneInchSwapData` - Encoded 1inch swap data
- `_minReturnAmount` - Minimum expected from swap (slippage protection)

**Process:**

1. Transfer user collateral to contract
2. Initiate Aave flash loan
3. In callback: Supply collateral, borrow, swap, repay flash loan
4. Emit `LeveragePositionCreated` event

**Requirements:**

- Caller must be position owner (NFT holder)
- Sufficient allowance for collateral transfer
- Valid swap data from 1inch API

### Closing a Position

#### `unwindPosition`

Closes position (fully or partially) by repaying debt and withdrawing collateral.

```solidity
function unwindPosition(
    uint256 _collateralToWithdraw,
    uint256 _debtAmount,
    bytes calldata _oneInchSwapData,
    uint256 _minReturnAmount
) external onlyOwner
```

**Parameters:**

- `_collateralToWithdraw` - Amount of collateral to withdraw
- `_debtAmount` - Amount of debt to repay
- `_oneInchSwapData` - Encoded 1inch swap data
- `_minReturnAmount` - Minimum expected from swap

**Process:**

1. Flash loan the debt token
2. Repay Aave debt
3. Withdraw collateral
4. Swap collateral to debt token
5. Pay protocol fee
6. Repay flash loan
7. Supply or send remaining tokens

**Emits:**

- `PositionUnwound` event

### Position Management

#### `supplyCollateral`

Add collateral to improve position health.

```solidity
function supplyCollateral(uint256 _amount) external onlyOwner
```

Transfers collateral from user and supplies to Aave.

#### `withdrawCollateral`

Remove excess collateral.

```solidity
function withdrawCollateral(uint256 _amount) external onlyOwner returns (uint256)
```

Withdraws from Aave and sends to owner. Requires health factor > 1.0 after withdrawal.

#### `borrowDebtToken`

Borrow additional debt token (increases leverage).

```solidity
function borrowDebtToken(uint256 _amount) external onlyOwner
```

Borrows from Aave and sends to owner. Requires healthy position after borrowing.

#### `repayDebtToken`

Repay debt (decreases leverage).

```solidity
function repayDebtToken(uint256 _amount) external onlyOwner returns (uint256)
```

Transfers debt token from user and repays to Aave.

### Calculation Functions

#### `calculateOpenParams`

Calculate flash loan and borrow amounts for desired leverage.

```solidity
function calculateOpenParams(CalcOpenParams memory _params)
    public
    returns (uint256 flashLoanAmount, uint256 borrowAmount)
```

**Input Struct:**

```solidity
struct CalcOpenParams {
    uint256 desiredLeverage;        // e.g., 30000 = 3x
    uint256 collateralAmount;       // User's collateral
    uint256 collateralTokenPrice;   // Price with 8 decimals (0 = fetch from oracle)
    uint256 borrowTokenPrice;       // Price with 8 decimals (0 = fetch from oracle)
}
```

**Returns:**

- Flash loan amount needed
- Borrow amount needed

Call this off-chain before opening a position.

#### `calculateUnwindParams`

Calculate amounts needed to close/reduce position.

```solidity
function calculateUnwindParams(uint256 _debtToRepay)
    public view
    returns (
        uint256 collateralToWithdraw,
        uint256 debtAmount,
        uint256 strataxFee
    )
```

Use this before calling `unwindPosition`.

#### `calculateDesiredLeverage`

Reverse-engineer leverage from flash loan and collateral amounts.

```solidity
function calculateDesiredLeverage(
    uint256 _flashLoanAmount,
    uint256 _collateralAmount
) public returns (uint256 desiredLeverage)
```

Useful for understanding the leverage of an existing position.

### View Functions

#### `getCurrentLeverage`

Get current position leverage accounting for interest and price changes.

```solidity
function getCurrentLeverage() public view returns (uint256)
```

Returns leverage with 4 decimals (e.g., 30000 = 3x).

#### `getPositionUsdValue`

Get position value in USD (equity = collateral - debt).

```solidity
function getPositionUsdValue() public view returns (uint256)
```

Returns value with 8 decimals.

#### `getMaxLeverage` / `getMaxAchievableLeverageBinary`

Calculate maximum theoretical or achievable leverage.

```solidity
function getMaxLeverage() public view returns (uint256)
function getMaxAchievableLeverageBinary() public view returns (uint256)
```

`getMaxLeverage()` - Theoretical max based on LTV
`getMaxAchievableLeverageBinary()` - Actual max considering fees

#### `getFreeCollateral`

Get amount of collateral not backing any debt.

```solidity
function getFreeCollateral() public view returns (uint256)
```

This collateral can be used to increase leverage without adding more funds.

### Admin Functions

#### `updateFlashLoanFee`

Update cached flash loan fee from Aave.

```solidity
function updateFlashLoanFee() external onlyOwner
```

#### `update1InchRouter`

Change 1inch router address.

```solidity
function update1InchRouter(address _newRouter) external onlyOwner
```

#### `updateMaxLeverageOffset`

Adjust max leverage safety offset (max 5%).

```solidity
function updateMaxLeverageOffset(uint256 _newOffset) external onlyOwner
```

#### `recoverTokens`

Emergency function to recover stuck tokens.

```solidity
function recoverTokens(address _token, uint256 _amount) external onlyOwner
```

## Events

```solidity
event LeveragePositionCreated(
    address indexed user,
    address collateralToken,
    address borrowedToken,
    uint256 totalCollateralSupplied,
    uint256 borrowedAmount
);

event PositionUnwound(
    address indexed user,
    address collateralToken,
    address debtToken,
    uint256 debtRepaid,
    uint256 collateralReturned
);

event CollateralSupplied(
    address indexed user,
    address collateralToken,
    uint256 amount,
    uint256 healthFactor
);

event CollateralWithdrawn(
    address indexed user,
    address collateralToken,
    uint256 amount,
    uint256 healthFactor
);

// ... more events
```

## Flash Loan Callback

### `executeOperation`

Called by Aave Pool after receiving flash loan.

```solidity
function executeOperation(
    address _asset,
    uint256 _amount,
    uint256 _premium,
    address _initiator,
    bytes calldata _params
) external nonReentrant returns (bool)
```

Routes to either open or unwind logic based on operation type.

**Security:**

- Only callable by Aave Pool
- Initiator must be this contract
- Reentrancy protected

## Usage Example

```solidity
// 1. Get position contract address
address positionContract = nft.ownerToContracts(msg.sender, 0);
IStratax stratax = IStratax(positionContract);

// 2. Calculate parameters for 3x leverage
IStratax.CalcOpenParams memory params = IStratax.CalcOpenParams({
    desiredLeverage: 30000,  // 3x
    collateralAmount: 1 ether,
    collateralTokenPrice: 0,  // Auto-fetch
    borrowTokenPrice: 0       // Auto-fetch
});

(uint256 flashLoan, uint256 borrow) = stratax.calculateOpenParams(params);

// 3. Get swap data from 1inch API
bytes memory swapData = getSwapDataFrom1Inch(borrow, borrowToken, collateralToken);

// 4. Approve collateral
IERC20(collateralToken).approve(positionContract, 1 ether);

// 5. Open position
stratax.createLeveragedPosition(
    flashLoan,
    1 ether,
    borrow,
    swapData,
    minReturn
);
```

## Security Considerations

1. **Reentrancy**: All external calls protected with `nonReentrant`
2. **Access Control**: `onlyOwner` modifier for position management
3. **Slippage**: `minReturnAmount` on all swaps
4. **Health Checks**: Verifies health factor on risky operations
5. **Flash Loan Safety**: Validates caller and initiator

## Gas Optimization

- Caches token decimals at initialization
- Uses `forceApprove` for efficient allowance management
- Minimizes storage reads with local variables

## Next Steps

- [Opening a Position Guide](../guides/opening-position.md)
- [Managing Positions](../guides/managing-positions.md)
- [API Reference](../guides/api-reference.md)
