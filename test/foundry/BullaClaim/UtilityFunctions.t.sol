// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.15;

import "forge-std/Test.sol";
import {
    Claim,
    Status,
    ClaimBinding,
    LockState,
    CreateClaimParams,
    ClaimMetadata
} from "contracts/types/Types.sol";
import {BullaClaim} from "contracts/BullaClaim.sol";
import {ClaimMetadataGenerator} from "contracts/ClaimMetadataGenerator.sol";
import {Deployer} from "script/Deployment.s.sol";

contract TestTokenURI is Test {
    BullaClaim public bullaClaim;

    address alice = address(0xA11cE);
    address charlie = address(0xC44511E);

    function setUp() public {
        bullaClaim = (new Deployer()).deploy_test({
            _deployer: address(this),
            _initialLockState: LockState.Unlocked
        });
    }

    function testDomainSeparator() public {
        assertTrue(bullaClaim.DOMAIN_SEPARATOR() != bytes32(0));
    }

    function testOwner() public {
        assertTrue(bullaClaim.owner() == address(this));
    }

    function testCurrentClaimId() public {
        assertTrue(bullaClaim.currentClaimId() == 0);
    }

    ////// OWNER FUNCTIONS //////

    function testSetExtensionRegistryOnlyOwner(address _extensionRegistry) public {
        bullaClaim.setExtensionRegistry(_extensionRegistry);

        assertEq(address(bullaClaim.extensionRegistry()), _extensionRegistry);

        vm.prank(charlie);
        vm.expectRevert("Ownable: caller is not the owner");
        bullaClaim.setExtensionRegistry(_extensionRegistry);
    }

    function testSetExtensionRegistryWhileLocked() public {
        bullaClaim.setLockState(LockState.Locked);
        bullaClaim.setExtensionRegistry(address(0x12345));
    }

    function testSetClaimMetadataGeneratorOnlyOwner(address _metadataGenerator) public {
        bullaClaim.setClaimMetadataGenerator(_metadataGenerator);

        assertEq(address(bullaClaim.claimMetadataGenerator()), _metadataGenerator);

        vm.prank(charlie);
        vm.expectRevert("Ownable: caller is not the owner");
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
        vm.expectRevert("Ownable: caller is not the owner");
        bullaClaim.setLockState(_lockState);
    }

    function testLockStateWhileLocked() public {
        bullaClaim.setLockState(LockState.Locked);
        bullaClaim.setLockState(LockState.Unlocked);
    }
}
