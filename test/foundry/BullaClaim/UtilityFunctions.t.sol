// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {Claim, Status, ClaimBinding, LockState, CreateClaimParams, ClaimMetadata} from "contracts/types/Types.sol";
import {BullaClaim} from "contracts/BullaClaim.sol";
import {ClaimMetadataGenerator} from "contracts/ClaimMetadataGenerator.sol";
import {DeployContracts} from "script/DeployContracts.s.sol";
import {IBullaApprovalRegistry} from "contracts/interfaces/IBullaApprovalRegistry.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract TestTokenURI is Test {
    BullaClaim public bullaClaim;
    IBullaApprovalRegistry public approvalRegistry;

    address alice = address(0xA11cE);
    address charlie = address(0xC44511E);

    function setUp() public {
        DeployContracts.DeploymentResult memory deploymentResult =
            (new DeployContracts()).deployForTest(address(this), LockState.Unlocked, 0, 0, 0, address(this));
        bullaClaim = BullaClaim(deploymentResult.bullaClaim);
        approvalRegistry = bullaClaim.approvalRegistry();
    }

    function testDomainSeparator() public {
        assertTrue(approvalRegistry.DOMAIN_SEPARATOR() != bytes32(0));
    }

    function testOwner() public {
        assertTrue(bullaClaim.owner() == address(this));
    }

    function testCurrentClaimId() public {
        assertTrue(bullaClaim.currentClaimId() == 0);
    }

    ////// OWNER FUNCTIONS //////

    function testSetControllerRegistryOnlyOwner(address _controllerRegistry) public {
        approvalRegistry.setControllerRegistry(_controllerRegistry);

        assertEq(address(approvalRegistry.controllerRegistry()), _controllerRegistry);

        vm.prank(charlie);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, charlie));
        approvalRegistry.setControllerRegistry(_controllerRegistry);
    }

    function testSetControllerRegistryWhileLocked() public {
        bullaClaim.setLockState(LockState.Locked);
        approvalRegistry.setControllerRegistry(address(0x12345));
    }

    function testSetClaimMetadataGeneratorOnlyOwner(address _metadataGenerator) public {
        bullaClaim.setClaimMetadataGenerator(_metadataGenerator);

        assertEq(address(bullaClaim.claimMetadataGenerator()), _metadataGenerator);

        vm.prank(charlie);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, charlie));
        bullaClaim.setClaimMetadataGenerator(_metadataGenerator);
    }

    function testSetClaimMetadataGeneratorWhileLocked() public {
        bullaClaim.setLockState(LockState.Locked);
        bullaClaim.setClaimMetadataGenerator(address(0x12345));
    }

    function testLockStateOnlyOwner(uint8 __lockState) public {
        LockState _lockState = LockState(__lockState % 3);
        bullaClaim.setLockState(_lockState);

        assertTrue(bullaClaim.lockState() == _lockState);

        vm.prank(charlie);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, charlie));
        bullaClaim.setLockState(_lockState);
    }

    function testLockStateWhileLocked() public {
        bullaClaim.setLockState(LockState.Locked);
        bullaClaim.setLockState(LockState.Unlocked);
    }
}
