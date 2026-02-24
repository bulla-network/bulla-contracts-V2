# Offer FrendLend Loan

## Description
Create a peer-to-peer loan offer using the BullaFrendLendV2 controller. Either the creditor or the debtor can initiate: if called by the creditor, it creates an offer for the debtor to accept; if called by the debtor, it creates a request for the creditor to fund.

## Context
- **Repo**: bulla-contracts-v2
- **Contract**: frendLendV2 (controller), bullaClaimV2 (underlying claim)
- **Networks**: all except RedBelly (chainId 151)

## Prerequisites
- Lender (creditor) and borrower (debtor) wallet addresses
- ERC20 token address for the loan
- The caller must have approved the FrendLendV2 contract on the BullaApprovalRegistry

## Function signature
```solidity
function offerLoan(LoanRequestParams calldata offer) external returns (uint256);
```

## LoanRequestParams struct
```solidity
struct LoanRequestParams {
    uint256 termLength;            // loan term in seconds
    InterestConfig interestConfig; // interest rate and compounding
    uint256 loanAmount;            // principal amount in token's smallest unit
    address creditor;              // lender address
    address debtor;                // borrower address
    string description;            // loan description
    address token;                 // ERC20 token address
    uint256 impairmentGracePeriod; // seconds after term ends before impairment allowed
    uint256 expiresAt;             // timestamp when offer expires (0 = no expiry)
    address callbackContract;      // contract to call when loan is accepted (address(0) = none)
    bytes4 callbackSelector;       // function selector for callback
}

struct InterestConfig {
    uint16 interestRateBps;        // net interest rate in basis points (100 = 1%)
    uint16 numberOfPeriodsPerYear; // compounding frequency (e.g. 12 = monthly)
}
```

## Steps
1. Look up `frendLendV2` and `bullaApprovalRegistry` addresses for the target chain
2. Call `setApprovalForController(frendLendV2Address, true)` on BullaApprovalRegistry (one-time)
3. Call `offerLoan(params)` on the FrendLendV2 contract
4. The counterparty accepts by calling `acceptLoan(offerId)` — this transfers the principal and creates the claim
5. The borrower repays via `payLoan(claimId, amount)` on FrendLendV2

## Example
```solidity
// Approve controller (one-time)
bullaApprovalRegistry.setApprovalForController(frendLendV2Address, true);

// Create loan offer (as creditor/lender)
LoanRequestParams memory params = LoanRequestParams({
    termLength: 30 days,                          // 2592000 seconds
    interestConfig: InterestConfig(500, 12),       // 5% APR, compounded monthly
    loanAmount: 1000000,                           // 1 USDC
    creditor: msg.sender,                          // lender
    debtor: borrowerAddress,                       // borrower
    description: "30-day loan at 5% APR",
    token: usdcTokenAddress,
    impairmentGracePeriod: 7 days,                 // 604800 seconds
    expiresAt: block.timestamp + 7 days,           // offer valid for 7 days
    callbackContract: address(0),                  // no callback
    callbackSelector: bytes4(0)                    // no callback
});

uint256 offerId = frendLendV2.offerLoan(params);

// Borrower accepts (transfers principal from lender to borrower, creates claim)
// token.approve(frendLendV2Address, amount) must be called by creditor first
uint256 claimId = frendLendV2.acceptLoan(offerId);
```

## Common Errors
- Caller has not approved FrendLendV2 on BullaApprovalRegistry: reverts
- Creditor and debtor are the same address: reverts
- loanAmount is 0: reverts
- Offer has expired (block.timestamp > expiresAt): reverts
- Offer already accepted or rejected: reverts
