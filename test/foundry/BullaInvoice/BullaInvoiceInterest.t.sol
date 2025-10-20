pragma solidity ^0.8.30;

import "forge-std/console.sol";
import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import "contracts/types/Types.sol";
import {WETH} from "contracts/mocks/weth.sol";
import {ERC20MockLegacy as ERC20Mock} from "contracts/mocks/ERC20MockLegacy.sol";
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
    NotPurchaseOrder
} from "contracts/BullaInvoice.sol";
import {DeployContracts} from "script/DeployContracts.s.sol";
import {CreateInvoiceParamsBuilder} from "test/foundry/BullaInvoice/CreateInvoiceParamsBuilder.sol";
import {CreateClaimParamsBuilder} from "test/foundry/BullaClaim/CreateClaimParamsBuilder.sol";
import {
    InterestConfig, InterestComputationState, CompoundInterestLib
} from "contracts/libraries/CompoundInterestLib.sol";

contract TestBullaInvoiceInterest is Test {
    WETH public weth;
    ERC20Mock public token;
    BullaClaimV2 public bullaClaim;
    EIP712Helper public sigHelper;
    BullaInvoice public bullaInvoice;

    uint256 creditorPK = uint256(0x01);
    uint256 debtorPK = uint256(0x02);
    uint256 adminPK = uint256(0x03);
    address creditor = vm.addr(creditorPK);
    address debtor = vm.addr(debtorPK);
    address admin = vm.addr(adminPK);

    // Common test amounts
    uint256 constant INVOICE_AMOUNT = 1 ether;
    uint256 constant SECONDS_PER_YEAR = 365 days;

    function setUp() public {
        weth = new WETH();
        token = new ERC20Mock("Test Token", "TST", debtor, 10 ether);

        DeployContracts.DeploymentResult memory deploymentResult =
            (new DeployContracts()).deployForTest(address(this), LockState.Unlocked, 0, 0, 0, 0, address(this));
        bullaClaim = BullaClaimV2(deploymentResult.bullaClaim);
        sigHelper = new EIP712Helper(address(bullaClaim));
        bullaInvoice = new BullaInvoice(address(bullaClaim), admin, 0);

        vm.prank(debtor);
        token.approve(address(bullaInvoice), type(uint256).max);

        // Setup create claim permission for creditor
        bullaClaim.approvalRegistry().permitCreateClaim({
            user: creditor,
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 10, // Allow multiple invoices
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 10,
                isBindingAllowed: false
            })
        });
    }

    // Test that a new invoice starts with period number 0
    function testInitialPeriodZero() public {
        uint256 dueBy = block.timestamp + 30 days;

        // Create invoice with late fee interest
        InterestConfig memory lateFeeConfig = InterestConfig({
            interestRateBps: 1000, // 10% annual interest rate
            numberOfPeriodsPerYear: 12 // Monthly compounding
        });

        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).withCreditor(creditor)
            .withToken(address(token)).withDueBy(dueBy).withLateFeeConfig(lateFeeConfig).build();

        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(params);

        // Check that period number is 0
        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        assertEq(invoice.interestComputationState.latestPeriodNumber, 0, "Initial period number should be 0");
        assertEq(invoice.interestComputationState.accruedInterest, 0, "Initial accrued interest should be 0");
    }

    // Test that no interest accrues before due date
    function testNoInterestBeforeDueDate() public {
        uint256 dueBy = block.timestamp + 30 days;

        // Create invoice with late fee interest
        InterestConfig memory lateFeeConfig = InterestConfig({
            interestRateBps: 1000, // 10% annual interest rate
            numberOfPeriodsPerYear: 12 // Monthly compounding
        });

        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).withCreditor(creditor)
            .withToken(address(token)).withDueBy(dueBy).withLateFeeConfig(lateFeeConfig).build();

        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(params);

        // Warp to 1 day before due date
        vm.warp(dueBy - 1 days);

        // Check that interest is still zero
        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        assertEq(invoice.interestComputationState.accruedInterest, 0, "No interest should accrue before due date");
        assertEq(
            invoice.interestComputationState.latestPeriodNumber, 0, "Period number should still be 0 before due date"
        );
    }

    // Test that interest starts accruing after due date
    function testInterestAccrualAfterDueDate() public {
        uint256 dueBy = block.timestamp + 30 days;

        // Create invoice with late fee interest
        InterestConfig memory lateFeeConfig = InterestConfig({
            interestRateBps: 1000, // 10% annual interest rate
            numberOfPeriodsPerYear: 12 // Monthly compounding
        });

        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).withCreditor(creditor)
            .withToken(address(token)).withDueBy(dueBy).withLateFeeConfig(lateFeeConfig).build();

        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(params);

        vm.warp(dueBy + 31 days);

        // Check that interest has accrued and period number is 1
        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        assertTrue(invoice.interestComputationState.accruedInterest > 0, "Interest should accrue after due date");
        assertEq(invoice.interestComputationState.latestPeriodNumber, 1, "Period number should be 1 after 1 period");
    }

    // Test compound interest over multiple periods
    function testCompoundInterestMultiplePeriods() public {
        uint256 dueBy = block.timestamp + 30 days;

        // Create invoice with late fee interest
        InterestConfig memory lateFeeConfig = InterestConfig({
            interestRateBps: 720, // 7.2% annual interest rate
            numberOfPeriodsPerYear: 1 // yearly compounding
        });

        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).withCreditor(creditor)
            .withToken(address(token)).withDueBy(dueBy).withLateFeeConfig(lateFeeConfig).build();

        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(params);

        vm.warp(dueBy + 10 * 365 days); // 10 years

        // Check interest after 1 quarter
        Invoice memory invoice1 = bullaInvoice.getInvoice(invoiceId);
        assertEq(
            invoice1.interestComputationState.latestPeriodNumber, 10, "Period number should be 10 after 10 periods"
        );

        // Should be 100% interest
        uint256 expectedInterest1 = INVOICE_AMOUNT;

        assertApproxEqRel(
            invoice1.interestComputationState.accruedInterest,
            expectedInterest1,
            0.01e18,
            "Interest after 10 periods should be 100% of the invoice amount"
        );

        // Warp to twenty periods
        vm.warp(dueBy + 20 * 365 days);

        // Check compounded interest after 20 periods
        Invoice memory invoice2 = bullaInvoice.getInvoice(invoiceId);
        assertEq(
            invoice2.interestComputationState.latestPeriodNumber, 20, "Period number should be 20 after twenty periods"
        );

        // Should be 300% interest
        uint256 expectedInterest2 = 3 ether;

        assertApproxEqRel(
            invoice2.interestComputationState.accruedInterest,
            expectedInterest2,
            0.01e18,
            "Interest after 20 periods should show compound effect"
        );
    }

    // Test paying interest while preserving period number
    function testInterestPaymentPreservesPeriod() public {
        uint256 dueBy = block.timestamp + 30 days;

        // Create invoice with late fee interest
        InterestConfig memory lateFeeConfig = InterestConfig({
            interestRateBps: 1000, // 10% annual interest rate
            numberOfPeriodsPerYear: 12 // Monthly compounding
        });

        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).withCreditor(creditor)
            .withToken(address(token)).withDueBy(dueBy).withLateFeeConfig(lateFeeConfig).build();

        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(params);

        // Warp to 2 months after due date
        uint256 secondsPerPeriod = SECONDS_PER_YEAR / 12;
        vm.warp(dueBy + 2 * secondsPerPeriod);

        // Check interest before payment
        Invoice memory invoiceBefore = bullaInvoice.getInvoice(invoiceId);
        uint256 periodNumberBefore = invoiceBefore.interestComputationState.latestPeriodNumber;
        uint256 interestBefore = invoiceBefore.interestComputationState.accruedInterest;
        assertTrue(interestBefore > 0, "Interest should have accrued");
        assertEq(periodNumberBefore, 2, "Period number should be 2 after two months");

        // Pay only the interest
        vm.prank(debtor);
        bullaInvoice.payInvoice(invoiceId, interestBefore);

        // Check interest after payment
        Invoice memory invoiceAfter = bullaInvoice.getInvoice(invoiceId);
        assertEq(
            invoiceAfter.interestComputationState.latestPeriodNumber,
            periodNumberBefore,
            "Period number should remain unchanged after payment"
        );
        assertEq(
            invoiceAfter.interestComputationState.accruedInterest,
            0,
            "Accrued interest should be zero after full interest payment"
        );
    }

    // Test partial interest payment
    function testPartialInterestPayment() public {
        uint256 dueBy = block.timestamp + 30 days;

        // Create invoice with late fee interest
        InterestConfig memory lateFeeConfig = InterestConfig({
            interestRateBps: 1000, // 10% annual interest rate
            numberOfPeriodsPerYear: 12 // Monthly compounding
        });

        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).withCreditor(creditor)
            .withToken(address(token)).withDueBy(dueBy).withLateFeeConfig(lateFeeConfig).build();

        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(params);

        // Warp to 3 months after due date
        vm.warp(dueBy + 3 * 92 days);

        // Check interest before payment
        Invoice memory invoiceBefore = bullaInvoice.getInvoice(invoiceId);
        uint256 interestBefore = invoiceBefore.interestComputationState.accruedInterest;
        assertTrue(interestBefore > 0, "Interest should have accrued");

        // Pay half of the interest
        uint256 halfInterest = interestBefore / 2;
        vm.prank(debtor);
        bullaInvoice.payInvoice(invoiceId, halfInterest);

        // Check interest after payment
        Invoice memory invoiceAfter = bullaInvoice.getInvoice(invoiceId);
        assertApproxEqRel(
            invoiceAfter.interestComputationState.accruedInterest,
            halfInterest,
            0.01e18,
            "Accrued interest should be approximately half of the original interest"
        );
    }

    // Test different compounding periods
    function testDifferentCompoundingPeriods() public {
        uint256 dueBy = block.timestamp + 30 days;
        uint256 oneYear = SECONDS_PER_YEAR;

        // Create invoice with quarterly compounding
        InterestConfig memory quarterlyConfig = InterestConfig({
            interestRateBps: 1000, // 10% annual interest rate
            numberOfPeriodsPerYear: 4 // Quarterly compounding
        });

        CreateInvoiceParams memory params1 = new CreateInvoiceParamsBuilder().withDebtor(debtor).withCreditor(creditor)
            .withToken(address(token)).withDueBy(dueBy).withLateFeeConfig(quarterlyConfig).build();

        vm.prank(creditor);
        uint256 invoiceId1 = bullaInvoice.createInvoice(params1);

        // Create invoice with monthly compounding
        InterestConfig memory monthlyConfig = InterestConfig({
            interestRateBps: 1000, // 10% annual interest rate
            numberOfPeriodsPerYear: 12 // Monthly compounding
        });

        CreateInvoiceParams memory params2 = new CreateInvoiceParamsBuilder().withDebtor(debtor).withCreditor(creditor)
            .withToken(address(token)).withDueBy(dueBy).withLateFeeConfig(monthlyConfig).build();

        vm.prank(creditor);
        uint256 invoiceId2 = bullaInvoice.createInvoice(params2);

        // Warp to 1 year after due date
        vm.warp(dueBy + oneYear);

        // Check interest with quarterly compounding
        Invoice memory invoice1 = bullaInvoice.getInvoice(invoiceId1);
        assertEq(
            invoice1.interestComputationState.latestPeriodNumber,
            4,
            "Period number should be 4 after 1 year with quarterly compounding"
        );

        // Check interest with monthly compounding
        Invoice memory invoice2 = bullaInvoice.getInvoice(invoiceId2);
        assertEq(
            invoice2.interestComputationState.latestPeriodNumber,
            12,
            "Period number should be 12 after 1 year with monthly compounding"
        );

        // Monthly compounding should result in slightly higher interest than quarterly
        assertTrue(
            invoice2.interestComputationState.accruedInterest > invoice1.interestComputationState.accruedInterest,
            "Monthly compounding should result in more interest than quarterly compounding"
        );
    }

    // Test zero interest configuration
    function testZeroInterestConfig() public {
        uint256 dueBy = block.timestamp + 30 days;

        // Create invoice with zero interest rate
        InterestConfig memory zeroInterestConfig = InterestConfig({
            interestRateBps: 0, // 0% interest
            numberOfPeriodsPerYear: 12 // Monthly compounding (doesn't matter with 0%)
        });

        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).withCreditor(creditor)
            .withToken(address(token)).withDueBy(dueBy).withLateFeeConfig(zeroInterestConfig).build();

        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(params);

        // Warp to 1 year after due date
        vm.warp(dueBy + SECONDS_PER_YEAR);

        // Check that no interest accrued despite being past due
        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        assertEq(invoice.interestComputationState.accruedInterest, 0, "No interest should accrue with 0% interest rate");
    }

    // Test simple interest configuration (numberOfPeriodsPerYear = 0)
    function testSimpleInterestConfig() public {
        uint256 dueBy = block.timestamp + 30 days;

        // Create invoice with simple interest configuration
        InterestConfig memory simpleInterestConfig = InterestConfig({
            interestRateBps: 1000, // 10% interest
            numberOfPeriodsPerYear: 0 // Simple interest (no compounding)
        });

        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).withCreditor(creditor)
            .withToken(address(token)).withDueBy(dueBy).withLateFeeConfig(simpleInterestConfig).build();

        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(params);

        // Test partial day doesn't accrue interest
        vm.warp(dueBy + 12 hours); // Only half a day
        Invoice memory invoicePartialDay = bullaInvoice.getInvoice(invoiceId);
        assertEq(
            invoicePartialDay.interestComputationState.accruedInterest, 0, "No interest should accrue for partial days"
        );

        // Warp to 365 complete days (1 year) after due date
        vm.warp(dueBy + 365 days);

        // Check that simple interest accrued
        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);

        // For simple interest: Interest = Principal × Rate × Time
        // Expected: 1 ether × 10% × 1 year = 0.1 ether
        assertEq(
            invoice.interestComputationState.accruedInterest,
            0.1 ether,
            "Simple interest should be 10% of principal for 1 year"
        );
        assertEq(
            invoice.interestComputationState.latestPeriodNumber, 0, "Period number should remain 0 for simple interest"
        );

        // Test that exactly 730 days (2 years) gives double interest
        vm.warp(dueBy + 730 days);

        Invoice memory invoiceAfter2Years = bullaInvoice.getInvoice(invoiceId);
        assertEq(
            invoiceAfter2Years.interestComputationState.accruedInterest,
            0.2 ether,
            "Simple interest should be 20% of principal for 2 years"
        );
        assertEq(
            invoiceAfter2Years.interestComputationState.latestPeriodNumber,
            0,
            "Period number should remain 0 for simple interest"
        );
    }

    // Test paying principal and interest together
    function testPayingPrincipalAndInterest() public {
        uint256 dueBy = block.timestamp + 30 days;

        // Create invoice with late fee interest
        InterestConfig memory lateFeeConfig = InterestConfig({
            interestRateBps: 1000, // 10% annual interest rate
            numberOfPeriodsPerYear: 12 // Monthly compounding
        });

        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).withCreditor(creditor)
            .withToken(address(token)).withDueBy(dueBy).withLateFeeConfig(lateFeeConfig).build();

        vm.prank(creditor);
        uint256 invoiceId = bullaInvoice.createInvoice(params);

        // Warp to 2 months after due date
        uint256 secondsPerPeriod = SECONDS_PER_YEAR / 12;
        vm.warp(dueBy + 2 * secondsPerPeriod);

        // Check interest before payment
        Invoice memory invoiceBefore = bullaInvoice.getInvoice(invoiceId);
        uint256 interestBefore = invoiceBefore.interestComputationState.accruedInterest;
        assertTrue(interestBefore > 0, "Interest should have accrued");

        // Pay half principal + all interest
        uint256 halfPrincipal = INVOICE_AMOUNT / 2;
        uint256 totalPayment = halfPrincipal + interestBefore;

        vm.prank(debtor);
        bullaInvoice.payInvoice(invoiceId, totalPayment);

        // Check invoice after payment
        Invoice memory invoiceAfter = bullaInvoice.getInvoice(invoiceId);
        assertEq(invoiceAfter.paidAmount, halfPrincipal, "Half of principal should be paid");
        assertEq(invoiceAfter.interestComputationState.accruedInterest, 0, "Interest should be fully paid");
    }
}
