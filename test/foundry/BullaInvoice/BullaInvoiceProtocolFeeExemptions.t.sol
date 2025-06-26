// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import {WETH} from "contracts/mocks/weth.sol";
import {MockERC20} from "contracts/mocks/MockERC20.sol";
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
import {
    CreateInvoiceParams,
    Invoice,
    InvoiceDetails,
    InterestConfig,
    InterestComputationState,
    PurchaseOrderState,
    IncorrectFee,
    InvoiceBatchInvalidMsgValue
} from "contracts/BullaInvoice.sol";
import {BullaClaim} from "contracts/BullaClaim.sol";
import {BullaInvoice} from "contracts/BullaInvoice.sol";
import {WhitelistPermissions} from "contracts/WhitelistPermissions.sol";
import {Deployer} from "script/Deployment.s.sol";
import {CreateInvoiceParamsBuilder} from "test/foundry/BullaInvoice/CreateInvoiceParamsBuilder.sol";
import {EIP712Helper} from "test/foundry/BullaClaim/EIP712/Utils.sol";

contract TestBullaInvoiceProtocolFeeExemptions is Test {
    BullaClaim public bullaClaim;
    BullaInvoice public bullaInvoice;
    WhitelistPermissions public feeExemptions;
    MockERC20 public token;
    EIP712Helper public sigHelper;

    address private _owner = makeAddr("owner");
    address private _creditor = makeAddr("creditor");
    address private _debtor = makeAddr("debtor");
    address private _exemptUser = makeAddr("exemptUser");
    address private _nonExemptUser = makeAddr("nonExemptUser");
    address private _admin = makeAddr("admin");

    uint256 private _creditorPK = 0x1;
    uint256 private _debtorPK = 0x2;
    uint256 private _exemptUserPK = 0x3;
    uint256 private _nonExemptUserPK = 0x4;

    uint256 private constant _CORE_PROTOCOL_FEE = 0.01 ether;
    uint256 private constant _PROTOCOL_FEE_BPS = 5000; // 50%

    event InvoiceCreated(uint256 indexed claimId, InvoiceDetails invoiceDetails);
    event InvoicePaid(uint256 indexed claimId, uint256 grossInterestPaid, uint256 principalPaid, uint256 protocolFee);

    function setUp() public {
        // Set up addresses from private keys
        _creditor = vm.addr(_creditorPK);
        _debtor = vm.addr(_debtorPK);
        _exemptUser = vm.addr(_exemptUserPK);
        _nonExemptUser = vm.addr(_nonExemptUserPK);

        token = new MockERC20("TestToken", "TT", 18);
        token.mint(_creditor, 1000000e18);
        token.mint(_debtor, 1000000e18);

        // Deploy fee exemptions contract
        vm.prank(_admin);
        feeExemptions = new WhitelistPermissions();

        // Deploy BullaClaim with fee exemptions
        vm.prank(_owner);
        bullaClaim = (new Deployer()).deploy_test({
            _deployer: _owner,
            _initialLockState: LockState.Unlocked,
            _coreProtocolFee: _CORE_PROTOCOL_FEE
        });

        // Set fee exemptions contract on BullaClaim
        vm.prank(_owner);
        bullaClaim.setFeeExemptions(address(feeExemptions));

        // Deploy BullaInvoice
        bullaInvoice = new BullaInvoice(address(bullaClaim), _admin, _PROTOCOL_FEE_BPS);

        sigHelper = new EIP712Helper(address(bullaClaim));

        // Setup balances
        vm.deal(_creditor, 100 ether);
        vm.deal(_debtor, 100 ether);
        vm.deal(_exemptUser, 100 ether);
        vm.deal(_nonExemptUser, 100 ether);

        // Setup permissions for invoice creation and payment
        _setupPermissions(_creditor, _creditorPK);
        _setupPermissions(_debtor, _debtorPK);
        _setupPermissions(_exemptUser, _exemptUserPK);
        _setupPermissions(_nonExemptUser, _nonExemptUserPK);
    }

    function _setupPermissions(address user, uint256 userPK) internal {
        bullaClaim.approvalRegistry().permitCreateClaim({
            user: user,
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: type(uint64).max,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: userPK,
                user: user,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: type(uint64).max,
                isBindingAllowed: false
            })
        });

        bullaClaim.approvalRegistry().permitPayClaim({
            user: user,
            controller: address(bullaInvoice),
            approvalType: PayClaimApprovalType.IsApprovedForAll,
            approvalDeadline: 0,
            paymentApprovals: new ClaimPaymentApprovalParam[](0),
            signature: sigHelper.signPayClaimPermit({
                pk: userPK,
                user: user,
                controller: address(bullaInvoice),
                approvalType: PayClaimApprovalType.IsApprovedForAll,
                approvalDeadline: 0,
                paymentApprovals: new ClaimPaymentApprovalParam[](0)
            })
        });
    }

    // Test that exempt user can create invoice without core protocol fee
    function testExemptUserCanCreateInvoiceWithoutCoreFee() public {
        // Add exempt user to whitelist
        vm.prank(_admin);
        feeExemptions.allow(_exemptUser);

        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withCreditor(_exemptUser).withDebtor(
            _debtor
        ).withClaimAmount(1 ether).build();

        uint256 contractBalanceBefore = address(bullaClaim).balance;

        vm.prank(_exemptUser);
        uint256 invoiceId = bullaInvoice.createInvoice{value: 0}(params);

        assertEq(invoiceId, 1, "Invoice should be created successfully");
        assertEq(address(bullaClaim).balance, contractBalanceBefore, "No core fee should be collected from exempt user");
    }

    // Test that non-exempt user must pay core protocol fee
    function testNonExemptUserMustPayCoreFee() public {
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withCreditor(_nonExemptUser).withDebtor(
            _debtor
        ).withClaimAmount(1 ether).build();

        // Should fail without fee
        vm.prank(_nonExemptUser);
        vm.expectRevert(IncorrectFee.selector);
        bullaInvoice.createInvoice{value: 0}(params);

        // Should succeed with fee
        uint256 contractBalanceBefore = address(bullaClaim).balance;

        vm.prank(_nonExemptUser);
        uint256 invoiceId = bullaInvoice.createInvoice{value: _CORE_PROTOCOL_FEE}(params);

        assertEq(invoiceId, 1, "Invoice should be created successfully with fee");
        assertEq(
            address(bullaClaim).balance, contractBalanceBefore + _CORE_PROTOCOL_FEE, "Core fee should be collected"
        );
    }

    // Test that exempt user pays no protocol fee on interest
    function testExemptUserPaysNoProtocolFeeOnInterest() public {
        // Add exempt user to whitelist
        vm.prank(_admin);
        feeExemptions.allow(_exemptUser);

        // Create invoice with interest (exempt user)
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withCreditor(_exemptUser).withDebtor(
            _debtor
        ).withClaimAmount(1 ether).withLateFeeConfig(
            InterestConfig({interestRateBps: 1200, numberOfPeriodsPerYear: 12})
        ).build();

        vm.prank(_exemptUser);
        uint256 invoiceId = bullaInvoice.createInvoice{value: 0}(params);

        // Fast forward to accrue interest
        vm.warp(block.timestamp + 90 days);

        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        uint256 accruedInterest = invoice.interestComputationState.accruedInterest;

        uint256 creditorBalanceBefore = _exemptUser.balance;
        uint256 contractBalanceBefore = address(bullaInvoice).balance;

        vm.expectEmit(true, false, false, true);
        emit InvoicePaid(invoiceId, accruedInterest, 0, 0); // No protocol fee

        // Pay interest
        vm.prank(_debtor);
        bullaInvoice.payInvoice{value: accruedInterest}(invoiceId, accruedInterest);

        // Verify no protocol fee was charged
        assertEq(_exemptUser.balance - creditorBalanceBefore, accruedInterest, "Creditor should receive full interest");
        assertEq(address(bullaInvoice).balance, contractBalanceBefore, "No protocol fee should be collected");
    }

    // Test that exempt debtor allows invoice creation without core fee and no protocol fee on interest
    function testExemptDebtorAllowsInvoiceCreationWithoutFees() public {
        // Add debtor to exemption list
        vm.prank(_admin);
        feeExemptions.allow(_debtor);

        // Non-exempt creditor creates invoice for exempt debtor with interest
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withCreditor(_nonExemptUser).withDebtor(
            _debtor
        ).withClaimAmount(1 ether).withLateFeeConfig(
            InterestConfig({interestRateBps: 1200, numberOfPeriodsPerYear: 12})
        ).build();

        uint256 contractBalanceBefore = address(bullaClaim).balance;

        // Should work without core fee because debtor is exempt
        vm.prank(_nonExemptUser);
        uint256 invoiceId = bullaInvoice.createInvoice{value: 0}(params);

        assertEq(invoiceId, 1, "Invoice should be created successfully");
        assertEq(
            address(bullaClaim).balance, contractBalanceBefore, "No core fee should be collected when debtor is exempt"
        );

        // Fast forward to accrue interest
        vm.warp(block.timestamp + 90 days);

        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        uint256 accruedInterest = invoice.interestComputationState.accruedInterest;

        uint256 creditorBalanceBefore = _nonExemptUser.balance;
        uint256 invoiceContractBalanceBefore = address(bullaInvoice).balance;

        vm.expectEmit(true, false, false, true);
        emit InvoicePaid(invoiceId, accruedInterest, 0, 0); // No protocol fee

        // Pay interest - no protocol fee should be charged because debtor was exempt at creation
        vm.prank(_debtor);
        bullaInvoice.payInvoice{value: accruedInterest}(invoiceId, accruedInterest);

        // Verify no protocol fee was charged on interest
        assertEq(
            _nonExemptUser.balance - creditorBalanceBefore, accruedInterest, "Creditor should receive full interest"
        );
        assertEq(
            address(bullaInvoice).balance,
            invoiceContractBalanceBefore,
            "No protocol fee should be collected on interest"
        );
    }

    // Test batch creation with exempt debtor - no core protocol fees
    function testBatchCreateInvoicesWithExemptDebtor() public {
        // Add debtor to exemption list
        vm.prank(_admin);
        feeExemptions.allow(_debtor);

        // Prepare batch calls with non-exempt creditor but exempt debtor
        CreateInvoiceParams memory params1 = new CreateInvoiceParamsBuilder().withCreditor(_nonExemptUser).withDebtor(
            _debtor
        ).withClaimAmount(1 ether).withLateFeeConfig(
            InterestConfig({interestRateBps: 1200, numberOfPeriodsPerYear: 12})
        ).build();

        CreateInvoiceParams memory params2 = new CreateInvoiceParamsBuilder().withCreditor(_nonExemptUser).withDebtor(
            _debtor
        ).withClaimAmount(2 ether).build();

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(bullaInvoice.createInvoice.selector, params1);
        calls[1] = abi.encodeWithSelector(bullaInvoice.createInvoice.selector, params2);

        uint256 contractBalanceBefore = address(bullaClaim).balance;

        // Should work with 0 msg.value because debtor is exempt
        vm.prank(_nonExemptUser);
        bullaInvoice.batchCreateInvoices{value: 0}(calls);

        // Verify no fees were charged
        assertEq(address(bullaClaim).balance, contractBalanceBefore, "No fees should be charged when debtor is exempt");

        // Verify both invoices were created
        Invoice memory invoice1 = bullaInvoice.getInvoice(1);
        Invoice memory invoice2 = bullaInvoice.getInvoice(2);
        assertEq(invoice1.claimAmount, 1 ether, "First invoice should be created");
        assertEq(invoice2.claimAmount, 2 ether, "Second invoice should be created");

        // Fast forward to accrue interest
        vm.warp(block.timestamp + 90 days);

        Invoice memory invoice1After = bullaInvoice.getInvoice(1);

        uint256 accruedInterest1 = invoice1After.interestComputationState.accruedInterest;

        uint256 creditorBalanceBefore = _nonExemptUser.balance;

        vm.expectEmit(true, false, false, true);
        emit InvoicePaid(1, accruedInterest1, 0, 0); // No protocol fee

        // Pay interest
        vm.prank(_debtor);
        bullaInvoice.payInvoice{value: accruedInterest1}(1, accruedInterest1);

        // Verify no protocol fee was charged on interest
        assertEq(
            _nonExemptUser.balance - creditorBalanceBefore, accruedInterest1, "Creditor should receive full interest"
        );
        assertEq(
            address(bullaInvoice).balance, contractBalanceBefore, "No protocol fee should be collected on interest"
        );
    }

    // Test that non-exempt user pays protocol fee on interest
    function testNonExemptUserPaysProtocolFeeOnInterest() public {
        // Create invoice with interest (non-exempt user)
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withCreditor(_nonExemptUser).withDebtor(
            _debtor
        ).withClaimAmount(1 ether).withLateFeeConfig(
            InterestConfig({interestRateBps: 1200, numberOfPeriodsPerYear: 12})
        ).build();

        vm.prank(_nonExemptUser);
        uint256 invoiceId = bullaInvoice.createInvoice{value: _CORE_PROTOCOL_FEE}(params);

        // Fast forward to accrue interest
        vm.warp(block.timestamp + 90 days);

        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        uint256 accruedInterest = invoice.interestComputationState.accruedInterest;

        uint256 expectedProtocolFee = accruedInterest * _PROTOCOL_FEE_BPS / 10000; // 50%
        uint256 expectedCreditorInterest = accruedInterest - expectedProtocolFee;

        uint256 creditorBalanceBefore = _nonExemptUser.balance;
        uint256 contractBalanceBefore = address(bullaInvoice).balance;

        vm.expectEmit(true, false, false, true);
        emit InvoicePaid(invoiceId, accruedInterest, 0, expectedProtocolFee);

        // Pay interest
        vm.prank(_debtor);
        bullaInvoice.payInvoice{value: accruedInterest}(invoiceId, accruedInterest);

        // Verify protocol fee was charged
        assertEq(
            _nonExemptUser.balance - creditorBalanceBefore,
            expectedCreditorInterest,
            "Creditor should receive interest minus protocol fee"
        );
        assertEq(
            address(bullaInvoice).balance - contractBalanceBefore,
            expectedProtocolFee,
            "Protocol fee should be collected"
        );
    }

    // Test batch creation with exemption
    function testBatchCreateInvoicesWithExemption() public {
        // Add exempt user to whitelist
        vm.prank(_admin);
        feeExemptions.allow(_exemptUser);

        // Prepare batch calls
        CreateInvoiceParams memory params1 = new CreateInvoiceParamsBuilder().withCreditor(_exemptUser).withDebtor(
            _debtor
        ).withClaimAmount(1 ether).build();

        CreateInvoiceParams memory params2 = new CreateInvoiceParamsBuilder().withCreditor(_exemptUser).withDebtor(
            _debtor
        ).withClaimAmount(2 ether).build();

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(bullaInvoice.createInvoice.selector, params1);
        calls[1] = abi.encodeWithSelector(bullaInvoice.createInvoice.selector, params2);

        uint256 contractBalanceBefore = address(bullaClaim).balance;

        // Should work with 0 msg.value for exempt user
        vm.prank(_exemptUser);
        bullaInvoice.batchCreateInvoices{value: 0}(calls);

        // Verify no fees were charged
        assertEq(address(bullaClaim).balance, contractBalanceBefore, "No fees should be charged for exempt user");

        // Verify both invoices were created
        Invoice memory invoice1 = bullaInvoice.getInvoice(1);
        Invoice memory invoice2 = bullaInvoice.getInvoice(2);
        assertEq(invoice1.claimAmount, 1 ether, "First invoice should be created");
        assertEq(invoice2.claimAmount, 2 ether, "Second invoice should be created");
    }

    // Test batch creation without exemption
    function testBatchCreateInvoicesWithoutExemption() public {
        // Prepare batch calls
        CreateInvoiceParams memory params1 = new CreateInvoiceParamsBuilder().withCreditor(_nonExemptUser).withDebtor(
            _debtor
        ).withClaimAmount(1 ether).build();

        CreateInvoiceParams memory params2 = new CreateInvoiceParamsBuilder().withCreditor(_nonExemptUser).withDebtor(
            _debtor
        ).withClaimAmount(2 ether).build();

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(bullaInvoice.createInvoice.selector, params1);
        calls[1] = abi.encodeWithSelector(bullaInvoice.createInvoice.selector, params2);

        uint256 expectedTotalFee = _CORE_PROTOCOL_FEE * 2;

        // Should fail with 0 msg.value
        vm.prank(_nonExemptUser);
        vm.expectRevert(InvoiceBatchInvalidMsgValue.selector);
        bullaInvoice.batchCreateInvoices{value: 0}(calls);

        uint256 contractBalanceBefore = address(bullaClaim).balance;

        // Should succeed with correct total fee
        vm.prank(_nonExemptUser);
        bullaInvoice.batchCreateInvoices{value: expectedTotalFee}(calls);

        // Verify fees were charged
        assertEq(address(bullaClaim).balance - contractBalanceBefore, expectedTotalFee, "Total fees should be charged");
    }

    // Test that exemption status is locked at creation time
    function testExemptionStatusLockedAtCreation() public {
        // Create invoice as non-exempt user
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withCreditor(_nonExemptUser).withDebtor(
            _debtor
        ).withClaimAmount(1 ether).withLateFeeConfig(
            InterestConfig({interestRateBps: 1200, numberOfPeriodsPerYear: 12})
        ).build();

        vm.prank(_nonExemptUser);
        uint256 invoiceId = bullaInvoice.createInvoice{value: _CORE_PROTOCOL_FEE}(params);

        // Now make user exempt
        vm.prank(_admin);
        feeExemptions.allow(_nonExemptUser);

        // Fast forward to accrue interest
        vm.warp(block.timestamp + 90 days);

        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        uint256 accruedInterest = invoice.interestComputationState.accruedInterest;

        uint256 expectedProtocolFee = accruedInterest * _PROTOCOL_FEE_BPS / 10000; // 50% - still applies

        uint256 contractBalanceBefore = address(bullaInvoice).balance;

        // Protocol fee should still apply because exemption status was determined at creation
        vm.prank(_debtor);
        bullaInvoice.payInvoice{value: accruedInterest}(invoiceId, accruedInterest);

        assertEq(
            address(bullaInvoice).balance - contractBalanceBefore,
            expectedProtocolFee,
            "Protocol fee should still apply - exemption status locked at creation"
        );
    }
}
