# Fork Testing Quick Reference

## Run Fork Tests

### With 1inch API Key

```bash
export ONE_INCH_API_KEY="your-key"
forge test --match-contract StrataxForkTest --fork-url $ETH_RPC_URL -vv
```

### Without API Key (Using Saved Data at Block 21650000)

```bash
forge test --match-contract StrataxForkTest --fork-url $ETH_RPC_URL --fork-block-number 21650000 -vv
```

## Save Swap Data for New Block

```bash
export ONE_INCH_API_KEY="your-key"
# Use current block
node test/scripts/calculate_and_save_swap_data.js
# Or specify a block
node test/scripts/calculate_and_save_swap_data.js 21700000
```

This creates: `test/fixtures/swap_data_block_21700000.json`

## How It Works

1. **Tests detect if API key exists**
2. **No API key** → Fork at SAVED_DATA_BLOCK (21650000) → Load from JSON
3. **Has API key** → Fork at latest → Call 1inch API

## Environment Variables

- `ONE_INCH_API_KEY` - Your 1inch API key (optional for saved data tests)
- `ETH_RPC_URL` - Ethereum RPC endpoint (required for fork tests)

## Benefits

✅ Run tests without API key  
✅ Deterministic results  
✅ No rate limits  
✅ Faster CI/CD
