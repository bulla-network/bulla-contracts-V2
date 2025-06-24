pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "contracts/BullaFrendLend.sol";
import "contracts/interfaces/IBullaFrendLend.sol";
import {EIP712Helper} from "test/foundry/BullaClaim/EIP712/Utils.sol";
import {Deployer} from "script/Deployment.s.sol";
import {BullaClaim} from "contracts/BullaClaim.sol";
import {IERC165} from "openzeppelin-contracts/contracts/utils/introspection/IERC165.sol";

contract BullaFrendLendERC165Test is Test {
    BullaClaim public bullaClaim;
    BullaFrendLend public bullaFrendLend;

    address admin = makeAddr("admin");
    uint256 constant FEE = 0.01 ether;
    uint256 constant PROTOCOL_FEE_BPS = 1000; // 10%

    function setUp() public {
        bullaClaim = (new Deployer()).deploy_test(address(this), LockState.Unlocked, FEE);
        bullaFrendLend = new BullaFrendLend(address(bullaClaim), admin, PROTOCOL_FEE_BPS);
    }

    function testSupportsERC165Interface() public {
        // ERC165 interface ID is 0x01ffc9a7
        bytes4 erc165InterfaceId = type(IERC165).interfaceId;
        assertTrue(bullaFrendLend.supportsInterface(erc165InterfaceId), "Should support ERC165");
    }

    function testSupportsIBullaFrendLendInterface() public {
        // IBullaFrendLend interface ID
        bytes4 bullaFrendLendInterfaceId = type(IBullaFrendLend).interfaceId;
        assertTrue(bullaFrendLend.supportsInterface(bullaFrendLendInterfaceId), "Should support IBullaFrendLend");
    }

    function testDoesNotSupportRandomInterface() public {
        // Random interface ID that should not be supported
        bytes4 randomInterfaceId = 0x12345678;
        assertFalse(bullaFrendLend.supportsInterface(randomInterfaceId), "Should not support random interface");
    }

    function testDoesNotSupportERC721Interface() public {
        // ERC721 interface ID (0x80ac58cd) - should not be supported
        bytes4 erc721InterfaceId = 0x80ac58cd;
        assertFalse(bullaFrendLend.supportsInterface(erc721InterfaceId), "Should not support ERC721");
    }

    function testInterfaceIdCalculation() public {
        // Test that we can calculate the interface ID correctly
        bytes4 expectedInterfaceId = IBullaFrendLend.getTotalAmountDue.selector ^ IBullaFrendLend.getLoan.selector
            ^ IBullaFrendLend.offerLoanWithMetadata.selector ^ IBullaFrendLend.offerLoan.selector
            ^ IBullaFrendLend.rejectLoanOffer.selector ^ IBullaFrendLend.acceptLoan.selector
            ^ IBullaFrendLend.acceptLoanWithReceiver.selector ^ IBullaFrendLend.batchAcceptLoans.selector
            ^ IBullaFrendLend.payLoan.selector ^ IBullaFrendLend.impairLoan.selector
            ^ IBullaFrendLend.markLoanAsPaid.selector ^ IBullaFrendLend.withdrawAllFees.selector
            ^ IBullaFrendLend.setProtocolFee.selector ^ IBullaFrendLend.admin.selector
            ^ IBullaFrendLend.loanOfferCount.selector ^ IBullaFrendLend.protocolFeeBPS.selector
            ^ IBullaFrendLend.getLoanOffer.selector ^ IBullaFrendLend.getLoanOfferMetadata.selector
            ^ IBullaFrendLend.protocolFeesByToken.selector;

        bytes4 actualInterfaceId = type(IBullaFrendLend).interfaceId;
        assertEq(actualInterfaceId, expectedInterfaceId, "Interface ID calculation should match");
    }

    function testERC165CompatibilityWithExternalContracts() public {
        // Test that external contracts can properly detect BullaFrendLend's interfaces
        MockERC165Detector detector = new MockERC165Detector();

        assertTrue(detector.detectsERC165(address(bullaFrendLend)), "External contract should detect ERC165");
        assertTrue(
            detector.detectsBullaFrendLend(address(bullaFrendLend)), "External contract should detect IBullaFrendLend"
        );
        assertFalse(detector.detectsERC721(address(bullaFrendLend)), "External contract should not detect ERC721");
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

    function detectsBullaFrendLend(address contractAddress) external view returns (bool) {
        return IERC165(contractAddress).supportsInterface(type(IBullaFrendLend).interfaceId);
    }

    function detectsERC721(address contractAddress) external view returns (bool) {
        return IERC165(contractAddress).supportsInterface(0x80ac58cd); // ERC721 interface ID
    }
}
