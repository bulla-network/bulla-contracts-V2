# Deployment Configuration Guide

## Environment Variables

Create a `.env` file in the project root with the following variables:

### Required Variables

```bash
# ===== RPC URLs =====
# Generic RPC URL (used by 'deploy' command)
RPC_URL=

# Network-specific RPC URLs
MAINNET_RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_API_KEY
SEPOLIA_RPC_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR_API_KEY
ARBITRUM_RPC_URL=https://arb-mainnet.g.alchemy.com/v2/YOUR_API_KEY
POLYGON_RPC_URL=https://polygon-mainnet.g.alchemy.com/v2/YOUR_API_KEY
BASE_RPC_URL=https://base-mainnet.g.alchemy.com/v2/YOUR_API_KEY
OPTIMISM_RPC_URL=https://opt-mainnet.g.alchemy.com/v2/YOUR_API_KEY
BSC_RPC_URL=https://bsc-dataseed.binance.org/
AVALANCHE_RPC_URL=https://api.avax.network/ext/bc/C/rpc

# ===== PRIVATE KEY =====
# Private key for deployment (without 0x prefix)
PRIVATE_KEY=

# ===== ETHERSCAN API KEYS =====
# For contract verification
ETHERSCAN_API_KEY=YOUR_ETHERSCAN_API_KEY
ARBISCAN_API_KEY=YOUR_ARBISCAN_API_KEY
POLYGONSCAN_API_KEY=YOUR_POLYGONSCAN_API_KEY
BASESCAN_API_KEY=YOUR_BASESCAN_API_KEY
OPTIMISM_API_KEY=YOUR_OPTIMISM_API_KEY
BSCSCAN_API_KEY=YOUR_BSCSCAN_API_KEY
SNOWTRACE_API_KEY=YOUR_SNOWTRACE_API_KEY
```

### Optional Configuration Variables

```bash
# ===== DEPLOYMENT CONFIGURATION =====
# Network name for verification (mainnet, sepolia, arbitrum, polygon, base, optimism, bsc, avalanche)
NETWORK=

# Lock state: 0=Unlocked, 1=NoNewClaims, 2=Locked
LOCK_STATE=0

# Core protocol fee in wei (e.g., 0.001 ETH = 1000000000000000)
CORE_PROTOCOL_FEE=0

# Admin address (defaults to deployer if not set)
ADMIN_ADDRESS=

# Protocol fees in basis points (100 = 1%, 0 = no fee)
INVOICE_PROTOCOL_FEE_BPS=0
FRENDLEND_PROTOCOL_FEE_BPS=0
```

### Contract Addresses (for verification)

```bash
# ===== CONTRACT ADDRESSES (for verification) =====
# Fill these after deployment to use verification script
BULLA_CLAIM_ADDRESS=
BULLA_INVOICE_ADDRESS=
BULLA_FRENDLEND_ADDRESS=
CONTROLLER_REGISTRY_ADDRESS=
WHITELIST_PERMISSIONS_ADDRESS=
APPROVAL_REGISTRY_ADDRESS=
```

## Default Values

| Variable                     | Default Value    | Description                 |
| ---------------------------- | ---------------- | --------------------------- |
| `LOCK_STATE`                 | `0`              | Unlocked state              |
| `CORE_PROTOCOL_FEE`          | `0`              | No fee                      |
| `ADMIN_ADDRESS`              | Deployer address | Admin for Invoice/FrendLend |
| `INVOICE_PROTOCOL_FEE_BPS`   | `0`              | No fee                      |
| `FRENDLEND_PROTOCOL_FEE_BPS` | `0`              | No fee                      |

## Security Notes

1. **Never commit `.env` files to version control**
2. **Use a secure private key management solution in production**
3. **Consider using a hardware wallet or multisig for the admin address**
4. **Test on testnets before mainnet deployment**
5. **Enable FFI**: The deployment script uses `--ffi` flag for automatic verification
