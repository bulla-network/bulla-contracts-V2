// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.14;

import "forge-std/console.sol";
import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import "contracts/types/Types.sol";
import {WETH} from "contracts/mocks/weth.sol";
import {EIP712Helper, privateKeyValidity} from "test/foundry/BullaClaim/EIP712/Utils.sol";
import {BullaClaim} from "contracts/BullaClaim.sol";
import {BullaInvoice, CreateInvoiceParams, Invoice, InvalidDueBy, CreditorCannotBeDebtor} from "contracts/BullaInvoice.sol";
import {Deployer} from "script/Deployment.s.sol";

contract TestBullaInvoice is Test {
    WETH public weth;
    BullaClaim public bullaClaim;
    EIP712Helper public sigHelper;
    BullaInvoice public bullaInvoice;

    uint256 creditorPK = uint256(0x01);
    uint256 debtorPK = uint256(0x02);
    address creditor = vm.addr(creditorPK);
    address debtor = vm.addr(debtorPK);

    function setUp() public {
        weth = new WETH();

        bullaClaim = (new Deployer()).deploy_test({_deployer: address(this), _initialLockState: LockState.Unlocked});
        sigHelper = new EIP712Helper(address(bullaClaim));
        bullaInvoice = new BullaInvoice(address(bullaClaim));

        vm.deal(debtor, 10 ether);
    }

    function testCreateInvoice() public {
        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            operator: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                operator: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Create an invoice as creditor
        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(
            CreateInvoiceParams({
                debtor: debtor,
                claimAmount: 1 ether,
                dueBy: block.timestamp + 30 days,
                deliveryDate: 0,
                description: "Test Invoice",
                token: address(0),
                binding: ClaimBinding.BindingPending,
                payerReceivesClaimOnPayment: true
            })
        );

        // Verify invoice was created correctly
        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        assertEq(invoice.claimAmount, 1 ether, "Invoice claim amount mismatch");
        assertEq(invoice.debtor, debtor, "Invoice debtor mismatch");
        assertEq(invoice.dueBy, block.timestamp + 30 days, "Invoice due date mismatch");
        assertTrue(invoice.status == Status.Pending, "Invoice status should be Pending");
        assertEq(uint8(invoice.binding), uint8(ClaimBinding.BindingPending), "Invoice binding status mismatch");
    }

    function testUpdateBinding() public {
        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            operator: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                operator: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Create an invoice
        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(
            CreateInvoiceParams({
                debtor: debtor,
                claimAmount: 1 ether,
                dueBy: block.timestamp + 30 days,
                deliveryDate: 0,
                description: "Test Invoice",
                token: address(0),
                binding: ClaimBinding.BindingPending,
                payerReceivesClaimOnPayment: true
            })
        );

        // Setup binding permit
        bullaClaim.permitUpdateBinding({
            user: debtor,
            operator: address(bullaInvoice),
            approvalCount: 1,
            signature: sigHelper.signUpdateBindingPermit({
                pk: debtorPK,
                user: debtor,
                operator: address(bullaInvoice),
                approvalCount: 1
            })
        });

        // Accept the invoice (update binding to Bound)
        vm.prank(debtor);
        bullaInvoice.updateBinding(invoiceId, ClaimBinding.Bound);

        // Verify invoice binding was updated
        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        assertEq(uint8(invoice.binding), uint8(ClaimBinding.Bound), "Invoice binding should be Bound");
    }

    function testPayInvoice() public {
        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            operator: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                operator: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Create an invoice
        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(
            CreateInvoiceParams({
                debtor: debtor,
                claimAmount: 1 ether,
                dueBy: block.timestamp + 30 days,
                deliveryDate: 0,
                description: "Test Invoice",
                token: address(0),
                binding: ClaimBinding.BindingPending,
                payerReceivesClaimOnPayment: true
            })
        );

        // Setup payment permit
        bullaClaim.permitPayClaim({
            user: debtor,
            operator: address(bullaInvoice),
            approvalType: PayClaimApprovalType.IsApprovedForAll,
            approvalDeadline: 0,
            paymentApprovals: new ClaimPaymentApprovalParam[](0),
            signature: sigHelper.signPayClaimPermit({
                pk: debtorPK,
                user: debtor,
                operator: address(bullaInvoice),
                approvalType: PayClaimApprovalType.IsApprovedForAll,
                approvalDeadline: 0,
                paymentApprovals: new ClaimPaymentApprovalParam[](0)
            })
        });

        // Pay the invoice
        vm.prank(debtor);
        bullaInvoice.payInvoice{value: 1 ether}(invoiceId, 1 ether);

        // Verify invoice is paid
        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        assertTrue(invoice.status == Status.Paid, "Invoice status should be Paid");
        assertEq(invoice.paidAmount, 1 ether, "Invoice paid amount mismatch");
    }

    function testRescindInvoice() public {
        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            operator: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                operator: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Create an invoice
        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(
            CreateInvoiceParams({
                debtor: debtor,
                claimAmount: 1 ether,
                dueBy: block.timestamp + 30 days,
                deliveryDate: 0,
                description: "Test Invoice",
                token: address(0),
                binding: ClaimBinding.BindingPending,
                payerReceivesClaimOnPayment: true
            })
        );

        // Setup cancel permit
        bullaClaim.permitCancelClaim({
            user: creditor,
            operator: address(bullaInvoice),
            approvalCount: 1,
            signature: sigHelper.signCancelClaimPermit({
                pk: creditorPK,
                user: creditor,
                operator: address(bullaInvoice),
                approvalCount: 1
            })
        });

        // Cancel the invoice
        vm.prank(creditor);
        bullaInvoice.cancelInvoice(invoiceId, "No longer needed");

        // Verify invoice is cancelled
        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        assertTrue(invoice.status == Status.Rescinded, "Invoice status should be Rescinded");
    }

    function testRejectInvoice() public {
        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            operator: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                operator: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Create an invoice
        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(
            CreateInvoiceParams({
                debtor: debtor,
                claimAmount: 1 ether,
                dueBy: block.timestamp + 30 days,
                deliveryDate: 0,
                description: "Test Invoice",
                token: address(0),
                binding: ClaimBinding.BindingPending,
                payerReceivesClaimOnPayment: true
            })
        );

        // Setup reject permit
        bullaClaim.permitCancelClaim({
            user: debtor,
            operator: address(bullaInvoice),
            approvalCount: 1,
            signature: sigHelper.signCancelClaimPermit({
                pk: debtorPK,
                user: debtor,
                operator: address(bullaInvoice),
                approvalCount: 1
            })
        });

        // Reject the invoice
        vm.prank(debtor);
        bullaInvoice.cancelInvoice(invoiceId, "Not needed");

        // Verify invoice is rejected
        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        assertTrue(invoice.status == Status.Rejected, "Invoice status should be Rejected");
    }

    // 1. Partial Payment Testing
    function testPartialPayment() public {
        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            operator: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                operator: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Create an invoice
        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(
            CreateInvoiceParams({
                debtor: debtor,
                claimAmount: 1 ether,
                dueBy: block.timestamp + 30 days,
                deliveryDate: 0,
                description: "Test Invoice",
                token: address(0),
                binding: ClaimBinding.BindingPending,
                payerReceivesClaimOnPayment: true
            })
        );

        // Setup payment permit
        bullaClaim.permitPayClaim({
            user: debtor,
            operator: address(bullaInvoice),
            approvalType: PayClaimApprovalType.IsApprovedForAll,
            approvalDeadline: 0,
            paymentApprovals: new ClaimPaymentApprovalParam[](0),
            signature: sigHelper.signPayClaimPermit({
                pk: debtorPK,
                user: debtor,
                operator: address(bullaInvoice),
                approvalType: PayClaimApprovalType.IsApprovedForAll,
                approvalDeadline: 0,
                paymentApprovals: new ClaimPaymentApprovalParam[](0)
            })
        });

        // Make a partial payment (0.4 ETH)
        vm.prank(debtor);
        bullaInvoice.payInvoice{value: 0.4 ether}(invoiceId, 0.4 ether);

        // Verify partial payment
        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        assertTrue(invoice.status == Status.Repaying, "Invoice status should still be Repaying after partial payment");
        assertEq(invoice.paidAmount, 0.4 ether, "Invoice paid amount should match partial payment");

        // Pay the remaining balance
        vm.prank(debtor);
        bullaInvoice.payInvoice{value: 0.6 ether}(invoiceId, 0.6 ether);

        // Verify full payment
        invoice = bullaInvoice.getInvoice(invoiceId);
        assertTrue(invoice.status == Status.Paid, "Invoice status should be Paid after full payment");
        assertEq(invoice.paidAmount, 1 ether, "Invoice paid amount should match full payment");
    }

    // 2. Token Payments
    function testTokenPayment() public {
        // Setup for token payment (using WETH)
        vm.prank(debtor);
        weth.deposit{value: 2 ether}();

        // Approve WETH spending for BullaClaim
        vm.prank(debtor);
        weth.approve(address(bullaClaim), 2 ether);

        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            operator: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                operator: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Create an invoice with WETH as token
        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(
            CreateInvoiceParams({
                debtor: debtor,
                claimAmount: 1 ether,
                dueBy: block.timestamp + 30 days,
                deliveryDate: 0,
                description: "Token Payment Invoice",
                token: address(weth),
                binding: ClaimBinding.BindingPending,
                payerReceivesClaimOnPayment: true
            })
        );

        // Setup payment permit
        bullaClaim.permitPayClaim({
            user: debtor,
            operator: address(bullaInvoice),
            approvalType: PayClaimApprovalType.IsApprovedForAll,
            approvalDeadline: 0,
            paymentApprovals: new ClaimPaymentApprovalParam[](0),
            signature: sigHelper.signPayClaimPermit({
                pk: debtorPK,
                user: debtor,
                operator: address(bullaInvoice),
                approvalType: PayClaimApprovalType.IsApprovedForAll,
                approvalDeadline: 0,
                paymentApprovals: new ClaimPaymentApprovalParam[](0)
            })
        });

        // Record initial balances
        uint256 creditorInitialBalance = weth.balanceOf(creditor);
        uint256 debtorInitialBalance = weth.balanceOf(debtor);

        // Pay the invoice with WETH
        vm.prank(debtor);
        bullaInvoice.payInvoice(invoiceId, 1 ether);

        // Verify invoice is paid
        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        assertTrue(invoice.status == Status.Paid, "Invoice status should be Paid");
        assertEq(invoice.paidAmount, 1 ether, "Invoice paid amount mismatch");

        // Check token balances
        assertEq(weth.balanceOf(creditor), creditorInitialBalance + 1 ether, "Creditor should receive payment");
        assertEq(weth.balanceOf(debtor), debtorInitialBalance - 1 ether, "Debtor should send payment");
    }

    // 3. Invoice Metadata
    function testCreateInvoiceWithMetadata() public {
        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            operator: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                operator: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Create metadata
        ClaimMetadata memory metadata =
            ClaimMetadata({tokenURI: "Monthly Service", attachmentURI: "Additional details about this invoice"});

        // Create an invoice with metadata
        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoiceWithMetadata(
            CreateInvoiceParams({
                debtor: debtor,
                claimAmount: 1 ether,
                dueBy: block.timestamp + 30 days,
                deliveryDate: 0,
                description: "Test Invoice with Metadata",
                token: address(0),
                binding: ClaimBinding.BindingPending,
                payerReceivesClaimOnPayment: true
            }),
            metadata
        );

        // Verify invoice was created correctly
        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        assertEq(invoice.claimAmount, 1 ether, "Invoice claim amount mismatch");
        assertEq(invoice.dueBy, block.timestamp + 30 days, "Invoice due date mismatch");

        // Verify metadata through BullaClaim's claimMetadata function
        (string memory tokenURI, string memory attachmentURI) = bullaClaim.claimMetadata(invoiceId);
        assertEq(tokenURI, "Monthly Service", "Token URI metadata mismatch");
        assertEq(attachmentURI, "Additional details about this invoice", "Attachment URI metadata mismatch");
    }

    // 4. Invalid Parameter Tests
    function testInvalidDueByDate() public {
        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            operator: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                operator: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        vm.warp(block.timestamp + 1 days);

        // Try to create an invoice with past due date
        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(InvalidDueBy.selector));
        bullaInvoice.createInvoice(
            CreateInvoiceParams({
                debtor: debtor,
                claimAmount: 1 ether,
                dueBy: block.timestamp - 1 days, // Past date
                deliveryDate: 0,
                description: "Test Invoice",
                token: address(0),
                binding: ClaimBinding.BindingPending,
                payerReceivesClaimOnPayment: true
            })
        );

        // Try to create an invoice with too far future due date
        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(InvalidDueBy.selector));
        bullaInvoice.createInvoice(
            CreateInvoiceParams({
                debtor: debtor,
                claimAmount: 1 ether,
                dueBy: uint256(type(uint40).max) + 1, // Too far in the future
                deliveryDate: 0,
                description: "Test Invoice",
                token: address(0),
                binding: ClaimBinding.BindingPending,
                payerReceivesClaimOnPayment: true
            })
        );
    }

    // 5. Edge Cases
    function testPaymentAtDueDate() public {
        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            operator: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                operator: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Create an invoice
        uint256 dueDate = block.timestamp + 30 days;
        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(
            CreateInvoiceParams({
                debtor: debtor,
                claimAmount: 1 ether,
                dueBy: dueDate,
                deliveryDate: 0,
                description: "Test Invoice",
                token: address(0),
                binding: ClaimBinding.BindingPending,
                payerReceivesClaimOnPayment: true
            })
        );

        // Setup payment permit
        bullaClaim.permitPayClaim({
            user: debtor,
            operator: address(bullaInvoice),
            approvalType: PayClaimApprovalType.IsApprovedForAll,
            approvalDeadline: 0,
            paymentApprovals: new ClaimPaymentApprovalParam[](0),
            signature: sigHelper.signPayClaimPermit({
                pk: debtorPK,
                user: debtor,
                operator: address(bullaInvoice),
                approvalType: PayClaimApprovalType.IsApprovedForAll,
                approvalDeadline: 0,
                paymentApprovals: new ClaimPaymentApprovalParam[](0)
            })
        });

        // Warp time to exactly the due date
        vm.warp(dueDate);

        // Pay the invoice exactly at due date
        vm.prank(debtor);
        bullaInvoice.payInvoice{value: 1 ether}(invoiceId, 1 ether);

        // Verify payment succeeded
        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        assertTrue(invoice.status == Status.Paid, "Invoice should be paid even at the due date");
    }

    function testPaymentAfterDueDate() public {
        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            operator: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                operator: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Create an invoice
        uint256 dueDate = block.timestamp + 30 days;
        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(
            CreateInvoiceParams({
                debtor: debtor,
                claimAmount: 1 ether,
                dueBy: dueDate,
                deliveryDate: 0,
                description: "Test Invoice",
                token: address(0),
                binding: ClaimBinding.BindingPending,
                payerReceivesClaimOnPayment: true
            })
        );

        // Setup payment permit
        bullaClaim.permitPayClaim({
            user: debtor,
            operator: address(bullaInvoice),
            approvalType: PayClaimApprovalType.IsApprovedForAll,
            approvalDeadline: 0,
            paymentApprovals: new ClaimPaymentApprovalParam[](0),
            signature: sigHelper.signPayClaimPermit({
                pk: debtorPK,
                user: debtor,
                operator: address(bullaInvoice),
                approvalType: PayClaimApprovalType.IsApprovedForAll,
                approvalDeadline: 0,
                paymentApprovals: new ClaimPaymentApprovalParam[](0)
            })
        });

        // Warp time past the due date
        vm.warp(dueDate + 1 days);

        // Pay the invoice after due date
        vm.prank(debtor);
        bullaInvoice.payInvoice{value: 1 ether}(invoiceId, 1 ether);

        // Verify payment still succeeded
        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        assertTrue(invoice.status == Status.Paid, "Invoice should be payable even after the due date");
    }

    // 7. Permission and Security Tests
    function testUnauthorizedCancellation() public {
        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            operator: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                operator: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Create an invoice
        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(
            CreateInvoiceParams({
                debtor: debtor,
                claimAmount: 1 ether,
                dueBy: block.timestamp + 30 days,
                deliveryDate: 0,
                description: "Test Invoice",
                token: address(0),
                binding: ClaimBinding.BindingPending,
                payerReceivesClaimOnPayment: true
            })
        );

        // Try to cancel without proper permissions (no permit)
        address randomUser = vm.addr(0x03);
        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(BullaClaim.NotApproved.selector)); // Should fail - random user can't cancel
        bullaInvoice.cancelInvoice(invoiceId, "Unauthorized cancellation");
    }

    function testUnauthorizedPayment() public {
        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            operator: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                operator: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Create an invoice
        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(
            CreateInvoiceParams({
                debtor: debtor,
                claimAmount: 1 ether,
                dueBy: block.timestamp + 30 days,
                deliveryDate: 0,
                description: "Test Invoice",
                token: address(0),
                binding: ClaimBinding.BindingPending,
                payerReceivesClaimOnPayment: true
            })
        );

        // Try to pay without proper permissions
        address randomUser = vm.addr(0x03);
        vm.deal(randomUser, 2 ether);
        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(BullaClaim.NotApproved.selector)); // Should fail - random user can't pay without permit
        bullaInvoice.payInvoice{value: 1 ether}(invoiceId, 1 ether);
    }

    // 9. Fuzz Tests
    function testFuzz_CreateInvoice(uint256 amount, uint40 dueByOffset) public {
        // Constrain input values to realistic ranges
        amount = bound(amount, 0.001 ether, 1000 ether);
        dueByOffset = uint40(bound(dueByOffset, 1 days, 365 days));
        uint256 dueBy = block.timestamp + dueByOffset;

        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            operator: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                operator: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Create an invoice
        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(
            CreateInvoiceParams({
                debtor: debtor,
                claimAmount: amount,
                dueBy: dueBy,
                deliveryDate: 0,
                description: "Fuzz Test Invoice",
                token: address(0),
                binding: ClaimBinding.BindingPending,
                payerReceivesClaimOnPayment: true
            })
        );

        // Verify invoice was created correctly
        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        assertEq(invoice.claimAmount, amount, "Invoice claim amount mismatch");
        assertEq(invoice.dueBy, dueBy, "Invoice due date mismatch");
    }

    function testFuzz_PartialPayment(uint256 amount, uint8 paymentPercentage) public {
        // Constrain input values
        amount = bound(amount, 0.1 ether, 10 ether);
        paymentPercentage = uint8(bound(paymentPercentage, 1, 99)); // 1-99%
        uint256 partialAmount = (amount * paymentPercentage) / 100;
        uint256 remainingAmount = amount - partialAmount;

        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            operator: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                operator: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Create an invoice
        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(
            CreateInvoiceParams({
                debtor: debtor,
                claimAmount: amount,
                dueBy: block.timestamp + 30 days,
                deliveryDate: 0,
                description: "Fuzz Test Invoice",
                token: address(0),
                binding: ClaimBinding.BindingPending,
                payerReceivesClaimOnPayment: true
            })
        );

        // Ensure debtor has enough ETH
        vm.deal(debtor, amount + 1 ether);

        // Setup payment permit
        bullaClaim.permitPayClaim({
            user: debtor,
            operator: address(bullaInvoice),
            approvalType: PayClaimApprovalType.IsApprovedForAll,
            approvalDeadline: 0,
            paymentApprovals: new ClaimPaymentApprovalParam[](0),
            signature: sigHelper.signPayClaimPermit({
                pk: debtorPK,
                user: debtor,
                operator: address(bullaInvoice),
                approvalType: PayClaimApprovalType.IsApprovedForAll,
                approvalDeadline: 0,
                paymentApprovals: new ClaimPaymentApprovalParam[](0)
            })
        });

        // Make partial payment
        vm.prank(debtor);
        bullaInvoice.payInvoice{value: partialAmount}(invoiceId, partialAmount);

        // Verify partial payment
        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        assertTrue(invoice.status == Status.Repaying, "Invoice status should still be Repaying after partial payment");
        assertEq(invoice.paidAmount, partialAmount, "Invoice paid amount should match partial payment");

        // Pay remaining amount
        vm.prank(debtor);
        bullaInvoice.payInvoice{value: remainingAmount}(invoiceId, remainingAmount);

        // Verify full payment
        invoice = bullaInvoice.getInvoice(invoiceId);
        assertTrue(invoice.status == Status.Paid, "Invoice status should be Paid after full payment");
        assertEq(invoice.paidAmount, amount, "Invoice paid amount should match full payment");
    }

    // 10. Error State Tests
    function testExcessivePayment() public {
        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            operator: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                operator: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Create an invoice
        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(
            CreateInvoiceParams({
                debtor: debtor,
                claimAmount: 1 ether,
                dueBy: block.timestamp + 30 days,
                deliveryDate: 0,
                description: "Test Invoice",
                token: address(0),
                binding: ClaimBinding.BindingPending,
                payerReceivesClaimOnPayment: true
            })
        );

        // Setup payment permit
        bullaClaim.permitPayClaim({
            user: debtor,
            operator: address(bullaInvoice),
            approvalType: PayClaimApprovalType.IsApprovedForAll,
            approvalDeadline: 0,
            paymentApprovals: new ClaimPaymentApprovalParam[](0),
            signature: sigHelper.signPayClaimPermit({
                pk: debtorPK,
                user: debtor,
                operator: address(bullaInvoice),
                approvalType: PayClaimApprovalType.IsApprovedForAll,
                approvalDeadline: 0,
                paymentApprovals: new ClaimPaymentApprovalParam[](0)
            })
        });

        // Try to pay more than owed
        vm.prank(debtor);
        vm.expectRevert(); // Should revert with appropriate error
        bullaInvoice.payInvoice{value: 2 ether}(invoiceId, 2 ether);
    }

    function testPaymentValueMismatch() public {
        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            operator: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                operator: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Create an invoice
        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(
            CreateInvoiceParams({
                debtor: debtor,
                claimAmount: 1 ether,
                dueBy: block.timestamp + 30 days,
                deliveryDate: 0,
                description: "Test Invoice",
                token: address(0),
                binding: ClaimBinding.BindingPending,
                payerReceivesClaimOnPayment: true
            })
        );

        // Setup payment permit
        bullaClaim.permitPayClaim({
            user: debtor,
            operator: address(bullaInvoice),
            approvalType: PayClaimApprovalType.IsApprovedForAll,
            approvalDeadline: 0,
            paymentApprovals: new ClaimPaymentApprovalParam[](0),
            signature: sigHelper.signPayClaimPermit({
                pk: debtorPK,
                user: debtor,
                operator: address(bullaInvoice),
                approvalType: PayClaimApprovalType.IsApprovedForAll,
                approvalDeadline: 0,
                paymentApprovals: new ClaimPaymentApprovalParam[](0)
            })
        });

        // Try to pay with mismatched amount (sending 0.5 ETH but claiming to pay 1 ETH)
        vm.prank(debtor);
        vm.expectRevert(); // Should revert with appropriate error
        bullaInvoice.payInvoice{value: 0.5 ether}(invoiceId, 1 ether);
    }

    function testPayAlreadyPaidInvoice() public {
        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            operator: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                operator: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Create an invoice
        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(
            CreateInvoiceParams({
                debtor: debtor,
                claimAmount: 1 ether,
                dueBy: block.timestamp + 30 days,
                deliveryDate: 0,
                description: "Test Invoice",
                token: address(0),
                binding: ClaimBinding.BindingPending,
                payerReceivesClaimOnPayment: true
            })
        );

        // Setup payment permit
        bullaClaim.permitPayClaim({
            user: debtor,
            operator: address(bullaInvoice),
            approvalType: PayClaimApprovalType.IsApprovedForAll,
            approvalDeadline: 0,
            paymentApprovals: new ClaimPaymentApprovalParam[](0),
            signature: sigHelper.signPayClaimPermit({
                pk: debtorPK,
                user: debtor,
                operator: address(bullaInvoice),
                approvalType: PayClaimApprovalType.IsApprovedForAll,
                approvalDeadline: 0,
                paymentApprovals: new ClaimPaymentApprovalParam[](0)
            })
        });

        // Pay the invoice
        vm.prank(debtor);
        bullaInvoice.payInvoice{value: 1 ether}(invoiceId, 1 ether);

        // Try to pay again
        vm.prank(debtor);
        vm.expectRevert(); // Should revert as invoice is already paid
        bullaInvoice.payInvoice{value: 1 ether}(invoiceId, 1 ether);
    }

    // Add new test cases

    // Test creating invoice with dueBy = 0
    function testCreateInvoiceWithZeroDueBy() public {
        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            operator: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                operator: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Create an invoice with dueBy = 0
        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(
            CreateInvoiceParams({
                debtor: debtor,
                claimAmount: 1 ether,
                dueBy: 0, // No due date
                deliveryDate: 0,
                description: "Test Invoice with No Due Date",
                token: address(0),
                binding: ClaimBinding.BindingPending,
                payerReceivesClaimOnPayment: true
            })
        );

        // Verify invoice was created correctly
        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        assertEq(invoice.dueBy, 0, "Invoice due date should be 0");
    }

    // Test trying to pay a claim that was not created by BullaInvoice
    function testPayDirectClaim() public {
        // Create a claim directly via BullaClaim
        vm.prank(creditor);
        uint256 claimId = bullaClaim.createClaim(
            CreateClaimParams({
                creditor: creditor,
                debtor: debtor,
                claimAmount: 1 ether,
                description: "Direct Claim",
                token: address(0),
                binding: ClaimBinding.BindingPending,
                payerReceivesClaimOnPayment: true
            })
        );

        // Try to pay via BullaInvoice
        vm.prank(debtor);
        vm.expectRevert(abi.encodeWithSelector(BullaClaim.NotController.selector, debtor)); // Should revert as the claim's controller is not BullaInvoice
        bullaInvoice.payInvoice{value: 1 ether}(claimId, 1 ether);
    }

    // Test trying to update binding of a claim that was not created by BullaInvoice
    function testUpdateBindingDirectClaim() public {
        // Create a claim directly via BullaClaim
        vm.prank(creditor);
        uint256 claimId = bullaClaim.createClaim(
            CreateClaimParams({
                creditor: creditor,
                debtor: debtor,
                claimAmount: 1 ether,
                description: "Direct Claim",
                token: address(0),
                binding: ClaimBinding.BindingPending,
                payerReceivesClaimOnPayment: true
            })
        );

        // Setup binding permit
        bullaClaim.permitUpdateBinding({
            user: debtor,
            operator: address(bullaInvoice),
            approvalCount: 1,
            signature: sigHelper.signUpdateBindingPermit({
                pk: debtorPK,
                user: debtor,
                operator: address(bullaInvoice),
                approvalCount: 1
            })
        });

        // Try to update binding via BullaInvoice
        vm.prank(debtor);
        vm.expectRevert(abi.encodeWithSelector(BullaClaim.NotController.selector, debtor)); // Should revert as the claim's controller is not BullaInvoice
        bullaInvoice.updateBinding(claimId, ClaimBinding.Bound);
    }

    // Test trying to cancel a claim that was not created by BullaInvoice
    function testCancelDirectClaim() public {
        // Create a claim directly via BullaClaim
        vm.prank(creditor);
        uint256 claimId = bullaClaim.createClaim(
            CreateClaimParams({
                creditor: creditor,
                debtor: debtor,
                claimAmount: 1 ether,
                description: "Direct Claim",
                token: address(0),
                binding: ClaimBinding.BindingPending,
                payerReceivesClaimOnPayment: true
            })
        );

        // Try to cancel via BullaInvoice
        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(BullaClaim.NotController.selector, creditor)); // Should revert as the claim's controller is not BullaInvoice
        bullaInvoice.cancelInvoice(claimId, "Trying to cancel direct claim");
    }

    // Test cannot directly pay claim created via BullaInvoice
    function testCannotDirectlyPayInvoiceClaim() public {
        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            operator: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                operator: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Create an invoice via BullaInvoice
        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(
            CreateInvoiceParams({
                debtor: debtor,
                claimAmount: 1 ether,
                dueBy: block.timestamp + 30 days,
                deliveryDate: 0,
                description: "Test Invoice",
                token: address(0),
                binding: ClaimBinding.BindingPending,
                payerReceivesClaimOnPayment: true
            })
        );

        // Try to pay directly via BullaClaim
        vm.prank(debtor);
        vm.expectRevert(abi.encodeWithSelector(BullaClaim.NotController.selector, debtor));
        bullaClaim.payClaim{value: 1 ether}(invoiceId, 1 ether);
    }

    // Test cannot directly cancel claim created via BullaInvoice
    function testCannotDirectlyCancelInvoiceClaim() public {
        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            operator: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                operator: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Create an invoice via BullaInvoice
        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(
            CreateInvoiceParams({
                debtor: debtor,
                claimAmount: 1 ether,
                dueBy: block.timestamp + 30 days,
                deliveryDate: 0,
                description: "Test Invoice",
                token: address(0),
                binding: ClaimBinding.BindingPending,
                payerReceivesClaimOnPayment: true
            })
        );

        // Try to cancel directly via BullaClaim
        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(BullaClaim.NotController.selector, creditor));
        bullaClaim.cancelClaim(invoiceId, "Trying to directly cancel");
    }

    // Test creating invoice with metadata and dueBy = 0
    function testCreateInvoiceWithMetadataZeroDueBy() public {
        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            operator: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                operator: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Create metadata
        ClaimMetadata memory metadata =
            ClaimMetadata({tokenURI: "Invoice with Zero Due Date", attachmentURI: "No due date specified"});

        // Create an invoice with metadata and dueBy = 0
        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoiceWithMetadata(
            CreateInvoiceParams({
                debtor: debtor,
                claimAmount: 1 ether,
                dueBy: 0, // No due date
                deliveryDate: 0,
                description: "Test Invoice with Metadata and No Due Date",
                token: address(0),
                binding: ClaimBinding.BindingPending,
                payerReceivesClaimOnPayment: true
            }),
            metadata
        );

        // Verify invoice was created correctly with dueBy = 0
        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        assertEq(invoice.dueBy, 0, "Invoice due date should be 0");

        // Verify metadata
        (string memory tokenURI, string memory attachmentURI) = bullaClaim.claimMetadata(invoiceId);
        assertEq(tokenURI, "Invoice with Zero Due Date", "Token URI metadata mismatch");
        assertEq(attachmentURI, "No due date specified", "Attachment URI metadata mismatch");
    }

    // Test creating invoice with metadata and past due date (should fail)
    function testCreateInvoiceWithMetadataPastDueBy() public {
        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            operator: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                operator: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Create metadata
        ClaimMetadata memory metadata = ClaimMetadata({
            tokenURI: "Invoice with Past Due Date",
            attachmentURI: "This should fail due to past due date"
        });

        vm.warp(block.timestamp + 1 days);

        // Try to create an invoice with metadata and past due date
        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(InvalidDueBy.selector));
        bullaInvoice.createInvoiceWithMetadata(
            CreateInvoiceParams({
                debtor: debtor,
                claimAmount: 1 ether,
                dueBy: block.timestamp - 1 days, // Past date
                deliveryDate: 0,
                description: "Test Invoice with Metadata and Past Due Date",
                token: address(0),
                binding: ClaimBinding.BindingPending,
                payerReceivesClaimOnPayment: true
            }),
            metadata
        );
    }

    // Test creating invoice with metadata and too far future due date (should fail)
    function testCreateInvoiceWithMetadataFarFutureDueBy() public {
        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            operator: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                operator: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Create metadata
        ClaimMetadata memory metadata = ClaimMetadata({
            tokenURI: "Invoice with Far Future Due Date",
            attachmentURI: "This should fail due to far future due date"
        });

        // Try to create an invoice with metadata and too far future due date
        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(InvalidDueBy.selector));
        bullaInvoice.createInvoiceWithMetadata(
            CreateInvoiceParams({
                debtor: debtor,
                claimAmount: 1 ether,
                dueBy: uint256(type(uint40).max) + 1, // Too far in the future
                deliveryDate: 0,
                description: "Test Invoice with Metadata and Far Future Due Date",
                token: address(0),
                binding: ClaimBinding.BindingPending,
                payerReceivesClaimOnPayment: true
            }),
            metadata
        );
    }

    // Test creditor cannot be debtor in createInvoice
    function testCreditorCannotBeDebtorInCreateInvoice() public {
        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            operator: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                operator: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Try to create an invoice where creditor (msg.sender) is the same as debtor
        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(CreditorCannotBeDebtor.selector));
        bullaInvoice.createInvoice(
            CreateInvoiceParams({
                debtor: creditor, // Same as the msg.sender
                claimAmount: 1 ether,
                dueBy: block.timestamp + 30 days,
                deliveryDate: 0,
                description: "Test Invoice with Same Creditor and Debtor",
                token: address(0),
                binding: ClaimBinding.BindingPending,
                payerReceivesClaimOnPayment: true
            })
        );
    }

    // Test creditor cannot be debtor in createInvoiceWithMetadata
    function testCreditorCannotBeDebtorInCreateInvoiceWithMetadata() public {
        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            operator: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                operator: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Create metadata
        ClaimMetadata memory metadata = ClaimMetadata({
            tokenURI: "Invalid Invoice - Same Creditor and Debtor",
            attachmentURI: "This should fail due to creditor being same as debtor"
        });

        // Try to create an invoice with metadata where creditor (msg.sender) is the same as debtor
        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(CreditorCannotBeDebtor.selector));
        bullaInvoice.createInvoiceWithMetadata(
            CreateInvoiceParams({
                debtor: creditor, // Same as the msg.sender
                claimAmount: 1 ether,
                dueBy: block.timestamp + 30 days,
                deliveryDate: 0,
                description: "Test Invoice with Metadata and Same Creditor and Debtor",
                token: address(0),
                binding: ClaimBinding.BindingPending,
                payerReceivesClaimOnPayment: true
            }),
            metadata
        );
    }
}
