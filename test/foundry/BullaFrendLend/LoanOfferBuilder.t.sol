// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.14;

import {LoanOffer} from "contracts/BullaFrendLend.sol";
import {InterestConfig} from "contracts/libraries/CompoundInterestLib.sol";

contract LoanOfferBuilder {
    uint256 private _termLength;
    InterestConfig private _interestConfig;
    uint128 private _loanAmount;
    address private _creditor;
    address private _debtor;
    string private _description;
    address private _token;

    constructor() {
        // Default values
        _termLength = 30 days;
        _interestConfig = InterestConfig({
            interestRateBps: 1000, // 10% APR
            numberOfPeriodsPerYear: 12 // Monthly compounding
        });
        _loanAmount = 1 ether;
        _creditor = address(0x1);
        _debtor = address(0x2);
        _description = "Test Loan Offer";
        _token = address(0x3); // Mock token address
    }

    function withTermLength(uint256 termLength) public returns (LoanOfferBuilder) {
        _termLength = termLength;
        return this;
    }

    function withInterestConfig(InterestConfig memory interestConfig) public returns (LoanOfferBuilder) {
        _interestConfig = interestConfig;
        return this;
    }

    function withInterestRate(uint16 interestRateBps, uint16 numberOfPeriodsPerYear) public returns (LoanOfferBuilder) {
        _interestConfig = InterestConfig({
            interestRateBps: interestRateBps,
            numberOfPeriodsPerYear: numberOfPeriodsPerYear
        });
        return this;
    }

    function withLoanAmount(uint128 loanAmount) public returns (LoanOfferBuilder) {
        _loanAmount = loanAmount;
        return this;
    }

    function withCreditor(address creditor) public returns (LoanOfferBuilder) {
        _creditor = creditor;
        return this;
    }

    function withDebtor(address debtor) public returns (LoanOfferBuilder) {
        _debtor = debtor;
        return this;
    }

    function withDescription(string memory description) public returns (LoanOfferBuilder) {
        _description = description;
        return this;
    }

    function withToken(address token) public returns (LoanOfferBuilder) {
        _token = token;
        return this;
    }

    function build() public view returns (LoanOffer memory) {
        return LoanOffer({
            termLength: _termLength,
            interestConfig: _interestConfig,
            loanAmount: _loanAmount,
            creditor: _creditor,
            debtor: _debtor,
            description: _description,
            token: _token
        });
    }
} 