// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import {MockERC20} from "contracts/mocks/MockERC20.sol";
import {
    Claim,
    Status,
    ClaimBinding,
    CreateClaimParams,
    LockState,
    ClaimMetadata,
    CreateClaimApprovalType
} from "contracts/types/Types.sol";
import {InterestConfig, InterestComputationState} from "contracts/libraries/CompoundInterestLib.sol";
import {
    LoanRequestParams,
    LoanOffer,
    LoanDetails,
    Loan,
    IncorrectFee,
    FrendLendBatchInvalidMsgValue,
    BullaFrendLendV2
} from "contracts/BullaFrendLendV2.sol";
import {BullaClaimV2} from "contracts/BullaClaimV2.sol";
import {WhitelistPermissions} from "contracts/WhitelistPermissions.sol";
import {DeployContracts} from "script/DeployContracts.s.sol";
import {LoanRequestParamsBuilder} from "test/foundry/BullaFrendLend/LoanRequestParamsBuilder.t.sol";
import {EIP712Helper} from "test/foundry/BullaClaim/EIP712/Utils.sol";

contract TestBullaFrendLendProtocolFeeExemptions is Test {
    BullaClaimV2 public bullaClaim;
    BullaFrendLendV2 public bullaFrendLend;
    WhitelistPermissions public feeExemptions;
    MockERC20 public token;
    EIP712Helper public sigHelper;

    address private _owner = makeAddr("owner");
    address private _creditor = makeAddr("creditor");
    address private _debtor = makeAddr("debtor");
    address private _exemptUser = makeAddr("exemptUser");
    address private _nonExemptUser = makeAddr("nonExemptUser");
    address private _admin = makeAddr("admin");

    uint256 private _creditorPK = 0x1;
    uint256 private _debtorPK = 0x2;
    uint256 private _exemptUserPK = 0x3;
    uint256 private _nonExemptUserPK = 0x4;

    uint256 private constant _CORE_PROTOCOL_FEE = 0.01 ether;
    uint16 private constant _PROTOCOL_FEE_BPS = 5000; // 50%
    uint256 private constant _LOAN_AMOUNT = 1000e18;
    uint256 private constant _TERM_LENGTH = 90 days;

    event LoanOffered(uint256 indexed loanId, address indexed offeredBy, LoanRequestParams loanOffer);
    event LoanOfferAccepted(uint256 indexed loanId, uint256 indexed claimId);
    event LoanPayment(uint256 indexed claimId, uint256 grossInterestPaid, uint256 principalPaid, uint256 protocolFee);

    function setUp() public {
        // Set up addresses from private keys
        _creditor = vm.addr(_creditorPK);
        _debtor = vm.addr(_debtorPK);
        _exemptUser = vm.addr(_exemptUserPK);
        _nonExemptUser = vm.addr(_nonExemptUserPK);

        token = new MockERC20("TestToken", "TT", 18);
        token.mint(_creditor, 1000000e18);
        token.mint(_debtor, 1000000e18);
        token.mint(_exemptUser, 1000000e18);
        token.mint(_nonExemptUser, 1000000e18);

        // Deploy fee exemptions contract
        vm.prank(_admin);
        feeExemptions = new WhitelistPermissions();

        // Deploy BullaClaim with fee exemptions
        vm.prank(_owner);
        DeployContracts.DeploymentResult memory deploymentResult =
            (new DeployContracts()).deployForTest(_owner, LockState.Unlocked, _CORE_PROTOCOL_FEE, 0, 0, _owner);
        bullaClaim = BullaClaimV2(deploymentResult.bullaClaim);

        // Set fee exemptions contract on BullaClaim
        vm.prank(_owner);
        bullaClaim.setFeeExemptions(address(feeExemptions));

        // Deploy BullaFrendLend
        bullaFrendLend = new BullaFrendLendV2(address(bullaClaim), _admin, _PROTOCOL_FEE_BPS);

        sigHelper = new EIP712Helper(address(bullaClaim));

        // Setup balances
        vm.deal(_creditor, 100 ether);
        vm.deal(_debtor, 100 ether);
        vm.deal(_exemptUser, 100 ether);
        vm.deal(_nonExemptUser, 100 ether);

        // Setup permissions for loan creation and payment
        _setupPermissions(_creditor, _creditorPK);
        _setupPermissions(_debtor, _debtorPK);
        _setupPermissions(_exemptUser, _exemptUserPK);
        _setupPermissions(_nonExemptUser, _nonExemptUserPK);
    }

    function _setupPermissions(address user, uint256 userPK) internal {
        bullaClaim.approvalRegistry().permitCreateClaim({
            user: user,
            controller: address(bullaFrendLend),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: type(uint64).max,
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: userPK,
                user: user,
                controller: address(bullaFrendLend),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: type(uint64).max,
                isBindingAllowed: true
            })
        });
    }

    function _createLoanOffer(address creditor, address debtor, uint256 loanAmount) internal returns (uint256) {
        LoanRequestParams memory loanParams = new LoanRequestParamsBuilder().withTermLength(_TERM_LENGTH)
            .withInterestRate(1200, 12).withLoanAmount(loanAmount).withCreditor(creditor).withDebtor(debtor).withToken(
            address(token)
        ).withImpairmentGracePeriod(30 days).build();

        vm.prank(creditor);
        return bullaFrendLend.offerLoan(loanParams);
    }

    // Test that exempt user can accept loan without core protocol fee
    function testExemptUserCanAcceptLoanWithoutCoreFee() public {
        // Add exempt user to whitelist
        vm.prank(_admin);
        feeExemptions.allow(_exemptUser);

        // Create loan offer as creditor
        uint256 offerId = _createLoanOffer(_creditor, _exemptUser, _LOAN_AMOUNT);

        // Approve token transfer for loan funding
        vm.prank(_creditor);
        token.approve(address(bullaFrendLend), _LOAN_AMOUNT);

        uint256 contractBalanceBefore = address(bullaClaim).balance;
        uint256 debtorBalanceBefore = token.balanceOf(_exemptUser);

        vm.prank(_exemptUser);
        uint256 claimId = bullaFrendLend.acceptLoan{value: 0}(offerId);

        assertEq(claimId, 0, "Loan should be accepted successfully");
        assertEq(address(bullaClaim).balance, contractBalanceBefore, "No core fee should be collected from exempt user");
        assertEq(token.balanceOf(_exemptUser) - debtorBalanceBefore, _LOAN_AMOUNT, "Debtor should receive loan amount");
    }

    // Test that non-exempt user must pay core protocol fee
    function testNonExemptUserMustPayCoreFee() public {
        // Create loan offer as creditor
        uint256 offerId = _createLoanOffer(_creditor, _nonExemptUser, _LOAN_AMOUNT);

        // Approve token transfer for loan funding
        vm.prank(_creditor);
        token.approve(address(bullaFrendLend), _LOAN_AMOUNT);

        // Should fail without fee
        vm.prank(_nonExemptUser);
        vm.expectRevert(IncorrectFee.selector);
        bullaFrendLend.acceptLoan{value: 0}(offerId);

        // Should succeed with fee
        uint256 contractBalanceBefore = address(bullaClaim).balance;

        vm.prank(_nonExemptUser);
        uint256 claimId = bullaFrendLend.acceptLoan{value: _CORE_PROTOCOL_FEE}(offerId);

        assertEq(claimId, 0, "Loan should be accepted successfully with fee");
        assertEq(
            address(bullaClaim).balance, contractBalanceBefore + _CORE_PROTOCOL_FEE, "Core fee should be collected"
        );
    }

    // Test that exempt user pays no protocol fee on interest
    function testExemptUserPaysNoProtocolFeeOnInterest() public {
        // Add exempt user to whitelist
        vm.prank(_admin);
        feeExemptions.allow(_exemptUser);

        // Create and accept loan with exempt user
        uint256 offerId = _createLoanOffer(_creditor, _exemptUser, _LOAN_AMOUNT);

        vm.prank(_creditor);
        token.approve(address(bullaFrendLend), _LOAN_AMOUNT);

        vm.prank(_exemptUser);
        uint256 claimId = bullaFrendLend.acceptLoan{value: 0}(offerId);

        // Fast forward to accrue interest
        vm.warp(block.timestamp + 90 days);

        Loan memory loan = bullaFrendLend.getLoan(claimId);
        uint256 accruedInterest = loan.interestComputationState.accruedInterest;

        uint256 creditorBalanceBefore = token.balanceOf(_creditor);
        uint256 contractBalanceBefore = token.balanceOf(address(bullaFrendLend));

        // Pay interest
        vm.prank(_exemptUser);
        token.approve(address(bullaFrendLend), accruedInterest);

        vm.expectEmit(true, false, false, true);
        emit LoanPayment(claimId, accruedInterest, 0, 0); // No protocol fee

        vm.prank(_exemptUser);
        bullaFrendLend.payLoan(claimId, accruedInterest);

        // Verify no protocol fee was charged
        assertEq(
            token.balanceOf(_creditor) - creditorBalanceBefore, accruedInterest, "Creditor should receive full interest"
        );
        assertEq(token.balanceOf(address(bullaFrendLend)), contractBalanceBefore, "No protocol fee should be collected");
    }

    // Test that non-exempt user pays protocol fee on interest
    function testNonExemptUserPaysProtocolFeeOnInterest() public {
        // Create and accept loan with non-exempt user
        uint256 offerId = _createLoanOffer(_creditor, _nonExemptUser, _LOAN_AMOUNT);

        vm.prank(_creditor);
        token.approve(address(bullaFrendLend), _LOAN_AMOUNT);

        vm.prank(_nonExemptUser);
        uint256 claimId = bullaFrendLend.acceptLoan{value: _CORE_PROTOCOL_FEE}(offerId);

        // Fast forward to accrue interest
        vm.warp(block.timestamp + 90 days);

        Loan memory loan = bullaFrendLend.getLoan(claimId);
        uint256 accruedInterest = loan.interestComputationState.accruedInterest;

        uint256 contractBalanceBefore = token.balanceOf(address(bullaFrendLend));

        // Pay interest
        vm.prank(_nonExemptUser);
        token.approve(address(bullaFrendLend), accruedInterest);

        vm.prank(_nonExemptUser);
        bullaFrendLend.payLoan(claimId, accruedInterest);

        assertGt(token.balanceOf(address(bullaFrendLend)), contractBalanceBefore, "Protocol fee should be collected");
    }

    // Test batch loan acceptance with exemption
    function testBatchAcceptLoansWithExemption() public {
        // Add exempt user to whitelist
        vm.prank(_admin);
        feeExemptions.allow(_exemptUser);

        // Create multiple loan offers
        uint256 offerId1 = _createLoanOffer(_creditor, _exemptUser, _LOAN_AMOUNT);
        uint256 offerId2 = _createLoanOffer(_creditor, _exemptUser, _LOAN_AMOUNT);

        // Approve token transfers for loan funding
        vm.prank(_creditor);
        token.approve(address(bullaFrendLend), _LOAN_AMOUNT * 2);

        uint256 contractBalanceBefore = address(bullaClaim).balance;

        uint256[] memory offerIds = new uint256[](2);
        offerIds[0] = offerId1;
        offerIds[1] = offerId2;

        // Should work with 0 msg.value for exempt user
        vm.prank(_exemptUser);
        bullaFrendLend.batchAcceptLoans{value: 0}(offerIds);

        // Verify no fees were charged
        assertEq(address(bullaClaim).balance, contractBalanceBefore, "No fees should be charged for exempt user");

        // Verify both loans were accepted
        Loan memory loan1 = bullaFrendLend.getLoan(0);
        Loan memory loan2 = bullaFrendLend.getLoan(1);
        assertEq(loan1.claimAmount, _LOAN_AMOUNT, "First loan should be accepted");
        assertEq(loan2.claimAmount, _LOAN_AMOUNT, "Second loan should be accepted");
    }

    // Test batch loan acceptance without exemption
    function testBatchAcceptLoansWithoutExemption() public {
        // Create multiple loan offers
        uint256 offerId1 = _createLoanOffer(_creditor, _nonExemptUser, _LOAN_AMOUNT);
        uint256 offerId2 = _createLoanOffer(_creditor, _nonExemptUser, _LOAN_AMOUNT);

        // Approve token transfers for loan funding
        vm.prank(_creditor);
        token.approve(address(bullaFrendLend), _LOAN_AMOUNT * 2);

        uint256 expectedTotalFee = _CORE_PROTOCOL_FEE * 2;

        uint256[] memory offerIds = new uint256[](2);
        offerIds[0] = offerId1;
        offerIds[1] = offerId2;

        // Should fail with 0 msg.value
        vm.prank(_nonExemptUser);
        vm.expectRevert(FrendLendBatchInvalidMsgValue.selector);
        bullaFrendLend.batchAcceptLoans{value: 0}(offerIds);

        uint256 contractBalanceBefore = address(bullaClaim).balance;

        // Should succeed with correct total fee
        vm.prank(_nonExemptUser);
        bullaFrendLend.batchAcceptLoans{value: expectedTotalFee}(offerIds);

        // Verify fees were charged
        assertEq(address(bullaClaim).balance - contractBalanceBefore, expectedTotalFee, "Total fees should be charged");
    }

    // Test that exemption status is locked at creation time
    function testExemptionStatusLockedAtCreation() public {
        // Create and accept loan as non-exempt user
        uint256 offerId = _createLoanOffer(_creditor, _nonExemptUser, _LOAN_AMOUNT);

        vm.prank(_creditor);
        token.approve(address(bullaFrendLend), _LOAN_AMOUNT);

        vm.prank(_nonExemptUser);
        uint256 claimId = bullaFrendLend.acceptLoan{value: _CORE_PROTOCOL_FEE}(offerId);

        // Now make user exempt
        vm.prank(_admin);
        feeExemptions.allow(_nonExemptUser);

        // Fast forward to accrue interest
        vm.warp(block.timestamp + 90 days);

        Loan memory loan = bullaFrendLend.getLoan(claimId);
        uint256 accruedInterest = loan.interestComputationState.accruedInterest;

        uint256 contractBalanceBefore = token.balanceOf(address(bullaFrendLend));

        // Protocol fee should still apply because exemption status was determined at creation
        vm.prank(_nonExemptUser);
        token.approve(address(bullaFrendLend), accruedInterest);
        vm.prank(_nonExemptUser);
        bullaFrendLend.payLoan(claimId, accruedInterest);

        assertGt(
            token.balanceOf(address(bullaFrendLend)),
            contractBalanceBefore,
            "Protocol fee should still apply - exemption status locked at creation"
        );
    }

    // Test mixed payment (principal + interest) with exemption
    function testMixedPaymentWithExemption() public {
        // Add exempt user to whitelist
        vm.prank(_admin);
        feeExemptions.allow(_exemptUser);

        // Create and accept loan with exempt user
        uint256 offerId = _createLoanOffer(_creditor, _exemptUser, _LOAN_AMOUNT);

        vm.prank(_creditor);
        token.approve(address(bullaFrendLend), _LOAN_AMOUNT);

        vm.prank(_exemptUser);
        uint256 claimId = bullaFrendLend.acceptLoan{value: 0}(offerId);

        // Fast forward to accrue interest
        vm.warp(block.timestamp + 90 days);

        Loan memory loan = bullaFrendLend.getLoan(claimId);
        uint256 accruedInterest = loan.interestComputationState.accruedInterest;
        uint256 principalPayment = 500e18;
        uint256 totalPayment = accruedInterest + principalPayment;

        uint256 creditorBalanceBefore = token.balanceOf(_creditor);

        // Pay interest + partial principal
        vm.prank(_exemptUser);
        token.approve(address(bullaFrendLend), totalPayment);

        vm.expectEmit(true, false, false, true);
        emit LoanPayment(claimId, accruedInterest, principalPayment, 0); // No protocol fee

        vm.prank(_exemptUser);
        bullaFrendLend.payLoan(claimId, totalPayment);

        // Verify no protocol fee on any portion
        assertEq(
            token.balanceOf(_creditor) - creditorBalanceBefore, totalPayment, "Creditor should receive full payment"
        );
        assertEq(token.balanceOf(address(bullaFrendLend)), 0, "No protocol fee should be collected");
    }

    // Test loan offered by debtor and accepted by creditor - fee based on debtor exemption
    function testDebtorOfferedLoanAcceptedByCreditor() public {
        // Create loan request as debtor (non-exempt user creates request)
        LoanRequestParams memory loanParams = new LoanRequestParamsBuilder().withTermLength(_TERM_LENGTH)
            .withInterestRate(1200, 12).withLoanAmount(_LOAN_AMOUNT).withCreditor(_creditor).withDebtor(_nonExemptUser)
            .withDescription("Test loan request").withToken(address(token)).withImpairmentGracePeriod(30 days) // Regular creditor
                // Non-exempt user is debtor making request
            .build();

        vm.prank(_nonExemptUser);
        uint256 offerId = bullaFrendLend.offerLoan(loanParams);

        // Approve token transfer for loan funding
        vm.prank(_creditor);
        token.approve(address(bullaFrendLend), _LOAN_AMOUNT);

        uint256 contractBalanceBefore = address(bullaClaim).balance;

        // Should require fee because debtor (non-exempt user) is not exempt
        vm.prank(_creditor);
        uint256 claimId = bullaFrendLend.acceptLoan{value: _CORE_PROTOCOL_FEE}(offerId);

        assertEq(claimId, 0, "Loan should be accepted successfully");
        assertEq(
            address(bullaClaim).balance,
            contractBalanceBefore + _CORE_PROTOCOL_FEE,
            "Core fee should be collected based on debtor exemption status"
        );
    }

    // Test fee exempt creditor offers loan - no protocol fee on interest
    function testExemptCreditorOffersLoanNoProtocolFeeOnInterest() public {
        // Add exempt creditor to whitelist
        vm.prank(_admin);
        feeExemptions.allow(_creditor);

        // Exempt creditor offers loan to non-exempt debtor
        uint256 offerId = _createLoanOffer(_creditor, _nonExemptUser, _LOAN_AMOUNT);

        // Approve token transfer for loan funding
        vm.prank(_creditor);
        token.approve(address(bullaFrendLend), _LOAN_AMOUNT);

        uint256 contractBalanceBefore = address(bullaClaim).balance;

        // Non-exempt debtor accepts loan - should be no core fee because creditor is exempt
        vm.prank(_nonExemptUser);
        uint256 claimId = bullaFrendLend.acceptLoan{value: 0}(offerId);

        assertEq(
            address(bullaClaim).balance, contractBalanceBefore, "No core fee should be charged when creditor is exempt"
        );

        // Fast forward to accrue interest
        vm.warp(block.timestamp + 90 days);

        Loan memory loan = bullaFrendLend.getLoan(claimId);
        uint256 accruedInterest = loan.interestComputationState.accruedInterest;

        uint256 creditorBalanceBefore = token.balanceOf(_creditor);
        uint256 frendLendBalanceBefore = token.balanceOf(address(bullaFrendLend));

        // Approve and pay interest
        vm.prank(_nonExemptUser);
        token.approve(address(bullaFrendLend), accruedInterest);

        vm.expectEmit(true, false, false, true);
        emit LoanPayment(claimId, accruedInterest, 0, 0); // No protocol fee

        vm.prank(_nonExemptUser);
        bullaFrendLend.payLoan(claimId, accruedInterest);

        // Verify no protocol fee was charged on interest
        assertEq(
            token.balanceOf(_creditor) - creditorBalanceBefore, accruedInterest, "Creditor should receive full interest"
        );
        assertEq(
            token.balanceOf(address(bullaFrendLend)),
            frendLendBalanceBefore,
            "No protocol fee should be collected on interest"
        );
    }
}
