pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import "contracts/types/Types.sol";
import {WETH} from "contracts/mocks/weth.sol";
import {EIP712Helper} from "test/foundry/BullaClaim/EIP712/Utils.sol";
import {BullaClaim} from "contracts/BullaClaim.sol";
import {
    BullaFrendLend,
    LoanRequestParams,
    Loan,
    LoanOffer,
    LoanOfferExpired,
    IncorrectFee,
    NotCreditor,
    NotDebtor,
    LoanOfferNotFound
} from "src/BullaFrendLend.sol";
import {Deployer} from "script/Deployment.s.sol";
import {LoanRequestParamsBuilder} from "./LoanRequestParamsBuilder.t.sol";
import {BullaFrendLendTestHelper} from "./BullaFrendLendTestHelper.sol";

contract TestLoanOfferExpiry is BullaFrendLendTestHelper {
    // Events for testing
    event LoanOffered(
        uint256 indexed loanId, address indexed offeredBy, LoanRequestParams loanOffer, uint256 originationFee
    );
    event LoanOfferAccepted(uint256 indexed loanId, uint256 indexed claimId);

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

        bullaClaim = (new Deployer()).deploy_test({
            _deployer: address(this),
            _initialLockState: LockState.Unlocked,
            _coreProtocolFee: FEE
        });
        sigHelper = new EIP712Helper(address(bullaClaim));
        approvalRegistry = bullaClaim.approvalRegistry();
        bullaFrendLend = new BullaFrendLend(address(bullaClaim), admin, PROTOCOL_FEE_BPS);

        vm.deal(creditor, 10 ether);
        vm.deal(debtor, 10 ether);

        // Setup WETH for tests
        vm.prank(creditor);
        weth.deposit{value: 5 ether}();

        vm.prank(debtor);
        weth.deposit{value: 5 ether}();
    }

    /*///////////////////// BASIC EXPIRY FUNCTIONALITY TESTS /////////////////////*/

    function testOfferLoan_WithoutExpiry() public {
        // Test that offers without expiry (expiresAt = 0) work normally
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 1 ether);

        LoanRequestParams memory offer = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withExpiresAt(0) // No expiry
            .build();

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan(offer);

        LoanOffer memory loanOffer = bullaFrendLend.getLoanOffer(loanId);
        assertEq(loanOffer.params.expiresAt, 0, "Should have no expiry");
        assertTrue(loanOffer.requestedByCreditor, "Should be requested by creditor");
    }

    function testOfferLoan_WithFutureExpiry() public {
        // Test that offers with future expiry work normally
        uint256 futureExpiry = block.timestamp + 1 days;

        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 1 ether);

        LoanRequestParams memory offer = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withExpiresAt(futureExpiry).build();

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan(offer);

        LoanOffer memory loanOffer = bullaFrendLend.getLoanOffer(loanId);
        assertEq(loanOffer.params.expiresAt, futureExpiry, "Should have correct expiry time");
        assertTrue(loanOffer.requestedByCreditor, "Should be requested by creditor");
    }

    function testOfferLoan_WithPastExpiry_ShouldFail() public {
        vm.warp(block.timestamp + 2 hours);
        uint256 pastExpiry = block.timestamp - 1 hours;

        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 1 ether);

        LoanRequestParams memory offer = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withExpiresAt(pastExpiry).build();

        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(LoanOfferExpired.selector));
        bullaFrendLend.offerLoan(offer);
    }

    /*///////////////////// LOAN ACCEPTANCE EXPIRY TESTS /////////////////////*/

    function testAcceptLoan_BeforeExpiry_Success() public {
        // Test that loans can be accepted before expiry
        uint256 futureExpiry = block.timestamp + 1 hours;

        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 1 ether);

        LoanRequestParams memory offer = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withExpiresAt(futureExpiry).build();

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan(offer);

        // Accept the loan before expiry
        _permitAcceptLoan(debtorPK);

        vm.prank(debtor);
        uint256 claimId = bullaFrendLend.acceptLoan{value: FEE}(loanId);

        // Verify loan was accepted successfully
        assertTrue(claimId > 0, "Claim should be created");

        // Verify offer was deleted after acceptance
        LoanOffer memory deletedOffer = bullaFrendLend.getLoanOffer(loanId);
        assertEq(deletedOffer.params.creditor, address(0), "Offer should be deleted");
    }

    function testAcceptLoan_AfterExpiry_ShouldFail() public {
        // Test that loans cannot be accepted after expiry
        uint256 shortExpiry = block.timestamp + 1 hours;

        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 1 ether);

        LoanRequestParams memory offer = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withExpiresAt(shortExpiry).build();

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan(offer);

        // Move time forward past expiry
        vm.warp(block.timestamp + 2 hours);

        // Try to accept the expired loan
        _permitAcceptLoan(debtorPK);

        vm.prank(debtor);
        vm.expectRevert(abi.encodeWithSelector(LoanOfferExpired.selector));
        bullaFrendLend.acceptLoan{value: FEE}(loanId);
    }

    function testAcceptLoan_AtExactExpiryTime_ShouldFail() public {
        // Test that loans cannot be accepted at exact expiry time
        uint256 exactExpiry = block.timestamp + 1 hours;

        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 1 ether);

        LoanRequestParams memory offer = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withExpiresAt(exactExpiry).build();

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan(offer);

        // Move time forward to exact expiry
        vm.warp(exactExpiry);

        // Try to accept at exact expiry time
        _permitAcceptLoan(debtorPK);

        vm.prank(debtor);
        vm.warp(exactExpiry + 1);
        vm.expectRevert(abi.encodeWithSelector(LoanOfferExpired.selector));
        bullaFrendLend.acceptLoan{value: FEE}(loanId);
    }

    /*///////////////////// DEBTOR REQUEST EXPIRY TESTS /////////////////////*/

    function testDebtorRequest_WithExpiry() public {
        // Test that debtor can create loan requests with expiry
        uint256 futureExpiry = block.timestamp + 2 days;

        LoanRequestParams memory request = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withExpiresAt(futureExpiry).build();

        vm.prank(debtor);
        uint256 requestId = bullaFrendLend.offerLoan(request);

        LoanOffer memory loanRequest = bullaFrendLend.getLoanOffer(requestId);
        assertEq(loanRequest.params.expiresAt, futureExpiry, "Should have correct expiry");
        assertFalse(loanRequest.requestedByCreditor, "Should be requested by debtor");
    }

    function testDebtorRequest_AcceptAfterExpiry_ShouldFail() public {
        // Test that creditor cannot accept debtor request after expiry
        uint256 shortExpiry = block.timestamp + 30 minutes;

        LoanRequestParams memory request = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withExpiresAt(shortExpiry).build();

        vm.prank(debtor);
        uint256 requestId = bullaFrendLend.offerLoan(request);

        // Move time forward past expiry
        vm.warp(block.timestamp + 1 hours);

        // Try to accept the expired request
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 1 ether);
        _permitAcceptLoan(creditorPK);

        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(LoanOfferExpired.selector));
        bullaFrendLend.acceptLoan{value: FEE}(requestId);
    }

    /*///////////////////// EDGE CASES AND BOUNDARY TESTS /////////////////////*/

    function testMultipleOffers_DifferentExpiryTimes() public {
        // Test multiple offers with different expiry times
        uint256 shortExpiry = block.timestamp + 30 minutes;
        uint256 longExpiry = block.timestamp + 2 days;

        vm.startPrank(creditor);
        weth.approve(address(bullaFrendLend), 3 ether);

        // Create offer with short expiry
        LoanRequestParams memory shortOffer = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withLoanAmount(1 ether).withExpiresAt(shortExpiry).build();

        uint256 shortLoanId = bullaFrendLend.offerLoan(shortOffer);

        // Create offer with long expiry
        LoanRequestParams memory longOffer = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withLoanAmount(2 ether).withExpiresAt(longExpiry).build();

        uint256 longLoanId = bullaFrendLend.offerLoan(longOffer);
        vm.stopPrank();

        // Move time forward past short expiry but before long expiry
        vm.warp(block.timestamp + 1 hours);

        _permitAcceptLoan(debtorPK, 2);

        // Try to accept short offer (should fail)
        vm.prank(debtor);
        vm.expectRevert(abi.encodeWithSelector(LoanOfferExpired.selector));
        bullaFrendLend.acceptLoan{value: FEE}(shortLoanId);

        // Accept long offer (should succeed)
        vm.prank(debtor);
        uint256 claimId = bullaFrendLend.acceptLoan{value: FEE}(longLoanId);
        assertTrue(claimId > 0, "Long offer should be accepted successfully");
    }

    function testOfferWithMetadata_Expiry() public {
        // Test that offers with metadata also respect expiry
        uint256 futureExpiry = block.timestamp + 1 days;
        ClaimMetadata memory metadata = ClaimMetadata({
            tokenURI: "https://example.com/token/123",
            attachmentURI: "https://example.com/attachment/123"
        });

        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 1 ether);

        LoanRequestParams memory offer = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withExpiresAt(futureExpiry).build();

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoanWithMetadata(offer, metadata);

        // Verify offer was created with correct expiry
        LoanOffer memory loanOffer = bullaFrendLend.getLoanOffer(loanId);
        assertEq(loanOffer.params.expiresAt, futureExpiry, "Should have correct expiry");

        // Verify metadata was stored
        ClaimMetadata memory storedMetadata = bullaFrendLend.getLoanOfferMetadata(loanId);
        assertEq(storedMetadata.tokenURI, metadata.tokenURI, "Token URI should match");
        assertEq(storedMetadata.attachmentURI, metadata.attachmentURI, "Attachment URI should match");

        // Move past expiry and try to accept
        vm.warp(futureExpiry + 1);
        _permitAcceptLoan(debtorPK);

        vm.prank(debtor);
        vm.expectRevert(abi.encodeWithSelector(LoanOfferExpired.selector));
        bullaFrendLend.acceptLoan{value: FEE}(loanId);
    }

    function testRejectExpiredOffer_ShouldStillWork() public {
        // Test that expired offers can still be rejected/rescinded
        uint256 shortExpiry = block.timestamp + 30 minutes;

        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 1 ether);

        LoanRequestParams memory offer = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withExpiresAt(shortExpiry).build();

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan(offer);

        // Move time forward past expiry
        vm.warp(block.timestamp + 1 hours);

        // Rejecting should still work even after expiry
        vm.prank(creditor);
        bullaFrendLend.rejectLoanOffer(loanId);

        // Verify offer was deleted
        LoanOffer memory deletedOffer = bullaFrendLend.getLoanOffer(loanId);
        assertEq(deletedOffer.params.creditor, address(0), "Offer should be deleted");
    }

    /*///////////////////// BATCH OPERATIONS WITH EXPIRY /////////////////////*/

    function testBatchOfferLoans_WithExpiry() public {
        // Test batch loan offers with expiry times
        uint256 futureExpiry = block.timestamp + 1 days;

        bytes[] memory calls = new bytes[](2);

        calls[0] = abi.encodeCall(
            BullaFrendLend.offerLoan,
            (
                new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth))
                    .withLoanAmount(1 ether).withExpiresAt(futureExpiry).build()
            )
        );

        calls[1] = abi.encodeCall(
            BullaFrendLend.offerLoan,
            (
                new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth))
                    .withLoanAmount(2 ether).withExpiresAt(futureExpiry + 1 days).build()
            )
        );

        vm.prank(creditor);
        bullaFrendLend.batch(calls, true);

        // Verify both offers were created with correct expiry times
        LoanOffer memory offer1 = bullaFrendLend.getLoanOffer(1);
        LoanOffer memory offer2 = bullaFrendLend.getLoanOffer(2);

        assertEq(offer1.params.expiresAt, futureExpiry, "First offer should have correct expiry");
        assertEq(offer2.params.expiresAt, futureExpiry + 1 days, "Second offer should have correct expiry");
        assertEq(bullaFrendLend.loanOfferCount(), 2, "Should have created 2 offers");
    }

    function testBatchOfferLoans_WithPastExpiry_ShouldFail() public {
        vm.warp(block.timestamp + 2 hours);
        uint256 pastExpiry = block.timestamp - 1 hours;
        uint256 futureExpiry = block.timestamp + 1 days;

        bytes[] memory calls = new bytes[](2);

        calls[0] = abi.encodeCall(
            BullaFrendLend.offerLoan,
            (
                new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth))
                    .withExpiresAt(futureExpiry).build()
            )
        );

        calls[1] = abi.encodeCall(
            BullaFrendLend.offerLoan,
            (
                new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth))
                    .withExpiresAt(pastExpiry) // This should cause failure
                    .build()
            )
        );

        vm.prank(creditor);
        vm.expectRevert("Transaction reverted silently");
        bullaFrendLend.batch(calls, true);

        // Verify no offers were created due to revert
        assertEq(bullaFrendLend.loanOfferCount(), 0, "No offers should be created");
    }

    /*///////////////////// TIME MANIPULATION TESTS /////////////////////*/

    function testExpiryBoundaryConditions() public {
        // Test expiry exactly at block.timestamp
        uint256 currentTime = block.timestamp;

        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 1 ether);

        LoanRequestParams memory offer = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withExpiresAt(currentTime).build();

        // Creating at current time should still work (not yet expired)
        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan(offer);

        // But accepting should fail because block.timestamp > expiresAt when we move forward
        vm.warp(currentTime + 1);
        _permitAcceptLoan(debtorPK);

        vm.prank(debtor);
        vm.expectRevert(abi.encodeWithSelector(LoanOfferExpired.selector));
        bullaFrendLend.acceptLoan{value: FEE}(loanId);
    }

    function testLargeExpiryTimestamp() public {
        // Test with a very large expiry timestamp (far in the future)
        uint256 farFutureExpiry = block.timestamp + 365 days * 100; // 100 years in the future

        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 1 ether);

        LoanRequestParams memory offer = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withExpiresAt(farFutureExpiry).build();

        vm.prank(creditor);
        uint256 loanId = bullaFrendLend.offerLoan(offer);

        // Should be able to accept even after moving forward significantly
        vm.warp(block.timestamp + 365 days); // 1 year later
        _permitAcceptLoan(debtorPK);

        vm.prank(debtor);
        uint256 claimId = bullaFrendLend.acceptLoan{value: FEE}(loanId);
        assertTrue(claimId > 0, "Should be able to accept with far future expiry");
    }
}
