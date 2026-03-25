# Staking, Token Sale & Managed Vaults — Frontend Reference

---

## StrataxStaking (ERC4626 Vault)

A staking vault where users deposit STRATAX and receive `stSTRATAX` shares. Stakers earn:

1. **Protocol fee rewards** — multi-token rewards from FeeCollector (USDC, WETH, etc.)
2. **STRATAX emission yield** — streamed over time as share-price appreciation

### Core Functions

#### Deposit & Withdraw

```solidity
function deposit(uint256 assets, address receiver) external returns (uint256 shares)
function mint(uint256 shares, address receiver) external returns (uint256 assets)
function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares)
function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets)
```

- Standard ERC4626. Requires STRATAX token approval for deposit/mint.

#### Claim Rewards

```solidity
function claimAllRewards() external                    // Claims all tracked reward tokens
function claimReward(address token) external           // Claims single reward token
function syncProtocolRewards() external                // Triggers FeeCollector → Staking distribution
```

#### View Functions

```solidity
function totalAssets() public view returns (uint256)               // STRATAX backing shares (excludes emission reserve)
function pendingReward(address account, address token) external view returns (uint256)
function getRewardTokens() external view returns (address[] memory)
function balanceOf(address account) public view returns (uint256)  // stSTRATAX shares
function convertToAssets(uint256 shares) public view returns (uint256)
function convertToShares(uint256 assets) public view returns (uint256)
function feeCollector() public view returns (address)
function strataxEmissionRatePerSecond() public view returns (uint256)
function strataxEmissionRemaining() public view returns (uint256)
```

---

## StrataxTokenSale

Sells STRATAX tokens for whitelisted ERC20 payment tokens (e.g., USDC, USDT). Uses Pyth oracle for payment token pricing.

### Tokenomics

| Constant               | Value                        |
| ---------------------- | ---------------------------- |
| Total Supply           | 100,000,000 STRATAX          |
| Public Sale Allocation | 20% (20,000,000 STRATAX)     |
| TGE Immediate Unlock   | 25% of purchased amount      |
| Vesting Period         | 270 days (9 months) linear   |
| Price Decimals         | 8 (e.g., $0.15 = 15_000_000) |

### Buy STRATAX

```solidity
function buy(
    address paymentToken,           // whitelisted token (e.g., USDC)
    uint256 paymentAmount,          // amount in payment token units
    uint256 minStrataxOut,          // slippage protection
    bytes[] calldata pythUpdateData // Pyth price update (can be empty if recent)
) external payable returns (uint256 strataxOut)
```

- **Requires**: Approval of `paymentAmount` on the payment token to the TokenSale contract.
- **msg.value**: Must cover Pyth update fee if `pythUpdateData` is provided.
- Returns total STRATAX amount (25% sent immediately, 75% vested).

### Quote (View)

```solidity
function quote(address paymentToken, uint256 paymentAmount) external view returns (uint256 strataxOut)
```

### Claim Vested Tokens

```solidity
function claimVestedTokens() external returns (uint256 claimedAmount)          // Public sale vesting
function claimManualVestedTokens() external returns (uint256 claimedAmount)    // Manual schedules (team/advisor)
```

### View Functions

```solidity
function getClaimableVested(address account) public view returns (uint256)
function getClaimableManualVested(address account) public view returns (uint256)
function getPublicSaleSupplyCap() public view returns (uint256)
function totalPublicSaleSold() public view returns (uint256)
function totalPurchased(address buyer) public view returns (uint256)
function totalVestedAllocation(address buyer) public view returns (uint256)
function vestedClaimed(address buyer) public view returns (uint256)
function getManualVestingCount(address account) external view returns (uint256)
function strataxPriceUsd() public view returns (uint256)               // 8 decimals
function salePaused() public view returns (bool)
function saleClosed() public view returns (bool)
function saleStartTimestamp() public view returns (uint256)
function strataxToken() public view returns (address)
function paymentTokenConfigs(address token) public view
    returns (bool isWhitelisted, bytes32 pythPriceId, uint256 maxPriceAge)
```

---

## StrataxManagedVault (ERC4626)

Tokenizes a single Stratax 1inch position as vault shares. Users deposit collateral; a manager controls leverage.

### User Functions

```solidity
function deposit(uint256 assets, address receiver) external returns (uint256 shares)
function mint(uint256 shares, address receiver) external returns (uint256 assets)
function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares)
function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets)
function requestWithdrawal(uint256 shares, address receiver) external returns (uint256 requestId)
function cancelWithdrawalRequest(uint256 requestId) external returns (uint256 restoredShares)
```

### Manager Functions (not user-facing, but useful for dashboards)

```solidity
function increaseLeverageToTarget(bytes calldata oneInchSwapData, uint256 minReturnAmount) external
function unwindPosition(uint256 debtToRepay, bytes calldata oneInchSwapData, uint256 minReturnAmount) external
function unwindPositionToTarget(bytes calldata oneInchSwapData, uint256 minReturnAmount) external
function processWithdrawalQueue(uint256 maxRequests) external returns (uint256 processedCount)
function setTargetLeverage(uint256 newTargetLeverage) external
function setPause(bool isPaused) external
function deactivate() external
```

### View Functions

```solidity
function totalAssets() public view returns (uint256)               // idle collateral + position equity
function convertToAssets(uint256 shares) public view returns (uint256)
function convertToShares(uint256 assets) public view returns (uint256)
function stratax() public view returns (address)                   // underlying position proxy
function collateralToken() public view returns (address)
function manager() public view returns (address)
function paused() public view returns (bool)
function deactivated() public view returns (bool)
function targetLeverage() public view returns (uint256)            // 10000 = 1x
function maxDeposit(address) public view returns (uint256)         // 0 if paused/deactivated
function maxMint(address) public view returns (uint256)
function nextWithdrawalRequestId() public view returns (uint256)
function nextWithdrawalToProcess() public view returns (uint256)
function totalPendingWithdrawals() public view returns (uint256)
function withdrawalRequests(uint256 requestId) public view returns (
    address owner, address receiver, uint256 shares, bool processed, bool canceled
)
```

---

## FeeCollector — Read-Only for Frontend

```solidity
function strataxFee() public view returns (uint256)                    // Protocol fee in bps (e.g., 5 = 0.05%)
function totalTradeVolume() public view returns (uint256)              // Total USD volume (8 decimals)
function assetTradeVolume(address asset) public view returns (uint256) // Per-asset volume
function strataxTradeVolume(address proxy) public view returns (uint256) // Per-position volume
function feeTokenFeesCollected(address token) public view returns (uint256)
function stakerRewardsBps() public view returns (uint256)              // Staker fee share (bps)
function stakingContract() public view returns (address)
```

---

## StrataxOracle — Price Feeds

```solidity
function getPrice(address token) external view returns (uint256)  // 8 decimal USD price
```

- Returns Chainlink price for a token (e.g., WETH → 217138354190 = $2,171.38).
