// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.14;

import {CreateInvoiceParams, ClaimBinding} from "contracts/BullaInvoice.sol";
import {InterestConfig} from "contracts/libraries/CompoundInterestLib.sol";

contract CreateInvoiceParamsBuilder {
    address private _debtor;
    uint256 private _claimAmount;
    uint256 private _dueBy;
    uint256 private _deliveryDate;
    string private _description;
    address private _token;
    ClaimBinding private _binding;
    bool private _payerReceivesClaimOnPayment;
    InterestConfig private _lateFeeConfig;
    uint256 private _impairmentGracePeriod;

    constructor() {
        // Default values
        _debtor = address(0);
        _claimAmount = 1 ether;
        _dueBy = block.timestamp + 30 days;
        _deliveryDate = 0;
        _description = "Test Invoice";
        _token = address(0); // ETH by default
        _binding = ClaimBinding.BindingPending;
        _payerReceivesClaimOnPayment = true;
        _lateFeeConfig = InterestConfig({interestRateBps: 0, numberOfPeriodsPerYear: 0});
        _impairmentGracePeriod = 7 days; // 7 days grace period by default
    }

    function withDebtor(address debtor) public returns (CreateInvoiceParamsBuilder) {
        _debtor = debtor;
        return this;
    }

    function withClaimAmount(uint256 claimAmount) public returns (CreateInvoiceParamsBuilder) {
        _claimAmount = claimAmount;
        return this;
    }

    function withDueBy(uint256 dueBy) public returns (CreateInvoiceParamsBuilder) {
        _dueBy = dueBy;
        return this;
    }

    function withDeliveryDate(uint256 deliveryDate) public returns (CreateInvoiceParamsBuilder) {
        _deliveryDate = deliveryDate;
        return this;
    }

    function withDescription(string memory description) public returns (CreateInvoiceParamsBuilder) {
        _description = description;
        return this;
    }

    function withToken(address token) public returns (CreateInvoiceParamsBuilder) {
        _token = token;
        return this;
    }

    function withBinding(ClaimBinding binding) public returns (CreateInvoiceParamsBuilder) {
        _binding = binding;
        return this;
    }

    function withPayerReceivesClaimOnPayment(bool payerReceivesClaim) public returns (CreateInvoiceParamsBuilder) {
        _payerReceivesClaimOnPayment = payerReceivesClaim;
        return this;
    }

    function withLateFeeConfig(InterestConfig memory lateFeeConfig) public returns (CreateInvoiceParamsBuilder) {
        _lateFeeConfig = lateFeeConfig;
        return this;
    }

    function withImpairmentGracePeriod(uint256 impairmentGracePeriod) public returns (CreateInvoiceParamsBuilder) {
        _impairmentGracePeriod = impairmentGracePeriod;
        return this;
    }

    function build() public view returns (CreateInvoiceParams memory) {
        return CreateInvoiceParams({
            debtor: _debtor,
            claimAmount: _claimAmount,
            dueBy: _dueBy,
            deliveryDate: _deliveryDate,
            description: _description,
            token: _token,
            binding: _binding,
            payerReceivesClaimOnPayment: _payerReceivesClaimOnPayment,
            lateFeeConfig: _lateFeeConfig,
            impairmentGracePeriod: _impairmentGracePeriod
        });
    }
}
