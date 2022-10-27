// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import {EIP712Helper, privateKeyValidity} from "test/foundry/BullaClaim/EIP712/Utils.sol";
import {
    Signature,
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

contract CreateClaimTest is Test {
    BullaClaim public bullaClaim;
    EIP712Helper public sigHelper;
    BullaFeeCalculator feeCalculator;

    uint256 creditorPK = uint256(0x01);

    address creditor = vm.addr(creditorPK);
    address debtor = address(0x02);
    address feeReceiver = address(0xFEE);

    uint256 ownerPK = uint256(0xA11c3);
    address owner = vm.addr(ownerPK);
    address operator = address(0xb0b);

    string tokenURI = "https://mytokenURI.com/1234";
    string attachmentURI = "https://coolcatpics.com/1234";

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

    function _newClaim(address _creditor, address _debtor) private returns (uint256 claimId) {
        claimId = bullaClaim.createClaimWithMetadata(
            CreateClaimParams({
                creditor: _creditor,
                debtor: _debtor,
                description: "",
                claimAmount: 1 ether,
                dueBy: block.timestamp + 1 days,
                token: address(0),
                delegator: address(0),
                feePayer: FeePayer.Debtor,
                binding: ClaimBinding.Unbound
            }),
            ClaimMetadata({tokenURI: tokenURI, attachmentURI: attachmentURI})
        );
    }

    function _newClaimFrom(address _from, address _creditor, address _debtor) private returns (uint256 claimId) {
        claimId = bullaClaim.createClaimWithMetadataFrom(
            _from,
            CreateClaimParams({
                creditor: _creditor,
                debtor: _debtor,
                description: "",
                claimAmount: 1 ether,
                dueBy: block.timestamp + 1 days,
                token: address(0),
                delegator: address(0),
                feePayer: FeePayer.Debtor,
                binding: ClaimBinding.Unbound
            }),
            ClaimMetadata({tokenURI: tokenURI, attachmentURI: attachmentURI})
        );
    }

    function _permitCreateClaim(
        uint256 _ownerPK,
        address _operator,
        uint64 _approvalCount,
        CreateClaimApprovalType _approvalType,
        bool _isBindingAllowed
    ) private {
        Signature memory sig = sigHelper.signCreateClaimPermit(
            _ownerPK, vm.addr(_ownerPK), _operator, _approvalType, _approvalCount, _isBindingAllowed
        );
        bullaClaim.permitCreateClaim(
            vm.addr(_ownerPK), _operator, _approvalType, _approvalCount, _isBindingAllowed, sig
        );
    }

    function _permitCreateClaim(uint256 _ownerPK, address _operator, uint64 _approvalCount) private {
        _permitCreateClaim(_ownerPK, _operator, _approvalCount, CreateClaimApprovalType.Approved, true);
    }

    function testCannotCreateClaimWhenContractIsLocked() public {
        bullaClaim.setLockState(LockState.Locked);

        _permitCreateClaim({_ownerPK: ownerPK, _operator: address(this), _approvalCount: type(uint64).max});

        vm.expectRevert(BullaClaim.Locked.selector);
        _newClaim(creditor, debtor);

        vm.expectRevert(BullaClaim.Locked.selector);
        _newClaimFrom(owner, creditor, debtor);

        bullaClaim.setLockState(LockState.NoNewClaims);

        vm.expectRevert(BullaClaim.Locked.selector);
        _newClaim(creditor, debtor);

        vm.expectRevert(BullaClaim.Locked.selector);
        _newClaimFrom(owner, creditor, debtor);
    }

    function testCreateClaimWithMetadata() public {
        vm.expectEmit(true, true, true, true);
        emit MetadataAdded(1, tokenURI, attachmentURI);
        uint256 claimId = _newClaim(creditor, debtor);

        (string memory _tokenURI, string memory _attachmentURI) = bullaClaim.claimMetadata(claimId);
        assertEq(_tokenURI, tokenURI);
        assertEq(_attachmentURI, attachmentURI);
        assertEq(bullaClaim.tokenURI(claimId), tokenURI);
    }

    function testCreateClaimWithMetadataFrom() public {
        _permitCreateClaim({_ownerPK: ownerPK, _operator: address(this), _approvalCount: type(uint64).max});

        vm.expectEmit(true, true, true, true);
        emit MetadataAdded(1, tokenURI, attachmentURI);
        uint256 claimId = _newClaimFrom(owner, owner, debtor);

        (string memory _tokenURI, string memory _attachmentURI) = bullaClaim.claimMetadata(claimId);
        assertEq(claimId, 1);
        assertEq(_tokenURI, tokenURI);
        assertEq(_attachmentURI, attachmentURI);
        assertEq(bullaClaim.tokenURI(claimId), tokenURI);
    }

    function testCreateClaimWithMetadataFromSpendsApproval() public {
        _permitCreateClaim({_ownerPK: ownerPK, _operator: address(this), _approvalCount: 1});

        _newClaimFrom(owner, owner, debtor);

        vm.expectRevert(abi.encodeWithSelector(BullaClaim.NotApproved.selector, address(this)));
        _newClaimFrom(owner, owner, debtor);
    }

    function testCreateClaimWithMetadataFromFollowsSpec_binding() public {
        _permitCreateClaim({
            _ownerPK: ownerPK,
            _operator: address(this),
            _approvalCount: type(uint64).max,
            _approvalType: CreateClaimApprovalType.Approved,
            _isBindingAllowed: false
        });

        vm.expectRevert(abi.encodeWithSelector(BullaClaim.Unauthorized.selector));
        bullaClaim.createClaimWithMetadataFrom(
            owner,
            CreateClaimParams({
                creditor: debtor,
                debtor: owner,
                description: "",
                claimAmount: 1 ether,
                dueBy: block.timestamp + 1 days,
                token: address(0),
                delegator: address(0),
                feePayer: FeePayer.Debtor,
                binding: ClaimBinding.Bound
            }),
            ClaimMetadata({tokenURI: tokenURI, attachmentURI: attachmentURI})
        );
    }

    function testCreateClaimWithMetadataFromFollowsSpec_creditorOnly() public {
        _permitCreateClaim({
            _ownerPK: ownerPK,
            _operator: address(this),
            _approvalCount: type(uint64).max,
            _approvalType: CreateClaimApprovalType.CreditorOnly,
            _isBindingAllowed: true
        });

        vm.expectRevert(abi.encodeWithSelector(BullaClaim.Unauthorized.selector));
        bullaClaim.createClaimWithMetadataFrom(
            owner,
            CreateClaimParams({
                creditor: debtor,
                debtor: owner,
                description: "",
                claimAmount: 1 ether,
                dueBy: block.timestamp + 1 days,
                token: address(0),
                delegator: address(0),
                feePayer: FeePayer.Debtor,
                binding: ClaimBinding.Unbound
            }),
            ClaimMetadata({tokenURI: tokenURI, attachmentURI: attachmentURI})
        );
    }

    function testCreateClaimWithMetadataFromFollowsSpec_debtorOnly() public {
        _permitCreateClaim({
            _ownerPK: ownerPK,
            _operator: address(this),
            _approvalCount: type(uint64).max,
            _approvalType: CreateClaimApprovalType.DebtorOnly,
            _isBindingAllowed: true
        });

        vm.expectRevert(abi.encodeWithSelector(BullaClaim.Unauthorized.selector));
        bullaClaim.createClaimWithMetadataFrom(
            owner,
            CreateClaimParams({
                creditor: owner,
                debtor: creditor,
                description: "",
                claimAmount: 1 ether,
                dueBy: block.timestamp + 1 days,
                token: address(0),
                delegator: address(0),
                feePayer: FeePayer.Debtor,
                binding: ClaimBinding.Unbound
            }),
            ClaimMetadata({tokenURI: tokenURI, attachmentURI: attachmentURI})
        );
    }
}
