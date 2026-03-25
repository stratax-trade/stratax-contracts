# Position NFT & Position Proxy — Frontend Reference

## StrataxPositionNft (ERC721 Enumerable)

The NFT contract manages position ownership and proxy deployment. Most interactions go through the Router, but the frontend reads state directly from this contract.

### Reading Positions

#### `getPositionsByOwner` — Get All User Positions

```solidity
function getPositionsByOwner(address owner) public view
    returns (uint256[] memory tokenIds, Position[] memory positionList)
```

#### `getPositionsByOwner` — Paginated

```solidity
function getPositionsByOwner(address owner, uint256 startIndex, uint256 endIndex) public view
    returns (uint256[] memory tokenIds, Position[] memory positionList)
```

#### `getPosition` — Single Position

```solidity
function getPosition(uint256 tokenId) public view returns (Position memory)
```

#### `getStrataxProxy` — Get Proxy Address

```solidity
function getStrataxProxy(uint256 tokenId) public view returns (address)
```

#### `exists`

```solidity
function exists(uint256 tokenId) public view returns (bool)
```

#### `getTotalPositionsCreated`

```solidity
function getTotalPositionsCreated() public view returns (uint256)
```

### Position Struct

```solidity
struct Position {
    address collateralToken;      // e.g., USDC
    address borrowToken;          // e.g., WETH
    address strataxProxy;         // proxy contract address
    bytes32 strategyId;           // reserved (bytes32(0))
    bytes32 swapProtocolId;       // e.g., keccak256("SWAP:UNISWAP_V3")
    bytes32 lendingProtocolId;    // e.g., keccak256("LENDING:AAVE_V3")
    bool isActive;                // true until burned
    bool isBurned;                // true after burnPosition()
    uint256 createdAt;            // block.timestamp at creation
}
```

### Dynamic Token URI (On-Chain Metadata)

```solidity
function tokenURI(uint256 tokenId) public view returns (string memory)
```

Returns a `data:application/json;base64,...` URI with attributes:

- `Position USD Value` — live net equity (from oracle prices)
- `Cumulative Trade Volume USD` — total volume from FeeCollector
- `Collateral Token` — hex address
- `Borrow Token` — hex address
- `Stratax Proxy` — hex address

---

## Position Proxy — View Functions

Each position proxy (BeaconProxy) exposes these view functions. Call them on the `strataxProxy` address returned by `getPosition()`.

### `getCurrentLeverage`

```solidity
function getCurrentLeverage() public view returns (uint256)
```

- Returns current leverage with 4-decimal precision.
- `10000` = 1x (no leverage), `25000` = 2.5x, `30000` = 3x.
- Returns `0` if position is underwater or has no collateral.

### `getPositionUsdValue`

```solidity
function getPositionUsdValue() public view returns (uint256)
```

- Returns net equity = collateral value - debt value, in USD with 8 decimals.
- Uses oracle prices. Returns `0` if underwater.

### `owner`

```solidity
function owner() public view returns (address)
```

- Returns current NFT owner (position controller).

### Token State

```solidity
function collateralToken() public view returns (address);
function borrowToken() public view returns (address);
function collateralTokenDecimals() public view returns (uint256);
function borrowTokenDecimals() public view returns (uint256);
function isBurned() public view returns (bool);
function tokenId() public view returns (uint256);
function borrowSafetyMargin() public view returns (uint256);
function maxLeverageOffset() public view returns (uint256);
```

### Aave+Uniswap Position Additional Views

```solidity
function flashLoanFeeBps() public view returns (uint256);
function calculateUnwindParams(uint256 debtToRepay) public view
    returns (uint256 collateralToWithdraw, uint256 debtAmount, uint256 strataxFee);
```

- Pass `type(uint256).max` to get full unwind parameters.
- Returns values in **token units** (not USD).

### Aave+1inch Position Additional Views

```solidity
function flashLoanFeeBps() public view returns (uint256);
function calculateOpenParams(CalcOpenParams memory params) public view
    returns (uint256 flashLoanAmount, uint256 borrowAmount);
function calculateUnwindParams(uint256 debtToRepay) public view
    returns (uint256 collateralToWithdraw, uint256 debtAmount, uint256 strataxFee);
function getMaxLeverage() public view returns (uint256);
function getFreeCollateral() public view returns (uint256);
```

#### CalcOpenParams Struct (1inch)

```solidity
struct CalcOpenParams {
    uint256 desiredLeverage;      // e.g., 25000 for 2.5x
    uint256 collateralAmount;     // in collateral token units
    uint256 collateralTokenPrice; // 0 to use oracle price
    uint256 borrowTokenPrice;     // 0 to use oracle price
}
```

### Aave+Uniswap Position: Adjust Leverage

```solidity
function adjustPositionLeverage(
    uint256 desiredLeverage,   // target leverage (10000 precision)
    uint24 poolFee,
    uint256 minReturnAmount
) external onlyOwner
```

- Can increase or decrease leverage to target.
- Only callable by position owner (NFT holder).
- This is called directly on the proxy, NOT through the Router.

---

## Reading Position Health from Aave

For Aave-based positions, you can also query Aave directly:

```solidity
IPool(AAVE_POOL).getUserAccountData(proxyAddress)
```

Returns:

```solidity
(
    uint256 totalCollateralBase,     // USD with 8 decimals
    uint256 totalDebtBase,           // USD with 8 decimals
    uint256 availableBorrowsBase,    // USD with 8 decimals
    uint256 currentLiquidationThreshold,  // 4 decimals (e.g., 8500 = 85%)
    uint256 ltv,                     // 4 decimals (e.g., 8000 = 80%)
    uint256 healthFactor             // 18 decimals (> 1e18 is healthy)
)
```

**⚠️ IMPORTANT**: `totalDebtBase` is in **USD (8 decimals)**, NOT in borrow token units. Never pass this value directly to `unwindPosition()` which expects borrow token units.
