# Opening a Position

This guide walks through the process of opening a leveraged position on Stratax.

## Prerequisites

Before opening a position, ensure you have:

- ✅ Collateral tokens in your wallet
- ✅ Gas for transaction (ETH on mainnet)
- ✅ Understanding of leverage and risks
- ✅ Access to 1inch API for swap data

## Step-by-Step Process

### Step 1: Mint Position NFT

First, create a position NFT by specifying your collateral and borrow tokens.

#### Example: Long ETH Position

```solidity
// Mint NFT for WETH collateral, USDC borrow (long ETH)
IStrataxPositionNft nft = IStrataxPositionNft(NFT_ADDRESS);
uint256 tokenId = nft.mintPosition(
    WETH_ADDRESS,  // collateral
    USDC_ADDRESS   // borrow token
);
```

Your position NFT is now minted with `tokenId`. The NFT represents ownership of the leveraged position contract.

### Step 2: Get Position Contract Address

```solidity
address positionContract = nft.tokenIdToContract(tokenId);
IStratax stratax = IStratax(positionContract);
```

### Step 3: Choose Your Leverage

Decide on leverage (e.g., 2x, 3x, or 5x). Higher leverage means:

- ✅ Greater potential profits
- ⚠️ Greater potential losses
- ⚠️ Higher liquidation risk

**Recommended starting leverage: 2-3x**

### Step 4: Calculate Position Parameters

Use the `calculateOpenParams` function to determine flash loan and borrow amounts.

```solidity
IStratax.CalcOpenParams memory params = IStratax.CalcOpenParams({
    desiredLeverage: 30000,      // 3x leverage (30000 = 3.0)
    collateralAmount: 1 ether,   // 1 WETH
    collateralTokenPrice: 0,     // 0 = auto-fetch from oracle
    borrowTokenPrice: 0          // 0 = auto-fetch from oracle
});

(uint256 flashLoanAmount, uint256 borrowAmount) = stratax.calculateOpenParams(params);
```

**Off-chain calculation recommended** - Call this via a view call to save gas.

### Step 5: Get 1inch Swap Data

Query the 1inch API to get optimal swap parameters.

#### Example API Request (JavaScript)

```javascript
const axios = require("axios");

async function get1inchSwapData(
  fromToken, // borrow token address
  toToken, // collateral token address
  amount, // borrow amount
  fromAddress, // position contract address
) {
  const url = `https://api.1inch.dev/swap/v5.2/1/swap`;

  const params = {
    src: fromToken,
    dst: toToken,
    amount: amount,
    from: fromAddress,
    slippage: 1, // 1% slippage tolerance
    disableEstimate: true,
  };

  const response = await axios.get(url, { params });
  return response.data.tx.data; // Returns encoded swap data
}

const swapData = await get1inchSwapData(
  USDC_ADDRESS,
  WETH_ADDRESS,
  borrowAmount,
  positionContract,
);
```

### Step 6: Calculate Minimum Return

Set slippage protection by calculating minimum acceptable return:

```javascript
// For 1% slippage tolerance
const minReturnAmount = flashLoanAmount * 0.99;
```

Adjust slippage based on:

- Market volatility
- Token liquidity
- Position size

### Step 7: Approve Collateral

Approve the position contract to spend your collateral:

```solidity
IERC20(WETH_ADDRESS).approve(positionContract, 1 ether);
```

### Step 8: Open Position

Call `createLeveragedPosition` with all calculated parameters:

```solidity
stratax.createLeveragedPosition(
    flashLoanAmount,   // from step 4
    1 ether,           // your collateral amount
    borrowAmount,      // from step 4
    swapData,          // from step 5
    minReturnAmount    // from step 6
);
```

## What Happens Behind the Scenes

1. **Collateral Transfer**: Your WETH is transferred to the position contract
2. **Flash Loan**: Aave flash loans additional WETH
3. **Protocol Fee**: Stratax fee is deducted from flash loan
4. **Supply to Aave**: All WETH (yours + flash loan - fee) is supplied as collateral
5. **Borrow**: Position borrows USDC from Aave against the collateral
6. **Swap**: USDC is swapped back to WETH via 1inch
7. **Repay Flash Loan**: WETH from swap repays the flash loan + 0.05% fee
8. **Supply Remaining**: Any leftover WETH is supplied to Aave

**Result**: You now have a 3x leveraged long position on WETH!

## Verification

After opening, verify your position:

```solidity
// Check current leverage
uint256 leverage = stratax.getCurrentLeverage();
console.log("Current Leverage:", leverage / 10000, "x");

