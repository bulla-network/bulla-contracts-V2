// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import {EIP712Helper, privateKeyValidity} from "test/foundry/BullaClaim/EIP712/Utils.sol";
import {Claim, Status, ClaimBinding, CreateClaimParams, ClaimMetadata, LockState} from "contracts/types/Types.sol";
import {BullaClaim, CreateClaimApprovalType} from "contracts/BullaClaim.sol";
import {PenalizedClaim} from "contracts/mocks/PenalizedClaim.sol";
import {Deployer} from "script/Deployment.s.sol";
import {BullaClaimTestHelper} from "test/foundry/BullaClaim/BullaClaimTestHelper.sol";
import {CreateClaimParamsBuilder} from "test/foundry/BullaClaim/CreateClaimParamsBuilder.sol";
import {BullaClaimValidationLib} from "contracts/libraries/BullaClaimValidationLib.sol";

contract TestCreateClaimWithMetadata is BullaClaimTestHelper {
    uint256 creditorPK = uint256(0x01);

    address creditor = vm.addr(creditorPK);
    address debtor = address(0x02);

    uint256 userPK = uint256(0xA11c3);
    address user = vm.addr(userPK);
    address controller = address(0xb0b);

    event MetadataAdded(uint256 indexed claimId, string tokenURI, string attachmentURI);

    function setUp() public {
        bullaClaim = (new Deployer()).deploy_test({
            _deployer: address(this),
            _initialLockState: LockState.Unlocked,
            _coreProtocolFee: 0
        });
        sigHelper = new EIP712Helper(address(bullaClaim));
    }

    function testCannotCreateClaimWhenContractIsLocked() public {
        bullaClaim.setLockState(LockState.Locked);

        _permitCreateClaim({_userPK: userPK, _controller: address(this), _approvalCount: type(uint64).max});

        vm.expectRevert(BullaClaim.Locked.selector);
        _newClaim(creditor, creditor, debtor);

        vm.expectRevert(BullaClaim.Locked.selector);
        _newClaimWithMetadataFrom(user, creditor, debtor);

        bullaClaim.setLockState(LockState.NoNewClaims);

        vm.expectRevert(BullaClaim.Locked.selector);
        _newClaim(creditor, creditor, debtor);

        vm.expectRevert(BullaClaim.Locked.selector);
        _newClaimWithMetadataFrom(user, creditor, debtor);
    }

    function testCreateClaimWithMetadata() public {
        CreateClaimParams memory params =
            new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth)).build();

        vm.expectEmit(true, true, true, true);
        emit MetadataAdded(1, tokenURI, attachmentURI);

        vm.prank(creditor);
        uint256 claimId = bullaClaim.createClaimWithMetadata(
            params, ClaimMetadata({tokenURI: tokenURI, attachmentURI: attachmentURI})
        );

        (string memory _tokenURI, string memory _attachmentURI) = bullaClaim.claimMetadata(claimId);
        assertEq(_tokenURI, tokenURI);
        assertEq(_attachmentURI, attachmentURI);
        assertEq(bullaClaim.tokenURI(claimId), tokenURI);
    }

    function testCreateClaimWithMetadataFrom() public {
        _permitCreateClaim({_userPK: userPK, _controller: address(this), _approvalCount: type(uint64).max});

        vm.expectEmit(true, true, true, true);
        emit MetadataAdded(1, tokenURI, attachmentURI);
        uint256 claimId = _newClaimWithMetadataFrom(user, user, debtor);

        (string memory _tokenURI, string memory _attachmentURI) = bullaClaim.claimMetadata(claimId);
        assertEq(claimId, 1);
        assertEq(_tokenURI, tokenURI);
        assertEq(_attachmentURI, attachmentURI);
        assertEq(bullaClaim.tokenURI(claimId), tokenURI);
    }

    function testCreateClaimWithMetadataFromSpendsApproval() public {
        _permitCreateClaim({_userPK: userPK, _controller: address(this), _approvalCount: 1});

        _newClaimWithMetadataFrom(user, user, debtor);

        CreateClaimParams memory params =
            new CreateClaimParamsBuilder().withCreditor(user).withDebtor(debtor).withToken(address(weth)).build();

        vm.expectRevert(abi.encodeWithSelector(BullaClaimValidationLib.NotApproved.selector));
        bullaClaim.createClaimWithMetadataFrom(
            user, params, ClaimMetadata({tokenURI: tokenURI, attachmentURI: attachmentURI})
        );
    }

    function testCreateClaimWithMetadataFromFollowsSpec_binding() public {
        _permitCreateClaim({
            _userPK: userPK,
            _controller: address(this),
            _approvalCount: type(uint64).max,
            _approvalType: CreateClaimApprovalType.Approved,
            _isBindingAllowed: false
        });

        CreateClaimParams memory params =
            new CreateClaimParamsBuilder().withCreditor(debtor).withDebtor(user).withBinding(ClaimBinding.Bound).build();

        vm.expectRevert(abi.encodeWithSelector(BullaClaimValidationLib.CannotBindClaim.selector));
        bullaClaim.createClaimWithMetadataFrom(
            user, params, ClaimMetadata({tokenURI: tokenURI, attachmentURI: attachmentURI})
        );
    }

    function testCreateClaimWithMetadataFromFollowsSpec_creditorOnly() public {
        _permitCreateClaim({
            _userPK: userPK,
            _controller: address(this),
            _approvalCount: type(uint64).max,
            _approvalType: CreateClaimApprovalType.CreditorOnly,
            _isBindingAllowed: true
        });

        CreateClaimParams memory params = new CreateClaimParamsBuilder().withCreditor(debtor).withDebtor(user).build();

        vm.expectRevert(abi.encodeWithSelector(BullaClaimValidationLib.NotApproved.selector));
        bullaClaim.createClaimWithMetadataFrom(
            user, params, ClaimMetadata({tokenURI: tokenURI, attachmentURI: attachmentURI})
        );
    }

    function testCreateClaimWithMetadataFromFollowsSpec_debtorOnly() public {
        _permitCreateClaim({
            _userPK: userPK,
            _controller: address(this),
            _approvalCount: type(uint64).max,
            _approvalType: CreateClaimApprovalType.DebtorOnly,
            _isBindingAllowed: true
        });

        CreateClaimParams memory params =
            new CreateClaimParamsBuilder().withCreditor(user).withDebtor(debtor).withToken(address(weth)).build();

        vm.expectRevert(abi.encodeWithSelector(BullaClaimValidationLib.NotApproved.selector));
        bullaClaim.createClaimWithMetadataFrom(
            user, params, ClaimMetadata({tokenURI: tokenURI, attachmentURI: attachmentURI})
        );
    }

    function testOriginalCreditorWithMetadata() public {
        // Test with createClaimWithMetadata
        vm.startPrank(creditor);
        bullaClaim.createClaimWithMetadata(
            new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth)).build(),
            ClaimMetadata({tokenURI: tokenURI, attachmentURI: attachmentURI})
        );
        vm.stopPrank();

        _permitCreateClaim({
            _userPK: userPK,
            _controller: address(this),
            _approvalCount: type(uint64).max,
            _approvalType: CreateClaimApprovalType.Approved,
            _isBindingAllowed: false
        });

        uint256 claimId3 = bullaClaim.createClaimFrom(
            user, new CreateClaimParamsBuilder().withCreditor(user).withDebtor(debtor).withToken(address(weth)).build()
        );

        Claim memory claim3 = bullaClaim.getClaim(claimId3);
        assertEq(claim3.originalCreditor, user);
    }
}
