// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import {EIP712Helper, privateKeyValidity} from "test/foundry/BullaClaim/EIP712/Utils.sol";
import {
    Claim,
    Status,
    ClaimBinding,
    FeePayer,
    CreateClaimParams,
    ClaimMetadata,
    LockState
} from "contracts/types/Types.sol";
import {BullaFeeCalculator} from "contracts/BullaFeeCalculator.sol";
import {BullaClaim, CreateClaimApprovalType} from "contracts/BullaClaim.sol";
import {PenalizedClaim} from "contracts/mocks/PenalizedClaim.sol";
import {Deployer} from "script/Deployment.s.sol";
import {BullaClaimTestHelper} from "test/foundry/BullaClaim/BullaClaimTestHelper.sol";

contract TestCreateClaimWithMetadata is BullaClaimTestHelper {
    BullaFeeCalculator feeCalculator;

    uint256 creditorPK = uint256(0x01);

    address creditor = vm.addr(creditorPK);
    address debtor = address(0x02);
    address feeReceiver = address(0xFEE);

    uint256 userPK = uint256(0xA11c3);
    address user = vm.addr(userPK);
    address operator = address(0xb0b);

    event MetadataAdded(uint256 indexed claimId, string tokenURI, string attachmentURI);

    event ClaimCreated(
        uint256 indexed claimId,
        address caller,
        address indexed creditor,
        address indexed debtor,
        string description,
        uint256 claimAmount,
        address claimToken,
        ClaimBinding binding,
        uint256 dueBy,
        uint256 feeCalculatorId
    );

    function setUp() public {
        (bullaClaim,) = (new Deployer()).deploy_test({
            _deployer: address(this),
            _feeReceiver: address(0xfee),
            _initialLockState: LockState.Unlocked,
            _feeBPS: 0
        });
        sigHelper = new EIP712Helper(address(bullaClaim));
    }

    function testCannotCreateClaimWhenContractIsLocked() public {
        bullaClaim.setLockState(LockState.Locked);

        _permitCreateClaim({_userPK: userPK, _operator: address(this), _approvalCount: type(uint64).max});

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
        vm.expectEmit(true, true, true, true);
        emit MetadataAdded(1, tokenURI, attachmentURI);
        vm.prank(creditor);
        uint256 claimId = bullaClaim.createClaimWithMetadata(
            CreateClaimParams({
                creditor: creditor,
                debtor: debtor,
                description: "",
                claimAmount: 1 ether,
                dueBy: block.timestamp + 1 days,
                token: address(weth),
                controller: address(0),
                feePayer: FeePayer.Debtor,
                binding: ClaimBinding.Unbound,
                payerReceivesClaimOnPayment: true
            }),
            ClaimMetadata({tokenURI: tokenURI, attachmentURI: attachmentURI})
        );

        (string memory _tokenURI, string memory _attachmentURI) = bullaClaim.claimMetadata(claimId);
        assertEq(_tokenURI, tokenURI);
        assertEq(_attachmentURI, attachmentURI);
        assertEq(bullaClaim.tokenURI(claimId), tokenURI);
    }

    function testCreateClaimWithMetadataFrom() public {
        _permitCreateClaim({_userPK: userPK, _operator: address(this), _approvalCount: type(uint64).max});

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
        _permitCreateClaim({_userPK: userPK, _operator: address(this), _approvalCount: 1});

        _newClaimWithMetadataFrom(user, user, debtor);

        vm.expectRevert(abi.encodeWithSelector(BullaClaim.NotApproved.selector));
        _newClaimWithMetadataFrom(user, user, debtor);
    }

    function testCreateClaimWithMetadataFromFollowsSpec_binding() public {
        _permitCreateClaim({
            _userPK: userPK,
            _operator: address(this),
            _approvalCount: type(uint64).max,
            _approvalType: CreateClaimApprovalType.Approved,
            _isBindingAllowed: false
        });

        vm.expectRevert(abi.encodeWithSelector(BullaClaim.CannotBindClaim.selector));
        bullaClaim.createClaimWithMetadataFrom(
            user,
            CreateClaimParams({
                creditor: debtor,
                debtor: user,
                description: "",
                claimAmount: 1 ether,
                dueBy: block.timestamp + 1 days,
                token: address(0),
                controller: address(0),
                feePayer: FeePayer.Debtor,
                binding: ClaimBinding.Bound,
                payerReceivesClaimOnPayment: true
            }),
            ClaimMetadata({tokenURI: tokenURI, attachmentURI: attachmentURI})
        );
    }

    function testCreateClaimWithMetadataFromFollowsSpec_creditorOnly() public {
        _permitCreateClaim({
            _userPK: userPK,
            _operator: address(this),
            _approvalCount: type(uint64).max,
            _approvalType: CreateClaimApprovalType.CreditorOnly,
            _isBindingAllowed: true
        });

        vm.expectRevert(abi.encodeWithSelector(BullaClaim.NotApproved.selector));
        bullaClaim.createClaimWithMetadataFrom(
            user,
            CreateClaimParams({
                creditor: debtor,
                debtor: user,
                description: "",
                claimAmount: 1 ether,
                dueBy: block.timestamp + 1 days,
                token: address(0),
                controller: address(0),
                feePayer: FeePayer.Debtor,
                binding: ClaimBinding.Unbound,
                payerReceivesClaimOnPayment: true
            }),
            ClaimMetadata({tokenURI: tokenURI, attachmentURI: attachmentURI})
        );
    }

    function testCreateClaimWithMetadataFromFollowsSpec_debtorOnly() public {
        _permitCreateClaim({
            _userPK: userPK,
            _operator: address(this),
            _approvalCount: type(uint64).max,
            _approvalType: CreateClaimApprovalType.DebtorOnly,
            _isBindingAllowed: true
        });

        vm.expectRevert(abi.encodeWithSelector(BullaClaim.NotApproved.selector));
        bullaClaim.createClaimWithMetadataFrom(
            user,
            CreateClaimParams({
                creditor: user,
                debtor: creditor,
                description: "",
                claimAmount: 1 ether,
                dueBy: block.timestamp + 1 days,
                token: address(0),
                controller: address(0),
                feePayer: FeePayer.Debtor,
                binding: ClaimBinding.Unbound,
                payerReceivesClaimOnPayment: true
            }),
            ClaimMetadata({tokenURI: tokenURI, attachmentURI: attachmentURI})
        );
    }
}
