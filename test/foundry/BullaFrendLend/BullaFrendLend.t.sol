pragma solidity ^0.8.30;

import "forge-std/console.sol";
import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import "contracts/types/Types.sol";
import {WETH} from "contracts/mocks/weth.sol";
import {EIP712Helper, privateKeyValidity} from "test/foundry/BullaClaim/EIP712/Utils.sol";
import {BullaClaim} from "contracts/BullaClaim.sol";
import {
    BullaFrendLend,
    LoanRequestParams,
    Loan,
    IncorrectFee,
    NotCreditor,
    InvalidTermLength,
    NativeTokenNotSupported,
    NotDebtor,
    NotCreditor,
    NotAdmin,
    LoanOfferNotFound,
    NotCreditorOrDebtor
} from "contracts/BullaFrendLend.sol";
import {DeployContracts} from "script/DeployContracts.s.sol";
import {MockERC20} from "contracts/mocks/MockERC20.sol";
import {LoanRequestParamsBuilder} from "./LoanRequestParamsBuilder.t.sol";
import {
    InterestConfig, InterestComputationState, CompoundInterestLib
} from "contracts/libraries/CompoundInterestLib.sol";
import "test/foundry/BullaClaim/CreateClaimParamsBuilder.sol";
import {BullaClaimValidationLib} from "contracts/libraries/BullaClaimValidationLib.sol";
import "contracts/interfaces/IBullaFrendLend.sol";
import {IBullaClaim} from "contracts/interfaces/IBullaClaim.sol";

