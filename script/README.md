# Bulla Contracts V2 Deployment Guide

This guide explains how to deploy BullaClaimV2, BullaInvoice, and BullaFrendLendV2 contracts using the provided deployment scripts.

## Overview

The deployment process includes:

1. **BullaClaimV2** - Core claim management contract
2. **BullaInvoice** - Invoice-specific functionality wrapper
3. **BullaFrendLendV2** - P2P lending functionality wrapper
4. **Dependencies** - Required supporting contracts (BullaControllerRegistry, WhitelistPermissions, BullaApprovalRegistry)

## Prerequisites

1. **Install Dependencies**

   ```bash
   yarn install
   ```

2. **Configure Environment**

   ```bash
   cp .env.example .env
   # Edit .env with your configuration
   ```

3. **Build Contracts**
   ```bash
   yarn build
   ```

> **Note**: The deployment script uses FFI (Foreign Function Interface) to automatically verify contracts. This is enabled via the `--ffi` flag in the deployment command.

## Environment Configuration

### Required Variables

| Variable      | Description                       | Example                                         |
| ------------- | --------------------------------- | ----------------------------------------------- |
| `RPC_URL`     | Generic RPC endpoint              | `https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY` |
| `PRIVATE_KEY` | Deployer private key (without 0x) | `your_private_key_here`                         |
| `NETWORK`     | Network name for verification     | `mainnet`, `sepolia`, `arbitrum`                |

### Optional Configuration

| Variable                     | Description                                              | Default          |
| ---------------------------- | -------------------------------------------------------- | ---------------- |
| `LOCK_STATE`                 | Initial lock state (0=Unlocked, 1=NoNewClaims, 2=Locked) | `0`              |
| `CORE_PROTOCOL_FEE`          | Core protocol fee in wei                                 | `0`              |
| `ADMIN_ADDRESS`              | Admin address for Invoice/FrendLend                      | Deployer address |
| `INVOICE_PROTOCOL_FEE_BPS`   | Invoice protocol fee in basis points                     | `0` (no fee)     |
| `FRENDLEND_PROTOCOL_FEE_BPS` | FrendLend protocol fee in basis points                   | `0` (no fee)     |

## Deployment Commands

### Sepolia Deployment

```bash
yarn deploy:sepolia
```

## Manual Deployment

For advanced users or custom networks:

```bash
forge script script/DeployContracts.s.sol:DeployContracts \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY
```

## Contract Verification

### Automatic Verification

The deployment scripts include built-in automatic verification. Each contract is verified immediately after deployment using forge's verification system. No additional configuration needed - just ensure your NETWORK environment variable is set.

### Manual Verification

Verification happens automatically during deployment. If automatic verification fails, the deployment script will output manual verification commands for you to run:

```bash
# Example output if automatic verification fails:
forge verify-contract 0x123... src/BullaClaimV2.sol:BullaClaimV2 --chain sepolia --constructor-args $(cast abi-encode "constructor(address,uint8,uint256,address)" ...)
```

You can also use the dedicated verification script:

```bash
forge script script/VerifyContracts.s.sol:VerifyContracts --rpc-url $SEPOLIA_RPC_URL
```

### Manual Verification Commands

The deployment script outputs verification commands. Example:

```bash
forge verify-contract 0x123... src/BullaClaimV2.sol:BullaClaimV2 \
  --chain mainnet \
  --constructor-args $(cast abi-encode "constructor(address,uint8,uint256,address)" 0x... 0 0 0x...)
```

## Deployment Output

The deployment script provides comprehensive logging:

```
=== Starting Bulla Contracts V2 Deployment ===
Deployer: 0x1234567890123456789012345678901234567890
Chain ID: 1

=== Deployment Configuration ===
Initial Lock State: 0
Core Protocol Fee: 0
Invoice Protocol Fee BPS: 0
FrendLend Protocol Fee BPS: 0
Admin Address: 0x1234567890123456789012345678901234567890

=== Deploying Dependencies ===
Deploying BullaControllerRegistry...
BullaControllerRegistry deployed at: 0x...

=== Deploying Main Contracts ===
Deploying BullaClaimV2...
BullaClaimV2 deployed at: 0x...

=== Setting up Authorizations ===
Authorizing BullaInvoice in ApprovalRegistry...

=== Deployment Complete ===
BullaClaimV2: 0x...
BullaInvoice: 0x...
BullaFrendLendV2: 0x...
```

## Contract Addresses Storage

### Automatic JSON Export

The deployment script automatically saves all deployment information to JSON files:

- **Timestamped file**: `deployments/sepolia-1703123456.json`
- **Latest file**: `deployments/sepolia-latest.json`

### JSON Structure

```json
{
  "deployer": "0x1234...",
  "chainId": 11155111,
  "blockNumber": 4567890,
  "timestamp": 1703123456,
  "network": "sepolia",
  "lockState": 0,
  "coreProtocolFee": 0,
  "invoiceProtocolFeeBPS": 0,
  "frendLendProtocolFeeBPS": 0,
  "adminAddress": "0x1234...",
  "bullaClaimV2": "0xabc123...",
  "bullaInvoice": "0xdef456...",
  "bullaFrendLendV2": "0x789ghi...",
  "controllerRegistry": "0xjkl012...",
  "whitelistPermissions": "0xmno345...",
  "approvalRegistry": "0xpqr678..."
}
```

### Using Deployment Data

```bash
# Get BullaClaimV2 address from latest deployment
cat deployments/sepolia-latest.json | jq '.bullaClaimV2'

# Generate .env variables
node -e "
const d = require('./deployments/sepolia-latest.json');
console.log(\`BULLA_CLAIM_ADDRESS=\${d.bullaClaimV2}\`);
console.log(\`BULLA_INVOICE_ADDRESS=\${d.bullaInvoice}\`);
"
```

## Security Considerations

1. **Private Key Security**: Never commit private keys to version control
2. **Admin Address**: Consider using a multisig wallet for the admin address
3. **Lock State**: Start with appropriate lock state for your deployment strategy
4. **Protocol Fees**: Review fee settings before deployment

## Troubleshooting

### Common Issues

1. **Insufficient Gas**: Increase gas limit or gas price
2. **Verification Failure**: Check API keys and network configuration
3. **RPC Issues**: Verify RPC URL and API rate limits
4. **Constructor Args**: Ensure all environment variables are set correctly

### Getting Help

1. Check the deployment logs for specific error messages
2. Verify all environment variables are correctly set
3. Ensure sufficient ETH balance for deployment
4. Review network-specific requirements (gas prices, etc.)

## Post-Deployment Steps

1. **Save Contract Addresses**: Update your `.env` file
2. **Verify Contracts**: Ensure all contracts are verified on block explorers
3. **Test Deployment**: Run basic functionality tests
4. **Update Documentation**: Document deployed addresses for your team
5. **Set Up Monitoring**: Consider setting up contract monitoring

## Scripts Reference

| Script                  | Purpose                      |
| ----------------------- | ---------------------------- |
| `DeployContracts.s.sol` | Main deployment script       |
| `VerifyContracts.s.sol` | Contract verification script |

## Environment Variables Reference

See `.env.example` for a complete list of supported environment variables and their descriptions.
