pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "contracts/BullaInvoice.sol";
// Note: We're testing interface detection without importing IBullaInvoice to avoid conflicts
import {EIP712Helper} from "test/foundry/BullaClaim/EIP712/Utils.sol";
import {DeployContracts} from "script/DeployContracts.s.sol";
import {BullaClaimV2} from "contracts/BullaClaimV2.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

contract BullaInvoiceERC165Test is Test {
    BullaClaimV2 public bullaClaim;
    BullaInvoice public bullaInvoice;

    address admin = makeAddr("admin");
    uint16 constant PROTOCOL_FEE_BPS = 1000; // 10%

    function setUp() public {
        DeployContracts.DeploymentResult memory deploymentResult =
            (new DeployContracts()).deployForTest(address(this), LockState.Unlocked, 0, 0, 0, address(this));
        bullaClaim = BullaClaimV2(deploymentResult.bullaClaim);
        bullaInvoice = new BullaInvoice(address(bullaClaim), admin, PROTOCOL_FEE_BPS);
    }

    function testSupportsERC165Interface() public {
        // ERC165 interface ID is 0x01ffc9a7
        bytes4 erc165InterfaceId = type(IERC165).interfaceId;
        assertTrue(bullaInvoice.supportsInterface(erc165InterfaceId), "Should support ERC165");
    }

    function testSupportsIBullaInvoiceInterface() public {
        // IBullaInvoice interface ID
        bytes4 bullaInvoiceInterfaceId = type(IBullaInvoice).interfaceId;
        assertTrue(bullaInvoice.supportsInterface(bullaInvoiceInterfaceId), "Should support IBullaInvoice");
    }

    function testDoesNotSupportRandomInterface() public {
        // Random interface ID that should not be supported
        bytes4 randomInterfaceId = 0x12345678;
        assertFalse(bullaInvoice.supportsInterface(randomInterfaceId), "Should not support random interface");
    }

    function testInterfaceIdCalculation() public {
        // Test that we can calculate the interface ID correctly
        bytes4 expectedInterfaceId = IBullaInvoice.createInvoice.selector
            ^ IBullaInvoice.createInvoiceWithMetadata.selector ^ IBullaInvoice.getInvoice.selector
            ^ IBullaInvoice.payInvoice.selector ^ IBullaInvoice.deliverPurchaseOrder.selector
            ^ IBullaInvoice.acceptPurchaseOrder.selector
            ^ IBullaInvoice.getTotalAmountNeededForPurchaseOrderDeposit.selector ^ IBullaInvoice.updateBinding.selector
            ^ IBullaInvoice.cancelInvoice.selector ^ IBullaInvoice.setProtocolFee.selector
            ^ IBullaInvoice.withdrawAllFees.selector ^ IBullaInvoice.addToFeeTokenWhitelist.selector
            ^ IBullaInvoice.removeFromFeeTokenWhitelist.selector ^ IBullaInvoice.admin.selector
            ^ IBullaInvoice.protocolFeeBPS.selector ^ IBullaInvoice.protocolFeesByToken.selector
            ^ IBullaInvoice.impairInvoice.selector ^ IBullaInvoice.markInvoiceAsPaid.selector;

        bytes4 actualInterfaceId = type(IBullaInvoice).interfaceId;
        assertEq(actualInterfaceId, expectedInterfaceId, "Interface ID calculation should match");
    }

    function testERC165CompatibilityWithExternalContracts() public {
        // Test that external contracts can properly detect BullaInvoice's interfaces
        MockERC165Detector detector = new MockERC165Detector();

        assertTrue(detector.detectsERC165(address(bullaInvoice)), "External contract should detect ERC165");
        assertTrue(detector.detectsBullaInvoice(address(bullaInvoice)), "External contract should detect IBullaInvoice");
    }
}

/**
 * @title MockERC165Detector
 * @notice A mock contract to test ERC165 detection from external contracts
 */
contract MockERC165Detector {
    function detectsERC165(address contractAddress) external view returns (bool) {
        return IERC165(contractAddress).supportsInterface(type(IERC165).interfaceId);
    }

    function detectsBullaInvoice(address contractAddress) external view returns (bool) {
        return IERC165(contractAddress).supportsInterface(type(IBullaInvoice).interfaceId);
    }

    function detectsERC721(address contractAddress) external view returns (bool) {
        return IERC165(contractAddress).supportsInterface(0x80ac58cd); // ERC721 interface ID
    }
}
