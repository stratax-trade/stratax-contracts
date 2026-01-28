# Stratax

A smart contract protocol that enables owners to open leveraged positions using:

- **Aave** lending and flash loans
- **1inch** swap data for optimal swap rates

## Contract Layout

Type declarations (enums, structs)
State variables
Events
Modifiers
Constructor
Fallback/Receive functions (if any)
External functions
Public functions
Internal functions
Private functions

# Stratax contract uses upgradeable beacon

For more information: https://rareskills.io/post/beacon-proxy

## Architecture

```
┌─────────────────┐
│  BeaconProxy 1  │──┐
└─────────────────┘  │
                     │    ┌──────────────────┐      ┌────────────────────┐
┌─────────────────┐  ├───▶│ UpgradeableBeacon│─────▶│ Stratax (Impl V1)  │
│  BeaconProxy 2  │──┤    └──────────────────┘      └────────────────────┘
└─────────────────┘  │
                     │
┌─────────────────┐  │
│  BeaconProxy N  │──┘
└─────────────────┘
```

## Setup

Requirements: Node and Foundry installed

1. Clone the repository
2. Install dependencies:
   ```bash
   npm install
   forge install
   ```
3. Build the contracts:
   ```bash
   forge build
   ```

## Testing

1. Create a `.env` file with:
   - Ethereum mainnet RPC URL
   - 1Inch API key (optional)
2. Run tests:
   ```bash
   forge test
   ```
