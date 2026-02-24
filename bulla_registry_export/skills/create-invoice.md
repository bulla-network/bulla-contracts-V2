# Create Invoice

## Description

Create an on-chain invoice using the BullaInvoice controller contract. An invoice is a specialized claim with additional features like late fees, impairment grace periods, delivery dates, and purchase order deposits.

## Context

- **Repo**: bulla-contracts-v2
- **Contract**: bullaInvoice (controller), bullaClaimV2 (underlying claim), bullaApprovalRegistry (approval)
- **Networks**: all except RedBelly (chainId 151)

## Creating an Invoice (Two Steps Required)

### Step 1: Approve on BullaApprovalRegistry

Before creating invoices, the caller must approve the BullaInvoice contract on the **BullaApprovalRegistry**. This is a separate contract — do NOT try to approve on BullaInvoice directly.

```solidity
function approveCreateClaim(
    address controller,
    CreateClaimApprovalType approvalType,
    uint64 approvalCount,
    bool isBindingAllowed
) external;
```

**Parameters:**

- `controller`: BullaInvoice contract address (look up from address_config.json for target chain)
- `approvalType`: `CreateClaimApprovalType` enum (see below)
- `approvalCount`: Number of claims allowed (`type(uint64).max` = `18446744073709551615` for unlimited). Note: this is `uint64`, NOT `uint256`
- `isBindingAllowed`: `true` to allow creating bound claims, `false` otherwise

**CreateClaimApprovalType enum:**
| Value | Name | Description |
|-------|------|-------------|
| 0 | `Unapproved` | Revoke approval (approvalCount and isBindingAllowed must be 0/false) |
| 1 | `CreditorOnly` | Caller can only create claims where they are the creditor |
| 2 | `DebtorOnly` | Caller can only create claims where they are the debtor |
| 3 | `Approved` | Caller can create any kind of claim |

**Example — unlimited approval:**

```solidity
bullaApprovalRegistry.approveCreateClaim(
    bullaInvoiceAddress,    // controller
    CreateClaimApprovalType.Approved, // 3 — can create any kind of claim
    type(uint64).max,       // 18446744073709551615 — unlimited
    true                    // allow binding
);
```

### Step 2: Create the Invoice

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

## BullaApprovalRegistry ABI (approval step)

```json
[
  "function approveCreateClaim(address controller, uint8 approvalType, uint64 approvalCount, bool isBindingAllowed)",
  "function getApprovals(address user, address controller) view returns (uint8 approvalType, uint64 approvalCount, bool isBindingAllowed)"
]
```

## Steps

1. Look up `bullaInvoice` and `bullaApprovalRegistry` addresses for the target chain from `address_config.json`
2. Check if approval exists: call `getApprovals(callerAddress, bullaInvoiceAddress)` on BullaApprovalRegistry
3. If not approved, call `approveCreateClaim(bullaInvoiceAddress, approvalType, approvalCount, isBindingAllowed)` on BullaApprovalRegistry
4. Call `createInvoice(params)` on the BullaInvoice contract
5. The transaction creates a claim on BullaClaimV2 and emits an `InvoiceCreated` event
6. Returns the claim token ID

## Example

```solidity
// Step 1: Approve the invoice controller on BullaApprovalRegistry (one-time)
bullaApprovalRegistry.approveCreateClaim(
    bullaInvoiceAddress,
    CreateClaimApprovalType.Approved, // 3
    type(uint64).max,                 // unlimited
    true                              // allow binding
);

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

## Common Gotchas

- Do NOT try to approve on BullaInvoice directly — approval happens on BullaApprovalRegistry (a separate contract)
- `approvalCount` is `uint64`, not `uint256` (max value: `18446744073709551615`)

## Common Errors

- `NotApproved`: Caller has not approved the BullaInvoice controller on BullaApprovalRegistry, or approval type doesn't match the claim role
- `InvalidApproval`: Trying to set `Unapproved` (0) with non-zero approvalCount or isBindingAllowed=true
- Debtor is zero address: reverts
- claimAmount is 0: reverts
- Token is not a valid ERC20: reverts
