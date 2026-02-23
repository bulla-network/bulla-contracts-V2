# Create Invoice

## Description
Create an on-chain invoice using the BullaInvoice controller contract. An invoice is a specialized claim with additional features like late fees, impairment grace periods, delivery dates, and purchase order deposits.

## Context
- **Repo**: bulla-contracts-v2
- **Contract**: bullaInvoice (controller), bullaClaimV2 (underlying claim)
- **Networks**: all except RedBelly (chainId 151)

## Prerequisites
- Creditor wallet address
- Debtor wallet address
- ERC20 token address for the payment currency
- The creditor must have approved the BullaInvoice contract on the BullaApprovalRegistry

## Function signature
```solidity
function createInvoice(CreateInvoiceParams memory params) external payable returns (uint256);
```

## CreateInvoiceParams struct
```solidity
struct CreateInvoiceParams {
    address debtor;                // who pays
    address creditor;              // who gets paid
    uint256 claimAmount;           // amount in token's smallest unit
    uint256 dueBy;                 // due date as unix timestamp
    uint256 deliveryDate;          // expected delivery date (0 if not applicable)
    string description;            // invoice description
    address token;                 // ERC20 token address
    ClaimBinding binding;          // 0 = Unbound, 1 = BindingPending, 2 = Bound
    InterestConfig lateFeeConfig;  // late fee configuration
    uint256 impairmentGracePeriod; // seconds after due date before impairment allowed
    uint256 depositAmount;         // upfront deposit required (0 if none)
}

struct InterestConfig {
    uint16 interestRateBps;        // net interest rate in basis points (100 = 1%)
    uint16 numberOfPeriodsPerYear; // compounding frequency (e.g. 12 = monthly)
}
```

## Steps
1. Look up `bullaInvoice` and `bullaApprovalRegistry` addresses for the target chain
2. If not already done, call `setApprovalForController(bullaInvoiceAddress, true)` on the BullaApprovalRegistry
3. Call `createInvoice(params)` on the BullaInvoice contract
4. The transaction creates a claim on BullaClaimV2 and emits an `InvoiceCreated` event
5. Returns the claim token ID

## Example
```solidity
// Step 1: Approve the invoice controller (one-time)
bullaApprovalRegistry.setApprovalForController(bullaInvoiceAddress, true);

// Step 2: Create the invoice
CreateInvoiceParams memory params = CreateInvoiceParams({
    debtor: debtorAddress,
    creditor: msg.sender,
    claimAmount: 1000000,                      // 1 USDC
    dueBy: 1709251200,                         // due date
    deliveryDate: 0,                           // no delivery date
    description: "Invoice #1234",
    token: usdcTokenAddress,
    binding: ClaimBinding.Unbound,             // 0
    lateFeeConfig: InterestConfig(0, 0),       // no late fees
    impairmentGracePeriod: 0,
    depositAmount: 0                           // no deposit
});

uint256 claimId = bullaInvoice.createInvoice(params);
```

## Common Errors
- Creditor has not approved the BullaInvoice controller on BullaApprovalRegistry: reverts
- Debtor is zero address: reverts
- claimAmount is 0: reverts
- Token is not a valid ERC20: reverts
