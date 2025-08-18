// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import {WETH} from "contracts/mocks/weth.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC20PermitMock} from "contracts/mocks/ERC20PermitMock.sol";
import {
    Claim,
    Status,
    ClaimBinding,
    CreateClaimParams,
    LockState,
    ClaimMetadata,
    CreateClaimApprovalType
} from "contracts/types/Types.sol";
import {BullaClaimV2} from "contracts/BullaClaimV2.sol";
import {DeployContracts} from "script/DeployContracts.s.sol";
import {BullaClaimTestHelper, EIP712Helper} from "test/foundry/BullaClaim/BullaClaimTestHelper.sol";
import {CreateClaimParamsBuilder} from "test/foundry/BullaClaim/CreateClaimParamsBuilder.sol";

contract TestBatchFunctionality is BullaClaimTestHelper {
    address creditor = address(0x01);
    address debtor = address(0x02);
    address charlie = address(0x03);
    address alice = address(0x04);

    ERC20PermitMock public permitToken;

    function setUp() public {
        weth = new WETH();
        permitToken = new ERC20PermitMock("PermitToken", "PT", address(this), 1000000 ether);

        vm.label(address(this), "TEST_CONTRACT");
        vm.label(creditor, "CREDITOR");
        vm.label(debtor, "DEBTOR");
        vm.label(charlie, "CHARLIE");
        vm.label(alice, "ALICE");

        DeployContracts.DeploymentResult memory deploymentResult =
            (new DeployContracts()).deployForTest(address(this), LockState.Unlocked, 0, 0, 0, address(this));
        bullaClaim = BullaClaimV2(deploymentResult.bullaClaim);
        sigHelper = new EIP712Helper(address(bullaClaim));
        approvalRegistry = bullaClaim.approvalRegistry();

        // Setup token balances
        weth.transferFrom(address(this), creditor, 10000 ether);
        weth.transferFrom(address(this), debtor, 10000 ether);
        weth.transferFrom(address(this), charlie, 10000 ether);
        weth.transferFrom(address(this), alice, 10000 ether);

        permitToken.transfer(creditor, 10000 ether);
        permitToken.transfer(debtor, 10000 ether);
        permitToken.transfer(charlie, 10000 ether);
        permitToken.transfer(alice, 10000 ether);

        // Setup ETH balances
        vm.deal(creditor, 10000 ether);
        vm.deal(debtor, 10000 ether);
        vm.deal(charlie, 10000 ether);
        vm.deal(alice, 10000 ether);
    }

    /*///////////////////// CORE BATCH FUNCTIONALITY TESTS /////////////////////*/

    function testBatch_EmptyArray() public {
        bytes[] memory calls = new bytes[](0);

        // Should not revert with empty array
        bullaClaim.batch(calls, true);
        bullaClaim.batch(calls, false);
    }

    function testBatch_SingleOperation() public {
        bytes[] memory calls = new bytes[](1);

        // Create a single claim via batch
        calls[0] = abi.encodeCall(
            BullaClaimV2.createClaim, (new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor).build())
        );

        vm.prank(creditor);
        bullaClaim.batch(calls, true);

        // Verify claim was created
        Claim memory claim = bullaClaim.getClaim(0);
        assertEq(claim.originalCreditor, creditor);
        assertEq(claim.debtor, debtor);
    }

    function testBatch_RevertOnFail_True() public {
        bytes[] memory calls = new bytes[](3);

        // First call succeeds
        calls[0] = abi.encodeCall(
            BullaClaimV2.createClaim, (new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor).build())
        );

        // Second call fails (invalid claim amount)
        calls[1] = abi.encodeCall(
            BullaClaimV2.createClaim,
            (new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor).withClaimAmount(0).build())
        );

        // Third call would succeed but won't be reached
        calls[2] = abi.encodeCall(
            BullaClaimV2.createClaim,
            (new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(charlie).build())
        );

        vm.prank(creditor);
        vm.expectRevert("Transaction reverted silently");
        bullaClaim.batch(calls, true);

        // Verify no claims were created due to revert
        assertEq(bullaClaim.currentClaimId(), 0);
    }

    /*///////////////////// BATCH CREATE CLAIM TESTS /////////////////////*/

    function testBatch_CreateClaimsWithMetadata() public {
        ClaimMetadata memory metadata1 =
            ClaimMetadata({tokenURI: "https://example.com/1", attachmentURI: "https://attachment.com/1"});

        ClaimMetadata memory metadata2 =
            ClaimMetadata({tokenURI: "https://example.com/2", attachmentURI: "https://attachment.com/2"});

        bytes[] memory calls = new bytes[](2);

        calls[0] = abi.encodeCall(
            BullaClaimV2.createClaimWithMetadata,
            (new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor).build(), metadata1)
        );
        calls[1] = abi.encodeCall(
            BullaClaimV2.createClaimWithMetadata,
            (new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(charlie).build(), metadata2)
        );

        vm.prank(creditor);
        bullaClaim.batch(calls, true);

        // Verify metadata was set
        (string memory tokenURI1, string memory attachmentURI1) = bullaClaim.claimMetadata(0);
        (string memory tokenURI2, string memory attachmentURI2) = bullaClaim.claimMetadata(1);

        assertEq(tokenURI1, "https://example.com/1");
        assertEq(attachmentURI1, "https://attachment.com/1");
        assertEq(tokenURI2, "https://example.com/2");
        assertEq(attachmentURI2, "https://attachment.com/2");
    }

    function testBatch_CreateClaimFrom_Delegated() public {
        uint256 userPK = 12345;
        address user = vm.addr(userPK);

        // Give permission for this contract to create claims on behalf of user
        _permitCreateClaim(userPK, address(this), 3);

        bytes[] memory calls = new bytes[](2);

        calls[0] = abi.encodeCall(
            BullaClaimV2.createClaimFrom,
            (user, new CreateClaimParamsBuilder().withCreditor(user).withDebtor(debtor).build())
        );
        calls[1] = abi.encodeCall(
            BullaClaimV2.createClaimFrom,
            (user, new CreateClaimParamsBuilder().withCreditor(user).withDebtor(charlie).build())
        );

        bullaClaim.batch(calls, true);

        // Verify claims were created with user as creditor
        Claim memory claim1 = bullaClaim.getClaim(0);
        Claim memory claim2 = bullaClaim.getClaim(1);

        assertEq(claim1.originalCreditor, user);
        assertEq(claim1.originalCreditor, user);
        assertEq(bullaClaim.ownerOf(0), user);
        assertEq(bullaClaim.ownerOf(1), user);
    }

    /*///////////////////// BATCH PAY CLAIM TESTS /////////////////////*/

    function testBatch_PayMultipleClaims_ERC20() public {
        // Create claims first
        uint256 claimId1 = _newClaim(creditor, creditor, debtor);
        uint256 claimId2 = _newClaim(creditor, creditor, debtor);
        uint256 claimId3 = _newClaim(creditor, creditor, debtor);

        bytes[] memory calls = new bytes[](3);

        calls[0] = abi.encodeCall(BullaClaimV2.payClaim, (claimId1, 1 ether));
        calls[1] = abi.encodeCall(BullaClaimV2.payClaim, (claimId2, 1 ether));
        calls[2] = abi.encodeCall(BullaClaimV2.payClaim, (claimId3, 1 ether));

        // Approve tokens for batch payment
        vm.prank(debtor);
        weth.approve(address(bullaClaim), 3 ether);

        vm.prank(debtor);
        bullaClaim.batch(calls, true);

        // Verify all claims were paid
        Claim memory claim1 = bullaClaim.getClaim(claimId1);
        Claim memory claim2 = bullaClaim.getClaim(claimId2);
        Claim memory claim3 = bullaClaim.getClaim(claimId3);

        assertEq(uint256(claim1.status), uint256(Status.Paid));
        assertEq(uint256(claim2.status), uint256(Status.Paid));
        assertEq(uint256(claim3.status), uint256(Status.Paid));

        // Verify NFT ownership remains with creditor
        assertEq(bullaClaim.ownerOf(claimId1), creditor);
        assertEq(bullaClaim.ownerOf(claimId2), creditor);
        assertEq(bullaClaim.ownerOf(claimId3), creditor);
    }

    function testBatch_PayMultipleClaims_ETH() public {
        // Create ETH claims
        vm.startPrank(creditor);
        uint256 claimId1 = bullaClaim.createClaim(
            new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(0)).build()
        );
        uint256 claimId2 = bullaClaim.createClaim(
            new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(0)).build()
        );
        vm.stopPrank();

        bytes[] memory calls = new bytes[](2);

        calls[0] = abi.encodeCall(BullaClaimV2.payClaim, (claimId1, 1 ether));
        calls[1] = abi.encodeCall(BullaClaimV2.payClaim, (claimId2, 1 ether));

        vm.prank(debtor);
        bullaClaim.batch{value: 2 ether}(calls, true);

        // Verify claims were paid
        Claim memory claim1 = bullaClaim.getClaim(claimId1);
        Claim memory claim2 = bullaClaim.getClaim(claimId2);

        assertEq(uint256(claim1.status), uint256(Status.Paid));
        assertEq(uint256(claim2.status), uint256(Status.Paid));
    }

    /*///////////////////// BATCH MANAGEMENT TESTS /////////////////////*/

    function testBatch_UpdateMultipleBindings() public {
        uint256 claimId1 = _newClaim(creditor, creditor, debtor);
        uint256 claimId2 = _newClaim(creditor, creditor, charlie);

        bytes[] memory calls = new bytes[](2);

        calls[0] = abi.encodeCall(BullaClaimV2.updateBinding, (claimId1, ClaimBinding.BindingPending));
        calls[1] = abi.encodeCall(BullaClaimV2.updateBinding, (claimId2, ClaimBinding.BindingPending));

        vm.prank(creditor);
        bullaClaim.batch(calls, true);

        Claim memory claim1 = bullaClaim.getClaim(claimId1);
        Claim memory claim2 = bullaClaim.getClaim(claimId2);

        assertEq(uint256(claim1.binding), uint256(ClaimBinding.BindingPending));
        assertEq(uint256(claim2.binding), uint256(ClaimBinding.BindingPending));
    }

    function testBatch_CancelMultipleClaims() public {
        uint256 claimId1 = _newClaim(creditor, creditor, debtor);
        uint256 claimId2 = _newClaim(creditor, creditor, charlie);

        bytes[] memory calls = new bytes[](2);

        calls[0] = abi.encodeCall(BullaClaimV2.cancelClaim, (claimId1, "Rescinding claim 1"));
        calls[1] = abi.encodeCall(BullaClaimV2.cancelClaim, (claimId2, "Rescinding claim 2"));

        vm.prank(creditor);
        bullaClaim.batch(calls, true);

        // Verify claims were rescinded
        Claim memory claim1 = bullaClaim.getClaim(claimId1);
        Claim memory claim2 = bullaClaim.getClaim(claimId2);

        assertEq(uint256(claim1.status), uint256(Status.Rescinded));
        assertEq(uint256(claim2.status), uint256(Status.Rescinded));
    }

    function testBatch_ImpairMultipleClaims() public {
        // Create claims with due dates in the past and move time forward
        uint256 pastDueBy = block.timestamp + 1 days;

        vm.startPrank(creditor);
        uint256 claimId1 = bullaClaim.createClaim(
            new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor).withDueBy(pastDueBy)
                .withImpairmentGracePeriod(1 hours).build()
        );
        uint256 claimId2 = bullaClaim.createClaim(
            new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(charlie).withDueBy(pastDueBy)
                .withImpairmentGracePeriod(1 hours).build()
        );
        vm.stopPrank();

        // Move time forward past due date and grace period
        vm.warp(pastDueBy + 2 hours);

        bytes[] memory calls = new bytes[](2);

        calls[0] = abi.encodeCall(BullaClaimV2.impairClaim, (claimId1));
        calls[1] = abi.encodeCall(BullaClaimV2.impairClaim, (claimId2));

        vm.prank(creditor);
        bullaClaim.batch(calls, true);

        // Verify claims are now impaired
        Claim memory claim1 = bullaClaim.getClaim(claimId1);
        Claim memory claim2 = bullaClaim.getClaim(claimId2);

        assertEq(uint256(claim1.status), uint256(Status.Impaired));
        assertEq(uint256(claim2.status), uint256(Status.Impaired));
    }

    function testBatch_MarkMultipleAsPaid() public {
        uint256 claimId1 = _newClaim(creditor, creditor, debtor);
        uint256 claimId2 = _newClaim(creditor, creditor, charlie);

        bytes[] memory calls = new bytes[](2);

        calls[0] = abi.encodeCall(BullaClaimV2.markClaimAsPaid, (claimId1));
        calls[1] = abi.encodeCall(BullaClaimV2.markClaimAsPaid, (claimId2));

        vm.prank(creditor);
        bullaClaim.batch(calls, true);

        // Verify both claims were paid
        Claim memory claim1 = bullaClaim.getClaim(claimId1);
        Claim memory claim2 = bullaClaim.getClaim(claimId2);

        assertEq(uint256(claim1.status), uint256(Status.Paid));
        assertEq(uint256(claim2.status), uint256(Status.Paid));
    }

    /*///////////////////// PERMITTOKEN TESTS /////////////////////*/

    function testPermitToken_ValidSignature() public {
        uint256 amount = 1000 ether;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 privateKey = 0x1234;
        address owner = vm.addr(privateKey);

        // Transfer tokens to owner
        permitToken.transfer(owner, amount);

        // Create permit signature using helper from BullaClaimTestHelper
        (uint8 v, bytes32 r, bytes32 s) =
            _permitERC20Token(privateKey, address(permitToken), address(bullaClaim), amount, deadline);

        // Call permitToken directly (not through batch)
        (bool success,) = address(bullaClaim).call(
            abi.encodeWithSignature(
                "permitToken(address,address,address,uint256,uint256,uint8,bytes32,bytes32)",
                address(permitToken),
                owner,
                address(bullaClaim),
                amount,
                deadline,
                v,
                r,
                s
            )
        );

        assertTrue(success, "permitToken call should succeed");

        // Verify allowance was set
        assertEq(permitToken.allowance(owner, address(bullaClaim)), amount);
    }

    function testPermitToken_InBatch() public {
        uint256 amount = 1000 ether;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 privateKey = 0x5678;
        address owner = vm.addr(privateKey);

        // Transfer tokens to owner
        permitToken.transfer(owner, amount);

        // Create permit signature using EIP712Helper
        (uint8 v, bytes32 r, bytes32 s) = sigHelper.signERC20PermitComponents(
            privateKey, address(permitToken), owner, address(bullaClaim), amount, deadline
        );

        bytes[] memory calls = new bytes[](2);

        // First call: permit
        calls[0] = abi.encodeWithSignature(
            "permitToken(address,address,address,uint256,uint256,uint8,bytes32,bytes32)",
            address(permitToken),
            owner,
            address(bullaClaim),
            amount,
            deadline,
            v,
            r,
            s
        );

        // Second call: create claim that would use the permitted tokens
        calls[1] = abi.encodeCall(
            BullaClaimV2.createClaim,
            (
                new CreateClaimParamsBuilder().withCreditor(owner).withDebtor(debtor).withToken(address(permitToken))
                    .withClaimAmount(amount).build()
            )
        );

        vm.prank(owner);
        bullaClaim.batch(calls, true);

        // Verify both permit and claim creation worked
        assertEq(permitToken.allowance(owner, address(bullaClaim)), amount);

        Claim memory claim = bullaClaim.getClaim(0);
        assertEq(claim.originalCreditor, owner);
        assertEq(claim.token, address(permitToken));
        assertEq(claim.claimAmount, amount);
    }

    /*///////////////////// EDGE CASES AND ERROR HANDLING /////////////////////*/

    function testBatch_MaxGasLimit() public {
        // Test with a reasonable number of operations to avoid gas limit issues
        uint256 numClaims = 10;
        bytes[] memory calls = new bytes[](numClaims);

        for (uint256 i = 0; i < numClaims; i++) {
            calls[i] = abi.encodeCall(
                BullaClaimV2.createClaim,
                (new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(address(uint160(0x1000 + i))).build())
            );
        }

        vm.prank(creditor);
        bullaClaim.batch(calls, true);

        assertEq(bullaClaim.currentClaimId(), numClaims);
    }
}
