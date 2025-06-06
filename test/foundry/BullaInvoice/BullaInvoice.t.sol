// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.14;

import "forge-std/console.sol";
import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import "contracts/types/Types.sol";
import {WETH} from "contracts/mocks/weth.sol";
import {EIP712Helper, privateKeyValidity} from "test/foundry/BullaClaim/EIP712/Utils.sol";
import {BullaClaim} from "contracts/BullaClaim.sol";
import {InterestConfig} from "contracts/libraries/CompoundInterestLib.sol";
import {
    BullaInvoice,
    CreateInvoiceParams,
    Invoice,
    CreditorCannotBeDebtor,
    InvalidDeliveryDate,
    NotOriginalCreditor,
    PurchaseOrderAlreadyDelivered,
    InvoiceNotPending,
    PurchaseOrderState,
    InvoiceDetails,
    NotPurchaseOrder,
    InvalidDepositAmount,
    InvalidMsgValue,
    NotAuthorizedForBinding
} from "contracts/BullaInvoice.sol";
import {Deployer} from "script/Deployment.s.sol";
import {CreateInvoiceParamsBuilder} from "test/foundry/BullaInvoice/CreateInvoiceParamsBuilder.sol";
import {CreateClaimParamsBuilder} from "test/foundry/BullaClaim/CreateClaimParamsBuilder.sol";
import {BullaClaimValidationLib} from "contracts/libraries/BullaClaimValidationLib.sol";

