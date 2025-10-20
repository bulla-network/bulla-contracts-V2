// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {WETH} from "contracts/mocks/weth.sol";
import {Claim, Status, ClaimBinding, CreateClaimParams, LockState} from "contracts/types/Types.sol";
import {BullaClaimV2} from "contracts/BullaClaimV2.sol";
import {DeployContracts} from "script/DeployContracts.s.sol";
import {CreateClaimParamsBuilder} from "test/foundry/BullaClaim/CreateClaimParamsBuilder.sol";
import {IBullaClaimV2} from "contracts/interfaces/IBullaClaimV2.sol";

/// @title Test to validate ClaimId behavior - whether first claim starts from 0 or 1
/// @notice This test demonstrates the current behavior where first claimId = 0
///         and shows how to fix it if claimId should start from 1
contract TestClaimIdStartsFromZero is Test {
    BullaClaimV2 internal bullaClaim;
    WETH internal weth;

    address creditor = address(0x1);
    address debtor = address(0x2);

    event ClaimCreated(
        uint256 indexed claimId,
        address from,
        address indexed creditor,
        address indexed debtor,
        uint256 claimAmount,
        uint256 dueBy,
        string description,
        address token,
        address controller,
        ClaimBinding binding
    );

    function setUp() public {
        weth = new WETH();
        DeployContracts.DeploymentResult memory deploymentResult =
            (new DeployContracts()).deployForTest(address(this), LockState.Unlocked, 0, 0, 0, 0, address(this));
        bullaClaim = BullaClaimV2(deploymentResult.bullaClaim);

        vm.deal(creditor, 10 ether);
        vm.deal(debtor, 10 ether);
    }

    /// @notice Test that validates first claimId = 0 and sequential assignment
    function testFirstClaimIdIsZero() public {
        // Verify initial state
        assertEq(bullaClaim.currentClaimId(), 0, "Initial currentClaimId should be 0");

        CreateClaimParams memory params = new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withClaimAmount(1 ether).build();

        // Create first claim - should get claimId = 0 (current behavior with post-increment)
        vm.prank(creditor);
        uint256 firstClaimId = bullaClaim.createClaim(params);
        assertEq(firstClaimId, 0, "First claim should have claimId = 0 (current behavior)");
        assertEq(bullaClaim.currentClaimId(), 1, "currentClaimId should be 1 after first claim");

        // Create second claim - should get claimId = 1
        vm.prank(creditor);
        uint256 secondClaimId = bullaClaim.createClaim(params);
        assertEq(secondClaimId, 1, "Second claim should be claimId = 1");
        assertEq(bullaClaim.currentClaimId(), 2, "currentClaimId should be 2");

        // Verify claims exist and can be retrieved
        Claim memory claim0 = bullaClaim.getClaim(0);
        Claim memory claim1 = bullaClaim.getClaim(1);
        assertEq(claim0.claimAmount, 1 ether, "Claim 0 should exist");
        assertEq(claim1.claimAmount, 1 ether, "Claim 1 should exist");
    }

    /// @notice Test demonstrates boundary check issue in getClaim function
    function testGetClaimBoundaryBug() public {
        // Initially no claims exist, currentClaimId = 0
        assertEq(bullaClaim.currentClaimId(), 0);

        vm.expectRevert(IBullaClaimV2.NotMinted.selector);
        bullaClaim.getClaim(0);

        // claimId = 1 correctly reverts (1 > 0 is true)
        vm.expectRevert(IBullaClaimV2.NotMinted.selector);
        bullaClaim.getClaim(1);
    }
}
