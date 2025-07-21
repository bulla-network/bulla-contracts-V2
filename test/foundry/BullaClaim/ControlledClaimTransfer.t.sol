// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.15;

import {BullaClaimTestHelper} from "./BullaClaimTestHelper.sol";
import {BullaClaim} from "contracts/BullaClaim.sol";
import {Claim, Status, ClaimBinding, LockState, CreateClaimParams} from "contracts/types/Types.sol";
import {DeployContracts} from "script/DeployContracts.s.sol";
import {CreateClaimParamsBuilder} from "test/foundry/BullaClaim/CreateClaimParamsBuilder.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IBullaClaim} from "contracts/interfaces/IBullaClaim.sol";
import {WETH} from "contracts/mocks/weth.sol";
import {EIP712Helper} from "test/foundry/BullaClaim/EIP712/Utils.sol";
import {BullaClaimControllerBase} from "contracts/BullaClaimControllerBase.sol";
import {BullaInvoice} from "contracts/BullaInvoice.sol";
import {BullaFrendLend} from "contracts/BullaFrendLend.sol";
import {CreateInvoiceParams, InterestConfig, PurchaseOrderState} from "contracts/interfaces/IBullaInvoice.sol";
import {LoanRequestParams} from "contracts/interfaces/IBullaFrendLend.sol";
import {Vm} from "forge-std/Vm.sol";
import {CreateClaimApprovalType} from "contracts/types/Types.sol";
import {CreateInvoiceParamsBuilder} from "test/foundry/BullaInvoice/CreateInvoiceParamsBuilder.sol";
import {LoanRequestParamsBuilder} from "test/foundry/BullaFrendLend/LoanRequestParamsBuilder.t.sol";
import {MockERC20} from "contracts/mocks/MockERC20.sol";

contract MockController is BullaClaimControllerBase {
    string public name = "Creative Mock Controller";

    constructor(address _bullaClaim) BullaClaimControllerBase(_bullaClaim) {}

    function createClaim(CreateClaimParams memory params) external returns (uint256) {
        return _bullaClaim.createClaimFrom(msg.sender, params);
    }

    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        return super._supportsERC721Interface(interfaceId);
    }
}

// Abstract controller interface for polymorphic testing
abstract contract IControllerAdapter {
    function createControlledClaim(Vm vm, address creditor, address debtor) external virtual returns (uint256);
    function getController() external view virtual returns (address);
    function getClaimCreatorPk(uint256 creditorPk, uint256 debtorPk) external view virtual returns (uint256);
}

// MockController adapter
contract MockAdapter is IControllerAdapter {
    MockController public controller;

    constructor(address _controller) {
        controller = MockController(_controller);
    }

    function createControlledClaim(Vm vm, address creditor, address debtor) external override returns (uint256) {
        CreateClaimParams memory createClaimParams = new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(
            debtor
        ).withDescription("Mock Controlled Claim").withBinding(ClaimBinding.Unbound).withClaimAmount(1 ether).build();

        vm.prank(creditor);
        return controller.createClaim(createClaimParams);
    }

    function getController() external view override returns (address) {
        return address(controller);
    }

    function getClaimCreatorPk(uint256 creditorPk, uint256) external pure override returns (uint256) {
        return creditorPk;
    }
}

// Invoice adapter
contract InvoiceAdapter is IControllerAdapter {
    BullaInvoice public invoice;

    constructor(address _invoice) {
        invoice = BullaInvoice(_invoice);
    }

    function createControlledClaim(Vm vm, address creditor, address debtor) external override returns (uint256) {
        CreateInvoiceParams memory createInvoiceParams = new CreateInvoiceParamsBuilder().withCreditor(creditor)
            .withDebtor(debtor).withClaimAmount(1 ether).withDescription("Invoice Controlled Claim").withBinding(
            ClaimBinding.Unbound
        ).withDueBy(uint40(block.timestamp + 30 days)).build();

        vm.prank(creditor);
        return invoice.createInvoice(createInvoiceParams);
    }

    function getController() external view override returns (address) {
        return address(invoice);
    }

    function getClaimCreatorPk(uint256 creditorPk, uint256) external pure override returns (uint256) {
        return creditorPk;
    }
}

