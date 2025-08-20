// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import "contracts/types/Types.sol";
import {WETH} from "contracts/mocks/weth.sol";
import {BullaClaimV2} from "contracts/BullaClaimV2.sol";
import {BullaFrendLendV2, LoanRequestParams, NotAdmin} from "src/BullaFrendLendV2.sol";
import {MockERC20} from "contracts/mocks/MockERC20.sol";
import {LoanRequestParamsBuilder} from "./LoanRequestParamsBuilder.t.sol";
import {InterestConfig} from "contracts/libraries/CompoundInterestLib.sol";
import {DeployContracts} from "script/DeployContracts.s.sol";
import {EIP712Helper} from "test/foundry/BullaClaim/EIP712/Utils.sol";

contract TestBullaFrendLendTokenWhitelist is Test {
    WETH public weth;
    MockERC20 public token1;
    MockERC20 public token2;
    MockERC20 public token3;
    BullaClaimV2 public bullaClaim;
    BullaFrendLendV2 public bullaFrendLend;
    EIP712Helper public sigHelper;

    uint256 constant CREDITOR_PK = 0x01;
    uint256 constant DEBTOR_PK = 0x02;
    uint256 constant ADMIN_PK = 0x03;
    uint256 constant NON_ADMIN_PK = 0x04;

    address creditor = vm.addr(CREDITOR_PK);
    address debtor = vm.addr(DEBTOR_PK);
    address admin = vm.addr(ADMIN_PK);
    address nonAdmin = vm.addr(NON_ADMIN_PK);

    uint256 constant LOAN_AMOUNT = 1000e18;
    uint256 constant PAYMENT_AMOUNT = 100e18;
    uint256 constant TERM_LENGTH = 365 days;
    uint256 constant FEE = 0.01 ether;
    uint16 constant PROTOCOL_FEE_BPS = 500; // 5%
    uint16 constant INTEREST_RATE_BPS = 1000; // 10%

    function setUp() public {
        weth = new WETH();
        token1 = new MockERC20("Token1", "TK1", 18);
        token2 = new MockERC20("Token2", "TK2", 18);
        token3 = new MockERC20("Token3", "TK3", 18);

        DeployContracts.DeploymentResult memory deploymentResult = (new DeployContracts()).deployForTest(
            address(this), // deployer
            LockState.Unlocked, // initialLockState
            FEE, // coreProtocolFee
            PROTOCOL_FEE_BPS, // invoiceProtocolFeeBPS
            PROTOCOL_FEE_BPS, // frendLendProtocolFeeBPS
            address(this) // admin
        );
        bullaClaim = BullaClaimV2(deploymentResult.bullaClaim);
        bullaFrendLend = new BullaFrendLendV2(address(bullaClaim), admin, PROTOCOL_FEE_BPS);
        sigHelper = new EIP712Helper(address(bullaClaim));

        vm.deal(creditor, 10 ether);
        vm.deal(debtor, 10 ether);

        // Setup token balances
        token1.mint(creditor, LOAN_AMOUNT * 10);
        token2.mint(creditor, LOAN_AMOUNT * 10);
        token3.mint(creditor, LOAN_AMOUNT * 10);

        token1.mint(debtor, LOAN_AMOUNT * 10);
        token2.mint(debtor, LOAN_AMOUNT * 10);
        token3.mint(debtor, LOAN_AMOUNT * 10);

        // Setup approvals
        vm.startPrank(creditor);
        token1.approve(address(bullaFrendLend), type(uint256).max);
        token2.approve(address(bullaFrendLend), type(uint256).max);
        token3.approve(address(bullaFrendLend), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(debtor);
        token1.approve(address(bullaFrendLend), type(uint256).max);
        token2.approve(address(bullaFrendLend), type(uint256).max);
        token3.approve(address(bullaFrendLend), type(uint256).max);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                          ACCESS CONTROL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_addToFeeTokenWhitelist_OnlyAdmin() public {
        vm.prank(nonAdmin);
        vm.expectRevert(NotAdmin.selector);
        bullaFrendLend.addToFeeTokenWhitelist(address(token1));
    }

    function test_removeFromFeeTokenWhitelist_OnlyAdmin() public {
        vm.prank(admin);
        bullaFrendLend.addToFeeTokenWhitelist(address(token1));

        vm.prank(nonAdmin);
        vm.expectRevert(NotAdmin.selector);
        bullaFrendLend.removeFromFeeTokenWhitelist(address(token1));
    }

    function test_addToFeeTokenWhitelist_AdminCanAdd() public {
        vm.prank(admin);
        vm.expectEmit(true, false, false, false);
        emit TokenAddedToFeesWhitelist(address(token1));
        bullaFrendLend.addToFeeTokenWhitelist(address(token1));

        assertTrue(bullaFrendLend.protocolFeeTokenWhitelist(address(token1)));
    }

    function test_removeFromFeeTokenWhitelist_AdminCanRemove() public {
        vm.prank(admin);
        bullaFrendLend.addToFeeTokenWhitelist(address(token1));

        vm.prank(admin);
        vm.expectEmit(true, false, false, false);
        emit TokenRemovedFromFeesWhitelist(address(token1));
        bullaFrendLend.removeFromFeeTokenWhitelist(address(token1));

        assertFalse(bullaFrendLend.protocolFeeTokenWhitelist(address(token1)));
    }

    /*//////////////////////////////////////////////////////////////
                    WHITELIST FUNCTIONALITY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_allTokens_AddedToProtocolFeeTokens() public {
        // Create and accept loan with interest to generate protocol fees (no whitelist needed for tracking)
        uint256 claimId = _createAndAcceptLoanWithInterest(address(token1));

        // Fast forward time to accrue interest
        vm.warp(block.timestamp + 180 days);

        // Pay the loan
        vm.prank(debtor);
        bullaFrendLend.payLoan(claimId, PAYMENT_AMOUNT);

        // Verify token was added to protocol fee tracking
        assertEq(bullaFrendLend.protocolFeeTokens(0), address(token1));

        // Verify protocol fees accumulated for this token
        assertGt(bullaFrendLend.protocolFeesByToken(address(token1)), 0);
    }

    function test_nonWhitelistedToken_CannotBeWithdrawn() public {
        // Create and pay loan to accumulate fees
        uint256 claimId = _createAndAcceptLoanWithInterest(address(token1));
        vm.warp(block.timestamp + 180 days);
        vm.prank(debtor);
        bullaFrendLend.payLoan(claimId, PAYMENT_AMOUNT);

        // Verify fees accumulated
        uint256 feesBefore = bullaFrendLend.protocolFeesByToken(address(token1));
        assertGt(feesBefore, 0);

        // Try to withdraw all fees (token1 is not whitelisted)
        vm.prank(admin);
        bullaFrendLend.withdrawAllFees();

        // Verify fees were NOT withdrawn (still there)
        assertEq(bullaFrendLend.protocolFeesByToken(address(token1)), feesBefore);
    }

    function test_whitelistedToken_CanBeWithdrawn() public {
        // Whitelist the token first
        vm.prank(admin);
        bullaFrendLend.addToFeeTokenWhitelist(address(token1));

        // Create and pay loan to accumulate fees
        uint256 claimId = _createAndAcceptLoanWithInterest(address(token1));
        vm.warp(block.timestamp + 180 days);
        vm.prank(debtor);
        bullaFrendLend.payLoan(claimId, PAYMENT_AMOUNT);

        // Verify fees accumulated
        uint256 feesBefore = bullaFrendLend.protocolFeesByToken(address(token1));
        assertGt(feesBefore, 0);

        // Withdraw all fees (token1 is whitelisted)
        vm.prank(admin);
        bullaFrendLend.withdrawAllFees();

        // Verify fees were withdrawn (reset to 0)
        assertEq(bullaFrendLend.protocolFeesByToken(address(token1)), 0);
    }

    /*//////////////////////////////////////////////////////////////
                          HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _createAndAcceptLoanWithInterest(address token) internal returns (uint256) {
        // Setup permissions for debtor (who will accept the loan)
        bullaClaim.approvalRegistry().permitCreateClaim({
            user: debtor,
            controller: address(bullaFrendLend),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: DEBTOR_PK,
                user: debtor,
                controller: address(bullaFrendLend),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: true
            })
        });

        InterestConfig memory interestConfig =
            InterestConfig({interestRateBps: INTEREST_RATE_BPS, numberOfPeriodsPerYear: 365});

        LoanRequestParams memory params = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withLoanAmount(LOAN_AMOUNT).withToken(token).withTermLength(TERM_LENGTH).withInterestConfig(interestConfig)
            .withDescription("Test loan with interest").build();

        // Offer loan
        vm.prank(creditor);
        uint256 offerId = bullaFrendLend.offerLoan(params);

        // Accept loan
        vm.prank(debtor);
        return bullaFrendLend.acceptLoan{value: FEE}(offerId);
    }

    /*//////////////////////////////////////////////////////////////
                             EVENTS
    //////////////////////////////////////////////////////////////*/

    event TokenAddedToFeesWhitelist(address indexed token);
    event TokenRemovedFromFeesWhitelist(address indexed token);
}
