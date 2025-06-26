pragma solidity ^0.8.30;

import {InvoiceDetails, PurchaseOrderState} from "contracts/BullaInvoice.sol";
import {InterestConfig, InterestComputationState} from "contracts/libraries/CompoundInterestLib.sol";

contract InvoiceDetailsBuilder {
    bool private _requestedByCreditor;
    PurchaseOrderState private _purchaseOrder;
    InterestConfig private _lateFeeConfig;
    InterestComputationState private _interestComputationState;
    bool private _isProtocolFeeExempt;

    constructor() {
        // Default values
        _requestedByCreditor = true;
        _purchaseOrder = PurchaseOrderState({deliveryDate: 0, isDelivered: false, depositAmount: 0});
        _lateFeeConfig = InterestConfig({interestRateBps: 0, numberOfPeriodsPerYear: 0});
        _interestComputationState =
            InterestComputationState({accruedInterest: 0, latestPeriodNumber: 0, protocolFeeBps: 0});
        _isProtocolFeeExempt = false;
    }

    function withRequestedByCreditor(bool requestedByCreditor) public returns (InvoiceDetailsBuilder) {
        _requestedByCreditor = requestedByCreditor;
        return this;
    }

    function withPurchaseOrder(PurchaseOrderState memory purchaseOrder) public returns (InvoiceDetailsBuilder) {
        _purchaseOrder = purchaseOrder;
        return this;
    }

    function withDeliveryDate(uint256 deliveryDate) public returns (InvoiceDetailsBuilder) {
        _purchaseOrder.deliveryDate = deliveryDate;
        return this;
    }

    function withIsDelivered(bool isDelivered) public returns (InvoiceDetailsBuilder) {
        _purchaseOrder.isDelivered = isDelivered;
        return this;
    }

    function withDepositAmount(uint256 depositAmount) public returns (InvoiceDetailsBuilder) {
        _purchaseOrder.depositAmount = depositAmount;
        return this;
    }

    function withLateFeeConfig(InterestConfig memory lateFeeConfig) public returns (InvoiceDetailsBuilder) {
        _lateFeeConfig = lateFeeConfig;
        return this;
    }

    function withInterestRateBps(uint16 interestRateBps) public returns (InvoiceDetailsBuilder) {
        _lateFeeConfig.interestRateBps = interestRateBps;
        return this;
    }

    function withNumberOfPeriodsPerYear(uint16 numberOfPeriodsPerYear) public returns (InvoiceDetailsBuilder) {
        _lateFeeConfig.numberOfPeriodsPerYear = numberOfPeriodsPerYear;
        return this;
    }

    function withInterestComputationState(InterestComputationState memory interestComputationState)
        public
        returns (InvoiceDetailsBuilder)
    {
        _interestComputationState = interestComputationState;
        return this;
    }

    function withAccruedInterest(uint256 accruedInterest) public returns (InvoiceDetailsBuilder) {
        _interestComputationState.accruedInterest = accruedInterest;
        return this;
    }

    function withLatestPeriodNumber(uint256 latestPeriodNumber) public returns (InvoiceDetailsBuilder) {
        _interestComputationState.latestPeriodNumber = latestPeriodNumber;
        return this;
    }

    function withIsProtocolFeeExempt(bool isProtocolFeeExempt) public returns (InvoiceDetailsBuilder) {
        _isProtocolFeeExempt = isProtocolFeeExempt;
        return this;
    }

    function build() public view returns (InvoiceDetails memory) {
        return InvoiceDetails({
            requestedByCreditor: _requestedByCreditor,
            isProtocolFeeExempt: _isProtocolFeeExempt,
            purchaseOrder: _purchaseOrder,
            lateFeeConfig: _lateFeeConfig,
            interestComputationState: _interestComputationState
        });
    }
}
