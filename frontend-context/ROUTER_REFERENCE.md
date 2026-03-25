# StrataxRouter — Frontend Contract Reference

> **This is the primary contract all user transactions should go through.**
> Users never call position proxies directly — the Router handles NFT custody atomically.

## Contract: `StrataxRouter`

- **Pattern**: Non-upgradeable, uses `ReentrancyGuard`
- **Constructor**: `constructor(address _positionNft)`
- **Implements**: `IERC721Receiver` (to temporarily hold NFTs during atomic operations)

---

## Position Creation

### `mintPosition` — Mint NFT Only (No Leverage)

```solidity
function mintPosition(
    address collateralToken,
    address borrowToken,
    bytes32 lendingProtocolId,
    bytes32 swapProtocolId
) external returns (uint256 tokenId, address strataxProxy)
```

- Mints an NFT and deploys a position proxy, but does NOT open leverage.
- Useful for "setup now, deposit later" flows.

---

### `createAaveUniswapPosition` — Mint + Open (Fully On-Chain)

```solidity
function createAaveUniswapPosition(
    address collateralToken,    // e.g., USDC
    address borrowToken,        // e.g., WETH
    uint256 collateralAmount,   // in token units (e.g., 2000 * 1e6 for 2000 USDC)
    uint256 desiredLeverage,    // 10000 = 1x, 25000 = 2.5x, 30000 = 3x
    uint24 poolFee,             // Uniswap V3 fee tier (3000 = 0.3%, 500 = 0.05%)
    uint256 minAmountOut        // slippage protection (0 for no protection)
) external nonReentrant returns (uint256 tokenId, address strataxProxy)
```

- **Requires**: User has approved Router for `collateralAmount` of `collateralToken`.
- **Does**: Mint NFT → transfer collateral → open leveraged position → transfer NFT to user.
- **Best for**: Simple "set leverage and go" UX. No off-chain computation needed.

---

### `createFluidUniswapPosition` — Mint + Open (Fluid Lending + Uniswap)

```solidity
function createFluidUniswapPosition(
    address collateralToken,
    address borrowToken,
    uint256 collateralAmount,
    uint256 desiredLeverage,
    uint24 poolFee,
    uint256 minAmountOut
) external nonReentrant returns (uint256 tokenId, address strataxProxy)
```

- Same interface as Aave+Uniswap but uses Fluid lending protocol.

---

### `createAaveOneInchPosition` — Mint + Open (1inch, Off-Chain Swap Data)

```solidity
function createAaveOneInchPosition(
    address collateralToken,
    address borrowToken,
    uint256 collateralAmount,
    uint256 flashLoanAmount,    // from calculate1InchOpenParams()
    uint256 borrowAmount,       // from calculate1InchOpenParams()
    bytes calldata oneInchSwapData,  // from 1inch API
    uint256 minAmountOut
) external nonReentrant returns (uint256 tokenId, address strataxProxy)
```

- **Frontend flow for 1inch positions:**
  1. Call `Router.calculate1InchOpenParams(proxy, desiredLeverage, collateralAmount)` → get `flashLoanAmount`, `borrowAmount`
  2. Call `Router.predictNextProxyAddress(collateral, borrow, lendingId, swapId)` → get `predictedProxy`
  3. Call 1inch API with `fromAddress = predictedProxy`, `tokenIn = borrowToken`, `tokenOut = collateralToken`, `amount = borrowAmount`
  4. Call `Router.createAaveOneInchPosition(...)` with all computed values

---

## Position Unwinding (Closing)

### `unwindAaveUniswapPosition` — On-Chain Unwind

```solidity
function unwindAaveUniswapPosition(
    uint256 tokenId,
    uint256 debtToRepay,        // in BORROW TOKEN units (e.g., WETH wei). type(uint256).max for full unwind
    uint24 poolFee,
    uint256 minReturnAmount
) external nonReentrant
```

- **Requires**: User has approved Router for the NFT (`positionNft.approve(router, tokenId)`).
- **IMPORTANT**: `debtToRepay` must be in **borrow token units** (e.g., WETH with 18 decimals), NOT USD.
- Use `type(uint256).max` to fully unwind all debt.
- For partial unwind, query the actual debt first via the position proxy's `calculateUnwindParams(type(uint256).max)` to get the debt amount in token units.

---

### `unwindAaveOneInchPosition` — 1inch Unwind (Pre-Computed)

```solidity
function unwindAaveOneInchPosition(
    uint256 tokenId,
    uint256 collateralToWithdraw,
    uint256 debtAmount,
    bytes calldata oneInchSwapData,
    uint256 minReturnAmount
) external nonReentrant
```

- **Frontend flow:**
  1. Call `position.calculateUnwindParams(debtToRepay)` → get `collateralToWithdraw`, `debtAmount`
  2. Call 1inch API with `fromAddress = proxyAddress`, `tokenIn = collateralToken`, `tokenOut = borrowToken`, `amount = collateralToWithdraw`
  3. Call `Router.unwindAaveOneInchPosition(...)` with all values

---

## Collateral & Debt Management

### `supplyCollateral`

```solidity
function supplyCollateral(uint256 tokenId, uint256 amount) external nonReentrant
```

- **Requires**: Approve Router for collateral token amount + Approve Router for NFT.
- Deposits additional collateral into the position (improves health factor).

### `withdrawCollateral`

```solidity
function withdrawCollateral(uint256 tokenId, uint256 amount) external nonReentrant
```

- **Requires**: Approve Router for NFT.
- Withdraws collateral. Reverts if health factor drops below 1.
- Withdrawn collateral is sent to `msg.sender`.

### `borrowDebtToken`

```solidity
function borrowDebtToken(uint256 tokenId, uint256 amount) external nonReentrant
```

- **Requires**: Approve Router for NFT.
- Borrows additional debt from the position. Reverts if health factor drops below 1.
- Borrowed tokens are sent to `msg.sender`.

### `repayDebtToken`

```solidity
function repayDebtToken(uint256 tokenId, uint256 amount) external nonReentrant
```

- **Requires**: Approve Router for debt token amount + Approve Router for NFT.
- Repays debt on the position.

---

## View / Helper Functions

### `calculate1InchOpenParams`

```solidity
function calculate1InchOpenParams(
    address proxy,
    uint256 desiredLeverage,
    uint256 collateralAmount
) external view returns (uint256 flashLoanAmount, uint256 borrowAmount)
```

- Used before calling `createAaveOneInchPosition`.

### `predictNextProxyAddress`

```solidity
function predictNextProxyAddress(
    address collateralToken,
    address borrowToken,
    bytes32 lendingProtocolId,
    bytes32 swapProtocolId
) external view returns (address predictedProxy)
```

- Returns the CREATE2-predicted proxy address for the next minted position.
- Required for 1inch API calls (the proxy must be the `fromAddress` in the swap).

---

## NFT Approval Pattern

All management functions (unwind, supply, withdraw, borrow, repay) require the user to **approve the Router for the NFT** before calling. The Router takes temporary custody of the NFT, performs the operation, then returns it.

```typescript
// Frontend pattern for any management operation:
await positionNft.approve(routerAddress, tokenId);
await router.unwindAaveUniswapPosition(tokenId, debtAmount, poolFee, 0);
// NFT is automatically returned to user
```

---

## Error Types

```solidity
error InvalidPositionNft();    // Constructor: zero address for position NFT
error NotPositionOwner();      // Caller doesn't own the NFT
error PositionNotActive();     // Position was already burned/deactivated
error InvalidSwapProtocol();   // Trying to use wrong unwind function for position type
```