contract TestBullaFrendLend is Test {
    WETH public weth;
    MockERC20 public usdc;
    MockERC20 public dai;
    BullaClaim public bullaClaim;
    EIP712Helper public sigHelper;
    BullaFrendLend public bullaFrendLend;

    // Events for testing
    event FeeWithdrawn(address indexed admin, address indexed token, uint256 amount);
    event LoanOffered(
        uint256 indexed loanId, address indexed offeredBy, LoanRequestParams loanOffer, ClaimMetadata metadata
    );

    uint256 creditorPK = uint256(0x01);
    uint256 debtorPK = uint256(0x02);
    uint256 adminPK = uint256(0x03);
    address creditor = vm.addr(creditorPK);
    address debtor = vm.addr(debtorPK);
    address admin = vm.addr(adminPK);
    uint256 constant FEE = 0.01 ether;
    uint16 constant PROTOCOL_FEE_BPS = 1000; // 10% protocol fee

    function setUp() public {
        weth = new WETH();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        dai = new MockERC20("Dai Stablecoin", "DAI", 18);

        DeployContracts.DeploymentResult memory deploymentResult = (new DeployContracts()).deployForTest(
            address(this), // deployer
            LockState.Unlocked, // initialLockState
            FEE, // coreProtocolFee
            PROTOCOL_FEE_BPS, // invoiceProtocolFeeBPS
            PROTOCOL_FEE_BPS, // frendLendProtocolFeeBPS
            address(this) // admin
        );
        bullaClaim = BullaClaim(deploymentResult.bullaClaim);
        sigHelper = new EIP712Helper(address(bullaClaim));
        bullaFrendLend = new BullaFrendLend(address(bullaClaim), admin, PROTOCOL_FEE_BPS);

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

    function testOfferLoanByCreditor() public {
        // Approve WETH for transfer
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 2 ether);

        LoanRequestParams memory offer = new LoanRequestParamsBuilder().withInterestRateBps(500).withCreditor(creditor)
            .withDebtor(debtor).withToken(address(weth)).withDescription("Test Loan") // 5% interest (different from default 1000)
            .build();

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan(offer);

        LoanOffer memory loanOffer = bullaFrendLend.getLoanOffer(loanId);
        LoanRequestParams memory params = loanOffer.params;
        bool requestedByCreditor = loanOffer.requestedByCreditor;

        assertEq(params.interestConfig.interestRateBps, 500, "Interest BPS mismatch");
        assertEq(params.termLength, 30 days, "Term length mismatch");
        assertEq(params.loanAmount, 1 ether, "Loan amount mismatch");
        assertEq(params.creditor, creditor, "Creditor mismatch");
        assertEq(params.debtor, debtor, "Debtor mismatch");
        assertEq(params.description, "Test Loan", "Description mismatch");
        assertEq(params.token, address(weth), "Token address mismatch");
        assertEq(params.impairmentGracePeriod, 7 days, "Impairment grace period mismatch");
        assertTrue(requestedByCreditor, "Should be requested by creditor");
    }

    function testOfferLoanByDebtor() public {
        LoanRequestParams memory request = new LoanRequestParamsBuilder().withInterestRateBps(750).withCreditor(
            creditor
        ).withDebtor(debtor).withToken(address(weth)).withDescription("Test Loan Request").build();

        vm.prank(debtor);
        uint256 requestId = bullaFrendLend.offerLoan(request);

        LoanRequestParams memory params = bullaFrendLend.getLoanOffer(requestId).params;
        bool requestedByCreditor = bullaFrendLend.getLoanOffer(requestId).requestedByCreditor;

        assertEq(params.interestConfig.interestRateBps, 750, "Interest BPS mismatch");
        assertEq(params.termLength, 30 days, "Term length mismatch");
        assertEq(params.loanAmount, 1 ether, "Loan amount mismatch");
        assertEq(params.creditor, creditor, "Creditor mismatch");
        assertEq(params.debtor, debtor, "Debtor mismatch");
        assertEq(params.description, "Test Loan Request", "Description mismatch");
        assertEq(params.token, address(weth), "Token address mismatch");
        assertEq(params.impairmentGracePeriod, 7 days, "Impairment grace period mismatch");
        assertFalse(requestedByCreditor, "Should be requested by debtor");
    }

    function testAcceptLoanWithReceiver() public {
        // Create a custom receiver address
        address customReceiver = address(0x1234567);

        // Setup: Creditor makes an offer
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 1 ether);

        LoanRequestParams memory offer = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withDescription("Test Loan with Custom Receiver").build();

        vm.prank(creditor);
        uint256 offerId = bullaFrendLend.offerLoan(offer);

        // Setup permits for debtor
        bullaClaim.approvalRegistry().permitCreateClaim({
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

        uint256 initialCustomReceiverBalance = weth.balanceOf(customReceiver);
        uint256 initialDebtorBalance = weth.balanceOf(debtor);
        uint256 initialCreditorBalance = weth.balanceOf(creditor);

        // Debtor accepts the offer with custom receiver
        vm.prank(debtor);
        uint256 claimId = bullaFrendLend.acceptLoanWithReceiver{value: FEE}(offerId, customReceiver);

        // Verify the custom receiver got the loan funds, not the debtor
        assertEq(
            weth.balanceOf(customReceiver),
            initialCustomReceiverBalance + 1 ether,
            "Custom receiver should receive the loan funds"
        );
        assertEq(weth.balanceOf(debtor), initialDebtorBalance, "Debtor balance should remain unchanged");
        assertEq(
            weth.balanceOf(creditor),
            initialCreditorBalance - 1 ether,
            "Creditor should have transferred the loan amount"
        );

        // Verify the claim was created properly with debtor as the debtor
        Claim memory claim = bullaClaim.getClaim(claimId);
        assertEq(claim.debtor, debtor, "Claim debtor should be the original debtor");
        assertEq(claim.claimAmount, 1 ether, "Claim amount should be correct");
    }

    function testCannotUseReceiverWhenCreditorAcceptsDebtorRequest() public {
        // Setup: Debtor makes a request
        LoanRequestParams memory request = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withDescription("Test Debtor Request").build();

        vm.prank(debtor);
        uint256 requestId = bullaFrendLend.offerLoan(request);

        // Creditor tries to accept with a custom receiver - should fail
        address customReceiver = address(0x1234567);

        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 1 ether);

        bullaClaim.approvalRegistry().permitCreateClaim({
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

        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(NotDebtor.selector));
        bullaFrendLend.acceptLoanWithReceiver{value: FEE}(requestId, customReceiver);
    }

    function testOfferLoanByCreditorWithWrongCreditor() public {
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 1 ether);

        LoanRequestParams memory offer = new LoanRequestParamsBuilder().withCreditor(debtor).withDebtor(debtor)
            .withDescription("Test Loan").withToken(address(weth)) // Wrong creditor
            .build();

        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(NotCreditorOrDebtor.selector));
        bullaFrendLend.offerLoan(offer);
    }

    function testOfferLoanByDebtorWithWrongDebtor() public {
        LoanRequestParams memory request = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(creditor)
            .withDescription("Test Loan Request").withToken(address(weth)) // Wrong debtor
            .build();

        vm.prank(debtor);
        vm.expectRevert(abi.encodeWithSelector(NotCreditorOrDebtor.selector));
        bullaFrendLend.offerLoan(request);
    }

    function testOfferLoanWithZeroTermLength() public {
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 1 ether);

        LoanRequestParams memory offer = new LoanRequestParamsBuilder().withTermLength(0).withCreditor(creditor)
            .withDebtor(debtor).withToken(address(weth)) // Invalid term length
            .build();

        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(InvalidTermLength.selector));
        bullaFrendLend.offerLoan(offer);
    }

    function testOfferLoanWithNativeToken() public {
        LoanRequestParams memory offer = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(0)) // Native token (should be rejected)
            .build();

        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(NativeTokenNotSupported.selector));
        bullaFrendLend.offerLoan(offer);
    }

    function testOfferLoanWithZeroInterest() public {
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 1 ether);

        LoanRequestParams memory offer = new LoanRequestParamsBuilder().withInterestRateBps(0).withCreditor(creditor)
            .withDebtor(debtor).withToken(address(weth)) // Zero interest
            .build();

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan(offer);

        LoanOffer memory loanOffer = bullaFrendLend.getLoanOffer(loanId);
        LoanRequestParams memory params = loanOffer.params;
        assertEq(params.interestConfig.interestRateBps, 0, "Interest BPS should be zero");
    }

    function testLoanOfferedEventEmittedWithOriginationFee() public {
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 1 ether);

        LoanRequestParams memory offer = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withDescription("Test Loan with Event").build();

        // Expect the LoanOffered event to be emitted with the correct parameters
        vm.expectEmit(true, true, false, true);
        emit LoanOffered(1, creditor, offer, ClaimMetadata({tokenURI: "", attachmentURI: ""}));

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan(offer);

        assertEq(loanId, 1, "Loan ID should be 1");
    }

    function testLoanOfferedEventEmittedByDebtorWithOriginationFee() public {
        LoanRequestParams memory request = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withDescription("Test Request with Event").build();

        // Expect the LoanOffered event to be emitted with the correct parameters (by debtor)
        vm.expectEmit(true, true, false, true);
        emit LoanOffered(1, debtor, request, ClaimMetadata({tokenURI: "", attachmentURI: ""}));

        vm.prank(debtor);
        uint256 requestId = bullaFrendLend.offerLoan(request);

        assertEq(requestId, 1, "Request ID should be 1");
    }

    function testCannotAcceptCreditorOfferIfNotDebtor() public {
        // Approve WETH for transfer
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 2 ether);

        LoanRequestParams memory offer =
            new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth)).build();

        vm.prank(creditor);
        uint256 offerId = bullaFrendLend.offerLoan(offer);

        // Creditor cannot accept their own offer
        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(NotDebtor.selector));
        bullaFrendLend.acceptLoan{value: FEE}(offerId);

        // Random user cannot accept offer
        address randomUser = address(0x999);
        vm.deal(randomUser, 1 ether);
        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(NotDebtor.selector));
        bullaFrendLend.acceptLoan{value: FEE}(offerId);

        uint256 nonExistentOfferId = 999;
        vm.expectRevert(abi.encodeWithSelector(LoanOfferNotFound.selector));
        bullaFrendLend.acceptLoan{value: FEE}(nonExistentOfferId);
    }

    function testCannotAcceptDebtorOfferIfNotCreditor() public {
        LoanRequestParams memory request =
            new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth)).build();

        vm.prank(debtor);
        uint256 requestId = bullaFrendLend.offerLoan(request);

        vm.prank(debtor);
        vm.expectRevert(abi.encodeWithSelector(NotCreditor.selector));
        bullaFrendLend.acceptLoan{value: FEE}(requestId);

        address randomUser = address(0x999);
        vm.deal(randomUser, 1 ether);
        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(NotCreditor.selector));
        bullaFrendLend.acceptLoan{value: FEE}(requestId);

        uint256 nonExistentRequestId = 999;
        vm.expectRevert(abi.encodeWithSelector(LoanOfferNotFound.selector));
        bullaFrendLend.acceptLoan{value: FEE}(nonExistentRequestId);
    }

    function testEndToEndLoanFlowCreditorOffer() public {
        // Approve WETH for transfer from creditor to BullaFrendLend
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 2 ether);

        vm.prank(debtor);
        weth.approve(address(bullaFrendLend), 2 ether);

        LoanRequestParams memory offer = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withNumberOfPeriodsPerYear(365).build();

        uint256 initialCreditorWeth = weth.balanceOf(creditor);
        uint256 initialDebtorWeth = weth.balanceOf(debtor);

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan(offer);

        bullaClaim.approvalRegistry().permitCreateClaim({
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
        uint256 claimId = bullaFrendLend.acceptLoan{value: FEE}(loanId);

        assertEq(
            weth.balanceOf(creditor),
            initialCreditorWeth - 1 ether,
            "Creditor WETH balance after loan acceptance incorrect"
        );
        assertEq(
            weth.balanceOf(debtor), initialDebtorWeth + 1 ether, "Debtor WETH balance after loan acceptance incorrect"
        );
        assertEq(weth.balanceOf(address(bullaFrendLend)), 0, "BullaFrendLend WETH balance should be 0 after transfer");

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

    function testEndToEndLoanFlowDebtorOffer() public {
        // Debtor creates a loan request
        LoanRequestParams memory request = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withNumberOfPeriodsPerYear(365).build();

        // Approve WETH for transfer from creditor to BullaFrendLend
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 2 ether);

        vm.prank(debtor);
        weth.approve(address(bullaFrendLend), 2 ether);

        uint256 initialCreditorWeth = weth.balanceOf(creditor);
        uint256 initialDebtorWeth = weth.balanceOf(debtor);

        // Debtor creates the loan request
        vm.prank(debtor);
        uint256 requestId = bullaFrendLend.offerLoan(request);

        bullaClaim.approvalRegistry().permitCreateClaim({
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

        // Creditor accepts the loan request
        vm.prank(creditor);
        uint256 claimId = bullaFrendLend.acceptLoan{value: FEE}(requestId);

        assertEq(
            weth.balanceOf(creditor),
            initialCreditorWeth - 1 ether,
            "Creditor WETH balance after loan acceptance incorrect"
        );
        assertEq(
            weth.balanceOf(debtor), initialDebtorWeth + 1 ether, "Debtor WETH balance after loan acceptance incorrect"
        );
        assertEq(weth.balanceOf(address(bullaFrendLend)), 0, "BullaFrendLend WETH balance should be 0 after transfer");

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

    function testRejectLoanOfferByCreditor() public {
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 2 ether);

        LoanRequestParams memory offer =
            new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth)).build();

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan(offer);

        vm.prank(creditor);
        bullaFrendLend.rejectLoanOffer(loanId);

        LoanOffer memory loanOffer = bullaFrendLend.getLoanOffer(loanId);
        LoanRequestParams memory params = loanOffer.params;
        assertEq(params.creditor, address(0), "Offer should be deleted after rejection");
    }

    function testRejectOfferByDebtor() public {
        LoanRequestParams memory request =
            new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth)).build();

        vm.prank(debtor);
        uint256 requestId = bullaFrendLend.offerLoan(request);

        vm.prank(debtor);
        bullaFrendLend.rejectLoanOffer(requestId);

        LoanOffer memory loanOffer = bullaFrendLend.getLoanOffer(requestId);
        LoanRequestParams memory params = loanOffer.params;
        assertEq(params.debtor, address(0), "Request should be deleted after rejection");
    }

    function testPartialLoanPayments() public {
        vm.startPrank(creditor);
        weth.approve(address(bullaFrendLend), 2 ether);
        vm.stopPrank();

        vm.startPrank(debtor);
        weth.approve(address(bullaFrendLend), 2 ether);
        vm.stopPrank();

        LoanRequestParams memory offer =
            new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth)).build();

        uint256 initialCreditorWeth = weth.balanceOf(creditor);
        uint256 initialDebtorWeth = weth.balanceOf(debtor);

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan(offer);

        bullaClaim.approvalRegistry().permitCreateClaim({
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
        uint256 claimId = bullaFrendLend.acceptLoan{value: FEE}(loanId);

        assertEq(
            weth.balanceOf(creditor),
            initialCreditorWeth - 1 ether,
            "Creditor WETH balance after loan acceptance incorrect"
        );
        assertEq(
            weth.balanceOf(debtor), initialDebtorWeth + 1 ether, "Debtor WETH balance after loan acceptance incorrect"
        );

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

        vm.prank(admin);
        bullaFrendLend.setProtocolFee(20); // 0.2%

        // Set up a loan with 7.2% gross interest (0.2% protocol + 7% interest) (720 BPS)
        LoanRequestParams memory offer = new LoanRequestParamsBuilder().withTermLength(10 * 365 days).withCreditor(
            creditor
        ).withDebtor(debtor).withToken(address(weth)).withInterestRateBps(700).withNumberOfPeriodsPerYear(1) // 1 year term (different from default 30 days)
            .build();

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan(offer);

        bullaClaim.approvalRegistry().permitCreateClaim({
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
        uint256 claimId = bullaFrendLend.acceptLoan{value: FEE}(loanId);

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

        LoanRequestParams memory offer =
            new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth)).build();

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan(offer);

        bullaClaim.approvalRegistry().permitCreateClaim({
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
        uint256 claimId = bullaFrendLend.acceptLoan{value: FEE}(loanId);

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
        vm.expectRevert(abi.encodeWithSelector(IBullaClaim.NotMinted.selector));
        bullaFrendLend.payLoan(nonExistentClaimId, 1 ether);
    }

    function testLoanMetadataOnClaim() public {
        vm.startPrank(creditor);
        weth.approve(address(bullaFrendLend), 2 ether);
        weth.approve(address(bullaClaim), 2 ether);
        vm.stopPrank();

        // Create a loan offer with metadata
        LoanRequestParams memory offer =
            new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth)).build();

        ClaimMetadata memory metadata =
            ClaimMetadata({tokenURI: "ipfs://QmTestTokenURI", attachmentURI: "ipfs://QmTestAttachmentURI"});

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoanWithMetadata(offer, metadata);

        bullaClaim.approvalRegistry().permitCreateClaim({
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
        uint256 claimId = bullaFrendLend.acceptLoan{value: FEE}(loanId);

        // Get the claim metadata directly from BullaClaim contract
        (string memory tokenURI, string memory attachmentURI) = bullaClaim.claimMetadata(claimId);

        // Verify the metadata was correctly stored on the claim
        assertEq(tokenURI, "ipfs://QmTestTokenURI", "Token URI not correctly stored on claim");
        assertEq(attachmentURI, "ipfs://QmTestAttachmentURI", "Attachment URI not correctly stored on claim");
    }

    function testSetProtocolFee() public {
        uint16 newProtocolFeeBPS = 2000; // 20%

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

        bullaClaim.approvalRegistry().permitCreateClaim({
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

        LoanRequestParams memory wethOffer = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withDescription("WETH Loan").withToken(address(weth)).withNumberOfPeriodsPerYear(365).build();

        vm.prank(creditor);
        uint256 wethLoanId = bullaFrendLend.offerLoan(wethOffer);

        vm.prank(debtor);
        uint256 wethClaimId = bullaFrendLend.acceptLoan{value: FEE}(wethLoanId);

        LoanRequestParams memory usdcOffer = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withDescription("USDC Loan").withToken(address(usdc)).withLoanAmount(1000 * 10 ** 6).withNumberOfPeriodsPerYear(
            365
        ).build();

        vm.prank(creditor);
        uint256 usdcLoanId = bullaFrendLend.offerLoan(usdcOffer);

        vm.prank(debtor);
        uint256 usdcClaimId = bullaFrendLend.acceptLoan{value: FEE}(usdcLoanId);

        LoanRequestParams memory daiOffer = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withDescription("DAI Loan").withToken(address(dai)).withLoanAmount(1000 ether).withNumberOfPeriodsPerYear(365)
            .build();

        vm.prank(creditor);
        uint256 daiLoanId = bullaFrendLend.offerLoan(daiOffer);

        vm.prank(debtor);
        uint256 daiClaimId = bullaFrendLend.acceptLoan{value: FEE}(daiLoanId);

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

        uint256 initialAdminWethBalance = weth.balanceOf(admin);
        uint256 initialAdminUsdcBalance = usdc.balanceOf(admin);
        uint256 initialAdminDaiBalance = dai.balanceOf(admin);

        uint256 wethFee = bullaFrendLend.protocolFeesByToken(address(weth));
        uint256 usdcFee = bullaFrendLend.protocolFeesByToken(address(usdc));
        uint256 daiFee = bullaFrendLend.protocolFeesByToken(address(dai));

        // Admin withdraws fees
        vm.prank(admin);
        bullaFrendLend.withdrawAllFees();

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

    // ==================== FEE WITHDRAWN EVENT TESTS ====================

    function testFeeWithdrawnEventEmittedForERC20Token() public {
        // Setup loan and make payment to accumulate protocol fees
        vm.startPrank(creditor);
        weth.approve(address(bullaFrendLend), 2 ether);
        vm.stopPrank();

        vm.startPrank(debtor);
        weth.approve(address(bullaFrendLend), 2 ether);
        vm.stopPrank();

        bullaClaim.approvalRegistry().permitCreateClaim({
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

        LoanRequestParams memory offer = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withInterestRateBps(1000).withNumberOfPeriodsPerYear(12).build();

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan(offer);

        vm.prank(debtor);
        uint256 claimId = bullaFrendLend.acceptLoan{value: FEE}(loanId);

        // Fast forward to accrue interest
        vm.warp(block.timestamp + 90 days);

        // Make payment to accumulate fees
        (, uint256 interest) = bullaFrendLend.getTotalAmountDue(claimId);
        vm.prank(debtor);
        bullaFrendLend.payLoan(claimId, interest);

        uint256 tokenFees = bullaFrendLend.protocolFeesByToken(address(weth));
        assertTrue(tokenFees > 0, "Contract should have token fees");

        // Expect FeeWithdrawn event for WETH
        vm.expectEmit(true, true, false, true);
        emit FeeWithdrawn(admin, address(weth), tokenFees);

        vm.prank(admin);
        bullaFrendLend.withdrawAllFees();
    }

    function testFeeWithdrawnEventEmittedForMultipleTokens() public {
        // Setup similar to testProtocolFeeWithMultipleTokens but just focusing on events
        vm.startPrank(creditor);
        weth.approve(address(bullaFrendLend), 10 ether);
        usdc.approve(address(bullaFrendLend), 10000 * 10 ** 6);
        dai.approve(address(bullaFrendLend), 10000 ether);
        vm.stopPrank();

        vm.startPrank(debtor);
        weth.approve(address(bullaFrendLend), 10 ether);
        usdc.approve(address(bullaFrendLend), 10000 * 10 ** 6);
        dai.approve(address(bullaFrendLend), 10000 ether);
        vm.stopPrank();

        bullaClaim.approvalRegistry().permitCreateClaim({
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

        // Create loans for different tokens
        LoanRequestParams memory wethOffer = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withInterestRateBps(1000).withNumberOfPeriodsPerYear(12).build();

        LoanRequestParams memory usdcOffer = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(usdc)).withLoanAmount(1000 * 10 ** 6).withInterestRateBps(800).withNumberOfPeriodsPerYear(12)
            .build();

        LoanRequestParams memory daiOffer = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(dai)).withLoanAmount(1000 ether).withInterestRateBps(1200).withNumberOfPeriodsPerYear(12)
            .build();

        vm.startPrank(creditor);
        uint256 wethLoanId = bullaFrendLend.offerLoan(wethOffer);
        uint256 usdcLoanId = bullaFrendLend.offerLoan(usdcOffer);
        uint256 daiLoanId = bullaFrendLend.offerLoan(daiOffer);
        vm.stopPrank();

        vm.startPrank(debtor);
        uint256 wethClaimId = bullaFrendLend.acceptLoan{value: FEE}(wethLoanId);
        uint256 usdcClaimId = bullaFrendLend.acceptLoan{value: FEE}(usdcLoanId);
        uint256 daiClaimId = bullaFrendLend.acceptLoan{value: FEE}(daiLoanId);
        vm.stopPrank();

        // Fast forward to accrue interest
        vm.warp(block.timestamp + 90 days);

        // Make payments to accumulate fees
        vm.startPrank(debtor);
        (, uint256 wethInterest) = bullaFrendLend.getTotalAmountDue(wethClaimId);
        bullaFrendLend.payLoan(wethClaimId, wethInterest);

        (, uint256 usdcInterest) = bullaFrendLend.getTotalAmountDue(usdcClaimId);
        bullaFrendLend.payLoan(usdcClaimId, usdcInterest);

        (, uint256 daiInterest) = bullaFrendLend.getTotalAmountDue(daiClaimId);
        bullaFrendLend.payLoan(daiClaimId, daiInterest);
        vm.stopPrank();

        // Get fee amounts before withdrawal
        uint256 wethFees = bullaFrendLend.protocolFeesByToken(address(weth));
        uint256 usdcFees = bullaFrendLend.protocolFeesByToken(address(usdc));
        uint256 daiFees = bullaFrendLend.protocolFeesByToken(address(dai));

        // Expect all FeeWithdrawn events
        vm.expectEmit(true, true, false, true);
        emit FeeWithdrawn(admin, address(weth), wethFees);

        vm.expectEmit(true, true, false, true);
        emit FeeWithdrawn(admin, address(usdc), usdcFees);

        vm.expectEmit(true, true, false, true);
        emit FeeWithdrawn(admin, address(dai), daiFees);

        vm.prank(admin);
        bullaFrendLend.withdrawAllFees();
    }

    function testNoFeeWithdrawnEventWhenNoFeesToWithdraw() public {
        // No loan offers made, so no fees accumulated
        uint256 adminBalanceBefore = admin.balance;

        // Should not emit any FeeWithdrawn events
        vm.recordLogs();

        vm.prank(admin);
        bullaFrendLend.withdrawAllFees();

        // Check that no FeeWithdrawn events were emitted
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            // FeeWithdrawn event has signature: keccak256("FeeWithdrawn(address,address,uint256)")
            assertFalse(
                logs[i].topics[0] == keccak256("FeeWithdrawn(address,address,uint256)"),
                "No FeeWithdrawn events should be emitted"
            );
        }

        assertEq(admin.balance, adminBalanceBefore, "Admin balance should be unchanged");
    }

    function testFeeWithdrawnEventNotEmittedForZeroTokenFees() public {
        // Setup loan and make payment to accumulate token fees
        vm.startPrank(creditor);
        weth.approve(address(bullaFrendLend), 2 ether);
        vm.stopPrank();

        vm.startPrank(debtor);
        weth.approve(address(bullaFrendLend), 2 ether);
        vm.stopPrank();

        bullaClaim.approvalRegistry().permitCreateClaim({
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

        LoanRequestParams memory offer = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withInterestRateBps(1000).withNumberOfPeriodsPerYear(12).build();

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan(offer);

        vm.prank(debtor);
        uint256 claimId = bullaFrendLend.acceptLoan{value: FEE}(loanId);

        // Fast forward to accrue interest
        vm.warp(block.timestamp + 90 days);

        // Make payment to accumulate fees
        (, uint256 interest) = bullaFrendLend.getTotalAmountDue(claimId);
        vm.prank(debtor);
        bullaFrendLend.payLoan(claimId, interest);

        // First withdrawal - should emit event
        uint256 tokenFees = bullaFrendLend.protocolFeesByToken(address(weth));

        vm.expectEmit(true, true, false, true);
        emit FeeWithdrawn(admin, address(weth), tokenFees);

        vm.prank(admin);
        bullaFrendLend.withdrawAllFees();

        // Second withdrawal - should NOT emit event for weth since fees are now 0
        vm.recordLogs();

        vm.prank(admin);
        bullaFrendLend.withdrawAllFees();

        // Check that no FeeWithdrawn events were emitted for weth
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("FeeWithdrawn(address,address,uint256)")) {
                // If any FeeWithdrawn event was emitted, it should not be for weth
                address tokenAddress = address(uint160(uint256(logs[i].topics[2])));
                assertFalse(
                    tokenAddress == address(weth), "No FeeWithdrawn event should be emitted for weth with zero fees"
                );
            }
        }
    }

    function testTokenTrackingUniqueness() public {
        vm.startPrank(creditor);
        weth.approve(address(bullaFrendLend), 10 ether);
        vm.stopPrank();

        vm.startPrank(debtor);
        weth.approve(address(bullaFrendLend), 10 ether);
        vm.stopPrank();

        bullaClaim.approvalRegistry().permitCreateClaim({
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

        // Create first WETH loan
        LoanRequestParams memory wethOffer1 = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withDescription("WETH Loan 1").withToken(address(weth)).withLoanAmount(1 ether).withNumberOfPeriodsPerYear(365)
            .build();

        vm.prank(creditor);
        uint256 wethLoanId1 = bullaFrendLend.offerLoan(wethOffer1);

        vm.prank(debtor);
        uint256 wethClaimId1 = bullaFrendLend.acceptLoan{value: FEE}(wethLoanId1);

        // Create second WETH loan
        LoanRequestParams memory wethOffer2 = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withDescription("WETH Loan 2").withToken(address(weth)).withLoanAmount(0.5 ether).withNumberOfPeriodsPerYear(
            365
        ).build();

        vm.prank(creditor);
        uint256 wethLoanId2 = bullaFrendLend.offerLoan(wethOffer2);

        vm.prank(debtor);
        uint256 wethClaimId2 = bullaFrendLend.acceptLoan{value: FEE}(wethLoanId2);

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

        bullaClaim.approvalRegistry().permitCreateClaim({
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

        // Protocol Fee = 0%
        vm.startPrank(admin);
        bullaFrendLend.setProtocolFee(0);
        vm.stopPrank();

        LoanRequestParams memory offer = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withInterestRateBps(1000).build();

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan(offer);

        vm.prank(debtor);
        uint256 claimId = bullaFrendLend.acceptLoan{value: FEE}(loanId);

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

        offer = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor).withDescription(
            "50% Protocol Fee Test Loan"
        ).withToken(address(weth)).withInterestRateBps(1000).build();

        vm.prank(creditor);
        loanId = bullaFrendLend.offerLoan(offer);

        vm.prank(debtor);
        claimId = bullaFrendLend.acceptLoan{value: FEE}(loanId);

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

        bullaClaim.approvalRegistry().permitCreateClaim({
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

        LoanRequestParams memory offer = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withTermLength(30 days).build();

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan(offer);

        vm.prank(debtor);
        uint256 claimId = bullaFrendLend.acceptLoan{value: FEE}(loanId);

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

        bullaClaim.approvalRegistry().permitCreateClaim({
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

        LoanRequestParams memory offer = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withInterestRateBps(1000).build();

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan(offer);

        vm.prank(debtor);
        uint256 claimId = bullaFrendLend.acceptLoan{value: FEE}(loanId);

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

        bullaClaim.approvalRegistry().permitCreateClaim({
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

        LoanRequestParams memory offer =
            new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth)).build();

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan(offer);

        vm.prank(debtor);
        uint256 claimId = bullaFrendLend.acceptLoan{value: FEE}(loanId);

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
        uint256 claimId = bullaClaim.createClaim{value: FEE}(params);

        // Try to impair via BullaFrendLend - should fail since it's not the controller
        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(IBullaClaim.NotController.selector, address(creditor)));
        bullaFrendLend.impairLoan(claimId);
    }

    function testImpairLoan_InterestAccrual() public {
        // Setup approvals
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 2 ether);

        bullaClaim.approvalRegistry().permitCreateClaim({
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
        LoanRequestParams memory offer = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withInterestRateBps(1000).withNumberOfPeriodsPerYear(365) // 10% annual interest
            .build();

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan(offer);

        vm.prank(debtor);
        uint256 claimId = bullaFrendLend.acceptLoan{value: FEE}(loanId);

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

        vm.prank(admin);
        bullaFrendLend.setProtocolFee(0); // 0%

        bullaClaim.approvalRegistry().permitCreateClaim({
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
        LoanRequestParams memory offer = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withInterestRateBps(1000).build();

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan(offer);

        vm.prank(debtor);
        uint256 claimId = bullaFrendLend.acceptLoan{value: FEE}(loanId);

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

        uint256 expectedCreditorAmount = principal + interest;

        assertEq(
            weth.balanceOf(creditor) - creditorBalanceBefore,
            expectedCreditorAmount,
            "Creditor should receive principal + net interest"
        );

        assertEq(
            weth.balanceOf(address(bullaFrendLend)),
            contractBalanceBefore,
            "Contract should not receive protocol fee since it is 0%"
        );
    }

    function testImpairLoan_StatusTransitions() public {
        // Setup approvals
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 2 ether);

        bullaClaim.approvalRegistry().permitCreateClaim({
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

        // Create first loan
        LoanRequestParams memory offer1 = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withDescription("First Loan").build();

        vm.prank(creditor);
        uint256 loanId1 = bullaFrendLend.offerLoan(offer1);

        vm.prank(debtor);
        uint256 claimId1 = bullaFrendLend.acceptLoan{value: FEE}(loanId1);

        // Create second loan
        LoanRequestParams memory offer2 = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withDescription("Second Loan").build();

        vm.prank(creditor);
        uint256 loanId2 = bullaFrendLend.offerLoan(offer2);

        vm.prank(debtor);
        uint256 claimId2 = bullaFrendLend.acceptLoan{value: FEE}(loanId2);

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

        bullaClaim.approvalRegistry().permitCreateClaim({
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

        // Create WETH loan
        LoanRequestParams memory wethOffer = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withDescription("WETH Loan").build();

        vm.prank(creditor);
        uint256 wethLoanId = bullaFrendLend.offerLoan(wethOffer);

        vm.prank(debtor);
        uint256 wethClaimId = bullaFrendLend.acceptLoan{value: FEE}(wethLoanId);

        // Create USDC loan
        LoanRequestParams memory usdcOffer = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(usdc)).withLoanAmount(1000 * 10 ** 6).withDescription("USDC Loan").build();

        vm.prank(creditor);
        uint256 usdcLoanId = bullaFrendLend.offerLoan(usdcOffer);

        vm.prank(debtor);
        uint256 usdcClaimId = bullaFrendLend.acceptLoan{value: FEE}(usdcLoanId);

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

    function testMarkLoanAsPaid_Success() public {
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 2 ether);

        bullaClaim.approvalRegistry().permitCreateClaim({
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

        LoanRequestParams memory offer = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withTermLength(30 days).build();

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan(offer);

        vm.prank(debtor);
        uint256 claimId = bullaFrendLend.acceptLoan{value: FEE}(loanId);

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

        bullaClaim.approvalRegistry().permitCreateClaim({
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

        LoanRequestParams memory offer = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withInterestRateBps(1000).build();

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan(offer);

        vm.prank(debtor);
        uint256 claimId = bullaFrendLend.acceptLoan{value: FEE}(loanId);

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

        bullaClaim.approvalRegistry().permitCreateClaim({
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

        LoanRequestParams memory offer =
            new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth)).build();

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan(offer);

        vm.prank(debtor);
        uint256 claimId = bullaFrendLend.acceptLoan{value: FEE}(loanId);

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
        uint256 claimId = bullaClaim.createClaim{value: FEE}(params);

        // Try to mark as paid via BullaFrendLend - should fail since it's not the controller
        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(IBullaClaim.NotController.selector, address(creditor)));
        bullaFrendLend.markLoanAsPaid(claimId);
    }

    function testMarkLoanAsPaid_FromImpairedStatus() public {
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 2 ether);

        bullaClaim.approvalRegistry().permitCreateClaim({
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

        LoanRequestParams memory offer = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withTermLength(30 days).build();

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan(offer);

        vm.prank(debtor);
        uint256 claimId = bullaFrendLend.acceptLoan{value: FEE}(loanId);

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

    // ========================================
    // CompoundInterestLib Test Cases
    // ========================================

    function testCompoundInterestLib_ValidateInterestConfig_ZeroPeriodsPerYear() public pure {
        InterestConfig memory config = InterestConfig({
            interestRateBps: 1000,
            numberOfPeriodsPerYear: 0 // Valid - means simple interest (no compounding)
        });

        // Should not revert - zero periods per year is now valid for simple interest
        CompoundInterestLib.validateInterestConfig(config);
    }

    function testCompoundInterestLib_ValidateInterestConfig_TooManyPeriodsPerYear() public {
        InterestConfig memory config = InterestConfig({
            interestRateBps: 1000,
            numberOfPeriodsPerYear: 366 // Invalid - exceeds MAX_DAYS_PER_YEAR (365)
        });

        vm.expectRevert(CompoundInterestLib.InvalidPeriodsPerYear.selector);
        CompoundInterestLib.validateInterestConfig(config);
    }

    function testCompoundInterestLib_ValidateInterestConfig_BoundaryTest() public pure {
        InterestConfig memory config = InterestConfig({
            interestRateBps: 1000,
            numberOfPeriodsPerYear: 365 // Valid - exactly at the limit
        });

        // Should not revert
        CompoundInterestLib.validateInterestConfig(config);
    }

    function testCompoundInterestLib_ValidateInterestConfig_ZeroInterestRate() public pure {
        InterestConfig memory config = InterestConfig({
            interestRateBps: 0, // Zero interest rate - should skip validation
            numberOfPeriodsPerYear: 0 // This would normally be invalid, but should be ignored
        });

        // Should not revert because interest rate is 0
        CompoundInterestLib.validateInterestConfig(config);
    }

    function testCompoundInterestLib_ComputeInterest_ZeroPeriodsElapsed() public {
        InterestConfig memory config = InterestConfig({
            interestRateBps: 1000, // 10% annual interest
            numberOfPeriodsPerYear: 12 // Monthly compounding
        });

        InterestComputationState memory state = InterestComputationState({
            accruedInterest: 0.1 ether, // Some existing accrued interest
            latestPeriodNumber: 5, // Already at period 5
            protocolFeeBps: 0,
            totalGrossInterestPaid: 0
        });

        uint256 remainingPrincipal = 1 ether;

        // Set a fixed due date in the past
        uint256 dueBy = 1000000; // Fixed timestamp in the past

        // Calculate the exact time that would still be in period 5
        uint256 secondsPerPeriod = 365 days / 12; // ~30.4 days per period
        uint256 timeForPeriod5End = dueBy + (6 * secondsPerPeriod); // End of period 5

        // Warp to a time that's still within period 5 (should result in periodsElapsed = 0)
        vm.warp(timeForPeriod5End - 1 days); // Still in period 5

        InterestComputationState memory result =
            CompoundInterestLib.computeInterest(remainingPrincipal, dueBy, config, state);

        // Should return unchanged state since no complete period has elapsed
        assertEq(result.latestPeriodNumber, 5, "Period number should remain unchanged");
        assertEq(result.accruedInterest, 0.1 ether, "Accrued interest should remain unchanged");
    }

    function testCompoundInterestLib_ComputeInterest_ZeroRemainingPrincipal() public {
        InterestConfig memory config = InterestConfig({
            interestRateBps: 1000, // 10% annual interest
            numberOfPeriodsPerYear: 12 // Monthly compounding
        });

        InterestComputationState memory state = InterestComputationState({
            accruedInterest: 0,
            latestPeriodNumber: 0,
            protocolFeeBps: 0,
            totalGrossInterestPaid: 0
        });

        uint256 remainingPrincipal = 0; // Zero principal - no interest should accrue

        // Set a fixed due date in the past
        uint256 dueBy = 1000000; // Fixed timestamp in the past

        // Warp to a time well after due date
        vm.warp(dueBy + 365 days); // 1 year after due date

        InterestComputationState memory result =
            CompoundInterestLib.computeInterest(remainingPrincipal, dueBy, config, state);

        // Should return unchanged state since principal is zero
        assertEq(result.latestPeriodNumber, 0, "Period number should remain 0");
        assertEq(result.accruedInterest, 0, "No interest should accrue with zero principal");
    }

    function testCompoundInterestLib_ComputeInterest_BeforeDueDate() public {
        InterestConfig memory config = InterestConfig({
            interestRateBps: 1000, // 10% annual interest
            numberOfPeriodsPerYear: 12 // Monthly compounding
        });

        InterestComputationState memory state = InterestComputationState({
            accruedInterest: 0,
            latestPeriodNumber: 0,
            protocolFeeBps: 0,
            totalGrossInterestPaid: 0
        });

        uint256 dueBy = block.timestamp + 30 days; // Future due date
        uint256 remainingPrincipal = 1 ether;

        InterestComputationState memory result =
            CompoundInterestLib.computeInterest(remainingPrincipal, dueBy, config, state);

        // Should return unchanged state since we're before due date
        assertEq(result.latestPeriodNumber, 0, "Period number should remain 0");
        assertEq(result.accruedInterest, 0, "No interest should accrue before due date");
    }

    function testCompoundInterestLib_ComputeSimpleInterest() public {
        InterestConfig memory config = InterestConfig({
            interestRateBps: 1000, // 10% annual interest
            numberOfPeriodsPerYear: 0 // Simple interest (no compounding)
        });

        InterestComputationState memory state = InterestComputationState({
            accruedInterest: 0,
            latestPeriodNumber: 0,
            protocolFeeBps: 0,
            totalGrossInterestPaid: 0
        });

        uint256 remainingPrincipal = 1 ether;
        uint256 dueBy = 1000000; // Fixed timestamp in the past

        // Warp to 1 year after due date
        vm.warp(dueBy + 365 days);

        InterestComputationState memory result =
            CompoundInterestLib.computeInterest(remainingPrincipal, dueBy, config, state);

        // For simple interest: Interest = Principal × Rate × Time
        // Expected: 1 ether × 10% × 1 year = 0.1 ether
        assertEq(result.accruedInterest, 0.1 ether, "Simple interest should be 10% of principal for 1 year");
        assertEq(result.latestPeriodNumber, 0, "Period number should remain 0 for simple interest");
    }

    function testCompoundInterestLib_ComputeSimpleInterest_PartialDay() public {
        InterestConfig memory config = InterestConfig({
            interestRateBps: 1000, // 10% annual interest
            numberOfPeriodsPerYear: 0 // Simple interest (no compounding)
        });

        InterestComputationState memory state = InterestComputationState({
            accruedInterest: 0,
            latestPeriodNumber: 0,
            protocolFeeBps: 0,
            totalGrossInterestPaid: 0
        });

        uint256 remainingPrincipal = 1 ether;
        uint256 dueBy = 1000000; // Fixed timestamp in the past

        // Warp to 12 hours after due date (partial day)
        vm.warp(dueBy + 12 hours);

        InterestComputationState memory result =
            CompoundInterestLib.computeInterest(remainingPrincipal, dueBy, config, state);

        // For simple interest with daily accrual: no interest should accrue for partial days
        assertEq(result.accruedInterest, 0, "No interest should accrue for partial days");
        assertEq(result.latestPeriodNumber, 0, "Period number should be 0 for partial days");
    }

    function testCompoundInterestLib_ComputeSimpleInterest_MultipleDays() public {
        InterestConfig memory config = InterestConfig({
            interestRateBps: 3650, // 36.5% annual interest for easy calculation (0.1% per day)
            numberOfPeriodsPerYear: 0 // Simple interest (no compounding)
        });

        InterestComputationState memory state = InterestComputationState({
            accruedInterest: 0,
            latestPeriodNumber: 0,
            protocolFeeBps: 0,
            totalGrossInterestPaid: 0
        });

        uint256 remainingPrincipal = 1 ether;
        uint256 dueBy = 1000000; // Fixed timestamp in the past

        // Warp to 10 complete days after due date
        vm.warp(dueBy + 10 days);

        InterestComputationState memory result =
            CompoundInterestLib.computeInterest(remainingPrincipal, dueBy, config, state);

        // For simple interest: Interest = Principal × Rate × Time
        // Expected: 1 ether × 36.5% × (10/365) year ≈ 0.01 ether (1% total)
        assertApproxEqAbs(
            result.accruedInterest,
            0.01 ether,
            1,
            "Simple interest should be approximately 1% of principal for 10 days at 36.5% annual rate"
        );
        assertEq(result.latestPeriodNumber, 0, "Period number should remain 0 for simple interest");
    }

    // ========================================
    // Interest Decrementation After Payment Tests
    // ========================================

    function testLoanInterestDecrementAfterFullInterestPayment() public {
        // Setup loan with interest
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 1 ether);

        LoanRequestParams memory offer = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withLoanAmount(1 ether).withTermLength(30 days).withInterestRate(1200, 12) // 12% annual, monthly compounding
            .build();

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan(offer);

        bullaClaim.approvalRegistry().permitCreateClaim({
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
        uint256 claimId = bullaFrendLend.acceptLoan{value: FEE}(loanId);

        // Fast forward to accrue interest
        vm.warp(block.timestamp + 90 days); // 3 months overdue

        // Check interest before payment
        Loan memory loanBefore = bullaFrendLend.getLoan(claimId);
        uint256 interestBefore = loanBefore.interestComputationState.accruedInterest;
        uint256 periodNumberBefore = loanBefore.interestComputationState.latestPeriodNumber;

        assertTrue(interestBefore > 0, "Interest should have accrued after due date");
        assertTrue(periodNumberBefore > 0, "Period number should be greater than 0");

        // Pay only the interest
        vm.prank(debtor);
        weth.approve(address(bullaFrendLend), interestBefore);
        vm.prank(debtor);
        bullaFrendLend.payLoan(claimId, interestBefore);

        // Check loan state after payment
        Loan memory loanAfter = bullaFrendLend.getLoan(claimId);
        assertEq(
            loanAfter.interestComputationState.accruedInterest,
            0,
            "Accrued interest should be zero after full interest payment"
        );
        assertEq(
            loanAfter.interestComputationState.latestPeriodNumber,
            periodNumberBefore,
            "Period number should remain unchanged after payment"
        );
        assertEq(loanAfter.paidAmount, 0, "Principal paid amount should remain 0 when only interest is paid");
    }

    function testLoanInterestDecrementAfterPartialInterestPayment() public {
        // Setup loan with interest
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 1 ether);

        LoanRequestParams memory offer = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withLoanAmount(1 ether).withTermLength(30 days).withInterestRate(1200, 12) // 12% annual, monthly compounding
            .build();

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan(offer);

        bullaClaim.approvalRegistry().permitCreateClaim({
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
        uint256 claimId = bullaFrendLend.acceptLoan{value: FEE}(loanId);

        // Fast forward to accrue interest
        vm.warp(block.timestamp + 120 days); // 4 months overdue

        // Check interest before payment
        Loan memory loanBefore = bullaFrendLend.getLoan(claimId);
        uint256 interestBefore = loanBefore.interestComputationState.accruedInterest;

        assertTrue(interestBefore > 0, "Interest should have accrued after due date");

        // Pay half of the interest
        uint256 halfInterest = interestBefore / 2;
        vm.prank(debtor);
        weth.approve(address(bullaFrendLend), halfInterest);
        vm.prank(debtor);
        bullaFrendLend.payLoan(claimId, halfInterest);

        // Check loan state after payment
        Loan memory loanAfter = bullaFrendLend.getLoan(claimId);
        assertApproxEqRel(
            loanAfter.interestComputationState.accruedInterest,
            halfInterest,
            0.01e18,
            "Accrued interest should be approximately half after partial payment"
        );
        assertEq(loanAfter.paidAmount, 0, "Principal paid amount should remain 0 when only interest is paid");
    }

    function testLoanInterestAndPrincipalPaymentTogether() public {
        // Setup loan with interest
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 1 ether);

        LoanRequestParams memory offer = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withLoanAmount(1 ether).withTermLength(30 days).withInterestRate(1200, 12) // 12% annual, monthly compounding
            .build();

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan(offer);

        bullaClaim.approvalRegistry().permitCreateClaim({
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
        uint256 claimId = bullaFrendLend.acceptLoan{value: FEE}(loanId);

        // Fast forward to accrue interest
        vm.warp(block.timestamp + 60 days); // 2 months overdue

        // Check interest before payment
        Loan memory loanBefore = bullaFrendLend.getLoan(claimId);
        uint256 interestBefore = loanBefore.interestComputationState.accruedInterest;

        assertTrue(interestBefore > 0, "Interest should have accrued after due date");

        // Pay all interest + half principal
        uint256 halfPrincipal = 0.5 ether;
        uint256 totalPayment = interestBefore + halfPrincipal;

        vm.prank(debtor);
        weth.approve(address(bullaFrendLend), totalPayment);
        vm.prank(debtor);
        bullaFrendLend.payLoan(claimId, totalPayment);

        // Check loan state after payment
        Loan memory loanAfter = bullaFrendLend.getLoan(claimId);
        assertEq(
            loanAfter.interestComputationState.accruedInterest,
            0,
            "Accrued interest should be zero after full interest payment"
        );
        assertEq(loanAfter.paidAmount, halfPrincipal, "Half of principal should be paid");
        assertEq(loanAfter.claimAmount - loanAfter.paidAmount, 0.5 ether, "Remaining principal should be 0.5 ether");
    }

    // ========================================
    // Total Gross Interest Paid Test Cases
    // ========================================

    function testTotalGrossInterestPaid_SingleFullPayment() public {
        // Setup loan with interest
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 1 ether);

        LoanRequestParams memory offer = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withLoanAmount(1 ether).withTermLength(30 days).withInterestRate(1200, 12) // 12% annual, monthly compounding
            .build();

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan(offer);

        bullaClaim.approvalRegistry().permitCreateClaim({
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
        uint256 claimId = bullaFrendLend.acceptLoan{value: FEE}(loanId);

        // Initially, no interest should be paid
        Loan memory initialLoan = bullaFrendLend.getLoan(claimId);
        assertEq(
            initialLoan.interestComputationState.totalGrossInterestPaid,
            0,
            "Initial total gross interest paid should be zero"
        );

        // Fast forward to accrue interest
        vm.warp(block.timestamp + 60 days); // 2 months overdue

        (uint256 remainingPrincipal, uint256 currentInterest) = bullaFrendLend.getTotalAmountDue(claimId);
        uint256 totalPayment = remainingPrincipal + currentInterest;

        vm.prank(debtor);
        weth.approve(address(bullaFrendLend), totalPayment);
        vm.prank(debtor);
        bullaFrendLend.payLoan(claimId, totalPayment);

        // Check total gross interest paid
        Loan memory finalLoan = bullaFrendLend.getLoan(claimId);
        assertEq(
            finalLoan.interestComputationState.totalGrossInterestPaid,
            currentInterest,
            "Total gross interest paid should equal current interest"
        );
    }

    function testTotalGrossInterestPaid_MultiplePartialPayments() public {
        // Setup loan with interest
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 1 ether);

        LoanRequestParams memory offer = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withLoanAmount(1 ether).withTermLength(30 days).withInterestRate(1200, 12) // 12% annual, monthly compounding
            .build();

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan(offer);

        bullaClaim.approvalRegistry().permitCreateClaim({
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
        uint256 claimId = bullaFrendLend.acceptLoan{value: FEE}(loanId);

        uint256 totalInterestPaid = 0;

        // First payment - interest only
        vm.warp(block.timestamp + 30 days);
        (, uint256 interest1) = bullaFrendLend.getTotalAmountDue(claimId);

        vm.prank(debtor);
        weth.approve(address(bullaFrendLend), interest1);
        vm.prank(debtor);
        bullaFrendLend.payLoan(claimId, interest1);

        totalInterestPaid += interest1;
        Loan memory loanAfterPayment1 = bullaFrendLend.getLoan(claimId);
        assertEq(
            loanAfterPayment1.interestComputationState.totalGrossInterestPaid,
            totalInterestPaid,
            "Total gross interest paid should equal first interest payment"
        );

        // Second payment - more interest accrued
        vm.warp(block.timestamp + 30 days);
        (, uint256 interest2) = bullaFrendLend.getTotalAmountDue(claimId);

        vm.prank(debtor);
        weth.approve(address(bullaFrendLend), interest2);
        vm.prank(debtor);
        bullaFrendLend.payLoan(claimId, interest2);

        totalInterestPaid += interest2;
        Loan memory loanAfterPayment2 = bullaFrendLend.getLoan(claimId);
        assertEq(
            loanAfterPayment2.interestComputationState.totalGrossInterestPaid,
            totalInterestPaid,
            "Total gross interest paid should equal sum of both interest payments"
        );

        // Final payment - remaining principal plus any new interest
        (, uint256 interest3) = bullaFrendLend.getTotalAmountDue(claimId);
        (uint256 remainingPrincipal,) = bullaFrendLend.getTotalAmountDue(claimId);
        uint256 finalPayment = remainingPrincipal + interest3;

        vm.prank(debtor);
        weth.approve(address(bullaFrendLend), finalPayment);
        vm.prank(debtor);
        bullaFrendLend.payLoan(claimId, finalPayment);

        totalInterestPaid += interest3;
        Loan memory loanAfterFinalPayment = bullaFrendLend.getLoan(claimId);
        assertEq(
            loanAfterFinalPayment.interestComputationState.totalGrossInterestPaid,
            totalInterestPaid,
            "Total gross interest paid should equal sum of all interest payments"
        );
    }

    function testTotalGrossInterestPaid_PrincipalOnlyPayment() public {
        // Setup loan without interest
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 1 ether);

        LoanRequestParams memory offer = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withLoanAmount(1 ether).withTermLength(365 days).withInterestRate(0, 1) // 0% interest
            .build();

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan(offer);

        bullaClaim.approvalRegistry().permitCreateClaim({
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
        uint256 claimId = bullaFrendLend.acceptLoan{value: FEE}(loanId);

        // Pay principal only (should be no interest)
        vm.prank(debtor);
        weth.approve(address(bullaFrendLend), 1 ether);
        vm.prank(debtor);
        bullaFrendLend.payLoan(claimId, 1 ether);

        // Total gross interest paid should remain zero
        Loan memory paidLoan = bullaFrendLend.getLoan(claimId);
        assertEq(
            paidLoan.interestComputationState.totalGrossInterestPaid,
            0,
            "Total gross interest paid should be zero for principal-only payment"
        );
    }

    function testTotalGrossInterestPaid_MultipleDifferentLoans() public {
        // Setup two different loans
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 3 ether);

        LoanRequestParams memory offer1 = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withLoanAmount(1 ether).withTermLength(30 days).withInterestRate(1000, 12)
            .withDescription("Loan 1") // 10% annual
            .build();

        LoanRequestParams memory offer2 = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withLoanAmount(2 ether).withTermLength(30 days).withInterestRate(1500, 12)
            .withDescription("Loan 2") // 15% annual
            .build();

        vm.prank(creditor);
        uint256 loanId1 = bullaFrendLend.offerLoan(offer1);

        vm.prank(creditor);
        uint256 loanId2 = bullaFrendLend.offerLoan(offer2);

        bullaClaim.approvalRegistry().permitCreateClaim({
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

        vm.prank(debtor);
        uint256 claimId1 = bullaFrendLend.acceptLoan{value: FEE}(loanId1);

        vm.prank(debtor);
        uint256 claimId2 = bullaFrendLend.acceptLoan{value: FEE}(loanId2);

        // Fast forward to accrue interest
        vm.warp(block.timestamp + 60 days);

        // Pay interest on loan 1
        (, uint256 interest1) = bullaFrendLend.getTotalAmountDue(claimId1);
        vm.prank(debtor);
        weth.approve(address(bullaFrendLend), interest1);
        vm.prank(debtor);
        bullaFrendLend.payLoan(claimId1, interest1);

        // Pay interest on loan 2
        (, uint256 interest2) = bullaFrendLend.getTotalAmountDue(claimId2);
        vm.prank(debtor);
        weth.approve(address(bullaFrendLend), interest2);
        vm.prank(debtor);
        bullaFrendLend.payLoan(claimId2, interest2);

        // Verify both loans track interest independently
        Loan memory loan1 = bullaFrendLend.getLoan(claimId1);
        Loan memory loan2 = bullaFrendLend.getLoan(claimId2);

        assertEq(
            loan1.interestComputationState.totalGrossInterestPaid,
            interest1,
            "Loan 1 total gross interest should be tracked independently"
        );

        assertEq(
            loan2.interestComputationState.totalGrossInterestPaid,
            interest2,
            "Loan 2 total gross interest should be tracked independently"
        );

        assertGt(interest2, interest1, "Loan 2 should have higher interest due to higher rate and amount");
    }

    // ========================================
    // Simple Interest Test Cases
    // ========================================

    function testLoanSimpleInterest() public {
        // Set protocol fee to 0 for cleaner calculations
        vm.prank(admin);
        bullaFrendLend.setProtocolFee(0);

        // Setup loan with simple interest (numberOfPeriodsPerYear = 0)
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 1 ether);

        LoanRequestParams memory offer = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withLoanAmount(1 ether).withTermLength(30 days).withInterestRateBps(1000)
            .withNumberOfPeriodsPerYear(0) // 10% annual simple interest
            .build();

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan(offer);

        bullaClaim.approvalRegistry().permitCreateClaim({
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
        uint256 claimId = bullaFrendLend.acceptLoan{value: FEE}(loanId);

        // Get the acceptance date for calculations
        Loan memory initialLoan = bullaFrendLend.getLoan(claimId);
        uint256 acceptedAt = initialLoan.acceptedAt;

        // Test 1: Right after acceptance - should have no interest
        Loan memory loanAtAcceptance = bullaFrendLend.getLoan(claimId);
        assertEq(
            loanAtAcceptance.interestComputationState.accruedInterest,
            0,
            "No interest should accrue immediately after acceptance"
        );

        // Test 2: Partial day should not accrue interest
        vm.warp(acceptedAt + 12 hours); // 12 hours after acceptance

        Loan memory loanPartialDay = bullaFrendLend.getLoan(claimId);
        assertEq(
            loanPartialDay.interestComputationState.accruedInterest, 0, "No interest should accrue for partial days"
        );
        assertEq(
            loanPartialDay.interestComputationState.latestPeriodNumber, 0, "Period number should be 0 for partial days"
        );

        // Test 3: 10 complete days should accrue interest
        vm.warp(acceptedAt + 10 days);

        Loan memory loan10Days = bullaFrendLend.getLoan(claimId);

        // For simple interest: Interest = Principal × Rate × Time
        // Expected: 1 ether × 10% × (10/365) year ≈ 0.00274 ether
        assertApproxEqAbs(
            loan10Days.interestComputationState.accruedInterest,
            2739726027397260, // Expected value in wei
            10000, // Allow for rounding errors
            "Simple interest should be calculated correctly for 10 days"
        );
        assertEq(
            loan10Days.interestComputationState.latestPeriodNumber,
            0,
            "Period number should remain 0 for simple interest"
        );

        // Test 4: 365 days (1 year) should accrue 10% interest
        vm.warp(acceptedAt + 365 days);

        Loan memory loan1Year = bullaFrendLend.getLoan(claimId);
        assertEq(
            loan1Year.interestComputationState.accruedInterest,
            0.1 ether,
            "Simple interest should be exactly 10% for 1 year"
        );
        assertEq(
            loan1Year.interestComputationState.latestPeriodNumber,
            0,
            "Period number should remain 0 for simple interest"
        );

        // Test 5: 730 days (2 years) should accrue 20% interest (linear growth)
        vm.warp(acceptedAt + 730 days);

        Loan memory loan2Years = bullaFrendLend.getLoan(claimId);
        assertEq(
            loan2Years.interestComputationState.accruedInterest,
            0.2 ether,
            "Simple interest should be exactly 20% for 2 years (linear growth)"
        );
        assertEq(
            loan2Years.interestComputationState.latestPeriodNumber,
            0,
            "Period number should remain 0 for simple interest"
        );

        // Test 6: Verify simple interest behavior is linear
        assertEq(
            loan2Years.interestComputationState.accruedInterest,
            2 * loan1Year.interestComputationState.accruedInterest,
            "Simple interest should be linear - 2 years should be exactly double 1 year"
        );
    }

    function testLoanSimpleVsCompoundInterest() public {
        // Set protocol fee to 0 for cleaner calculations
        vm.prank(admin);
        bullaFrendLend.setProtocolFee(0);

        // Setup two identical loans, one with simple interest, one with compound
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 2 ether);

        // Simple interest loan (numberOfPeriodsPerYear = 0)
        LoanRequestParams memory simpleOffer = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withLoanAmount(1 ether).withTermLength(30 days).withInterestRateBps(1200)
            .withNumberOfPeriodsPerYear(0).withDescription("Simple Interest Loan") // 12% annual simple interest
            .build();

        // Compound interest loan (numberOfPeriodsPerYear = 12)
        LoanRequestParams memory compoundOffer = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(
            debtor
        ).withToken(address(weth)).withLoanAmount(1 ether).withTermLength(30 days).withInterestRateBps(1200)
            .withNumberOfPeriodsPerYear(12).withDescription("Compound Interest Loan") // 12% annual compound interest, monthly
            .build();

        vm.prank(creditor);
        uint256 simpleLoanId = bullaFrendLend.offerLoan(simpleOffer);

        vm.prank(creditor);
        uint256 compoundLoanId = bullaFrendLend.offerLoan(compoundOffer);

        bullaClaim.approvalRegistry().permitCreateClaim({
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

        vm.prank(debtor);
        uint256 simpleClaimId = bullaFrendLend.acceptLoan{value: FEE}(simpleLoanId);

        vm.prank(debtor);
        uint256 compoundClaimId = bullaFrendLend.acceptLoan{value: FEE}(compoundLoanId);

        // Fast forward to 1 year after loan acceptance
        Loan memory simpleLoanInitial = bullaFrendLend.getLoan(simpleClaimId);
        vm.warp(simpleLoanInitial.acceptedAt + 365 days);

        Loan memory simpleLoan = bullaFrendLend.getLoan(simpleClaimId);
        Loan memory compoundLoan = bullaFrendLend.getLoan(compoundClaimId);

        // Simple interest should be exactly 12% (linear)
        assertEq(
            simpleLoan.interestComputationState.accruedInterest,
            0.12 ether,
            "Simple interest should be exactly 12% for 1 year"
        );
        assertEq(
            simpleLoan.interestComputationState.latestPeriodNumber, 0, "Simple interest should have period number 0"
        );

        // Compound interest should be higher than simple interest
        assertTrue(
            compoundLoan.interestComputationState.accruedInterest > simpleLoan.interestComputationState.accruedInterest,
            "Compound interest should be higher than simple interest over time"
        );
        assertTrue(
            compoundLoan.interestComputationState.latestPeriodNumber > 0,
            "Compound interest should have period number > 0"
        );
    }
}
