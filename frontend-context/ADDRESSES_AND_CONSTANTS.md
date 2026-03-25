# Contract Addresses & External Dependencies

## Ethereum Mainnet — External Protocol Addresses

### Aave V3

| Contract                     | Address                                      |
| ---------------------------- | -------------------------------------------- |
| Aave V3 Pool                 | `0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2` |
| Aave V3 Data Provider        | `0x0a16f2FCC0D44FaE41cc54e079281D84A363bECD` |
| Aave Pool Addresses Provider | `0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e` |

### Uniswap V3

| Contract         | Address                                      |
| ---------------- | -------------------------------------------- |
| Swap Router      | `0xE592427A0AEce92De3Edee1F18E0157C05861564` |
| QuoterV2         | `0x61fFE014bA17989E743c5F6cB21bF9697530B21e` |
| Default Pool Fee | `3000` (0.3%)                                |

### 1inch V6

| Contract           | Address                                      |
| ------------------ | -------------------------------------------- |
| Aggregation Router | `0x111111125421cA6dc452d289314280a0f8842A65` |

### Fluid

| Contract        | Address                                      |
| --------------- | -------------------------------------------- |
| WETH/USDC Vault | `0x0C8C77B7FF4c2aF7F6CEBbe67350A490E3DD6cB3` |

### Chainlink Price Feeds

| Token    | Feed Address                                 |
| -------- | -------------------------------------------- |
| USDC/USD | `0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6` |
| ETH/USD  | `0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419` |

### Token Addresses

| Token | Address                                      | Decimals |
| ----- | -------------------------------------------- | -------- |
| USDC  | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` | 6        |
| WETH  | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` | 18       |

---

## Stratax Protocol — Deployment Addresses

> ⚠️ The addresses below are from a **dry-run deployment** on Ethereum mainnet (chain ID 1).
> Replace with actual production addresses once deployed.

| Contract                     | Address                                      | Type           |
| ---------------------------- | -------------------------------------------- | -------------- |
| StrataxOracle (impl)         | `0xe26e6c5cb47167627d6bc24705dddc5a6ec22ace` | Implementation |
| StrataxOracle (proxy)        | `0x95ba2074cd84ea48aaa3dc553e663d98b9a756a4` | ERC1967Proxy   |
| FeeCollector (impl)          | `0x92e092b5e18aeb5b6c951f0ccb20f49f97081757` | Implementation |
| FeeCollector (proxy)         | `0xab2787995106e2fd488f5d9b149d0a4232553357` | ERC1967Proxy   |
| StrataxPositionNft (impl)    | `0xc230763588c93f664d43a8d3f583a3a0e5e9ae68` | Implementation |
| StrataxPositionNft (proxy)   | `0xb9d86f7faddc177c41e1d3de8a7a21127a8018d2` | ERC1967Proxy   |
| StrataxConfigManager (impl)  | `0x3f1b31cdc3d81f0e3a147da2681d51e13a2488c0` | Implementation |
| StrataxConfigManager (proxy) | `0x0b8253ec8ce305767d9d33d28e614244b7ea25c6` | ERC1967Proxy   |
| **Aave+1inch**               |                                              |                |
| Stratax_Aave_1Inch (impl)    | `0xae8231021acd6699201d8877c63135ed53fe5835` | Beacon impl    |
| StrataxProtocolBeacon        | `0x2b5b6a06a8f91bd39fdb6b0091388f2b4abc7e7a` | Beacon         |
| AaveOneInchPositionAdapter   | `0x2f81f39477fddc6192bc300ff90fcc0ccd18e625` | Adapter        |
| **Aave+Uniswap**             |                                              |                |
| Stratax_Aave_Uniswap (impl)  | `0x2b18dd5e3f439bf0c7215deffc98fa277fccdf0f` | Beacon impl    |
| StrataxProtocolBeacon        | `0xb6f63c819c14305f2754c9ecb8018ebb086cdaff` | Beacon         |
| AaveUniswapPositionAdapter   | `0xb16952556e1e62826819c855b30afaee70f919ab` | Adapter        |
| **Fluid+Uniswap**            |                                              |                |
| Stratax_Fluid_Uniswap (impl) | `0x533a758ee56b34fc02eb4bcf748a2ded5dba29a6` | Beacon impl    |
| StrataxProtocolBeacon        | `0xfe7f04805747b164f9ca13f6751b9ac475fbb422` | Beacon         |
| FluidUniswapPositionAdapter  | `0x6bac6b8a6d2d51ec9d192ca9181f6179a0a52c4f` | Adapter        |

---

## Protocol ID Reference

Use these constants in the frontend (compute once via `keccak256`):

```typescript
// ethers.js v6
import { keccak256, toUtf8Bytes } from "ethers";

const LENDING_AAVE_V3_ID = keccak256(toUtf8Bytes("LENDING:AAVE_V3"));
const LENDING_FLUID_V1_ID = keccak256(toUtf8Bytes("LENDING:FLUID_V1"));
const SWAP_UNISWAP_V3_ID = keccak256(toUtf8Bytes("SWAP:UNISWAP_V3"));
const SWAP_ONEINCH_V6_ID = keccak256(toUtf8Bytes("SWAP:ONEINCH_V6"));
```

---

## Default Protocol Parameters

| Parameter                  | Value  | Meaning                     |
| -------------------------- | ------ | --------------------------- |
| borrowSafetyMargin (Aave)  | 9950   | Use 99.5% of max LTV        |
| maxLeverageOffset (Aave)   | 75     | 0.75% below theoretical max |
| borrowSafetyMargin (Fluid) | 9900   | Use 99% of max LTV          |
| maxLeverageOffset (Fluid)  | 100    | 1% below theoretical max    |
| Default Uniswap Pool Fee   | 3000   | 0.3% fee tier               |
| Default Slippage Buffer    | 50 bps | 0.5%                        |
| Protocol Fee               | 5 bps  | 0.05% on borrow volume      |
