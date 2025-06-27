// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import "../types/Types.sol";
import "../interfaces/IPermissions.sol";

/// @title BullaClaimValidationLib
/// @notice Library containing validation logic for BullaClaim operations
library BullaClaimValidationLib {
    // Custom errors
    error InvalidDueBy();
    error ZeroAmount();
    error NotCreditorOrDebtor();
    error CannotBindClaim();
    error PayingZero();
    error ClaimNotPending();
    error OverPaying(uint256 paymentAmount);
    error NotCreditor();
    error NoDueBy();
    error StillInGracePeriod();
    error ClaimBound();
    error NotApproved();
    error PastApprovalDeadline();
    error PaymentUnderApproved();
    error IncorrectFee();

    /// @notice Validates parameters for creating a new claim
    /// @param from The address creating the claim
    /// @param params The claim creation parameters
    function validateCreateClaimParams(
        address from,
        CreateClaimParams calldata params,
        IPermissions feeExemptions,
        uint256 CORE_PROTOCOL_FEE,
        uint256 _msgValue
    ) external view {
        if (
            !feeExemptions.isAllowed(params.debtor) && !feeExemptions.isAllowed(params.creditor)
                && _msgValue != CORE_PROTOCOL_FEE
        ) revert IncorrectFee();
        // Validate the caller is either creditor or debtor
        if (from != params.debtor && from != params.creditor) revert NotCreditorOrDebtor();

        // Validate due date
        if (params.dueBy != 0 && (params.dueBy < block.timestamp || params.dueBy > type(uint40).max)) {
            revert InvalidDueBy();
        }

        // Validate impairment grace period
        if (params.impairmentGracePeriod > type(uint40).max) {
            revert InvalidDueBy(); // reuse this error for consistency since it's about time validation
        }

        // Validate binding permissions - only debtor can bind themselves
        if (params.binding == ClaimBinding.Bound && from != params.debtor) revert CannotBindClaim();

        // Validate claim amount is not zero
        if (params.claimAmount == 0) revert ZeroAmount();
    }

    /// @notice Validates payment parameters and calculates payment state
    /// @param claim The claim being paid
    /// @param paymentAmount The amount being paid
    /// @return totalPaidAmount The total amount that will be paid after this payment
    /// @return claimPaid Whether the claim will be fully paid after this payment
    function validateAndCalculatePayment(Claim memory claim, uint256 paymentAmount)
        external
        pure
        returns (uint256 totalPaidAmount, bool claimPaid)
    {
        // Validate payment amount is not zero
        if (paymentAmount == 0) revert PayingZero();

        // Validate claim can be paid (not completed, not rejected, not rescinded)
        if (claim.status != Status.Pending && claim.status != Status.Repaying && claim.status != Status.Impaired) {
            revert ClaimNotPending();
        }

        // Calculate payment state
        totalPaidAmount = claim.paidAmount + paymentAmount;
        claimPaid = totalPaidAmount == claim.claimAmount;

        // Validate not overpaying
        if (totalPaidAmount > claim.claimAmount) revert OverPaying(paymentAmount);

        return (totalPaidAmount, claimPaid);
    }

    /// @notice Validates binding update parameters
    /// @param from The address updating the binding
    /// @param claim The claim being updated
    /// @param creditor The current creditor (NFT owner)
    /// @param binding The new binding state
    function validateBindingUpdate(address from, Claim memory claim, address creditor, ClaimBinding binding)
        external
        pure
    {
        // Validate claim status allows binding updates
        if (claim.status != Status.Pending && claim.status != Status.Repaying && claim.status != Status.Impaired) {
            revert ClaimNotPending();
        }

        // Validate sender is authorized (creditor or debtor)
        if (from != creditor && from != claim.debtor) revert NotCreditorOrDebtor();

        // Validate binding rules
        if (from == creditor && binding == ClaimBinding.Bound) revert CannotBindClaim();
        if (from == claim.debtor && claim.binding == ClaimBinding.Bound) revert ClaimBound();
    }

    /// @notice Validates claim cancellation parameters
    /// @param from The address canceling the claim
    /// @param claim The claim being canceled
    /// @param creditor The current creditor (NFT owner)
    function validateClaimCancellation(address from, Claim memory claim, address creditor) external pure {
        // Validate bound claims cannot be canceled by debtor
        if (claim.binding == ClaimBinding.Bound && claim.debtor == from) revert ClaimBound();

        // Validate claim status allows cancellation
        if (claim.status != Status.Pending) revert ClaimNotPending();

        // Validate sender is authorized (creditor or debtor)
        if (from != claim.debtor && from != creditor) revert NotCreditorOrDebtor();
    }

    /// @notice Validates claim impairment parameters
    /// @param from The address impairing the claim
    /// @param claim The claim being impaired
    /// @param creditor The current creditor (NFT owner)
    function validateClaimImpairment(address from, Claim memory claim, address creditor) external view {
        // Validate claim status allows impairment
        if (claim.status != Status.Pending && claim.status != Status.Repaying) revert ClaimNotPending();

        // Validate only creditor can impair
        if (from != creditor) revert NotCreditor();

        // Validate grace period requirements
        if (claim.dueBy == 0) revert NoDueBy();
        if (block.timestamp < claim.dueBy + claim.impairmentGracePeriod) revert StillInGracePeriod();
    }

    /// @notice Validates mark as paid parameters
    /// @param from The address marking the claim as paid
    /// @param claim The claim being marked as paid
    /// @param creditor The current creditor (NFT owner)
    function validateMarkAsPaid(address from, Claim memory claim, address creditor) external pure {
        // Validate claim status allows marking as paid
        if (claim.status != Status.Pending && claim.status != Status.Repaying && claim.status != Status.Impaired) {
            revert ClaimNotPending();
        }

        // Validate only creditor can mark as paid
        if (from != creditor) revert NotCreditor();
    }

    /// @notice Validates create claim approval parameters
    /// @param approval The create claim approval struct
    /// @param from The address creating the claim
    /// @param creditor The creditor address
    /// @param debtor The debtor address
    /// @param binding The claim binding
    function validateCreateClaimApproval(
        CreateClaimApproval memory approval,
        address from,
        address creditor,
        address debtor,
        ClaimBinding binding
    ) external pure {
        // Validate approval count
        if (approval.approvalCount == 0) revert NotApproved();

        // Validate binding permissions
        if (binding == ClaimBinding.Bound && !approval.isBindingAllowed) revert CannotBindClaim();

        // Validate approval type permissions
        if (
            (approval.approvalType == CreateClaimApprovalType.CreditorOnly && from != creditor)
                || (approval.approvalType == CreateClaimApprovalType.DebtorOnly && from != debtor)
        ) {
            revert NotApproved();
        }
    }
}
