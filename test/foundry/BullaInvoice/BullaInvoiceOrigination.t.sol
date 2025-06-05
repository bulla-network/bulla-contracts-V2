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
    CreditorCannotBeDebtor,
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
    IncorrectFee
} from "contracts/BullaInvoice.sol";
import {Deployer} from "script/Deployment.s.sol";
import {CreateInvoiceParamsBuilder} from "test/foundry/BullaInvoice/CreateInvoiceParamsBuilder.sol";
import {CreateClaimParamsBuilder} from "test/foundry/BullaClaim/CreateClaimParamsBuilder.sol";
import {BullaClaimValidationLib} from "contracts/libraries/BullaClaimValidationLib.sol";
import {InterestConfig, InterestComputationState} from "contracts/libraries/CompoundInterestLib.sol";
import {ERC20Mock} from "openzeppelin-contracts/contracts/mocks/ERC20Mock.sol";

contract TestBullaInvoiceOrigination is Test {
    WETH public weth;
    BullaClaim public bullaClaim;
    EIP712Helper public sigHelper;
    BullaInvoice public bullaInvoice;
    BullaInvoice public zeroFeeInvoice;

    uint256 constant INVOICE_ORIGINATION_FEE = 0.01 ether;
    uint256 constant PURCHASE_ORDER_ORIGINATION_FEE = 0.02 ether;
    uint256 creditorPK = uint256(0x01);
    uint256 debtorPK = uint256(0x02);
    uint256 adminPK = uint256(0x03);
    address creditor = vm.addr(creditorPK);
    address debtor = vm.addr(debtorPK);
    address admin = vm.addr(adminPK);

    // Events for testing
    event InvoiceCreated(uint256 indexed claimId, InvoiceDetails invoiceDetails, uint256 originationFee);
    event FeeWithdrawn(address indexed admin, address indexed token, uint256 amount);

    function setUp() public {
        weth = new WETH();

        bullaClaim = (new Deployer()).deploy_test({_deployer: address(this), _initialLockState: LockState.Unlocked});
        sigHelper = new EIP712Helper(address(bullaClaim));

        // Main invoice contract with origination fees
        bullaInvoice =
            new BullaInvoice(address(bullaClaim), admin, 0, INVOICE_ORIGINATION_FEE, PURCHASE_ORDER_ORIGINATION_FEE);

        // Zero fee invoice contract for testing
        zeroFeeInvoice = new BullaInvoice(address(bullaClaim), admin, 0, 0 ether, 0 ether);

        // Setup balances
        vm.deal(debtor, 100 ether);
        vm.deal(creditor, 100 ether);
        vm.deal(admin, 100 ether);

        // Setup permissions for both contracts
        _setupPermissions(address(bullaInvoice));
        _setupPermissions(address(zeroFeeInvoice));
    }

    function _setupPermissions(address invoiceContract) internal {
        // Setup create claim permissions
        bullaClaim.permitCreateClaim({
            user: creditor,
            controller: invoiceContract,
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: type(uint64).max,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: invoiceContract,
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: type(uint64).max,
                isBindingAllowed: false
            })
        });

        // Setup pay claim permissions
        bullaClaim.permitPayClaim({
            user: debtor,
            controller: invoiceContract,
            approvalType: PayClaimApprovalType.IsApprovedForAll,
            approvalDeadline: 0,
            paymentApprovals: new ClaimPaymentApprovalParam[](0),
            signature: sigHelper.signPayClaimPermit({
                pk: debtorPK,
                user: debtor,
                controller: invoiceContract,
                approvalType: PayClaimApprovalType.IsApprovedForAll,
                approvalDeadline: 0,
                paymentApprovals: new ClaimPaymentApprovalParam[](0)
            })
        });
    }

    // ==================== CORE FEE PAYMENT TESTS ====================

    function testCreateInvoiceWithCorrectInvoiceFee() public {
        // Setup for no delivery date (invoice)
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).withDeliveryDate(0) // No delivery date = invoice
            .build();

        uint256 expectedFee = bullaInvoice.invoiceOriginationFee();
        uint256 contractBalanceBefore = address(bullaInvoice).balance;

        // Expected InvoiceDetails struct
        InvoiceDetails memory expectedInvoiceDetails = InvoiceDetails({
            purchaseOrder: PurchaseOrderState({deliveryDate: 0, isDelivered: false}),
            lateFeeConfig: InterestConfig({interestRateBps: 0, numberOfPeriodsPerYear: 0}),
            interestComputationState: InterestComputationState({accruedInterest: 0, latestPeriodNumber: 0}),
            depositAmount: 0
        });

        // Expect InvoiceCreated event
        vm.expectEmit(true, false, false, true);
        emit InvoiceCreated(1, expectedInvoiceDetails, expectedFee);

        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice{value: expectedFee}(params);

        // Verify fee was sent to contract (not admin directly)
        assertEq(
            address(bullaInvoice).balance - contractBalanceBefore,
            expectedFee,
            "Contract should hold the origination fee"
        );

        // Verify invoice was created successfully
        assertTrue(invoiceId > 0, "Invoice should be created");
    }

    function testCreatePurchaseOrderWithCorrectFee() public {
        // Setup for delivery date (purchase order)
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).withDeliveryDate(
            block.timestamp + 1 days
        ) // Has delivery date = purchase order
            .build();

        uint256 expectedFee = bullaInvoice.purchaseOrderOriginationFee();
        uint256 contractBalanceBefore = address(bullaInvoice).balance;

        // Expected InvoiceDetails struct
        InvoiceDetails memory expectedInvoiceDetails = InvoiceDetails({
            purchaseOrder: PurchaseOrderState({deliveryDate: block.timestamp + 1 days, isDelivered: false}),
            lateFeeConfig: InterestConfig({interestRateBps: 0, numberOfPeriodsPerYear: 0}),
            interestComputationState: InterestComputationState({accruedInterest: 0, latestPeriodNumber: 0}),
            depositAmount: 0
        });

        // Expect InvoiceCreated event
        vm.expectEmit(true, false, false, true);
        emit InvoiceCreated(1, expectedInvoiceDetails, expectedFee);

        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice{value: expectedFee}(params);

        // Verify fee was sent to contract
        assertEq(
            address(bullaInvoice).balance - contractBalanceBefore,
            expectedFee,
            "Contract should hold the purchase order fee"
        );
        assertTrue(invoiceId > 0, "Purchase order should be created");
    }

    // ==================== FEE VALIDATION ERROR TESTS ====================

    function testCreateInvoiceRevertsWithIncorrectFee() public {
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).withDeliveryDate(0) // No delivery date = invoice
            .build();

        uint256 incorrectFee = bullaInvoice.invoiceOriginationFee() + 0.001 ether;

        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(IncorrectFee.selector));
        bullaInvoice.createInvoice{value: incorrectFee}(params);
    }

    function testCreatePurchaseOrderRevertsWithIncorrectFee() public {
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).withDeliveryDate(
            block.timestamp + 1 days
        ) // Has delivery date = purchase order
            .build();

        uint256 incorrectFee = bullaInvoice.purchaseOrderOriginationFee() + 0.001 ether;

        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(IncorrectFee.selector));
        bullaInvoice.createInvoice{value: incorrectFee}(params);
    }

    function testCreateInvoiceRevertsWhenNoFeeProvided() public {
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).withDeliveryDate(0) // No delivery date = invoice
            .build();

        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(IncorrectFee.selector));
        bullaInvoice.createInvoice{value: 0}(params); // No fee provided
    }

    // ==================== EDGE CASES ====================

    function testCreateInvoiceAtExactBlockTimestamp() public {
        // Delivery date at exact block timestamp should be treated as purchase order
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).withDeliveryDate(
            block.timestamp
        ) // Exact timestamp = purchase order
            .build();

        uint256 expectedFee = bullaInvoice.purchaseOrderOriginationFee();

        // Expected InvoiceDetails struct
        InvoiceDetails memory expectedInvoiceDetails = InvoiceDetails({
            purchaseOrder: PurchaseOrderState({deliveryDate: block.timestamp, isDelivered: false}),
            lateFeeConfig: InterestConfig({interestRateBps: 0, numberOfPeriodsPerYear: 0}),
            interestComputationState: InterestComputationState({accruedInterest: 0, latestPeriodNumber: 0}),
            depositAmount: 0
        });

        // Expect InvoiceCreated event
        vm.expectEmit(true, false, false, true);
        emit InvoiceCreated(1, expectedInvoiceDetails, expectedFee);

        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice{value: expectedFee}(params);

        assertTrue(invoiceId > 0, "Should create as purchase order");
    }

    function testCreateInvoiceWithZeroConfiguredFees() public {
        // Test with zero fee contract
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).withDeliveryDate(0) // No delivery date = invoice
            .build();

        // Expected InvoiceDetails struct
        InvoiceDetails memory expectedInvoiceDetails = InvoiceDetails({
            purchaseOrder: PurchaseOrderState({deliveryDate: 0, isDelivered: false}),
            lateFeeConfig: InterestConfig({interestRateBps: 0, numberOfPeriodsPerYear: 0}),
            interestComputationState: InterestComputationState({accruedInterest: 0, latestPeriodNumber: 0}),
            depositAmount: 0
        });

        // Expect InvoiceCreated event with zero fee
        vm.expectEmit(true, false, false, true);
        emit InvoiceCreated(1, expectedInvoiceDetails, 0);

        vm.prank(creditor);
        uint256 invoiceId = zeroFeeInvoice.createInvoice{value: 0}(params);

        assertTrue(invoiceId > 0, "Should create invoice with zero fees");
        assertEq(address(zeroFeeInvoice).balance, 0, "No ETH should be in contract");
    }

    // ==================== FEE WITHDRAWAL ====================

    function testAdminCanWithdrawOriginationFees() public {
        CreateInvoiceParams memory invoiceParams = new CreateInvoiceParamsBuilder().withDebtor(debtor).withDeliveryDate(
            0
        ) // No delivery date = invoice
            .build();

        CreateInvoiceParams memory purchaseOrderParams = new CreateInvoiceParamsBuilder().withDebtor(debtor)
            .withDeliveryDate(block.timestamp + 1 days) // Has delivery date = purchase order
            .build();

        uint256 invoiceFee = bullaInvoice.invoiceOriginationFee();
        uint256 purchaseOrderFee = bullaInvoice.purchaseOrderOriginationFee();

        // Expected InvoiceDetails for invoice
        InvoiceDetails memory expectedInvoiceDetails = InvoiceDetails({
            purchaseOrder: PurchaseOrderState({deliveryDate: 0, isDelivered: false}),
            lateFeeConfig: InterestConfig({interestRateBps: 0, numberOfPeriodsPerYear: 0}),
            interestComputationState: InterestComputationState({accruedInterest: 0, latestPeriodNumber: 0}),
            depositAmount: 0
        });

        // Expected InvoiceDetails for purchase order
        InvoiceDetails memory expectedPurchaseOrderDetails = InvoiceDetails({
            purchaseOrder: PurchaseOrderState({deliveryDate: block.timestamp + 1 days, isDelivered: false}),
            lateFeeConfig: InterestConfig({interestRateBps: 0, numberOfPeriodsPerYear: 0}),
            interestComputationState: InterestComputationState({accruedInterest: 0, latestPeriodNumber: 0}),
            depositAmount: 0
        });

        // Create invoice
        vm.expectEmit(true, false, false, true);
        emit InvoiceCreated(1, expectedInvoiceDetails, invoiceFee);

        vm.prank(creditor);
        bullaInvoice.createInvoice{value: invoiceFee}(invoiceParams);

        // Create purchase order
        vm.expectEmit(true, false, false, true);
        emit InvoiceCreated(2, expectedPurchaseOrderDetails, purchaseOrderFee);

        vm.prank(creditor);
        bullaInvoice.createInvoice{value: purchaseOrderFee}(purchaseOrderParams);

        // Verify fees are held in contract
        uint256 expectedTotal = invoiceFee + purchaseOrderFee;
        assertEq(address(bullaInvoice).balance, expectedTotal, "Contract should hold all origination fees");

        // Admin withdraws fees
        uint256 adminBalanceBefore = admin.balance;

        vm.expectEmit(true, true, false, true);
        emit FeeWithdrawn(admin, address(0), expectedTotal);

        vm.prank(admin);
        bullaInvoice.withdrawAllFees();

        // Verify admin received the fees
        assertEq(admin.balance - adminBalanceBefore, expectedTotal, "Admin should receive all origination fees");

        // Verify contract has no remaining fees
        assertEq(address(bullaInvoice).balance, 0, "No ETH should remain in contract after withdrawal");
    }

    function testNonAdminCannotWithdrawFees() public {
        // Create an invoice with fee
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).withDeliveryDate(0) // No delivery date = invoice
            .build();

        uint256 fee = bullaInvoice.invoiceOriginationFee();

        // Expected InvoiceDetails struct
        InvoiceDetails memory expectedInvoiceDetails = InvoiceDetails({
            purchaseOrder: PurchaseOrderState({deliveryDate: 0, isDelivered: false}),
            lateFeeConfig: InterestConfig({interestRateBps: 0, numberOfPeriodsPerYear: 0}),
            interestComputationState: InterestComputationState({accruedInterest: 0, latestPeriodNumber: 0}),
            depositAmount: 0
        });

        // Expect InvoiceCreated event
        vm.expectEmit(true, false, false, true);
        emit InvoiceCreated(1, expectedInvoiceDetails, fee);

        vm.prank(creditor);
        bullaInvoice.createInvoice{value: fee}(params);

        // Non-admin tries to withdraw
        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(NotAdmin.selector));
        bullaInvoice.withdrawAllFees();
    }
}
