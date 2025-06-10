// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.14;

import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import {WETH} from "contracts/mocks/weth.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC20PermitMock} from "openzeppelin-contracts/contracts/mocks/ERC20PermitMock.sol";
import {
    Claim,
    Status,
    ClaimBinding,
    CreateClaimParams,
    LockState,
    ClaimMetadata,
    CreateClaimApprovalType,
    PayClaimApprovalType,
    ClaimPaymentApprovalParam
} from "contracts/types/Types.sol";
import {BullaClaim} from "contracts/BullaClaim.sol";
import {BullaFrendLend, LoanRequestParams, Loan, LoanOffer} from "src/BullaFrendLend.sol";
import {Deployer} from "script/Deployment.s.sol";
import {BullaFrendLendTestHelper} from "test/foundry/BullaFrendLend/BullaFrendLendTestHelper.sol";
import {EIP712Helper} from "test/foundry/BullaClaim/BullaClaimTestHelper.sol";
import {LoanRequestParamsBuilder} from "test/foundry/BullaFrendLend/LoanRequestParamsBuilder.t.sol";

contract TestBullaFrendLendBatchFunctionality is BullaFrendLendTestHelper {
    uint256 creditorPK = uint256(0x01);
    uint256 debtorPK = uint256(0x02);
    uint256 charliePK = uint256(0x03);
    uint256 adminPK = uint256(0x05);
    
    address creditor = vm.addr(creditorPK);
    address debtor = vm.addr(debtorPK);
    address charlie = vm.addr(charliePK);
    address admin = vm.addr(adminPK);
    
    ERC20PermitMock public permitToken;
    
    uint256 constant FEE = 0.01 ether;
    uint256 constant PROTOCOL_FEE_BPS = 1000; // 10%
    
    function setUp() public {
        weth = new WETH();
        permitToken = new ERC20PermitMock("PermitToken", "PT", address(this), 1000000 ether);

        vm.label(address(this), "TEST_CONTRACT");
        vm.label(creditor, "CREDITOR");
        vm.label(debtor, "DEBTOR");
        vm.label(charlie, "CHARLIE");
        vm.label(admin, "ADMIN");

        bullaClaim = (new Deployer()).deploy_test({_deployer: address(this), _initialLockState: LockState.Unlocked});
        sigHelper = new EIP712Helper(address(bullaClaim));
        bullaFrendLend = new BullaFrendLend(address(bullaClaim), admin, FEE, PROTOCOL_FEE_BPS);

        // Setup ETH balances for fees and WETH deposits
        vm.deal(creditor, 10000 ether);
        vm.deal(debtor, 10000 ether);
        vm.deal(charlie, 10000 ether);

        // Setup WETH tokens by depositing ETH
        vm.prank(creditor);
        weth.deposit{value: 5000 ether}();
        
        vm.prank(debtor);
        weth.deposit{value: 5000 ether}();
        
        vm.prank(charlie);
        weth.deposit{value: 5000 ether}();
        
        // Setup permit tokens
        permitToken.transfer(creditor, 10000 ether);
        permitToken.transfer(debtor, 10000 ether);
        permitToken.transfer(charlie, 10000 ether);
    }

    /*///////////////////// HELPER FUNCTIONS /////////////////////*/

    function _getUserPK(address user) internal view returns (uint256) {
        if (user == creditor) return creditorPK;
        if (user == debtor) return debtorPK;
        if (user == charlie) return charliePK;
        if (user == admin) return adminPK;
        return 12345; // default
    }

    /*///////////////////// BASIC BATCH FUNCTIONALITY TESTS /////////////////////*/

    function testBatch_EmptyArray() public {
        bytes[] memory calls = new bytes[](0);
        
        // Should not revert with empty array
        bullaFrendLend.batch(calls, true);
        bullaFrendLend.batch(calls, false);
    }

    function testBatch_SingleLoanOffer() public {
        bytes[] memory calls = new bytes[](1);
        
        // Create a single loan offer via batch
        calls[0] = abi.encodeCall(
            BullaFrendLend.offerLoan,
            (new LoanRequestParamsBuilder()
                .withCreditor(creditor)
                .withDebtor(debtor)
                .withToken(address(weth))
                .build())
        );
        
        vm.prank(creditor);
        bullaFrendLend.batch{value: FEE}(calls, true);
        
        // Verify loan offer was created
        (LoanRequestParams memory params, bool requestedByCreditor) = bullaFrendLend.loanOffers(1);
        assertEq(params.creditor, creditor);
        assertEq(params.debtor, debtor);
        assertTrue(requestedByCreditor);
        assertEq(bullaFrendLend.loanOfferCount(), 1);
    }

    function testBatch_RevertOnFail_True() public {
        bytes[] memory calls = new bytes[](2);
        
        // First call succeeds
        calls[0] = abi.encodeCall(
            BullaFrendLend.offerLoan,
            (new LoanRequestParamsBuilder()
                .withCreditor(creditor)
                .withDebtor(debtor)
                .withToken(address(weth))
                .build())
        );
        
        // Second call fails (invalid term length)
        calls[1] = abi.encodeCall(
            BullaFrendLend.offerLoan,
            (new LoanRequestParamsBuilder()
                .withCreditor(creditor)
                .withDebtor(debtor)
                .withToken(address(weth))
                .withTermLength(0)
                .build())
        );
        
        vm.prank(creditor);
        vm.expectRevert("Transaction reverted silently");
        bullaFrendLend.batch{value: FEE * 2}(calls, true);
        
        // Verify no loan offers were created due to revert
        assertEq(bullaFrendLend.loanOfferCount(), 0);
    }

    function testBatch_RevertOnFail_False() public {
        // Create multiple valid loan offers first using individual calls
        vm.startPrank(creditor);
        uint256 validOfferId1 = bullaFrendLend.offerLoan{value: FEE}(
            new LoanRequestParamsBuilder()
                .withCreditor(creditor)
                .withDebtor(debtor)
                .withToken(address(weth))
                .build()
        );
        uint256 validOfferId2 = bullaFrendLend.offerLoan{value: FEE}(
            new LoanRequestParamsBuilder()
                .withCreditor(creditor)
                .withDebtor(charlie)
                .withToken(address(weth))
                .build()
        );
        vm.stopPrank();
        
        bytes[] memory calls = new bytes[](3);
        
        // First call is valid (creditor rejecting their own offer)
        calls[0] = abi.encodeCall(BullaFrendLend.rejectLoanOffer, (validOfferId1));
        
        // Second call is invalid (trying to reject non-existent offer)
        calls[1] = abi.encodeCall(BullaFrendLend.rejectLoanOffer, (999));
        
        // Third call is valid (creditor rejecting their other offer)
        calls[2] = abi.encodeCall(BullaFrendLend.rejectLoanOffer, (validOfferId2));
        
        vm.prank(creditor);
        bullaFrendLend.batch(calls, false); // revertOnFail = false
        
        // Verify first and third operations succeeded, second failed
        (LoanRequestParams memory params1,) = bullaFrendLend.loanOffers(validOfferId1);
        (LoanRequestParams memory params2,) = bullaFrendLend.loanOffers(validOfferId2);
        
        assertEq(params1.creditor, address(0)); // First offer was deleted
        assertEq(params2.creditor, address(0)); // Third offer was deleted
        
    }

    /*///////////////////// BATCH LOAN OFFER MANAGEMENT TESTS /////////////////////*/

    function testBatch_RejectMultipleLoanOffers() public {
        // Create multiple loan offers first
        vm.startPrank(creditor);
        uint256 loanId1 = bullaFrendLend.offerLoan{value: FEE}(
            new LoanRequestParamsBuilder()
                .withCreditor(creditor)
                .withDebtor(debtor)
                .withToken(address(weth))
                .build()
        );
        uint256 loanId2 = bullaFrendLend.offerLoan{value: FEE}(
            new LoanRequestParamsBuilder()
                .withCreditor(creditor)
                .withDebtor(charlie)
                .withToken(address(weth))
                .build()
        );
        vm.stopPrank();
        
        bytes[] memory calls = new bytes[](2);
        
        calls[0] = abi.encodeCall(BullaFrendLend.rejectLoanOffer, (loanId1));
        calls[1] = abi.encodeCall(BullaFrendLend.rejectLoanOffer, (loanId2));
        
        vm.prank(creditor);
        bullaFrendLend.batch(calls, true);
        
        // Verify all loan offers were rejected (deleted)
        (LoanRequestParams memory params1,) = bullaFrendLend.loanOffers(loanId1);
        (LoanRequestParams memory params2,) = bullaFrendLend.loanOffers(loanId2);
        
        assertEq(params1.creditor, address(0));
        assertEq(params2.creditor, address(0));
    }

    /*///////////////////// BATCH PERMIT TESTS /////////////////////*/

    function testPermitToken_InBatch() public {
        // Simplified test - just test the permit functionality without loan acceptance
        uint256 amount = 1000 ether;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 privateKey = 0x5678;
        address owner = vm.addr(privateKey);
        
        // Transfer tokens to owner
        permitToken.transfer(owner, amount);
        
        // Create permit signature
        (uint8 v, bytes32 r, bytes32 s) = _permitERC20Token(
            privateKey,
            address(permitToken),
            address(bullaClaim),
            amount,
            deadline
        );
        
        bytes[] memory calls = new bytes[](1);
        
        // Single call: permit (test permit functionality in batch)
        calls[0] = abi.encodeWithSignature(
            "permitToken(address,address,address,uint256,uint256,uint8,bytes32,bytes32)",
            address(permitToken), owner, address(bullaClaim), amount, deadline, v, r, s
        );
        
        vm.prank(owner);
        bullaFrendLend.batch(calls, true);
        
        // Verify permit worked
        assertEq(permitToken.allowance(owner, address(bullaClaim)), amount);
    }

    function testPermitToken_ValidSignature() public {
        uint256 amount = 1000 ether;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 privateKey = 0x1234;
        address owner = vm.addr(privateKey);
        
        // Transfer tokens to owner
        permitToken.transfer(owner, amount);
        
        // Create permit signature using helper from BullaFrendLendTestHelper
        (uint8 v, bytes32 r, bytes32 s) = _permitERC20Token(
            privateKey,
            address(permitToken),
            address(bullaClaim),
            amount,
            deadline
        );
        
        // Call permitToken directly (not through batch)
        (bool success,) = address(bullaClaim).call(
            abi.encodeWithSignature(
                "permitToken(address,address,address,uint256,uint256,uint8,bytes32,bytes32)",
                address(permitToken), owner, address(bullaClaim), amount, deadline, v, r, s
            )
        );
        
        assertTrue(success, "permitToken call should succeed");
        
        // Verify allowance was set
        assertEq(permitToken.allowance(owner, address(bullaClaim)), amount);
    }

    /*///////////////////// EDGE CASES /////////////////////*/

    function testBatch_LimitedNumberOfOperations() public {
        // Test with a small number of operations to demonstrate batching without hitting gas limits
        uint256 numRejects = 3;
        
        // Create multiple loan offers individually first
        uint256[] memory offerIds = new uint256[](numRejects);
        
        vm.startPrank(creditor);
        for (uint256 i = 0; i < numRejects; i++) {
            offerIds[i] = bullaFrendLend.offerLoan{value: FEE}(
                new LoanRequestParamsBuilder()
                    .withCreditor(creditor)
                    .withDebtor(address(uint160(0x1000 + i)))
                    .withToken(address(weth))
                    .build()
            );
        }
        vm.stopPrank();
        
        // Now batch reject all offers (no fees required for rejection)
        bytes[] memory calls = new bytes[](numRejects);
        
        for (uint256 i = 0; i < numRejects; i++) {
            calls[i] = abi.encodeCall(BullaFrendLend.rejectLoanOffer, (offerIds[i]));
        }
        
        vm.prank(creditor);
        bullaFrendLend.batch(calls, true);
        
        // Verify all offers were rejected
        for (uint256 i = 0; i < numRejects; i++) {
            (LoanRequestParams memory params,) = bullaFrendLend.loanOffers(offerIds[i]);
            assertEq(params.creditor, address(0)); // Deleted offer has zero address
        }
    }

    /*///////////////////// BATCH LOAN ACCEPTANCE TESTS /////////////////////*/

    function testBatch_AcceptMultipleLoans() public {
        // Create multiple loan offers individually first
        uint256[] memory offerIds = new uint256[](3);
        
        vm.startPrank(creditor);
        weth.approve(address(bullaFrendLend), 3 ether);
        
        offerIds[0] = bullaFrendLend.offerLoan{value: FEE}(
            new LoanRequestParamsBuilder()
                .withCreditor(creditor)
                .withDebtor(debtor)
                .withToken(address(weth))
                .withLoanAmount(1 ether)
                .build()
        );
        offerIds[1] = bullaFrendLend.offerLoan{value: FEE}(
            new LoanRequestParamsBuilder()
                .withCreditor(creditor)
                .withDebtor(charlie)
                .withToken(address(weth))
                .withLoanAmount(1 ether)
                .build()
        );
        offerIds[2] = bullaFrendLend.offerLoan{value: FEE}(
            new LoanRequestParamsBuilder()
                .withCreditor(creditor)
                .withDebtor(debtor)
                .withToken(address(weth))
                .withLoanAmount(1 ether)
                .build()
        );
        vm.stopPrank();

        // Setup permissions for multiple loan acceptances
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

        bullaClaim.permitCreateClaim({
            user: charlie,
            controller: address(bullaFrendLend),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: charliePK,
                user: charlie,
                controller: address(bullaFrendLend),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: true
            })
        });

        // Batch accept loans (no fees required for acceptance)
        bytes[] memory calls = new bytes[](2);
        
        calls[0] = abi.encodeCall(BullaFrendLend.acceptLoan, (offerIds[0]));
        calls[1] = abi.encodeCall(BullaFrendLend.acceptLoan, (offerIds[2]));
        
        vm.prank(debtor);
        bullaFrendLend.batch(calls, true);
        
        // Accept third loan individually
        vm.prank(charlie);
        bullaFrendLend.acceptLoan(offerIds[1]);
        
        // Verify all loans were accepted and claims created
        assertEq(bullaClaim.currentClaimId(), 3);
        
        Claim memory claim1 = bullaClaim.getClaim(1);
        Claim memory claim2 = bullaClaim.getClaim(2);
        Claim memory claim3 = bullaClaim.getClaim(3);
        
        assertEq(claim1.debtor, debtor);  // First accepted loan (offer 1)
        assertEq(claim2.debtor, debtor);  // Second accepted loan (offer 3)
        assertEq(claim3.debtor, charlie); // Third accepted loan (offer 2)
        assertEq(claim1.claimAmount, 1 ether);
        assertEq(claim2.claimAmount, 1 ether);
        assertEq(claim3.claimAmount, 1 ether);
    }

    /*///////////////////// BATCH LOAN PAYMENT TESTS /////////////////////*/

    function testBatch_PayMultipleLoans_ERC20() public {
        // Create and accept loans individually first
        vm.startPrank(creditor);
        weth.approve(address(bullaFrendLend), 3 ether);
        
        uint256 loanId1 = bullaFrendLend.offerLoan{value: FEE}(
            new LoanRequestParamsBuilder()
                .withCreditor(creditor)
                .withDebtor(debtor)
                .withToken(address(weth))
                .withLoanAmount(1 ether)
                .build()
        );
        uint256 loanId2 = bullaFrendLend.offerLoan{value: FEE}(
            new LoanRequestParamsBuilder()
                .withCreditor(creditor)
                .withDebtor(debtor)
                .withToken(address(weth))
                .withLoanAmount(1 ether)
                .build()
        );
        uint256 loanId3 = bullaFrendLend.offerLoan{value: FEE}(
            new LoanRequestParamsBuilder()
                .withCreditor(creditor)
                .withDebtor(debtor)
                .withToken(address(weth))
                .withLoanAmount(1 ether)
                .build()
        );
        vm.stopPrank();

        // Setup permissions for loan acceptance
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

        // Accept loans individually
        vm.startPrank(debtor);
        uint256 claimId1 = bullaFrendLend.acceptLoan(loanId1);
        uint256 claimId2 = bullaFrendLend.acceptLoan(loanId2);
        uint256 claimId3 = bullaFrendLend.acceptLoan(loanId3);
        vm.stopPrank();

        // Setup payment permissions
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

        // Approve tokens for batch payment
        vm.prank(debtor);
        weth.approve(address(bullaFrendLend), 3 ether);

        bytes[] memory calls = new bytes[](3);
        
        calls[0] = abi.encodeCall(BullaFrendLend.payLoan, (claimId1, 1 ether));
        calls[1] = abi.encodeCall(BullaFrendLend.payLoan, (claimId2, 1 ether));
        calls[2] = abi.encodeCall(BullaFrendLend.payLoan, (claimId3, 1 ether));
        
        vm.prank(debtor);
        bullaFrendLend.batch(calls, true);
        
        // Verify all loans were paid
        Claim memory claim1 = bullaClaim.getClaim(claimId1);
        Claim memory claim2 = bullaClaim.getClaim(claimId2);
        Claim memory claim3 = bullaClaim.getClaim(claimId3);
        
        assertEq(uint256(claim1.status), uint256(Status.Paid));
        assertEq(uint256(claim2.status), uint256(Status.Paid));
        assertEq(uint256(claim3.status), uint256(Status.Paid));
    }

    /*///////////////////// BATCH LOAN MANAGEMENT TESTS /////////////////////*/

    function testBatch_ImpairMultipleLoans() public {
        // Create and accept loans with past due dates individually
        uint256 pastDueBy = block.timestamp + 1 days;
        
        vm.startPrank(creditor);
        weth.approve(address(bullaFrendLend), 2 ether);
        
        uint256 loanId1 = bullaFrendLend.offerLoan{value: FEE}(
            new LoanRequestParamsBuilder()
                .withCreditor(creditor)
                .withDebtor(debtor)
                .withToken(address(weth))
                .withTermLength(1 days)
                .withImpairmentGracePeriod(1 hours)
                .build()
        );
        uint256 loanId2 = bullaFrendLend.offerLoan{value: FEE}(
            new LoanRequestParamsBuilder()
                .withCreditor(creditor)
                .withDebtor(charlie)
                .withToken(address(weth))
                .withTermLength(1 days)
                .withImpairmentGracePeriod(1 hours)
                .build()
        );
        vm.stopPrank();

        // Setup permissions for loan acceptance
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

        bullaClaim.permitCreateClaim({
            user: charlie,
            controller: address(bullaFrendLend),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: charliePK,
                user: charlie,
                controller: address(bullaFrendLend),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: true
            })
        });

        // Accept loans individually
        vm.prank(debtor);
        uint256 claimId1 = bullaFrendLend.acceptLoan(loanId1);
        
        vm.prank(charlie);
        uint256 claimId2 = bullaFrendLend.acceptLoan(loanId2);

        // Move time forward past due date and grace period
        vm.warp(block.timestamp + 2 days + 2 hours);

        // Setup impair permissions
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

        bytes[] memory calls = new bytes[](2);
        
        calls[0] = abi.encodeCall(BullaFrendLend.impairLoan, (claimId1));
        calls[1] = abi.encodeCall(BullaFrendLend.impairLoan, (claimId2));
        
        vm.prank(creditor);
        bullaFrendLend.batch(calls, true);
        
        // Verify loans are now impaired
        Claim memory claim1 = bullaClaim.getClaim(claimId1);
        Claim memory claim2 = bullaClaim.getClaim(claimId2);
        
        assertEq(uint256(claim1.status), uint256(Status.Impaired));
        assertEq(uint256(claim2.status), uint256(Status.Impaired));
    }

    function testBatch_MarkMultipleAsPaid() public {
        // Create and accept loans individually first
        vm.startPrank(creditor);
        weth.approve(address(bullaFrendLend), 2 ether);
        
        uint256 loanId1 = bullaFrendLend.offerLoan{value: FEE}(
            new LoanRequestParamsBuilder()
                .withCreditor(creditor)
                .withDebtor(debtor)
                .withToken(address(weth))
                .build()
        );
        uint256 loanId2 = bullaFrendLend.offerLoan{value: FEE}(
            new LoanRequestParamsBuilder()
                .withCreditor(creditor)
                .withDebtor(charlie)
                .withToken(address(weth))
                .build()
        );
        vm.stopPrank();

        // Setup permissions for loan acceptance
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

        bullaClaim.permitCreateClaim({
            user: charlie,
            controller: address(bullaFrendLend),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: charliePK,
                user: charlie,
                controller: address(bullaFrendLend),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: true
            })
        });

        // Accept loans individually
        vm.prank(debtor);
        uint256 claimId1 = bullaFrendLend.acceptLoan(loanId1);
        
        vm.prank(charlie);
        uint256 claimId2 = bullaFrendLend.acceptLoan(loanId2);

        // Setup mark as paid permissions
        bullaClaim.permitMarkAsPaid({
            user: creditor,
            controller: address(bullaFrendLend),
            approvalCount: 2,
            signature: sigHelper.signMarkAsPaidPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaFrendLend),
                approvalCount: 2
            })
        });

        bytes[] memory calls = new bytes[](2);
        
        calls[0] = abi.encodeCall(BullaFrendLend.markLoanAsPaid, (claimId1));
        calls[1] = abi.encodeCall(BullaFrendLend.markLoanAsPaid, (claimId2));
        
        vm.prank(creditor);
        bullaFrendLend.batch(calls, true);
        
        // Verify both loans were marked as paid
        Claim memory claim1 = bullaClaim.getClaim(claimId1);
        Claim memory claim2 = bullaClaim.getClaim(claimId2);
        
        assertEq(uint256(claim1.status), uint256(Status.Paid));
        assertEq(uint256(claim2.status), uint256(Status.Paid));
    }

    /*///////////////////// BATCH LIMITATION TESTS /////////////////////*/

    function testBatch_MultipleOfferCreation_ShouldFail() public {
        // Due to BullaFrendLend's fee validation (each offer must pay exactly the fee amount),
        // multiple loan offers cannot be batched in a single transaction since all msg.value
        // goes to the first function call
        
        bytes[] memory calls = new bytes[](2);
        
        calls[0] = abi.encodeCall(
            BullaFrendLend.offerLoan,
            (new LoanRequestParamsBuilder()
                .withCreditor(creditor)
                .withDebtor(debtor)
                .withToken(address(weth))
                .build())
        );
        calls[1] = abi.encodeCall(
            BullaFrendLend.offerLoan,
            (new LoanRequestParamsBuilder()
                .withCreditor(creditor)
                .withDebtor(charlie)
                .withToken(address(weth))
                .build())
        );
        
        // Even with 2x the fee, this should fail because the second call gets msg.value = 0
        vm.prank(creditor);
        vm.expectRevert("Transaction reverted silently");
        bullaFrendLend.batch{value: FEE * 2}(calls, true);
        
        // Verify no loan offers were created
        assertEq(bullaFrendLend.loanOfferCount(), 0);
    }

    /*///////////////////// GAS LIMIT TESTS /////////////////////*/

    function testBatch_RejectMultipleOffers_GasLimit() public {
        // Test with a reasonable number of operations to avoid gas limit issues
        uint256 numOffers = 5;
        
        // Create multiple loan offers individually first
        uint256[] memory offerIds = new uint256[](numOffers);
        
        vm.startPrank(creditor);
        for (uint256 i = 0; i < numOffers; i++) {
            offerIds[i] = bullaFrendLend.offerLoan{value: FEE}(
                new LoanRequestParamsBuilder()
                    .withCreditor(creditor)
                    .withDebtor(address(uint160(0x1000 + i)))
                    .withToken(address(weth))
                    .build()
            );
        }
        vm.stopPrank();
        
        // Now batch reject all offers (no fees required for rejection)
        bytes[] memory calls = new bytes[](numOffers);
        
        for (uint256 i = 0; i < numOffers; i++) {
            calls[i] = abi.encodeCall(BullaFrendLend.rejectLoanOffer, (offerIds[i]));
        }
        
        vm.prank(creditor);
        bullaFrendLend.batch(calls, true);
        
        // Verify all offers were rejected
        for (uint256 i = 0; i < numOffers; i++) {
            (LoanRequestParams memory params,) = bullaFrendLend.loanOffers(offerIds[i]);
            assertEq(params.creditor, address(0)); // Deleted offer has zero address
        }
        
        assertEq(bullaFrendLend.loanOfferCount(), numOffers); // Count doesn't decrease on rejection
    }

    function testBatch_MaxGasLimit() public {
        // Test with a reasonable number of operations to avoid gas limit issues
        uint256 numOffers = 10;
        
        // Create multiple loan offers individually first
        uint256[] memory offerIds = new uint256[](numOffers);
        
        vm.startPrank(creditor);
        for (uint256 i = 0; i < numOffers; i++) {
            offerIds[i] = bullaFrendLend.offerLoan{value: FEE}(
                new LoanRequestParamsBuilder()
                    .withCreditor(creditor)
                    .withDebtor(address(uint160(0x1000 + i)))
                    .withToken(address(weth))
                    .build()
            );
        }
        vm.stopPrank();
        
        // Now batch reject all offers (no fees required for rejection)
        bytes[] memory calls = new bytes[](numOffers);
        
        for (uint256 i = 0; i < numOffers; i++) {
            calls[i] = abi.encodeCall(BullaFrendLend.rejectLoanOffer, (offerIds[i]));
        }
        
        vm.prank(creditor);
        bullaFrendLend.batch(calls, true);
        
        // Verify all offers were rejected
        for (uint256 i = 0; i < numOffers; i++) {
            (LoanRequestParams memory params,) = bullaFrendLend.loanOffers(offerIds[i]);
            assertEq(params.creditor, address(0)); // Deleted offer has zero address
        }
        
        assertEq(bullaFrendLend.loanOfferCount(), numOffers); // Count doesn't decrease on rejection
    }
} 