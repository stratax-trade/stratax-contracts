# Frontend User Flows — Step-by-Step

---

## Flow 1: Open a Leveraged Position (Uniswap — Simplest)

**User wants**: 2.5x long ETH using 2000 USDC collateral.

### Steps:

1. **Approve collateral**: `USDC.approve(routerAddress, 2000e6)`
2. **Create position**:
   ```typescript
   const tx = await router.createAaveUniswapPosition(
     USDC_ADDRESS, // collateralToken
     WETH_ADDRESS, // borrowToken
     2000_000_000n, // collateralAmount (2000 USDC, 6 decimals)
     25_000n, // desiredLeverage (2.5x)
     3000, // poolFee (0.3% Uniswap tier)
     0n, // minAmountOut (0 = no slippage protection, use real value in prod)
   );
   ```
3. **Result**: User receives an ERC721 NFT. Position is live on Aave.

### Reading Position State:

```typescript
const [tokenIds, positions] =
  await positionNft.getPositionsByOwner(userAddress);
const proxy = positions[0].strataxProxy;
const leverage = await proxyContract.getCurrentLeverage(); // e.g., 25000 = 2.5x
const equity = await proxyContract.getPositionUsdValue(); // USD 8 decimals
```

---

## Flow 2: Open a Leveraged Position (1inch — Better Pricing)

**User wants**: 2.5x long ETH using 1000 USDC on 1inch for better swap rates.

### Steps:

1. **Calculate params**:

   ```typescript
   const { flashLoanAmount, borrowAmount } =
     await router.calculate1InchOpenParams(
       proxyAddress, // use predictedProxy for new positions
       25_000n, // desiredLeverage
       1000_000_000n, // collateralAmount
     );
   ```

2. **Predict proxy address** (needed for 1inch API):

   ```typescript
   const predictedProxy = await router.predictNextProxyAddress(
     USDC_ADDRESS,
     WETH_ADDRESS,
     LENDING_AAVE_V3_ID,
     SWAP_ONEINCH_V6_ID,
   );
   ```

3. **Get 1inch swap data** (off-chain API call):

   ```typescript
   const swapData = await fetch1inchSwap({
     fromAddress: predictedProxy,
     tokenIn: WETH_ADDRESS,
     tokenOut: USDC_ADDRESS,
     amount: borrowAmount.toString(),
   });
   ```

4. **Approve & create**:
   ```typescript
   await USDC.approve(routerAddress, 1000_000_000n);
   await router.createAaveOneInchPosition(
     USDC_ADDRESS,
     WETH_ADDRESS,
     1000_000_000n,
     flashLoanAmount,
     borrowAmount,
     swapData,
     0n,
   );
   ```

---

## Flow 3: Partial Unwind (Reduce Leverage)

**User wants**: Reduce a 2.5x position to ~1.5x by repaying half the debt.

### Steps:

1. **Get actual debt in borrow token units** (NOT USD):

   ```typescript
   const proxy = await positionNft.getStrataxProxy(tokenId);
   const position = new Contract(proxy, Stratax_Aave_Uniswap_ABI, provider);

   // Get full debt amount in WETH units
   const [, fullDebtInWeth] = await position.calculateUnwindParams(MaxUint256);
   const halfDebt = fullDebtInWeth / 2n;
   ```

2. **Approve NFT to Router**:

   ```typescript
   await positionNft.approve(routerAddress, tokenId);
   ```

3. **Unwind**:
   ```typescript
   await router.unwindAaveUniswapPosition(
     tokenId,
     halfDebt, // in WETH units (18 decimals)
     3000, // poolFee
     0n, // minReturnAmount
   );
   ```

**⚠️ CRITICAL**: Never use `getUserAccountData().totalDebtBase` for `debtToRepay`. That's in USD. Always use `calculateUnwindParams` to get borrow-token-denominated amounts.

---

## Flow 4: Full Unwind (Close Position)

```typescript
await positionNft.approve(routerAddress, tokenId);
await router.unwindAaveUniswapPosition(
  tokenId,
  MaxUint256, // type(uint256).max = repay ALL debt
  3000,
  0n,
);
```

