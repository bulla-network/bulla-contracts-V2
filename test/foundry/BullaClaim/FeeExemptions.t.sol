// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import {WETH} from "contracts/mocks/weth.sol";
import {MockERC20} from "contracts/mocks/MockERC20.sol";
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
import {WhitelistPermissions} from "contracts/WhitelistPermissions.sol";
import {Permissions} from "contracts/Permissions.sol";
import {IPermissions} from "contracts/interfaces/IPermissions.sol";
import {Deployer} from "script/Deployment.s.sol";
import {CreateClaimParamsBuilder} from "test/foundry/BullaClaim/CreateClaimParamsBuilder.sol";
import {IERC165} from "openzeppelin-contracts/contracts/utils/introspection/IERC165.sol";
import {ERC165} from "openzeppelin-contracts/contracts/utils/introspection/ERC165.sol";
import {IBullaClaim} from "contracts/interfaces/IBullaClaim.sol";

// Mock contract that implements ERC165 but NOT IPermissions
contract MockERC165Contract is ERC165 {
    // This contract only supports ERC165, not IPermissions
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IERC165).interfaceId || super.supportsInterface(interfaceId);
    }
}

contract TestFeeExemptions is Test {
    BullaClaim public bullaClaim;
    WhitelistPermissions public feeExemptions;
    WETH public weth;
    MockERC20 public token;

    address private _owner = makeAddr("owner");
    address private _creditor = makeAddr("creditor");
    address private _debtor = makeAddr("debtor");
    address private _exemptUser = makeAddr("exemptUser");
    address private _nonExemptUser = makeAddr("nonExemptUser");
    address private _admin = makeAddr("admin");

    uint256 private constant _STANDARD_FEE = 0.01 ether;

    event ClaimCreated(
        uint256 indexed claimId,
        address from,
        address indexed creditor,
        address indexed debtor,
        uint256 claimAmount,
        uint256 dueBy,
        string description,
        address token,
        address controller,
        ClaimBinding binding
    );

    event AccessGranted(address indexed _account);
    event AccessRevoked(address indexed _account);

    function setUp() public {
        weth = new WETH();
        token = new MockERC20("TestToken", "TT", 18);
        token.mint(_creditor, type(uint256).max);

        // Deploy fee exemptions contract
        vm.prank(_admin);
        feeExemptions = new WhitelistPermissions();

        // Deploy BullaClaim
        vm.prank(_owner);
        bullaClaim = (new Deployer()).deploy_test({
            _deployer: _owner,
            _initialLockState: LockState.Unlocked,
            _coreProtocolFee: _STANDARD_FEE
        });

        // Set fee exemptions contract
        vm.prank(_owner);
        bullaClaim.setFeeExemptions(address(feeExemptions));

        // Setup balances
        vm.deal(_creditor, 100 ether);
        vm.deal(_debtor, 100 ether);
        vm.deal(_exemptUser, 100 ether);
        vm.deal(_nonExemptUser, 100 ether);
    }

    // ==================== CONSTRUCTOR & INITIALIZATION TESTS ====================

    function testConstructorSetsFeeExemptionsCorrectly() public {
        assertEq(address(bullaClaim.feeExemptions()), address(feeExemptions), "Fee exemptions should be set correctly");
    }

    // ==================== EXEMPT USER TESTS ====================

    function testExemptUserCanCreateClaimWithoutFee() public {
        // Add exempt user to whitelist
        vm.prank(_admin);
        feeExemptions.allow(_exemptUser);

        CreateClaimParams memory params = new CreateClaimParamsBuilder().withCreditor(_exemptUser).withDebtor(_debtor)
            .withClaimAmount(1 ether).build();

        uint256 initialBalance = address(bullaClaim).balance;

        vm.expectEmit(true, true, true, true);
        emit ClaimCreated(
            1,
            _exemptUser,
            _exemptUser,
            _debtor,
            1 ether,
            uint256(0),
            "Test Claim",
            address(0),
            address(0),
            ClaimBinding.Unbound
        );

        vm.prank(_exemptUser);
        uint256 claimId = bullaClaim.createClaim{value: 0}(params);

        assertEq(claimId, 1, "Claim should be created successfully");
        assertEq(address(bullaClaim).balance, initialBalance, "No fee should be collected from exempt user");
    }

    function testExemptUserCanCreateClaimWithMetadataWithoutFee() public {
        // Add exempt user to whitelist
        vm.prank(_admin);
        feeExemptions.allow(_exemptUser);

        CreateClaimParams memory params = new CreateClaimParamsBuilder().withCreditor(_exemptUser).withDebtor(_debtor)
            .withClaimAmount(1 ether).build();

        ClaimMetadata memory metadata =
            ClaimMetadata({tokenURI: "https://example.com/token", attachmentURI: "https://example.com/attachment"});

        uint256 initialBalance = address(bullaClaim).balance;

        vm.prank(_exemptUser);
        uint256 claimId = bullaClaim.createClaimWithMetadata{value: 0}(params, metadata);

        assertEq(claimId, 1, "Claim with metadata should be created successfully");
        assertEq(address(bullaClaim).balance, initialBalance, "No fee should be collected from exempt user");
    }

    function testExemptUserStillPaysIfSendingFee() public {
        // Add exempt user to whitelist
        vm.prank(_admin);
        feeExemptions.allow(_exemptUser);

        CreateClaimParams memory params = new CreateClaimParamsBuilder().withCreditor(_exemptUser).withDebtor(_debtor)
            .withClaimAmount(1 ether).build();

        uint256 initialBalance = address(bullaClaim).balance;

        // Exempt user sends fee anyway - should still work
        vm.prank(_exemptUser);
        uint256 claimId = bullaClaim.createClaim{value: _STANDARD_FEE}(params);

        assertEq(claimId, 1, "Claim should be created successfully");
        assertEq(address(bullaClaim).balance, initialBalance + _STANDARD_FEE, "Fee should still be collected if sent");
    }

    function testExemptDebtorAllowsClaimCreationWithoutFee() public {
        // Add debtor to exemption list
        vm.prank(_admin);
        feeExemptions.allow(_debtor);

        // Non-exempt creditor creates claim for exempt debtor
        CreateClaimParams memory params = new CreateClaimParamsBuilder().withCreditor(_nonExemptUser).withDebtor(
            _debtor
        ).withClaimAmount(1 ether).build();

        uint256 initialBalance = address(bullaClaim).balance;

        vm.expectEmit(true, true, true, true);
        emit ClaimCreated(
            1,
            _nonExemptUser,
            _nonExemptUser,
            _debtor,
            1 ether,
            uint256(0),
            "Test Claim",
            address(0),
            address(0),
            ClaimBinding.Unbound
        );

        // Should work without fee because debtor is exempt
        vm.prank(_nonExemptUser);
        uint256 claimId = bullaClaim.createClaim{value: 0}(params);

        assertEq(claimId, 1, "Claim should be created successfully");
        assertEq(address(bullaClaim).balance, initialBalance, "No fee should be collected when debtor is exempt");
    }

    // ==================== NON-EXEMPT USER TESTS ====================

    function testNonExemptUserMustPayFee() public {
        CreateClaimParams memory params = new CreateClaimParamsBuilder().withCreditor(_nonExemptUser).withDebtor(
            _debtor
        ).withClaimAmount(1 ether).build();

        // Should fail without fee
        vm.prank(_nonExemptUser);
        vm.expectRevert(IBullaClaim.IncorrectFee.selector);
        bullaClaim.createClaim{value: 0}(params);

        // Should succeed with fee
        uint256 initialBalance = address(bullaClaim).balance;

        vm.prank(_nonExemptUser);
        uint256 claimId = bullaClaim.createClaim{value: _STANDARD_FEE}(params);

        assertEq(claimId, 1, "Claim should be created successfully with fee");
        assertEq(address(bullaClaim).balance, initialBalance + _STANDARD_FEE, "Fee should be collected");
    }

    function testNonExemptUserFailsWithIncorrectFee() public {
        CreateClaimParams memory params = new CreateClaimParamsBuilder().withCreditor(_nonExemptUser).withDebtor(
            _debtor
        ).withClaimAmount(1 ether).build();

        // Too little fee
        vm.prank(_nonExemptUser);
        vm.expectRevert(IBullaClaim.IncorrectFee.selector);
        bullaClaim.createClaim{value: _STANDARD_FEE - 1}(params);

        // Too much fee
        vm.prank(_nonExemptUser);
        vm.expectRevert(IBullaClaim.IncorrectFee.selector);
        bullaClaim.createClaim{value: _STANDARD_FEE + 1}(params);
    }

    // ==================== EXEMPTION MANAGEMENT TESTS ====================

    function testAddingAndRemovingExemptions() public {
        CreateClaimParams memory params = new CreateClaimParamsBuilder().withCreditor(_nonExemptUser).withDebtor(
            _debtor
        ).withClaimAmount(1 ether).build();

        // Initially not exempt - should fail without fee
        vm.prank(_nonExemptUser);
        vm.expectRevert(IBullaClaim.IncorrectFee.selector);
        bullaClaim.createClaim{value: 0}(params);

        // Add exemption
        vm.expectEmit(true, false, false, false);
        emit AccessGranted(_nonExemptUser);

        vm.prank(_admin);
        feeExemptions.allow(_nonExemptUser);

        // Now exempt - should work without fee
        vm.prank(_nonExemptUser);
        uint256 claimId1 = bullaClaim.createClaim{value: 0}(params);
        assertEq(claimId1, 1, "First claim should be created without fee");

        // Remove exemption
        vm.expectEmit(true, false, false, false);
        emit AccessRevoked(_nonExemptUser);

        vm.prank(_admin);
        feeExemptions.disallow(_nonExemptUser);

        // No longer exempt - should fail without fee
        vm.prank(_nonExemptUser);
        vm.expectRevert(IBullaClaim.IncorrectFee.selector);
        bullaClaim.createClaim{value: 0}(params);

        // Should work with fee
        vm.prank(_nonExemptUser);
        uint256 claimId2 = bullaClaim.createClaim{value: _STANDARD_FEE}(params);
        assertEq(claimId2, 2, "Second claim should be created with fee");
    }

    function testMultipleExemptUsers() public {
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");
        address user3 = makeAddr("user3");

        vm.deal(user1, 10 ether);
        vm.deal(user2, 10 ether);
        vm.deal(user3, 10 ether);

        // Add multiple users to exemption list
        vm.startPrank(_admin);
        feeExemptions.allow(user1);
        feeExemptions.allow(user2);
        // user3 remains non-exempt
        vm.stopPrank();

        CreateClaimParams memory params =
            new CreateClaimParamsBuilder().withDebtor(_debtor).withClaimAmount(1 ether).build();

        // User1 (exempt) - should work without fee
        params.creditor = user1;
        vm.prank(user1);
        uint256 claimId1 = bullaClaim.createClaim{value: 0}(params);
        assertEq(claimId1, 1, "User1 claim should be created without fee");

        // User2 (exempt) - should work without fee
        params.creditor = user2;
        vm.prank(user2);
        uint256 claimId2 = bullaClaim.createClaim{value: 0}(params);
        assertEq(claimId2, 2, "User2 claim should be created without fee");

        // User3 (not exempt) - should fail without fee
        params.creditor = user3;
        vm.prank(user3);
        vm.expectRevert(IBullaClaim.IncorrectFee.selector);
        bullaClaim.createClaim{value: 0}(params);

        // User3 with fee - should work
        vm.prank(user3);
        uint256 claimId3 = bullaClaim.createClaim{value: _STANDARD_FEE}(params);
        assertEq(claimId3, 3, "User3 claim should be created with fee");
    }

    // ==================== FEE EXEMPTIONS CONTRACT MANAGEMENT TESTS ====================

    function testSetFeeExemptionsAsOwner() public {
        // Deploy new fee exemptions contract
        vm.prank(_admin);
        WhitelistPermissions newFeeExemptions = new WhitelistPermissions();

        // Set new fee exemptions
        vm.prank(_owner);
        bullaClaim.setFeeExemptions(address(newFeeExemptions));

        assertEq(address(bullaClaim.feeExemptions()), address(newFeeExemptions), "Fee exemptions should be updated");
    }

    function testSetFeeExemptionsFailsAsNonOwner() public {
        WhitelistPermissions newFeeExemptions = new WhitelistPermissions();

        vm.prank(_creditor);
        vm.expectRevert("Ownable: caller is not the owner");
        bullaClaim.setFeeExemptions(address(newFeeExemptions));
    }

    function testFeeExemptionsWithDifferentContracts() public {
        // Create and setup a new fee exemptions contract
        vm.prank(_admin);
        WhitelistPermissions newFeeExemptions = new WhitelistPermissions();

        vm.prank(_admin);
        newFeeExemptions.allow(_creditor);

        // Update to new contract
        vm.prank(_owner);
        bullaClaim.setFeeExemptions(address(newFeeExemptions));

        CreateClaimParams memory params =
            new CreateClaimParamsBuilder().withCreditor(_creditor).withDebtor(_debtor).withClaimAmount(1 ether).build();

        // _creditor should now be exempt in new contract
        vm.prank(_creditor);
        uint256 claimId = bullaClaim.createClaim{value: 0}(params);
        assertEq(claimId, 1, "Claim should be created without fee with new exemptions contract");

        // _exemptUser should no longer be exempt (not in new contract)
        params.creditor = _exemptUser;
        vm.prank(_exemptUser);
        vm.expectRevert(IBullaClaim.IncorrectFee.selector);
        bullaClaim.createClaim{value: 0}(params);
    }

    // ==================== EDGE CASES & ERROR CONDITIONS ====================

    function testFeeExemptionWhenContractLocked() public {
        // Add user to exemptions
        vm.prank(_admin);
        feeExemptions.allow(_exemptUser);

        // Lock the contract
        vm.prank(_owner);
        bullaClaim.setLockState(LockState.Locked);

        CreateClaimParams memory params = new CreateClaimParamsBuilder().withCreditor(_exemptUser).withDebtor(_debtor)
            .withClaimAmount(1 ether).build();

        // Should fail due to lock, not fee
        vm.prank(_exemptUser);
        vm.expectRevert(IBullaClaim.Locked.selector);
        bullaClaim.createClaim{value: 0}(params);
    }

    function testFeeExemptionWithZeroProtocolFee() public {
        // Deploy claim with zero fee
        vm.prank(_owner);
        BullaClaim zeroFeeClaim = (new Deployer()).deploy_test({
            _deployer: _owner,
            _initialLockState: LockState.Unlocked,
            _coreProtocolFee: 0
        });

        vm.prank(_owner);
        zeroFeeClaim.setFeeExemptions(address(feeExemptions));

        CreateClaimParams memory params = new CreateClaimParamsBuilder().withCreditor(_nonExemptUser).withDebtor(
            _debtor
        ).withClaimAmount(1 ether).build();

        // Non-exempt user should be able to create claims with zero fee when protocol fee is zero
        vm.prank(_nonExemptUser);
        uint256 claimId = zeroFeeClaim.createClaim{value: 0}(params);
        assertEq(claimId, 1, "Claim should be created with zero fee when protocol fee is zero");
    }

    function testFeeExemptionWithDifferentTokens() public {
        // Add user to exemptions
        vm.prank(_admin);
        feeExemptions.allow(_exemptUser);

        // Test with ETH (address(0))
        CreateClaimParams memory ethParams = new CreateClaimParamsBuilder().withCreditor(_exemptUser).withDebtor(
            _debtor
        ).withClaimAmount(1 ether).withToken(address(0)).build();

        vm.prank(_exemptUser);
        uint256 claimId1 = bullaClaim.createClaim{value: 0}(ethParams);
        assertEq(claimId1, 1, "ETH claim should be created without fee");

        // Test with ERC20 token
        CreateClaimParams memory tokenParams = new CreateClaimParamsBuilder().withCreditor(_exemptUser).withDebtor(
            _debtor
        ).withClaimAmount(1000e18).withToken(address(token)).build();

        vm.prank(_exemptUser);
        uint256 claimId2 = bullaClaim.createClaim{value: 0}(tokenParams);
        assertEq(claimId2, 2, "Token claim should be created without fee");

        assertEq(address(bullaClaim).balance, 0, "No fees should be collected for exempt user");
    }

    function testFeeExemptionWithZeroAddress() public {
        // Try to exempt zero address
        vm.prank(_admin);
        feeExemptions.allow(address(0));

        // This should still follow normal fee rules (zero address likely can't create claims anyway)
        assertTrue(feeExemptions.isAllowed(address(0)), "Zero address should be marked as allowed");
    }

    // ==================== INTEGRATION TESTS ====================

    function testIntegrationFeeExemptionLifecycle() public {
        uint256 initialBalance = address(bullaClaim).balance;

        CreateClaimParams memory params = new CreateClaimParamsBuilder().withCreditor(_nonExemptUser).withDebtor(
            _debtor
        ).withClaimAmount(1 ether).build();

        // 1. Non-exempt user pays fee
        vm.prank(_nonExemptUser);
        bullaClaim.createClaim{value: _STANDARD_FEE}(params);
        assertEq(address(bullaClaim).balance, initialBalance + _STANDARD_FEE, "Fee should be collected");

        // 2. Add to exemptions
        vm.prank(_admin);
        feeExemptions.allow(_nonExemptUser);

        // 3. Now exempt - no fee required
        vm.prank(_nonExemptUser);
        bullaClaim.createClaim{value: 0}(params);
        assertEq(address(bullaClaim).balance, initialBalance + _STANDARD_FEE, "No additional fee should be collected");

        // 4. Change fee exemptions contract
        vm.prank(_admin);
        WhitelistPermissions newExemptions = new WhitelistPermissions();

        vm.prank(_owner);
        bullaClaim.setFeeExemptions(address(newExemptions));

        // 5. User no longer exempt - fee required again
        vm.prank(_nonExemptUser);
        vm.expectRevert(IBullaClaim.IncorrectFee.selector);
        bullaClaim.createClaim{value: 0}(params);

        vm.prank(_nonExemptUser);
        bullaClaim.createClaim{value: _STANDARD_FEE}(params);
        assertEq(address(bullaClaim).balance, initialBalance + (2 * _STANDARD_FEE), "Fee should be collected again");
    }

    // ==================== FUZZ TESTS ====================

    function testFuzzFeeExemptionWithVariousUsers(address randomUser) public {
        vm.assume(randomUser != address(0));
        vm.assume(randomUser.code.length == 0); // Not a contract
        vm.deal(randomUser, 10 ether);

        CreateClaimParams memory params =
            new CreateClaimParamsBuilder().withCreditor(randomUser).withDebtor(_debtor).withClaimAmount(1 ether).build();

        // Should fail without exemption and fee
        vm.prank(randomUser);
        vm.expectRevert(IBullaClaim.IncorrectFee.selector);
        bullaClaim.createClaim{value: 0}(params);

        // Add to exemptions
        vm.prank(_admin);
        feeExemptions.allow(randomUser);

        // Should work without fee
        vm.prank(randomUser);
        uint256 claimId = bullaClaim.createClaim{value: 0}(params);
        assertEq(claimId, 1, "Random user should be able to create claim without fee when exempt");
    }

    function testFuzzFeeExemptionWithVaryingFees(uint256 feeAmount) public {
        vm.assume(feeAmount <= 10 ether); // Reasonable upper bound

        // Update protocol fee
        vm.prank(_owner);
        bullaClaim.setCoreProtocolFee(feeAmount);

        CreateClaimParams memory params = new CreateClaimParamsBuilder().withCreditor(_nonExemptUser).withDebtor(
            _debtor
        ).withClaimAmount(1 ether).build();

        vm.deal(_nonExemptUser, feeAmount + 1 ether);

        // Non-exempt user should need to pay the fee
        vm.prank(_nonExemptUser);
        uint256 claimId1 = bullaClaim.createClaim{value: feeAmount}(params);
        assertEq(claimId1, 1, "Non-exempt user should pay fee");

        // Add to exemptions
        vm.prank(_admin);
        feeExemptions.allow(_nonExemptUser);

        // Exempt user should not need to pay fee
        vm.prank(_nonExemptUser);
        uint256 claimId2 = bullaClaim.createClaim{value: 0}(params);
        assertEq(claimId2, 2, "Exempt user should not pay fee regardless of fee amount");
    }

    // ==================== VIEW FUNCTION TESTS ====================

    function testFeeExemptionsView() public {
        // Test isAllowed view function through BullaClaim
        assertFalse(feeExemptions.isAllowed(_nonExemptUser), "Non-exempt user should not be allowed");

        vm.prank(_admin);
        feeExemptions.allow(_exemptUser);

        assertTrue(feeExemptions.isAllowed(_exemptUser), "Exempt user should be allowed");
    }

    function testFeeExemptionsContractAddress() public {
        assertEq(
            address(bullaClaim.feeExemptions()), address(feeExemptions), "Fee exemptions contract address should match"
        );

        // Test after changing
        vm.prank(_admin);
        WhitelistPermissions newFeeExemptions = new WhitelistPermissions();

        vm.prank(_owner);
        bullaClaim.setFeeExemptions(address(newFeeExemptions));

        assertEq(
            address(bullaClaim.feeExemptions()),
            address(newFeeExemptions),
            "Fee exemptions contract address should be updated"
        );
    }
}
