// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.14;

import {DSTestPlus} from "solmate/test/utils/DSTestPlus.sol";
import {BullaClaim} from "contracts/BullaClaim.sol";
import {Claim, Status, ClaimBinding, LockState, CreateClaimParams} from "contracts/types/Types.sol";
import {Deployer} from "script/Deployment.s.sol";
import {CreateClaimParamsBuilder} from "test/foundry/BullaClaim/CreateClaimParamsBuilder.sol";

// run the solmate ERC721 spec against bulla claim to ensure functionality

contract ERC721Test is DSTestPlus {
    BullaClaim token;

    address creditor = address(0x01);
    address debtor = address(0x02);

    function setUp() public {
        token = (new Deployer()).deploy_test({_deployer: address(this), _initialLockState: LockState.Unlocked});
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
        token.approve(creditor, tokenId);

        assertEq(token.getApproved(tokenId), creditor);
    }

    function testApproveAll() public {
        token.setApprovalForAll(address(0xBEEF), true);

        assertTrue(token.isApprovedForAll(address(this), address(0xBEEF)));
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

    function testTransferFromApproveAll() public {
        address from = creditor;
        uint256 tokenId = _mint();

        hevm.prank(from);
        token.setApprovalForAll(address(this), true);

        token.transferFrom(from, address(0xBEEF), tokenId);

        assertEq(token.getApproved(tokenId), address(0));
        assertEq(token.ownerOf(tokenId), address(0xBEEF));
        assertEq(token.balanceOf(address(0xBEEF)), 1);
        assertEq(token.balanceOf(from), 0);
    }

    function testSafeTransferFromToEOA() public {
        address from = creditor;
        uint256 tokenId = _mint();

        hevm.prank(from);
        token.setApprovalForAll(address(this), true);

        token.safeTransferFrom(from, address(0xBEEF), tokenId);

        assertEq(token.getApproved(tokenId), address(0));
        assertEq(token.ownerOf(tokenId), address(0xBEEF));
        assertEq(token.balanceOf(address(0xBEEF)), 1);
        assertEq(token.balanceOf(from), 0);
    }

    function testFailMintToZero() public {
        token.createClaim(new CreateClaimParamsBuilder().withCreditor(address(0)).withDebtor(debtor).build());
    }

    function testFailApproveUnMinted() public {
        token.approve(address(0xBEEF), 1);
    }

    function testFailApproveUnAuthorized() public {
        uint256 tokenId = _mint();

        token.approve(address(0xBEEF), tokenId);
    }

    function testFailTransferFromUnOwned() public {
        token.transferFrom(address(0xFEED), address(0xBEEF), 1);
    }

    function testFailTransferFromWrongFrom() public {
        uint256 tokenId = _mint();

        token.transferFrom(address(0xFEED), address(0xBEEF), tokenId);
    }

    function testFailTransferFromToZero() public {
        uint256 tokenId = _mint();

        token.transferFrom(address(this), address(0), tokenId);
    }

    function testFailTransferFromNotOwner() public {
        uint256 tokenId = _mint();

        token.transferFrom(address(0xFEED), address(0xBEEF), tokenId);
    }

    function testFailBalanceOfZeroAddress() public view {
        token.balanceOf(address(0));
    }

    function testFailOwnerOfUnminted() public view {
        token.ownerOf(1337);
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
        token.approve(to, tokenId);

        assertEq(token.getApproved(tokenId), to);
    }

    function testApproveAll(address to, bool approved) public {
        token.setApprovalForAll(to, approved);

        assertBoolEq(token.isApprovedForAll(address(this), to), approved);
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

    function testTransferFromApproveAll(address to) public {
        address from = address(0xABCD);

        if (to == address(0) || to == from) {
            to = address(0xBEEF);
        }

        uint256 tokenId = _mint(from, from);

        hevm.prank(from);
        token.setApprovalForAll(address(this), true);

        token.transferFrom(from, to, tokenId);

        assertEq(token.getApproved(tokenId), address(0));
        assertEq(token.ownerOf(tokenId), to);
        assertEq(token.balanceOf(to), 1);
        assertEq(token.balanceOf(from), 0);
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
        token.setApprovalForAll(address(this), true);

        token.safeTransferFrom(from, to, tokenId);

        assertEq(token.getApproved(tokenId), address(0));
        assertEq(token.ownerOf(tokenId), to);
        assertEq(token.balanceOf(to), 1);
        assertEq(token.balanceOf(from), 0);
    }
}
