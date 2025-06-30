// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.30;

import "forge-std/Vm.sol";
import "contracts/types/Types.sol";
import {WETH} from "contracts/mocks/weth.sol";
import {EIP712Helper} from "test/foundry/BullaClaim/EIP712/Utils.sol";
import {BullaClaim} from "contracts/BullaClaim.sol";
import {Deployer} from "script/Deployment.s.sol";
import {BullaClaimTestHelper} from "test/foundry/BullaClaim/BullaClaimTestHelper.sol";
import {CreateClaimParamsBuilder} from "test/foundry/BullaClaim/CreateClaimParamsBuilder.sol";
import {BullaClaimValidationLib} from "contracts/libraries/BullaClaimValidationLib.sol";
import {IBullaClaim} from "contracts/interfaces/IBullaClaim.sol";

/// @notice SPEC:
/// A function can call this internal function to verify and "spend" `from`'s approval of `controller` to pay a claim under the following circumstances:
///     SA1. The `approvalType` is not `Unapproved` -> otherwise: reverts
///     SA2. The contract LockStatus is not `Locked` -> otherwise: reverts
///
///     When the `approvalType` is `IsApprovedForSpecific`, then `controller` must be approved to pay that claim meaning:
///         AS1: `from` has approved payment for the `claimId` agrument -> otherwise: reverts
///         AS2: `from` has approved payment for at least the `amount` agrument -> otherwise: reverts
///         AS3: `from`'s approval has not expired, meaning:
///             AS3.1: If the controller has an "controller" expirary, then the controller expirary must be greater than the current block timestamp -> otherwise: reverts
///             AS3.2: If the controller does not have an controller expirary and instead has a claim-specific expirary,
///                 then the claim-specific expirary must be greater than the current block timestamp -> otherwise: reverts
///
///         AS.RES1: If the `amount` agrument == the pre-approved amount on the permission, spend the permission -> otherwise: decrement the approved amount by `amount`
///
///     If the `approvalType` is `IsApprovedForAll`, then `controller` must be approved to pay, meaning:
///         AA1: `from`'s approval of `controller` has not expired -> otherwise: reverts
///
///         AA.RES1: This function allows execution to continue - (no storage needs to be updated)
contract TestPayClaimFrom is BullaClaimTestHelper {
    uint256 OCTOBER_28TH_2022 = 1666980688;
    uint256 OCTOBER_23RD_2022 = 1666560688;

    uint256 userPK = uint256(0xA11c3);
    uint256 user2PK = uint256(0xB11c3);
    address user = vm.addr(userPK);
    address controller = address(0xb0b);
    address user2 = vm.addr(user2PK);

    function setUp() public {
        weth = new WETH();

        vm.label(address(this), "TEST_CONTRACT");

        vm.label(user, "user");
        vm.label(controller, "controller");
        vm.label(user2, "USER2");

        bullaClaim = (new Deployer()).deploy_test(address(this), LockState.Unlocked, 0);
        sigHelper = new EIP712Helper(address(bullaClaim));
        approvalRegistry = bullaClaim.approvalRegistry();

        weth.transferFrom(address(this), user, 1000 ether);
        weth.transferFrom(address(this), controller, 1000 ether);
        weth.transferFrom(address(this), user2, 1000 ether);

        _permitCreateClaim(userPK, controller, 1);
        _permitCreateClaim(user2PK, controller, 1);
    }

    /*///////////////////////////////////////////////////////////////
                        PAY CLAIM FROM TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice SPEC.SA1
    function testCannotPayClaimFromIfUnapproved() public {
        uint256 claimId = _newClaim({_creator: user2, _creditor: user2, _debtor: user});

        vm.prank(user);
        weth.approve(address(bullaClaim), 1 ether);

        // user 2 tries to pull user's funds
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(IBullaClaim.MustBeControlledClaim.selector));
        bullaClaim.payClaimFrom(user, claimId, 1 ether);
    }

    //// CONTRACT LOCK ////
    /// @notice SPEC.SA2
    function testCanPayClaimFromWhenPartiallyLocked() public {
        vm.startPrank(controller);
        uint256 claimId = _newClaimFrom({_from: user2, _creditor: user2, _debtor: user});
        vm.stopPrank();

        bullaClaim.setLockState(LockState.NoNewClaims);

        vm.prank(user);
        weth.approve(address(bullaClaim), 1 ether);

        vm.prank(controller);
        bullaClaim.payClaimFrom(user, claimId, 1 ether);
    }

    /// @notice SPEC.SA2
    function testCannotPayClaimFromWhenLocked() public {
        vm.startPrank(controller);
        uint256 claimId = _newClaimFrom({_from: user2, _creditor: user2, _debtor: user});
        vm.stopPrank();

        bullaClaim.setLockState(LockState.Locked);

        vm.prank(user);
        weth.approve(address(bullaClaim), 1 ether);

        vm.prank(controller);
        vm.expectRevert(IBullaClaim.Locked.selector);
        bullaClaim.payClaimFrom(user, claimId, 1 ether);
    }

    /// a strange side effect of using the native token is that controller must send the ether value in the call
    function testPayClaimFromWithNativeToken() public {
        vm.deal(controller, 1 ether);

        CreateClaimParams memory params = new CreateClaimParamsBuilder().withCreditor(user2).withDebtor(user)
            .withPayerReceivesClaimOnPayment(true).build();

        vm.prank(controller);
        uint256 claimId = bullaClaim.createClaimFrom(user2, params);

        vm.prank(controller);
        bullaClaim.payClaimFrom{value: 1 ether}(user, claimId, 1 ether);
    }
}
