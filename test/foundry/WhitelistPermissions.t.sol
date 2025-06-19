// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "../../src/WhitelistPermissions.sol";
import "../../src/interfaces/IPermissions.sol";
import {IERC165} from "openzeppelin-contracts/contracts/utils/introspection/IERC165.sol";

contract WhitelistPermissionsTest is Test {
    WhitelistPermissions public whitelist;

    address public owner;
    address public user1;
    address public user2;
    address public user3;
    address public nonOwner;

    event AccessGranted(address indexed _account);
    event AccessRevoked(address indexed _account);

    function setUp() public {
        owner = address(this);
        user1 = address(0x1);
        user2 = address(0x2);
        user3 = address(0x3);
        nonOwner = address(0x999);

        whitelist = new WhitelistPermissions();

        vm.label(owner, "OWNER");
        vm.label(user1, "USER1");
        vm.label(user2, "USER2");
        vm.label(user3, "USER3");
        vm.label(nonOwner, "NON_OWNER");
    }

    /*///////////////////// CONSTRUCTOR TESTS /////////////////////*/

    function test_Constructor_SetsOwnerCorrectly() public {
        WhitelistPermissions newWhitelist = new WhitelistPermissions();
        assertEq(newWhitelist.owner(), address(this));
    }

    function test_Constructor_InitialStateEmpty() public {
        assertFalse(whitelist.isAllowed(user1));
        assertFalse(whitelist.isAllowed(user2));
        assertFalse(whitelist.isAllowed(address(0)));
    }

    /*///////////////////// isAllowed TESTS /////////////////////*/

    function test_IsAllowed_ReturnsTrueForWhitelistedAddress() public {
        whitelist.allow(user1);
        assertTrue(whitelist.isAllowed(user1));
        assertFalse(whitelist.isAllowed(user2)); // Still false for non-whitelisted
    }

    function test_IsAllowed_ConsistentBehavior() public {
        // Test before whitelisting
        assertFalse(whitelist.isAllowed(user1));
        assertFalse(whitelist.isAllowed(user2));

        // Test after whitelisting
        whitelist.allow(user1);
        assertTrue(whitelist.isAllowed(user1));
        assertFalse(whitelist.isAllowed(user2)); // Still false for non-whitelisted
    }

    /*///////////////////// allow TESTS /////////////////////*/

    function test_Allow_EmitsAccessGrantedEvent() public {
        vm.expectEmit(true, false, false, false);
        emit AccessGranted(user1);

        whitelist.allow(user1);
    }

    function test_Allow_CanWhitelistMultipleAddresses() public {
        whitelist.allow(user1);
        whitelist.allow(user2);
        whitelist.allow(user3);

        assertTrue(whitelist.isAllowed(user1));
        assertTrue(whitelist.isAllowed(user2));
        assertTrue(whitelist.isAllowed(user3));
    }

    function test_Allow_OnlyOwnerCanCall() public {
        vm.prank(nonOwner);
        vm.expectRevert();
        whitelist.allow(user1);

        // Verify it wasn't whitelisted
        assertFalse(whitelist.isAllowed(user1));
    }

    /*///////////////////// disallow TESTS /////////////////////*/

    function test_Disallow_OwnerCanRemoveFromWhitelist() public {
        // First whitelist the address
        whitelist.allow(user1);
        assertTrue(whitelist.isAllowed(user1));

        // Then remove it
        whitelist.disallow(user1);
        assertFalse(whitelist.isAllowed(user1));
    }

    function test_Disallow_EmitsAccessRevokedEvent() public {
        whitelist.allow(user1);

        vm.expectEmit(true, false, false, false);
        emit AccessRevoked(user1);

        whitelist.disallow(user1);
    }

    function test_Disallow_OnlyOwnerCanCall() public {
        whitelist.allow(user1);

        vm.prank(nonOwner);
        vm.expectRevert();
        whitelist.disallow(user1);

        // Verify it's still whitelisted
        assertTrue(whitelist.isAllowed(user1));
    }

    function test_Disallow_DoesNotAffectOtherAddresses() public {
        whitelist.allow(user1);
        whitelist.allow(user2);
        whitelist.allow(user3);

        whitelist.disallow(user2);

        assertTrue(whitelist.isAllowed(user1)); // Unaffected
        assertFalse(whitelist.isAllowed(user2)); // Removed
        assertTrue(whitelist.isAllowed(user3)); // Unaffected
    }

    /*///////////////////// OWNERSHIP TESTS /////////////////////*/

    function test_OwnershipTransfer_NewOwnerCanManageWhitelist() public {
        address newOwner = address(0x123);

        // Transfer ownership
        whitelist.transferOwnership(newOwner);

        // New owner can manage whitelist
        vm.prank(newOwner);
        whitelist.allow(user1);
        assertTrue(whitelist.isAllowed(user1));

        vm.prank(newOwner);
        whitelist.disallow(user1);
        assertFalse(whitelist.isAllowed(user1));
    }

    function test_OwnershipTransfer_OldOwnerCannotManageWhitelist() public {
        address newOwner = address(0x123);

        // Transfer ownership
        whitelist.transferOwnership(newOwner);

        // Old owner cannot manage whitelist
        vm.expectRevert();
        whitelist.allow(user1);

        vm.expectRevert();
        whitelist.disallow(user1);
    }

    /*///////////////////// EDGE CASES /////////////////////*/

    function test_WhitelistOwner_CanWhitelistOwner() public {
        whitelist.allow(owner);
        assertTrue(whitelist.isAllowed(owner));
    }

    function test_LargeScale_CanHandleMultipleAddresses() public {
        address[] memory addresses = new address[](100);

        // Create and whitelist 100 addresses
        for (uint256 i = 0; i < 100; i++) {
            addresses[i] = address(uint160(1000 + i));
            whitelist.allow(addresses[i]);
        }

        // Verify all are whitelisted
        for (uint256 i = 0; i < 100; i++) {
            assertTrue(whitelist.isAllowed(addresses[i]));
        }

        // Remove every other address
        for (uint256 i = 0; i < 100; i += 2) {
            whitelist.disallow(addresses[i]);
        }

        // Verify removal
        for (uint256 i = 0; i < 100; i++) {
            if (i % 2 == 0) {
                assertFalse(whitelist.isAllowed(addresses[i]));
            } else {
                assertTrue(whitelist.isAllowed(addresses[i]));
            }
        }
    }

    /*///////////////////// FUZZ TESTS /////////////////////*/

    function testFuzz_Allow_CanWhitelistAnyAddress(address randomAddress) public {
        whitelist.allow(randomAddress);
        assertTrue(whitelist.isAllowed(randomAddress));
    }

    function testFuzz_Disallow_CanRemoveAnyAddress(address randomAddress) public {
        whitelist.allow(randomAddress);
        whitelist.disallow(randomAddress);
        assertFalse(whitelist.isAllowed(randomAddress));
    }

    function testFuzz_OnlyOwner_NonOwnerCannotCall(address nonOwnerAddress) public {
        vm.assume(nonOwnerAddress != owner);

        vm.prank(nonOwnerAddress);
        vm.expectRevert();
        whitelist.allow(user1);

        vm.prank(nonOwnerAddress);
        vm.expectRevert();
        whitelist.disallow(user1);
    }

    /*///////////////////// STATE CONSISTENCY TESTS /////////////////////*/

    function test_StateConsistency_ProperStateTransitions() public {
        // Test various state transitions
        address[] memory testAddresses = new address[](5);
        testAddresses[0] = user1;
        testAddresses[1] = user2;
        testAddresses[2] = address(0);
        testAddresses[3] = address(whitelist);
        testAddresses[4] = owner;

        for (uint256 i = 0; i < testAddresses.length; i++) {
            address addr = testAddresses[i];

            // Initially false
            assertFalse(whitelist.isAllowed(addr));

            // After allowing
            whitelist.allow(addr);
            assertTrue(whitelist.isAllowed(addr));

            // After disallowing
            whitelist.disallow(addr);
            assertFalse(whitelist.isAllowed(addr));
        }
    }

    function test_EventsIntegrity_AllOperationsEmitCorrectEvents() public {
        // Test allow events
        vm.expectEmit(true, false, false, false);
        emit AccessGranted(user1);
        whitelist.allow(user1);

        vm.expectEmit(true, false, false, false);
        emit AccessGranted(user2);
        whitelist.allow(user2);

        // Test disallow events
        vm.expectEmit(true, false, false, false);
        emit AccessRevoked(user1);
        whitelist.disallow(user1);

        vm.expectEmit(true, false, false, false);
        emit AccessRevoked(user2);
        whitelist.disallow(user2);
    }

    /*///////////////////// ERC165 INTERFACE TESTS /////////////////////*/

    function test_ERC165_SupportsRequiredInterfaces() public {
        // Test that the contract supports ERC165
        assertTrue(whitelist.supportsInterface(type(IERC165).interfaceId));

        // Test that the contract supports IPermissions interface
        assertTrue(whitelist.supportsInterface(type(IPermissions).interfaceId));

        // Test that it returns false for a random interface
        assertFalse(whitelist.supportsInterface(0x12345678));
    }

    function test_ERC165_InterfaceIdIsCorrect() public {
        // Verify the interface ID for IPermissions is correctly calculated
        bytes4 expectedInterfaceId = IPermissions.isAllowed.selector;
        assertEq(type(IPermissions).interfaceId, expectedInterfaceId);
    }

    function test_ERC165_SupportsInterfaceHierarchy() public {
        // Test that parent interfaces are also supported
        assertTrue(whitelist.supportsInterface(type(IERC165).interfaceId));
        assertTrue(whitelist.supportsInterface(type(IPermissions).interfaceId));
    }

    function test_ERC165_DoesNotSupportRandomInterface() public {
        // Test various random interface IDs
        assertFalse(whitelist.supportsInterface(0x12345678));
        assertFalse(whitelist.supportsInterface(0xffffffff));
        assertFalse(whitelist.supportsInterface(0x00000000));
    }
}
