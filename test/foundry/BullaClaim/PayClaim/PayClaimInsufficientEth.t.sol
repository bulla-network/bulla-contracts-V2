// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.30;

import "forge-std/Vm.sol";
import "forge-std/Test.sol";
import "forge-std/console.sol";
import "contracts/types/Types.sol";
import {BullaClaimV2} from "contracts/BullaClaimV2.sol";
import {IBullaClaimV2} from "contracts/interfaces/IBullaClaimV2.sol";
import {BullaClaimTestHelper} from "test/foundry/BullaClaim/BullaClaimTestHelper.sol";
import {DeployContracts} from "script/DeployContracts.s.sol";
import {CreateClaimParamsBuilder} from "test/foundry/BullaClaim/CreateClaimParamsBuilder.sol";

/**
 * @title TestPayClaimInsufficientEth
 * @notice Tests to validate ETH payment validation in BullaClaimV2
 * @dev These tests verify that BullaClaimV2 now correctly validates msg.value == paymentAmount
 *      matching the secure behavior of BullaInvoice
 */
contract TestPayClaimInsufficientEth is BullaClaimTestHelper {
    address creditor = address(0xA11c3);
    address debtor = address(0xB0b);

    function setUp() public {
        vm.label(address(this), "TEST_CONTRACT");
        vm.label(creditor, "CREDITOR");
        vm.label(debtor, "DEBTOR");

        DeployContracts.DeploymentResult memory deploymentResult =
            (new DeployContracts()).deployForTest(address(this), LockState.Unlocked, 0, 0, 0, address(this));
        bullaClaim = BullaClaimV2(deploymentResult.bullaClaim);
        approvalRegistry = bullaClaim.approvalRegistry();

        // Give debtor and creditor ETH
        vm.deal(creditor, 1000 ether);
        vm.deal(debtor, 1000 ether);
    }

    function _createNativeEthClaim(uint256 claimAmount) private returns (uint256 claimId) {
        vm.startPrank(creditor);
        claimId = bullaClaim.createClaim(
            new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor).withClaimAmount(claimAmount)
                .withToken(address(0)) // Native ETH
                .build()
        );
        vm.stopPrank();
    }

    function testPayClaimInsufficientMsgValueFails() public {
        uint256 claimAmount = 10 ether;
        uint256 claimId = _createNativeEthClaim(claimAmount);

        uint256 paymentAmount = 10 ether;
        uint256 insufficientMsgValue = 5 ether; // Less than payment amount

        // BullaClaimV2 now correctly validates msg.value == paymentAmount
        vm.prank(debtor);
        vm.expectRevert(IBullaClaimV2.IncorrectMsgValue.selector);
        bullaClaim.payClaim{value: insufficientMsgValue}(claimId, paymentAmount);
    }

    function testPayClaimInsufficientContractBalanceFails() public {
        uint256 claimAmount = 20 ether;
        uint256 claimId = _createNativeEthClaim(claimAmount);

        uint256 paymentAmount = 10 ether;
        uint256 insufficientMsgValue = 3 ether; // Less than payment amount

        // With the new validation, msg.value validation happens first
        // So insufficient msg.value will revert with IncorrectMsgValue, not ETH_TRANSFER_FAILED
        vm.prank(debtor);
        vm.expectRevert(IBullaClaimV2.IncorrectMsgValue.selector);
        bullaClaim.payClaim{value: insufficientMsgValue}(claimId, paymentAmount);

        // Verify claim state remains unchanged
        Claim memory claim = bullaClaim.getClaim(claimId);
        assertEq(uint256(claim.status), uint256(Status.Pending));
        assertEq(claim.paidAmount, 0);
    }

    function testFuzzPayClaimInsufficientMsgValueFails(uint256 claimAmount, uint256 paymentAmount, uint256 msgValue)
        public
    {
        // Bound inputs to reasonable ranges
        claimAmount = bound(claimAmount, 1 ether, 100 ether);
        paymentAmount = bound(paymentAmount, 1 ether, claimAmount);
        msgValue = bound(msgValue, 0, paymentAmount - 1); // Always less than payment amount

        uint256 claimId = _createNativeEthClaim(claimAmount);

        // Ensure contract has enough balance to demonstrate the vulnerability
        vm.deal(address(bullaClaim), paymentAmount + 100 ether);

        vm.prank(debtor);
        // Should correctly revert with validation
        vm.expectRevert(IBullaClaimV2.IncorrectMsgValue.selector);
        bullaClaim.payClaim{value: msgValue}(claimId, paymentAmount);
    }
}