After full unwind, the position has zero debt. Remaining collateral stays earning Aave supply yield.

---

## Flow 5: Supply Additional Collateral

```typescript
const amount = 500_000_000n; // 500 USDC
await USDC.approve(routerAddress, amount);
await positionNft.approve(routerAddress, tokenId);
await router.supplyCollateral(tokenId, amount);
```

---

## Flow 6: Withdraw Collateral

```typescript
await positionNft.approve(routerAddress, tokenId);
await router.withdrawCollateral(tokenId, 500_000_000n);
// Withdrawn USDC goes to msg.sender
// Reverts if health factor drops below 1
```

---

## Flow 7: Buy STRATAX Tokens

```typescript
// 1. Quote
const strataxOut = await tokenSale.quote(USDC_ADDRESS, 100_000_000n); // 100 USDC

// 2. Buy (25% immediately, 75% vested over 270 days)
await USDC.approve(tokenSaleAddress, 100_000_000n);
await tokenSale.buy(
  USDC_ADDRESS,
  100_000_000n,
  (strataxOut * 99n) / 100n, // 1% slippage
  [], // no Pyth update (or pass update data)
);

// 3. Later: claim vested tokens
const claimable = await tokenSale.getClaimableVested(userAddress);
if (claimable > 0n) {
  await tokenSale.claimVestedTokens();
}
```

---

## Flow 8: Stake STRATAX

```typescript
const amount = parseUnits("1000", 18); // 1000 STRATAX

// Deposit
await strataxToken.approve(stakingAddress, amount);
await staking.deposit(amount, userAddress);

// Check rewards
const rewardTokens = await staking.getRewardTokens();
for (const token of rewardTokens) {
  const pending = await staking.pendingReward(userAddress, token);
  console.log(`Pending ${token}: ${pending}`);
}

// Claim all rewards
await staking.claimAllRewards();

// Withdraw STRATAX
const shares = await staking.balanceOf(userAddress);
await staking.redeem(shares, userAddress, userAddress);
```

---

## Flow 9: Managed Vault — Deposit

```typescript
const amount = 1000_000_000n; // 1000 USDC

// Check if vault is accepting deposits
const maxDep = await vault.maxDeposit(userAddress);
if (maxDep > 0n) {
  await USDC.approve(vaultAddress, amount);
  await vault.deposit(amount, userAddress);
}

// Read vault state
const shares = await vault.balanceOf(userAddress);
const assetsValue = await vault.convertToAssets(shares);
const currentLev = await strataxProxy.getCurrentLeverage();
const targetLev = await vault.targetLeverage();
```

---

## Dashboard Data Points to Display

| Data                    | Source                                                    | Notes                    |
| ----------------------- | --------------------------------------------------------- | ------------------------ |
| User's positions        | `positionNft.getPositionsByOwner(user)`                   | Returns all NFTs         |
| Position leverage       | `proxy.getCurrentLeverage()`                              | 10000 = 1x               |
| Position equity (USD)   | `proxy.getPositionUsdValue()`                             | 8 decimal USD            |
| Health factor           | `aavePool.getUserAccountData(proxy)`                      | 18 decimal, >1e18 = safe |
| Total collateral (USD)  | `aavePool.getUserAccountData(proxy)[0]`                   | 8 decimal USD            |
| Total debt (USD)        | `aavePool.getUserAccountData(proxy)[1]`                   | 8 decimal USD            |
| Protocol fee            | `feeCollector.strataxFee()`                               | bps (5 = 0.05%)          |
| Trade volume (position) | `feeCollector.strataxTradeVolume(proxy)`                  | USD 8 decimal            |
| Total protocol volume   | `feeCollector.totalTradeVolume()`                         | USD 8 decimal            |
| STRATAX price           | `tokenSale.strataxPriceUsd()`                             | 8 decimal USD            |
| Staking APY             | Compute from `strataxEmissionRatePerSecond` + fee rewards | —                        |
| Token prices            | `oracle.getPrice(token)`                                  | Chainlink 8 decimal      |
