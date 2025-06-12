// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.14;

import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import "contracts/types/Types.sol";
import {WETH} from "contracts/mocks/weth.sol";
import {EIP712Helper, privateKeyValidity} from "test/foundry/BullaClaim/EIP712/Utils.sol";
import {BullaClaim} from "contracts/BullaClaim.sol";
import {
    BullaInvoice,
    CreateInvoiceParams,
    Invoice,
    InvalidDeliveryDate,
    NotOriginalCreditor,
    PurchaseOrderAlreadyDelivered,
    InvoiceNotPending,
    PurchaseOrderState,
    InvoiceDetails,
    NotPurchaseOrder,
    PayingZero,
    InvalidProtocolFee,
    NotAdmin,
    WithdrawalFailed,
    IncorrectMsgValue,
    IncorrectFee,
    InvalidDepositAmount
} from "contracts/BullaInvoice.sol";
import {InvoiceDetailsBuilder} from "test/foundry/BullaInvoice/InvoiceDetailsBuilder.t.sol";
import {Deployer} from "script/Deployment.s.sol";
import {CreateInvoiceParamsBuilder} from "test/foundry/BullaInvoice/CreateInvoiceParamsBuilder.sol";
import {BullaClaimValidationLib} from "contracts/libraries/BullaClaimValidationLib.sol";
import {InterestConfig, InterestComputationState} from "contracts/libraries/CompoundInterestLib.sol";
import {ERC20Mock} from "openzeppelin-contracts/contracts/mocks/ERC20Mock.sol";

