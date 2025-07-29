// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.30;

import {DSTestPlus} from "solmate/test/utils/DSTestPlus.sol";
import {BullaClaimV2} from "contracts/BullaClaimV2.sol";
import {IBullaClaimV2} from "contracts/interfaces/IBullaClaimV2.sol";
import {Claim, Status, ClaimBinding, LockState, CreateClaimParams} from "contracts/types/Types.sol";
import {DeployContracts} from "script/DeployContracts.s.sol";
import {CreateClaimParamsBuilder} from "test/foundry/BullaClaim/CreateClaimParamsBuilder.sol";
import {BullaClaimValidationLib} from "src/libraries/BullaClaimValidationLib.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

// run the solmate ERC721 spec against bulla claim to ensure functionality

contract ERC721Test is DSTestPlus {
    BullaClaimV2 token;

    address creditor = address(0x01);
    address debtor = address(0x02);

    function setUp() public {
        DeployContracts.DeploymentResult memory deploymentResult =
            (new DeployContracts()).deployForTest(address(this), LockState.Unlocked, 0, 0, 0, address(this));
        token = BullaClaimV2(deploymentResult.bullaClaim);
    }

    function _mint() private returns (uint256 claimId) {
        hevm.startPrank(creditor);
        claimId = token.createClaim(new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor).build());
        hevm.stopPrank();
    }

    function _mint(address _creator, address _creditor) private returns (uint256 claimId) {
        hevm.startPrank(_creator);
        claimId = token.createClaim(new CreateClaimParamsBuilder().withCreditor(_creditor).withDebtor(debtor).build());
        hevm.stopPrank();
    }

    function testMint() public {
        uint256 tokenId = _mint();

        assertEq(token.balanceOf(creditor), 1);
        assertEq(token.ownerOf(tokenId), creditor);
    }

    function testApprove() public {
        uint256 tokenId = _mint();

        hevm.prank(creditor);
        // OpenZeppelin v5 allows self-approval and stores it
        token.approve(creditor, tokenId);
        // Check that the approval was actually set to the owner
        assertEq(token.getApproved(tokenId), creditor);
    }

    function testApproveAll() public {
        hevm.expectRevert(IBullaClaimV2.NotSupported.selector);
        token.setApprovalForAll(address(0xBEEF), true);
    }

    function testTransferFrom() public {
        address from = address(creditor);

        uint256 tokenId = _mint();

        hevm.prank(from);
        token.approve(address(this), tokenId);

        token.transferFrom(from, address(0xBEEF), tokenId);

        assertEq(token.getApproved(tokenId), address(0));
        assertEq(token.ownerOf(tokenId), address(0xBEEF));
        assertEq(token.balanceOf(address(0xBEEF)), 1);
        assertEq(token.balanceOf(from), 0);
    }

    function testTransferFromSelf() public {
        uint256 tokenId = _mint();

        hevm.prank(creditor);
        token.transferFrom(address(creditor), address(0xBEEF), tokenId);

        assertEq(token.getApproved(tokenId), address(0));
        assertEq(token.ownerOf(tokenId), address(0xBEEF));
        assertEq(token.balanceOf(address(0xBEEF)), 1);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function testSafeTransferFromToEOA() public {
        address from = creditor;
        uint256 tokenId = _mint();

        hevm.prank(from);
        token.approve(address(this), tokenId);

        token.safeTransferFrom(from, address(0xBEEF), tokenId);

        assertEq(token.getApproved(tokenId), address(0));
        assertEq(token.ownerOf(tokenId), address(0xBEEF));
        assertEq(token.balanceOf(address(0xBEEF)), 1);
        assertEq(token.balanceOf(from), 0);
    }

    function test_RevertWhen_MintToZero() public {
        CreateClaimParams memory params =
            new CreateClaimParamsBuilder().withCreditor(address(0)).withDebtor(debtor).build();

        hevm.expectRevert(BullaClaimValidationLib.NotCreditorOrDebtor.selector);
        token.createClaim(params);
    }

    function test_RevertWhen_ApproveUnMinted() public {
        hevm.expectRevert(IBullaClaimV2.NotMinted.selector);
        token.approve(address(0xBEEF), 1);
    }

    function test_RevertWhen_ApproveUnAuthorized() public {
        uint256 tokenId = _mint();

        hevm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidApprover.selector, address(this)));
        token.approve(address(0xBEEF), tokenId);
    }

    function test_RevertWhen_TransferFromUnOwned() public {
        hevm.expectRevert(IBullaClaimV2.NotMinted.selector);
        token.transferFrom(address(0xFEED), address(0xBEEF), 1);
    }

    function test_RevertWhen_TransferFromWrongFrom() public {
        uint256 tokenId = _mint();

        hevm.expectRevert(
            abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, address(this), tokenId)
        );
        token.transferFrom(address(0xFEED), address(0xBEEF), tokenId);
    }

    function test_RevertWhen_TransferFromToZero() public {
        uint256 tokenId = _mint();

        hevm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(0)));
        token.transferFrom(address(this), address(0), tokenId);
    }

    function test_RevertWhen_TransferFromNotOwner() public {
        uint256 tokenId = _mint();

        hevm.expectRevert(
            abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, address(this), tokenId)
        );
        token.transferFrom(address(0xFEED), address(0xBEEF), tokenId);
    }

    function test_RevertWhen_BalanceOfZeroAddress() public {
        hevm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidOwner.selector, address(0)));
        token.balanceOf(address(0));
    }

    function test_RevertWhen_OwnerOfUnminted() public {
        // BullaClaim returns address(0) for unminted tokens instead of reverting
        assertEq(token.ownerOf(1337), address(0));
    }

    function testMint(address to) public {
        if (to == address(0)) {
            to = address(0xBEEF);
        }

        uint256 tokenId = _mint(to, to);

        assertEq(token.balanceOf(to), 1);
        assertEq(token.ownerOf(tokenId), to);
    }

    function testApprove(address to) public {
        if (to == address(0)) {
            to = address(0xBEEF);
        }
        uint256 tokenId = _mint(to, to);

        hevm.prank(to);
        // OpenZeppelin v5 allows self-approval and stores it
        token.approve(to, tokenId);
        // Check that the approval was actually set to the owner
        assertEq(token.getApproved(tokenId), to);
    }

    function testTransferFrom(address to) public {
        address from = address(0xABCD);

        if (to == address(0) || to == from) {
            to = address(0xBEEF);
        }

        uint256 tokenId = _mint(from, from);

        hevm.prank(from);
        token.approve(address(this), tokenId);

        token.transferFrom(from, to, tokenId);

        assertEq(token.getApproved(tokenId), address(0));
        assertEq(token.ownerOf(tokenId), to);
        assertEq(token.balanceOf(to), 1);
        assertEq(token.balanceOf(from), 0);
    }

    function testTransferFromSelf(address to) public {
        if (to == address(0) || to == address(this)) {
            to = address(0xBEEF);
        }

        uint256 tokenId = _mint(address(this), address(this));

        token.transferFrom(address(this), to, tokenId);

        assertEq(token.getApproved(tokenId), address(0));
        assertEq(token.ownerOf(tokenId), to);
        assertEq(token.balanceOf(to), 1);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function testSafeTransferFromToEOA(address to) public {
        address from = address(0xABCD);

        if (to == address(0) || to == from) {
            to = address(0xBEEF);
        }

        if (uint256(uint160(to)) <= 18 || to.code.length > 0) {
            return;
        }

        uint256 tokenId = _mint(from, from);

        hevm.prank(from);
        token.approve(address(this), tokenId);

        token.safeTransferFrom(from, to, tokenId);

        assertEq(token.getApproved(tokenId), address(0));
        assertEq(token.ownerOf(tokenId), to);
        assertEq(token.balanceOf(to), 1);
        assertEq(token.balanceOf(from), 0);
    }
}
