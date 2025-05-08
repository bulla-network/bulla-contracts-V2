// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.14;

import "forge-std/console.sol";
import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import "contracts/types/Types.sol";
import {WETH} from "contracts/mocks/weth.sol";
import {EIP712Helper, privateKeyValidity} from "test/foundry/BullaClaim/EIP712/Utils.sol";
import {BullaClaim} from "contracts/BullaClaim.sol";
import {BullaFrendLend, LoanOffer, Loan, IncorrectFee, NotCreditor, InvalidTermLength, NativeTokenNotSupported} from "contracts/BullaFrendLend.sol";
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
        uint256 claimId = bullaFrendLend.acceptLoan(loanId, ClaimMetadata("", ""));

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

        uint256 paymentAmount = 1.05 ether; // Principal + 5% interest
                
        vm.prank(debtor);
        bullaFrendLend.payLoan(claimId, paymentAmount);

        assertEq(weth.balanceOf(creditor), initialCreditorWeth + 0.05 ether, "Creditor final WETH balance incorrect");
        assertEq(weth.balanceOf(debtor), initialDebtorWeth - 0.05 ether, "Debtor final WETH balance incorrect");

        Loan memory loan = bullaFrendLend.getLoan(claimId);
        assertTrue(loan.status == Status.Paid, "Loan status should be Paid");
        assertEq(loan.paidAmount, paymentAmount, "Paid amount should match payment");
        assertEq(loan.claimAmount, paymentAmount, "Claim amount should match payment");
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
} 