contract TestCreateSelfBillingInvoice is Test {
    WETH public weth;
    BullaClaim public bullaClaim;
    EIP712Helper public sigHelper;
    BullaInvoice public bullaInvoice;
    ERC20Mock public testToken;

    uint256 constant INVOICE_ORIGINATION_FEE = 0.01 ether;
    uint256 constant PURCHASE_ORDER_ORIGINATION_FEE = 0.02 ether;
    uint256 debtorPK = uint256(0x01);
    uint256 creditorPK = uint256(0x02);
    uint256 adminPK = uint256(0x03);
    address debtor = vm.addr(debtorPK);
    address creditor = vm.addr(creditorPK);
    address admin = vm.addr(adminPK);

    event InvoiceCreated(uint256 indexed claimId, InvoiceDetails invoiceDetails, uint256 originationFee);
    event ClaimCreated(
        uint256 indexed claimId,
        address from,
        address indexed creditor,
        address indexed debtor,
        uint256 claimAmount,
        string description,
        address token,
        address controller,
        ClaimBinding binding
    );

    function setUp() public {
        weth = new WETH();
        testToken = new ERC20Mock("Test Token", "TEST", address(this), 1000000 ether);

        bullaClaim = (new Deployer()).deploy_test({_deployer: address(this), _initialLockState: LockState.Unlocked});
        sigHelper = new EIP712Helper(address(bullaClaim));

        // Main invoice contract with origination fees
        bullaInvoice =
            new BullaInvoice(address(bullaClaim), admin, 0, INVOICE_ORIGINATION_FEE, PURCHASE_ORDER_ORIGINATION_FEE);

        // Setup balances
        vm.deal(debtor, 100 ether);
        vm.deal(creditor, 100 ether);

        // Give test tokens to both parties
        testToken.transfer(debtor, 10000 ether);
        testToken.transfer(creditor, 10000 ether);

        // Setup permissions for debtor to create invoices
        _setupDebtorPermissions();
    }

    function _setupDebtorPermissions() internal {
        // Setup create claim permissions for debtor (self-billing)
        bullaClaim.permitCreateClaim({
            user: debtor,
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: type(uint64).max,
            isBindingAllowed: true, // Allow debtor to create bound claims
            signature: sigHelper.signCreateClaimPermit({
                pk: debtorPK,
                user: debtor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: type(uint64).max,
                isBindingAllowed: true
            })
        });

        // Setup pay claim permissions for creditor (to pay debtor-created invoices)
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
    }

    // ==================== BASIC SELF BILLING TESTS ====================

    function testCreateSelfBillingInvoice() public {
        // Create invoice params where debtor creates invoice
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withClaimAmount(5 ether).withDescription("Self-billing invoice - payment request").withToken(address(0))
            .withDueBy(block.timestamp + 30 days) // ETH
            .build();

        uint256 contractBalanceBefore = address(bullaInvoice).balance;

        // Expected InvoiceDetails struct for self-billing invoice
        InvoiceDetails memory expectedInvoiceDetails =
            new InvoiceDetailsBuilder().withRequestedByCreditor(false).build();

        // Expect ClaimCreated event with debtor as creator and creditor as recipient
        vm.expectEmit(true, true, true, true);
        emit ClaimCreated(
            1,
            debtor, // from (creator)
            creditor, // creditor (who will receive the NFT)
            debtor, // debtor (who owes the payment)
            5 ether, // claimAmount
            "Self-billing invoice - payment request", // description
            address(0), // token (ETH)
            address(bullaInvoice), // controller
            ClaimBinding.BindingPending // binding
        );

        // Expect InvoiceCreated event
        vm.expectEmit(true, false, false, true);
        emit InvoiceCreated(1, expectedInvoiceDetails, INVOICE_ORIGINATION_FEE);

        // Debtor creates self-billing invoice
        vm.prank(debtor);
        uint256 invoiceId = bullaInvoice.createInvoice{value: INVOICE_ORIGINATION_FEE}(params);

        // Verify fee was sent to contract
        assertEq(
            address(bullaInvoice).balance - contractBalanceBefore,
            INVOICE_ORIGINATION_FEE,
            "Contract should hold the origination fee"
        );

        // Verify invoice was created successfully
        assertTrue(invoiceId > 0, "Invoice should be created");

        // Verify the claim structure
        Claim memory claim = bullaClaim.getClaim(invoiceId);
        assertEq(claim.debtor, debtor, "Debtor should be set correctly");
        assertEq(claim.creditor, creditor, "Creditor should be set correctly");
        assertEq(claim.originalCreditor, creditor, "Original creditor should be set correctly");
        assertEq(claim.claimAmount, 5 ether, "Claim amount should match");
        assertEq(claim.token, address(0), "Token should be ETH");
        assertTrue(claim.status == Status.Pending, "Status should be Pending");
        assertTrue(claim.binding == ClaimBinding.BindingPending, "Binding should be BindingPending");

        // Verify the creditor owns the NFT (can receive payments)
        assertEq(bullaClaim.ownerOf(invoiceId), creditor, "Creditor should own the invoice NFT");

        // Verify invoice details
        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        assertEq(invoice.claimAmount, 5 ether, "Invoice claim amount should match");
        assertEq(invoice.debtor, debtor, "Invoice debtor should match");
        assertEq(invoice.creditor, creditor, "Invoice creditor should match");
        assertEq(invoice.purchaseOrder.deliveryDate, 0, "Should not be a purchase order");
    }

    function testCreateSelfBillingInvoiceWithERC20Token() public {
        // Create invoice params for ERC20 token payment
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withClaimAmount(1000 ether).withDescription("ERC20 self-billing invoice").withToken(address(testToken))
            .withDueBy(block.timestamp + 15 days).build();

        // Debtor creates self-billing invoice for ERC20 payment
        vm.prank(debtor);
        uint256 invoiceId = bullaInvoice.createInvoice{value: INVOICE_ORIGINATION_FEE}(params);

        // Verify invoice was created successfully
        assertTrue(invoiceId > 0, "Invoice should be created");

        // Verify the claim structure for ERC20
        Claim memory claim = bullaClaim.getClaim(invoiceId);
        assertEq(claim.debtor, debtor, "Debtor should be set correctly");
        assertEq(claim.creditor, creditor, "Creditor should be set correctly");
        assertEq(claim.claimAmount, 1000 ether, "Claim amount should match");
        assertEq(claim.token, address(testToken), "Token should be test token");

        // Verify the creditor owns the NFT
        assertEq(bullaClaim.ownerOf(invoiceId), creditor, "Creditor should own the invoice NFT");
    }

    function testCreateSelfBillingInvoiceWithBoundStatus() public {
        // Create invoice params with bound status
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withClaimAmount(2 ether).withDescription("Bound self-billing invoice").withToken(address(0)).withBinding(
            ClaimBinding.Bound
        ) // Debtor can bind themselves
            .build();

        // Debtor creates bound self-billing invoice
        vm.prank(debtor);
        uint256 invoiceId = bullaInvoice.createInvoice{value: INVOICE_ORIGINATION_FEE}(params);

        // Verify the claim is bound
        Claim memory claim = bullaClaim.getClaim(invoiceId);
        assertTrue(claim.binding == ClaimBinding.Bound, "Claim should be bound");
        assertEq(claim.debtor, debtor, "Debtor should be set correctly");
        assertEq(claim.originalCreditor, creditor, "Creditor should be set correctly");
    }

    function testCreateSelfBillingInvoiceWithInterest() public {
        // Create interest config
        InterestConfig memory interestConfig = InterestConfig({
            interestRateBps: 500, // 5% APR
            numberOfPeriodsPerYear: 12 // Monthly compounding
        });

        // Create invoice params with interest
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withClaimAmount(10 ether).withDescription("Self-billing invoice with interest").withToken(address(0))
            .withLateFeeConfig(interestConfig).withDueBy(block.timestamp + 60 days).build();

        // Debtor creates self-billing invoice with interest
        vm.prank(debtor);
        uint256 invoiceId = bullaInvoice.createInvoice{value: INVOICE_ORIGINATION_FEE}(params);

        // Verify invoice was created successfully
        assertTrue(invoiceId > 0, "Invoice should be created");

        // Verify the invoice details
        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        assertEq(invoice.lateFeeConfig.interestRateBps, 500, "Interest rate should match");
        assertEq(invoice.lateFeeConfig.numberOfPeriodsPerYear, 12, "Periods per year should match");
        assertEq(invoice.debtor, debtor, "Debtor should be set correctly");
    }

    // ==================== PURCHASE ORDER TESTS ====================

    function testCreateSelfBillingPurchaseOrder() public {
        uint256 deliveryDate = block.timestamp + 7 days;
        uint256 depositAmount = 1 ether;

        // Create purchase order params
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withClaimAmount(5 ether).withDescription("Self-billing purchase order").withToken(address(0)).withDeliveryDate(
            deliveryDate
        ).withDepositAmount(depositAmount).build();

        // Expected InvoiceDetails struct for self-billing purchase order
        InvoiceDetails memory expectedInvoiceDetails = new InvoiceDetailsBuilder().withRequestedByCreditor(false)
            .withDeliveryDate(deliveryDate).withDepositAmount(depositAmount).build();

        // Expect InvoiceCreated event
        vm.expectEmit(true, false, false, true);
        emit InvoiceCreated(1, expectedInvoiceDetails, PURCHASE_ORDER_ORIGINATION_FEE);

        // Debtor creates self-billing purchase order
        vm.prank(debtor);
        uint256 invoiceId = bullaInvoice.createInvoice{value: PURCHASE_ORDER_ORIGINATION_FEE}(params);

        // Verify purchase order was created
        assertTrue(invoiceId > 0, "Purchase order should be created");

        // Verify the invoice details
        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        assertEq(invoice.purchaseOrder.deliveryDate, deliveryDate, "Delivery date should match");
        assertEq(invoice.purchaseOrder.depositAmount, depositAmount, "Deposit amount should match");
        assertFalse(invoice.purchaseOrder.isDelivered, "Should not be delivered initially");
        assertEq(invoice.debtor, debtor, "Debtor should be set correctly");

        // Verify the creditor owns the NFT
        assertEq(bullaClaim.ownerOf(invoiceId), creditor, "Creditor should own the purchase order NFT");
    }

    // ==================== VALIDATION TESTS ====================

    function testSelfBillingMustPayCorrectOriginationFee() public {
        CreateInvoiceParams memory params =
            new CreateInvoiceParamsBuilder().withCreditor(creditor).withDebtor(debtor).withClaimAmount(5 ether).build();

        // Try with wrong fee
        vm.prank(debtor);
        vm.expectRevert(IncorrectFee.selector);
        bullaInvoice.createInvoice{value: INVOICE_ORIGINATION_FEE + 0.001 ether}(params);

        // Try with no fee
        vm.prank(debtor);
        vm.expectRevert(IncorrectFee.selector);
        bullaInvoice.createInvoice{value: 0}(params);
    }

    function testSelfBillingMustPayCorrectPurchaseOrderFee() public {
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withClaimAmount(5 ether).withDeliveryDate(block.timestamp + 7 days).build();

        // Try with invoice fee instead of purchase order fee
        vm.prank(debtor);
        vm.expectRevert(IncorrectFee.selector);
        bullaInvoice.createInvoice{value: INVOICE_ORIGINATION_FEE}(params);

        // Try with wrong purchase order fee
        vm.prank(debtor);
        vm.expectRevert(IncorrectFee.selector);
        bullaInvoice.createInvoice{value: PURCHASE_ORDER_ORIGINATION_FEE + 0.001 ether}(params);
    }

    function testSelfBillingInvalidDeliveryDate() public {
        vm.warp(30 days);

        // Create invoice params with past delivery date
        uint256 pastDeliveryDate = block.timestamp - 1 days;
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withDeliveryDate(pastDeliveryDate).build();

        // Create should revert with InvalidDeliveryDate
        vm.prank(debtor);
        vm.expectRevert(InvalidDeliveryDate.selector);
        bullaInvoice.createInvoice{value: PURCHASE_ORDER_ORIGINATION_FEE}(params);

        // Create invoice params with future delivery date beyond uint40
        uint256 farFutureDeliveryDate = uint256(type(uint40).max) + 1;
        params = new CreateInvoiceParamsBuilder().withCreditor(creditor).withDebtor(debtor).withDeliveryDate(
            farFutureDeliveryDate
        ).build();

        // Create should revert with InvalidDeliveryDate
        vm.prank(debtor);
        vm.expectRevert(InvalidDeliveryDate.selector);
        bullaInvoice.createInvoice{value: PURCHASE_ORDER_ORIGINATION_FEE}(params);
    }

    function testSelfBillingInvalidDepositAmount() public {
        // Try to create self-billing invoice with deposit larger than claim amount
        uint256 claimAmount = 1 ether;
        uint256 depositAmount = 2 ether; // Larger than claim amount
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withClaimAmount(claimAmount).withDepositAmount(depositAmount).build();

        vm.prank(debtor);
        vm.expectRevert(abi.encodeWithSelector(InvalidDepositAmount.selector));
        bullaInvoice.createInvoice{value: INVOICE_ORIGINATION_FEE}(params);
    }

    // ==================== PAYMENT FLOW TESTS ====================

    function testDebtorCanPaySelfBillingInvoice() public {
        // Debtor creates self-billing invoice
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withClaimAmount(2 ether).withDescription("Self-billing invoice to be paid by debtor").withToken(address(0))
            .build();

        vm.prank(debtor);
        uint256 invoiceId = bullaInvoice.createInvoice{value: INVOICE_ORIGINATION_FEE}(params);

        // Verify initial state
        Claim memory claim = bullaClaim.getClaim(invoiceId);
        assertEq(claim.paidAmount, 0, "Initial paid amount should be zero");
        assertTrue(claim.status == Status.Pending, "Status should be Pending");

        uint256 debtorBalanceBefore = debtor.balance;

        // debtor pays the self-billing invoice
        vm.prank(debtor);
        bullaInvoice.payInvoice{value: 2 ether}(invoiceId, 2 ether);

        // Verify payment was processed
        claim = bullaClaim.getClaim(invoiceId);
        assertEq(claim.paidAmount, 2 ether, "Paid amount should be 2 ether");
        assertTrue(claim.status == Status.Paid, "Status should be Paid");

        // Verify debtor's balance decreased by payment amount
        assertEq(debtor.balance, debtorBalanceBefore - 2 ether, "debtor balance should decrease");
    }

    // ==================== FUZZING TESTS ====================

    function testFuzz_CreateSelfBillingInvoice(uint256 amount, uint256 dueBy) public {
        // Constrain input values
        amount = bound(amount, 0.1 ether, 100 ether);
        dueBy = bound(dueBy, block.timestamp + 1 days, type(uint40).max);

        // Create invoice params with fuzzing values
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withClaimAmount(amount).withDueBy(dueBy).withDescription("Fuzz Test Self-Billing Invoice").build();

        // Create a self-billing invoice
        vm.prank(debtor);
        uint256 invoiceId = bullaInvoice.createInvoice{value: INVOICE_ORIGINATION_FEE}(params);

        // Verify invoice was created correctly
        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        assertEq(invoice.claimAmount, amount, "Invoice claim amount mismatch");
        assertEq(invoice.dueBy, dueBy, "Invoice due date mismatch");
    }
}
