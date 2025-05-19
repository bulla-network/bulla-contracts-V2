// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.14;

import "forge-std/console.sol";
import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import "contracts/types/Types.sol";
import {WETH} from "contracts/mocks/weth.sol";
import {EIP712Helper, privateKeyValidity} from "test/foundry/BullaClaim/EIP712/Utils.sol";
import {BullaClaim} from "contracts/BullaClaim.sol";
import {BullaFrendLend, LoanOffer, Loan, IncorrectFee, NotCreditor, InvalidTermLength, NativeTokenNotSupported, NotDebtor} from "contracts/BullaFrendLend.sol";
import {Deployer} from "script/Deployment.s.sol";

contract TestBullaFrendLend is Test {
    WETH public weth;
    BullaClaim public bullaClaim;
    EIP712Helper public sigHelper;
    BullaFrendLend public bullaFrendLend;

    uint256 creditorPK = uint256(0x01);
    uint256 debtorPK = uint256(0x02);
    address creditor = vm.addr(creditorPK);
    address debtor = vm.addr(debtorPK);
    address admin = vm.addr(0x03);
    uint256 constant FEE = 0.01 ether;

    function setUp() public {
        weth = new WETH();

        bullaClaim = (new Deployer()).deploy_test({_deployer: address(this), _initialLockState: LockState.Unlocked});
        sigHelper = new EIP712Helper(address(bullaClaim));
        bullaFrendLend = new BullaFrendLend(address(bullaClaim), admin, FEE);

        vm.deal(creditor, 10 ether);
        vm.deal(debtor, 10 ether);
        
        // Setup WETH for tests
        vm.prank(creditor);
        weth.deposit{value: 5 ether}();
        
        vm.prank(debtor);
        weth.deposit{value: 5 ether}();
    }

    function testOfferLoan() public {
        // Approve WETH for transfer
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 2 ether);

        LoanOffer memory offer = LoanOffer({
            interestBPS: 500, // 5% interest
            termLength: 30 days,
            loanAmount: 1 ether,
            creditor: creditor,
            debtor: debtor,
            description: "Test Loan",
            token: address(weth)
        });

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan{value: FEE}(offer);

        (uint24 interestBPS, uint40 termLength, uint128 loanAmount, address offerCreditor, address offerDebtor, string memory description, address token) = bullaFrendLend.loanOffers(loanId);
        
        assertEq(interestBPS, 500, "Interest BPS mismatch");
        assertEq(termLength, 30 days, "Term length mismatch");
        assertEq(loanAmount, 1 ether, "Loan amount mismatch");
        assertEq(offerCreditor, creditor, "Creditor mismatch");
        assertEq(offerDebtor, debtor, "Debtor mismatch");
        assertEq(description, "Test Loan", "Description mismatch");
        assertEq(token, address(weth), "Token address mismatch");
    }

    function testOfferLoanWithIncorrectFee() public {
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 1 ether);

        LoanOffer memory offer = LoanOffer({
            interestBPS: 500,
            termLength: 30 days,
            loanAmount: 1 ether,
            creditor: creditor,
            debtor: debtor,
            description: "Test Loan",
            token: address(weth)
        });

        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(IncorrectFee.selector));
        bullaFrendLend.offerLoan{value: FEE + 0.1 ether}(offer);
    }

    function testOfferLoanWithWrongCreditor() public {
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 1 ether);

        LoanOffer memory offer = LoanOffer({
            interestBPS: 500,
            termLength: 30 days,
            loanAmount: 1 ether,
            creditor: debtor, // Wrong creditor
            debtor: debtor,
            description: "Test Loan",
            token: address(weth)
        });

        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(NotCreditor.selector));
        bullaFrendLend.offerLoan{value: FEE}(offer);
    }

    function testOfferLoanWithZeroTermLength() public {
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 1 ether);

        LoanOffer memory offer = LoanOffer({
            interestBPS: 500,
            termLength: 0, // Invalid term length
            loanAmount: 1 ether,
            creditor: creditor,
            debtor: debtor,
            description: "Test Loan",
            token: address(weth)
        });

        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(InvalidTermLength.selector));
        bullaFrendLend.offerLoan{value: FEE}(offer);
    }

    function testOfferLoanWithNativeToken() public {
        LoanOffer memory offer = LoanOffer({
            interestBPS: 500,
            termLength: 30 days,
            loanAmount: 1 ether,
            creditor: creditor,
            debtor: debtor,
            description: "Test Loan with Native Token",
            token: address(0) // Native token (should be rejected)
        });

        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(NativeTokenNotSupported.selector));
        bullaFrendLend.offerLoan{value: FEE}(offer);
    }

    function testOfferLoanWithZeroInterest() public {
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 1 ether);

        LoanOffer memory offer = LoanOffer({
            interestBPS: 0, // Zero interest
            termLength: 30 days,
            loanAmount: 1 ether,
            creditor: creditor,
            debtor: debtor,
            description: "Test Loan with Zero Interest",
            token: address(weth)
        });

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan{value: FEE}(offer);

        (uint24 interestBPS,,,,,,) = bullaFrendLend.loanOffers(loanId);
        assertEq(interestBPS, 0, "Interest BPS should be zero");
    }

    function testOfferLoanWithMaxInterest() public {
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 1 ether);

        LoanOffer memory offer = LoanOffer({
            interestBPS: 10000, // 100% interest
            termLength: 30 days,
            loanAmount: 1 ether,
            creditor: creditor,
            debtor: debtor,
            description: "Test Loan with Max Interest",
            token: address(weth)
        });

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan{value: FEE}(offer);

        (uint24 interestBPS,,,,,,) = bullaFrendLend.loanOffers(loanId);
        assertEq(interestBPS, 10000, "Interest BPS should be 10000");
    }

    function testEndToEndLoanFlow() public {
        // Approve WETH for transfer from creditor to BullaFrendLend
        vm.prank(creditor);
        weth.approve(address(bullaClaim), 2 ether);

        // Also approve the BullaFrendLend contract directly - this is needed for the token transfer
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 2 ether);
        
        vm.prank(debtor);
        weth.approve(address(bullaClaim), 2 ether);
        
        LoanOffer memory offer = LoanOffer({
            interestBPS: 500, 
            termLength: 30 days,
            loanAmount: 1 ether,
            creditor: creditor,
            debtor: debtor,
            description: "End to End Test Loan with WETH",
            token: address(weth)
        });

        uint256 initialCreditorWeth = weth.balanceOf(creditor);
        uint256 initialDebtorWeth = weth.balanceOf(debtor);

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan{value: FEE}(offer);

        bullaClaim.permitCreateClaim({
            user: debtor,
            operator: address(bullaFrendLend),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: debtorPK,
                user: debtor,
                operator: address(bullaFrendLend),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: true
            })
        });

        vm.prank(debtor);
        uint256 claimId = bullaFrendLend.acceptLoan(loanId);

        assertEq(weth.balanceOf(creditor), initialCreditorWeth - 1 ether, "Creditor WETH balance after loan acceptance incorrect");
        assertEq(weth.balanceOf(debtor), initialDebtorWeth + 1 ether, "Debtor WETH balance after loan acceptance incorrect");
        assertEq(weth.balanceOf(address(bullaFrendLend)), 0, "BullaFrendLend WETH balance should be 0 after transfer");

        bullaClaim.permitPayClaim({
            user: debtor,
            operator: address(bullaFrendLend),
            approvalType: PayClaimApprovalType.IsApprovedForAll,
            approvalDeadline: 0,
            paymentApprovals: new ClaimPaymentApprovalParam[](0),
            signature: sigHelper.signPayClaimPermit({
                pk: debtorPK,
                user: debtor,
                operator: address(bullaFrendLend),
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
        
        vm.prank(debtor);
        weth.approve(address(bullaFrendLend), paymentAmount);
                
        vm.prank(debtor);
        bullaFrendLend.payLoan(claimId, paymentAmount);

        assertEq(weth.balanceOf(creditor), initialCreditorWeth - remainingPrincipal + paymentAmount, "Creditor final WETH balance incorrect");
        assertEq(weth.balanceOf(debtor), initialDebtorWeth + remainingPrincipal - paymentAmount, "Debtor final WETH balance incorrect");

        Loan memory loan = bullaFrendLend.getLoan(claimId);
        assertTrue(loan.status == Status.Paid, "Loan status should be Paid");
        assertEq(loan.paidAmount, remainingPrincipal, "Paid amount should match principal");
        assertEq(loan.claimAmount, remainingPrincipal, "Claim amount should match principal");
    }

    function testRejectLoanOffer() public {
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 2 ether);

        LoanOffer memory offer = LoanOffer({
            interestBPS: 500,
            termLength: 30 days,
            loanAmount: 1 ether,
            creditor: creditor,
            debtor: debtor,
            description: "Test Loan to Reject",
            token: address(weth)
        });

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan{value: FEE}(offer);

        vm.prank(creditor);
        bullaFrendLend.rejectLoanOffer(loanId);

        (uint24 interestBPS, uint40 termLength, uint128 loanAmount, address offerCreditor, ,, ) = bullaFrendLend.loanOffers(loanId);
        assertEq(offerCreditor, address(0), "Offer should be deleted after rejection");
    }

    function testPartialLoanPayments() public {
        vm.startPrank(creditor);
        weth.approve(address(bullaFrendLend), 2 ether);
        weth.approve(address(bullaClaim), 2 ether);
        vm.stopPrank();
        vm.startPrank(debtor);
        weth.approve(address(bullaClaim), 2 ether);
        weth.approve(address(bullaFrendLend), 2 ether);
        vm.stopPrank();
        LoanOffer memory offer = LoanOffer({
            interestBPS: 500,
            termLength: 30 days,
            loanAmount: 1 ether,
            creditor: creditor,
            debtor: debtor,
            description: "Partial Payments Test Loan",
            token: address(weth)
        });

        uint256 initialCreditorWeth = weth.balanceOf(creditor);
        uint256 initialDebtorWeth = weth.balanceOf(debtor);

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan{value: FEE}(offer);

        bullaClaim.permitCreateClaim({
            user: debtor,
            operator: address(bullaFrendLend),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: debtorPK,
                user: debtor,
                operator: address(bullaFrendLend),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: true
            })
        });

        vm.prank(debtor);
        uint256 claimId = bullaFrendLend.acceptLoan(loanId);

        assertEq(weth.balanceOf(creditor), initialCreditorWeth - 1 ether, "Creditor WETH balance after loan acceptance incorrect");
        assertEq(weth.balanceOf(debtor), initialDebtorWeth + 1 ether, "Debtor WETH balance after loan acceptance incorrect");

        bullaClaim.permitPayClaim({
            user: debtor,
            operator: address(bullaFrendLend),
            approvalType: PayClaimApprovalType.IsApprovedForAll,
            approvalDeadline: 0,
            paymentApprovals: new ClaimPaymentApprovalParam[](0),
            signature: sigHelper.signPayClaimPermit({
                pk: debtorPK,
                user: debtor,
                operator: address(bullaFrendLend),
                approvalType: PayClaimApprovalType.IsApprovedForAll,
                approvalDeadline: 0,
                paymentApprovals: new ClaimPaymentApprovalParam[](0)
            })
        });

        // Advance time by 10 days to generate some interest
        vm.warp(block.timestamp + 10 days);
        
        // Make first partial payment
        uint256 firstPaymentAmount = 0.3 ether;
        vm.startPrank(debtor);
        weth.approve(address(bullaFrendLend), firstPaymentAmount);
        bullaFrendLend.payLoan(claimId, firstPaymentAmount);
        vm.stopPrank();
        // Check loan state after first payment
        (uint256 remainingPrincipal1, uint256 currentInterest1) = bullaFrendLend.getTotalAmountDue(claimId);
        Loan memory loanAfterFirstPayment = bullaFrendLend.getLoan(claimId);
        
        assertEq(loanAfterFirstPayment.paidAmount, firstPaymentAmount - currentInterest1, "Paid amount after first payment incorrect");
        assertEq(uint8(loanAfterFirstPayment.status), uint8(Status.Repaying), "Loan should still be active after partial payment");
        
        // Advance time by another 10 days
        vm.warp(block.timestamp + 10 days);
        
        // Make second partial payment
        uint256 secondPaymentAmount = 0.4 ether;
        vm.startPrank(debtor);
        weth.approve(address(bullaFrendLend), secondPaymentAmount);
        bullaFrendLend.payLoan(claimId, secondPaymentAmount);
        vm.stopPrank();
        
        // Check loan state after second payment
        (uint256 remainingPrincipal2, uint256 currentInterest2) = bullaFrendLend.getTotalAmountDue(claimId);
        Loan memory loanAfterSecondPayment = bullaFrendLend.getLoan(claimId);
        
        assertEq(loanAfterSecondPayment.paidAmount, loanAfterFirstPayment.paidAmount + (secondPaymentAmount - currentInterest2), 
            "Paid amount after second payment incorrect");
        assertEq(uint8(loanAfterSecondPayment.status), uint8(Status.Repaying), "Loan should still be active after second partial payment");
        
        // Make final payment to close the loan
        (uint256 finalRemainingPrincipal, uint256 finalInterest) = bullaFrendLend.getTotalAmountDue(claimId);
        uint256 finalPaymentAmount = finalRemainingPrincipal + finalInterest;
        
        vm.startPrank(debtor);
        weth.approve(address(bullaFrendLend), finalPaymentAmount);
        bullaFrendLend.payLoan(claimId, finalPaymentAmount);
        vm.stopPrank();
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
        LoanOffer memory offer = LoanOffer({
            interestBPS: 1000, // 10% interest
            termLength: 365 days, // 1 year term
            loanAmount: 1 ether,
            creditor: creditor,
            debtor: debtor,
            description: "APR Test Loan",
            token: address(weth)
        });

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan{value: FEE}(offer);

        bullaClaim.permitCreateClaim({
            user: debtor,
            operator: address(bullaFrendLend),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: debtorPK,
                user: debtor,
                operator: address(bullaFrendLend),
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
            operator: address(bullaFrendLend),
            approvalType: PayClaimApprovalType.IsApprovedForAll,
            approvalDeadline: 0,
            paymentApprovals: new ClaimPaymentApprovalParam[](0),
            signature: sigHelper.signPayClaimPermit({
                pk: debtorPK,
                user: debtor,
                operator: address(bullaFrendLend),
                approvalType: PayClaimApprovalType.IsApprovedForAll,
                approvalDeadline: 0,
                paymentApprovals: new ClaimPaymentApprovalParam[](0)
            })
        });

        // Check interest after exactly 1/4 year
        vm.warp(acceptTime + 91.25 days);
        uint256 interest1 = bullaFrendLend.calculateCurrentInterest(claimId);
        
        // After 1/4 year, we should have approximately 2.5% interest (10% / 4)
        // 1 ether * 0.025 = 0.025 ether
        uint256 expectedInterest1 = 0.025 ether;
        assertApproxEqRel(interest1, expectedInterest1, 0.005e18, "Interest after 1/4 year should be ~0.025 ether");
        
        // Check interest after exactly 1/2 year (182.5 days)
        vm.warp(acceptTime + 182.5 days);
        uint256 interest2 = bullaFrendLend.calculateCurrentInterest(claimId);
        
        // After 1/2 year, we should have approximately 5% interest (10% / 2)
        // 1 ether * 0.05 = 0.05 ether
        uint256 expectedInterest2 = 0.05 ether;
        assertApproxEqRel(interest2, expectedInterest2, 0.005e18, "Interest after 1/2 year should be ~0.05 ether");
        
        // Check interest after exactly 1 year (365 days)
        vm.warp(acceptTime + 365 days);
        uint256 interest3 = bullaFrendLend.calculateCurrentInterest(claimId);
        
        // After 1 year, we should have approximately 10% interest
        // 1 ether * 0.1 = 0.1 ether
        uint256 expectedInterest3 = 0.1 ether;
        assertApproxEqRel(interest3, expectedInterest3, 0.005e18, "Interest after 1 year should be ~0.1 ether");
    }


    function testPayLoanWithExcessiveAmount() public {
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 2 ether);
        
        vm.prank(creditor);
        weth.approve(address(bullaClaim), 2 ether);
        
        vm.prank(debtor);
        weth.approve(address(bullaClaim), 2 ether);
        
        vm.prank(debtor);
        weth.approve(address(bullaFrendLend), 5 ether);
        
        LoanOffer memory offer = LoanOffer({
            interestBPS: 500,
            termLength: 30 days,
            loanAmount: 1 ether,
            creditor: creditor,
            debtor: debtor,
            description: "Excessive Payment Test Loan",
            token: address(weth)
        });

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan{value: FEE}(offer);

        bullaClaim.permitCreateClaim({
            user: debtor,
            operator: address(bullaFrendLend),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: debtorPK,
                user: debtor,
                operator: address(bullaFrendLend),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: true
            })
        });

        vm.prank(debtor);
        uint256 claimId = bullaFrendLend.acceptLoan(loanId);

        bullaClaim.permitPayClaim({
            user: debtor,
            operator: address(bullaFrendLend),
            approvalType: PayClaimApprovalType.IsApprovedForAll,
            approvalDeadline: 0,
            paymentApprovals: new ClaimPaymentApprovalParam[](0),
            signature: sigHelper.signPayClaimPermit({
                pk: debtorPK,
                user: debtor,
                operator: address(bullaFrendLend),
                approvalType: PayClaimApprovalType.IsApprovedForAll,
                approvalDeadline: 0,
                paymentApprovals: new ClaimPaymentApprovalParam[](0)
            })
        });

        vm.warp(block.timestamp + 15 days);
        
        vm.prank(debtor);
        weth.deposit{value: 3 ether}(); 
        
        // Set a high approval for the excessive payment
        vm.prank(debtor);
        weth.approve(address(bullaFrendLend), 5 ether);
        
        // Payment amount greater than loan + interest
        uint256 excessiveAmount = 3 ether;
        
        uint256 initialCreditorBalance = weth.balanceOf(creditor);
        uint256 initialDebtorBalance = weth.balanceOf(debtor);
        
        vm.prank(debtor);
        bullaFrendLend.payLoan(claimId, excessiveAmount);
        
        Loan memory loan = bullaFrendLend.getLoan(claimId);
        assertTrue(loan.status == Status.Paid, "Loan should be fully paid");
        assertEq(loan.paidAmount, loan.claimAmount, "Paid amount should equal loan amount");
        
        (uint256 remainingPrincipal, uint256 currentInterest) = bullaFrendLend.getTotalAmountDue(claimId);
        
        uint256 actualDebtorPayment = initialDebtorBalance - weth.balanceOf(debtor);
        uint256 actualCreditorReceived = weth.balanceOf(creditor) - initialCreditorBalance;
        
        // Calculate expected payment (principal + interest)
        uint256 expectedPayment = loan.claimAmount + currentInterest;
        
        // Verify exact payment amounts
        assertEq(actualDebtorPayment, expectedPayment, "Debtor should have paid exactly the principal + interest");
        assertEq(actualCreditorReceived, expectedPayment, "Creditor should have received exactly the principal + interest");
        
        assertGt(excessiveAmount, actualDebtorPayment, "Excess payment should have been refunded");
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
        LoanOffer memory offer = LoanOffer({
            interestBPS: 500,
            termLength: 30 days,
            loanAmount: 1 ether,
            creditor: creditor,
            debtor: debtor,
            description: "Simple Metadata Test Loan",
            token: address(weth)
        });
        
        ClaimMetadata memory metadata = ClaimMetadata({
            tokenURI: "ipfs://QmTestTokenURI",
            attachmentURI: "ipfs://QmTestAttachmentURI"
        });
        
        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoanWithMetadata{value: FEE}(offer, metadata);
        
        bullaClaim.permitCreateClaim({
            user: debtor,
            operator: address(bullaFrendLend),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: debtorPK,
                user: debtor,
                operator: address(bullaFrendLend),
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
} 