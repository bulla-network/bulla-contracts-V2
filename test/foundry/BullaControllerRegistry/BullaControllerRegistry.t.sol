// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {BullaControllerRegistry} from "contracts/BullaControllerRegistry.sol";

contract TestBullaControllerRegistry is Test {
    BullaControllerRegistry public registry;

    address public owner;
    address public nonOwner = address(0x456);
    address public testController = address(0x123);

    function setUp() public {
        owner = address(this);
        registry = new BullaControllerRegistry();
    }

    // ========================================
    // Constructor and Ownership Tests
    // ========================================

    function testConstructor() public {
        BullaControllerRegistry newRegistry = new BullaControllerRegistry();
        assertEq(newRegistry.owner(), address(this), "Constructor should set deployer as owner");
    }

    function testOwnership() public {
        assertEq(registry.owner(), address(this), "Should have correct owner");
    }

    function testDefaultControllerName() public {
        assertEq(
            registry.DEFAULT_CONTROLLER_NAME(),
            "WARNING: CONTRACT UNKNOWN",
            "Should have correct default controller name"
        );
    }

    // ========================================
    // getControllerName Function Tests
    // ========================================

    function testGetControllerName_Success() public {
        string memory controllerName = "TestController";

        // Set a controller name
        registry.setControllerName(testController, controllerName);

        // Should return the controller name
        string memory result = registry.getControllerName(testController);
        assertEq(result, controllerName, "Should return the correct controller name");
    }

    function testGetControllerName_UnknownController() public {
        address unknownController = address(0x999);

        // Should return warning message for unknown controller
        string memory result = registry.getControllerName(unknownController);
        assertEq(result, "WARNING: CONTRACT UNKNOWN", "Should return warning for unknown controller");
    }

    function testGetControllerName_EmptyString() public {
        // Set controller with empty string
        registry.setControllerName(testController, "");

        // Should return warning message for empty string
        string memory result = registry.getControllerName(testController);
        assertEq(result, "WARNING: CONTRACT UNKNOWN", "Should return warning for empty controller name");
    }

    function testGetControllerName_ZeroAddress() public {
        // Should return warning message for zero address
        string memory result = registry.getControllerName(address(0));
        assertEq(result, "WARNING: CONTRACT UNKNOWN", "Should return warning for zero address");
    }

    function testGetControllerName_MultipleControllers() public {
        address controller1 = address(0x111);
        address controller2 = address(0x222);
        string memory name1 = "Controller1";
        string memory name2 = "Controller2";

        // Set multiple controllers
        registry.setControllerName(controller1, name1);
        registry.setControllerName(controller2, name2);

        // Should return correct names for each
        assertEq(registry.getControllerName(controller1), name1, "Should return correct name for controller1");
        assertEq(registry.getControllerName(controller2), name2, "Should return correct name for controller2");
    }

    // ========================================
    // setControllerName Function Tests
    // ========================================

    function testSetControllerName_Success() public {
        string memory controllerName = "TestController";

        // Should successfully set controller name
        registry.setControllerName(testController, controllerName);

        // Verify it was set correctly
        assertEq(registry.getControllerName(testController), controllerName, "Controller name should be set correctly");
    }

    function testSetControllerName_OnlyOwner() public {
        string memory controllerName = "TestController";

        // Should revert when called by non-owner
        vm.prank(nonOwner);
        vm.expectRevert("UNAUTHORIZED");
        registry.setControllerName(testController, controllerName);
    }

    function testSetControllerName_UpdateExisting() public {
        string memory oldName = "OldController";
        string memory newName = "NewController";

        // Set initial name
        registry.setControllerName(testController, oldName);
        assertEq(registry.getControllerName(testController), oldName, "Should set initial name");

        // Update name
        registry.setControllerName(testController, newName);
        assertEq(registry.getControllerName(testController), newName, "Should update to new name");
    }

    function testSetControllerName_EmptyString() public {
        string memory initialName = "InitialController";

        // Set initial name
        registry.setControllerName(testController, initialName);
        assertEq(registry.getControllerName(testController), initialName, "Should set initial name");

        // Set to empty string
        registry.setControllerName(testController, "");

        // getControllerName should return warning
        assertEq(
            registry.getControllerName(testController),
            "WARNING: CONTRACT UNKNOWN",
            "Should return warning for empty string"
        );
    }

    function testSetControllerName_ZeroAddress() public {
        string memory controllerName = "ZeroAddressController";

        // Should allow setting name for zero address
        registry.setControllerName(address(0), controllerName);
        assertEq(registry.getControllerName(address(0)), controllerName, "Should set name for zero address");
    }

    function testSetControllerName_LongString() public {
        // Test with a very long controller name
        string memory longName = "ThisIsAVeryLongControllerNameThatExceedsNormalLengthsAndTestsStringHandling";

        registry.setControllerName(testController, longName);
        assertEq(registry.getControllerName(testController), longName, "Should handle long controller names");
    }

    function testSetControllerName_SpecialCharacters() public {
        // Test with special characters
        string memory specialName = "Controller-With_Special.Characters@123!";

        registry.setControllerName(testController, specialName);
        assertEq(registry.getControllerName(testController), specialName, "Should handle special characters");
    }

    // ========================================
    // Integration and Edge Case Tests
    // ========================================

    function testMultipleOperations() public {
        address controller1 = address(0x111);
        address controller2 = address(0x222);
        address controller3 = address(0x333);

        // Set multiple controllers
        registry.setControllerName(controller1, "Controller1");
        registry.setControllerName(controller2, "Controller2");
        registry.setControllerName(controller3, "Controller3");

        // Verify all are set correctly
        assertEq(registry.getControllerName(controller1), "Controller1");
        assertEq(registry.getControllerName(controller2), "Controller2");
        assertEq(registry.getControllerName(controller3), "Controller3");

        // Update one
        registry.setControllerName(controller2, "UpdatedController2");
        assertEq(registry.getControllerName(controller2), "UpdatedController2");

        // Others should remain unchanged
        assertEq(registry.getControllerName(controller1), "Controller1");
        assertEq(registry.getControllerName(controller3), "Controller3");

        // Remove one (set to empty) - should return default warning
        registry.setControllerName(controller1, "");
        assertEq(
            registry.getControllerName(controller1),
            "WARNING: CONTRACT UNKNOWN",
            "Should return warning for empty controller"
        );

        // Others should still work
        assertEq(registry.getControllerName(controller2), "UpdatedController2");
        assertEq(registry.getControllerName(controller3), "Controller3");
    }

    // ========================================
    // Fuzz Tests
    // ========================================

    function testFuzz_SetAndGetControllerName(address controller, string calldata name) public {
        registry.setControllerName(controller, name);

        if (bytes(name).length > 0) {
            assertEq(registry.getControllerName(controller), name, "Fuzz: getControllerName should return set name");
        } else {
            assertEq(
                registry.getControllerName(controller),
                "WARNING: CONTRACT UNKNOWN",
                "Fuzz: should return warning for empty name"
            );
        }
    }

    function testFuzz_GetControllerName_EmptyOrUnknown(address controller) public {
        // For any unset controller, should return warning
        string memory result = registry.getControllerName(controller);
        assertEq(result, "WARNING: CONTRACT UNKNOWN", "Fuzz: should return warning for unset controller");
    }

    function testFuzz_SetControllerName_OnlyOwner(address caller, address controller, string calldata name) public {
        vm.assume(caller != address(this)); // Assume caller is not the owner

        vm.prank(caller);
        vm.expectRevert("UNAUTHORIZED");
        registry.setControllerName(controller, name);
    }
}
