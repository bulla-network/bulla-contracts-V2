// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import "contracts/types/Types.sol";
import {WETH} from "contracts/mocks/weth.sol";
import {BullaClaimV2} from "contracts/BullaClaimV2.sol";
import {CreateInvoiceParamsBuilder} from "./CreateInvoiceParamsBuilder.sol";
import {BullaInvoice, CreateInvoiceParams, NotAdmin} from "src/BullaInvoice.sol";
import {MockERC20} from "contracts/mocks/MockERC20.sol";
import {InterestConfig} from "contracts/libraries/CompoundInterestLib.sol";
import {DeployContracts} from "script/DeployContracts.s.sol";
import {EIP712Helper} from "test/foundry/BullaClaim/EIP712/Utils.sol";

contract TestBullaInvoiceTokenWhitelist is Test {
    WETH public weth;
    MockERC20 public token1;
    MockERC20 public token2;
    MockERC20 public token3;
    BullaClaimV2 public bullaClaim;
    BullaInvoice public bullaInvoice;
    EIP712Helper public sigHelper;

    uint256 constant CREDITOR_PK = 0x01;
    uint256 constant DEBTOR_PK = 0x02;
    uint256 constant ADMIN_PK = 0x03;
    uint256 constant NON_ADMIN_PK = 0x04;

    address creditor = vm.addr(CREDITOR_PK);
    address debtor = vm.addr(DEBTOR_PK);
    address admin = vm.addr(ADMIN_PK);
    address nonAdmin = vm.addr(NON_ADMIN_PK);

    uint256 constant CLAIM_AMOUNT = 1000e18;
    uint256 constant PAYMENT_AMOUNT = 100e18;
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
        bullaInvoice = new BullaInvoice(address(bullaClaim), admin, PROTOCOL_FEE_BPS);
        sigHelper = new EIP712Helper(address(bullaClaim));

        vm.deal(creditor, 10 ether);
        vm.deal(debtor, 10 ether);

        // Setup token balances
        token1.mint(debtor, CLAIM_AMOUNT * 10);
        token2.mint(debtor, CLAIM_AMOUNT * 10);
        token3.mint(debtor, CLAIM_AMOUNT * 10);

        // Setup approvals
        vm.startPrank(debtor);
        token1.approve(address(bullaInvoice), type(uint256).max);
        token2.approve(address(bullaInvoice), type(uint256).max);
        token3.approve(address(bullaInvoice), type(uint256).max);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                          ACCESS CONTROL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_addToFeeTokenWhitelist_OnlyAdmin() public {
        vm.prank(nonAdmin);
        vm.expectRevert(NotAdmin.selector);
        bullaInvoice.addToFeeTokenWhitelist(address(token1));
    }

    function test_removeFromFeeTokenWhitelist_OnlyAdmin() public {
        vm.prank(admin);
        bullaInvoice.addToFeeTokenWhitelist(address(token1));

        vm.prank(nonAdmin);
        vm.expectRevert(NotAdmin.selector);
        bullaInvoice.removeFromFeeTokenWhitelist(address(token1));
    }

    function test_addToFeeTokenWhitelist_AdminCanAdd() public {
        vm.prank(admin);
        vm.expectEmit(true, false, false, false);
        emit TokenAddedToFeesWhitelist(address(token1));
        bullaInvoice.addToFeeTokenWhitelist(address(token1));

        assertTrue(bullaInvoice.protocolFeeTokenWhitelist(address(token1)));
    }

    function test_removeFromFeeTokenWhitelist_AdminCanRemove() public {
        vm.prank(admin);
        bullaInvoice.addToFeeTokenWhitelist(address(token1));

        vm.prank(admin);
        vm.expectEmit(true, false, false, false);
        emit TokenRemovedFromFeesWhitelist(address(token1));
        bullaInvoice.removeFromFeeTokenWhitelist(address(token1));

        assertFalse(bullaInvoice.protocolFeeTokenWhitelist(address(token1)));
    }

    /*//////////////////////////////////////////////////////////////
                    WHITELIST FUNCTIONALITY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_allTokens_AddedToProtocolFeeTokens() public {
        // Create invoice and pay with interest to generate protocol fees (no whitelist needed for tracking)
        uint256 invoiceId = _createInvoiceWithInterest(address(token1));

        // Fast forward time to accrue interest
        vm.warp(block.timestamp + 365 days);

        // Pay the invoice
        vm.prank(debtor);
        bullaInvoice.payInvoice(invoiceId, PAYMENT_AMOUNT);

        // Verify token was added to protocol fee tracking
        assertEq(bullaInvoice.protocolFeeTokens(0), address(token1));

        // Verify protocol fees accumulated for this token
        assertGt(bullaInvoice.protocolFeesByToken(address(token1)), 0);
    }

    function test_nonWhitelistedToken_CannotBeWithdrawn() public {
        // Create and pay invoice to accumulate fees
        uint256 invoiceId = _createInvoiceWithInterest(address(token1));
        vm.warp(block.timestamp + 365 days);
        vm.prank(debtor);
        bullaInvoice.payInvoice(invoiceId, PAYMENT_AMOUNT);

        // Verify fees accumulated
        uint256 feesBefore = bullaInvoice.protocolFeesByToken(address(token1));
        assertGt(feesBefore, 0);

        // Try to withdraw all fees (token1 is not whitelisted)
        vm.prank(admin);
        bullaInvoice.withdrawAllFees();

        // Verify fees were NOT withdrawn (still there)
        assertEq(bullaInvoice.protocolFeesByToken(address(token1)), feesBefore);
    }

    function test_whitelistedToken_CanBeWithdrawn() public {
        // Whitelist the token first
        vm.prank(admin);
        bullaInvoice.addToFeeTokenWhitelist(address(token1));

        // Create and pay invoice to accumulate fees
        uint256 invoiceId = _createInvoiceWithInterest(address(token1));
        vm.warp(block.timestamp + 365 days);
        vm.prank(debtor);
        bullaInvoice.payInvoice(invoiceId, PAYMENT_AMOUNT);

        // Verify fees accumulated
        uint256 feesBefore = bullaInvoice.protocolFeesByToken(address(token1));
        assertGt(feesBefore, 0);

        // Withdraw all fees (token1 is whitelisted)
        vm.prank(admin);
        bullaInvoice.withdrawAllFees();

        // Verify fees were withdrawn (reset to 0)
        assertEq(bullaInvoice.protocolFeesByToken(address(token1)), 0);
    }

    /*//////////////////////////////////////////////////////////////
                          HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _createInvoiceWithInterest(address token) internal returns (uint256) {
        // Setup permissions for creditor
        bullaClaim.approvalRegistry().permitCreateClaim({
            user: creditor,
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: 1,
            isBindingAllowed: false,
            signature: sigHelper.signCreateClaimPermit({
                pk: CREDITOR_PK,
                user: creditor,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: 1,
                isBindingAllowed: false
            })
        });

        InterestConfig memory interestConfig =
            InterestConfig({interestRateBps: INTEREST_RATE_BPS, numberOfPeriodsPerYear: 365});

        CreateInvoiceParams memory params = new CreateInvoiceParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withClaimAmount(CLAIM_AMOUNT).withToken(token).withDueBy(block.timestamp + 30 days).withLateFeeConfig(
            interestConfig
        ).withDescription("Test invoice with interest").build();

        vm.prank(creditor);
        return bullaInvoice.createInvoice{value: FEE}(params);
    }

    /*//////////////////////////////////////////////////////////////
                             EVENTS
    //////////////////////////////////////////////////////////////*/

    event TokenAddedToFeesWhitelist(address indexed token);
    event TokenRemovedFromFeesWhitelist(address indexed token);
}