contract TestBullaInvoice is Test {
    WETH public weth;
    BullaClaim public bullaClaim;
    EIP712Helper public sigHelper;
    BullaInvoice public bullaInvoice;

    uint256 creditorPK = uint256(0x01);
    uint256 debtorPK = uint256(0x02);
    uint256 adminPK = uint256(0x03);
    address creditor = vm.addr(creditorPK);
    address debtor = vm.addr(debtorPK);
    address admin = vm.addr(adminPK);

    function setUp() public {
        weth = new WETH();

        bullaClaim = (new Deployer()).deploy_test({_deployer: address(this), _initialLockState: LockState.Unlocked});
        sigHelper = new EIP712Helper(address(bullaClaim));
        bullaInvoice = new BullaInvoice(address(bullaClaim), admin, 0);

        vm.deal(debtor, 10 ether);
    }

    function testCreateInvoice() public {
        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Create invoice params
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).build();

        // Create an invoice as creditor
        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(params);

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
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Create invoice params
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).build();

        // Create an invoice
        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(params);

        // Setup binding permit
        bullaClaim.permitUpdateBinding({
            user: debtor,
            controller: address(bullaInvoice),
            approvalCount: 1,
            signature: sigHelper.signUpdateBindingPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaInvoice),
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
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Create invoice params
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).build();

        // Create an invoice
        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(params);

        // Setup payment permit
        bullaClaim.permitPayClaim({
            user: debtor,
            controller: address(bullaInvoice),
            approvalType: PayClaimApprovalType.IsApprovedForAll,
            approvalDeadline: 0,
            paymentApprovals: new ClaimPaymentApprovalParam[](0),
            signature: sigHelper.signPayClaimPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaInvoice),
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
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Create invoice params
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).build();

        // Create an invoice
        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(params);

        // Setup cancel permit
        bullaClaim.permitCancelClaim({
            user: creditor,
            controller: address(bullaInvoice),
            approvalCount: 1,
            signature: sigHelper.signCancelClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
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
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Create invoice params
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).build();

        // Create an invoice
        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(params);

        // Setup reject permit
        bullaClaim.permitCancelClaim({
            user: debtor,
            controller: address(bullaInvoice),
            approvalCount: 1,
            signature: sigHelper.signCancelClaimPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaInvoice),
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
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Create invoice params
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).build();

        // Create an invoice
        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(params);

        // Setup payment permit
        bullaClaim.permitPayClaim({
            user: debtor,
            controller: address(bullaInvoice),
            approvalType: PayClaimApprovalType.IsApprovedForAll,
            approvalDeadline: 0,
            paymentApprovals: new ClaimPaymentApprovalParam[](0),
            signature: sigHelper.signPayClaimPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaInvoice),
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
        weth.approve(address(bullaInvoice), 2 ether);

        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Create invoice params with WETH as token
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).withDescription(
            "Token Payment Invoice"
        ).withToken(address(weth)).build();

        // Create an invoice with WETH as token
        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(params);

        // Setup payment permit
        bullaClaim.permitPayClaim({
            user: debtor,
            controller: address(bullaInvoice),
            approvalType: PayClaimApprovalType.IsApprovedForAll,
            approvalDeadline: 0,
            paymentApprovals: new ClaimPaymentApprovalParam[](0),
            signature: sigHelper.signPayClaimPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaInvoice),
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
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Create metadata
        ClaimMetadata memory metadata =
            ClaimMetadata({tokenURI: "Monthly Service", attachmentURI: "Additional details about this invoice"});

        // Create invoice params with metadata
        CreateInvoiceParams memory invoiceParams =
            new CreateInvoiceParamsBuilder().withDebtor(debtor).withDescription("Test Invoice with Metadata").build();

        // Create an invoice with metadata
        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoiceWithMetadata(invoiceParams, metadata);

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
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        vm.warp(block.timestamp + 1 days);

        // Create params with past due date
        CreateInvoiceParams memory pastDueParams = new CreateInvoiceParamsBuilder().withDebtor(debtor).withDueBy(
            block.timestamp - 1 days
        ) // Past date
            .build();

        // Try to create an invoice with past due date
        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(BullaClaimValidationLib.InvalidDueBy.selector));
        bullaInvoice.createInvoice(pastDueParams);

        // Create params with far future due date
        CreateInvoiceParams memory farFutureParams = new CreateInvoiceParamsBuilder().withDebtor(debtor).withDueBy(
            uint256(type(uint40).max) + 1
        ) // Too far in the future
            .build();

        // Try to create an invoice with too far future due date
        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(BullaClaimValidationLib.InvalidDueBy.selector));
        bullaInvoice.createInvoice(farFutureParams);
    }

    // 5. Edge Cases
    function testPaymentAtDueDate() public {
        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Set due date and create invoice params
        uint256 dueDate = block.timestamp + 30 days;
        CreateInvoiceParams memory params =
            new CreateInvoiceParamsBuilder().withDebtor(debtor).withDueBy(dueDate).build();

        // Create an invoice
        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(params);

        // Setup payment permit
        bullaClaim.permitPayClaim({
            user: debtor,
            controller: address(bullaInvoice),
            approvalType: PayClaimApprovalType.IsApprovedForAll,
            approvalDeadline: 0,
            paymentApprovals: new ClaimPaymentApprovalParam[](0),
            signature: sigHelper.signPayClaimPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaInvoice),
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
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Set due date and create invoice params
        uint256 dueDate = block.timestamp + 30 days;
        CreateInvoiceParams memory params =
            new CreateInvoiceParamsBuilder().withDebtor(debtor).withDueBy(dueDate).build();

        // Create an invoice
        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(params);

        // Setup payment permit
        bullaClaim.permitPayClaim({
            user: debtor,
            controller: address(bullaInvoice),
            approvalType: PayClaimApprovalType.IsApprovedForAll,
            approvalDeadline: 0,
            paymentApprovals: new ClaimPaymentApprovalParam[](0),
            signature: sigHelper.signPayClaimPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaInvoice),
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
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Create invoice params
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).build();

        // Create an invoice
        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(params);

        // Try to cancel without proper permissions (no permit)
        address randomUser = vm.addr(0x03);
        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(BullaClaimValidationLib.NotApproved.selector)); // Should fail - random user can't cancel
        bullaInvoice.cancelInvoice(invoiceId, "Unauthorized cancellation");
    }

    function testUnauthorizedPayment() public {
        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Create invoice params
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).build();

        // Create an invoice
        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(params);

        // Try to pay without proper permissions
        address randomUser = vm.addr(0x03);
        vm.deal(randomUser, 2 ether);
        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(BullaClaimValidationLib.NotApproved.selector)); // Should fail - random user can't pay without permit
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
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Create invoice params with fuzzing values
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).withClaimAmount(amount)
            .withDueBy(dueBy).withDescription("Fuzz Test Invoice").build();

        // Create an invoice
        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(params);

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
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Create invoice params with fuzzing values
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).withClaimAmount(amount)
            .withDescription("Fuzz Test Invoice").build();

        // Create an invoice
        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(params);

        // Ensure debtor has enough ETH
        vm.deal(debtor, amount + 1 ether);

        // Setup payment permit
        bullaClaim.permitPayClaim({
            user: debtor,
            controller: address(bullaInvoice),
            approvalType: PayClaimApprovalType.IsApprovedForAll,
            approvalDeadline: 0,
            paymentApprovals: new ClaimPaymentApprovalParam[](0),
            signature: sigHelper.signPayClaimPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaInvoice),
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

    function testPaymentValueMismatch() public {
        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Create invoice params
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).build();

        // Create an invoice
        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(params);

        // Setup payment permit
        bullaClaim.permitPayClaim({
            user: debtor,
            controller: address(bullaInvoice),
            approvalType: PayClaimApprovalType.IsApprovedForAll,
            approvalDeadline: 0,
            paymentApprovals: new ClaimPaymentApprovalParam[](0),
            signature: sigHelper.signPayClaimPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaInvoice),
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
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Create invoice params
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).build();

        // Create an invoice
        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(params);

        // Setup payment permit
        bullaClaim.permitPayClaim({
            user: debtor,
            controller: address(bullaInvoice),
            approvalType: PayClaimApprovalType.IsApprovedForAll,
            approvalDeadline: 0,
            paymentApprovals: new ClaimPaymentApprovalParam[](0),
            signature: sigHelper.signPayClaimPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaInvoice),
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
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Create invoice params with zero due date
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).withDueBy(0)
            .withDescription("Test Invoice with No Due Date") // No due date
            .build();

        // Create an invoice with dueBy = 0
        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(params);

        // Verify invoice was created correctly
        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        assertEq(invoice.dueBy, 0, "Invoice due date should be 0");
    }

    // Test trying to pay a claim that was not created by BullaInvoice
    function testPayDirectClaim() public {
        // Create a claim directly via BullaClaim
        CreateClaimParams memory params = new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withClaimAmount(1 ether).withDescription("Direct Claim").withToken(address(0)).withBinding(
            ClaimBinding.BindingPending
        ).build();

        vm.prank(creditor);
        uint256 claimId = bullaClaim.createClaim(params);

        // Try to pay via BullaInvoice
        vm.prank(debtor);
        vm.expectRevert(abi.encodeWithSelector(BullaClaim.NotController.selector, debtor)); // Should revert as the claim's controller is not BullaInvoice
        bullaInvoice.payInvoice{value: 1 ether}(claimId, 1 ether);
    }

    // Test trying to update binding of a claim that was not created by BullaInvoice
    function testUpdateBindingDirectClaim() public {
        // Create a claim directly via BullaClaim
        CreateClaimParams memory params = new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withBinding(ClaimBinding.BindingPending).build();

        vm.prank(creditor);
        uint256 claimId = bullaClaim.createClaim(params);

        // Setup binding permit
        bullaClaim.permitUpdateBinding({
            user: debtor,
            controller: address(bullaInvoice),
            approvalCount: 1,
            signature: sigHelper.signUpdateBindingPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaInvoice),
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
        CreateClaimParams memory params = new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withClaimAmount(1 ether).withBinding(ClaimBinding.BindingPending).build();

        vm.prank(creditor);
        uint256 claimId = bullaClaim.createClaim(params);

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
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).build();

        // Create an invoice via BullaInvoice
        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(params);

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
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).build();

        // Create an invoice via BullaInvoice
        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(params);

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
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Create metadata
        ClaimMetadata memory metadata =
            ClaimMetadata({tokenURI: "Invoice with Zero Due Date", attachmentURI: "No due date specified"});

        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).withDueBy(0)
            .withDescription("Test Invoice with Metadata and No Due Date") // No due date
            .build();

        // Create an invoice with metadata and dueBy = 0
        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoiceWithMetadata(params, metadata);

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
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
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

        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).withClaimAmount(1 ether)
            .withDueBy(block.timestamp - 1 days).withDescription("Test Invoice with Metadata and Past Due Date") // Past date
            .build();

        // Try to create an invoice with metadata and past due date
        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(BullaClaimValidationLib.InvalidDueBy.selector));
        bullaInvoice.createInvoiceWithMetadata(params, metadata);
    }

    // Test creating invoice with metadata and too far future due date (should fail)
    function testCreateInvoiceWithMetadataFarFutureDueBy() public {
        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
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

        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).withDueBy(
            uint256(type(uint40).max) + 1
        ).withDescription("Test Invoice with Metadata and Far Future Due Date") // Too far in the future
            .build();

        // Try to create an invoice with metadata and too far future due date
        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(BullaClaimValidationLib.InvalidDueBy.selector));
        bullaInvoice.createInvoiceWithMetadata(params, metadata);
    }

    // Test creditor cannot be debtor in createInvoice
    function testCreditorCannotBeDebtorInCreateInvoice() public {
        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(creditor).withDescription(
            "Test Invoice with Same Creditor and Debtor"
        ).build();

        // Try to create an invoice where creditor (msg.sender) is the same as debtor
        vm.prank(creditor);
        vm.expectRevert(CreditorCannotBeDebtor.selector);
        bullaInvoice.createInvoice(params);
    }

    // Test creditor cannot be debtor in createInvoiceWithMetadata
    function testCreditorCannotBeDebtorInCreateInvoiceWithMetadata() public {
        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
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

        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(creditor).withDescription(
            "Test Invoice with Metadata and Same Creditor and Debtor"
        ).build();

        // Try to create an invoice with metadata where creditor (msg.sender) is the same as debtor
        vm.prank(creditor);
        vm.expectRevert(CreditorCannotBeDebtor.selector);
        bullaInvoice.createInvoiceWithMetadata(params, metadata);
    }

    /// PURCHASE ORDER TESTS ///

    function testCreateInvoiceWithPurchaseOrder() public {
        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Future delivery date (7 days from now)
        uint256 deliveryDate = block.timestamp + 7 days;

        // Create invoice params with delivery date
        CreateInvoiceParams memory params =
            new CreateInvoiceParamsBuilder().withDebtor(debtor).withDeliveryDate(deliveryDate).build();

        // Create an invoice as creditor
        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(params);

        // Verify the invoice was created correctly
        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        assertEq(invoice.purchaseOrder.deliveryDate, deliveryDate, "Invoice delivery date mismatch");
        assertFalse(invoice.purchaseOrder.isDelivered, "Purchase order should not be delivered initially");
        assertTrue(invoice.status == Status.Pending, "Invoice status should be Pending");
    }

    function testInvalidDeliveryDate() public {
        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        vm.warp(30 days);

        // Create invoice params with past delivery date
        uint256 pastDeliveryDate = block.timestamp - 1 days;
        CreateInvoiceParams memory params =
            new CreateInvoiceParamsBuilder().withDebtor(debtor).withDeliveryDate(pastDeliveryDate).build();

        // Create should revert with InvalidDeliveryDate
        vm.prank(creditor);
        vm.expectRevert(InvalidDeliveryDate.selector);
        bullaInvoice.createInvoice(params);

        // Create invoice params with future delivery date beyond uint40
        uint256 farFutureDeliveryDate = uint256(type(uint40).max) + 1;
        params = new CreateInvoiceParamsBuilder().withDebtor(debtor).withDeliveryDate(farFutureDeliveryDate).build();

        // Create should revert with InvalidDeliveryDate
        vm.prank(creditor);
        vm.expectRevert(InvalidDeliveryDate.selector);
        bullaInvoice.createInvoice(params);
    }

    function testDeliverPurchaseOrder() public {
        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Create invoice params with delivery date
        uint256 deliveryDate = block.timestamp + 7 days;
        CreateInvoiceParams memory params =
            new CreateInvoiceParamsBuilder().withDebtor(debtor).withDeliveryDate(deliveryDate).build();

        // Create an invoice as creditor
        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(params);

        // Verify initial state
        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        assertFalse(invoice.purchaseOrder.isDelivered, "Purchase order should not be delivered initially");
        assertEq(invoice.purchaseOrder.deliveryDate, deliveryDate, "Delivery date should match");

        // Mark the purchase order as delivered
        vm.prank(creditor);
        bullaInvoice.deliverPurchaseOrder(invoiceId);

        // Verify the delivery state was updated
        invoice = bullaInvoice.getInvoice(invoiceId);
        assertTrue(invoice.purchaseOrder.isDelivered, "Purchase order should be marked as delivered");
        assertEq(invoice.purchaseOrder.deliveryDate, deliveryDate, "Delivery date should remain unchanged");

        // Try to deliver again - should revert
        vm.prank(creditor);
        vm.expectRevert(PurchaseOrderAlreadyDelivered.selector);
        bullaInvoice.deliverPurchaseOrder(invoiceId);
    }

    function testUnauthorizedDeliveryPurchaseOrder() public {
        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Create invoice params with delivery date
        uint256 deliveryDate = block.timestamp + 7 days;
        CreateInvoiceParams memory params =
            new CreateInvoiceParamsBuilder().withDebtor(debtor).withDeliveryDate(deliveryDate).build();

        // Create an invoice as creditor
        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(params);

        // Try to deliver from non-original creditor account
        address notCreditor = address(0x1234);
        vm.prank(notCreditor);
        vm.expectRevert(abi.encodeWithSelector(NotOriginalCreditor.selector));
        bullaInvoice.deliverPurchaseOrder(invoiceId);

        // Try to deliver from debtor account
        vm.prank(debtor);
        vm.expectRevert(abi.encodeWithSelector(NotOriginalCreditor.selector));
        bullaInvoice.deliverPurchaseOrder(invoiceId);
    }

    function testDeliverNonPendingPurchaseOrder() public {
        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Create invoice params with delivery date
        uint256 deliveryDate = block.timestamp + 7 days;
        CreateInvoiceParams memory params =
            new CreateInvoiceParamsBuilder().withDebtor(debtor).withDeliveryDate(deliveryDate).build();

        // Create an invoice
        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(params);

        // Setup cancel permit
        bullaClaim.permitCancelClaim({
            user: creditor,
            controller: address(bullaInvoice),
            approvalCount: 1,
            signature: sigHelper.signCancelClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalCount: 1
            })
        });

        // Cancel the invoice
        vm.prank(creditor);
        bullaInvoice.cancelInvoice(invoiceId, "No longer needed");

        // Try to deliver the purchase order - should revert
        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(InvoiceNotPending.selector));
        bullaInvoice.deliverPurchaseOrder(invoiceId);
    }

    function testCantDeliverInvoiceWithZeroDeliveryDate() public {
        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Create invoice params with zero delivery date (not a purchase order)
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).withDeliveryDate(0) // Explicitly set to 0
            .build();

        // Create an invoice as creditor
        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(params);

        // Verify initial state
        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        assertFalse(invoice.purchaseOrder.isDelivered, "Purchase order should not be delivered initially");
        assertEq(invoice.purchaseOrder.deliveryDate, 0, "Delivery date should be zero");

        // Still can mark as delivered even with 0 delivery date
        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(NotPurchaseOrder.selector));
        bullaInvoice.deliverPurchaseOrder(invoiceId);
    }

    function testCreateInvoiceWithMetadataAndPurchaseOrder() public {
        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Future delivery date (7 days from now)
        uint256 deliveryDate = block.timestamp + 7 days;

        // Create invoice params with delivery date
        CreateInvoiceParams memory params =
            new CreateInvoiceParamsBuilder().withDebtor(debtor).withDeliveryDate(deliveryDate).build();

        // Create an invoice with metadata
        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoiceWithMetadata(
            params,
            ClaimMetadata({tokenURI: "https://example.com/token/1", attachmentURI: "https://example.com/attachment/1"})
        );

        // Verify invoice was created correctly
        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        assertEq(invoice.claimAmount, 1 ether, "Invoice claim amount mismatch");
        assertEq(invoice.debtor, debtor, "Invoice debtor mismatch");
        assertEq(invoice.dueBy, block.timestamp + 30 days, "Invoice due date mismatch");
        assertTrue(invoice.status == Status.Pending, "Invoice status should be Pending");
        assertEq(invoice.purchaseOrder.deliveryDate, deliveryDate, "Purchase order delivery date mismatch");
        assertFalse(invoice.purchaseOrder.isDelivered, "Purchase order should not be delivered initially");

        // Verify metadata
        (string memory tokenURI, string memory attachmentURI) = bullaClaim.claimMetadata(invoiceId);
        assertEq(tokenURI, "https://example.com/token/1", "Token URI mismatch");
        assertEq(attachmentURI, "https://example.com/attachment/1", "Attachment URI mismatch");

        // Mark the purchase order as delivered
        vm.prank(creditor);
        bullaInvoice.deliverPurchaseOrder(invoiceId);

        // Verify the delivery state was updated
        invoice = bullaInvoice.getInvoice(invoiceId);
        assertTrue(invoice.purchaseOrder.isDelivered, "Purchase order should be marked as delivered");

        // Try to deliver again - should revert
        vm.prank(creditor);
        vm.expectRevert(PurchaseOrderAlreadyDelivered.selector);
        bullaInvoice.deliverPurchaseOrder(invoiceId);
    }

    function testPaymentOfDeliveredPurchaseOrder() public {
        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Future delivery date (7 days from now)
        uint256 deliveryDate = block.timestamp + 7 days;

        // Create invoice params with delivery date
        CreateInvoiceParams memory params =
            new CreateInvoiceParamsBuilder().withDebtor(debtor).withDeliveryDate(deliveryDate).build();

        // Create an invoice as creditor
        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(params);

        // Check initial state
        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        assertEq(invoice.purchaseOrder.deliveryDate, deliveryDate, "Purchase order delivery date mismatch");
        assertFalse(invoice.purchaseOrder.isDelivered, "Purchase order should not be delivered initially");
        assertTrue(invoice.status == Status.Pending, "Invoice status should be Pending");

        // Mark the purchase order as delivered
        vm.prank(creditor);
        bullaInvoice.deliverPurchaseOrder(invoiceId);

        // Verify purchase order is now marked as delivered
        invoice = bullaInvoice.getInvoice(invoiceId);
        assertTrue(invoice.purchaseOrder.isDelivered, "Purchase order should be marked as delivered");
        assertTrue(invoice.status == Status.Pending, "Invoice status should still be Pending after delivery");

        // Setup payment permit
        bullaClaim.permitPayClaim({
            user: debtor,
            controller: address(bullaInvoice),
            approvalType: PayClaimApprovalType.IsApprovedForAll,
            approvalDeadline: 0,
            paymentApprovals: new ClaimPaymentApprovalParam[](0),
            signature: sigHelper.signPayClaimPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaInvoice),
                approvalType: PayClaimApprovalType.IsApprovedForAll,
                approvalDeadline: 0,
                paymentApprovals: new ClaimPaymentApprovalParam[](0)
            })
        });

        // Pay the invoice
        vm.prank(debtor);
        bullaInvoice.payInvoice{value: 1 ether}(invoiceId, 1 ether);

        // Verify invoice is paid but purchase order state remains the same
        invoice = bullaInvoice.getInvoice(invoiceId);
        assertTrue(invoice.status == Status.Paid, "Invoice status should be Paid");
        assertEq(invoice.paidAmount, 1 ether, "Invoice paid amount mismatch");
        assertTrue(
            invoice.purchaseOrder.isDelivered, "Purchase order should still be marked as delivered after payment"
        );
        assertEq(
            invoice.purchaseOrder.deliveryDate, deliveryDate, "Delivery date should remain unchanged after payment"
        );
    }

    function testPartialPaymentOfPurchaseOrder() public {
        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Future delivery date (7 days from now)
        uint256 deliveryDate = block.timestamp + 7 days;

        // Create invoice params with delivery date
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).withDeliveryDate(
            deliveryDate
        ).withClaimAmount(2 ether) // Larger amount to test partial payment
            .build();

        // Create an invoice as creditor
        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(params);

        // Mark the purchase order as delivered
        vm.prank(creditor);
        bullaInvoice.deliverPurchaseOrder(invoiceId);

        // Verify purchase order is marked as delivered
        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        assertTrue(invoice.purchaseOrder.isDelivered, "Purchase order should be marked as delivered");
        assertTrue(invoice.status == Status.Pending, "Invoice status should be Pending");

        // Setup payment permit
        bullaClaim.permitPayClaim({
            user: debtor,
            controller: address(bullaInvoice),
            approvalType: PayClaimApprovalType.IsApprovedForAll,
            approvalDeadline: 0,
            paymentApprovals: new ClaimPaymentApprovalParam[](0),
            signature: sigHelper.signPayClaimPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaInvoice),
                approvalType: PayClaimApprovalType.IsApprovedForAll,
                approvalDeadline: 0,
                paymentApprovals: new ClaimPaymentApprovalParam[](0)
            })
        });

        // Make first partial payment
        vm.prank(debtor);
        bullaInvoice.payInvoice{value: 1 ether}(invoiceId, 1 ether);

        // Verify partial payment and purchase order state
        invoice = bullaInvoice.getInvoice(invoiceId);
        assertTrue(invoice.status == Status.Repaying, "Invoice status should be Repaying after partial payment");
        assertEq(invoice.paidAmount, 1 ether, "Invoice paid amount should be 1 ether");
        assertTrue(
            invoice.purchaseOrder.isDelivered,
            "Purchase order should still be marked as delivered after partial payment"
        );
        assertEq(invoice.purchaseOrder.deliveryDate, deliveryDate, "Delivery date should remain unchanged");

        // Make final payment
        vm.prank(debtor);
        bullaInvoice.payInvoice{value: 1 ether}(invoiceId, 1 ether);

        // Verify full payment and purchase order state
        invoice = bullaInvoice.getInvoice(invoiceId);
        assertTrue(invoice.status == Status.Paid, "Invoice status should be Paid after full payment");
        assertEq(invoice.paidAmount, 2 ether, "Invoice paid amount should be 2 ether");
        assertTrue(
            invoice.purchaseOrder.isDelivered, "Purchase order should still be marked as delivered after full payment"
        );
        assertEq(invoice.purchaseOrder.deliveryDate, deliveryDate, "Delivery date should remain unchanged");
    }

    function testOnlyOriginalCreditorCanDeliverAfterTransfer() public {
        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Future delivery date (7 days from now)
        uint256 deliveryDate = block.timestamp + 7 days;

        // Create invoice params with delivery date
        CreateInvoiceParams memory params =
            new CreateInvoiceParamsBuilder().withDebtor(debtor).withDeliveryDate(deliveryDate).build();

        // Create an invoice as creditor
        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(params);

        // Verify initial invoice state
        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        assertEq(invoice.purchaseOrder.deliveryDate, deliveryDate, "Purchase order delivery date mismatch");
        assertFalse(invoice.purchaseOrder.isDelivered, "Purchase order should not be delivered initially");
        assertEq(bullaClaim.ownerOf(invoiceId), creditor, "Original creditor should own the invoice");

        // Create new creditor address
        address newCreditor = address(0x1234);

        // Transfer invoice to new creditor
        vm.prank(creditor);
        bullaClaim.safeTransferFrom(creditor, newCreditor, invoiceId);

        // Verify ownership transfer
        assertEq(bullaClaim.ownerOf(invoiceId), newCreditor, "New creditor should own the invoice");

        // Attempt to deliver from new creditor - should fail
        vm.prank(newCreditor);
        vm.expectRevert(abi.encodeWithSelector(NotOriginalCreditor.selector));
        bullaInvoice.deliverPurchaseOrder(invoiceId);

        // Verify purchase order is still not delivered
        invoice = bullaInvoice.getInvoice(invoiceId);
        assertFalse(invoice.purchaseOrder.isDelivered, "Purchase order should not be delivered after failed attempt");

        // Original creditor can still deliver
        vm.prank(creditor);
        bullaInvoice.deliverPurchaseOrder(invoiceId);

        // Verify purchase order is now delivered
        invoice = bullaInvoice.getInvoice(invoiceId);
        assertTrue(invoice.purchaseOrder.isDelivered, "Purchase order should be delivered by original creditor");

        // Verify ownership hasn't changed
        assertEq(bullaClaim.ownerOf(invoiceId), newCreditor, "New creditor should still own the invoice");
    }

    /*///////////////////////////////////////////////////////////////
                        MARK INVOICE AS PAID TESTS
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

    function testMarkInvoiceAsPaid_Success() public {
        bullaClaim.permitCreateClaim({
            user: creditor,
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).build();

        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(params);

        Invoice memory invoiceBefore = bullaInvoice.getInvoice(invoiceId);
        assertEq(uint256(invoiceBefore.status), uint256(Status.Pending), "Invoice should be pending");

        // Set up mark as paid permission
        _permitMarkAsPaid(creditorPK, address(bullaInvoice), 1);

        // Check balances before marking as paid
        uint256 debtorBalanceBefore = debtor.balance;
        uint256 creditorBalanceBefore = creditor.balance;

        // Mark the invoice as paid
        vm.prank(creditor);
        bullaInvoice.markInvoiceAsPaid(invoiceId);

        // Verify invoice is marked as paid
        Invoice memory invoiceAfter = bullaInvoice.getInvoice(invoiceId);
        assertEq(uint256(invoiceAfter.status), uint256(Status.Paid), "Invoice should be marked as paid");

        // Verify that no token transfers occurred
        assertEq(debtor.balance, debtorBalanceBefore, "Debtor balance should remain unchanged");
        assertEq(creditor.balance, creditorBalanceBefore, "Creditor balance should remain unchanged");
    }

    function testMarkInvoiceAsPaid_WithPartialPayment() public {
        bullaClaim.permitCreateClaim({
            user: creditor,
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).build();

        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(params);

        bullaClaim.permitPayClaim({
            user: debtor,
            controller: address(bullaInvoice),
            approvalType: PayClaimApprovalType.IsApprovedForAll,
            approvalDeadline: 0,
            paymentApprovals: new ClaimPaymentApprovalParam[](0),
            signature: sigHelper.signPayClaimPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaInvoice),
                approvalType: PayClaimApprovalType.IsApprovedForAll,
                approvalDeadline: 0,
                paymentApprovals: new ClaimPaymentApprovalParam[](0)
            })
        });

        // Make partial payment (0.4 ETH)
        vm.prank(debtor);
        bullaInvoice.payInvoice{value: 0.4 ether}(invoiceId, 0.4 ether);

        // Verify partial payment
        Invoice memory invoiceAfterPayment = bullaInvoice.getInvoice(invoiceId);
        assertEq(uint256(invoiceAfterPayment.status), uint256(Status.Repaying), "Invoice should be repaying");
        assertEq(invoiceAfterPayment.paidAmount, 0.4 ether, "Invoice paid amount should match partial payment");

        // Set up mark as paid permission
        _permitMarkAsPaid(creditorPK, address(bullaInvoice), 1);

        // Mark the invoice as paid
        vm.prank(creditor);
        bullaInvoice.markInvoiceAsPaid(invoiceId);

        // Verify invoice is marked as paid but payment amount is preserved
        Invoice memory invoiceAfterMarkedPaid = bullaInvoice.getInvoice(invoiceId);
        assertEq(uint256(invoiceAfterMarkedPaid.status), uint256(Status.Paid), "Invoice should be marked as paid");
        assertEq(invoiceAfterMarkedPaid.paidAmount, 0.4 ether, "Payment amount should be preserved");
    }

    function testCannotMarkInvoiceAsPaid_NotCreditor() public {
        bullaClaim.permitCreateClaim({
            user: creditor,
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).build();

        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(params);

        // Set up mark as paid permission for all users (so they pass the approval check and reach the NotCreditor validation)
        _permitMarkAsPaid(creditorPK, address(bullaInvoice), 1);
        _permitMarkAsPaid(debtorPK, address(bullaInvoice), 1);
        _permitMarkAsPaid(adminPK, address(bullaInvoice), 1);

        // Debtor cannot mark invoice as paid
        vm.prank(debtor);
        vm.expectRevert(abi.encodeWithSelector(BullaClaimValidationLib.NotCreditor.selector));
        bullaInvoice.markInvoiceAsPaid(invoiceId);

        // Random user cannot mark invoice as paid
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(BullaClaimValidationLib.NotCreditor.selector));
        bullaInvoice.markInvoiceAsPaid(invoiceId);
    }

    function testCannotMarkInvoiceAsPaid_WrongController() public {
        // Create a claim directly via BullaClaim (not through BullaInvoice)
        CreateClaimParams memory params = new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withClaimAmount(1 ether).withToken(address(0)).build();

        vm.prank(creditor);
        uint256 claimId = bullaClaim.createClaim(params);

        // Set up mark as paid permission
        _permitMarkAsPaid(creditorPK, address(bullaInvoice), 1);

        // Try to mark as paid via BullaInvoice - should fail since it's not the controller
        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(BullaClaim.NotController.selector, address(creditor)));
        bullaInvoice.markInvoiceAsPaid(claimId);
    }

    function testMarkInvoiceAsPaid_FromImpairedStatus() public {
        bullaClaim.permitCreateClaim({
            user: creditor,
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        bullaClaim.permitImpairClaim({
            user: creditor,
            controller: address(bullaInvoice),
            approvalCount: 1,
            signature: sigHelper.signImpairClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalCount: 1
            })
        });

        uint256 dueDate = block.timestamp + 30 days;
        CreateInvoiceParams memory params =
            new CreateInvoiceParamsBuilder().withDebtor(debtor).withDueBy(dueDate).build();

        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(params);

        // First impair the invoice
        vm.warp(dueDate + 8 days); // Move past due date + grace period
        vm.prank(creditor);
        bullaInvoice.impairInvoice(invoiceId);

        Invoice memory invoiceAfterImpairment = bullaInvoice.getInvoice(invoiceId);
        assertEq(uint256(invoiceAfterImpairment.status), uint256(Status.Impaired), "Invoice should be impaired");

        // Set up mark as paid permission
        _permitMarkAsPaid(creditorPK, address(bullaInvoice), 1);

        // Then mark it as paid
        vm.prank(creditor);
        bullaInvoice.markInvoiceAsPaid(invoiceId);

        // Verify invoice is marked as paid
        Invoice memory invoiceAfterMarkedPaid = bullaInvoice.getInvoice(invoiceId);
        assertEq(uint256(invoiceAfterMarkedPaid.status), uint256(Status.Paid), "Invoice should be marked as paid");
    }

    function testMarkInvoiceAsPaid_WithPurchaseOrder() public {
        bullaClaim.permitCreateClaim({
            user: creditor,
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Future delivery date (7 days from now)
        uint256 deliveryDate = block.timestamp + 7 days;

        // Create invoice params with delivery date
        CreateInvoiceParams memory params =
            new CreateInvoiceParamsBuilder().withDebtor(debtor).withDeliveryDate(deliveryDate).build();

        // Create an invoice as creditor
        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(params);

        // Mark the purchase order as delivered
        vm.prank(creditor);
        bullaInvoice.deliverPurchaseOrder(invoiceId);

        // Verify purchase order is delivered
        Invoice memory invoiceAfterDelivery = bullaInvoice.getInvoice(invoiceId);
        assertTrue(invoiceAfterDelivery.purchaseOrder.isDelivered, "Purchase order should be delivered");
        assertEq(uint256(invoiceAfterDelivery.status), uint256(Status.Pending), "Invoice should still be pending");

        // Set up mark as paid permission
        _permitMarkAsPaid(creditorPK, address(bullaInvoice), 1);

        // Check balances before marking as paid
        uint256 debtorBalanceBefore = debtor.balance;
        uint256 creditorBalanceBefore = creditor.balance;

        // Mark the invoice as paid
        vm.prank(creditor);
        bullaInvoice.markInvoiceAsPaid(invoiceId);

        // Verify that no exchange of money has taken place
        assertEq(debtor.balance, debtorBalanceBefore, "Debtor balance should remain unchanged");
        assertEq(creditor.balance, creditorBalanceBefore, "Creditor balance should remain unchanged");

        // Verify invoice is marked as paid and purchase order state is preserved
        Invoice memory invoiceAfterMarkedPaid = bullaInvoice.getInvoice(invoiceId);
        assertEq(uint256(invoiceAfterMarkedPaid.status), uint256(Status.Paid), "Invoice should be marked as paid");
        assertTrue(
            invoiceAfterMarkedPaid.purchaseOrder.isDelivered,
            "Purchase order should still be marked as delivered after marking as paid"
        );
        assertEq(
            invoiceAfterMarkedPaid.purchaseOrder.deliveryDate,
            deliveryDate,
            "Delivery date should remain unchanged after marking as paid"
        );
    }

    function testMarkInvoiceAsPaid_WithMetadata() public {
        bullaClaim.permitCreateClaim({
            user: creditor,
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        ClaimMetadata memory metadata =
            ClaimMetadata({tokenURI: "Monthly Service", attachmentURI: "Additional details about this invoice"});

        CreateInvoiceParams memory invoiceParams =
            new CreateInvoiceParamsBuilder().withDebtor(debtor).withDescription("Test Invoice with Metadata").build();

        // Create an invoice with metadata
        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoiceWithMetadata(invoiceParams, metadata);

        // Set up mark as paid permission
        _permitMarkAsPaid(creditorPK, address(bullaInvoice), 1);

        // Mark the invoice as paid
        vm.prank(creditor);
        bullaInvoice.markInvoiceAsPaid(invoiceId);

        // Verify invoice is marked as paid
        Invoice memory invoiceAfter = bullaInvoice.getInvoice(invoiceId);
        assertEq(uint256(invoiceAfter.status), uint256(Status.Paid), "Invoice should be marked as paid");

        // Verify metadata still exists after marking as paid
        (string memory tokenURI, string memory attachmentURI) = bullaClaim.claimMetadata(invoiceId);
        assertEq(tokenURI, "Monthly Service", "Token URI metadata should be preserved");
        assertEq(attachmentURI, "Additional details about this invoice", "Attachment URI metadata should be preserved");
    }

    function testMarkInvoiceAsPaid_AfterOwnershipTransfer() public {
        bullaClaim.permitCreateClaim({
            user: creditor,
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).build();

        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(params);

        // Create new creditor address with a known private key
        uint256 newCreditorPK = uint256(0x1234);
        address newCreditor = vm.addr(newCreditorPK);

        // Transfer invoice to new creditor
        vm.prank(creditor);
        bullaClaim.safeTransferFrom(creditor, newCreditor, invoiceId);

        // Verify ownership transfer
        assertEq(bullaClaim.ownerOf(invoiceId), newCreditor, "New creditor should own the invoice");

        // Set up mark as paid permission for new creditor
        bullaClaim.permitMarkAsPaid({
            user: newCreditor,
            controller: address(bullaInvoice),
            approvalCount: 1,
            signature: sigHelper.signMarkAsPaidPermit({
                pk: newCreditorPK,
                user: newCreditor,
                controller: address(bullaInvoice),
                approvalCount: 1
            })
        });

        // Mark as paid using new creditor
        vm.prank(newCreditor);
        bullaInvoice.markInvoiceAsPaid(invoiceId);

        // Verify invoice is marked as paid
        Invoice memory invoiceAfter = bullaInvoice.getInvoice(invoiceId);
        assertEq(uint256(invoiceAfter.status), uint256(Status.Paid), "Invoice should be marked as paid");
    }

    /*///////////////////////////////////////////////////////////////
                     ACCEPT PURCHASE ORDER TESTS
    //////////////////////////////////////////////////////////////*/

    function testAcceptPurchaseOrder_Success_ETH() public {
        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        bullaClaim.permitPayClaim({
            user: debtor,
            controller: address(bullaInvoice),
            approvalType: PayClaimApprovalType.IsApprovedForAll,
            approvalDeadline: 0,
            paymentApprovals: new ClaimPaymentApprovalParam[](0),
            signature: sigHelper.signPayClaimPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaInvoice),
                approvalType: PayClaimApprovalType.IsApprovedForAll,
                approvalDeadline: 0,
                paymentApprovals: new ClaimPaymentApprovalParam[](0)
            })
        });

        bullaClaim.permitUpdateBinding({
            user: debtor,
            controller: address(bullaInvoice),
            approvalCount: 1,
            signature: sigHelper.signUpdateBindingPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaInvoice),
                approvalCount: 1
            })
        });

        // Create purchase order with deposit amount
        uint256 deliveryDate = block.timestamp + 7 days;
        uint256 depositAmount = 0.3 ether;
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).withClaimAmount(1 ether)
            .withDeliveryDate(deliveryDate).withDepositAmount(depositAmount).build();

        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(params);

        // Verify initial state
        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        assertEq(uint8(invoice.binding), uint8(ClaimBinding.BindingPending), "Invoice should be BindingPending");
        assertEq(invoice.paidAmount, 0, "No payment should have been made yet");
        uint256 remainingDeposit = bullaInvoice.getTotalAmountNeededForPurchaseOrderDeposit(invoiceId);
        assertEq(remainingDeposit, depositAmount, "Remaining deposit should equal full deposit amount");

        // Record balances before acceptance
        uint256 debtorBalanceBefore = debtor.balance;
        uint256 creditorBalanceBefore = creditor.balance;

        // Accept purchase order by paying full deposit
        vm.prank(debtor);
        bullaInvoice.acceptPurchaseOrder{value: depositAmount}(invoiceId, depositAmount);

        // Verify purchase order acceptance
        invoice = bullaInvoice.getInvoice(invoiceId);
        assertEq(uint8(invoice.binding), uint8(ClaimBinding.Bound), "Invoice should be Bound");
        assertEq(invoice.paidAmount, depositAmount, "Paid amount should equal deposit");

        // Verify remaining deposit is now 0
        remainingDeposit = bullaInvoice.getTotalAmountNeededForPurchaseOrderDeposit(invoiceId);
        assertEq(remainingDeposit, 0, "No remaining deposit should be left");

        // Verify token transfers
        assertEq(debtor.balance, debtorBalanceBefore - depositAmount, "Debtor should pay deposit amount");
        assertEq(creditor.balance, creditorBalanceBefore + depositAmount, "Creditor should receive deposit amount");
    }

    function testAcceptPurchaseOrder_Success_ERC20() public {
        // Setup for token payment (using WETH)
        vm.prank(debtor);
        weth.deposit{value: 2 ether}();

        // Approve WETH spending for BullaClaim
        vm.prank(debtor);
        weth.approve(address(bullaClaim), 2 ether);

        // Approve WETH spending for BullaInvoice
        vm.prank(debtor);
        weth.approve(address(bullaInvoice), 2 ether);

        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        bullaClaim.permitPayClaim({
            user: debtor,
            controller: address(bullaInvoice),
            approvalType: PayClaimApprovalType.IsApprovedForAll,
            approvalDeadline: 0,
            paymentApprovals: new ClaimPaymentApprovalParam[](0),
            signature: sigHelper.signPayClaimPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaInvoice),
                approvalType: PayClaimApprovalType.IsApprovedForAll,
                approvalDeadline: 0,
                paymentApprovals: new ClaimPaymentApprovalParam[](0)
            })
        });

        bullaClaim.permitUpdateBinding({
            user: debtor,
            controller: address(bullaInvoice),
            approvalCount: 1,
            signature: sigHelper.signUpdateBindingPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaInvoice),
                approvalCount: 1
            })
        });

        // Create purchase order with deposit amount using WETH
        uint256 deliveryDate = block.timestamp + 7 days;
        uint256 depositAmount = 0.4 ether;
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).withClaimAmount(1 ether)
            .withToken(address(weth)).withDeliveryDate(deliveryDate).withDepositAmount(depositAmount).build();

        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(params);

        // Record balances before acceptance
        uint256 debtorBalanceBefore = weth.balanceOf(debtor);
        uint256 creditorBalanceBefore = weth.balanceOf(creditor);

        // Accept purchase order by paying full deposit (no ETH should be sent)
        vm.prank(debtor);
        bullaInvoice.acceptPurchaseOrder{value: 0}(invoiceId, depositAmount);

        // Verify purchase order acceptance
        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        assertEq(uint8(invoice.binding), uint8(ClaimBinding.Bound), "Invoice should be Bound");
        assertEq(invoice.paidAmount, depositAmount, "Paid amount should equal deposit");

        // Verify token transfers
        assertEq(weth.balanceOf(debtor), debtorBalanceBefore - depositAmount, "Debtor should pay deposit amount");
        assertEq(
            weth.balanceOf(creditor), creditorBalanceBefore + depositAmount, "Creditor should receive deposit amount"
        );
    }

    function testAcceptPurchaseOrder_PartialDeposit() public {
        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        bullaClaim.permitPayClaim({
            user: debtor,
            controller: address(bullaInvoice),
            approvalType: PayClaimApprovalType.IsApprovedForAll,
            approvalDeadline: 0,
            paymentApprovals: new ClaimPaymentApprovalParam[](0),
            signature: sigHelper.signPayClaimPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaInvoice),
                approvalType: PayClaimApprovalType.IsApprovedForAll,
                approvalDeadline: 0,
                paymentApprovals: new ClaimPaymentApprovalParam[](0)
            })
        });

        bullaClaim.permitUpdateBinding({
            user: debtor,
            controller: address(bullaInvoice),
            approvalCount: 1,
            signature: sigHelper.signUpdateBindingPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaInvoice),
                approvalCount: 1
            })
        });

        // Create purchase order with deposit amount
        uint256 deliveryDate = block.timestamp + 7 days;
        uint256 totalDepositAmount = 0.5 ether;
        uint256 partialDepositAmount = 0.3 ether;
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).withClaimAmount(1 ether)
            .withDeliveryDate(deliveryDate).withDepositAmount(totalDepositAmount).build();

        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(params);

        // Accept purchase order by paying partial deposit
        vm.prank(debtor);
        bullaInvoice.acceptPurchaseOrder{value: partialDepositAmount}(invoiceId, partialDepositAmount);

        // Verify purchase order acceptance - should NOT be bound with partial deposit
        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        assertEq(
            uint8(invoice.binding),
            uint8(ClaimBinding.BindingPending),
            "Invoice should remain BindingPending with partial deposit"
        );
        assertEq(invoice.paidAmount, partialDepositAmount, "Paid amount should equal partial deposit");

        // Verify remaining deposit
        uint256 remainingDeposit = bullaInvoice.getTotalAmountNeededForPurchaseOrderDeposit(invoiceId);
        assertEq(
            remainingDeposit,
            totalDepositAmount - partialDepositAmount,
            "Remaining deposit should be calculated correctly"
        );
        assertTrue(remainingDeposit > 0, "Should still have remaining deposit amount");

        // Now pay the remaining deposit to complete the binding
        uint256 finalDepositAmount = remainingDeposit;
        vm.prank(debtor);
        bullaInvoice.acceptPurchaseOrder{value: finalDepositAmount}(invoiceId, finalDepositAmount);

        // Verify purchase order is now bound after full deposit
        invoice = bullaInvoice.getInvoice(invoiceId);
        assertEq(
            uint8(invoice.binding), uint8(ClaimBinding.Bound), "Invoice should be Bound after full deposit is paid"
        );
        assertEq(invoice.paidAmount, totalDepositAmount, "Total paid amount should equal full deposit");

        // Verify no remaining deposit
        remainingDeposit = bullaInvoice.getTotalAmountNeededForPurchaseOrderDeposit(invoiceId);
        assertEq(remainingDeposit, 0, "No remaining deposit should be left");
    }

    function testAcceptPurchaseOrder_ZeroDeposit() public {
        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        bullaClaim.permitUpdateBinding({
            user: debtor,
            controller: address(bullaInvoice),
            approvalCount: 1,
            signature: sigHelper.signUpdateBindingPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaInvoice),
                approvalCount: 1
            })
        });

        // Create purchase order with zero deposit amount
        uint256 deliveryDate = block.timestamp + 7 days;
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).withClaimAmount(1 ether)
            .withDeliveryDate(deliveryDate).withDepositAmount(0).build();

        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(params);

        // Accept purchase order with no payment
        vm.prank(debtor);
        bullaInvoice.acceptPurchaseOrder{value: 0}(invoiceId, 0);

        // Verify purchase order acceptance
        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        assertEq(uint8(invoice.binding), uint8(ClaimBinding.Bound), "Invoice should be Bound");
        assertEq(invoice.paidAmount, 0, "No payment should have been made");
    }

    function testAcceptPurchaseOrder_NotAuthorized() public {
        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Create purchase order
        uint256 deliveryDate = block.timestamp + 7 days;
        uint256 depositAmount = 0.3 ether;
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).withClaimAmount(1 ether)
            .withDeliveryDate(deliveryDate).withDepositAmount(depositAmount).build();

        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(params);

        // Try to accept from non-debtor account
        address randomUser = address(0x1234);
        vm.deal(randomUser, 1 ether);
        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorizedForBinding.selector));
        bullaInvoice.acceptPurchaseOrder{value: depositAmount}(invoiceId, depositAmount);

        // Try to accept from creditor account
        vm.deal(creditor, 1 ether);
        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorizedForBinding.selector));
        bullaInvoice.acceptPurchaseOrder{value: depositAmount}(invoiceId, depositAmount);
    }

    function testAcceptPurchaseOrder_ExceedsRemainingDeposit() public {
        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        bullaClaim.permitPayClaim({
            user: debtor,
            controller: address(bullaInvoice),
            approvalType: PayClaimApprovalType.IsApprovedForAll,
            approvalDeadline: 0,
            paymentApprovals: new ClaimPaymentApprovalParam[](0),
            signature: sigHelper.signPayClaimPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaInvoice),
                approvalType: PayClaimApprovalType.IsApprovedForAll,
                approvalDeadline: 0,
                paymentApprovals: new ClaimPaymentApprovalParam[](0)
            })
        });

        bullaClaim.permitUpdateBinding({
            user: debtor,
            controller: address(bullaInvoice),
            approvalCount: 1,
            signature: sigHelper.signUpdateBindingPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaInvoice),
                approvalCount: 1
            })
        });

        // Create purchase order
        uint256 deliveryDate = block.timestamp + 7 days;
        uint256 depositAmount = 0.3 ether;
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).withClaimAmount(1 ether)
            .withDeliveryDate(deliveryDate).withDepositAmount(depositAmount).build();

        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(params);

        // Try to accept with amount exceeding the deposit requirement
        uint256 excessiveAmount = depositAmount + 0.1 ether;
        vm.prank(debtor);
        bullaInvoice.acceptPurchaseOrder{value: excessiveAmount}(invoiceId, excessiveAmount);

        // Verify the purchase order is accepted and paid amount is the excessive amount
        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        assertEq(uint8(invoice.binding), uint8(ClaimBinding.Bound), "Invoice should be Bound");
        assertEq(invoice.paidAmount, excessiveAmount, "Paid amount should be the excessive amount");
    }

    function testAcceptPurchaseOrder_ExceedsClaimAmount() public {
        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Create purchase order where deposit equals full claim amount
        uint256 deliveryDate = block.timestamp + 7 days;
        uint256 claimAmount = 1 ether;
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).withClaimAmount(
            claimAmount
        ).withDeliveryDate(deliveryDate).withDepositAmount(claimAmount) // Full amount as deposit
            .build();

        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(params);

        // Try to accept with amount exceeding the claim amount
        uint256 excessiveAmount = claimAmount + 0.1 ether;
        vm.prank(debtor);
        vm.expectRevert(abi.encodeWithSelector(InvalidDepositAmount.selector));
        bullaInvoice.acceptPurchaseOrder{value: excessiveAmount}(invoiceId, excessiveAmount);
    }

    function testAcceptPurchaseOrder_InvalidMsgValue_ETH() public {
        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Create ETH purchase order
        uint256 deliveryDate = block.timestamp + 7 days;
        uint256 depositAmount = 0.3 ether;
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).withClaimAmount(1 ether)
            .withToken(address(0)).withDeliveryDate(deliveryDate).withDepositAmount(depositAmount) // ETH
            .build();

        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(params);

        // Try to accept with mismatched msg.value (sending less than deposit amount)
        vm.prank(debtor);
        vm.expectRevert(abi.encodeWithSelector(InvalidMsgValue.selector));
        bullaInvoice.acceptPurchaseOrder{value: 0.2 ether}(invoiceId, depositAmount);

        // Try to accept with mismatched msg.value (sending more than deposit amount)
        vm.prank(debtor);
        vm.expectRevert(abi.encodeWithSelector(InvalidMsgValue.selector));
        bullaInvoice.acceptPurchaseOrder{value: 0.4 ether}(invoiceId, depositAmount);
    }

    function testAcceptPurchaseOrder_InvalidMsgValue_ERC20() public {
        // Setup for token payment (using WETH)
        vm.prank(debtor);
        weth.deposit{value: 2 ether}();
        vm.prank(debtor);
        weth.approve(address(bullaClaim), 2 ether);

        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Create ERC20 purchase order
        uint256 deliveryDate = block.timestamp + 7 days;
        uint256 depositAmount = 0.3 ether;
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).withClaimAmount(1 ether)
            .withToken(address(weth)).withDeliveryDate(deliveryDate).withDepositAmount(depositAmount) // ERC20
            .build();

        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(params);

        // Try to accept with non-zero msg.value for ERC20 token
        vm.prank(debtor);
        vm.expectRevert(abi.encodeWithSelector(InvalidMsgValue.selector));
        bullaInvoice.acceptPurchaseOrder{value: 0.1 ether}(invoiceId, depositAmount);
    }

    function testAcceptPurchaseOrder_ZeroDepositInvalidMsgValue() public {
        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Create purchase order with zero deposit
        uint256 deliveryDate = block.timestamp + 7 days;
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).withClaimAmount(1 ether)
            .withDeliveryDate(deliveryDate).withDepositAmount(0).build();

        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(params);

        // Try to accept with non-zero msg.value when no payment needed
        vm.prank(debtor);
        vm.expectRevert(abi.encodeWithSelector(InvalidMsgValue.selector));
        bullaInvoice.acceptPurchaseOrder{value: 0.1 ether}(invoiceId, 0);
    }

    function testAcceptPurchaseOrder_NotPurchaseOrder() public {
        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Create regular invoice (not a purchase order)
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).withClaimAmount(1 ether)
            .withDeliveryDate(0).withDepositAmount(0) // No delivery date = not a purchase order
            .build();

        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(params);

        // Verify it's not a purchase order
        uint256 remainingDeposit = bullaInvoice.getTotalAmountNeededForPurchaseOrderDeposit(invoiceId);
        assertEq(remainingDeposit, 0, "Should not be a purchase order");

        // Try to accept as purchase order - should fail with NotPurchaseOrder error
        vm.prank(debtor);
        vm.expectRevert(abi.encodeWithSelector(NotPurchaseOrder.selector));
        bullaInvoice.acceptPurchaseOrder{value: 0}(invoiceId, 0);
    }

    function testAcceptPurchaseOrder_AfterPartialPayment() public {
        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        bullaClaim.permitPayClaim({
            user: debtor,
            controller: address(bullaInvoice),
            approvalType: PayClaimApprovalType.IsApprovedForAll,
            approvalDeadline: 0,
            paymentApprovals: new ClaimPaymentApprovalParam[](0),
            signature: sigHelper.signPayClaimPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaInvoice),
                approvalType: PayClaimApprovalType.IsApprovedForAll,
                approvalDeadline: 0,
                paymentApprovals: new ClaimPaymentApprovalParam[](0)
            })
        });

        bullaClaim.permitUpdateBinding({
            user: debtor,
            controller: address(bullaInvoice),
            approvalCount: 1,
            signature: sigHelper.signUpdateBindingPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaInvoice),
                approvalCount: 1
            })
        });

        // Create purchase order with deposit amount
        uint256 deliveryDate = block.timestamp + 7 days;
        uint256 depositAmount = 0.5 ether;
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).withClaimAmount(1 ether)
            .withDeliveryDate(deliveryDate).withDepositAmount(depositAmount).build();

        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(params);

        // Make partial payment first
        uint256 partialPayment = 0.2 ether;
        vm.prank(debtor);
        bullaInvoice.payInvoice{value: partialPayment}(invoiceId, partialPayment);

        // Verify partial payment
        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        assertEq(invoice.paidAmount, partialPayment, "Partial payment should be recorded");

        // Check remaining deposit
        uint256 remainingDeposit = bullaInvoice.getTotalAmountNeededForPurchaseOrderDeposit(invoiceId);
        assertEq(remainingDeposit, depositAmount - partialPayment, "Remaining deposit should be reduced");

        // Accept purchase order with remaining deposit amount
        vm.prank(debtor);
        bullaInvoice.acceptPurchaseOrder{value: remainingDeposit}(invoiceId, remainingDeposit);

        // Verify final state
        invoice = bullaInvoice.getInvoice(invoiceId);
        assertEq(uint8(invoice.binding), uint8(ClaimBinding.Bound), "Invoice should be Bound");
        assertEq(invoice.paidAmount, depositAmount, "Total paid should equal deposit amount");

        // Verify no remaining deposit
        remainingDeposit = bullaInvoice.getTotalAmountNeededForPurchaseOrderDeposit(invoiceId);
        assertEq(remainingDeposit, 0, "No remaining deposit should be left");
    }

    function testAcceptPurchaseOrder_WrongController() public {
        // Create a claim directly via BullaClaim (not through BullaInvoice)
        CreateClaimParams memory params =
            new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor).withClaimAmount(1 ether).build();

        vm.prank(creditor);
        uint256 claimId = bullaClaim.createClaim(params);

        // Try to accept via BullaInvoice - should fail since it's not the controller
        vm.prank(debtor);
        vm.expectRevert(abi.encodeWithSelector(BullaClaim.NotController.selector, address(debtor)));
        bullaInvoice.acceptPurchaseOrder{value: 0}(claimId, 0);
    }

    /*///////////////////////////////////////////////////////////////
                     DEPOSIT AMOUNT VALIDATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testCreateInvoice_DepositAmountExceedsClaimAmount() public {
        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Try to create invoice with deposit larger than claim amount
        uint256 claimAmount = 1 ether;
        uint256 depositAmount = 1.5 ether; // Larger than claim amount
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).withClaimAmount(
            claimAmount
        ).withDepositAmount(depositAmount).build();

        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(InvalidDepositAmount.selector));
        bullaInvoice.createInvoice(params);
    }

    function testCreateInvoiceWithMetadata_DepositAmountExceedsClaimAmount() public {
        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Create metadata
        ClaimMetadata memory metadata =
            ClaimMetadata({tokenURI: "Invalid Invoice", attachmentURI: "Deposit exceeds claim amount"});

        // Try to create invoice with metadata and deposit larger than claim amount
        uint256 claimAmount = 1 ether;
        uint256 depositAmount = 2 ether; // Larger than claim amount
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).withClaimAmount(
            claimAmount
        ).withDepositAmount(depositAmount).build();

        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(InvalidDepositAmount.selector));
        bullaInvoice.createInvoiceWithMetadata(params, metadata);
    }

    function testAcceptPurchaseOrder_InsufficientPayment_WithAccruedInterest() public {
        // Setup permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        bullaClaim.permitPayClaim({
            user: debtor,
            controller: address(bullaInvoice),
            approvalType: PayClaimApprovalType.IsApprovedForAll,
            approvalDeadline: 0,
            paymentApprovals: new ClaimPaymentApprovalParam[](0),
            signature: sigHelper.signPayClaimPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaInvoice),
                approvalType: PayClaimApprovalType.IsApprovedForAll,
                approvalDeadline: 0,
                paymentApprovals: new ClaimPaymentApprovalParam[](0)
            })
        });

        bullaClaim.permitUpdateBinding({
            user: debtor,
            controller: address(bullaInvoice),
            approvalCount: 1,
            signature: sigHelper.signUpdateBindingPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaInvoice),
                approvalCount: 1
            })
        });

        // Create purchase order with deposit amount and late fee configuration
        uint256 deliveryDate = block.timestamp + 7 days;
        uint256 depositAmount = 0.5 ether;
        uint256 dueBy = block.timestamp + 30 days; // Due in 30 days

        InterestConfig memory lateFeeConfig = InterestConfig({
            interestRateBps: 1000, // 10% annual interest rate
            numberOfPeriodsPerYear: 365 // Daily compounding
        });

        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).withClaimAmount(1 ether)
            .withDueBy(dueBy).withDeliveryDate(deliveryDate).withDepositAmount(depositAmount).withLateFeeConfig(
            lateFeeConfig
        ).build();

        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(params);

        // Fast forward time to after the due date to accrue interest
        vm.warp(dueBy + 365 days); // 1 year past due date

        // Get the current invoice to check accrued interest
        Invoice memory invoiceBefore = bullaInvoice.getInvoice(invoiceId);
        assertTrue(invoiceBefore.interestComputationState.accruedInterest > 0, "Interest should have accrued");

        // Check the amounts excluding accrued interest
        uint256 remainingPrincipalDepositExcludingInterest = depositAmount - invoiceBefore.paidAmount;

        // Record balances before payment
        uint256 debtorBalanceBefore = debtor.balance;
        uint256 creditorBalanceBefore = creditor.balance;

        // Attempt to accept purchase order by paying only the principal deposit amount (insufficient)
        vm.prank(debtor);
        bullaInvoice.acceptPurchaseOrder{value: remainingPrincipalDepositExcludingInterest}(
            invoiceId, remainingPrincipalDepositExcludingInterest
        );

        // Verify that the binding was NOT updated to Bound because payment was insufficient
        Invoice memory invoiceAfter = bullaInvoice.getInvoice(invoiceId);
        assertEq(
            uint8(invoiceAfter.binding),
            uint8(ClaimBinding.BindingPending),
            "Invoice should remain BindingPending because payment was insufficient"
        );

        // Verify partial payment was made (some interest + partial principal)
        assertTrue(invoiceAfter.paidAmount > 0, "Some payment should have been made");

        // Verify there's still an amount needed to complete the deposit
        uint256 remainingAmountNeeded = bullaInvoice.getTotalAmountNeededForPurchaseOrderDeposit(invoiceId);
        assertTrue(remainingAmountNeeded > 0, "There should still be an amount needed to complete the deposit");

        // Now pay the remaining amount needed to complete the deposit
        vm.prank(debtor);
        bullaInvoice.acceptPurchaseOrder{value: remainingAmountNeeded}(invoiceId, remainingAmountNeeded);

        // Verify that the binding is updated to Bound
        Invoice memory invoiceFinal = bullaInvoice.getInvoice(invoiceId);
        assertEq(
            uint8(invoiceFinal.binding),
            uint8(ClaimBinding.Bound),
            "Invoice should now be Bound after paying the full amount needed"
        );

        // Verify no remaining amount is needed
        uint256 finalAmountNeeded = bullaInvoice.getTotalAmountNeededForPurchaseOrderDeposit(invoiceId);
        assertEq(finalAmountNeeded, 0, "No remaining amount should be needed");
    }
}
