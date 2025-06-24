pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import "contracts/types/Types.sol";
import {WETH} from "contracts/mocks/weth.sol";
import {EIP712Helper, privateKeyValidity} from "test/foundry/BullaClaim/EIP712/Utils.sol";
import {BullaClaim} from "contracts/BullaClaim.sol";
import {IBullaClaim} from "contracts/interfaces/IBullaClaim.sol";
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
    IncorrectFee
} from "contracts/BullaInvoice.sol";
import {InvoiceDetailsBuilder} from "test/foundry/BullaInvoice/InvoiceDetailsBuilder.t.sol";
import {Deployer} from "script/Deployment.s.sol";
import {CreateInvoiceParamsBuilder} from "test/foundry/BullaInvoice/CreateInvoiceParamsBuilder.sol";
import {CreateClaimParamsBuilder} from "test/foundry/BullaClaim/CreateClaimParamsBuilder.sol";
import {BullaClaimValidationLib} from "contracts/libraries/BullaClaimValidationLib.sol";
import {InterestConfig, InterestComputationState} from "contracts/libraries/CompoundInterestLib.sol";
import {ERC20Mock} from "openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";

contract TestBullaInvoiceOrigination is Test {
    WETH public weth;
    BullaClaim public bullaClaim;
    BullaClaim public zeroFeeBullaClaim;
    EIP712Helper public sigHelper;
    EIP712Helper public zeroFeeSigHelper;
    BullaInvoice public bullaInvoice;
    BullaInvoice public zeroFeeInvoice;

    uint256 constant CORE_PROTOCOL_FEE = 0.01 ether;
    uint256 creditorPK = uint256(0x01);
    uint256 debtorPK = uint256(0x02);
    uint256 adminPK = uint256(0x03);
    address creditor = vm.addr(creditorPK);
    address debtor = vm.addr(debtorPK);
    address admin = vm.addr(adminPK);

    // Events for testing
    event InvoiceCreated(uint256 indexed claimId, InvoiceDetails invoiceDetails);
    event FeeWithdrawn(address indexed admin, address indexed token, uint256 amount);

    function setUp() public {
        weth = new WETH();

        bullaClaim = (new Deployer()).deploy_test({
            _deployer: address(this),
            _initialLockState: LockState.Unlocked,
            _coreProtocolFee: CORE_PROTOCOL_FEE
        });
        zeroFeeBullaClaim = (new Deployer()).deploy_test({
            _deployer: address(this),
            _initialLockState: LockState.Unlocked,
            _coreProtocolFee: 0
        });
        sigHelper = new EIP712Helper(address(bullaClaim));
        zeroFeeSigHelper = new EIP712Helper(address(zeroFeeBullaClaim));

        // Main invoice contract with origination fees
        bullaInvoice = new BullaInvoice(address(bullaClaim), admin, 0);

        // Zero fee invoice contract for testing
        zeroFeeInvoice = new BullaInvoice(address(zeroFeeBullaClaim), admin, 0);

        // Setup balances
        vm.deal(debtor, 100 ether);
        vm.deal(creditor, 100 ether);
        vm.deal(admin, 100 ether);

        // Setup permissions for both contracts
        _setupPermissions(sigHelper, address(bullaInvoice));
        _setupPermissions(zeroFeeSigHelper, address(zeroFeeInvoice));
    }

    function _setupPermissions(EIP712Helper _sigHelper, address invoiceContract) internal {
        IBullaClaim _bullaClaim = IBullaClaim(BullaInvoice(invoiceContract)._bullaClaim());
        // Setup create claim permissions
        _bullaClaim.permitCreateClaim({
            user: creditor,
            controller: invoiceContract,
            approvalType: uint8(CreateClaimApprovalType.Approved),
            approvalCount: type(uint64).max,
            isBindingAllowed: false,
            signature: _sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: invoiceContract,
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: type(uint64).max,
                isBindingAllowed: false
            })
        });

        // Setup pay claim permissions
        _bullaClaim.permitPayClaim({
            user: debtor,
            controller: invoiceContract,
            approvalType: uint8(PayClaimApprovalType.IsApprovedForAll),
            approvalDeadline: 0,
            paymentApprovals: new ClaimPaymentApprovalParam[](0),
            signature: _sigHelper.signPayClaimPermit({
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
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).withCreditor(creditor)
            .withDeliveryDate(0) // No delivery date = invoice
            .build();

        uint256 expectedFee = bullaClaim.CORE_PROTOCOL_FEE();
        uint256 contractBalanceBefore = address(bullaClaim).balance;

        // Expected InvoiceDetails struct
        InvoiceDetails memory expectedInvoiceDetails = new InvoiceDetailsBuilder().build();

        // Expect InvoiceCreated event
        vm.expectEmit(true, false, false, true);
        emit InvoiceCreated(1, expectedInvoiceDetails);

        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice{value: expectedFee}(params);

        // Verify fee was sent to contract (not admin directly)
        assertEq(
            address(bullaClaim).balance - contractBalanceBefore, expectedFee, "Contract should hold the origination fee"
        );

        // Verify invoice was created successfully
        assertTrue(invoiceId > 0, "Invoice should be created");
    }

    function testCreatePurchaseOrderWithCorrectFee() public {
        // Setup for delivery date (purchase order)
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).withCreditor(creditor)
            .withDeliveryDate(block.timestamp + 1 days) // Has delivery date = purchase order
            .build();

        uint256 expectedFee = bullaClaim.CORE_PROTOCOL_FEE();
        uint256 contractBalanceBefore = address(bullaInvoice).balance;

        // Expected InvoiceDetails struct
        InvoiceDetails memory expectedInvoiceDetails =
            new InvoiceDetailsBuilder().withDeliveryDate(block.timestamp + 1 days).build();

        // Expect InvoiceCreated event
        vm.expectEmit(true, false, false, true);
        emit InvoiceCreated(1, expectedInvoiceDetails);

        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice{value: expectedFee}(params);

        // Verify fee was sent to contract
        assertEq(
            address(bullaClaim).balance - contractBalanceBefore,
            expectedFee,
            "Contract should hold the purchase order fee"
        );
        assertTrue(invoiceId > 0, "Purchase order should be created");
    }

    // ==================== FEE VALIDATION ERROR TESTS ====================

    function testCreateInvoiceRevertsWithIncorrectFee() public {
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).withCreditor(creditor)
            .withDeliveryDate(0) // No delivery date = invoice
            .build();

        uint256 incorrectFee = bullaClaim.CORE_PROTOCOL_FEE() + 0.001 ether;

        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(IncorrectFee.selector));
        bullaInvoice.createInvoice{value: incorrectFee}(params);
    }

    function testCreatePurchaseOrderRevertsWithIncorrectFee() public {
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).withCreditor(creditor)
            .withDeliveryDate(block.timestamp + 1 days) // Has delivery date = purchase order
            .build();

        uint256 incorrectFee = bullaClaim.CORE_PROTOCOL_FEE() + 0.001 ether;

        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(IncorrectFee.selector));
        bullaInvoice.createInvoice{value: incorrectFee}(params);
    }

    function testCreateInvoiceRevertsWhenNoFeeProvided() public {
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).withCreditor(creditor)
            .withDeliveryDate(0) // No delivery date = invoice
            .build();

        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(IncorrectFee.selector));
        bullaInvoice.createInvoice{value: 0}(params); // No fee provided
    }

    // ==================== EDGE CASES ====================

    function testCreateInvoiceAtExactBlockTimestamp() public {
        // Delivery date at exact block timestamp should be treated as purchase order
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).withCreditor(creditor)
            .withDeliveryDate(block.timestamp) // Exact timestamp = purchase order
            .build();

        uint256 expectedFee = bullaClaim.CORE_PROTOCOL_FEE();

        // Expected InvoiceDetails struct
        InvoiceDetails memory expectedInvoiceDetails =
            new InvoiceDetailsBuilder().withDeliveryDate(block.timestamp).build();

        // Expect InvoiceCreated event
        vm.expectEmit(true, false, false, true);
        emit InvoiceCreated(1, expectedInvoiceDetails);

        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice{value: expectedFee}(params);

        assertTrue(invoiceId > 0, "Should create as purchase order");
    }

    function testCreateInvoiceWithZeroConfiguredFees() public {
        // Test with zero fee contract
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).withCreditor(creditor)
            .withDeliveryDate(0) // No delivery date = invoice
            .build();

        // Expected InvoiceDetails struct
        InvoiceDetails memory expectedInvoiceDetails = new InvoiceDetailsBuilder().build();

        // Expect InvoiceCreated event with zero fee
        vm.expectEmit(true, false, false, true);
        emit InvoiceCreated(1, expectedInvoiceDetails);

        vm.prank(creditor);
        uint256 invoiceId = zeroFeeInvoice.createInvoice{value: 0}(params);

        assertTrue(invoiceId > 0, "Should create invoice with zero fees");
        assertEq(address(zeroFeeInvoice).balance, 0, "No ETH should be in contract");
    }

    // ==================== FEE WITHDRAWAL ====================

    function testNonAdminCannotWithdrawFees() public {
        // Create an invoice with fee
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).withCreditor(creditor)
            .withDeliveryDate(0) // No delivery date = invoice
            .build();

        uint256 fee = bullaClaim.CORE_PROTOCOL_FEE();

        // Expected InvoiceDetails struct
        InvoiceDetails memory expectedInvoiceDetails = new InvoiceDetailsBuilder().build();

        // Expect InvoiceCreated event
        vm.expectEmit(true, false, false, true);
        emit InvoiceCreated(1, expectedInvoiceDetails);

        vm.prank(creditor);
        bullaInvoice.createInvoice{value: fee}(params);

        // Non-admin tries to withdraw
        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(NotAdmin.selector));
        bullaInvoice.withdrawAllFees();
    }
}
