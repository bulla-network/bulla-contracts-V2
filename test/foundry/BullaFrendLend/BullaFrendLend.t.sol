// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.14;

import "forge-std/console.sol";
import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import "contracts/types/Types.sol";
import {WETH} from "contracts/mocks/weth.sol";
import {EIP712Helper, privateKeyValidity} from "test/foundry/BullaClaim/EIP712/Utils.sol";
import {BullaClaim} from "contracts/BullaClaim.sol";
import {
    BullaFrendLend,
    LoanOffer,
    Loan,
    IncorrectFee,
    NotCreditor,
    InvalidTermLength,
    NativeTokenNotSupported,
    NotDebtor,
    NotAdmin
} from "contracts/BullaFrendLend.sol";
import {Deployer} from "script/Deployment.s.sol";
import {MockERC20} from "contracts/mocks/MockERC20.sol";
import {LoanOfferBuilder} from "./LoanOfferBuilder.t.sol";
import {InterestConfig} from "contracts/libraries/CompoundInterestLib.sol";
import "test/foundry/BullaClaim/CreateClaimParamsBuilder.sol";
import {BullaClaimValidationLib} from "contracts/libraries/BullaClaimValidationLib.sol";

contract TestBullaFrendLend is Test {
    WETH public weth;
    MockERC20 public usdc;
    MockERC20 public dai;
    BullaClaim public bullaClaim;
    EIP712Helper public sigHelper;
    BullaFrendLend public bullaFrendLend;

    uint256 creditorPK = uint256(0x01);
    uint256 debtorPK = uint256(0x02);
    uint256 adminPK = uint256(0x03);
    address creditor = vm.addr(creditorPK);
    address debtor = vm.addr(debtorPK);
    address admin = vm.addr(adminPK);
    uint256 constant FEE = 0.01 ether;
    uint256 constant PROTOCOL_FEE_BPS = 1000; // 10% protocol fee

    function setUp() public {
        weth = new WETH();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        dai = new MockERC20("Dai Stablecoin", "DAI", 18);

        bullaClaim = (new Deployer()).deploy_test({_deployer: address(this), _initialLockState: LockState.Unlocked});
        sigHelper = new EIP712Helper(address(bullaClaim));
        bullaFrendLend = new BullaFrendLend(address(bullaClaim), admin, FEE, PROTOCOL_FEE_BPS);

        vm.deal(creditor, 10 ether);
        vm.deal(debtor, 10 ether);

        // Setup WETH for tests
        vm.prank(creditor);
        weth.deposit{value: 5 ether}();

        vm.prank(debtor);
        weth.deposit{value: 5 ether}();

        // Setup USDC
        usdc.mint(creditor, 10_000 * 10 ** 6);
        usdc.mint(debtor, 10_000 * 10 ** 6);

        // Setup DAI
        dai.mint(creditor, 10_000 ether);
        dai.mint(debtor, 10_000 ether);
    }

    function _permitImpairClaim(uint256 pk, address controller, uint64 approvalCount) internal {
        bullaClaim.permitImpairClaim({
            user: vm.addr(pk),
            controller: controller,
            approvalCount: approvalCount,
            signature: sigHelper.signImpairClaimPermit({
                pk: pk,
                user: vm.addr(pk),
                controller: controller,
                approvalCount: approvalCount
            })
        });
    }

    function testOfferLoan() public {
        // Approve WETH for transfer
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 2 ether);

        LoanOffer memory offer = new LoanOfferBuilder().withInterestRateBps(500).withCreditor(creditor).withDebtor(
            debtor
        ).withToken(address(weth)).withDescription("Test Loan") // 5% interest (different from default 1000)
            .build();

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan{value: FEE}(offer);

        (
            uint256 termLength,
            InterestConfig memory interestConfig,
            uint128 loanAmount,
            address offerCreditor,
            address offerDebtor,
            string memory description,
            address token,
            uint256 impairmentGracePeriod
        ) = bullaFrendLend.loanOffers(loanId);

        assertEq(interestConfig.interestRateBps, 500, "Interest BPS mismatch");
        assertEq(termLength, 30 days, "Term length mismatch");
        assertEq(loanAmount, 1 ether, "Loan amount mismatch");
        assertEq(offerCreditor, creditor, "Creditor mismatch");
        assertEq(offerDebtor, debtor, "Debtor mismatch");
        assertEq(description, "Test Loan", "Description mismatch");
        assertEq(token, address(weth), "Token address mismatch");
        assertEq(impairmentGracePeriod, 7 days, "Impairment grace period mismatch");
    }

    function testOfferLoanWithIncorrectFee() public {
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 1 ether);

        LoanOffer memory offer = new LoanOfferBuilder().withCreditor(creditor).withDebtor(debtor).withDescription(
            "Test Loan"
        ).withToken(address(weth)).build();

        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(IncorrectFee.selector));
        bullaFrendLend.offerLoan{value: FEE + 0.1 ether}(offer);
    }

    function testOfferLoanWithWrongCreditor() public {
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 1 ether);

        LoanOffer memory offer = new LoanOfferBuilder().withCreditor(debtor).withDebtor(debtor).withDescription(
            "Test Loan"
        ).withToken(address(weth)) // Wrong creditor
            .build();

        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(NotCreditor.selector));
        bullaFrendLend.offerLoan{value: FEE}(offer);
    }

    function testOfferLoanWithZeroTermLength() public {
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 1 ether);

        LoanOffer memory offer = new LoanOfferBuilder().withTermLength(0).withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)) // Invalid term length
            .build();

        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(InvalidTermLength.selector));
        bullaFrendLend.offerLoan{value: FEE}(offer);
    }

    function testOfferLoanWithNativeToken() public {
        LoanOffer memory offer = new LoanOfferBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(0)) // Native token (should be rejected)
            .build();

        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(NativeTokenNotSupported.selector));
        bullaFrendLend.offerLoan{value: FEE}(offer);
    }

    function testOfferLoanWithZeroInterest() public {
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 1 ether);

        LoanOffer memory offer = new LoanOfferBuilder().withInterestRateBps(0).withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)) // Zero interest
            .build();

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan{value: FEE}(offer);

        (, InterestConfig memory interestConfig,,,,,,) = bullaFrendLend.loanOffers(loanId);
        assertEq(interestConfig.interestRateBps, 0, "Interest BPS should be zero");
    }

    function testEndToEndLoanFlow() public {
        // Approve WETH for transfer from creditor to BullaFrendLend
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 2 ether);

        vm.prank(debtor);
        weth.approve(address(bullaFrendLend), 2 ether);

        LoanOffer memory offer = new LoanOfferBuilder().withCreditor(creditor).withDebtor(debtor).withToken(
            address(weth)
        ).withNumberOfPeriodsPerYear(365).build();

        uint256 initialCreditorWeth = weth.balanceOf(creditor);
        uint256 initialDebtorWeth = weth.balanceOf(debtor);

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan{value: FEE}(offer);

        bullaClaim.permitCreateClaim({
            user: debtor,
            controller: address(bullaFrendLend),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaFrendLend),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: true
            })
        });

        vm.prank(debtor);
        uint256 claimId = bullaFrendLend.acceptLoan(loanId);

        assertEq(
            weth.balanceOf(creditor),
            initialCreditorWeth - 1 ether,
            "Creditor WETH balance after loan acceptance incorrect"
        );
        assertEq(
            weth.balanceOf(debtor), initialDebtorWeth + 1 ether, "Debtor WETH balance after loan acceptance incorrect"
        );
        assertEq(weth.balanceOf(address(bullaFrendLend)), 0, "BullaFrendLend WETH balance should be 0 after transfer");

        bullaClaim.permitPayClaim({
            user: debtor,
            controller: address(bullaFrendLend),
            approvalType: PayClaimApprovalType.IsApprovedForAll,
            approvalDeadline: 0,
            paymentApprovals: new ClaimPaymentApprovalParam[](0),
            signature: sigHelper.signPayClaimPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaFrendLend),
                approvalType: PayClaimApprovalType.IsApprovedForAll,
                approvalDeadline: 0,
                paymentApprovals: new ClaimPaymentApprovalParam[](0)
            })
        });

        // Advance time by 15 days to generate some interest
        vm.warp(block.timestamp + 15 days);

        // Get the exact amounts needed for payment
        (uint256 remainingPrincipal, uint256 currentInterest) = bullaFrendLend.getTotalAmountDue(claimId);
        uint256 paymentAmount = remainingPrincipal + currentInterest;

        uint256 initialCreditorBalance = weth.balanceOf(creditor);
        uint256 initialDebtorBalance = weth.balanceOf(debtor);
        uint256 initialContractBalance = weth.balanceOf(address(bullaFrendLend));

        vm.prank(debtor);
        bullaFrendLend.payLoan(claimId, paymentAmount);

        console.log("currentInterest", currentInterest);

        uint256 debtorPaid = initialDebtorBalance - weth.balanceOf(debtor);
        uint256 creditorReceived = weth.balanceOf(creditor) - initialCreditorBalance;
        uint256 contractReceived = weth.balanceOf(address(bullaFrendLend)) - initialContractBalance;

        assertEq(
            debtorPaid,
            creditorReceived + contractReceived,
            "Total paid should equal total received by creditor and contract"
        );

        assertGt(contractReceived, 0, "Protocol fee should be non-zero");

        assertEq(debtorPaid, paymentAmount, "Debtor should pay exactly the required amount");

        assertEq(bullaFrendLend.protocolFeesByToken(address(weth)), contractReceived, "Protocol fee tracking incorrect");

        Loan memory loan = bullaFrendLend.getLoan(claimId);
        assertTrue(loan.status == Status.Paid, "Loan status should be Paid");
        assertEq(loan.paidAmount, remainingPrincipal, "Paid amount should match principal");
        assertEq(loan.claimAmount, remainingPrincipal, "Claim amount should match principal");
    }

    function testRejectLoanOffer() public {
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 2 ether);

        LoanOffer memory offer =
            new LoanOfferBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth)).build();

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan{value: FEE}(offer);

        vm.prank(creditor);
        bullaFrendLend.rejectLoanOffer(loanId);

        (,,, address offerCreditor,,,,) = bullaFrendLend.loanOffers(loanId);
        assertEq(offerCreditor, address(0), "Offer should be deleted after rejection");
    }

    function testPartialLoanPayments() public {
        vm.startPrank(creditor);
        weth.approve(address(bullaFrendLend), 2 ether);
        vm.stopPrank();

        vm.startPrank(debtor);
        weth.approve(address(bullaFrendLend), 2 ether);
        vm.stopPrank();

        LoanOffer memory offer =
            new LoanOfferBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth)).build();

        uint256 initialCreditorWeth = weth.balanceOf(creditor);
        uint256 initialDebtorWeth = weth.balanceOf(debtor);

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan{value: FEE}(offer);

        bullaClaim.permitCreateClaim({
            user: debtor,
            controller: address(bullaFrendLend),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaFrendLend),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: true
            })
        });

        vm.prank(debtor);
        uint256 claimId = bullaFrendLend.acceptLoan(loanId);

        assertEq(
            weth.balanceOf(creditor),
            initialCreditorWeth - 1 ether,
            "Creditor WETH balance after loan acceptance incorrect"
        );
        assertEq(
            weth.balanceOf(debtor), initialDebtorWeth + 1 ether, "Debtor WETH balance after loan acceptance incorrect"
        );

        bullaClaim.permitPayClaim({
            user: debtor,
            controller: address(bullaFrendLend),
            approvalType: PayClaimApprovalType.IsApprovedForAll,
            approvalDeadline: 0,
            paymentApprovals: new ClaimPaymentApprovalParam[](0),
            signature: sigHelper.signPayClaimPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaFrendLend),
                approvalType: PayClaimApprovalType.IsApprovedForAll,
                approvalDeadline: 0,
                paymentApprovals: new ClaimPaymentApprovalParam[](0)
            })
        });

        // Advance time by 10 days to generate some interest
        vm.warp(block.timestamp + 10 days);

        // Make first partial payment
        uint256 firstPaymentAmount = 0.3 ether;
        vm.prank(debtor);
        bullaFrendLend.payLoan(claimId, firstPaymentAmount);

        // Check loan state after first payment
        (, uint256 currentInterest1) = bullaFrendLend.getTotalAmountDue(claimId);
        Loan memory loanAfterFirstPayment = bullaFrendLend.getLoan(claimId);

        assertEq(
            loanAfterFirstPayment.paidAmount,
            firstPaymentAmount - currentInterest1,
            "Paid amount after first payment incorrect"
        );
        assertEq(
            uint8(loanAfterFirstPayment.status),
            uint8(Status.Repaying),
            "Loan should still be active after partial payment"
        );

        // Advance time by another 10 days
        vm.warp(block.timestamp + 10 days);

        // Make second partial payment
        uint256 secondPaymentAmount = 0.4 ether;
        vm.prank(debtor);
        bullaFrendLend.payLoan(claimId, secondPaymentAmount);

        // Check loan state after second payment
        (, uint256 currentInterest2) = bullaFrendLend.getTotalAmountDue(claimId);
        Loan memory loanAfterSecondPayment = bullaFrendLend.getLoan(claimId);

        assertEq(
            loanAfterSecondPayment.paidAmount,
            loanAfterFirstPayment.paidAmount + (secondPaymentAmount - currentInterest2),
            "Paid amount after second payment incorrect"
        );
        assertEq(
            uint8(loanAfterSecondPayment.status),
            uint8(Status.Repaying),
            "Loan should still be active after second partial payment"
        );

        // Make final payment to close the loan
        (uint256 finalRemainingPrincipal, uint256 finalInterest) = bullaFrendLend.getTotalAmountDue(claimId);
        uint256 finalPaymentAmount = finalRemainingPrincipal + finalInterest;

        vm.prank(debtor);
        bullaFrendLend.payLoan(claimId, finalPaymentAmount);

        // Check that loan is now paid
        Loan memory finalLoan = bullaFrendLend.getLoan(claimId);
        assertEq(uint8(finalLoan.status), uint8(Status.Paid), "Loan should be paid after final payment");
        assertEq(finalLoan.paidAmount, finalLoan.claimAmount, "Paid amount should equal claim amount");
    }

    function testInterestAPRCalculation() public {
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 2 ether);

        vm.prank(creditor);
        weth.approve(address(bullaClaim), 2 ether);

        vm.prank(debtor);
        weth.approve(address(bullaClaim), 2 ether);

        // Set up a loan with 10% interest (1000 BPS)
        LoanOffer memory offer = new LoanOfferBuilder().withTermLength(10 * 365 days).withCreditor(creditor).withDebtor(
            debtor
        ).withToken(address(weth)).withInterestRateBps(720).withNumberOfPeriodsPerYear(1) // 1 year term (different from default 30 days)
            .build();

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan{value: FEE}(offer);

        bullaClaim.permitCreateClaim({
            user: debtor,
            controller: address(bullaFrendLend),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaFrendLend),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: true
            })
        });

        uint256 acceptTime = block.timestamp;
        vm.prank(debtor);
        uint256 claimId = bullaFrendLend.acceptLoan(loanId);

        bullaClaim.permitPayClaim({
            user: debtor,
            controller: address(bullaFrendLend),
            approvalType: PayClaimApprovalType.IsApprovedForAll,
            approvalDeadline: 0,
            paymentApprovals: new ClaimPaymentApprovalParam[](0),
            signature: sigHelper.signPayClaimPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaFrendLend),
                approvalType: PayClaimApprovalType.IsApprovedForAll,
                approvalDeadline: 0,
                paymentApprovals: new ClaimPaymentApprovalParam[](0)
            })
        });

        // Check interest after exactly 1/4 year
        vm.warp(acceptTime + 10 * 365 days);
        (, uint256 interest1) = bullaFrendLend.getTotalAmountDue(claimId);

        // After 1/4 year, we should have approximately 2.5% interest (10% / 4)
        // 1 ether * 0.025 = 0.025 ether
        uint256 expectedInterest1 = 1 ether;
        assertApproxEqRel(interest1, expectedInterest1, 0.005e18, "Interest after 1/4 year should be ~0.025 ether");

        // Check interest after exactly 1/2 year (182.5 days)
        vm.warp(acceptTime + 20 * 365 days);
        (, uint256 interest2) = bullaFrendLend.getTotalAmountDue(claimId);

        // After 1/2 year, we should have approximately 5% interest (10% / 2)
        // 1 ether * 0.05 = 0.05 ether
        uint256 expectedInterest2 = 3 ether;
        assertApproxEqRel(interest2, expectedInterest2, 0.006e18, "Interest after 1/2 year should be ~0.05 ether");
    }

    function testPayLoanWithExcessiveAmount() public {
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 2 ether);

        vm.prank(debtor);
        weth.approve(address(bullaFrendLend), 5 ether);

        LoanOffer memory offer =
            new LoanOfferBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth)).build();

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan{value: FEE}(offer);

        bullaClaim.permitCreateClaim({
            user: debtor,
            controller: address(bullaFrendLend),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaFrendLend),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: true
            })
        });

        vm.prank(debtor);
        uint256 claimId = bullaFrendLend.acceptLoan(loanId);

        bullaClaim.permitPayClaim({
            user: debtor,
            controller: address(bullaFrendLend),
            approvalType: PayClaimApprovalType.IsApprovedForAll,
            approvalDeadline: 0,
            paymentApprovals: new ClaimPaymentApprovalParam[](0),
            signature: sigHelper.signPayClaimPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaFrendLend),
                approvalType: PayClaimApprovalType.IsApprovedForAll,
                approvalDeadline: 0,
                paymentApprovals: new ClaimPaymentApprovalParam[](0)
            })
        });

        vm.warp(block.timestamp + 15 days);

        vm.prank(debtor);
        weth.deposit{value: 3 ether}();

        // Payment amount greater than loan + interest
        uint256 excessiveAmount = 3 ether;

        uint256 initialDebtorBalance = weth.balanceOf(debtor);

        vm.prank(debtor);
        bullaFrendLend.payLoan(claimId, excessiveAmount);

        Loan memory loan = bullaFrendLend.getLoan(claimId);
        assertTrue(loan.status == Status.Paid, "Loan should be fully paid");
        assertEq(loan.paidAmount, loan.claimAmount, "Paid amount should equal loan amount");

        uint256 debtorPaid = initialDebtorBalance - weth.balanceOf(debtor);
        assertGt(excessiveAmount, debtorPaid, "Excess payment should have been refunded");
    }

    function testPayNonExistentLoan() public {
        // Create a fake claim ID that doesn't exist
        uint256 nonExistentClaimId = 999;

        // Attempt to pay a non-existent loan
        vm.prank(debtor);
        vm.expectRevert(abi.encodeWithSelector(BullaClaim.NotMinted.selector));
        bullaFrendLend.payLoan(nonExistentClaimId, 1 ether);
    }

    function testLoanMetadataOnClaim() public {
        vm.startPrank(creditor);
        weth.approve(address(bullaFrendLend), 2 ether);
        weth.approve(address(bullaClaim), 2 ether);
        vm.stopPrank();

        // Create a loan offer with metadata
        LoanOffer memory offer =
            new LoanOfferBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth)).build();

        ClaimMetadata memory metadata =
            ClaimMetadata({tokenURI: "ipfs://QmTestTokenURI", attachmentURI: "ipfs://QmTestAttachmentURI"});

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoanWithMetadata{value: FEE}(offer, metadata);

        bullaClaim.permitCreateClaim({
            user: debtor,
            controller: address(bullaFrendLend),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaFrendLend),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: true
            })
        });

        vm.prank(debtor);
        uint256 claimId = bullaFrendLend.acceptLoan(loanId);

        // Get the claim metadata directly from BullaClaim contract
        (string memory tokenURI, string memory attachmentURI) = bullaClaim.claimMetadata(claimId);

        // Verify the metadata was correctly stored on the claim
        assertEq(tokenURI, "ipfs://QmTestTokenURI", "Token URI not correctly stored on claim");
        assertEq(attachmentURI, "ipfs://QmTestAttachmentURI", "Attachment URI not correctly stored on claim");
    }

    function testSetProtocolFee() public {
        uint256 newProtocolFeeBPS = 2000; // 20%

        // Test that non-admin cannot set protocol fee
        vm.prank(debtor);
        vm.expectRevert(abi.encodeWithSelector(NotAdmin.selector));
        bullaFrendLend.setProtocolFee(newProtocolFeeBPS);

        vm.prank(admin);
        bullaFrendLend.setProtocolFee(newProtocolFeeBPS);

        assertEq(bullaFrendLend.protocolFeeBPS(), newProtocolFeeBPS, "Protocol fee not updated correctly");
    }

    // helper function to check if token is in protocol fee tokens
    function isTokenInProtocolFeeTokens(address token) internal view returns (bool) {
        // we've defined at most 3 tokens in our test
        for (uint256 i = 0; i < 3; i++) {
            try bullaFrendLend.protocolFeeTokens(i) returns (address tokenAddr) {
                if (tokenAddr == token) {
                    return true;
                }
            } catch {
                break;
            }
        }
        return false;
    }

    function testProtocolFeeWithMultipleTokens() public {
        vm.startPrank(creditor);
        weth.approve(address(bullaFrendLend), 10 ether);
        usdc.approve(address(bullaFrendLend), 10_000 * 10 ** 6);
        dai.approve(address(bullaFrendLend), 10_000 ether);
        vm.stopPrank();

        vm.startPrank(debtor);
        weth.approve(address(bullaFrendLend), 10 ether);
        usdc.approve(address(bullaFrendLend), 10_000 * 10 ** 6);
        dai.approve(address(bullaFrendLend), 10_000 ether);
        vm.stopPrank();

        bullaClaim.permitCreateClaim({
            user: debtor,
            controller: address(bullaFrendLend),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 3,
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaFrendLend),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 3,
                isBindingAllowed: true
            })
        });

        bullaClaim.permitPayClaim({
            user: debtor,
            controller: address(bullaFrendLend),
            approvalType: PayClaimApprovalType.IsApprovedForAll,
            approvalDeadline: 0,
            paymentApprovals: new ClaimPaymentApprovalParam[](0),
            signature: sigHelper.signPayClaimPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaFrendLend),
                approvalType: PayClaimApprovalType.IsApprovedForAll,
                approvalDeadline: 0,
                paymentApprovals: new ClaimPaymentApprovalParam[](0)
            })
        });

        LoanOffer memory wethOffer = new LoanOfferBuilder().withCreditor(creditor).withDebtor(debtor).withDescription(
            "WETH Loan"
        ).withToken(address(weth)).withNumberOfPeriodsPerYear(365).build();

        vm.prank(creditor);
        uint256 wethLoanId = bullaFrendLend.offerLoan{value: FEE}(wethOffer);

        vm.prank(debtor);
        uint256 wethClaimId = bullaFrendLend.acceptLoan(wethLoanId);

        LoanOffer memory usdcOffer = new LoanOfferBuilder().withCreditor(creditor).withDebtor(debtor).withDescription(
            "USDC Loan"
        ).withToken(address(usdc)).withLoanAmount(1000 * 10 ** 6).withNumberOfPeriodsPerYear(365).build();

        vm.prank(creditor);
        uint256 usdcLoanId = bullaFrendLend.offerLoan{value: FEE}(usdcOffer);

        vm.prank(debtor);
        uint256 usdcClaimId = bullaFrendLend.acceptLoan(usdcLoanId);

        LoanOffer memory daiOffer = new LoanOfferBuilder().withCreditor(creditor).withDebtor(debtor).withDescription(
            "DAI Loan"
        ).withToken(address(dai)).withLoanAmount(1000 ether).withNumberOfPeriodsPerYear(365).build();

        vm.prank(creditor);
        uint256 daiLoanId = bullaFrendLend.offerLoan{value: FEE}(daiOffer);

        vm.prank(debtor);
        uint256 daiClaimId = bullaFrendLend.acceptLoan(daiLoanId);

        vm.warp(block.timestamp + 15 days);

        vm.startPrank(debtor);
        uint256 wethBalanceBefore = weth.balanceOf(address(bullaFrendLend));
        (uint256 wethPrincipal, uint256 wethInterest) = bullaFrendLend.getTotalAmountDue(wethClaimId);
        bullaFrendLend.payLoan(wethClaimId, wethPrincipal + wethInterest);
        uint256 wethProtocolFee = weth.balanceOf(address(bullaFrendLend)) - wethBalanceBefore;

        uint256 usdcBalanceBefore = usdc.balanceOf(address(bullaFrendLend));
        (uint256 usdcPrincipal, uint256 usdcInterest) = bullaFrendLend.getTotalAmountDue(usdcClaimId);
        bullaFrendLend.payLoan(usdcClaimId, usdcPrincipal + usdcInterest);
        uint256 usdcProtocolFee = usdc.balanceOf(address(bullaFrendLend)) - usdcBalanceBefore;

        uint256 daiBalanceBefore = dai.balanceOf(address(bullaFrendLend));
        (uint256 daiPrincipal, uint256 daiInterest) = bullaFrendLend.getTotalAmountDue(daiClaimId);
        bullaFrendLend.payLoan(daiClaimId, daiPrincipal + daiInterest);
        uint256 daiProtocolFee = dai.balanceOf(address(bullaFrendLend)) - daiBalanceBefore;
        vm.stopPrank();

        assertEq(weth.balanceOf(address(bullaFrendLend)), wethProtocolFee, "WETH protocol fee not correct");
        assertEq(usdc.balanceOf(address(bullaFrendLend)), usdcProtocolFee, "USDC protocol fee not correct");
        assertEq(dai.balanceOf(address(bullaFrendLend)), daiProtocolFee, "DAI protocol fee not correct");

        assertEq(bullaFrendLend.protocolFeesByToken(address(weth)), wethProtocolFee, "WETH fee tracking incorrect");
        assertEq(bullaFrendLend.protocolFeesByToken(address(usdc)), usdcProtocolFee, "USDC fee tracking incorrect");
        assertEq(bullaFrendLend.protocolFeesByToken(address(dai)), daiProtocolFee, "DAI fee tracking incorrect");

        assertTrue(isTokenInProtocolFeeTokens(address(weth)), "WETH not found in protocol fee tokens array");
        assertTrue(isTokenInProtocolFeeTokens(address(usdc)), "USDC not found in protocol fee tokens array");
        assertTrue(isTokenInProtocolFeeTokens(address(dai)), "DAI not found in protocol fee tokens array");
    }

    function testWithdrawAllFees() public {
        testProtocolFeeWithMultipleTokens();

        uint256 initialAdminEthBalance = admin.balance;
        uint256 initialAdminWethBalance = weth.balanceOf(admin);
        uint256 initialAdminUsdcBalance = usdc.balanceOf(admin);
        uint256 initialAdminDaiBalance = dai.balanceOf(admin);

        uint256 contractEthBalance = address(bullaFrendLend).balance;
        uint256 wethFee = bullaFrendLend.protocolFeesByToken(address(weth));
        uint256 usdcFee = bullaFrendLend.protocolFeesByToken(address(usdc));
        uint256 daiFee = bullaFrendLend.protocolFeesByToken(address(dai));

        // Admin withdraws fees
        vm.prank(admin);
        bullaFrendLend.withdrawAllFees();

        // Verify native token fees were transferred
        assertEq(admin.balance, initialAdminEthBalance + contractEthBalance, "ETH fees not transferred correctly");
        assertEq(address(bullaFrendLend).balance, 0, "Contract ETH balance should be 0 after withdrawal");

        // Verify ERC20 token fees were transferred
        assertEq(weth.balanceOf(admin), initialAdminWethBalance + wethFee, "WETH fees not transferred correctly");
        assertEq(usdc.balanceOf(admin), initialAdminUsdcBalance + usdcFee, "USDC fees not transferred correctly");
        assertEq(dai.balanceOf(admin), initialAdminDaiBalance + daiFee, "DAI fees not transferred correctly");

        // Verify fee tracking was reset
        assertEq(bullaFrendLend.protocolFeesByToken(address(weth)), 0, "WETH fee not reset after withdrawal");
        assertEq(bullaFrendLend.protocolFeesByToken(address(usdc)), 0, "USDC fee not reset after withdrawal");
        assertEq(bullaFrendLend.protocolFeesByToken(address(dai)), 0, "DAI fee not reset after withdrawal");

        // Verify token balances in contract are 0
        assertEq(weth.balanceOf(address(bullaFrendLend)), 0, "Contract WETH balance should be 0 after withdrawal");
        assertEq(usdc.balanceOf(address(bullaFrendLend)), 0, "Contract USDC balance should be 0 after withdrawal");
        assertEq(dai.balanceOf(address(bullaFrendLend)), 0, "Contract DAI balance should be 0 after withdrawal");
    }

    function testWithdrawEmptyFees() public {
        uint256 initialAdminEthBalance = admin.balance;

        vm.prank(admin);
        bullaFrendLend.withdrawAllFees();

        assertEq(admin.balance, initialAdminEthBalance, "Admin ETH balance should not change when no fees exist");
    }

    function testTokenTrackingUniqueness() public {
        vm.startPrank(creditor);
        weth.approve(address(bullaFrendLend), 10 ether);
        vm.stopPrank();

        vm.startPrank(debtor);
        weth.approve(address(bullaFrendLend), 10 ether);
        vm.stopPrank();

        bullaClaim.permitCreateClaim({
            user: debtor,
            controller: address(bullaFrendLend),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 2,
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaFrendLend),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 2,
                isBindingAllowed: true
            })
        });

        bullaClaim.permitPayClaim({
            user: debtor,
            controller: address(bullaFrendLend),
            approvalType: PayClaimApprovalType.IsApprovedForAll,
            approvalDeadline: 0,
            paymentApprovals: new ClaimPaymentApprovalParam[](0),
            signature: sigHelper.signPayClaimPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaFrendLend),
                approvalType: PayClaimApprovalType.IsApprovedForAll,
                approvalDeadline: 0,
                paymentApprovals: new ClaimPaymentApprovalParam[](0)
            })
        });

        // Create first WETH loan
        LoanOffer memory wethOffer1 = new LoanOfferBuilder().withCreditor(creditor).withDebtor(debtor).withDescription(
            "WETH Loan 1"
        ).withToken(address(weth)).withLoanAmount(1 ether).withNumberOfPeriodsPerYear(365).build();

        vm.prank(creditor);
        uint256 wethLoanId1 = bullaFrendLend.offerLoan{value: FEE}(wethOffer1);

        vm.prank(debtor);
        uint256 wethClaimId1 = bullaFrendLend.acceptLoan(wethLoanId1);

        // Create second WETH loan
        LoanOffer memory wethOffer2 = new LoanOfferBuilder().withCreditor(creditor).withDebtor(debtor).withDescription(
            "WETH Loan 2"
        ).withToken(address(weth)).withLoanAmount(0.5 ether).withNumberOfPeriodsPerYear(365).build();

        vm.prank(creditor);
        uint256 wethLoanId2 = bullaFrendLend.offerLoan{value: FEE}(wethOffer2);

        vm.prank(debtor);
        uint256 wethClaimId2 = bullaFrendLend.acceptLoan(wethLoanId2);

        vm.warp(block.timestamp + 15 days);

        // Make payments on both loans
        vm.startPrank(debtor);

        uint256 initialContractBalance = weth.balanceOf(address(bullaFrendLend));
        (uint256 principal1, uint256 interest1) = bullaFrendLend.getTotalAmountDue(wethClaimId1);
        bullaFrendLend.payLoan(wethClaimId1, principal1 + interest1);
        uint256 fee1 = weth.balanceOf(address(bullaFrendLend)) - initialContractBalance;

        uint256 contractBalanceAfterFirst = weth.balanceOf(address(bullaFrendLend));
        (uint256 principal2, uint256 interest2) = bullaFrendLend.getTotalAmountDue(wethClaimId2);
        bullaFrendLend.payLoan(wethClaimId2, principal2 + interest2);
        uint256 fee2 = weth.balanceOf(address(bullaFrendLend)) - contractBalanceAfterFirst;
        vm.stopPrank();

        // Count WETH tokens in the array
        uint256 wethTokenCount = 0;
        for (uint256 i = 0; i < 3; i++) {
            try bullaFrendLend.protocolFeeTokens(i) returns (address token) {
                if (token == address(weth)) {
                    wethTokenCount++;
                }
            } catch {
                break;
            }
        }

        assertEq(wethTokenCount, 1, "WETH should only appear once in protocol fee tokens array");
        assertEq(
            bullaFrendLend.protocolFeesByToken(address(weth)), fee1 + fee2, "WETH fees should accumulate correctly"
        );
    }

    function testProtocolFeeVariations() public {
        vm.startPrank(creditor);
        weth.approve(address(bullaFrendLend), 10 ether);
        vm.stopPrank();

        vm.startPrank(debtor);
        weth.approve(address(bullaFrendLend), 10 ether);
        vm.stopPrank();

        bullaClaim.permitCreateClaim({
            user: debtor,
            controller: address(bullaFrendLend),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 3,
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaFrendLend),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 3,
                isBindingAllowed: true
            })
        });

        bullaClaim.permitPayClaim({
            user: debtor,
            controller: address(bullaFrendLend),
            approvalType: PayClaimApprovalType.IsApprovedForAll,
            approvalDeadline: 0,
            paymentApprovals: new ClaimPaymentApprovalParam[](0),
            signature: sigHelper.signPayClaimPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaFrendLend),
                approvalType: PayClaimApprovalType.IsApprovedForAll,
                approvalDeadline: 0,
                paymentApprovals: new ClaimPaymentApprovalParam[](0)
            })
        });

        // Protocol Fee = 0%
        vm.startPrank(admin);
        bullaFrendLend.setProtocolFee(0);
        vm.stopPrank();

        LoanOffer memory offer = new LoanOfferBuilder().withCreditor(creditor).withDebtor(debtor).withToken(
            address(weth)
        ).withInterestRateBps(1000).build();

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan{value: FEE}(offer);

        vm.prank(debtor);
        uint256 claimId = bullaFrendLend.acceptLoan(loanId);

        vm.warp(block.timestamp + 15 days);

        (uint256 remainingPrincipal, uint256 interestAmount) = bullaFrendLend.getTotalAmountDue(claimId);
        uint256 totalAmountDue = remainingPrincipal + interestAmount;

        uint256 initialCreditorBalance = weth.balanceOf(creditor);
        uint256 initialContractBalance = weth.balanceOf(address(bullaFrendLend));

        vm.prank(debtor);
        bullaFrendLend.payLoan(claimId, totalAmountDue);

        uint256 finalCreditorBalance = weth.balanceOf(creditor);
        uint256 finalContractBalance = weth.balanceOf(address(bullaFrendLend));

        assertEq(
            finalCreditorBalance - initialCreditorBalance,
            totalAmountDue,
            "Creditor should receive full amount with 0% protocol fee"
        );
        assertEq(
            finalContractBalance,
            initialContractBalance,
            "Contract balance should remain unchanged with 0% protocol fee"
        );
        assertEq(finalContractBalance, 0, "Contract should have 0 balance with 0% protocol fee");

        // Protocol Fee = 50%
        vm.startPrank(admin);
        bullaFrendLend.setProtocolFee(5000); // 50%
        vm.stopPrank();

        offer = new LoanOfferBuilder().withCreditor(creditor).withDebtor(debtor).withDescription(
            "50% Protocol Fee Test Loan"
        ).withToken(address(weth)).withInterestRateBps(1000).build();

        vm.prank(creditor);
        loanId = bullaFrendLend.offerLoan{value: FEE}(offer);

        vm.prank(debtor);
        claimId = bullaFrendLend.acceptLoan(loanId);

        vm.warp(block.timestamp + 15 days);

        (remainingPrincipal, interestAmount) = bullaFrendLend.getTotalAmountDue(claimId);
        totalAmountDue = remainingPrincipal + interestAmount;

        initialCreditorBalance = weth.balanceOf(creditor);
        initialContractBalance = weth.balanceOf(address(bullaFrendLend));

        vm.prank(debtor);
        bullaFrendLend.payLoan(claimId, totalAmountDue);

        finalCreditorBalance = weth.balanceOf(creditor);
        finalContractBalance = weth.balanceOf(address(bullaFrendLend));

        uint256 expectedProtocolFee = interestAmount / 2;
        assertEq(
            finalCreditorBalance - initialCreditorBalance,
            remainingPrincipal + (interestAmount - expectedProtocolFee),
            "Creditor should receive principal + 50% of interest"
        );
        assertEq(
            finalContractBalance - initialContractBalance,
            expectedProtocolFee,
            "Contract should receive 50% of interest"
        );

        // Protocol Fee = 100%
        vm.startPrank(admin);
        bullaFrendLend.setProtocolFee(10000); // 100%
        vm.stopPrank();
        // Verify protocol fee handling
        uint256 protocolFee = interestAmount * bullaFrendLend.protocolFeeBPS() / 10000; // MAX_BPS = 10000
        uint256 expectedCreditorAmount = remainingPrincipal + (interestAmount - protocolFee);

        assertEq(
            finalCreditorBalance - initialCreditorBalance,
            expectedCreditorAmount,
            "Creditor should receive principal + net interest"
        );
        assertEq(finalContractBalance - initialContractBalance, protocolFee, "Contract should receive protocol fee");
    }

    /*///////////////////////////////////////////////////////////////
                        IMPAIR LOAN TESTS
    //////////////////////////////////////////////////////////////*/

    function testImpairLoan_Success() public {
        // Setup approvals
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 2 ether);

        bullaClaim.permitCreateClaim({
            user: debtor,
            controller: address(bullaFrendLend),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaFrendLend),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: true
            })
        });

        bullaClaim.permitCancelClaim({
            user: creditor,
            controller: address(bullaFrendLend),
            approvalCount: 1,
            signature: sigHelper.signCancelClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaFrendLend),
                approvalCount: 1
            })
        });

        bullaClaim.permitImpairClaim({
            user: creditor,
            controller: address(bullaFrendLend),
            approvalCount: 1,
            signature: sigHelper.signImpairClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaFrendLend),
                approvalCount: 1
            })
        });

        LoanOffer memory offer = new LoanOfferBuilder().withCreditor(creditor).withDebtor(debtor).withToken(
            address(weth)
        ).withTermLength(30 days).build();

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan{value: FEE}(offer);

        vm.prank(debtor);
        uint256 claimId = bullaFrendLend.acceptLoan(loanId);

        // Verify loan is active
        Claim memory claimBefore = bullaClaim.getClaim(claimId);
        assertEq(uint256(claimBefore.status), uint256(Status.Pending), "Loan should be pending");

        // Move past the due date
        vm.warp(block.timestamp + 38 days);

        // Impair the loan
        vm.prank(creditor);
        bullaFrendLend.impairLoan(claimId);

        // Verify loan is impaired
        Claim memory claimAfter = bullaClaim.getClaim(claimId);
        assertEq(uint256(claimAfter.status), uint256(Status.Impaired), "Loan should be impaired");
    }

    function testImpairLoan_WithPartialPayment() public {
        // Setup approvals
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 2 ether);

        vm.prank(debtor);
        weth.approve(address(bullaFrendLend), 2 ether);

        bullaClaim.permitCreateClaim({
            user: debtor,
            controller: address(bullaFrendLend),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaFrendLend),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: true
            })
        });

        bullaClaim.permitPayClaim({
            user: debtor,
            controller: address(bullaFrendLend),
            approvalType: PayClaimApprovalType.IsApprovedForAll,
            approvalDeadline: 0,
            paymentApprovals: new ClaimPaymentApprovalParam[](0),
            signature: sigHelper.signPayClaimPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaFrendLend),
                approvalType: PayClaimApprovalType.IsApprovedForAll,
                approvalDeadline: 0,
                paymentApprovals: new ClaimPaymentApprovalParam[](0)
            })
        });

        bullaClaim.permitCancelClaim({
            user: creditor,
            controller: address(bullaFrendLend),
            approvalCount: 1,
            signature: sigHelper.signCancelClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaFrendLend),
                approvalCount: 1
            })
        });

        bullaClaim.permitImpairClaim({
            user: creditor,
            controller: address(bullaFrendLend),
            approvalCount: 1,
            signature: sigHelper.signImpairClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaFrendLend),
                approvalCount: 1
            })
        });

        LoanOffer memory offer = new LoanOfferBuilder().withCreditor(creditor).withDebtor(debtor).withToken(
            address(weth)
        ).withInterestRateBps(1000).build();

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan{value: FEE}(offer);

        vm.prank(debtor);
        uint256 claimId = bullaFrendLend.acceptLoan(loanId);

        // Make partial payment
        vm.warp(block.timestamp + 10 days);

        vm.prank(debtor);
        bullaFrendLend.payLoan(claimId, 0.5 ether);

        Claim memory claimAfterPayment = bullaClaim.getClaim(claimId);
        assertEq(uint256(claimAfterPayment.status), uint256(Status.Repaying), "Loan should be repaying");
        assertEq(claimAfterPayment.paidAmount, 0.5 ether, "Partial payment should be recorded");

        vm.warp(block.timestamp + 28 days);

        // Impair the loan
        vm.prank(creditor);
        bullaFrendLend.impairLoan(claimId);

        // Verify loan is impaired but payment amount is preserved
        Claim memory claimAfterImpairment = bullaClaim.getClaim(claimId);
        assertEq(uint256(claimAfterImpairment.status), uint256(Status.Impaired), "Loan should be impaired");
        assertEq(claimAfterImpairment.paidAmount, 0.5 ether, "Payment amount should be preserved");
    }

    function testCannotImpairLoan_NotCreditor() public {
        // Setup approvals
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 2 ether);

        bullaClaim.permitCreateClaim({
            user: debtor,
            controller: address(bullaFrendLend),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaFrendLend),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: true
            })
        });

        LoanOffer memory offer =
            new LoanOfferBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth)).build();

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan{value: FEE}(offer);

        vm.prank(debtor);
        uint256 claimId = bullaFrendLend.acceptLoan(loanId);

        _permitImpairClaim(debtorPK, address(bullaFrendLend), 1);
        _permitImpairClaim(adminPK, address(bullaFrendLend), 1);

        // Debtor cannot impair loan
        vm.prank(debtor);
        vm.expectRevert(abi.encodeWithSelector(BullaClaimValidationLib.NotCreditor.selector));
        bullaFrendLend.impairLoan(claimId);

        // Random user cannot impair loan
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(BullaClaimValidationLib.NotCreditor.selector));
        bullaFrendLend.impairLoan(claimId);
    }

    function testCannotImpairLoan_WrongController() public {
        // Create a claim directly via BullaClaim (not through BullaFrendLend)
        CreateClaimParams memory params = new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withClaimAmount(1 ether).withToken(address(weth)).build();

        vm.prank(creditor);
        uint256 claimId = bullaClaim.createClaim(params);

        _permitImpairClaim(creditorPK, address(bullaFrendLend), 1);

        // Try to impair via BullaFrendLend - should fail since it's not the controller
        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(BullaClaim.NotController.selector, address(creditor)));
        bullaFrendLend.impairLoan(claimId);
    }

    function testImpairLoan_InterestAccrual() public {
        // Setup approvals
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 2 ether);

        bullaClaim.permitCreateClaim({
            user: debtor,
            controller: address(bullaFrendLend),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaFrendLend),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: true
            })
        });

        bullaClaim.permitCancelClaim({
            user: creditor,
            controller: address(bullaFrendLend),
            approvalCount: 1,
            signature: sigHelper.signCancelClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaFrendLend),
                approvalCount: 1
            })
        });

        bullaClaim.permitImpairClaim({
            user: creditor,
            controller: address(bullaFrendLend),
            approvalCount: 1,
            signature: sigHelper.signImpairClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaFrendLend),
                approvalCount: 1
            })
        });

        LoanOffer memory offer = new LoanOfferBuilder().withCreditor(creditor).withDebtor(debtor).withToken(
            address(weth)
        ).withInterestRateBps(1000).withNumberOfPeriodsPerYear(365) // 10% annual interest
            .build();

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan{value: FEE}(offer);

        vm.prank(debtor);
        uint256 claimId = bullaFrendLend.acceptLoan(loanId);

        // Wait some time for interest to accrue
        vm.warp(block.timestamp + 38 days);

        (uint256 principalBefore, uint256 interestBefore) = bullaFrendLend.getTotalAmountDue(claimId);

        // Impair the loan
        vm.prank(creditor);
        bullaFrendLend.impairLoan(claimId);

        // Interest should continue to accrue on impaired loans
        vm.warp(block.timestamp + 30 days);

        (uint256 principalAfter, uint256 interestAfter) = bullaFrendLend.getTotalAmountDue(claimId);

        assertEq(principalBefore, principalAfter, "Principal should remain the same");
        assertGt(interestAfter, interestBefore, "Interest should continue to accrue on impaired loans");
    }

    function testPayImpairedLoan_Success() public {
        // Setup approvals
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 2 ether);

        vm.prank(debtor);
        weth.approve(address(bullaFrendLend), 2 ether);

        bullaClaim.permitCreateClaim({
            user: debtor,
            controller: address(bullaFrendLend),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaFrendLend),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: true
            })
        });

        bullaClaim.permitPayClaim({
            user: debtor,
            controller: address(bullaFrendLend),
            approvalType: PayClaimApprovalType.IsApprovedForAll,
            approvalDeadline: 0,
            paymentApprovals: new ClaimPaymentApprovalParam[](0),
            signature: sigHelper.signPayClaimPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaFrendLend),
                approvalType: PayClaimApprovalType.IsApprovedForAll,
                approvalDeadline: 0,
                paymentApprovals: new ClaimPaymentApprovalParam[](0)
            })
        });

        bullaClaim.permitCancelClaim({
            user: creditor,
            controller: address(bullaFrendLend),
            approvalCount: 1,
            signature: sigHelper.signCancelClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaFrendLend),
                approvalCount: 1
            })
        });

        bullaClaim.permitImpairClaim({
            user: creditor,
            controller: address(bullaFrendLend),
            approvalCount: 1,
            signature: sigHelper.signImpairClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaFrendLend),
                approvalCount: 1
            })
        });

        LoanOffer memory offer = new LoanOfferBuilder().withCreditor(creditor).withDebtor(debtor).withToken(
            address(weth)
        ).withInterestRateBps(1000).build();

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan{value: FEE}(offer);

        vm.prank(debtor);
        uint256 claimId = bullaFrendLend.acceptLoan(loanId);

        vm.warp(block.timestamp + 38 days);

        // Impair the loan
        vm.prank(creditor);
        bullaFrendLend.impairLoan(claimId);

        // Wait for interest to accrue
        vm.warp(block.timestamp + 15 days);

        // Should still be able to pay impaired loan
        (uint256 principal, uint256 interest) = bullaFrendLend.getTotalAmountDue(claimId);
        uint256 totalAmount = principal + interest;

        uint256 creditorBalanceBefore = weth.balanceOf(creditor);
        uint256 contractBalanceBefore = weth.balanceOf(address(bullaFrendLend));

        vm.prank(debtor);
        bullaFrendLend.payLoan(claimId, totalAmount);

        // Verify payment was processed correctly
        Claim memory claimAfter = bullaClaim.getClaim(claimId);
        assertEq(uint256(claimAfter.status), uint256(Status.Paid), "Loan should be paid");

        // Verify protocol fee handling
        uint256 protocolFee = interest * bullaFrendLend.protocolFeeBPS() / 10000; // MAX_BPS = 10000
        uint256 expectedCreditorAmount = principal + (interest - protocolFee);

        assertEq(
            weth.balanceOf(creditor) - creditorBalanceBefore,
            expectedCreditorAmount,
            "Creditor should receive principal + net interest"
        );
        assertEq(
            weth.balanceOf(address(bullaFrendLend)) - contractBalanceBefore,
            protocolFee,
            "Contract should receive protocol fee"
        );
    }

    function testImpairLoan_StatusTransitions() public {
        // Setup approvals
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 2 ether);

        bullaClaim.permitCreateClaim({
            user: debtor,
            controller: address(bullaFrendLend),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 2, // Multiple claims
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaFrendLend),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 2,
                isBindingAllowed: true
            })
        });

        bullaClaim.permitCancelClaim({
            user: creditor,
            controller: address(bullaFrendLend),
            approvalCount: 2,
            signature: sigHelper.signCancelClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaFrendLend),
                approvalCount: 2
            })
        });

        bullaClaim.permitImpairClaim({
            user: creditor,
            controller: address(bullaFrendLend),
            approvalCount: 2,
            signature: sigHelper.signImpairClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaFrendLend),
                approvalCount: 2
            })
        });

        // Create first loan
        LoanOffer memory offer1 = new LoanOfferBuilder().withCreditor(creditor).withDebtor(debtor).withToken(
            address(weth)
        ).withDescription("First Loan").build();

        vm.prank(creditor);
        uint256 loanId1 = bullaFrendLend.offerLoan{value: FEE}(offer1);

        vm.prank(debtor);
        uint256 claimId1 = bullaFrendLend.acceptLoan(loanId1);

        // Create second loan
        LoanOffer memory offer2 = new LoanOfferBuilder().withCreditor(creditor).withDebtor(debtor).withToken(
            address(weth)
        ).withDescription("Second Loan").build();

        vm.prank(creditor);
        uint256 loanId2 = bullaFrendLend.offerLoan{value: FEE}(offer2);

        vm.prank(debtor);
        uint256 claimId2 = bullaFrendLend.acceptLoan(loanId2);

        // Verify both loans are pending
        Claim memory claim1 = bullaClaim.getClaim(claimId1);
        Claim memory claim2 = bullaClaim.getClaim(claimId2);
        assertTrue(uint256(claim1.status) == uint256(Status.Pending), "First loan should be pending");
        assertTrue(uint256(claim2.status) == uint256(Status.Pending), "Second loan should be pending");

        vm.warp(block.timestamp + 38 days);

        // Impair first loan
        vm.prank(creditor);
        bullaFrendLend.impairLoan(claimId1);

        // Verify first loan is impaired, second remains pending
        claim1 = bullaClaim.getClaim(claimId1);
        claim2 = bullaClaim.getClaim(claimId2);
        assertEq(uint256(claim1.status), uint256(Status.Impaired), "First loan should be impaired");
        assertEq(uint256(claim2.status), uint256(Status.Pending), "Second loan should remain pending");

        // Try to impair already impaired loan (should fail)
        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(BullaClaimValidationLib.ClaimNotPending.selector));
        bullaFrendLend.impairLoan(claimId1);
    }

    function testImpairLoan_MultipleTokens() public {
        // Setup approvals for multiple tokens
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 2 ether);
        vm.prank(creditor);
        usdc.approve(address(bullaFrendLend), 1000 * 10 ** 6);

        bullaClaim.permitCreateClaim({
            user: debtor,
            controller: address(bullaFrendLend),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 2,
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaFrendLend),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 2,
                isBindingAllowed: true
            })
        });

        bullaClaim.permitCancelClaim({
            user: creditor,
            controller: address(bullaFrendLend),
            approvalCount: 2,
            signature: sigHelper.signCancelClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaFrendLend),
                approvalCount: 2
            })
        });

        bullaClaim.permitImpairClaim({
            user: creditor,
            controller: address(bullaFrendLend),
            approvalCount: 2,
            signature: sigHelper.signImpairClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaFrendLend),
                approvalCount: 2
            })
        });

        // Create WETH loan
        LoanOffer memory wethOffer = new LoanOfferBuilder().withCreditor(creditor).withDebtor(debtor).withToken(
            address(weth)
        ).withDescription("WETH Loan").build();

        vm.prank(creditor);
        uint256 wethLoanId = bullaFrendLend.offerLoan{value: FEE}(wethOffer);

        vm.prank(debtor);
        uint256 wethClaimId = bullaFrendLend.acceptLoan(wethLoanId);

        // Create USDC loan
        LoanOffer memory usdcOffer = new LoanOfferBuilder().withCreditor(creditor).withDebtor(debtor).withToken(
            address(usdc)
        ).withLoanAmount(1000 * 10 ** 6).withDescription("USDC Loan").build();

        vm.prank(creditor);
        uint256 usdcLoanId = bullaFrendLend.offerLoan{value: FEE}(usdcOffer);

        vm.prank(debtor);
        uint256 usdcClaimId = bullaFrendLend.acceptLoan(usdcLoanId);

        vm.warp(block.timestamp + 38 days);

        // Impair both loans
        vm.prank(creditor);
        bullaFrendLend.impairLoan(wethClaimId);

        vm.prank(creditor);
        bullaFrendLend.impairLoan(usdcClaimId);

        // Verify both loans are impaired
        Claim memory wethClaim = bullaClaim.getClaim(wethClaimId);
        Claim memory usdcClaim = bullaClaim.getClaim(usdcClaimId);

        assertEq(uint256(wethClaim.status), uint256(Status.Impaired), "WETH loan should be impaired");
        assertEq(uint256(usdcClaim.status), uint256(Status.Impaired), "USDC loan should be impaired");
        assertEq(wethClaim.token, address(weth), "WETH loan token should be correct");
        assertEq(usdcClaim.token, address(usdc), "USDC loan token should be correct");
    }

    /*///////////////////////////////////////////////////////////////
                    MARK LOAN AS PAID TESTS
    //////////////////////////////////////////////////////////////*/

    function _permitMarkAsPaid(uint256 pk, address controller, uint64 approvalCount) internal {
        bullaClaim.permitMarkAsPaid({
            user: vm.addr(pk),
            controller: controller,
            approvalCount: approvalCount,
            signature: sigHelper.signMarkAsPaidPermit({
                pk: pk,
                user: vm.addr(pk),
                controller: controller,
                approvalCount: approvalCount
            })
        });
    }

    function testMarkLoanAsPaid_Success() public {
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 2 ether);

        bullaClaim.permitCreateClaim({
            user: debtor,
            controller: address(bullaFrendLend),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaFrendLend),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: true
            })
        });

        _permitMarkAsPaid(creditorPK, address(bullaFrendLend), 1);

        LoanOffer memory offer = new LoanOfferBuilder().withCreditor(creditor).withDebtor(debtor).withToken(
            address(weth)
        ).withTermLength(30 days).build();

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan{value: FEE}(offer);

        vm.prank(debtor);
        uint256 claimId = bullaFrendLend.acceptLoan(loanId);

        // Verify loan is active
        Claim memory claimBefore = bullaClaim.getClaim(claimId);
        assertEq(uint256(claimBefore.status), uint256(Status.Pending), "Loan should be pending");

        // Check balances before marking as paid
        uint256 debtorBalanceBefore = weth.balanceOf(debtor);
        uint256 creditorBalanceBefore = weth.balanceOf(creditor);

        // Mark the loan as paid
        vm.prank(creditor);
        bullaFrendLend.markLoanAsPaid(claimId);

        // Verify loan is marked as paid
        Claim memory claimAfter = bullaClaim.getClaim(claimId);
        assertEq(uint256(claimAfter.status), uint256(Status.Paid), "Loan should be marked as paid");

        // Verify that no token transfers occurred
        assertEq(weth.balanceOf(debtor), debtorBalanceBefore, "Debtor balance should remain unchanged");
        assertEq(weth.balanceOf(creditor), creditorBalanceBefore, "Creditor balance should remain unchanged");
    }

    function testMarkLoanAsPaid_WithPartialPayment() public {
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 2 ether);

        vm.prank(debtor);
        weth.approve(address(bullaFrendLend), 2 ether);

        bullaClaim.permitCreateClaim({
            user: debtor,
            controller: address(bullaFrendLend),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaFrendLend),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: true
            })
        });

        bullaClaim.permitPayClaim({
            user: debtor,
            controller: address(bullaFrendLend),
            approvalType: PayClaimApprovalType.IsApprovedForAll,
            approvalDeadline: 0,
            paymentApprovals: new ClaimPaymentApprovalParam[](0),
            signature: sigHelper.signPayClaimPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaFrendLend),
                approvalType: PayClaimApprovalType.IsApprovedForAll,
                approvalDeadline: 0,
                paymentApprovals: new ClaimPaymentApprovalParam[](0)
            })
        });

        _permitMarkAsPaid(creditorPK, address(bullaFrendLend), 1);

        LoanOffer memory offer = new LoanOfferBuilder().withCreditor(creditor).withDebtor(debtor).withToken(
            address(weth)
        ).withInterestRateBps(1000).build();

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan{value: FEE}(offer);

        vm.prank(debtor);
        uint256 claimId = bullaFrendLend.acceptLoan(loanId);

        // Make partial payment
        vm.warp(block.timestamp + 10 days);

        vm.prank(debtor);
        bullaFrendLend.payLoan(claimId, 0.5 ether);

        Claim memory claimAfterPayment = bullaClaim.getClaim(claimId);
        assertEq(uint256(claimAfterPayment.status), uint256(Status.Repaying), "Loan should be repaying");
        assertEq(claimAfterPayment.paidAmount, 0.5 ether, "Partial payment should be recorded");

        // Mark the loan as paid
        vm.prank(creditor);
        bullaFrendLend.markLoanAsPaid(claimId);

        // Verify loan is marked as paid but payment amount is preserved
        Claim memory claimAfterMarkedPaid = bullaClaim.getClaim(claimId);
        assertEq(uint256(claimAfterMarkedPaid.status), uint256(Status.Paid), "Loan should be marked as paid");
        assertEq(claimAfterMarkedPaid.paidAmount, 0.5 ether, "Payment amount should be preserved");
    }

    function testCannotMarkLoanAsPaid_NotCreditor() public {
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 2 ether);

        bullaClaim.permitCreateClaim({
            user: debtor,
            controller: address(bullaFrendLend),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaFrendLend),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: true
            })
        });

        _permitMarkAsPaid(creditorPK, address(bullaFrendLend), 1);
        _permitMarkAsPaid(debtorPK, address(bullaFrendLend), 1);
        _permitMarkAsPaid(adminPK, address(bullaFrendLend), 1);

        LoanOffer memory offer =
            new LoanOfferBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth)).build();

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan{value: FEE}(offer);

        vm.prank(debtor);
        uint256 claimId = bullaFrendLend.acceptLoan(loanId);

        // Debtor cannot mark loan as paid
        vm.prank(debtor);
        vm.expectRevert(abi.encodeWithSelector(BullaClaimValidationLib.NotCreditor.selector));
        bullaFrendLend.markLoanAsPaid(claimId);

        // Random user cannot mark loan as paid
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(BullaClaimValidationLib.NotCreditor.selector));
        bullaFrendLend.markLoanAsPaid(claimId);
    }

    function testCannotMarkLoanAsPaid_WrongController() public {
        // Create a claim directly via BullaClaim (not through BullaFrendLend)
        CreateClaimParams memory params = new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withClaimAmount(1 ether).withToken(address(weth)).build();

        vm.prank(creditor);
        uint256 claimId = bullaClaim.createClaim(params);

        _permitMarkAsPaid(creditorPK, address(bullaFrendLend), 1);

        // Try to mark as paid via BullaFrendLend - should fail since it's not the controller
        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(BullaClaim.NotController.selector, address(creditor)));
        bullaFrendLend.markLoanAsPaid(claimId);
    }

    function testMarkLoanAsPaid_FromImpairedStatus() public {
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 2 ether);

        bullaClaim.permitCreateClaim({
            user: debtor,
            controller: address(bullaFrendLend),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaFrendLend),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: true
            })
        });

        bullaClaim.permitImpairClaim({
            user: creditor,
            controller: address(bullaFrendLend),
            approvalCount: 1,
            signature: sigHelper.signImpairClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaFrendLend),
                approvalCount: 1
            })
        });

        _permitMarkAsPaid(creditorPK, address(bullaFrendLend), 1);

        LoanOffer memory offer = new LoanOfferBuilder().withCreditor(creditor).withDebtor(debtor).withToken(
            address(weth)
        ).withTermLength(30 days).build();

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan{value: FEE}(offer);

        vm.prank(debtor);
        uint256 claimId = bullaFrendLend.acceptLoan(loanId);

        // First impair the loan
        vm.warp(block.timestamp + 38 days);
        vm.prank(creditor);
        bullaFrendLend.impairLoan(claimId);

        Claim memory claimAfterImpairment = bullaClaim.getClaim(claimId);
        assertEq(uint256(claimAfterImpairment.status), uint256(Status.Impaired), "Loan should be impaired");

        // Then mark it as paid
        vm.prank(creditor);
        bullaFrendLend.markLoanAsPaid(claimId);

        // Verify loan is marked as paid
        Claim memory claimAfterMarkedPaid = bullaClaim.getClaim(claimId);
        assertEq(uint256(claimAfterMarkedPaid.status), uint256(Status.Paid), "Loan should be marked as paid");
    }
}
