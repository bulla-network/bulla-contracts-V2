pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import "contracts/types/Types.sol";
import {WETH} from "contracts/mocks/weth.sol";
import {EIP712Helper, privateKeyValidity} from "test/foundry/BullaClaim/EIP712/Utils.sol";
import {BullaClaimV2} from "contracts/BullaClaimV2.sol";
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
import {DeployContracts} from "script/DeployContracts.s.sol";
import {CreateInvoiceParamsBuilder} from "test/foundry/BullaInvoice/CreateInvoiceParamsBuilder.sol";
import {BullaClaimValidationLib} from "contracts/libraries/BullaClaimValidationLib.sol";
import {InterestConfig, InterestComputationState} from "contracts/libraries/CompoundInterestLib.sol";
import {ERC20MockLegacy as ERC20Mock} from "contracts/mocks/ERC20MockLegacy.sol";

contract TestCreateSelfBillingInvoiceWithMetadata is Test {
    WETH public weth;
    BullaClaimV2 public bullaClaim;
    EIP712Helper public sigHelper;
    BullaInvoice public bullaInvoice;
    ERC20Mock public testToken;

    uint256 constant CORE_PROTOCOL_FEE = 0.01 ether;
    uint256 debtorPK = uint256(0x01);
    uint256 creditorPK = uint256(0x02);
    uint256 adminPK = uint256(0x03);
    address debtor = vm.addr(debtorPK);
    address creditor = vm.addr(creditorPK);
    address admin = vm.addr(adminPK);

    event InvoiceCreated(uint256 indexed claimId, InvoiceDetails invoiceDetails, uint256 fee, ClaimMetadata metadata);
    event ClaimCreated(
        uint256 indexed claimId,
        address from,
        address indexed creditor,
        address indexed debtor,
        uint256 claimAmount,
        uint256 dueBy,
        string description,
        address token,
        address controller,
        ClaimBinding binding
    );

    function setUp() public {
        weth = new WETH();
        testToken = new ERC20Mock("Test Token", "TEST", address(this), 1000000 ether);

        DeployContracts.DeploymentResult memory deploymentResult = (new DeployContracts()).deployForTest(
            address(this), LockState.Unlocked, CORE_PROTOCOL_FEE, 0, 0, 0, address(this)
        );
        bullaClaim = BullaClaimV2(deploymentResult.bullaClaim);
        sigHelper = new EIP712Helper(address(bullaClaim));

        // Main invoice contract with origination fees
        bullaInvoice = new BullaInvoice(address(bullaClaim), admin, 0);

        // Setup balances
        vm.deal(debtor, 100 ether);
        vm.deal(creditor, 100 ether);
        vm.deal(admin, 100 ether);

        // Give test tokens to both parties
        testToken.transfer(debtor, 10000 ether);
        testToken.transfer(creditor, 10000 ether);

        // Setup permissions for debtor to create invoices
        _setupDebtorPermissions();
    }

    function _setupDebtorPermissions() internal {
        // Setup create claim permissions for debtor (self-billing)
        bullaClaim.approvalRegistry().permitCreateClaim({
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
    }

    // ==================== BASIC SELF BILLING WITH METADATA TESTS ====================

    function testCreateSelfBillingInvoiceWithMetadata() public {
        // Create metadata
        ClaimMetadata memory metadata = ClaimMetadata({
            tokenURI: "https://example.com/self-billing-invoice",
            attachmentURI: "https://example.com/self-billing-attachment"
        });

        // Create invoice params where debtor creates invoice
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withClaimAmount(5 ether).withDescription("Self-billing invoice with metadata").withToken(address(0)).withDueBy(
            block.timestamp + 30 days
        ) // ETH
            .build();

        uint256 contractBalanceBefore = address(bullaClaim).balance;

        // Expected InvoiceDetails struct for self-billing invoice
        InvoiceDetails memory expectedInvoiceDetails =
            new InvoiceDetailsBuilder().withRequestedByCreditor(false).build();

        // Expect ClaimCreated event with debtor as creator and creditor as recipient
        vm.expectEmit(true, true, true, true);
        emit ClaimCreated(
            0,
            debtor, // from (creator)
            creditor, // creditor (who will receive the NFT)
            debtor, // debtor (who owes the payment)
            5 ether, // claimAmount
            block.timestamp + 30 days, // dueBy
            "Self-billing invoice with metadata", // description
            address(0), // token (ETH)
            address(bullaInvoice), // controller
            ClaimBinding.BindingPending // binding
        );

        // Expect InvoiceCreated event
        vm.expectEmit(true, false, false, true);
        emit InvoiceCreated(0, expectedInvoiceDetails, CORE_PROTOCOL_FEE, metadata);

        // Debtor creates self-billing invoice with metadata
        vm.prank(debtor);
        uint256 invoiceId = bullaInvoice.createInvoiceWithMetadata{value: CORE_PROTOCOL_FEE}(params, metadata);

        // Verify fee was sent to contract
        assertEq(
            address(bullaClaim).balance - contractBalanceBefore,
            CORE_PROTOCOL_FEE,
            "Contract should hold the origination fee"
        );

        // Verify invoice was created successfully
        assertTrue(bullaClaim.currentClaimId() > 0, "Invoice should be created");

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
        assertEq(invoice.purchaseOrder.deliveryDate, 0, "Should not be a purchase order");

        // Verify metadata through BullaClaim's claimMetadata function
        (string memory tokenURI, string memory attachmentURI) = bullaClaim.claimMetadata(invoiceId);
        assertEq(tokenURI, "https://example.com/self-billing-invoice", "Token URI metadata mismatch");
        assertEq(attachmentURI, "https://example.com/self-billing-attachment", "Attachment URI metadata mismatch");
    }

    function testCreateSelfBillingInvoiceWithMetadataAndERC20Token() public {
        // Create metadata
        ClaimMetadata memory metadata = ClaimMetadata({
            tokenURI: "https://example.com/erc20-self-billing",
            attachmentURI: "https://example.com/erc20-attachment"
        });

        // Create invoice params for ERC20 token payment
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withClaimAmount(1000 ether).withDescription("ERC20 self-billing invoice with metadata").withToken(
            address(testToken)
        ).withDueBy(block.timestamp + 15 days).build();

        // Debtor creates self-billing invoice for ERC20 payment with metadata
        vm.prank(debtor);
        uint256 invoiceId = bullaInvoice.createInvoiceWithMetadata{value: CORE_PROTOCOL_FEE}(params, metadata);

        // Verify invoice was created successfully
        assertTrue(bullaClaim.currentClaimId() > 0, "Invoice should be created");

        // Verify the claim structure for ERC20
        Claim memory claim = bullaClaim.getClaim(invoiceId);
        assertEq(claim.debtor, debtor, "Debtor should be set correctly");
        assertEq(claim.creditor, creditor, "Creditor should be set correctly");
        assertEq(claim.claimAmount, 1000 ether, "Claim amount should match");
        assertEq(claim.token, address(testToken), "Token should be test token");

        // Verify the creditor owns the NFT
        assertEq(bullaClaim.ownerOf(invoiceId), creditor, "Creditor should own the invoice NFT");

        // Verify metadata
        (string memory tokenURI, string memory attachmentURI) = bullaClaim.claimMetadata(invoiceId);
        assertEq(tokenURI, "https://example.com/erc20-self-billing", "Token URI metadata mismatch");
        assertEq(attachmentURI, "https://example.com/erc20-attachment", "Attachment URI metadata mismatch");
    }

    function testCreateSelfBillingInvoiceWithMetadataAndBoundStatus() public {
        // Create metadata
        ClaimMetadata memory metadata = ClaimMetadata({
            tokenURI: "https://example.com/bound-self-billing",
            attachmentURI: "https://example.com/bound-attachment"
        });

        // Create invoice params with bound status
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withClaimAmount(2 ether).withDescription("Bound self-billing invoice with metadata").withToken(address(0))
            .withBinding(ClaimBinding.Bound) // Debtor can bind themselves
            .build();

        // Debtor creates bound self-billing invoice with metadata
        vm.prank(debtor);
        uint256 invoiceId = bullaInvoice.createInvoiceWithMetadata{value: CORE_PROTOCOL_FEE}(params, metadata);

        // Verify the claim is bound
        Claim memory claim = bullaClaim.getClaim(invoiceId);
        assertTrue(claim.binding == ClaimBinding.Bound, "Claim should be bound");
        assertEq(claim.debtor, debtor, "Debtor should be set correctly");
        assertEq(claim.creditor, creditor, "Creditor should be set correctly");
        assertEq(claim.originalCreditor, creditor, "Creditor should be set correctly");

        // Verify metadata
        (string memory tokenURI, string memory attachmentURI) = bullaClaim.claimMetadata(invoiceId);
        assertEq(tokenURI, "https://example.com/bound-self-billing", "Token URI metadata mismatch");
        assertEq(attachmentURI, "https://example.com/bound-attachment", "Attachment URI metadata mismatch");
    }

    function testCreateSelfBillingInvoiceWithMetadataAndInterest() public {
        // Create metadata
        ClaimMetadata memory metadata = ClaimMetadata({
            tokenURI: "https://example.com/interest-self-billing",
            attachmentURI: "https://example.com/interest-attachment"
        });

        // Create interest config
        InterestConfig memory interestConfig = InterestConfig({
            interestRateBps: 500, // 5% APR
            numberOfPeriodsPerYear: 12 // Monthly compounding
        });

        // Create invoice params with interest
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withClaimAmount(10 ether).withDescription("Self-billing invoice with interest and metadata").withToken(
            address(0)
        ).withLateFeeConfig(interestConfig).withDueBy(block.timestamp + 60 days).build();

        // Debtor creates self-billing invoice with interest and metadata
        vm.prank(debtor);
        uint256 invoiceId = bullaInvoice.createInvoiceWithMetadata{value: CORE_PROTOCOL_FEE}(params, metadata);

        // Verify invoice was created successfully
        assertTrue(bullaClaim.currentClaimId() > 0, "Invoice should be created");

        // Verify the invoice details
        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        assertEq(invoice.lateFeeConfig.interestRateBps, 500, "Interest rate should match");
        assertEq(invoice.lateFeeConfig.numberOfPeriodsPerYear, 12, "Periods per year should match");
        assertEq(invoice.debtor, debtor, "Debtor should be set correctly");

        // Verify metadata
        (string memory tokenURI, string memory attachmentURI) = bullaClaim.claimMetadata(invoiceId);
        assertEq(tokenURI, "https://example.com/interest-self-billing", "Token URI metadata mismatch");
        assertEq(attachmentURI, "https://example.com/interest-attachment", "Attachment URI metadata mismatch");
    }

    function testCreateSelfBillingInvoiceWithMetadataZeroDueBy() public {
        // Create metadata
        ClaimMetadata memory metadata = ClaimMetadata({
            tokenURI: "https://example.com/zero-due-date",
            attachmentURI: "https://example.com/zero-due-attachment"
        });

        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withDueBy(0).withDescription("Self-billing invoice with metadata and no due date") // No due date
            .build();

        // Create a self-billing invoice with metadata and dueBy = 0
        vm.prank(debtor);
        uint256 invoiceId = bullaInvoice.createInvoiceWithMetadata{value: CORE_PROTOCOL_FEE}(params, metadata);

        // Verify invoice was created correctly with dueBy = 0
        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        assertEq(invoice.dueBy, 0, "Invoice due date should be 0");

        // Verify metadata
        (string memory tokenURI, string memory attachmentURI) = bullaClaim.claimMetadata(invoiceId);
        assertEq(tokenURI, "https://example.com/zero-due-date", "Token URI metadata mismatch");
        assertEq(attachmentURI, "https://example.com/zero-due-attachment", "Attachment URI metadata mismatch");
    }

    // ==================== PURCHASE ORDER WITH METADATA TESTS ====================

    function testCreateSelfBillingPurchaseOrderWithMetadata() public {
        uint256 deliveryDate = block.timestamp + 7 days;
        uint256 depositAmount = 1 ether;

        // Create metadata
        ClaimMetadata memory metadata = ClaimMetadata({
            tokenURI: "https://example.com/purchase-order-self-billing",
            attachmentURI: "https://example.com/purchase-order-attachment"
        });

        // Create purchase order params
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withClaimAmount(5 ether).withDescription("Self-billing purchase order with metadata").withToken(address(0))
            .withDeliveryDate(deliveryDate).withDepositAmount(depositAmount).build();

        // Expected InvoiceDetails struct for self-billing purchase order
        InvoiceDetails memory expectedInvoiceDetails = new InvoiceDetailsBuilder().withRequestedByCreditor(false)
            .withDeliveryDate(deliveryDate).withDepositAmount(depositAmount).build();

        // Expect InvoiceCreated event
        vm.expectEmit(true, false, false, true);
        emit InvoiceCreated(0, expectedInvoiceDetails, CORE_PROTOCOL_FEE, metadata);

        // Debtor creates self-billing purchase order with metadata
        vm.prank(debtor);
        uint256 invoiceId = bullaInvoice.createInvoiceWithMetadata{value: CORE_PROTOCOL_FEE}(params, metadata);

        // Verify purchase order was created
        assertTrue(bullaClaim.currentClaimId() > 0, "Purchase order should be created");

        // Verify the invoice details
        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        assertEq(invoice.purchaseOrder.deliveryDate, deliveryDate, "Delivery date should match");
        assertEq(invoice.purchaseOrder.depositAmount, depositAmount, "Deposit amount should match");
        assertFalse(invoice.purchaseOrder.isDelivered, "Should not be delivered initially");
        assertEq(invoice.debtor, debtor, "Debtor should be set correctly");

        // Verify the creditor owns the NFT
        assertEq(bullaClaim.ownerOf(invoiceId), creditor, "Creditor should own the purchase order NFT");

        // Verify metadata
        (string memory tokenURI, string memory attachmentURI) = bullaClaim.claimMetadata(invoiceId);
        assertEq(tokenURI, "https://example.com/purchase-order-self-billing", "Token URI metadata mismatch");
        assertEq(attachmentURI, "https://example.com/purchase-order-attachment", "Attachment URI metadata mismatch");
    }

    // ==================== VALIDATION TESTS ====================

    function testSelfBillingWithMetadataMustPayCorrectOriginationFee() public {
        // Create metadata
        ClaimMetadata memory metadata = ClaimMetadata({
            tokenURI: "https://example.com/fee-test",
            attachmentURI: "https://example.com/fee-attachment"
        });

        CreateInvoiceParams memory params =
            new CreateInvoiceParamsBuilder().withCreditor(creditor).withDebtor(debtor).withClaimAmount(5 ether).build();

        // Try with wrong fee
        vm.prank(debtor);
        vm.expectRevert(IncorrectFee.selector);
        bullaInvoice.createInvoiceWithMetadata{value: CORE_PROTOCOL_FEE + 0.001 ether}(params, metadata);

        // Try with no fee
        vm.prank(debtor);
        vm.expectRevert(IncorrectFee.selector);
        bullaInvoice.createInvoiceWithMetadata{value: 0}(params, metadata);
    }

    function testSelfBillingWithMetadataMustPayCorrectPurchaseOrderFee() public {
        // Create metadata
        ClaimMetadata memory metadata = ClaimMetadata({
            tokenURI: "https://example.com/purchase-order-fee-test",
            attachmentURI: "https://example.com/purchase-order-fee-attachment"
        });

        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withClaimAmount(5 ether).withDeliveryDate(block.timestamp + 7 days).build();

        // Try with wrong purchase order fee
        vm.prank(debtor);
        vm.expectRevert(IncorrectFee.selector);
        bullaInvoice.createInvoiceWithMetadata{value: CORE_PROTOCOL_FEE + 0.001 ether}(params, metadata);
    }

    function testSelfBillingWithMetadataInvalidDeliveryDate() public {
        // Create metadata
        ClaimMetadata memory metadata = ClaimMetadata({
            tokenURI: "https://example.com/invalid-delivery-date",
            attachmentURI: "https://example.com/invalid-delivery-attachment"
        });

        vm.warp(30 days);

        // Create invoice params with past delivery date
        uint256 pastDeliveryDate = block.timestamp - 1 days;
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withDeliveryDate(pastDeliveryDate).build();

        // Create should revert with InvalidDeliveryDate
        vm.prank(debtor);
        vm.expectRevert(InvalidDeliveryDate.selector);
        bullaInvoice.createInvoiceWithMetadata{value: CORE_PROTOCOL_FEE}(params, metadata);

        // Create invoice params with future delivery date beyond uint40
        uint256 farFutureDeliveryDate = uint256(type(uint40).max) + 1;
        params = new CreateInvoiceParamsBuilder().withCreditor(creditor).withDebtor(debtor).withDeliveryDate(
            farFutureDeliveryDate
        ).build();

        // Create should revert with InvalidDeliveryDate
        vm.prank(debtor);
        vm.expectRevert(InvalidDeliveryDate.selector);
        bullaInvoice.createInvoiceWithMetadata{value: CORE_PROTOCOL_FEE}(params, metadata);
    }

    function testSelfBillingWithMetadataInvalidDepositAmount() public {
        // Create metadata
        ClaimMetadata memory metadata = ClaimMetadata({
            tokenURI: "https://example.com/invalid-deposit",
            attachmentURI: "https://example.com/invalid-deposit-attachment"
        });

        // Try to create self-billing invoice with deposit larger than claim amount
        uint256 claimAmount = 1 ether;
        uint256 depositAmount = 2 ether; // Larger than claim amount
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withClaimAmount(claimAmount).withDepositAmount(depositAmount).build();

        vm.prank(debtor);
        vm.expectRevert(abi.encodeWithSelector(InvalidDepositAmount.selector));
        bullaInvoice.createInvoiceWithMetadata{value: CORE_PROTOCOL_FEE}(params, metadata);
    }

    function testSelfBillingWithMetadataPastDueBy() public {
        // Create metadata
        ClaimMetadata memory metadata = ClaimMetadata({
            tokenURI: "https://example.com/past-due-date",
            attachmentURI: "https://example.com/past-due-attachment"
        });

        vm.warp(block.timestamp + 1 days);

        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withClaimAmount(1 ether).withDueBy(block.timestamp - 1 days).withDescription(
            "Self-billing invoice with metadata and past due date"
        ) // Past date
            .build();

        // Try to create a self-billing invoice with metadata and past due date
        vm.prank(debtor);
        vm.expectRevert(abi.encodeWithSelector(BullaClaimValidationLib.InvalidDueBy.selector));
        bullaInvoice.createInvoiceWithMetadata{value: CORE_PROTOCOL_FEE}(params, metadata);
    }

    function testSelfBillingWithMetadataFarFutureDueBy() public {
        // Create metadata
        ClaimMetadata memory metadata = ClaimMetadata({
            tokenURI: "https://example.com/far-future-due-date",
            attachmentURI: "https://example.com/far-future-attachment"
        });

        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withDueBy(uint256(type(uint40).max) + 1).withDescription(
            "Self-billing invoice with metadata and far future due date"
        ) // Too far in the future
            .build();

        // Try to create a self-billing invoice with metadata and too far future due date
        vm.prank(debtor);
        vm.expectRevert(abi.encodeWithSelector(BullaClaimValidationLib.InvalidDueBy.selector));
        bullaInvoice.createInvoiceWithMetadata{value: CORE_PROTOCOL_FEE}(params, metadata);
    }

    // ==================== PAYMENT FLOW TESTS ====================

    function testDebtorCanPaySelfBillingInvoiceWithMetadata() public {
        // Create metadata
        ClaimMetadata memory metadata = ClaimMetadata({
            tokenURI: "https://example.com/payable-self-billing",
            attachmentURI: "https://example.com/payable-attachment"
        });

        // Debtor creates self-billing invoice with metadata
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withClaimAmount(2 ether).withDescription("Self-billing invoice with metadata to be paid by debtor").withToken(
            address(0)
        ).build();

        vm.prank(debtor);
        uint256 invoiceId = bullaInvoice.createInvoiceWithMetadata{value: CORE_PROTOCOL_FEE}(params, metadata);

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
        assertEq(debtor.balance, debtorBalanceBefore - 2 ether, "Debtor balance should decrease");

        // Verify metadata still exists after payment
        (string memory tokenURI, string memory attachmentURI) = bullaClaim.claimMetadata(invoiceId);
        assertEq(tokenURI, "https://example.com/payable-self-billing", "Token URI metadata should be preserved");
        assertEq(attachmentURI, "https://example.com/payable-attachment", "Attachment URI metadata should be preserved");
    }

    // ==================== FUZZING TESTS ====================

    function testFuzz_CreateSelfBillingInvoiceWithMetadata(uint256 amount, uint256 dueBy) public {
        // Constrain input values
        amount = bound(amount, 0.1 ether, 100 ether);
        dueBy = bound(dueBy, block.timestamp + 1 days, type(uint40).max);

        // Create metadata
        ClaimMetadata memory metadata = ClaimMetadata({
            tokenURI: "https://example.com/fuzz-test",
            attachmentURI: "https://example.com/fuzz-attachment"
        });

        // Create invoice params with fuzzing values
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withClaimAmount(amount).withDueBy(dueBy).withDescription("Fuzz Test Self-Billing Invoice with Metadata").build(
        );

        // Create a self-billing invoice with metadata
        vm.prank(debtor);
        uint256 invoiceId = bullaInvoice.createInvoiceWithMetadata{value: CORE_PROTOCOL_FEE}(params, metadata);

        // Verify invoice was created correctly
        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        assertEq(invoice.claimAmount, amount, "Invoice claim amount mismatch");
        assertEq(invoice.dueBy, dueBy, "Invoice due date mismatch");

        // Verify metadata exists
        (string memory tokenURI, string memory attachmentURI) = bullaClaim.claimMetadata(invoiceId);
        assertEq(tokenURI, "https://example.com/fuzz-test", "Token URI metadata mismatch");
        assertEq(attachmentURI, "https://example.com/fuzz-attachment", "Attachment URI metadata mismatch");
    }
}
