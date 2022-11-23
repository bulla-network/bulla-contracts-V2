// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.15;

import "forge-std/Test.sol";
import {
    Claim,
    Status,
    ClaimBinding,
    FeePayer,
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
    address feeReceiver = address(0xFEE);

    function setUp() public {
        (bullaClaim,) = (new Deployer()).deploy_test({
            _deployer: address(this),
            _feeReceiver: feeReceiver,
            _initialLockState: LockState.Unlocked,
            _feeBPS: 0
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

    function testSetFeeCalculatorOnlyOwner(address _feeCalculator) public {
        uint256 feeCalcBefore = bullaClaim.currentFeeCalculatorId();
        bullaClaim.setFeeCalculator(_feeCalculator);

        assertEq(bullaClaim.currentFeeCalculatorId(), feeCalcBefore + 1);
        assertEq(address(bullaClaim.feeCalculators(bullaClaim.currentFeeCalculatorId())), _feeCalculator);

        vm.prank(charlie);
        vm.expectRevert("Ownable: caller is not the owner");
        bullaClaim.setFeeCalculator(_feeCalculator);
    }

    function testSetFeeCalculatorWhileLocked() public {
        bullaClaim.setLockState(LockState.Locked);
        bullaClaim.setFeeCalculator(address(0x12345));
    }

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

    function testSetFeeCollectionAddressOnlyOwner(address _feeCollectionAddress) public {
        bullaClaim.setFeeCollectionAddress(_feeCollectionAddress);

        assertEq(address(bullaClaim.feeCollectionAddress()), _feeCollectionAddress);

        vm.prank(charlie);
        vm.expectRevert("Ownable: caller is not the owner");
        bullaClaim.setFeeCollectionAddress(_feeCollectionAddress);
    }

    function testSetFeeCollectionAddressWhileLocked() public {
        bullaClaim.setLockState(LockState.Locked);
        bullaClaim.setFeeCollectionAddress(address(0x12345));
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
