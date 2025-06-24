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
import {Deployer} from "script/Deployment.s.sol";
import {CreateClaimParamsBuilder} from "test/foundry/BullaClaim/CreateClaimParamsBuilder.sol";
import {BaseBullaClaim} from "contracts/BaseBullaClaim.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

contract TestCoreProtocolFee is Test {
    BullaClaim public bullaClaim;
    BullaClaim public zeroFeeBullaClaim;
    WETH public weth;
    MockERC20 public token;

    address private _owner = makeAddr("owner");
    address private _creditor = makeAddr("creditor");
    address private _debtor = makeAddr("debtor");
    address private _nonOwner = makeAddr("nonOwner");

    uint256 private constant _STANDARD_FEE = 0.01 ether;
    uint256 private constant _HIGH_FEE = 0.1 ether;
    uint256 private constant _MAX_FEE = 1 ether;

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

    event FeeWithdrawn(address indexed owner, uint256 amount);

    function setUp() public {
        weth = new WETH();
        token = new MockERC20("TestToken", "TT", 18);
        token.mint(_creditor, type(uint256).max);

        // Deploy BullaClaim with standard fee
        vm.startPrank(_owner);
        bullaClaim = (new Deployer()).deploy_test({
            _deployer: _owner,
            _initialLockState: LockState.Unlocked,
            _coreProtocolFee: _STANDARD_FEE
        });

        // Deploy BullaClaim with zero fee for comparison tests
        zeroFeeBullaClaim = (new Deployer()).deploy_test({
            _deployer: _owner,
            _initialLockState: LockState.Unlocked,
            _coreProtocolFee: 0
        });
        vm.stopPrank();

        // Setup balances
        vm.deal(_creditor, 100 ether);
        vm.deal(_debtor, 100 ether);
        vm.deal(_nonOwner, 100 ether);
    }

    // ==================== CONSTRUCTOR & INITIALIZATION TESTS ====================

    function testConstructorSetsCorrectFee() public {
        assertEq(bullaClaim.CORE_PROTOCOL_FEE(), _STANDARD_FEE, "Standard fee should be set correctly");
        assertEq(zeroFeeBullaClaim.CORE_PROTOCOL_FEE(), 0, "Zero fee should be set correctly");
    }

    // ==================== FEE VALIDATION TESTS ====================

    function testCreateClaimWithCorrectFee() public {
        CreateClaimParams memory params =
            new CreateClaimParamsBuilder().withCreditor(_creditor).withDebtor(_debtor).withClaimAmount(1 ether).build();

        uint256 initialBalance = address(bullaClaim).balance;

        vm.prank(_creditor);
        uint256 claimId = bullaClaim.createClaim{value: _STANDARD_FEE}(params);

        assertEq(claimId, 1, "Claim should be created successfully");
        assertEq(address(bullaClaim).balance, initialBalance + _STANDARD_FEE, "Fee should be collected");
    }

    function testCreateClaimWithZeroFeeContract() public {
        CreateClaimParams memory params =
            new CreateClaimParamsBuilder().withCreditor(_creditor).withDebtor(_debtor).withClaimAmount(1 ether).build();

        vm.prank(_creditor);
        uint256 claimId = zeroFeeBullaClaim.createClaim{value: 0}(params);

        assertEq(claimId, 1, "Claim should be created successfully with zero fee");
        assertEq(address(zeroFeeBullaClaim).balance, 0, "No fee should be collected");
    }

    function testCreateClaimFailsWithIncorrectFee() public {
        CreateClaimParams memory params =
            new CreateClaimParamsBuilder().withCreditor(_creditor).withDebtor(_debtor).withClaimAmount(1 ether).build();

        // Test with too little fee
        vm.prank(_creditor);
        vm.expectRevert(BaseBullaClaim.IncorrectFee.selector);
        bullaClaim.createClaim{value: _STANDARD_FEE - 1}(params);

        // Test with too much fee
        vm.prank(_creditor);
        vm.expectRevert(BaseBullaClaim.IncorrectFee.selector);
        bullaClaim.createClaim{value: _STANDARD_FEE + 1}(params);

        // Test with zero fee when fee is required
        vm.prank(_creditor);
        vm.expectRevert(BaseBullaClaim.IncorrectFee.selector);
        bullaClaim.createClaim{value: 0}(params);
    }

    function testCreateClaimWithMetadataWithCorrectFee() public {
        CreateClaimParams memory params =
            new CreateClaimParamsBuilder().withCreditor(_creditor).withDebtor(_debtor).withClaimAmount(1 ether).build();

        ClaimMetadata memory metadata =
            ClaimMetadata({tokenURI: "https://example.com/token", attachmentURI: "https://example.com/attachment"});

        uint256 initialBalance = address(bullaClaim).balance;

        vm.prank(_creditor);
        uint256 claimId = bullaClaim.createClaimWithMetadata{value: _STANDARD_FEE}(params, metadata);

        assertEq(claimId, 1, "Claim with metadata should be created successfully");
        assertEq(address(bullaClaim).balance, initialBalance + _STANDARD_FEE, "Fee should be collected");
    }

    function testCreateClaimWithMetadataFailsWithIncorrectFee() public {
        CreateClaimParams memory params =
            new CreateClaimParamsBuilder().withCreditor(_creditor).withDebtor(_debtor).withClaimAmount(1 ether).build();

        ClaimMetadata memory metadata =
            ClaimMetadata({tokenURI: "https://example.com/token", attachmentURI: "https://example.com/attachment"});

        vm.prank(_creditor);
        vm.expectRevert(BaseBullaClaim.IncorrectFee.selector);
        bullaClaim.createClaimWithMetadata{value: _STANDARD_FEE - 1}(params, metadata);
    }

    // ==================== FEE ACCUMULATION TESTS ====================

    function testFeeAccumulationMultipleClaims() public {
        CreateClaimParams memory params =
            new CreateClaimParamsBuilder().withCreditor(_creditor).withDebtor(_debtor).withClaimAmount(1 ether).build();

        uint256 initialBalance = address(bullaClaim).balance;

        // Create 5 claims
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(_creditor);
            bullaClaim.createClaim{value: _STANDARD_FEE}(params);
        }

        uint256 expectedBalance = initialBalance + (5 * _STANDARD_FEE);
        assertEq(address(bullaClaim).balance, expectedBalance, "Fees should accumulate correctly");
    }

    function testFeeAccumulationDifferentUsers() public {
        CreateClaimParams memory params1 =
            new CreateClaimParamsBuilder().withCreditor(_creditor).withDebtor(_debtor).withClaimAmount(1 ether).build();

        CreateClaimParams memory params2 =
            new CreateClaimParamsBuilder().withCreditor(_debtor).withDebtor(_creditor).withClaimAmount(2 ether).build();

        uint256 initialBalance = address(bullaClaim).balance;

        vm.prank(_creditor);
        bullaClaim.createClaim{value: _STANDARD_FEE}(params1);

        vm.prank(_debtor);
        bullaClaim.createClaim{value: _STANDARD_FEE}(params2);

        uint256 expectedBalance = initialBalance + (2 * _STANDARD_FEE);
        assertEq(address(bullaClaim).balance, expectedBalance, "Fees should accumulate from different users");
    }

    // ==================== FEE WITHDRAWAL TESTS ====================

    function testWithdrawAllFeesAsOwner() public {
        // Create some claims to accumulate fees
        CreateClaimParams memory params =
            new CreateClaimParamsBuilder().withCreditor(_creditor).withDebtor(_debtor).withClaimAmount(1 ether).build();

        for (uint256 i = 0; i < 3; i++) {
            vm.prank(_creditor);
            bullaClaim.createClaim{value: _STANDARD_FEE}(params);
        }

        uint256 totalFees = 3 * _STANDARD_FEE;
        uint256 ownerBalanceBefore = _owner.balance;

        vm.prank(_owner);
        vm.expectEmit(true, false, false, true);
        emit FeeWithdrawn(_owner, totalFees);
        bullaClaim.withdrawAllFees();

        assertEq(address(bullaClaim).balance, 0, "Contract balance should be zero after withdrawal");
        assertEq(_owner.balance, ownerBalanceBefore + totalFees, "Owner should receive all fees");
    }

    function testWithdrawAllFeesWithZeroBalance() public {
        uint256 ownerBalanceBefore = _owner.balance;

        vm.prank(_owner);
        bullaClaim.withdrawAllFees(); // Should not revert

        assertEq(_owner.balance, ownerBalanceBefore, "Owner balance should not change with zero withdrawal");
    }

    function testWithdrawAllFeesFailsAsNonOwner() public {
        // Create a claim to accumulate fees
        CreateClaimParams memory params =
            new CreateClaimParamsBuilder().withCreditor(_creditor).withDebtor(_debtor).withClaimAmount(1 ether).build();

        vm.prank(_creditor);
        bullaClaim.createClaim{value: _STANDARD_FEE}(params);

        vm.prank(_nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _nonOwner));
        bullaClaim.withdrawAllFees();
    }

    // ==================== FEE SETTING TESTS ====================

    function testSetCoreProtocolFeeAsOwner() public {
        uint256 newFee = 0.05 ether;

        vm.prank(_owner);
        bullaClaim.setCoreProtocolFee(newFee);

        assertEq(bullaClaim.CORE_PROTOCOL_FEE(), newFee, "Fee should be updated correctly");
    }

    function testSetCoreProtocolFeeToZero() public {
        vm.prank(_owner);
        bullaClaim.setCoreProtocolFee(0);

        assertEq(bullaClaim.CORE_PROTOCOL_FEE(), 0, "Fee should be set to zero");

        // Test that claims can be created with zero fee
        CreateClaimParams memory params =
            new CreateClaimParamsBuilder().withCreditor(_creditor).withDebtor(_debtor).withClaimAmount(1 ether).build();

        vm.prank(_creditor);
        uint256 claimId = bullaClaim.createClaim{value: 0}(params);

        assertEq(claimId, 1, "Claim should be created with zero fee");
    }

    function testSetCoreProtocolFeeToMaxValue() public {
        uint256 maxFee = type(uint256).max;

        vm.prank(_owner);
        bullaClaim.setCoreProtocolFee(maxFee);

        assertEq(bullaClaim.CORE_PROTOCOL_FEE(), maxFee, "Fee should be set to max value");
    }

    function testSetCoreProtocolFeeFailsAsNonOwner() public {
        uint256 newFee = 0.05 ether;

        vm.prank(_nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _nonOwner));
        bullaClaim.setCoreProtocolFee(newFee);
    }

    function testFeeUpdateAffectsNewClaims() public {
        uint256 newFee = 0.05 ether;

        // Create claim with original fee
        CreateClaimParams memory params =
            new CreateClaimParamsBuilder().withCreditor(_creditor).withDebtor(_debtor).withClaimAmount(1 ether).build();

        vm.prank(_creditor);
        bullaClaim.createClaim{value: _STANDARD_FEE}(params);

        // Update fee
        vm.prank(_owner);
        bullaClaim.setCoreProtocolFee(newFee);

        // Create claim with new fee
        vm.prank(_creditor);
        bullaClaim.createClaim{value: newFee}(params);

        uint256 expectedBalance = _STANDARD_FEE + newFee;
        assertEq(address(bullaClaim).balance, expectedBalance, "Both fees should be collected");
    }

    // ==================== EDGE CASES & ERROR CONDITIONS ====================

    function testCreateClaimWhenContractLocked() public {
        vm.prank(_owner);
        bullaClaim.setLockState(LockState.Locked);

        CreateClaimParams memory params =
            new CreateClaimParamsBuilder().withCreditor(_creditor).withDebtor(_debtor).withClaimAmount(1 ether).build();

        vm.prank(_creditor);
        vm.expectRevert(BaseBullaClaim.Locked.selector);
        bullaClaim.createClaim{value: _STANDARD_FEE}(params);
    }

    function testCreateClaimWhenNoNewClaims() public {
        vm.prank(_owner);
        bullaClaim.setLockState(LockState.NoNewClaims);

        CreateClaimParams memory params =
            new CreateClaimParamsBuilder().withCreditor(_creditor).withDebtor(_debtor).withClaimAmount(1 ether).build();

        vm.prank(_creditor);
        vm.expectRevert(BaseBullaClaim.Locked.selector);
        bullaClaim.createClaim{value: _STANDARD_FEE}(params);
    }

    function testFeeValidationWithDifferentTokens() public {
        // Test with ETH (address(0))
        CreateClaimParams memory ethParams = new CreateClaimParamsBuilder().withCreditor(_creditor).withDebtor(_debtor)
            .withClaimAmount(1 ether).withToken(address(0)).build();

        vm.prank(_creditor);
        bullaClaim.createClaim{value: _STANDARD_FEE}(ethParams);

        // Test with ERC20 token
        CreateClaimParams memory tokenParams = new CreateClaimParamsBuilder().withCreditor(_creditor).withDebtor(
            _debtor
        ).withClaimAmount(1000e18).withToken(address(token)).build();

        vm.prank(_creditor);
        bullaClaim.createClaim{value: _STANDARD_FEE}(tokenParams);

        uint256 expectedBalance = 2 * _STANDARD_FEE;
        assertEq(address(bullaClaim).balance, expectedBalance, "Fee should be same regardless of claim token");
    }

    // ==================== FUZZ TESTS ====================

    function testFuzzCreateClaimWithVariousFees(uint256 feeAmount) public {
        vm.assume(feeAmount <= 10 ether); // Reasonable upper bound

        vm.prank(_owner);
        bullaClaim.setCoreProtocolFee(feeAmount);

        CreateClaimParams memory params =
            new CreateClaimParamsBuilder().withCreditor(_creditor).withDebtor(_debtor).withClaimAmount(1 ether).build();

        vm.deal(_creditor, feeAmount + 1 ether); // Ensure sufficient balance

        vm.prank(_creditor);
        uint256 claimId = bullaClaim.createClaim{value: feeAmount}(params);

        assertEq(claimId, 1, "Claim should be created with any valid fee");
        assertEq(address(bullaClaim).balance, feeAmount, "Contract should receive the fee");
    }

    function testFuzzFeeAccumulation(uint8 numClaims, uint256 feePerClaim) public {
        vm.assume(numClaims > 0 && numClaims <= 20); // Reasonable bounds
        vm.assume(feePerClaim <= 1 ether); // Reasonable upper bound

        vm.prank(_owner);
        bullaClaim.setCoreProtocolFee(feePerClaim);

        CreateClaimParams memory params =
            new CreateClaimParamsBuilder().withCreditor(_creditor).withDebtor(_debtor).withClaimAmount(1 ether).build();

        uint256 totalFeesNeeded = uint256(numClaims) * feePerClaim;
        vm.deal(_creditor, totalFeesNeeded + 10 ether); // Ensure sufficient balance

        for (uint256 i = 0; i < numClaims; i++) {
            vm.prank(_creditor);
            bullaClaim.createClaim{value: feePerClaim}(params);
        }

        assertEq(address(bullaClaim).balance, totalFeesNeeded, "All fees should accumulate correctly");
        assertEq(bullaClaim.currentClaimId(), numClaims, "All claims should be created");
    }

    // ==================== INTEGRATION TESTS ====================

    function testIntegrationFeeLifecycle() public {
        // 1. Set a custom fee
        uint256 customFee = 0.025 ether;
        vm.prank(_owner);
        bullaClaim.setCoreProtocolFee(customFee);

        // 2. Create multiple claims
        CreateClaimParams memory params =
            new CreateClaimParamsBuilder().withCreditor(_creditor).withDebtor(_debtor).withClaimAmount(1 ether).build();

        for (uint256 i = 0; i < 4; i++) {
            vm.prank(_creditor);
            bullaClaim.createClaim{value: customFee}(params);
        }

        uint256 totalFees = 4 * customFee;
        assertEq(address(bullaClaim).balance, totalFees, "Fees should accumulate");

        // 3. Withdraw fees
        uint256 ownerBalanceBefore = _owner.balance;
        vm.prank(_owner);
        bullaClaim.withdrawAllFees();

        assertEq(address(bullaClaim).balance, 0, "Contract balance should be zero");
        assertEq(_owner.balance, ownerBalanceBefore + totalFees, "Owner should receive all fees");

        // 4. Change fee and create more claims
        uint256 newFee = 0.05 ether;
        vm.prank(_owner);
        bullaClaim.setCoreProtocolFee(newFee);

        vm.prank(_creditor);
        bullaClaim.createClaim{value: newFee}(params);

        assertEq(address(bullaClaim).balance, newFee, "New fee should be collected");
    }

    function testIntegrationMixedClaimTypes() public {
        CreateClaimParams memory params =
            new CreateClaimParamsBuilder().withCreditor(_creditor).withDebtor(_debtor).withClaimAmount(1 ether).build();

        ClaimMetadata memory metadata =
            ClaimMetadata({tokenURI: "https://example.com/token", attachmentURI: "https://example.com/attachment"});

        uint256 initialBalance = address(bullaClaim).balance;

        // Create different types of claims
        vm.prank(_creditor);
        bullaClaim.createClaim{value: _STANDARD_FEE}(params);

        vm.prank(_creditor);
        bullaClaim.createClaimWithMetadata{value: _STANDARD_FEE}(params, metadata);

        uint256 expectedBalance = initialBalance + (2 * _STANDARD_FEE);
        assertEq(address(bullaClaim).balance, expectedBalance, "All claim types should collect fees");
    }
}
