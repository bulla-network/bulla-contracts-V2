pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "contracts/BullaInvoice.sol";
// Note: We're testing interface detection without importing IBullaInvoice to avoid conflicts
import {EIP712Helper} from "test/foundry/BullaClaim/EIP712/Utils.sol";
import {Deployer} from "script/Deployment.s.sol";
import {BullaClaim} from "contracts/BullaClaim.sol";
import {IERC165} from "openzeppelin-contracts/contracts/utils/introspection/IERC165.sol";

contract BullaInvoiceERC165Test is Test {
    BullaClaim public bullaClaim;
    BullaInvoice public bullaInvoice;

    address admin = makeAddr("admin");
    uint256 constant PROTOCOL_FEE_BPS = 1000; // 10%
    uint256 constant INVOICE_ORIGINATION_FEE = 0.01 ether;
    uint256 constant PURCHASE_ORDER_ORIGINATION_FEE = 0.02 ether;

    function setUp() public {
        bullaClaim = (new Deployer()).deploy_test({_deployer: address(this), _initialLockState: LockState.Unlocked});
        bullaInvoice = new BullaInvoice(
            address(bullaClaim), admin, PROTOCOL_FEE_BPS, INVOICE_ORIGINATION_FEE, PURCHASE_ORDER_ORIGINATION_FEE
        );
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

    function testDoesNotSupportERC721Interface() public {
        // ERC721 interface ID (0x80ac58cd) - should not be supported
        bytes4 erc721InterfaceId = 0x80ac58cd;
        assertFalse(bullaInvoice.supportsInterface(erc721InterfaceId), "Should not support ERC721");
    }

    function testInterfaceIdCalculation() public {
        // Test that we can calculate the interface ID correctly
        bytes4 expectedInterfaceId = IBullaInvoice.createInvoice.selector
            ^ IBullaInvoice.createInvoiceWithMetadata.selector ^ IBullaInvoice.getInvoice.selector
            ^ IBullaInvoice.payInvoice.selector ^ IBullaInvoice.deliverPurchaseOrder.selector
            ^ IBullaInvoice.acceptPurchaseOrder.selector
            ^ IBullaInvoice.getTotalAmountNeededForPurchaseOrderDeposit.selector ^ IBullaInvoice.updateBinding.selector
            ^ IBullaInvoice.cancelInvoice.selector ^ IBullaInvoice.setProtocolFee.selector
            ^ IBullaInvoice.withdrawAllFees.selector ^ IBullaInvoice.admin.selector ^ IBullaInvoice.protocolFeeBPS.selector
            ^ IBullaInvoice.invoiceOriginationFee.selector ^ IBullaInvoice.purchaseOrderOriginationFee.selector
            ^ IBullaInvoice.protocolFeesByToken.selector;

        bytes4 actualInterfaceId = type(IBullaInvoice).interfaceId;
        assertEq(actualInterfaceId, expectedInterfaceId, "Interface ID calculation should match");
    }

    function testERC165CompatibilityWithExternalContracts() public {
        // Test that external contracts can properly detect BullaInvoice's interfaces
        MockERC165Detector detector = new MockERC165Detector();

        assertTrue(detector.detectsERC165(address(bullaInvoice)), "External contract should detect ERC165");
        assertTrue(detector.detectsBullaInvoice(address(bullaInvoice)), "External contract should detect IBullaInvoice");
        assertFalse(detector.detectsERC721(address(bullaInvoice)), "External contract should not detect ERC721");
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
