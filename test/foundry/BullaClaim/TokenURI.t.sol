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

    address creditor = address(0x01);
    address debtor = address(0x02);

    function setUp() public {
        vm.label(creditor, "CREDITOR");
        vm.label(debtor, "DEBTOR");
        vm.label(alice, "ALICE");

        (bullaClaim,) = (new Deployer()).deploy_test({
            _deployer: address(this),
            _feeReceiver: address(0xFEE),
            _initialLockState: LockState.Unlocked,
            _feeBPS: 0
        });
    }

    function testTokenURIReturnsSetMetadata() public {
        string memory tokenURI = "tokenURI.com";

        vm.prank(creditor);
        uint256 claimId = bullaClaim.createClaimWithMetadata(
            CreateClaimParams({
                creditor: creditor,
                debtor: debtor,
                description: "",
                claimAmount: 1 ether,
                dueBy: block.timestamp + 1 days,
                token: address(0),
                controller: address(0),
                feePayer: FeePayer.Debtor,
                binding: ClaimBinding.Unbound
            }),
            ClaimMetadata({tokenURI: tokenURI, attachmentURI: "test1234"})
        );

        assertEq(bullaClaim.tokenURI(claimId), tokenURI);
    }

    function testNoMetadataGeneratesTokenURI() public {
        address metadataGenerator = address(new ClaimMetadataGenerator());
        bullaClaim.setClaimMetadataGenerator(metadataGenerator);

        vm.prank(creditor);
        uint256 claimId = bullaClaim.createClaim(
            CreateClaimParams({
                creditor: creditor,
                debtor: debtor,
                description: "",
                claimAmount: 1 ether,
                dueBy: block.timestamp + 1 days,
                token: address(0),
                controller: address(0),
                feePayer: FeePayer.Debtor,
                binding: ClaimBinding.Unbound
            })
        );

        Claim memory claim = bullaClaim.getClaim(claimId);

        vm.expectCall(
            metadataGenerator,
            abi.encodeWithSelector(ClaimMetadataGenerator.tokenURI.selector, claim, claimId, creditor)
        );
        string memory tokenURI = bullaClaim.tokenURI(claimId);

        assertTrue(bytes(tokenURI).length > 0);
    }

    function testRevertsIfNoMetadataGenerator() public {
        vm.prank(creditor);
        uint256 claimId = bullaClaim.createClaim(
            CreateClaimParams({
                creditor: creditor,
                debtor: debtor,
                description: "",
                claimAmount: 1 ether,
                dueBy: block.timestamp + 1 days,
                token: address(0),
                controller: address(0),
                feePayer: FeePayer.Debtor,
                binding: ClaimBinding.Unbound
            })
        );

        vm.expectRevert();
        bullaClaim.tokenURI(claimId);
    }

    function testOnlyOwnerCanSetTokenURI(address caller) public {
        vm.startPrank(caller);
        address metadataGenerator = address(new ClaimMetadataGenerator());
        vm.expectRevert("Ownable: caller is not the owner");
        bullaClaim.setClaimMetadataGenerator(metadataGenerator);
        vm.stopPrank();
    }
}
