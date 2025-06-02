// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.14;

import {LoanRequestParams} from "contracts/BullaFrendLend.sol";
import {InterestConfig} from "contracts/libraries/CompoundInterestLib.sol";

contract LoanRequestParamsBuilder {
    uint256 private _termLength;
    InterestConfig private _interestConfig;
    uint128 private _loanAmount;
    address private _creditor;
    address private _debtor;
    string private _description;
    address private _token;
    uint256 private _impairmentGracePeriod;

    constructor() {
        // Default values
        _termLength = 30 days;
        _interestConfig = InterestConfig({
            interestRateBps: 500, // 5% APR
            numberOfPeriodsPerYear: 12 // Monthly compounding
        });
        _loanAmount = 1 ether;
        _creditor = address(0x0);
        _debtor = address(0x0);
        _description = "";
        _token = address(0x0); // Mock token address
        _impairmentGracePeriod = 7 days; // 7 days grace period by default
    }

    function withTermLength(uint256 termLength) public returns (LoanRequestParamsBuilder) {
        _termLength = termLength;
        return this;
    }

    function withInterestConfig(InterestConfig memory interestConfig) public returns (LoanRequestParamsBuilder) {
        _interestConfig = interestConfig;
        return this;
    }

    function withInterestRateBps(uint16 interestRateBps) public returns (LoanRequestParamsBuilder) {
        _interestConfig.interestRateBps = interestRateBps;
        return this;
    }

    function withNumberOfPeriodsPerYear(uint16 numberOfPeriodsPerYear) public returns (LoanRequestParamsBuilder) {
        _interestConfig.numberOfPeriodsPerYear = numberOfPeriodsPerYear;
        return this;
    }

    function withInterestRate(uint16 interestRateBps, uint16 numberOfPeriodsPerYear)
        public
        returns (LoanRequestParamsBuilder)
    {
        _interestConfig =
            InterestConfig({interestRateBps: interestRateBps, numberOfPeriodsPerYear: numberOfPeriodsPerYear});
        return this;
    }

    function withLoanAmount(uint128 loanAmount) public returns (LoanRequestParamsBuilder) {
        _loanAmount = loanAmount;
        return this;
    }

    function withCreditor(address creditor) public returns (LoanRequestParamsBuilder) {
        _creditor = creditor;
        return this;
    }

    function withDebtor(address debtor) public returns (LoanRequestParamsBuilder) {
        _debtor = debtor;
        return this;
    }

    function withDescription(string memory description) public returns (LoanRequestParamsBuilder) {
        _description = description;
        return this;
    }

    function withToken(address token) public returns (LoanRequestParamsBuilder) {
        _token = token;
        return this;
    }

    function withImpairmentGracePeriod(uint256 impairmentGracePeriod) public returns (LoanRequestParamsBuilder) {
        _impairmentGracePeriod = impairmentGracePeriod;
        return this;
    }

    function build() public view returns (LoanRequestParams memory) {
        return LoanRequestParams({
            termLength: _termLength,
            interestConfig: _interestConfig,
            loanAmount: _loanAmount,
            creditor: _creditor,
            debtor: _debtor,
            description: _description,
            token: _token,
            impairmentGracePeriod: _impairmentGracePeriod
        });
    }
}
