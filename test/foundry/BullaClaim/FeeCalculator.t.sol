// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.14;

import "forge-std/Vm.sol";
import "forge-std/Test.sol";
import {Claim, Status, ClaimBinding, FeePayer, CreateClaimParams} from "contracts/types/Types.sol";
import {WETH} from "contracts/mocks/weth.sol";
import {BullaClaim, LockState} from "contracts/BullaClaim.sol";
import {BullaFeeCalculator} from "contracts/BullaFeeCalculator.sol";
import {Deployer} from "script/Deployment.s.sol";

contract TestFeeCalculator is Test {
    WETH public weth;
    BullaClaim public bullaClaim;
    BullaFeeCalculator feeCalculator;

    address alice = address(0xA11cE);
    address contractOwner = address(0xB0b);
    address creditor = address(0x01);
    address debtor = address(0x02);
    address feeReceiver = address(0xFEE);

    function setUp() public {
        weth = new WETH();

        (bullaClaim,) = (new Deployer()).deploy_test(contractOwner, address(0xfee), LockState.Unlocked, 0);
    }

    function testFeeCalculatorOnlyAddedByOwner() public {
        feeCalculator = new BullaFeeCalculator(500);

        vm.prank(contractOwner);
        bullaClaim.setFeeCalculator(address(feeCalculator));

        BullaFeeCalculator feeCalculator2 = new BullaFeeCalculator(100);

        vm.expectRevert("Ownable: caller is not the owner");
        // alice is not the contract owner
        vm.prank(alice);
        bullaClaim.setFeeCalculator(address(feeCalculator2));
    }

    function testNoFeeCalculatorIsStoredIfCalculatorIsDisabled() public {
        // fee calculator is never added to the claim contract

        vm.prank(alice);
        uint256 claimId = bullaClaim.createClaim(
            CreateClaimParams({
                creditor: alice,
                debtor: debtor,
                description: "",
                claimAmount: 1 ether,
                dueBy: block.timestamp + 1 days,
                token: address(weth),
                controller: address(0),
                feePayer: FeePayer.Debtor,
                binding: ClaimBinding.Unbound
            })
        );

        assertEq(bullaClaim.getClaim(claimId).feeCalculatorId, 0);
    }

    function testCanDisableFeesBySettingTheCalculatorToAddressZero() public {
        feeCalculator = new BullaFeeCalculator(500);

        vm.prank(contractOwner);
        bullaClaim.setFeeCalculator(address(feeCalculator));

        uint256 feeReceiverBalanceBefore = weth.balanceOf(feeReceiver);

        vm.prank(alice);
        uint256 claimId = bullaClaim.createClaim(
            CreateClaimParams({
                creditor: alice,
                debtor: debtor,
                description: "",
                claimAmount: 1 ether,
                dueBy: block.timestamp + 1 days,
                token: address(weth),
                controller: address(0),
                feePayer: FeePayer.Creditor,
                binding: ClaimBinding.Unbound
            })
        );

        weth.approve(address(bullaClaim), type(uint256).max);
        bullaClaim.payClaim(claimId, 1 ether);

        // fee is enabled
        assertEq(bullaClaim.getClaim(claimId).feeCalculatorId, 1);

        // fee is transferred as expected
        assertTrue(weth.balanceOf(feeReceiver) > feeReceiverBalanceBefore);

        // disable fee
        vm.prank(contractOwner);
        bullaClaim.setFeeCalculator(address(0));

        vm.prank(alice);
        uint256 claimId__noFee = bullaClaim.createClaim(
            CreateClaimParams({
                creditor: alice,
                debtor: debtor,
                description: "",
                claimAmount: 1 ether,
                dueBy: block.timestamp + 1 days,
                token: address(weth),
                controller: address(0),
                feePayer: FeePayer.Creditor,
                binding: ClaimBinding.Unbound
            })
        );

        // ensure fee calculator version is not set
        assertEq(bullaClaim.getClaim(claimId__noFee).feeCalculatorId, 0);

        feeReceiverBalanceBefore = weth.balanceOf(feeReceiver);

        bullaClaim.payClaim(claimId__noFee, 1 ether);

        assertEq(weth.balanceOf(feeReceiver), feeReceiverBalanceBefore); // no fee transferred
    }
}
