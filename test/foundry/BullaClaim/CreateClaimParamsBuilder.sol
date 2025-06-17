// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.30;

import {CreateClaimParams, ClaimBinding} from "contracts/types/Types.sol";

contract CreateClaimParamsBuilder {
    address private _creditor;
    address private _debtor;
    uint256 private _claimAmount;
    string private _description;
    address private _token;
    ClaimBinding private _binding;
    bool private _payerReceivesClaimOnPayment;
    uint256 private _dueBy;
    uint256 private _impairmentGracePeriod;

    constructor() {
        // Default values
        _creditor = address(0);
        _debtor = address(0);
        _claimAmount = 1 ether;
        _description = "Test Claim";
        _token = address(0); // ETH by default
        _binding = ClaimBinding.Unbound;
        _payerReceivesClaimOnPayment = true;
        _dueBy = 0; // No due date by default
        _impairmentGracePeriod = 7 days; // 7 days grace period by default
    }

    function withCreditor(address creditor) public returns (CreateClaimParamsBuilder) {
        _creditor = creditor;
        return this;
    }

    function withDebtor(address debtor) public returns (CreateClaimParamsBuilder) {
        _debtor = debtor;
        return this;
    }

    function withClaimAmount(uint256 claimAmount) public returns (CreateClaimParamsBuilder) {
        _claimAmount = claimAmount;
        return this;
    }

    function withDescription(string memory description) public returns (CreateClaimParamsBuilder) {
        _description = description;
        return this;
    }

    function withToken(address token) public returns (CreateClaimParamsBuilder) {
        _token = token;
        return this;
    }

    function withBinding(ClaimBinding binding) public returns (CreateClaimParamsBuilder) {
        _binding = binding;
        return this;
    }

    function withPayerReceivesClaimOnPayment(bool payerReceivesClaim) public returns (CreateClaimParamsBuilder) {
        _payerReceivesClaimOnPayment = payerReceivesClaim;
        return this;
    }

    function withDueBy(uint256 dueBy) public returns (CreateClaimParamsBuilder) {
        _dueBy = dueBy;
        return this;
    }

    function withImpairmentGracePeriod(uint256 impairmentGracePeriod) public returns (CreateClaimParamsBuilder) {
        _impairmentGracePeriod = impairmentGracePeriod;
        return this;
    }

    function build() public view returns (CreateClaimParams memory) {
        return CreateClaimParams({
            creditor: _creditor,
            debtor: _debtor,
            claimAmount: _claimAmount,
            description: _description,
            token: _token,
            binding: _binding,
            payerReceivesClaimOnPayment: _payerReceivesClaimOnPayment,
            dueBy: _dueBy,
            impairmentGracePeriod: _impairmentGracePeriod
        });
    }
}
