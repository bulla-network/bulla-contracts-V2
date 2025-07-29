pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "contracts/BullaFrendLendV2.sol";
import "contracts/interfaces/IBullaFrendLendV2.sol";
import {EIP712Helper} from "test/foundry/BullaClaim/EIP712/Utils.sol";
import {DeployContracts} from "script/DeployContracts.s.sol";
import {BullaClaimV2} from "contracts/BullaClaimV2.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

contract BullaFrendLendERC165Test is Test {
    BullaClaimV2 public bullaClaim;
    BullaFrendLendV2 public bullaFrendLend;

    address admin = makeAddr("admin");
    uint256 constant FEE = 0.01 ether;
    uint16 constant PROTOCOL_FEE_BPS = 1000; // 10%

    function setUp() public {
        DeployContracts.DeploymentResult memory deploymentResult =
            (new DeployContracts()).deployForTest(address(this), LockState.Unlocked, FEE, 0, 0, address(this));
        bullaClaim = BullaClaimV2(deploymentResult.bullaClaim);
        bullaFrendLend = new BullaFrendLendV2(address(bullaClaim), admin, PROTOCOL_FEE_BPS);
    }

    function testSupportsERC165Interface() public {
        // ERC165 interface ID is 0x01ffc9a7
        bytes4 erc165InterfaceId = type(IERC165).interfaceId;
        assertTrue(bullaFrendLend.supportsInterface(erc165InterfaceId), "Should support ERC165");
    }

    function testSupportsIBullaFrendLendInterface() public {
        // IBullaFrendLendV2 interface ID
        bytes4 bullaFrendLendInterfaceId = type(IBullaFrendLendV2).interfaceId;
        assertTrue(bullaFrendLend.supportsInterface(bullaFrendLendInterfaceId), "Should support IBullaFrendLendV2");
    }

    function testDoesNotSupportRandomInterface() public {
        // Random interface ID that should not be supported
        bytes4 randomInterfaceId = 0x12345678;
        assertFalse(bullaFrendLend.supportsInterface(randomInterfaceId), "Should not support random interface");
    }

    function testInterfaceIdCalculation() public {
        // Test that we can calculate the interface ID correctly
        bytes4 expectedInterfaceId = IBullaFrendLendV2.getTotalAmountDue.selector ^ IBullaFrendLendV2.getLoan.selector
            ^ IBullaFrendLendV2.offerLoanWithMetadata.selector ^ IBullaFrendLendV2.offerLoan.selector
            ^ IBullaFrendLendV2.rejectLoanOffer.selector ^ IBullaFrendLendV2.acceptLoan.selector
            ^ IBullaFrendLendV2.acceptLoanWithReceiver.selector ^ IBullaFrendLendV2.batchAcceptLoans.selector
            ^ IBullaFrendLendV2.payLoan.selector ^ IBullaFrendLendV2.impairLoan.selector
            ^ IBullaFrendLendV2.markLoanAsPaid.selector ^ IBullaFrendLendV2.withdrawAllFees.selector
            ^ IBullaFrendLendV2.setProtocolFee.selector ^ IBullaFrendLendV2.admin.selector
            ^ IBullaFrendLendV2.loanOfferCount.selector ^ IBullaFrendLendV2.protocolFeeBPS.selector
            ^ IBullaFrendLendV2.getLoanOffer.selector ^ IBullaFrendLendV2.getLoanOfferMetadata.selector
            ^ IBullaFrendLendV2.protocolFeesByToken.selector;

        bytes4 actualInterfaceId = type(IBullaFrendLendV2).interfaceId;
        assertEq(actualInterfaceId, expectedInterfaceId, "Interface ID calculation should match");
    }

    function testERC165CompatibilityWithExternalContracts() public {
        // Test that external contracts can properly detect BullaFrendLend's interfaces
        MockERC165Detector detector = new MockERC165Detector();

        assertTrue(detector.detectsERC165(address(bullaFrendLend)), "External contract should detect ERC165");
        assertTrue(
            detector.detectsBullaFrendLend(address(bullaFrendLend)), "External contract should detect IBullaFrendLendV2"
        );
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
        return IERC165(contractAddress).supportsInterface(type(IBullaFrendLendV2).interfaceId);
    }

    function detectsERC721(address contractAddress) external view returns (bool) {
        return IERC165(contractAddress).supportsInterface(0x80ac58cd); // ERC721 interface ID
    }
}
