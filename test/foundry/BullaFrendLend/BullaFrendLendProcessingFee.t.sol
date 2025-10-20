// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import {MockERC20} from "contracts/mocks/MockERC20.sol";
import {WETH} from "contracts/mocks/weth.sol";
import {
    Claim,
    Status,
    ClaimBinding,
    CreateClaimParams,
    LockState,
    ClaimMetadata,
    CreateClaimApprovalType
} from "contracts/types/Types.sol";
import {InterestConfig, InterestComputationState} from "contracts/libraries/CompoundInterestLib.sol";
import {
    LoanRequestParams,
    LoanOffer,
    LoanDetails,
    Loan,
    IncorrectFee,
    InvalidProtocolFee,
    BullaFrendLendV2
} from "contracts/BullaFrendLendV2.sol";
import {BullaClaimV2} from "contracts/BullaClaimV2.sol";
import {WhitelistPermissions} from "contracts/WhitelistPermissions.sol";
import {DeployContracts} from "script/DeployContracts.s.sol";
import {LoanRequestParamsBuilder} from "test/foundry/BullaFrendLend/LoanRequestParamsBuilder.t.sol";
import {EIP712Helper} from "test/foundry/BullaClaim/EIP712/Utils.sol";

/// @title BullaFrendLendProcessingFee Test Suite
/// @notice Tests for the processing fee functionality in BullaFrendLendV2
/// @dev Processing fee is taken upfront from loan amount on acceptance (independent of protocol fee on interest)
contract TestBullaFrendLendProcessingFee is Test {
    BullaClaimV2 public bullaClaim;
    BullaFrendLendV2 public bullaFrendLend;
    WhitelistPermissions public feeExemptions;
    MockERC20 public token;
    MockERC20 public token2;
    MockERC20 public usdc;
    WETH public weth;
    EIP712Helper public sigHelper;

    address private _owner = makeAddr("owner");
    address private _creditor = makeAddr("creditor");
    address private _debtor = makeAddr("debtor");
    address private _receiver = makeAddr("receiver");
    address private _admin = makeAddr("admin");

    uint256 private _creditorPK = 0x1;
    uint256 private _debtorPK = 0x2;
    uint256 private _receiverPK = 0x3;

    uint256 private constant _CORE_PROTOCOL_FEE = 0.01 ether;
    uint16 private constant _PROTOCOL_FEE_BPS = 1000; // 10% on interest
    uint16 private constant _PROCESSING_FEE_BPS = 500; // 5% on loan amount
    uint256 private constant _LOAN_AMOUNT = 1000e18;
    uint256 private constant _TERM_LENGTH = 90 days;

    event LoanOfferAccepted(
        uint256 indexed offerId,
        uint256 indexed claimId,
        address indexed receiver,
        uint256 fee,
        uint256 processingFee,
        ClaimMetadata metadata
    );
    event ProcessingFeeUpdated(uint16 oldFee, uint16 newFee);
    event FeeWithdrawn(address indexed admin, address indexed token, uint256 amount);
    event LoanPayment(uint256 indexed claimId, uint256 grossInterestPaid, uint256 principalPaid, uint256 protocolFee);

    function setUp() public {
        // Set up addresses from private keys
        _creditor = vm.addr(_creditorPK);
        _debtor = vm.addr(_debtorPK);
        _receiver = vm.addr(_receiverPK);

        // Deploy tokens
        token = new MockERC20("TestToken", "TT", 18);
        token2 = new MockERC20("Token2", "TK2", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new WETH();

        token.mint(_creditor, 1000000e18);
        token.mint(_debtor, 1000000e18);
        token2.mint(_creditor, 1000000e18);
        token2.mint(_debtor, 1000000e18);
        usdc.mint(_creditor, 1000000e6);
        usdc.mint(_debtor, 1000000e6);

        // Deploy fee exemptions contract
        feeExemptions = new WhitelistPermissions();

        // Deploy BullaClaim
        vm.prank(_owner);
        DeployContracts.DeploymentResult memory deploymentResult =
            (new DeployContracts()).deployForTest(_owner, LockState.Unlocked, _CORE_PROTOCOL_FEE, 0, 0, 0, _owner);
        bullaClaim = BullaClaimV2(deploymentResult.bullaClaim);

        // Set fee exemptions contract on BullaClaim
        vm.prank(_owner);
        bullaClaim.setFeeExemptions(address(feeExemptions));

        // Deploy BullaFrendLend with processing fee
        bullaFrendLend = new BullaFrendLendV2(address(bullaClaim), _admin, _PROTOCOL_FEE_BPS, _PROCESSING_FEE_BPS);

        sigHelper = new EIP712Helper(address(bullaClaim));

        // Setup balances
        vm.deal(_creditor, 100 ether);
        vm.deal(_debtor, 100 ether);
        vm.deal(_receiver, 100 ether);

        // Setup WETH
        vm.prank(_creditor);
        weth.deposit{value: 10 ether}();
        vm.prank(_debtor);
        weth.deposit{value: 10 ether}();

        // Setup permissions for loan creation
        _setupPermissions(_creditor, _creditorPK);
        _setupPermissions(_debtor, _debtorPK);
        _setupPermissions(_receiver, _receiverPK);
    }

    function _setupPermissions(address user, uint256 userPK) internal {
        bullaClaim.approvalRegistry().permitCreateClaim({
            user: user,
            controller: address(bullaFrendLend),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: type(uint64).max,
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: userPK,
                user: user,
                controller: address(bullaFrendLend),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: type(uint64).max,
                isBindingAllowed: true
            })
        });
    }

    function _createLoanOffer(address creditor, address debtor, uint256 loanAmount, address tokenAddr)
        internal
        returns (uint256)
    {
        LoanRequestParams memory loanParams = new LoanRequestParamsBuilder().withTermLength(_TERM_LENGTH)
            .withInterestRate(1200, 12).withLoanAmount(loanAmount).withCreditor(creditor).withDebtor(debtor).withToken(
            tokenAddr
        ).withImpairmentGracePeriod(30 days).build();

        vm.prank(creditor);
        return bullaFrendLend.offerLoan(loanParams);
    }

    /// @notice Test 1: Processing fee is correctly deducted from loan amount
    function testProcessingFeeDeductedFromLoanAmount() public {
        uint256 offerId = _createLoanOffer(_creditor, _debtor, _LOAN_AMOUNT, address(token));

        vm.prank(_creditor);
        token.approve(address(bullaFrendLend), _LOAN_AMOUNT);

        uint256 debtorBalanceBefore = token.balanceOf(_debtor);
        uint256 expectedProcessingFee = (_LOAN_AMOUNT * _PROCESSING_FEE_BPS) / 10000;
        uint256 expectedAmountToDebtor = _LOAN_AMOUNT - expectedProcessingFee;

        vm.prank(_debtor);
        bullaFrendLend.acceptLoan{value: _CORE_PROTOCOL_FEE}(offerId);

        uint256 debtorBalanceAfter = token.balanceOf(_debtor);

        assertEq(
            debtorBalanceAfter - debtorBalanceBefore,
            expectedAmountToDebtor,
            "Debtor should receive loan amount minus processing fee"
        );
    }

    /// @notice Test 2: Processing fee is tracked in mapping AND held in contract
    function testProcessingFeeTrackedAndHeldInContract() public {
        uint256 offerId = _createLoanOffer(_creditor, _debtor, _LOAN_AMOUNT, address(token));

        vm.prank(_creditor);
        token.approve(address(bullaFrendLend), _LOAN_AMOUNT);

        uint256 contractBalanceBefore = token.balanceOf(address(bullaFrendLend));
        uint256 expectedProcessingFee = (_LOAN_AMOUNT * _PROCESSING_FEE_BPS) / 10000;

        vm.prank(_debtor);
        bullaFrendLend.acceptLoan{value: _CORE_PROTOCOL_FEE}(offerId);

        // Check mapping
        assertEq(
            bullaFrendLend.protocolFeesByToken(address(token)),
            expectedProcessingFee,
            "Processing fee should be tracked in protocolFeesByToken"
        );

        // Check contract balance
        uint256 contractBalanceAfter = token.balanceOf(address(bullaFrendLend));
        assertEq(
            contractBalanceAfter - contractBalanceBefore,
            expectedProcessingFee,
            "Contract should hold the processing fee"
        );
    }

    /// @notice Test 3: Claim amount is NOT reduced by processing fee
    function testClaimAmountNotReducedByProcessingFee() public {
        uint256 offerId = _createLoanOffer(_creditor, _debtor, _LOAN_AMOUNT, address(token));

        vm.prank(_creditor);
        token.approve(address(bullaFrendLend), _LOAN_AMOUNT);

        vm.prank(_debtor);
        uint256 claimId = bullaFrendLend.acceptLoan{value: _CORE_PROTOCOL_FEE}(offerId);

        // Verify claim is for full loan amount (not reduced by processing fee)
        Claim memory claim = bullaClaim.getClaim(claimId);
        assertEq(
            claim.claimAmount, _LOAN_AMOUNT, "Claim amount should be full loan amount, not reduced by processing fee"
        );
    }

    /// @notice Test 4: LoanOfferAccepted event includes processing fee
    function testLoanOfferAcceptedEventIncludesProcessingFee() public {
        uint256 offerId = _createLoanOffer(_creditor, _debtor, _LOAN_AMOUNT, address(token));

        vm.prank(_creditor);
        token.approve(address(bullaFrendLend), _LOAN_AMOUNT);

        uint256 expectedProcessingFee = (_LOAN_AMOUNT * _PROCESSING_FEE_BPS) / 10000;

        vm.expectEmit(true, true, true, true);
        emit LoanOfferAccepted(offerId, 0, _debtor, _CORE_PROTOCOL_FEE, expectedProcessingFee, ClaimMetadata("", ""));

        vm.prank(_debtor);
        bullaFrendLend.acceptLoan{value: _CORE_PROTOCOL_FEE}(offerId);
    }

    /// @notice Test 6: Exemption status at acceptance time doesn't affect processing fee (it's always collected)
    function testExemptionStatusDoesNotAffectProcessingFee() public {
        // Start with debtor NOT exempt
        uint256 offerId = _createLoanOffer(_creditor, _debtor, _LOAN_AMOUNT, address(token));

        vm.prank(_creditor);
        token.approve(address(bullaFrendLend), _LOAN_AMOUNT);

        uint256 expectedProcessingFee = (_LOAN_AMOUNT * _PROCESSING_FEE_BPS) / 10000;

        // Accept loan - should pay processing fee
        vm.prank(_debtor);
        bullaFrendLend.acceptLoan{value: _CORE_PROTOCOL_FEE}(offerId);

        assertEq(
            bullaFrendLend.protocolFeesByToken(address(token)),
            expectedProcessingFee,
            "Processing fee collected when not exempt"
        );

        // Now add debtor to exemptions and create another loan
        feeExemptions.allow(_debtor);
        uint256 offerId2 = _createLoanOffer(_creditor, _debtor, _LOAN_AMOUNT, address(token));

        vm.prank(_creditor);
        token.approve(address(bullaFrendLend), _LOAN_AMOUNT);

        // Accept second loan - should STILL pay processing fee even though exempt
        vm.prank(_debtor);
        bullaFrendLend.acceptLoan{value: 0}(offerId2); // No core fee because exempt

        assertEq(
            bullaFrendLend.protocolFeesByToken(address(token)),
            expectedProcessingFee * 2,
            "Processing fee collected even when protocol-fee-exempt"
        );
    }

    /// @notice Test 7: Processing fees tracked separately for multiple tokens
    function testProcessingFeeWithMultipleTokens() public {
        // Create loans with different tokens
        uint256 tokenOfferId = _createLoanOffer(_creditor, _debtor, _LOAN_AMOUNT, address(token));
        uint256 token2OfferId = _createLoanOffer(_creditor, _debtor, _LOAN_AMOUNT, address(token2));
        uint256 usdcOfferId = _createLoanOffer(_creditor, _debtor, 1000e6, address(usdc));

        // Approve transfers
        vm.startPrank(_creditor);
        token.approve(address(bullaFrendLend), _LOAN_AMOUNT);
        token2.approve(address(bullaFrendLend), _LOAN_AMOUNT);
        usdc.approve(address(bullaFrendLend), 1000e6);
        vm.stopPrank();

        uint256 expectedTokenFee = (_LOAN_AMOUNT * _PROCESSING_FEE_BPS) / 10000;
        uint256 usdcAmount = 1000e6;
        uint256 expectedUsdcFee = (usdcAmount * _PROCESSING_FEE_BPS) / 10000;

        // Accept all loans
        vm.startPrank(_debtor);
        bullaFrendLend.acceptLoan{value: _CORE_PROTOCOL_FEE}(tokenOfferId);
        bullaFrendLend.acceptLoan{value: _CORE_PROTOCOL_FEE}(token2OfferId);
        bullaFrendLend.acceptLoan{value: _CORE_PROTOCOL_FEE}(usdcOfferId);
        vm.stopPrank();

        // Verify each token tracks its own fees
        assertEq(bullaFrendLend.protocolFeesByToken(address(token)), expectedTokenFee, "Token fee incorrect");
        assertEq(bullaFrendLend.protocolFeesByToken(address(token2)), expectedTokenFee, "Token2 fee incorrect");
        assertEq(bullaFrendLend.protocolFeesByToken(address(usdc)), expectedUsdcFee, "USDC fee incorrect");

        // Test accumulation: accept another loan with token
        uint256 tokenOfferId2 = _createLoanOffer(_creditor, _debtor, _LOAN_AMOUNT, address(token));
        vm.prank(_creditor);
        token.approve(address(bullaFrendLend), _LOAN_AMOUNT);
        vm.prank(_debtor);
        bullaFrendLend.acceptLoan{value: _CORE_PROTOCOL_FEE}(tokenOfferId2);

        assertEq(
            bullaFrendLend.protocolFeesByToken(address(token)), expectedTokenFee * 2, "Token fees should accumulate"
        );
    }

    /// @notice Test 8: Admin can withdraw processing fees
    function testAdminCanWithdrawProcessingFees() public {
        // Collect some processing fees
        uint256 offerId = _createLoanOffer(_creditor, _debtor, _LOAN_AMOUNT, address(token));
        vm.prank(_creditor);
        token.approve(address(bullaFrendLend), _LOAN_AMOUNT);
        vm.prank(_debtor);
        bullaFrendLend.acceptLoan{value: _CORE_PROTOCOL_FEE}(offerId);

        uint256 expectedProcessingFee = (_LOAN_AMOUNT * _PROCESSING_FEE_BPS) / 10000;
        uint256 adminBalanceBefore = token.balanceOf(_admin);

        // Whitelist token for withdrawal
        vm.prank(_admin);
        bullaFrendLend.addToFeeTokenWhitelist(address(token));

        // Admin withdraws fees
        vm.prank(_admin);
        bullaFrendLend.withdrawAllFees();

        uint256 adminBalanceAfter = token.balanceOf(_admin);

        assertEq(adminBalanceAfter - adminBalanceBefore, expectedProcessingFee, "Admin should receive processing fees");
        assertEq(bullaFrendLend.protocolFeesByToken(address(token)), 0, "Fee mapping should be reset to 0");
    }

    /// @notice Test 9: Withdraw processing fees for multiple tokens
    function testWithdrawProcessingFeesMultipleTokens() public {
        // Collect processing fees in multiple tokens
        uint256 tokenOfferId = _createLoanOffer(_creditor, _debtor, _LOAN_AMOUNT, address(token));
        uint256 token2OfferId = _createLoanOffer(_creditor, _debtor, _LOAN_AMOUNT, address(token2));

        vm.startPrank(_creditor);
        token.approve(address(bullaFrendLend), _LOAN_AMOUNT);
        token2.approve(address(bullaFrendLend), _LOAN_AMOUNT);
        vm.stopPrank();

        vm.startPrank(_debtor);
        bullaFrendLend.acceptLoan{value: _CORE_PROTOCOL_FEE}(tokenOfferId);
        bullaFrendLend.acceptLoan{value: _CORE_PROTOCOL_FEE}(token2OfferId);
        vm.stopPrank();

        uint256 expectedFeePerToken = (_LOAN_AMOUNT * _PROCESSING_FEE_BPS) / 10000;

        // Whitelist tokens
        vm.startPrank(_admin);
        bullaFrendLend.addToFeeTokenWhitelist(address(token));
        bullaFrendLend.addToFeeTokenWhitelist(address(token2));

        uint256 adminTokenBalanceBefore = token.balanceOf(_admin);
        uint256 adminToken2BalanceBefore = token2.balanceOf(_admin);

        // Withdraw all fees
        bullaFrendLend.withdrawAllFees();
        vm.stopPrank();

        assertEq(token.balanceOf(_admin) - adminTokenBalanceBefore, expectedFeePerToken, "Token fees withdrawn");
        assertEq(token2.balanceOf(_admin) - adminToken2BalanceBefore, expectedFeePerToken, "Token2 fees withdrawn");
        assertEq(bullaFrendLend.protocolFeesByToken(address(token)), 0, "Token fee mapping reset");
        assertEq(bullaFrendLend.protocolFeesByToken(address(token2)), 0, "Token2 fee mapping reset");
    }

    /// @notice Test 10: Admin can update processing fee
    function testSetProcessingFeeAsAdmin() public {
        uint16 newFee = 1000; // 10%

        vm.expectEmit(true, true, true, true);
        emit ProcessingFeeUpdated(_PROCESSING_FEE_BPS, newFee);

        vm.prank(_admin);
        bullaFrendLend.setProcessingFee(newFee);

        assertEq(bullaFrendLend.processingFeeBPS(), newFee, "Processing fee should be updated");

        // Verify non-admin cannot set fee
        vm.prank(_debtor);
        vm.expectRevert();
        bullaFrendLend.setProcessingFee(2000);
    }

    /// @notice Test 11: Cannot set invalid processing fee
    function testSetProcessingFeeInvalidAmount() public {
        vm.prank(_admin);
        vm.expectRevert(InvalidProtocolFee.selector);
        bullaFrendLend.setProcessingFee(10001); // > 100%
    }

    /// @notice Test 12: Processing fee update affects new loans only
    function testProcessingFeeUpdateAffectsNewLoansOnly() public {
        // Accept loan with original fee (500 BPS = 5%)
        uint256 offerId1 = _createLoanOffer(_creditor, _debtor, _LOAN_AMOUNT, address(token));
        vm.prank(_creditor);
        token.approve(address(bullaFrendLend), _LOAN_AMOUNT);
        vm.prank(_debtor);
        bullaFrendLend.acceptLoan{value: _CORE_PROTOCOL_FEE}(offerId1);

        uint256 firstFee = (_LOAN_AMOUNT * _PROCESSING_FEE_BPS) / 10000;
        assertEq(bullaFrendLend.protocolFeesByToken(address(token)), firstFee, "First fee collected");

        // Update fee to 10%
        vm.prank(_admin);
        bullaFrendLend.setProcessingFee(1000);

        // Accept second loan with new fee
        uint256 offerId2 = _createLoanOffer(_creditor, _debtor, _LOAN_AMOUNT, address(token));
        vm.prank(_creditor);
        token.approve(address(bullaFrendLend), _LOAN_AMOUNT);
        vm.prank(_debtor);
        bullaFrendLend.acceptLoan{value: _CORE_PROTOCOL_FEE}(offerId2);

        uint256 secondFee = (_LOAN_AMOUNT * 1000) / 10000;
        uint256 totalFees = firstFee + secondFee;
        assertEq(bullaFrendLend.protocolFeesByToken(address(token)), totalFees, "Both fees accumulated correctly");
    }

    /// @notice Test 13: Zero processing fee means no fee deducted
    function testZeroProcessingFee() public {
        // Deploy new contract with 0% processing fee
        BullaFrendLendV2 zeroFeeLend = new BullaFrendLendV2(address(bullaClaim), _admin, _PROTOCOL_FEE_BPS, 0);

        // Setup permissions for new contract
        bullaClaim.approvalRegistry().permitCreateClaim({
            user: _debtor,
            controller: address(zeroFeeLend),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: type(uint64).max,
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: _debtorPK,
                user: _debtor,
                controller: address(zeroFeeLend),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: type(uint64).max,
                isBindingAllowed: true
            })
        });

        LoanRequestParams memory loanParams = new LoanRequestParamsBuilder().withTermLength(_TERM_LENGTH)
            .withInterestRate(1200, 12).withLoanAmount(_LOAN_AMOUNT).withCreditor(_creditor).withDebtor(_debtor).withToken(
            address(token)
        ).withImpairmentGracePeriod(30 days).build();

        vm.prank(_creditor);
        uint256 offerId = zeroFeeLend.offerLoan(loanParams);

        vm.prank(_creditor);
        token.approve(address(zeroFeeLend), _LOAN_AMOUNT);

        uint256 debtorBalanceBefore = token.balanceOf(_debtor);

        vm.prank(_debtor);
        zeroFeeLend.acceptLoan{value: _CORE_PROTOCOL_FEE}(offerId);

        uint256 debtorBalanceAfter = token.balanceOf(_debtor);

        // Debtor should receive full loan amount
        assertEq(
            debtorBalanceAfter - debtorBalanceBefore, _LOAN_AMOUNT, "Debtor should receive full amount with 0% fee"
        );
        assertEq(zeroFeeLend.protocolFeesByToken(address(token)), 0, "No processing fee should be tracked");
    }

    /// @notice Test 14: Small loan amounts and rounding
    function testSmallLoanAmountProcessingFee() public {
        uint256 smallAmount = 100; // Very small amount

        uint256 offerId = _createLoanOffer(_creditor, _debtor, smallAmount, address(token));
        vm.prank(_creditor);
        token.approve(address(bullaFrendLend), smallAmount);

        uint256 expectedFee = (smallAmount * _PROCESSING_FEE_BPS) / 10000;
        uint256 expectedAmount = smallAmount - expectedFee;

        uint256 debtorBalanceBefore = token.balanceOf(_debtor);

        vm.prank(_debtor);
        bullaFrendLend.acceptLoan{value: _CORE_PROTOCOL_FEE}(offerId);

        uint256 debtorBalanceAfter = token.balanceOf(_debtor);

        assertEq(debtorBalanceAfter - debtorBalanceBefore, expectedAmount, "Small amount fee calculated correctly");
        assertEq(bullaFrendLend.protocolFeesByToken(address(token)), expectedFee, "Small fee tracked correctly");
    }

    /// @notice Test 15: Processing fee and protocol fee are independent
    function testProcessingFeeAndProtocolFeeIndependent() public {
        // Accept loan - pays processing fee on principal
        uint256 offerId = _createLoanOffer(_creditor, _debtor, _LOAN_AMOUNT, address(token));
        vm.prank(_creditor);
        token.approve(address(bullaFrendLend), _LOAN_AMOUNT);

        vm.prank(_debtor);
        uint256 claimId = bullaFrendLend.acceptLoan{value: _CORE_PROTOCOL_FEE}(offerId);

        uint256 expectedProcessingFee = (_LOAN_AMOUNT * _PROCESSING_FEE_BPS) / 10000;
        assertEq(
            bullaFrendLend.protocolFeesByToken(address(token)),
            expectedProcessingFee,
            "Processing fee collected on acceptance"
        );

        // Wait and make interest payment - pays protocol fee on interest
        vm.warp(block.timestamp + 30 days);

        (uint256 principal, uint256 interest) = bullaFrendLend.getTotalAmountDue(claimId);

        uint256 paymentAmount = principal + interest;

        vm.prank(_debtor);
        token.approve(address(bullaFrendLend), paymentAmount);

        uint256 expectedProtocolFeeOnInterest = (interest * _PROTOCOL_FEE_BPS) / 10000;

        vm.prank(_debtor);
        bullaFrendLend.payLoan(claimId, paymentAmount);

        // Total fees = processing fee + protocol fee on interest
        uint256 expectedTotalFees = expectedProcessingFee + expectedProtocolFeeOnInterest;
        assertEq(
            bullaFrendLend.protocolFeesByToken(address(token)),
            expectedTotalFees,
            "Both processing and protocol fees tracked independently"
        );
    }

    /// @notice Test 16: Custom receiver gets reduced amount
    function testProcessingFeeWithCustomReceiver() public {
        uint256 offerId = _createLoanOffer(_creditor, _debtor, _LOAN_AMOUNT, address(token));

        vm.prank(_creditor);
        token.approve(address(bullaFrendLend), _LOAN_AMOUNT);

        uint256 expectedProcessingFee = (_LOAN_AMOUNT * _PROCESSING_FEE_BPS) / 10000;
        uint256 expectedAmountToReceiver = _LOAN_AMOUNT - expectedProcessingFee;

        uint256 receiverBalanceBefore = token.balanceOf(_receiver);

        vm.prank(_debtor);
        bullaFrendLend.acceptLoanWithReceiver{value: _CORE_PROTOCOL_FEE}(offerId, _receiver);

        uint256 receiverBalanceAfter = token.balanceOf(_receiver);

        assertEq(
            receiverBalanceAfter - receiverBalanceBefore,
            expectedAmountToReceiver,
            "Custom receiver should get loan amount minus processing fee"
        );
        assertEq(bullaFrendLend.protocolFeesByToken(address(token)), expectedProcessingFee, "Processing fee tracked");
    }

    /// @notice Test 17: View function returns correct value
    function testProcessingFeeBPSReturnsCorrectValue() public {
        assertEq(bullaFrendLend.processingFeeBPS(), _PROCESSING_FEE_BPS, "View function should return correct fee");

        // Update fee and check again
        uint16 newFee = 750;
        vm.prank(_admin);
        bullaFrendLend.setProcessingFee(newFee);

        assertEq(bullaFrendLend.processingFeeBPS(), newFee, "View function should return updated fee");
    }
}
