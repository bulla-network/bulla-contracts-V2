# Deployments Directory

This directory contains JSON files with deployment information for each network deployment.

## File Structure

### Timestamped Deployments

- `sepolia-1703123456.json` - Deployment on Sepolia at timestamp 1703123456
- `mainnet-1703234567.json` - Deployment on Mainnet at timestamp 1703234567

### Latest Deployments

- `sepolia-latest.json` - Most recent Sepolia deployment
- `mainnet-latest.json` - Most recent Mainnet deployment

## JSON Structure

Each deployment file contains:

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
  "bullaClaim": "0xabc123...",
  "bullaInvoice": "0xdef456...",
  "bullaFrendLend": "0x789ghi...",
  "controllerRegistry": "0xjkl012...",
  "whitelistPermissions": "0xmno345...",
  "approvalRegistry": "0xpqr678..."
}
```

## Usage

### Reading Latest Deployment

```bash
# Get latest Sepolia deployment addresses
cat deployments/sepolia-latest.json | jq '.bullaClaim'
```

### Integration with Scripts

The deployment addresses can be easily imported into other scripts:

```javascript
const deployment = require("./deployments/sepolia-latest.json");
console.log("BullaClaim address:", deployment.bullaClaim);
```

### Environment Variable Generation

```bash
# Generate .env file from deployment
node -e "
const d = require('./deployments/sepolia-latest.json');
console.log(\`BULLA_CLAIM_ADDRESS=\${d.bullaClaim}\`);
console.log(\`BULLA_INVOICE_ADDRESS=\${d.bullaInvoice}\`);
console.log(\`BULLA_FRENDLEND_ADDRESS=\${d.bullaFrendLend}\`);
"
```
