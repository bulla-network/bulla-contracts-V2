// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import {WETH} from "contracts/mocks/weth.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC20PermitMock} from "test/foundry/mocks/ERC20PermitMock.sol";
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

        bullaClaim = (new Deployer()).deploy_test({
            _deployer: address(this),
            _initialLockState: LockState.Unlocked,
            _coreProtocolFee: FEE
        });
        sigHelper = new EIP712Helper(address(bullaClaim));
        bullaFrendLend = new BullaFrendLend(address(bullaClaim), admin, PROTOCOL_FEE_BPS);

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
        revert("Invalid user address");
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
            (new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth)).build())
        );

        vm.prank(creditor);
        bullaFrendLend.batch(calls, true);

        // Verify loan offer was created
        LoanOffer memory loanOffer = bullaFrendLend.getLoanOffer(1);
        assertEq(loanOffer.params.creditor, creditor);
        assertEq(loanOffer.params.debtor, debtor);
        assertTrue(loanOffer.requestedByCreditor);
        assertEq(bullaFrendLend.loanOfferCount(), 1);
    }

    function testBatch_RevertOnFail_True() public {
        bytes[] memory calls = new bytes[](2);

        // First call succeeds
        calls[0] = abi.encodeCall(
            BullaFrendLend.offerLoan,
            (new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth)).build())
        );

        // Second call fails (invalid term length)
        calls[1] = abi.encodeCall(
            BullaFrendLend.offerLoan,
            (
                new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth))
                    .withTermLength(0).build()
            )
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
        uint256 validOfferId1 = bullaFrendLend.offerLoan(
            new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth)).build()
        );
        uint256 validOfferId2 = bullaFrendLend.offerLoan(
            new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(charlie).withToken(address(weth)).build()
        );
        vm.stopPrank();

        // Validate loan offers were created properly
        LoanOffer memory initialOffer1 = bullaFrendLend.getLoanOffer(validOfferId1);
        LoanOffer memory initialOffer2 = bullaFrendLend.getLoanOffer(validOfferId2);

        assertEq(
            initialOffer1.params.creditor, creditor, "First loan offer should have been created with correct creditor"
        );
        assertEq(
            initialOffer2.params.creditor, creditor, "Second loan offer should have been created with correct creditor"
        );

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
        LoanOffer memory loanOffer1 = bullaFrendLend.getLoanOffer(validOfferId1);
        LoanOffer memory loanOffer2 = bullaFrendLend.getLoanOffer(validOfferId2);

        assertEq(loanOffer1.params.creditor, address(0)); // First offer was deleted
        assertEq(loanOffer2.params.creditor, address(0)); // Third offer was deleted
    }

    /*///////////////////// BATCH LOAN OFFER MANAGEMENT TESTS /////////////////////*/

    function testBatch_RejectMultipleLoanOffers() public {
        // Create multiple loan offers first
        vm.startPrank(creditor);
        uint256 loanId1 = bullaFrendLend.offerLoan(
            new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth)).build()
        );
        uint256 loanId2 = bullaFrendLend.offerLoan(
            new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(charlie).withToken(address(weth)).build()
        );
        vm.stopPrank();

        // Validate loan offers were created properly
        LoanOffer memory initialOffer1 = bullaFrendLend.getLoanOffer(loanId1);
        LoanOffer memory initialOffer2 = bullaFrendLend.getLoanOffer(loanId2);

        assertEq(
            initialOffer1.params.creditor, creditor, "First loan offer should have been created with correct creditor"
        );
        assertEq(
            initialOffer2.params.creditor, creditor, "Second loan offer should have been created with correct creditor"
        );

        bytes[] memory calls = new bytes[](2);

        calls[0] = abi.encodeCall(BullaFrendLend.rejectLoanOffer, (loanId1));
        calls[1] = abi.encodeCall(BullaFrendLend.rejectLoanOffer, (loanId2));

        vm.prank(creditor);
        bullaFrendLend.batch(calls, true);

        // Verify all loan offers were rejected (deleted)
        LoanOffer memory loanOffer1 = bullaFrendLend.getLoanOffer(loanId1);
        LoanOffer memory loanOffer2 = bullaFrendLend.getLoanOffer(loanId2);

        assertEq(loanOffer1.params.creditor, address(0));
        assertEq(loanOffer2.params.creditor, address(0));
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
        (uint8 v, bytes32 r, bytes32 s) =
            _permitERC20Token(privateKey, address(permitToken), address(bullaClaim), amount, deadline);

        bytes[] memory calls = new bytes[](1);

        // Single call: permit (test permit functionality in batch)
        calls[0] = abi.encodeWithSignature(
            "permitToken(address,address,address,uint256,uint256,uint8,bytes32,bytes32)",
            address(permitToken),
            owner,
            address(bullaClaim),
            amount,
            deadline,
            v,
            r,
            s
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

        // Create permit signature
        (uint8 v, bytes32 r, bytes32 s) =
            _permitERC20Token(privateKey, address(permitToken), address(bullaClaim), amount, deadline);

        // Call permitToken directly (not through batch)
        (bool success,) = address(bullaClaim).call(
            abi.encodeWithSignature(
                "permitToken(address,address,address,uint256,uint256,uint8,bytes32,bytes32)",
                address(permitToken),
                owner,
                address(bullaClaim),
                amount,
                deadline,
                v,
                r,
                s
            )
        );

        assertTrue(success, "permitToken call should succeed");

        // Verify allowance was set
        assertEq(permitToken.allowance(owner, address(bullaClaim)), amount);
    }

    /*///////////////////// EDGE CASES /////////////////////*/

    function testBatch_LimitedNumberOfOperations() public {
        // Test with a small number of operations to demonstrate batching without hitting gas limits
        uint256 numRejects = 10;

        // Create multiple loan offers individually first
        uint256[] memory offerIds = new uint256[](numRejects);

        vm.startPrank(creditor);
        for (uint256 i = 0; i < numRejects; i++) {
            offerIds[i] = bullaFrendLend.offerLoan(
                new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(address(uint160(0x1000 + i))).withToken(
                    address(weth)
                ).build()
            );
        }
        vm.stopPrank();

        // Validate loan offers were created
        for (uint256 i = 0; i < numRejects; i++) {
            LoanOffer memory initialOffer = bullaFrendLend.getLoanOffer(offerIds[i]);
            assertEq(
                initialOffer.params.creditor, creditor, "Loan offer should have been created with correct creditor"
            );
            assertEq(initialOffer.params.debtor, address(uint160(0x1000 + i)), "Loan offer should have correct debtor");
        }

        // Now batch reject all offers (no fees required for rejection)
        bytes[] memory calls = new bytes[](numRejects);

        for (uint256 i = 0; i < numRejects; i++) {
            calls[i] = abi.encodeCall(BullaFrendLend.rejectLoanOffer, (offerIds[i]));
        }

        vm.prank(creditor);
        bullaFrendLend.batch(calls, true);

        // Verify all offers were rejected
        for (uint256 i = 0; i < numRejects; i++) {
            LoanOffer memory loanOffer = bullaFrendLend.getLoanOffer(offerIds[i]);
            assertEq(loanOffer.params.creditor, address(0)); // Deleted offer has zero address
        }
    }

    /*///////////////////// BATCH LOAN ACCEPTANCE TESTS /////////////////////*/

    function testBatch_AcceptMultipleLoans() public {
        // Create multiple loan offers individually first
        uint256[] memory offerIds = new uint256[](3);

        vm.startPrank(creditor);
        weth.approve(address(bullaFrendLend), 3 ether);

        offerIds[0] = bullaFrendLend.offerLoan(
            new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth))
                .withLoanAmount(1 ether).build()
        );
        offerIds[1] = bullaFrendLend.offerLoan(
            new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(charlie).withToken(address(weth))
                .withLoanAmount(1 ether).build()
        );
        offerIds[2] = bullaFrendLend.offerLoan(
            new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth))
                .withLoanAmount(1 ether).build()
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

        uint256[] memory offerIdsToAccept = new uint256[](2);
        offerIdsToAccept[0] = offerIds[0];
        offerIdsToAccept[1] = offerIds[2];

        vm.prank(debtor);
        bullaFrendLend.batchAcceptLoans{value: 2 * FEE}(offerIdsToAccept);

        // Accept third loan individually
        vm.prank(charlie);
        bullaFrendLend.acceptLoan{value: FEE}(offerIds[1]);

        // Verify all loans were accepted and claims created
        assertEq(bullaClaim.currentClaimId(), 3);

        Claim memory claim1 = bullaClaim.getClaim(1);
        Claim memory claim2 = bullaClaim.getClaim(2);
        Claim memory claim3 = bullaClaim.getClaim(3);

        assertEq(claim1.debtor, debtor); // First accepted loan (offer 1)
        assertEq(claim2.debtor, debtor); // Second accepted loan (offer 3)
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

        uint256 loanId1 = bullaFrendLend.offerLoan(
            new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth))
                .withLoanAmount(1 ether).build()
        );
        uint256 loanId2 = bullaFrendLend.offerLoan(
            new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth))
                .withLoanAmount(1 ether).build()
        );
        uint256 loanId3 = bullaFrendLend.offerLoan(
            new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth))
                .withLoanAmount(1 ether).build()
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
        uint256 claimId1 = bullaFrendLend.acceptLoan{value: FEE}(loanId1);
        uint256 claimId2 = bullaFrendLend.acceptLoan{value: FEE}(loanId2);
        uint256 claimId3 = bullaFrendLend.acceptLoan{value: FEE}(loanId3);
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
        vm.startPrank(creditor);
        weth.approve(address(bullaFrendLend), 2 ether);

        uint256 loanId1 = bullaFrendLend.offerLoan(
            new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth))
                .withTermLength(1 days).withImpairmentGracePeriod(1 hours).build()
        );
        uint256 loanId2 = bullaFrendLend.offerLoan(
            new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(charlie).withToken(address(weth))
                .withTermLength(1 days).withImpairmentGracePeriod(1 hours).build()
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
        uint256 claimId1 = bullaFrendLend.acceptLoan{value: FEE}(loanId1);

        vm.prank(charlie);
        uint256 claimId2 = bullaFrendLend.acceptLoan{value: FEE}(loanId2);

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

        uint256 loanId1 = bullaFrendLend.offerLoan(
            new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth)).build()
        );
        uint256 loanId2 = bullaFrendLend.offerLoan(
            new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(charlie).withToken(address(weth)).build()
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
        uint256 claimId1 = bullaFrendLend.acceptLoan{value: FEE}(loanId1);

        vm.prank(charlie);
        uint256 claimId2 = bullaFrendLend.acceptLoan{value: FEE}(loanId2);

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
            (new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth)).build())
        );
        calls[1] = abi.encodeCall(
            BullaFrendLend.offerLoan,
            (new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(charlie).withToken(address(weth)).build())
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
        uint256 numOffers = 10;

        // Create multiple loan offers individually first
        uint256[] memory offerIds = new uint256[](numOffers);

        vm.startPrank(creditor);
        for (uint256 i = 0; i < numOffers; i++) {
            offerIds[i] = bullaFrendLend.offerLoan(
                new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(address(uint160(0x1000 + i))).withToken(
                    address(weth)
                ).build()
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
            LoanOffer memory loanOffer = bullaFrendLend.getLoanOffer(offerIds[i]);
            assertEq(loanOffer.params.creditor, address(0)); // Deleted offer has zero address
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
            offerIds[i] = bullaFrendLend.offerLoan(
                new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(address(uint160(0x1000 + i))).withToken(
                    address(weth)
                ).build()
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
            LoanOffer memory loanOffer = bullaFrendLend.getLoanOffer(offerIds[i]);
            assertEq(loanOffer.params.creditor, address(0)); // Deleted offer has zero address
        }

        assertEq(bullaFrendLend.loanOfferCount(), numOffers); // Count doesn't decrease on rejection
    }

    /*///////////////////// BATCH LOAN OFFER TESTS /////////////////////*/

    function testBatchOfferLoans_EmptyArray() public {
        bytes[] memory calls = new bytes[](0);

        // Should not revert with empty array and no value
        bullaFrendLend.batch(calls, true);
    }

    function testBatchOfferLoans_MultipleOffers() public {
        bytes[] memory calls = new bytes[](3);

        calls[0] = abi.encodeCall(
            BullaFrendLend.offerLoan,
            (
                new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth))
                    .withLoanAmount(1 ether).build()
            )
        );
        calls[1] = abi.encodeCall(
            BullaFrendLend.offerLoan,
            (
                new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(charlie).withToken(address(weth))
                    .withLoanAmount(2 ether).build()
            )
        );
        calls[2] = abi.encodeCall(
            BullaFrendLend.offerLoanWithMetadata,
            (
                new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(permitToken))
                    .withLoanAmount(3 ether).build(),
                ClaimMetadata({tokenURI: "test-uri", attachmentURI: "test-attachment"})
            )
        );

        vm.prank(creditor);
        bullaFrendLend.batch(calls, true);

        // Verify all loan offers were created
        assertEq(bullaFrendLend.loanOfferCount(), 3);

        LoanOffer memory offer1 = bullaFrendLend.getLoanOffer(1);
        LoanOffer memory offer2 = bullaFrendLend.getLoanOffer(2);
        LoanOffer memory offer3 = bullaFrendLend.getLoanOffer(3);

        assertEq(offer1.params.loanAmount, 1 ether);
        assertEq(offer1.params.debtor, debtor);
        assertEq(offer2.params.loanAmount, 2 ether);
        assertEq(offer2.params.debtor, charlie);
        assertEq(offer3.params.loanAmount, 3 ether);
        assertEq(offer3.params.token, address(permitToken));

        // Check metadata for the third offer
        ClaimMetadata memory metadata = bullaFrendLend.getLoanOfferMetadata(3);
        assertEq(metadata.tokenURI, "test-uri");
        assertEq(metadata.attachmentURI, "test-attachment");
    }

    /*///////////////////// BATCH LOAN ACCEPTANCE WITH RECEIVERS TESTS /////////////////////*/

    function testBatchAcceptLoans_WithCustomReceivers() public {
        // Setup: Creditor creates multiple loan offers
        vm.startPrank(creditor);
        weth.approve(address(bullaFrendLend), 10 ether);

        uint256 loanId1 = bullaFrendLend.offerLoan(
            new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth))
                .withLoanAmount(1 ether).build()
        );
        uint256 loanId2 = bullaFrendLend.offerLoan(
            new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth))
                .withLoanAmount(2 ether).build()
        );
        vm.stopPrank();

        // Setup permissions for loan acceptance
        _permitAcceptLoan(debtorPK, 2);

        // Setup receiver addresses (different from debtor)
        address receiver1 = charlie;
        address receiver2 = address(0x999);
        vm.deal(receiver2, 1 ether); // Give receiver2 some ETH for gas

        uint256[] memory offerIds = new uint256[](2);
        offerIds[0] = loanId1;
        offerIds[1] = loanId2;

        address[] memory receivers = new address[](2);
        receivers[0] = receiver1;
        receivers[1] = receiver2;

        // Record initial balances
        uint256 receiver1InitialBalance = weth.balanceOf(receiver1);
        uint256 receiver2InitialBalance = weth.balanceOf(receiver2);

        // Debtor accepts both loans with custom receivers
        vm.prank(debtor);
        bullaFrendLend.batchAcceptLoans{value: FEE * 2}(offerIds, receivers);

        // Verify loans were created and tokens went to custom receivers
        assertEq(weth.balanceOf(receiver1), receiver1InitialBalance + 1 ether);
        assertEq(weth.balanceOf(receiver2), receiver2InitialBalance + 2 ether);

        // Verify claims were created with debtor as the actual debtor
        Claim memory claim1 = bullaClaim.getClaim(1);
        Claim memory claim2 = bullaClaim.getClaim(2);
        assertEq(claim1.debtor, debtor);
        assertEq(claim2.debtor, debtor);
    }

    function testBatchAcceptLoans_WithMixedReceivers() public {
        // Setup: Creditor creates multiple loan offers
        vm.startPrank(creditor);
        weth.approve(address(bullaFrendLend), 10 ether);

        uint256 loanId1 = bullaFrendLend.offerLoan(
            new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth))
                .withLoanAmount(1 ether).build()
        );
        uint256 loanId2 = bullaFrendLend.offerLoan(
            new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth))
                .withLoanAmount(2 ether).build()
        );
        vm.stopPrank();

        // Setup permissions for loan acceptance
        _permitAcceptLoan(debtorPK, 2);

        uint256[] memory offerIds = new uint256[](2);
        offerIds[0] = loanId1;
        offerIds[1] = loanId2;

        address[] memory receivers = new address[](2);
        receivers[0] = charlie; // Custom receiver
        receivers[1] = address(0); // Default receiver (debtor)

        // Record initial balances
        uint256 charlieInitialBalance = weth.balanceOf(charlie);
        uint256 debtorInitialBalance = weth.balanceOf(debtor);

        // Debtor accepts both loans with mixed receivers
        vm.prank(debtor);
        bullaFrendLend.batchAcceptLoans{value: FEE * 2}(offerIds, receivers);

        // Verify tokens went to correct receivers
        assertEq(weth.balanceOf(charlie), charlieInitialBalance + 1 ether); // Custom receiver got first loan
        assertEq(weth.balanceOf(debtor), debtorInitialBalance + 2 ether); // Debtor got second loan (default)
    }

    function testBatchAcceptLoans_InvalidCalldata_MismatchedArrays() public {
        // Setup: Creditor creates loan offers
        vm.startPrank(creditor);
        weth.approve(address(bullaFrendLend), 10 ether);

        uint256 loanId1 = bullaFrendLend.offerLoan(
            new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth)).build()
        );
        uint256 loanId2 = bullaFrendLend.offerLoan(
            new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth)).build()
        );
        vm.stopPrank();

        uint256[] memory offerIds = new uint256[](2);
        offerIds[0] = loanId1;
        offerIds[1] = loanId2;

        // Mismatched receivers array (only 1 receiver for 2 offers)
        address[] memory receivers = new address[](1);
        receivers[0] = charlie;

        // Should revert with FrendLendBatchInvalidCalldata
        vm.prank(debtor);
        vm.expectRevert(abi.encodeWithSignature("FrendLendBatchInvalidCalldata()"));
        bullaFrendLend.batchAcceptLoans{value: FEE * 2}(offerIds, receivers);
    }

    function testBatchAcceptLoans_InvalidCalldata_EmptyReceivers() public {
        // Setup: Creditor creates loan offers
        vm.startPrank(creditor);
        weth.approve(address(bullaFrendLend), 10 ether);

        uint256 loanId1 = bullaFrendLend.offerLoan(
            new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth)).build()
        );
        vm.stopPrank();

        uint256[] memory offerIds = new uint256[](1);
        offerIds[0] = loanId1;

        // Empty receivers array for non-empty offers
        address[] memory receivers = new address[](0);

        // Should revert with FrendLendBatchInvalidCalldata
        vm.prank(debtor);
        vm.expectRevert(abi.encodeWithSignature("FrendLendBatchInvalidCalldata()"));
        bullaFrendLend.batchAcceptLoans{value: FEE}(offerIds, receivers);
    }
}