// FrendLend adapter
contract FrendLendAdapter is IControllerAdapter {
    BullaFrendLend public frendLend;
    MockERC20 public claimToken;

    constructor(address _frendLend) {
        frendLend = BullaFrendLend(_frendLend);
        claimToken = new MockERC20("Claim Token", "CTK", 18);
    }

    function createControlledClaim(Vm vm, address creditor, address debtor) external override returns (uint256) {
        vm.startPrank(creditor);
        claimToken.mint(creditor, 1 ether);
        claimToken.approve(address(frendLend), 1 ether);
        vm.stopPrank();

        LoanRequestParams memory loanRequestParams = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(
            debtor
        ).withToken(address(claimToken)).withLoanAmount(1 ether).withInterestRateBps(1000).withNumberOfPeriodsPerYear(
            12
        ).build();

        vm.prank(creditor);
        uint256 loanOfferId = frendLend.offerLoan(loanRequestParams);

        vm.prank(debtor);
        return frendLend.acceptLoan(loanOfferId);
    }

    function getController() external view override returns (address) {
        return address(frendLend);
    }

    function getClaimCreatorPk(uint256, uint256 debtorPk) external pure override returns (uint256) {
        return debtorPk;
    }
}

contract ControlledClaimTransferTest is BullaClaimTestHelper {
    uint256 constant CREDITOR_PK = uint256(0x01);
    uint256 constant DEBTOR_PK = uint256(0x02);

    address creditor = vm.addr(CREDITOR_PK);
    address debtor = vm.addr(DEBTOR_PK);
    address newOwner = address(0x04);

    // Three controllers
    MockController mockController;
    BullaInvoice invoice;
    BullaFrendLend frendLend;

    function setUp() public {
        weth = new WETH();
        DeployContracts.DeploymentResult memory deploymentResult =
            (new DeployContracts()).deployForTest(address(this), LockState.Unlocked, 0, 0, 0, address(this));
        bullaClaim = BullaClaim(deploymentResult.bullaClaim);
        approvalRegistry = bullaClaim.approvalRegistry();
        sigHelper = new EIP712Helper(address(bullaClaim));

        // Deploy controllers
        mockController = new MockController(address(bullaClaim));
        invoice = new BullaInvoice(address(bullaClaim), address(this), 250);
        frendLend = new BullaFrendLend(address(bullaClaim), address(this), 100);

        vm.deal(creditor, 10 ether);
        vm.deal(debtor, 10 ether);
    }

    function _createControlledClaim(IControllerAdapter adapter) internal returns (uint256) {
        // All controller types need permission
        _permitCreateClaim(adapter.getClaimCreatorPk(CREDITOR_PK, DEBTOR_PK), adapter.getController(), 1);

        return adapter.createControlledClaim(vm, creditor, debtor);
    }

    function _createUncontrolledClaim() internal returns (uint256 claimId) {
        // Create a regular claim (not through a controller) using the helper
        claimId = _newClaim(creditor, creditor, debtor);

        // Verify the claim is not controlled
        Claim memory claim = bullaClaim.getClaim(claimId);
        assertEq(claim.controller, address(0), "Claim should not be controlled");
        assertEq(bullaClaim.ownerOf(claimId), creditor, "Creditor should own the claim NFT");
    }

    // ================== CORE TEST FUNCTIONS (ADAPTER-BASED) ==================

    function _testControlledClaimTransferRequiresController(IControllerAdapter adapter) internal {
        uint256 claimId = _createControlledClaim(adapter);

        // Direct ERC721 transfers should fail for controlled claims
        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(IBullaClaim.NotController.selector, creditor));
        bullaClaim.transferFrom(creditor, newOwner, claimId);
    }

    function _testControlledClaimApprovalRequiresController(IControllerAdapter adapter) internal {
        uint256 claimId = _createControlledClaim(adapter);

        // Direct ERC721 approvals should fail for controlled claims
        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(IBullaClaim.NotController.selector, creditor));
        bullaClaim.approve(newOwner, claimId);
    }

    function _testControlledClaimSafeTransferRequiresController(IControllerAdapter adapter) internal {
        uint256 claimId = _createControlledClaim(adapter);

        // Direct ERC721 safe transfers should fail for controlled claims
        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(IBullaClaim.NotController.selector, creditor));
        bullaClaim.safeTransferFrom(creditor, newOwner, claimId);
    }

    function _testControllerCanTransferControlledClaim(IControllerAdapter adapter) internal {
        uint256 claimId = _createControlledClaim(adapter);
        BullaClaimControllerBase controller = BullaClaimControllerBase(adapter.getController());

        // Controller should be able to transfer the claim
        vm.prank(creditor);
        controller.transferFrom(creditor, newOwner, claimId);

        assertEq(bullaClaim.ownerOf(claimId), newOwner, "Controller should be able to transfer claim");

        // The claim should still be controlled by the same controller
        Claim memory claim = bullaClaim.getClaim(claimId);
        assertEq(claim.controller, adapter.getController(), "Controller should remain the same");
    }

    function _testControllerCanApproveControlledClaim(IControllerAdapter adapter) internal {
        uint256 claimId = _createControlledClaim(adapter);
        BullaClaimControllerBase controller = BullaClaimControllerBase(adapter.getController());

        // Controller should be able to approve the claim
        vm.prank(creditor);
        controller.approve(newOwner, claimId);

        assertEq(bullaClaim.getApproved(claimId), newOwner, "Controller should be able to approve claim");
    }

    function _testControllerCanSafeTransferControlledClaim(IControllerAdapter adapter) internal {
        uint256 claimId = _createControlledClaim(adapter);
        BullaClaimControllerBase controller = BullaClaimControllerBase(adapter.getController());

        // Controller should be able to safe transfer the claim
        vm.prank(creditor);
        controller.safeTransferFrom(creditor, newOwner, claimId);

        assertEq(bullaClaim.ownerOf(claimId), newOwner, "Controller should be able to safe transfer claim");
    }

    function _testControlledClaimSetApprovalForAllRequiresController(IControllerAdapter adapter) internal {
        _createControlledClaim(adapter); // Create a controlled claim to establish context

        // Direct ERC721 setApprovalForAll should fail - it's not supported
        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(IBullaClaim.NotSupported.selector));
        bullaClaim.setApprovalForAll(newOwner, true);
    }

    function _testControlledClaimERC721Errors(IControllerAdapter adapter) internal {
        uint256 claimId = _createControlledClaim(adapter);
        BullaClaimControllerBase controller = BullaClaimControllerBase(adapter.getController());

        // Cannot transfer if not owner or approved
        vm.prank(newOwner);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, newOwner, claimId));
        controller.transferFrom(creditor, newOwner, claimId);

        // Cannot approve if not owner
        vm.prank(newOwner);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidApprover.selector, newOwner));
        controller.approve(debtor, claimId);

        // Cannot transfer to zero address
        vm.prank(creditor);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(0)));
        controller.transferFrom(creditor, address(0), claimId);
    }

    function _testControlledClaimOperationsRequireController(IControllerAdapter adapter) internal {
        uint256 claimId = _createControlledClaim(adapter);
        BullaClaimControllerBase controller = BullaClaimControllerBase(adapter.getController());

        // Transfer the claim via controller first
        vm.prank(creditor);
        controller.transferFrom(creditor, newOwner, claimId);

        // Give the debtor some ETH to pay the claim
        vm.deal(debtor, 1 ether);

        // Try to pay the claim directly (should fail)
        vm.prank(debtor);
        vm.expectRevert(abi.encodeWithSelector(IBullaClaim.NotController.selector, debtor));
        bullaClaim.payClaim{value: 0.5 ether}(claimId, 0.5 ether);

        // Try to update binding directly (should fail)
        vm.prank(debtor);
        vm.expectRevert(abi.encodeWithSelector(IBullaClaim.NotController.selector, debtor));
        bullaClaim.updateBinding(claimId, ClaimBinding.Bound);

        // Try to cancel directly (should fail)
        vm.prank(newOwner); // Now the creditor is newOwner
        vm.expectRevert(abi.encodeWithSelector(IBullaClaim.NotController.selector, newOwner));
        bullaClaim.cancelClaim(claimId, "Not allowed");

        // Try to impair directly (should fail)
        vm.prank(newOwner);
        vm.expectRevert(abi.encodeWithSelector(IBullaClaim.NotController.selector, newOwner));
        bullaClaim.impairClaim(claimId);

        // Try to mark as paid directly (should fail)
        vm.prank(newOwner);
        vm.expectRevert(abi.encodeWithSelector(IBullaClaim.NotController.selector, newOwner));
        bullaClaim.markClaimAsPaid(claimId);
    }

    // ================== MOCK CONTROLLER TESTS ==================

    function testControlledClaimTransferRequiresController_MockController() public {
        _testControlledClaimTransferRequiresController(new MockAdapter(address(mockController)));
    }

    function testControlledClaimApprovalRequiresController_MockController() public {
        _testControlledClaimApprovalRequiresController(new MockAdapter(address(mockController)));
    }

    function testControlledClaimSafeTransferRequiresController_MockController() public {
        _testControlledClaimSafeTransferRequiresController(new MockAdapter(address(mockController)));
    }

    function testControllerCanTransferControlledClaim_MockController() public {
        _testControllerCanTransferControlledClaim(new MockAdapter(address(mockController)));
    }

    function testControllerCanApproveControlledClaim_MockController() public {
        _testControllerCanApproveControlledClaim(new MockAdapter(address(mockController)));
    }

    function testControllerCanSafeTransferControlledClaim_MockController() public {
        _testControllerCanSafeTransferControlledClaim(new MockAdapter(address(mockController)));
    }

    function testControlledClaimSetApprovalForAllRequiresController_MockController() public {
        _testControlledClaimSetApprovalForAllRequiresController(new MockAdapter(address(mockController)));
    }

    function testControlledClaimERC721Errors_MockController() public {
        _testControlledClaimERC721Errors(new MockAdapter(address(mockController)));
    }

    function testControlledClaimOperationsRequireController_MockController() public {
        _testControlledClaimOperationsRequireController(new MockAdapter(address(mockController)));
    }

    // ================== BULLA INVOICE TESTS ==================

    function testControlledClaimTransferRequiresController_BullaInvoice() public {
        _testControlledClaimTransferRequiresController(new InvoiceAdapter(address(invoice)));
    }

    function testControlledClaimApprovalRequiresController_BullaInvoice() public {
        _testControlledClaimApprovalRequiresController(new InvoiceAdapter(address(invoice)));
    }

    function testControlledClaimSafeTransferRequiresController_BullaInvoice() public {
        _testControlledClaimSafeTransferRequiresController(new InvoiceAdapter(address(invoice)));
    }

    function testControllerCanTransferControlledClaim_BullaInvoice() public {
        _testControllerCanTransferControlledClaim(new InvoiceAdapter(address(invoice)));
    }

    function testControllerCanApproveControlledClaim_BullaInvoice() public {
        _testControllerCanApproveControlledClaim(new InvoiceAdapter(address(invoice)));
    }

    function testControllerCanSafeTransferControlledClaim_BullaInvoice() public {
        _testControllerCanSafeTransferControlledClaim(new InvoiceAdapter(address(invoice)));
    }

    function testControlledClaimSetApprovalForAllRequiresController_BullaInvoice() public {
        _testControlledClaimSetApprovalForAllRequiresController(new InvoiceAdapter(address(invoice)));
    }

    function testControlledClaimERC721Errors_BullaInvoice() public {
        _testControlledClaimERC721Errors(new InvoiceAdapter(address(invoice)));
    }

    function testControlledClaimOperationsRequireController_BullaInvoice() public {
        _testControlledClaimOperationsRequireController(new InvoiceAdapter(address(invoice)));
    }

    // ================== BULLA FRENDLEND TESTS ==================

    function testControlledClaimTransferRequiresController_BullaFrendLend() public {
        _testControlledClaimTransferRequiresController(new FrendLendAdapter(address(frendLend)));
    }

    function testControlledClaimApprovalRequiresController_BullaFrendLend() public {
        _testControlledClaimApprovalRequiresController(new FrendLendAdapter(address(frendLend)));
    }

    function testControlledClaimSafeTransferRequiresController_BullaFrendLend() public {
        _testControlledClaimSafeTransferRequiresController(new FrendLendAdapter(address(frendLend)));
    }

    function testControllerCanTransferControlledClaim_BullaFrendLend() public {
        _testControllerCanTransferControlledClaim(new FrendLendAdapter(address(frendLend)));
    }

    function testControllerCanApproveControlledClaim_BullaFrendLend() public {
        _testControllerCanApproveControlledClaim(new FrendLendAdapter(address(frendLend)));
    }

    function testControllerCanSafeTransferControlledClaim_BullaFrendLend() public {
        _testControllerCanSafeTransferControlledClaim(new FrendLendAdapter(address(frendLend)));
    }

    function testControlledClaimSetApprovalForAllRequiresController_BullaFrendLend() public {
        _testControlledClaimSetApprovalForAllRequiresController(new FrendLendAdapter(address(frendLend)));
    }

    function testControlledClaimERC721Errors_BullaFrendLend() public {
        _testControlledClaimERC721Errors(new FrendLendAdapter(address(frendLend)));
    }

    function testControlledClaimOperationsRequireController_BullaFrendLend() public {
        _testControlledClaimOperationsRequireController(new FrendLendAdapter(address(frendLend)));
    }

    // ================== UNCONTROLLED CLAIM TEST (BASELINE) ==================

    function testUncontrolledClaimCanBeTransferred() public {
        uint256 claimId = _createUncontrolledClaim();

        vm.prank(creditor);
        bullaClaim.transferFrom(creditor, newOwner, claimId);

        assertEq(bullaClaim.ownerOf(claimId), newOwner, "Claim should be transferred to new owner");

        // The claim should still have no controller
        Claim memory claim = bullaClaim.getClaim(claimId);
        assertEq(claim.controller, address(0), "Claim should have no controller");
    }
}
