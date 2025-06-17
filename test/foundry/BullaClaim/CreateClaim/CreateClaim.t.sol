// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import {WETH} from "contracts/mocks/weth.sol";
import {
    Claim,
    Status,
    ClaimBinding,
    CreateClaimParams,
    LockState,
    ClaimMetadata,
    CreateClaimApprovalType
} from "contracts/types/Types.sol";
import {BullaClaim} from "contracts/BullaClaim.sol";
import {PenalizedClaim} from "contracts/mocks/PenalizedClaim.sol";
import {Deployer} from "script/Deployment.s.sol";
import {BullaClaimTestHelper} from "test/foundry/BullaClaim/BullaClaimTestHelper.sol";
import {ClaimMetadataGenerator} from "contracts/ClaimMetadataGenerator.sol";
import {CreateClaimParamsBuilder} from "test/foundry/BullaClaim/CreateClaimParamsBuilder.sol";
import {BullaClaimValidationLib} from "contracts/libraries/BullaClaimValidationLib.sol";

contract TestCreateClaim is BullaClaimTestHelper {
    address creditor = address(0x01);
    address debtor = address(0x02);

    event ClaimCreated(
        uint256 indexed claimId,
        address from,
        address indexed creditor,
        address indexed debtor,
        uint256 claimAmount,
        string description,
        address token,
        address controller,
        ClaimBinding binding
    );

    function setUp() public {
        weth = new WETH();

        bullaClaim = (new Deployer()).deploy_test({
            _deployer: address(this),
            _initialLockState: LockState.Unlocked,
            _coreProtocolFee: 0
        });
        _newClaim(creditor, creditor, debtor);
    }

    /*///////////////////// CREATE CLAIM TESTS /////////////////////*/

    //baseline gas report after 1 mint
    function testBaselineGas__createClaim() public {
        _newClaim(creditor, creditor, debtor);
    }

    function testCreateNativeClaim() public {
        CreateClaimParams memory params =
            new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor).build();

        vm.prank(creditor);
        uint256 claimId = bullaClaim.createClaim(params);

        Claim memory claim = bullaClaim.getClaim(claimId);
        assertEq(claim.token, address(0));
    }

    function testCannotCreateClaimWhenContractIsLocked() public {
        bullaClaim.setLockState(LockState.Locked);

        vm.expectRevert(BullaClaim.Locked.selector);
        _newClaim(creditor, creditor, debtor);

        bullaClaim.setLockState(LockState.NoNewClaims);
        vm.expectRevert(BullaClaim.Locked.selector);
        _newClaim(creditor, creditor, debtor);
    }

    function testCannotCreateClaimLargerThanMaxUint128() public {
        CreateClaimParams memory params = new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withClaimAmount(uint256(type(uint128).max) + 1).build();

        vm.expectRevert();
        vm.prank(creditor);
        bullaClaim.createClaim(params);
    }

    function testCannotCreateClaimWhenNotCreditorOrDebtor() public {
        CreateClaimParams memory params =
            new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor).withClaimAmount(1 ether).build();

        address randomUser = address(0x1234);
        vm.prank(randomUser);
        vm.expectRevert(BullaClaimValidationLib.NotCreditorOrDebtor.selector);
        bullaClaim.createClaim(params);
    }

    function testCreateBoundClaim() public {
        // test creation of a pending bound claim
        CreateClaimParams memory params1 = new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withBinding(ClaimBinding.BindingPending).build();

        vm.prank(creditor);
        uint256 claimId = bullaClaim.createClaim(params1);

        Claim memory claim = bullaClaim.getClaim(claimId);
        assertTrue(claim.binding == ClaimBinding.BindingPending);

        //test creation of a pending claim that is bound
        CreateClaimParams memory params2 = new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withBinding(ClaimBinding.Bound).build();

        vm.prank(debtor);
        uint256 boundClaimId = bullaClaim.createClaim(params2);

        Claim memory boundClaim = bullaClaim.getClaim(boundClaimId);
        assertTrue(boundClaim.binding == ClaimBinding.Bound);
    }

    function testCreateEdgeCase_ZeroDebtor() public {
        uint256 beforeClaimCreation = bullaClaim.currentClaimId();
        uint256 claimId = _newClaim(creditor, creditor, address(0));
        assertEq(bullaClaim.currentClaimId(), claimId);
        assertEq(bullaClaim.currentClaimId(), beforeClaimCreation + 1);
    }

    function testCannotCreateBoundClaimUnlessDebtor() public {
        CreateClaimParams memory params1 = new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withBinding(ClaimBinding.Bound).build();

        vm.prank(debtor);
        bullaClaim.createClaim(params1);

        CreateClaimParams memory params2 = new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withBinding(ClaimBinding.Bound).build();

        vm.expectRevert(BullaClaimValidationLib.CannotBindClaim.selector);
        vm.prank(creditor);
        bullaClaim.createClaim(params2);
    }

    function testCannotCreateClaimWithUintOverflow() public {
        uint256 claimAmount = uint256(type(uint128).max) + 1;

        CreateClaimParams memory params = new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withClaimAmount(claimAmount).withToken(address(weth)).build();

        vm.expectRevert();
        bullaClaim.createClaim(params);
    }

    function testCannotCreateZeroAmountClaim() public {
        CreateClaimParams memory params = new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withClaimAmount(0).withToken(address(weth)).build();

        vm.expectRevert(BullaClaimValidationLib.ZeroAmount.selector);
        vm.prank(creditor);
        bullaClaim.createClaim(params);
    }

    function testCannotCreateBoundClaim() public {
        CreateClaimParams memory params = new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withBinding(ClaimBinding.Bound).build();

        vm.expectRevert(BullaClaimValidationLib.CannotBindClaim.selector);
        vm.prank(creditor);
        bullaClaim.createClaim(params);
    }

    /**
     * /// TEST CASES FOR ORIGINAL CREDITOR ///
     */
    function testOriginalCreditorPersistenceAfterTransfer() public {
        address newOwner = address(0xABC);

        CreateClaimParams memory params =
            new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth)).build();

        vm.prank(creditor);
        uint256 claimId = bullaClaim.createClaim(params);

        // Transfer NFT to another address
        vm.prank(creditor);
        bullaClaim.safeTransferFrom(creditor, newOwner, claimId);

        // Check that originalCreditor is still preserved
        Claim memory claim = bullaClaim.getClaim(claimId);
        assertEq(claim.originalCreditor, creditor);
        assertEq(bullaClaim.ownerOf(claimId), newOwner);
    }

    function testOriginalCreditorInTokenURI() public {
        // We need to set the metadata generator first
        ClaimMetadataGenerator metadataGenerator = new ClaimMetadataGenerator();
        bullaClaim.setClaimMetadataGenerator(address(metadataGenerator));

        CreateClaimParams memory params =
            new CreateClaimParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth)).build();

        vm.prank(creditor);
        uint256 claimId = bullaClaim.createClaim(params);

        // Get the tokenURI and verify it contains creditor information
        string memory uri = bullaClaim.tokenURI(claimId);

        // Transfer to a new owner
        address newOwner = address(0xDEF);
        vm.prank(creditor);
        bullaClaim.safeTransferFrom(creditor, newOwner, claimId);

        // Get the tokenURI again and verify it contains current owner (not original creditor)
        // This test is verifying the current implementation which uses the current owner
        // and not the originalCreditor in the token URI
        string memory newUri = bullaClaim.tokenURI(claimId);

        // We can't directly compare strings in Solidity easily, but we can check that the URIs are different
        // which indicates the owner change is reflected in the URI
        assertTrue(keccak256(bytes(uri)) != keccak256(bytes(newUri)));
    }

    function test_FUZZ_createClaim(
        bool isInvoice,
        address _creditor,
        address _debtor,
        uint128 claimAmount,
        address token,
        uint8 binding,
        bool payerReceivesClaimOnPayment
    ) public {
        vm.assume(_creditor != address(0));
        vm.assume(claimAmount > 0);
        vm.assume(binding <= 1); // assumes a fuzz can only produce unbound or binding pending claims
        vm.warp(block.timestamp + 6 days);
        vm.roll(10_000);
        uint256 expectedClaimId = bullaClaim.currentClaimId() + 1;

        uint256 creditorBalanceBefore = bullaClaim.balanceOf(_creditor);

        address creator = isInvoice ? _creditor : _debtor;

        CreateClaimParams memory params = new CreateClaimParamsBuilder().withCreditor(_creditor).withDebtor(_debtor)
            .withClaimAmount(claimAmount).withToken(token).withDescription("test description").withBinding(
            ClaimBinding(binding)
        ).withPayerReceivesClaimOnPayment(payerReceivesClaimOnPayment).build();

        vm.startPrank(creator);
        vm.expectEmit(true, true, true, true);
        emit ClaimCreated(
            expectedClaimId,
            creator,
            _creditor,
            _debtor,
            uint256(claimAmount),
            "test description",
            token,
            address(0),
            ClaimBinding(binding)
        );

        uint256 claimId = bullaClaim.createClaim(params);
        vm.stopPrank();

        {
            assertEq(bullaClaim.currentClaimId(), claimId);
            Claim memory claim = bullaClaim.getClaim(claimId);
            assertEq(claim.originalCreditor, _creditor);
            assertEq(bullaClaim.ownerOf(claimId), _creditor);
            assertEq(claim.paidAmount, 0);
            assertTrue(claim.status == Status.Pending);
            assertEq(claim.claimAmount, claimAmount);
            assertEq(claim.debtor, _debtor);
            assertEq(claim.payerReceivesClaimOnPayment, payerReceivesClaimOnPayment);
            assertTrue(claim.binding == ClaimBinding(binding));
            assertEq(claim.token, token);
            assertEq(bullaClaim.balanceOf(_creditor), creditorBalanceBefore + 1);
            assertEq(bullaClaim.ownerOf(claimId), _creditor);

            vm.prank(_creditor);
            bullaClaim.safeTransferFrom(_creditor, address(0xB0B), claimId);

            assertEq(bullaClaim.ownerOf(claimId), address(0xB0B));
        }
    }
}
