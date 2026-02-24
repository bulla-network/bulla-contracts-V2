# Pay Invoice

## Description
Pay an existing on-chain invoice. The debtor transfers the owed token amount to the creditor through the BullaInvoice controller. Handles late fee accrual and supports partial payments.

## Context
- **Repo**: bulla-contracts-v2
- **Contract**: bullaInvoice
- **Networks**: all except RedBelly (chainId 151)

## Prerequisites
- The invoice claim ID (obtained from `InvoiceCreated` event)
- The debtor must hold sufficient balance of the invoice's ERC20 token
- The debtor must have approved the BullaInvoice contract to spend the token amount

## Function signature
```solidity
function payInvoice(uint256 claimId, uint256 paymentAmount) external payable;
```

### Parameters
| Name | Type | Description |
|------|------|-------------|
| `claimId` | `uint256` | The invoice's claim token ID |
| `paymentAmount` | `uint256` | Amount to pay in the token's smallest unit. Can be partial. If late fees have accrued, payment is applied to interest first, then principal. |

## Steps
1. Look up the `bullaInvoice` contract address for the target chain
2. Call `token.approve(bullaInvoiceAddress, paymentAmount)` on the payment token
3. Call `payInvoice(claimId, paymentAmount)` on the BullaInvoice contract
4. The transaction transfers tokens from debtor to creditor and emits a `InvoicePayment` event
5. If late fees have accrued (past due date with lateFeeConfig), payment covers interest first
6. If the full principal + interest is paid, the invoice status changes to `Paid`

## Example
```solidity
// Step 1: Approve token spend
usdc.approve(bullaInvoiceAddress, 1000000);

// Step 2: Pay the invoice (full amount)
bullaInvoice.payInvoice(invoiceClaimId, 1000000);

// Or partial payment
bullaInvoice.payInvoice(invoiceClaimId, 500000); // pay half
```

## Common Errors
- Insufficient token balance: ERC20 transfer reverts
- Insufficient allowance: ERC20 transferFrom reverts
- Claim does not exist or is not an invoice: reverts
- Caller is not the debtor: reverts
- Invoice already fully paid: reverts
