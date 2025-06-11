// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.14;

import {CreateInvoiceParams, ClaimBinding} from "contracts/BullaInvoice.sol";
import {InterestConfig} from "contracts/libraries/CompoundInterestLib.sol";

contract CreateInvoiceParamsBuilder {
    address private _recipient;
    uint256 private _claimAmount;
    uint256 private _dueBy;
    uint256 private _deliveryDate;
    string private _description;
    address private _token;
    ClaimBinding private _binding;
    bool private _payerReceivesClaimOnPayment;
    InterestConfig private _lateFeeConfig;
    uint256 private _impairmentGracePeriod;
    uint256 private _depositAmount;

    constructor() {
        // Default values
        _recipient = address(0);
        _claimAmount = 1 ether;
        _dueBy = block.timestamp + 30 days;
        _deliveryDate = 0;
        _description = "Test Invoice";
        _token = address(0); // ETH by default
        _binding = ClaimBinding.BindingPending;
        _payerReceivesClaimOnPayment = true;
        _lateFeeConfig = InterestConfig({interestRateBps: 0, numberOfPeriodsPerYear: 0});
        _impairmentGracePeriod = 7 days; // 7 days grace period by default
        _depositAmount = 0; // No deposit by default
    }

    function withDebtor(address debtor) public returns (CreateInvoiceParamsBuilder) {
        _recipient = debtor;
        return this;
    }

    function withCreditor(address creditor) public returns (CreateInvoiceParamsBuilder) {
        _recipient = creditor;
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

    function withDepositAmount(uint256 depositAmount) public returns (CreateInvoiceParamsBuilder) {
        _depositAmount = depositAmount;
        return this;
    }

    function build() public view returns (CreateInvoiceParams memory) {
        return CreateInvoiceParams({
            recipient: _recipient,
            claimAmount: _claimAmount,
            dueBy: _dueBy,
            deliveryDate: _deliveryDate,
            description: _description,
            token: _token,
            binding: _binding,
            payerReceivesClaimOnPayment: _payerReceivesClaimOnPayment,
            lateFeeConfig: _lateFeeConfig,
            impairmentGracePeriod: _impairmentGracePeriod,
            depositAmount: _depositAmount
        });
    }
}
