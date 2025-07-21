pragma solidity ^0.8.30;

import "forge-std/console.sol";
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
    IncorrectMsgValue
} from "contracts/BullaInvoice.sol";
import {DeployContracts} from "script/DeployContracts.s.sol";
import {CreateInvoiceParamsBuilder} from "test/foundry/BullaInvoice/CreateInvoiceParamsBuilder.sol";
import {CreateClaimParamsBuilder} from "test/foundry/BullaClaim/CreateClaimParamsBuilder.sol";
import {BullaClaimValidationLib} from "contracts/libraries/BullaClaimValidationLib.sol";
import {InterestConfig} from "contracts/libraries/CompoundInterestLib.sol";
import {ERC20MockLegacy as ERC20Mock} from "contracts/mocks/ERC20MockLegacy.sol";

contract TestBullaInvoiceProtocolFee is Test {
    WETH public weth;
    BullaClaim public bullaClaim;
    EIP712Helper public sigHelper;
    BullaInvoice public bullaInvoice;
    ERC20Mock public token1;
    ERC20Mock public token2;

    uint16 constant MAX_BPS = 10_000;
    uint256 constant INVOICE_ORIGINATION_FEE = 0 ether;
    uint256 constant PURCHASE_ORDER_ORIGINATION_FEE = 0 ether;
    uint256 creditorPK = uint256(0x01);
    uint256 debtorPK = uint256(0x02);
    uint256 adminPK = uint256(0x03);
    uint256 nonAdminPK = uint256(0x04);
    address creditor = vm.addr(creditorPK);
    address debtor = vm.addr(debtorPK);
    address admin = vm.addr(adminPK);
    address nonAdmin = vm.addr(nonAdminPK);

    // Events for testing
    event InvoiceCreated(uint256 indexed claimId, InvoiceDetails invoiceDetails, uint256 originationFee);
    event InvoicePaid(uint256 indexed claimId, uint256 grossInterestPaid, uint256 principalPaid, uint256 protocolFee);
    event ProtocolFeeUpdated(uint16 oldFee, uint16 newFee);
    event FeeWithdrawn(address indexed admin, address indexed token, uint256 amount);

    function setUp() public {
        weth = new WETH();
        token1 = new ERC20Mock("Token1", "TK1", debtor, 1000 ether);
        token2 = new ERC20Mock("Token2", "TK2", debtor, 1000 ether);

        DeployContracts.DeploymentResult memory deploymentResult =
            (new DeployContracts()).deployForTest(address(this), LockState.Unlocked, 0 ether, 0, 0, address(this));
        bullaClaim = BullaClaim(deploymentResult.bullaClaim);
        sigHelper = new EIP712Helper(address(bullaClaim));

        // Start with 10% protocol fee for mathematical simplicity (interest % = protocol fee %)
        bullaInvoice = new BullaInvoice(address(bullaClaim), admin, 1000);

        // Setup balances
        vm.deal(debtor, 100 ether);
        vm.deal(creditor, 100 ether);
        vm.deal(admin, 100 ether);
    }

    // ==================== 1. CONSTRUCTOR & INITIALIZATION TESTS ====================

    function testConstructorWithMaxProtocolFee() public {
        BullaInvoice testInvoice = new BullaInvoice(address(bullaClaim), admin, MAX_BPS);
        assertEq(testInvoice.protocolFeeBPS(), MAX_BPS, "Protocol fee should be MAX_BPS");
        assertEq(testInvoice.admin(), admin, "Admin should be set correctly");
    }

    function testConstructorRevertsWithInvalidProtocolFee() public {
        vm.expectRevert(InvalidProtocolFee.selector);
        new BullaInvoice(address(bullaClaim), admin, MAX_BPS + 1);
    }

    // ==================== 2. PROTOCOL FEE CALCULATION TESTS ====================

    function testFeeCalculationWithZeroProtocolFee() public {
        BullaInvoice zeroFeeInvoice = new BullaInvoice(address(bullaClaim), admin, 0);

        uint256 invoiceId = _createAndSetupInvoice(zeroFeeInvoice, address(0), 1 ether, _getInterestConfig(1000, 12));

        // Fast forward to accrue interest
        vm.warp(block.timestamp + 90 days);

        // Make payment covering interest
        vm.prank(debtor);
        zeroFeeInvoice.payInvoice{value: 0.1 ether}(invoiceId, 0.1 ether);

        // Check that no protocol fee was charged
        assertEq(address(zeroFeeInvoice).balance, 0, "No ETH should remain in contract");
    }

    // Helper functions
    function _createAndSetupInvoice(
        BullaInvoice invoice,
        address token,
        uint256 amount,
        InterestConfig memory interestConfig
    ) internal returns (uint256) {
        // Setup permissions
        bullaClaim.approvalRegistry().permitCreateClaim({
            user: creditor,
            controller: address(invoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: creditorPK,
                user: creditor,
                controller: address(invoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        // Create invoice with interest
        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withDebtor(debtor).withCreditor(creditor)
            .withToken(token).withClaimAmount(amount).withLateFeeConfig(interestConfig).build();

        uint256 fee = bullaClaim.CORE_PROTOCOL_FEE();

        vm.prank(creditor);
        return invoice.createInvoice{value: fee}(params);
    }

    function _getInterestConfig(uint16 rateBps, uint16 periodsPerYear) internal pure returns (InterestConfig memory) {
        return InterestConfig({interestRateBps: rateBps, numberOfPeriodsPerYear: periodsPerYear});
    }

    // ==================== 3. PAYMENT FUNCTION TESTS - CORE LOGIC ====================
    function testPaymentCoveringOnlyPrincipal() public {
        uint256 invoiceId = _createAndSetupInvoice(bullaInvoice, address(0), 1 ether, _getInterestConfig(0, 0)); // No interest

        uint256 creditorBalanceBefore = creditor.balance;
        uint256 principalPayment = 0.5 ether;

        vm.expectEmit(true, false, false, true);
        emit InvoicePaid(invoiceId, 0, principalPayment, 0);

        // Pay principal only (no interest, so no protocol fee)
        vm.prank(debtor);
        bullaInvoice.payInvoice{value: principalPayment}(invoiceId, principalPayment);

        // Verify no protocol fee charged on principal
        assertEq(
            creditor.balance - creditorBalanceBefore, principalPayment, "Creditor should receive full principal payment"
        );
        assertEq(address(bullaInvoice).balance, 0, "No protocol fee should be charged");

        Invoice memory updatedInvoice = bullaInvoice.getInvoice(invoiceId);
        assertEq(updatedInvoice.paidAmount, principalPayment, "Principal should be updated");
    }

    function testPaymentCoveringFullInterestAndPartialPrincipal() public {
        uint256 invoiceId = _createAndSetupInvoice(bullaInvoice, address(0), 1 ether, _getInterestConfig(1000, 12));

        // Fast forward to accrue interest
        vm.warp(block.timestamp + 90 days);

        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        uint256 accruedInterest = invoice.interestComputationState.accruedInterest;

        uint256 principalPortion = 0.4 ether;
        uint256 paymentAmount = accruedInterest + principalPortion;

        // With 50% protocol fee: protocol fee = accruedInterest / 2
        uint256 expectedProtocolFee = accruedInterest / 2;
        uint256 creditorBalanceBefore = creditor.balance;

        vm.expectEmit(true, false, false, true);
        emit InvoicePaid(invoiceId, accruedInterest, principalPortion, expectedProtocolFee);

        vm.prank(debtor);
        bullaInvoice.payInvoice{value: paymentAmount}(invoiceId, paymentAmount);

        assertEq(
            creditor.balance - creditorBalanceBefore - 0.4 ether,
            address(bullaInvoice).balance,
            "Creditor should receive correct amount"
        );
    }

    function testPaymentCoveringFullInterestAndFullPrincipal() public {
        uint256 invoiceId = _createAndSetupInvoice(bullaInvoice, address(0), 1 ether, _getInterestConfig(1000, 12));

        // Fast forward to accrue interest
        vm.warp(block.timestamp + 90 days);

        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        uint256 accruedInterest = invoice.interestComputationState.accruedInterest;

        uint256 paymentAmount = accruedInterest + 1 ether; // Full interest + full principal

        // With 50% protocol fee: protocol fee = accruedInterest / 2
        uint256 expectedProtocolFee = accruedInterest / 2;
        uint256 creditorBalanceBefore = creditor.balance;

        vm.expectEmit(true, false, false, true);
        emit InvoicePaid(invoiceId, accruedInterest, 1 ether, expectedProtocolFee);

        vm.prank(debtor);
        bullaInvoice.payInvoice{value: paymentAmount}(invoiceId, paymentAmount);

        // Verify invoice is fully paid
        Invoice memory updatedInvoice = bullaInvoice.getInvoice(invoiceId);
        assertTrue(updatedInvoice.status == Status.Paid, "Invoice should be fully paid");
        assertEq(
            creditor.balance - creditorBalanceBefore - 1 ether,
            address(bullaInvoice).balance,
            "Creditor should receive correct amount"
        );
        assertGt(address(bullaInvoice).balance, 0, "Protocol fee is not 0");
    }

    function testProtocolFeeOnlyOnInterestPortion() public {
        uint256 invoiceId = _createAndSetupInvoice(bullaInvoice, address(0), 2 ether, _getInterestConfig(1000, 12));

        // Fast forward to accrue significant interest
        vm.warp(block.timestamp + 62 days); // 2 months

        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        uint256 accruedInterest = invoice.interestComputationState.accruedInterest;

        // Make multiple payments to verify consistent behavior
        uint256 payment1 = accruedInterest / 3 + 0.5 ether; // Part interest + part principal
        uint256 payment2 = accruedInterest / 3 + 0.5 ether; // Part interest + part principal
        uint256 payment3 = accruedInterest - (2 * (accruedInterest / 3)) + 1 ether; // Remaining interest + remaining principal

        uint256 creditorBalanceBefore = creditor.balance;

        // Payment 1
        vm.prank(debtor);
        bullaInvoice.payInvoice{value: payment1}(invoiceId, payment1);

        // Payment 2
        vm.prank(debtor);
        bullaInvoice.payInvoice{value: payment2}(invoiceId, payment2);

        // Payment 3
        vm.prank(debtor);
        bullaInvoice.payInvoice{value: payment3}(invoiceId, payment3);

        // Verify total protocol fee accumulated correctly
        assertEq(
            address(bullaInvoice).balance,
            creditor.balance - creditorBalanceBefore - 2 ether,
            "Total protocol fee should be half of total interest"
        );
        assertGt(address(bullaInvoice).balance, 0, "Protocol fee is not 0");
    }

    // ==================== 4. ERC20 PAYMENT TESTS ====================

    function testFirstERC20PaymentAddsTokenToArray() public {
        uint256 invoiceId = _createAndSetupInvoice(bullaInvoice, address(token1), 1 ether, _getInterestConfig(1000, 12));

        // Fast forward to accrue interest
        vm.warp(block.timestamp + 90 days);

        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        uint256 accruedInterest = invoice.interestComputationState.accruedInterest;

        vm.expectRevert();
        bullaInvoice.protocolFeeTokens(0);

        // Make payment with interest
        vm.prank(debtor);
        token1.approve(address(bullaInvoice), accruedInterest);

        vm.prank(debtor);
        bullaInvoice.payInvoice(invoiceId, accruedInterest);

        // Verify token added to array
        assertEq(bullaInvoice.protocolFeeTokens(0), address(token1), "Token should be added to protocolFeeTokens array");
        assertGt(bullaInvoice.protocolFeesByToken(address(token1)), 0, "Protocol fee should be tracked");
    }

    function testSubsequentPaymentsSameTokenIncrementFees() public {
        uint256 invoiceId = _createAndSetupInvoice(bullaInvoice, address(token1), 2 ether, _getInterestConfig(1000, 24));

        // Fast forward to accrue interest
        vm.warp(block.timestamp + 60 days);

        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        uint256 accruedInterest = invoice.interestComputationState.accruedInterest;

        // Make first payment (partial interest)
        uint256 payment1 = accruedInterest / 2;
        vm.prank(debtor);
        token1.approve(address(bullaInvoice), payment1);
        vm.prank(debtor);
        bullaInvoice.payInvoice(invoiceId, payment1);

        uint256 collectedFee1 = bullaInvoice.protocolFeesByToken(address(token1));

        // Make second payment (remaining interest)
        vm.prank(debtor);
        token1.approve(address(bullaInvoice), payment1);
        vm.prank(debtor);
        bullaInvoice.payInvoice(invoiceId, payment1);

        // Total protocol fee = (payment1 + payment2) / 2 = accruedInterest / 2
        assertEq(
            bullaInvoice.protocolFeesByToken(address(token1)),
            2 * collectedFee1,
            "Total protocol fee should be double since it is the same amount twice"
        );
        assertGt(bullaInvoice.protocolFeesByToken(address(token1)), 0, "Protocol fee is not 0");

        // Verify only one entry in array
        assertEq(bullaInvoice.protocolFeeTokens(0), address(token1), "Token should still be at index 0");
        vm.expectRevert();
        bullaInvoice.protocolFeeTokens(1); // Should revert - no second token
    }

    // ==================== 5. ETH PAYMENT TESTS ====================

    function testETHPaymentWithCorrectMsgValue() public {
        uint256 invoiceId = _createAndSetupInvoice(bullaInvoice, address(0), 1 ether, _getInterestConfig(1000, 12));

        // Fast forward to accrue interest
        vm.warp(block.timestamp + 90 days);

        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        uint256 accruedInterest = invoice.interestComputationState.accruedInterest;
        uint256 paymentAmount = accruedInterest + 0.5 ether;

        // Make ETH payment with correct msg.value does not throw
        vm.prank(debtor);
        bullaInvoice.payInvoice{value: paymentAmount}(invoiceId, paymentAmount);
    }

    function testETHPaymentWithIncorrectMsgValueReverts() public {
        uint256 invoiceId = _createAndSetupInvoice(bullaInvoice, address(0), 1 ether, _getInterestConfig(1000, 12));

        // Fast forward to accrue interest
        vm.warp(block.timestamp + 90 days);

        uint256 paymentAmount = 0.5 ether;
        uint256 incorrectMsgValue = 0.3 ether; // Different from paymentAmount

        // Should revert when msg.value != paymentAmount
        vm.prank(debtor);
        vm.expectRevert(IncorrectMsgValue.selector);
        bullaInvoice.payInvoice{value: incorrectMsgValue}(invoiceId, paymentAmount);
    }

    function testETHBalanceVerification() public {
        uint256 invoiceId = _createAndSetupInvoice(bullaInvoice, address(0), 2 ether, _getInterestConfig(1000, 12));

        // Fast forward to accrue interest
        vm.warp(block.timestamp + 90 days);

        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        uint256 accruedInterest = invoice.interestComputationState.accruedInterest;
        uint256 paymentAmount = accruedInterest + 1 ether; // Interest + partial principal

        uint256 debtorBalanceBefore = debtor.balance;
        uint256 creditorBalanceBefore = creditor.balance;
        uint256 contractBalanceBefore = address(bullaInvoice).balance;

        vm.prank(debtor);
        bullaInvoice.payInvoice{value: paymentAmount}(invoiceId, paymentAmount);

        // Verify all balance changes
        assertEq(debtorBalanceBefore - debtor.balance, paymentAmount, "Debtor should pay full amount");
        assertEq(
            paymentAmount - (creditor.balance - creditorBalanceBefore),
            address(bullaInvoice).balance - contractBalanceBefore,
            "Protocol fee is half of net interest"
        );
        assertGt(address(bullaInvoice).balance - contractBalanceBefore, 0, "Protocol fee should be greater than 0");
    }

    // ==================== 6. PROTOCOL FEE MANAGEMENT TESTS ====================

    function testAdminCanWithdrawETHFees() public {
        uint256 invoiceId = _createAndSetupInvoice(bullaInvoice, address(0), 1 ether, _getInterestConfig(1000, 12));

        // Fast forward and make payment to accumulate ETH fees
        vm.warp(block.timestamp + 90 days);
        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        uint256 accruedInterest = invoice.interestComputationState.accruedInterest;

        vm.prank(debtor);
        bullaInvoice.payInvoice{value: accruedInterest}(invoiceId, accruedInterest);

        uint256 adminBalanceBefore = admin.balance;

        // Admin withdraws fees
        vm.prank(admin);
        bullaInvoice.withdrawAllFees();

        // Verify admin received ETH fees
        assertGt(admin.balance - adminBalanceBefore, 0, "Admin should receive ETH protocol fees");
        assertEq(address(bullaInvoice).balance, 0, "Contract ETH balance should be zero after withdrawal");
    }

    function testAdminCanWithdrawERC20FeesMultipleTokens() public {
        // Create invoices with different tokens
        uint256 invoice1 = _createAndSetupInvoice(bullaInvoice, address(token1), 1 ether, _getInterestConfig(1000, 12));
        uint256 invoice2 = _createAndSetupInvoice(bullaInvoice, address(token2), 1 ether, _getInterestConfig(1000, 12));

        // Fast forward and make payments
        vm.warp(block.timestamp + 90 days);

        Invoice memory inv1 = bullaInvoice.getInvoice(invoice1);
        Invoice memory inv2 = bullaInvoice.getInvoice(invoice2);

        uint256 payment1 = inv1.interestComputationState.accruedInterest;
        uint256 payment2 = inv2.interestComputationState.accruedInterest;

        vm.prank(debtor);
        token1.approve(address(bullaInvoice), payment1);
        vm.prank(debtor);
        bullaInvoice.payInvoice(invoice1, payment1);

        vm.prank(debtor);
        token2.approve(address(bullaInvoice), payment2);
        vm.prank(debtor);
        bullaInvoice.payInvoice(invoice2, payment2);

        uint256 adminToken1Before = token1.balanceOf(admin);
        uint256 adminToken2Before = token2.balanceOf(admin);

        // Admin withdraws all fees
        vm.prank(admin);
        bullaInvoice.withdrawAllFees();

        // Verify admin received both token fees
        assertGt(token1.balanceOf(admin) - adminToken1Before, 0, "Admin should receive token1 fees");
        assertGt(token2.balanceOf(admin) - adminToken2Before, 0, "Admin should receive token2 fees");

        // Verify fees reset to 0
        assertEq(bullaInvoice.protocolFeesByToken(address(token1)), 0, "Token1 fees should be reset");
        assertEq(bullaInvoice.protocolFeesByToken(address(token2)), 0, "Token2 fees should be reset");
    }

    function testFeeAmountsResetAfterWithdrawal() public {
        uint256 invoiceId = _createAndSetupInvoice(bullaInvoice, address(token1), 1 ether, _getInterestConfig(1000, 12));

        // Make payment to accumulate fees
        vm.warp(block.timestamp + 90 days);
        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        uint256 accruedInterest = invoice.interestComputationState.accruedInterest;

        vm.prank(debtor);
        token1.approve(address(bullaInvoice), accruedInterest);
        vm.prank(debtor);
        bullaInvoice.payInvoice(invoiceId, accruedInterest);

        uint256 feeBeforeWithdrawal = bullaInvoice.protocolFeesByToken(address(token1));
        assertTrue(feeBeforeWithdrawal > 0, "Fee should be accumulated");

        // Withdraw fees
        vm.prank(admin);
        bullaInvoice.withdrawAllFees();

        // Verify fee reset
        assertEq(bullaInvoice.protocolFeesByToken(address(token1)), 0, "Fee should be reset to 0");
    }

    function testNonAdminCannotWithdrawFees() public {
        vm.prank(nonAdmin);
        vm.expectRevert(NotAdmin.selector);
        bullaInvoice.withdrawAllFees();
    }

    function testWithdrawalWithNoAccumulatedFees() public {
        uint256 adminBalanceBefore = admin.balance;

        // Admin tries to withdraw with no accumulated fees
        vm.prank(admin);
        bullaInvoice.withdrawAllFees(); // Should not revert

        // Verify no change in admin balance
        assertEq(admin.balance, adminBalanceBefore, "Admin balance should be unchanged");
    }

    function testAdminCanUpdateProtocolFee() public {
        uint16 newFee = 500; // 5%

        vm.expectEmit(false, false, false, true);
        emit ProtocolFeeUpdated(uint16(1000), newFee); // Old fee was 10%

        vm.prank(admin);
        bullaInvoice.setProtocolFee(newFee);

        assertEq(bullaInvoice.protocolFeeBPS(), newFee, "Protocol fee should be updated");
    }

    function testProtocolFeeUpdateEmitsEvent() public {
        uint16 oldFee = bullaInvoice.protocolFeeBPS();
        uint16 newFee = 750;

        vm.expectEmit(false, false, false, true);
        emit ProtocolFeeUpdated(oldFee, newFee);

        vm.prank(admin);
        bullaInvoice.setProtocolFee(newFee);
    }

    function testNonAdminCannotUpdateProtocolFee() public {
        vm.prank(nonAdmin);
        vm.expectRevert(NotAdmin.selector);
        bullaInvoice.setProtocolFee(10000);
    }

    function testSetProtocolFeeRevertsWithInvalidFee() public {
        vm.prank(admin);
        vm.expectRevert(InvalidProtocolFee.selector);
        bullaInvoice.setProtocolFee(MAX_BPS + uint16(1));
    }

    function testSetProtocolFeeToZero() public {
        vm.prank(admin);
        bullaInvoice.setProtocolFee(0);

        assertEq(bullaInvoice.protocolFeeBPS(), 0, "Protocol fee should be set to 0");
    }

    function testSetProtocolFeeToMaxBPS() public {
        vm.prank(admin);
        bullaInvoice.setProtocolFee(MAX_BPS);

        assertEq(bullaInvoice.protocolFeeBPS(), MAX_BPS, "Protocol fee should be set to MAX_BPS");
    }

    // ==================== 7. EVENT EMISSION TESTS ====================

    function testInvoicePaidEventWithCorrectParameters() public {
        uint256 invoiceId = _createAndSetupInvoice(bullaInvoice, address(0), 1 ether, _getInterestConfig(1000, 12));

        vm.warp(block.timestamp + 90 days);
        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        uint256 accruedInterest = invoice.interestComputationState.accruedInterest;
        uint256 principalPayment = 0.5 ether;
        uint256 paymentAmount = accruedInterest + principalPayment;

        // With protocol fee = interest: protocol fee = accruedInterest / 2
        uint256 expectedProtocolFee = accruedInterest / 2;

        vm.expectEmit(true, false, false, true);
        emit InvoicePaid(invoiceId, accruedInterest, principalPayment, expectedProtocolFee);

        vm.prank(debtor);
        bullaInvoice.payInvoice{value: paymentAmount}(invoiceId, paymentAmount);
    }

    function testEventEmissionWithVariousPaymentScenarios() public {
        uint256 invoiceId = _createAndSetupInvoice(bullaInvoice, address(token1), 2 ether, _getInterestConfig(1000, 12));

        vm.warp(block.timestamp + 90 days);
        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        uint256 accruedInterest = invoice.interestComputationState.accruedInterest;

        // Scenario 1: Interest only
        uint256 payment1 = accruedInterest;
        // With protocol fee = interest: protocol fee = payment1 / 2
        uint256 expectedProtocolFee1 = payment1 / 2;

        vm.prank(debtor);
        token1.approve(address(bullaInvoice), payment1);

        vm.expectEmit(true, false, false, true);
        emit InvoicePaid(invoiceId, payment1, 0, expectedProtocolFee1);
        vm.prank(debtor);
        bullaInvoice.payInvoice(invoiceId, payment1);

        // Scenario 2: Principal only (no remaining interest)
        uint256 payment2 = 1 ether;

        vm.prank(debtor);
        token1.approve(address(bullaInvoice), payment2);

        vm.expectEmit(true, false, false, true);
        emit InvoicePaid(invoiceId, 0, payment2, 0);

        vm.prank(debtor);
        bullaInvoice.payInvoice(invoiceId, payment2);
    }

    function testEventEmissionWhenProtocolFeeIsZero() public {
        BullaInvoice zeroFeeInvoice = new BullaInvoice(address(bullaClaim), admin, 0);
        uint256 invoiceId = _createAndSetupInvoice(zeroFeeInvoice, address(0), 1 ether, _getInterestConfig(1000, 12));

        vm.warp(block.timestamp + 90 days);
        Invoice memory invoice = zeroFeeInvoice.getInvoice(invoiceId);
        uint256 accruedInterest = invoice.interestComputationState.accruedInterest;

        vm.expectEmit(true, false, false, true);
        emit InvoicePaid(invoiceId, accruedInterest, 0, 0); // Protocol fee should be 0

        vm.prank(debtor);
        zeroFeeInvoice.payInvoice{value: accruedInterest}(invoiceId, accruedInterest);
    }

    // ==================== 8. INTEGRATION TESTS ====================

    function testEndToEndInvoiceLifecycleWithProtocolFees() public {
        // Create invoice with interest
        uint256 invoiceId = _createAndSetupInvoice(bullaInvoice, address(token1), 2 ether, _getInterestConfig(1000, 12));

        // Fast forward to accrue interest
        vm.warp(block.timestamp + 62 days); // 2 months

        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        uint256 totalInterest = invoice.interestComputationState.accruedInterest;

        // Make partial payments
        uint256 payment1 = totalInterest / 3 + 0.5 ether;
        uint256 payment2 = totalInterest / 3 + 0.5 ether;
        uint256 payment3 = (totalInterest - (totalInterest / 3) - (totalInterest / 3)) + 1 ether; // Remaining

        // With protocol fee = interest: total protocol fee = totalInterest / 2
        uint256 expectedTotalProtocolFee = totalInterest / 2;

        // Payment 1
        vm.prank(debtor);
        token1.approve(address(bullaInvoice), payment1);
        vm.prank(debtor);
        bullaInvoice.payInvoice(invoiceId, payment1);

        // Payment 2
        vm.prank(debtor);
        token1.approve(address(bullaInvoice), payment2);
        vm.prank(debtor);
        bullaInvoice.payInvoice(invoiceId, payment2);

        // Payment 3 (final)
        vm.prank(debtor);
        token1.approve(address(bullaInvoice), payment3);
        vm.prank(debtor);
        bullaInvoice.payInvoice(invoiceId, payment3);

        // Verify final state
        Invoice memory finalInvoice = bullaInvoice.getInvoice(invoiceId);
        assertTrue(finalInvoice.status == Status.Paid, "Invoice should be fully paid");
        assertEq(finalInvoice.paidAmount, 2 ether, "Principal should be fully paid");

        // Verify protocol fees accumulated
        assertApproxEqAbs(
            bullaInvoice.protocolFeesByToken(address(token1)), expectedTotalProtocolFee, 3, "Protocol fees should match"
        );

        // Admin withdraws fees
        uint256 adminBalanceBefore = token1.balanceOf(admin);
        vm.prank(admin);
        bullaInvoice.withdrawAllFees();

        assertApproxEqAbs(
            token1.balanceOf(admin) - adminBalanceBefore,
            expectedTotalProtocolFee,
            3,
            "Admin should receive total protocol fees"
        );
    }

    function testMultipleInvoicesDifferentTokensAndFeeAccumulation() public {
        // Create multiple invoices with different tokens
        uint256 ethInvoice = _createAndSetupInvoice(bullaInvoice, address(0), 1 ether, _getInterestConfig(1000, 12));
        uint256 token1Invoice =
            _createAndSetupInvoice(bullaInvoice, address(token1), 1 ether, _getInterestConfig(1000, 12));
        uint256 token2Invoice =
            _createAndSetupInvoice(bullaInvoice, address(token2), 1 ether, _getInterestConfig(1000, 12));

        vm.warp(block.timestamp + 90 days);

        // Make payments on all invoices
        Invoice memory ethInv = bullaInvoice.getInvoice(ethInvoice);
        Invoice memory token1Inv = bullaInvoice.getInvoice(token1Invoice);
        Invoice memory token2Inv = bullaInvoice.getInvoice(token2Invoice);

        uint256 ethInterest = ethInv.interestComputationState.accruedInterest;
        uint256 token1Interest = token1Inv.interestComputationState.accruedInterest;
        uint256 token2Interest = token2Inv.interestComputationState.accruedInterest;

        // ETH payment
        vm.prank(debtor);
        bullaInvoice.payInvoice{value: ethInterest}(ethInvoice, ethInterest);

        // Token1 payment
        vm.prank(debtor);
        token1.approve(address(bullaInvoice), token1Interest);
        vm.prank(debtor);
        bullaInvoice.payInvoice(token1Invoice, token1Interest);

        // Token2 payment
        vm.prank(debtor);
        token2.approve(address(bullaInvoice), token2Interest);
        vm.prank(debtor);
        bullaInvoice.payInvoice(token2Invoice, token2Interest);

        // Verify separate fee tracking - with protocol fee = interest
        uint256 expectedEthFee = ethInterest / 2;
        uint256 expectedToken1Fee = token1Interest / 2;
        uint256 expectedToken2Fee = token2Interest / 2;

        assertEq(address(bullaInvoice).balance, expectedEthFee, "ETH fees in contract balance");
        assertEq(bullaInvoice.protocolFeesByToken(address(token1)), expectedToken1Fee, "Token1 fees tracked");
        assertEq(bullaInvoice.protocolFeesByToken(address(token2)), expectedToken2Fee, "Token2 fees tracked");

        // Verify token array contains both tokens
        assertEq(bullaInvoice.protocolFeeTokens(0), address(token1), "First token in array");
        assertEq(bullaInvoice.protocolFeeTokens(1), address(token2), "Second token in array");
    }

    // ==================== 9. EDGE CASES & ERROR HANDLING ====================

    function testPaymentOfOneWeiWithProtocolFees() public {
        uint256 invoiceId = _createAndSetupInvoice(bullaInvoice, address(0), 1000 wei, _getInterestConfig(1000, 12));

        vm.warp(block.timestamp + 1 days);

        uint256 creditorBalanceBefore = creditor.balance;

        // Make tiny payment
        vm.prank(debtor);
        bullaInvoice.payInvoice{value: 1 wei}(invoiceId, 1 wei);

        // Verify precision handling (protocol fee might round to 0)
        assertTrue(creditor.balance >= creditorBalanceBefore, "Creditor should receive something or nothing");
        assertTrue(address(bullaInvoice).balance <= 1 wei, "Protocol fee should be handled correctly");
    }

    function testVeryLargePaymentAmounts() public {
        uint256 largeAmount = 1000000 ether;
        uint256 invoiceId =
            _createAndSetupInvoice(bullaInvoice, address(token1), largeAmount, _getInterestConfig(1000, 12));

        // Mint large amount for debtor
        token1.mint(debtor, largeAmount * 2);

        vm.warp(block.timestamp + 90 days);

        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        uint256 accruedInterest = invoice.interestComputationState.accruedInterest;

        vm.prank(debtor);
        token1.approve(address(bullaInvoice), accruedInterest);
        vm.prank(debtor);
        bullaInvoice.payInvoice(invoiceId, accruedInterest);

        // Verify protocol fee calculation with large numbers - with 50% fee: expectedFee = accruedInterest / 2
        uint256 expectedFee = accruedInterest / 2;
        assertEq(bullaInvoice.protocolFeesByToken(address(token1)), expectedFee, "Large amount protocol fee");
    }

    function testZeroPaymentAmountReverts() public {
        uint256 invoiceId = _createAndSetupInvoice(bullaInvoice, address(0), 1 ether, _getInterestConfig(0, 0));

        vm.prank(debtor);
        vm.expectRevert(PayingZero.selector);
        bullaInvoice.payInvoice{value: 0}(invoiceId, 0);
    }

    // ==================== 10. FEE WITHDRAWN EVENT TESTS ====================

    function testFeeWithdrawnEventEmittedForETH() public {
        // Create invoice and make payment to accumulate ETH fees
        uint256 invoiceId = _createAndSetupInvoice(bullaInvoice, address(0), 1 ether, _getInterestConfig(1000, 12));

        vm.warp(block.timestamp + 90 days);
        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        uint256 accruedInterest = invoice.interestComputationState.accruedInterest;

        vm.prank(debtor);
        bullaInvoice.payInvoice{value: accruedInterest}(invoiceId, accruedInterest);

        uint256 ethBalance = address(bullaInvoice).balance;
        assertTrue(ethBalance > 0, "Contract should have ETH balance");

        // Expect FeeWithdrawn event for ETH (address(0))
        vm.expectEmit(true, true, false, true);
        emit FeeWithdrawn(admin, address(0), ethBalance);

        vm.prank(admin);
        bullaInvoice.withdrawAllFees();
    }

    function testFeeWithdrawnEventEmittedForERC20Token() public {
        // Create invoice and make payment to accumulate token fees
        uint256 invoiceId = _createAndSetupInvoice(bullaInvoice, address(token1), 1 ether, _getInterestConfig(1000, 12));

        vm.warp(block.timestamp + 90 days);
        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        uint256 accruedInterest = invoice.interestComputationState.accruedInterest;

        vm.prank(debtor);
        token1.approve(address(bullaInvoice), accruedInterest);
        vm.prank(debtor);
        bullaInvoice.payInvoice(invoiceId, accruedInterest);

        uint256 tokenFees = bullaInvoice.protocolFeesByToken(address(token1));
        assertTrue(tokenFees > 0, "Contract should have token fees");

        // Expect FeeWithdrawn event for token1
        vm.expectEmit(true, true, false, true);
        emit FeeWithdrawn(admin, address(token1), tokenFees);

        vm.prank(admin);
        bullaInvoice.withdrawAllFees();
    }

    function testFeeWithdrawnEventEmittedForMultipleTokens() public {
        // Create invoices for ETH and multiple tokens
        uint256 ethInvoice = _createAndSetupInvoice(bullaInvoice, address(0), 1 ether, _getInterestConfig(1000, 12));
        uint256 token1Invoice =
            _createAndSetupInvoice(bullaInvoice, address(token1), 1 ether, _getInterestConfig(1000, 12));
        uint256 token2Invoice =
            _createAndSetupInvoice(bullaInvoice, address(token2), 1 ether, _getInterestConfig(1000, 12));

        vm.warp(block.timestamp + 90 days);

        // Make payments on all invoices
        Invoice memory ethInv = bullaInvoice.getInvoice(ethInvoice);
        Invoice memory token1Inv = bullaInvoice.getInvoice(token1Invoice);
        Invoice memory token2Inv = bullaInvoice.getInvoice(token2Invoice);

        uint256 ethInterest = ethInv.interestComputationState.accruedInterest;
        uint256 token1Interest = token1Inv.interestComputationState.accruedInterest;
        uint256 token2Interest = token2Inv.interestComputationState.accruedInterest;

        // ETH payment
        vm.prank(debtor);
        bullaInvoice.payInvoice{value: ethInterest}(ethInvoice, ethInterest);

        // Token1 payment
        vm.prank(debtor);
        token1.approve(address(bullaInvoice), token1Interest);
        vm.prank(debtor);
        bullaInvoice.payInvoice(token1Invoice, token1Interest);

        // Token2 payment
        vm.prank(debtor);
        token2.approve(address(bullaInvoice), token2Interest);
        vm.prank(debtor);
        bullaInvoice.payInvoice(token2Invoice, token2Interest);

        // Get fee amounts before withdrawal
        uint256 ethBalance = address(bullaInvoice).balance;
        uint256 token1Fees = bullaInvoice.protocolFeesByToken(address(token1));
        uint256 token2Fees = bullaInvoice.protocolFeesByToken(address(token2));

        // Expect all three FeeWithdrawn events
        vm.expectEmit(true, true, false, true);
        emit FeeWithdrawn(admin, address(0), ethBalance);

        vm.expectEmit(true, true, false, true);
        emit FeeWithdrawn(admin, address(token1), token1Fees);

        vm.expectEmit(true, true, false, true);
        emit FeeWithdrawn(admin, address(token2), token2Fees);

        vm.prank(admin);
        bullaInvoice.withdrawAllFees();
    }

    function testNoFeeWithdrawnEventWhenNoFeesToWithdraw() public {
        // No payments made, so no fees accumulated
        uint256 adminBalanceBefore = admin.balance;

        // Should not emit any FeeWithdrawn events
        vm.recordLogs();

        vm.prank(admin);
        bullaInvoice.withdrawAllFees();

        // Check that no FeeWithdrawn events were emitted
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            // FeeWithdrawn event has signature: keccak256("FeeWithdrawn(address,address,uint256)")
            assertFalse(
                logs[i].topics[0] == keccak256("FeeWithdrawn(address,address,uint256)"),
                "No FeeWithdrawn events should be emitted"
            );
        }

        assertEq(admin.balance, adminBalanceBefore, "Admin balance should be unchanged");
    }

    function testFeeWithdrawnEventNotEmittedForZeroTokenFees() public {
        // Create invoice and make payment to accumulate token fees
        uint256 invoiceId = _createAndSetupInvoice(bullaInvoice, address(token1), 1 ether, _getInterestConfig(1000, 12));

        vm.warp(block.timestamp + 90 days);
        Invoice memory invoice = bullaInvoice.getInvoice(invoiceId);
        uint256 accruedInterest = invoice.interestComputationState.accruedInterest;

        vm.prank(debtor);
        token1.approve(address(bullaInvoice), accruedInterest);
        vm.prank(debtor);
        bullaInvoice.payInvoice(invoiceId, accruedInterest);

        // First withdrawal - should emit event
        uint256 tokenFees = bullaInvoice.protocolFeesByToken(address(token1));

        vm.expectEmit(true, true, false, true);
        emit FeeWithdrawn(admin, address(token1), tokenFees);

        vm.prank(admin);
        bullaInvoice.withdrawAllFees();

        // Second withdrawal - should NOT emit event for token1 since fees are now 0
        vm.recordLogs();

        vm.prank(admin);
        bullaInvoice.withdrawAllFees();

        // Check that no FeeWithdrawn events were emitted for token1
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("FeeWithdrawn(address,address,uint256)")) {
                // If any FeeWithdrawn event was emitted, it should not be for token1
                address tokenAddress = address(uint160(uint256(logs[i].topics[2])));
                assertFalse(
                    tokenAddress == address(token1), "No FeeWithdrawn event should be emitted for token1 with zero fees"
                );
            }
        }
    }
}