// Check position value
uint256 valueUSD = stratax.getPositionUsdValue();
console.log("Position Value: $", valueUSD / 1e8);

// Check health factor (via Aave)
(,,,,, uint256 healthFactor) = aavePool.getUserAccountData(positionContract);
console.log("Health Factor:", healthFactor / 1e18);
```

**Healthy Position:**

- Leverage ≈ desired leverage (±5%)
- Health factor > 1.5 (recommended)
- Position value > initial investment

## Complete Example (Solidity)

```solidity
pragma solidity ^0.8.13;

contract PositionOpener {
    IStrataxPositionNft public nft;

    function openLongWETH(uint256 collateralAmount, uint256 desiredLeverage) external {
        // 1. Mint NFT
        uint256 tokenId = nft.mintPosition(WETH, USDC);

        // 2. Get contract
        address positionContract = nft.tokenIdToContract(tokenId);
        IStratax stratax = IStratax(positionContract);

        // 3. Calculate params
        IStratax.CalcOpenParams memory params = IStratax.CalcOpenParams({
            desiredLeverage: desiredLeverage,
            collateralAmount: collateralAmount,
            collateralTokenPrice: 0,
            borrowTokenPrice: 0
        });

        (uint256 flashLoan, uint256 borrow) = stratax.calculateOpenParams(params);

        // 4. Get swap data (assume fetched off-chain)
        bytes memory swapData = getSwapData(borrow);
        uint256 minReturn = (flashLoan * 99) / 100;

        // 5. Approve
        IERC20(WETH).approve(positionContract, collateralAmount);

        // 6. Open position
        stratax.createLeveragedPosition(
            flashLoan,
            collateralAmount,
            borrow,
            swapData,
            minReturn
        );
    }
}
```

## Common Issues

### "Insufficient return amount from swap"

- **Cause**: Slippage exceeded limit or poor swap route
- **Solution**: Increase slippage tolerance or wait for better liquidity

### "Insufficient funds to repay flash loan"

- **Cause**: Swap didn't return enough collateral
- **Solution**: Adjust leverage lower or increase slippage tolerance

### "Invalid effective LTV"

- **Cause**: Desired leverage exceeds maximum for asset
- **Solution**: Lower leverage or check max with `getMaxAchievableLeverageBinary()`

### "Health factor too low"

- **Cause**: Position starts too close to liquidation
- **Solution**: Reduce leverage or adjust safety parameters

## Best Practices

1. **Start Small**: Test with small amounts first
2. **Conservative Leverage**: Begin with 2-3x, not max leverage
3. **Monitor Regularly**: Check health factor daily
4. **Set Alerts**: Monitor for price movements
5. **Have Exit Plan**: Know when to close position
6. **Understand Costs**: Factor in fees (Stratax + Aave + 1inch)

## Cost Breakdown

Opening a 3x leveraged $10,000 position:

- **Stratax Fee**: ~$15-30 (0.15-0.30% of notional × leverage)
- **Aave Flash Loan**: ~$15 (0.05% of flash loan)
- **1inch Swap**: ~$10-50 (depends on slippage)
- **Gas**: ~$20-100 (depends on network congestion)
- **Total**: ~$60-210

## Next Steps

- [Managing Your Position](managing-positions.md)
- [Understanding Health Factor](health-factor.md)
- [Closing a Position](closing-position.md)
