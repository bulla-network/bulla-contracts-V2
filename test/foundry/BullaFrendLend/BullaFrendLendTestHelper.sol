// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.30;

import {BullaClaimTestHelper} from "test/foundry/BullaClaim/BullaClaimTestHelper.sol";
import {BullaFrendLend, LoanRequestParams} from "src/BullaFrendLend.sol";
import {LoanRequestParamsBuilder} from "test/foundry/BullaFrendLend/LoanRequestParamsBuilder.t.sol";
import {CreateClaimApprovalType} from "contracts/types/Types.sol";

/**
 * @title BullaFrendLendTestHelper
 * @notice Test helper contract that extends BullaClaimTestHelper with FrendLend-specific functionality
 * @dev Provides convenience methods for setting up permits and creating loans in tests
 */
contract BullaFrendLendTestHelper is BullaClaimTestHelper {
    BullaFrendLend public bullaFrendLend;

    /*///////////////////// FRENDLEND-SPECIFIC PERMIT HELPERS /////////////////////*/

    /**
     * @notice Set up create claim permissions for a user (used when accepting loans)
     * @param userPK The private key of the user
     * @param count Number of claims the user can create
     * @param isBindingAllowed Whether binding operations are allowed
     */
    function _permitAcceptLoan(uint256 userPK, uint64 count, bool isBindingAllowed) internal {
        _permitCreateClaim(userPK, address(bullaFrendLend), count, CreateClaimApprovalType.Approved, isBindingAllowed);
    }

    /**
     * @notice Set up create claim permissions for a user (with binding allowed)
     * @param userPK The private key of the user
     * @param count Number of loans the user can accept
     */
    function _permitAcceptLoan(uint256 userPK, uint64 count) internal {
        _permitAcceptLoan(userPK, count, true);
    }

    /**
     * @notice Set up create claim permissions for a user (single loan, binding allowed)
     * @param userPK The private key of the user
     */
    function _permitAcceptLoan(uint256 userPK) internal {
        _permitAcceptLoan(userPK, 1, true);
    }

    /*///////////////////// CONVENIENCE METHODS FOR COMMON PATTERNS /////////////////////*/

    /**
     * @notice Set up all permissions needed for a creditor to manage loans
     * @param creditorPK The private key of the creditor
     * @param count Number of operations allowed for each permission type
     */
    function _permitCreditorLoanOperations(uint256 creditorPK, uint64 count) internal {
        _permitAcceptLoan(creditorPK, count);
    }

    /**
     * @notice Set up all permissions needed for a debtor to interact with loans
     * @param debtorPK The private key of the debtor
     * @param count Number of operations allowed for each permission type
     */
    function _permitDebtorLoanOperations(uint256 debtorPK, uint64 count) internal {
        _permitAcceptLoan(debtorPK, count);
    }

    /*///////////////////// LOAN CREATION HELPERS /////////////////////*/

    /**
     * @notice Create a simple loan offer with minimal setup
     * @param creditorPK The private key of the creditor
     * @param debtor The debtor address
     * @param token The token address for the loan
     * @return loanOfferId The ID of the created loan offer
     */
    function _createSimpleLoanOffer(uint256 creditorPK, address debtor, address token)
        internal
        returns (uint256 loanOfferId)
    {
        address creditor = vm.addr(creditorPK);

        vm.prank(creditor);
        loanOfferId = bullaFrendLend.offerLoan(
            new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(token).build()
        );
    }

    /**
     * @notice Create a loan offer with custom parameters
     * @param userPK The private key of the user creating the offer
     * @param params The loan request parameters
     * @return loanOfferId The ID of the created loan offer
     */
    function _createLoanOfferWithParams(uint256 userPK, LoanRequestParams memory params)
        internal
        returns (uint256 loanOfferId)
    {
        address user = vm.addr(userPK);

        vm.prank(user);
        loanOfferId = bullaFrendLend.offerLoan(params);
    }

    /**
     * @notice Accept a loan offer and get the resulting claim ID
     * @param userPK The private key of the user accepting the loan
     * @param loanOfferId The ID of the loan offer to accept
     * @return claimId The ID of the created claim
     */
    function _acceptLoanOffer(uint256 userPK, uint256 loanOfferId, uint256 fee) internal returns (uint256 claimId) {
        address user = vm.addr(userPK);
        _permitAcceptLoan(userPK);

        vm.prank(user);
        claimId = bullaFrendLend.acceptLoan{value: fee}(loanOfferId);
    }

    /**
     * @notice Create a complete loan (offer + acceptance) for testing
     * @param creditorPK The private key of the creditor
     * @param debtorPK The private key of the debtor
     * @param token The token address for the loan
     * @param fee The fee amount to pay for creating the offer
     * @return claimId The ID of the created claim
     */
    function _createCompleteLoan(uint256 creditorPK, uint256 debtorPK, address token, uint256 fee)
        internal
        returns (uint256 claimId)
    {
        address debtor = vm.addr(debtorPK);

        // Create loan offer
        uint256 loanOfferId = _createSimpleLoanOffer(creditorPK, debtor, token);

        // Accept loan offer
        claimId = _acceptLoanOffer(debtorPK, loanOfferId, fee);
    }

    /**
     * @notice Create multiple loan offers for batch testing
     * @param creditorPK The private key of the creditor
     * @param debtors Array of debtor addresses
     * @param token The token address for all loans
     * @return loanOfferIds Array of created loan offer IDs
     */
    function _createMultipleLoanOffers(uint256 creditorPK, address[] memory debtors, address token)
        internal
        returns (uint256[] memory loanOfferIds)
    {
        address creditor = vm.addr(creditorPK);

        loanOfferIds = new uint256[](debtors.length);
        vm.startPrank(creditor);
        for (uint256 i = 0; i < debtors.length; i++) {
            loanOfferIds[i] = bullaFrendLend.offerLoan(
                new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtors[i]).withToken(token).build()
            );
        }
        vm.stopPrank();
    }

    /**
     * @notice Create multiple complete loans for batch testing
     * @param creditorPK The private key of the creditor
     * @param debtorPKs Array of debtor private keys
     * @param token The token address for all loans
     * @param fee The fee amount per loan offer
     * @return claimIds Array of created claim IDs
     */
    function _createMultipleCompleteLoans(uint256 creditorPK, uint256[] memory debtorPKs, address token, uint256 fee)
        internal
        returns (uint256[] memory claimIds)
    {
        claimIds = new uint256[](debtorPKs.length);

        for (uint256 i = 0; i < debtorPKs.length; i++) {
            claimIds[i] = _createCompleteLoan(creditorPK, debtorPKs[i], token, fee);
        }
    }
}
