// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {WETH} from "contracts/mocks/weth.sol";
import {BullaFrendLendV2} from "contracts/BullaFrendLendV2.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BullaClaimV2} from "contracts/BullaClaimV2.sol";
import {DeployContracts} from "script/DeployContracts.s.sol";
import {LoanRequestParams} from "contracts/interfaces/IBullaFrendLendV2.sol";
import {InterestConfig} from "contracts/libraries/CompoundInterestLib.sol";
import {LockState, ClaimMetadata} from "contracts/types/Types.sol";
import {BullaFrendLendTestHelper} from "test/foundry/BullaFrendLend/BullaFrendLendTestHelper.sol";
import {LoanRequestParamsBuilder} from "test/foundry/BullaFrendLend/LoanRequestParamsBuilder.t.sol";
import {EIP712Helper} from "test/foundry/BullaClaim/BullaClaimTestHelper.sol";

// Custom errors
error CallbackNotWhitelisted();

/**
 * @title MockCallbackContract
 * @notice Mock contracts for testing callback functionality with different selectors
 */
contract MockCallbackContract {
    struct CallbackData {
        uint256 loanOfferId;
        uint256 claimId;
        uint256 callCount;
    }

    mapping(uint256 => CallbackData) public callbackData;
    bool public shouldRevert;
    string public revertMessage;

    event CallbackExecuted(bytes4 selector, uint256 loanOfferId, uint256 claimId);

    function onLoanAccepted(uint256 loanOfferId, uint256 claimId) external {
        if (shouldRevert) {
            revert(revertMessage);
        }

        bytes4 selector = this.onLoanAccepted.selector;
        callbackData[loanOfferId] = CallbackData({
            loanOfferId: loanOfferId,
            claimId: claimId,
            callCount: callbackData[loanOfferId].callCount + 1
        });

        emit CallbackExecuted(selector, loanOfferId, claimId);
    }

    function handleLoanProcessed(uint256 loanOfferId, uint256 claimId) external {
        if (shouldRevert) {
            revert(revertMessage);
        }

        bytes4 selector = this.handleLoanProcessed.selector;
        callbackData[loanOfferId] = CallbackData({
            loanOfferId: loanOfferId,
            claimId: claimId,
            callCount: callbackData[loanOfferId].callCount + 1
        });

        emit CallbackExecuted(selector, loanOfferId, claimId);
    }

    function notifyLoanEvent(uint256 loanOfferId, uint256 claimId) external {
        if (shouldRevert) {
            revert(revertMessage);
        }

        bytes4 selector = this.notifyLoanEvent.selector;
        callbackData[loanOfferId] = CallbackData({
            loanOfferId: loanOfferId,
            claimId: claimId,
            callCount: callbackData[loanOfferId].callCount + 1
        });

        emit CallbackExecuted(selector, loanOfferId, claimId);
    }

    function getCallbackData(uint256 loanOfferId) external view returns (CallbackData memory) {
        return callbackData[loanOfferId];
    }

    function setRevertBehavior(bool _shouldRevert, string memory _revertMessage) external {
        shouldRevert = _shouldRevert;
        revertMessage = _revertMessage;
    }
}

contract MaliciousCallbackContract {
    function onLoanAccepted(uint256, uint256) external pure {
        // This is a malicious contract that should not be whitelisted
        revert("Malicious callback");
    }
}

/**
 * @title CallbackWhitelistTest
 * @notice Test suite for BullaFrendLend callback whitelist functionality
 */
contract CallbackWhitelistTest is BullaFrendLendTestHelper {
    MockCallbackContract public mockCallback;
    MockCallbackContract public mockCallback2;
    MaliciousCallbackContract public maliciousCallback;

    uint256 public constant FEE = 0.01 ether;

    uint256 public creditorPK = uint256(0x012345);
    uint256 public debtorPK = uint256(0x09876);
    uint256 public adminPK = uint256(0x111111);
    uint256 public nonAdminPK = uint256(0x222222);

    address public creditor;
    address public debtor;
    address public admin;
    address public nonAdmin;

    // Events we expect to be emitted
    event CallbackWhitelisted(address indexed callbackContract, bytes4 indexed selector);
    event CallbackRemovedFromWhitelist(address indexed callbackContract, bytes4 indexed selector);

    function setUp() public {
        weth = new WETH();

        creditor = vm.addr(creditorPK);
        debtor = vm.addr(debtorPK);
        admin = vm.addr(adminPK);
        nonAdmin = vm.addr(nonAdminPK);

        // Initialize the base contracts
        DeployContracts.DeploymentResult memory deploymentResult =
            (new DeployContracts()).deployForTest(address(this), LockState.Unlocked, FEE, 0, 0, admin);
        bullaClaim = BullaClaimV2(deploymentResult.bullaClaim);
        sigHelper = new EIP712Helper(address(bullaClaim));
        approvalRegistry = bullaClaim.approvalRegistry();

        // Initialize the BullaFrendLend contract with admin
        bullaFrendLend = new BullaFrendLendV2(address(bullaClaim), admin, 1000);

        // Deploy mock callback contracts
        mockCallback = new MockCallbackContract();
        mockCallback2 = new MockCallbackContract();
        maliciousCallback = new MaliciousCallbackContract();

        // Give parties some ETH
        vm.deal(creditor, 10 ether);
        vm.deal(debtor, 10 ether);
        vm.deal(admin, 10 ether);
        vm.deal(nonAdmin, 10 ether);

        // Give creditor some WETH tokens
        vm.prank(creditor);
        weth.deposit{value: 5 ether}();
    }

    /*//////////////////////////////////////////////////////////////
                        WHITELIST MANAGEMENT TESTS
    //////////////////////////////////////////////////////////////*/

    function testAddCallbackToWhitelist() public {
        bytes4 selector = mockCallback.onLoanAccepted.selector;

        // Expect event to be emitted
        vm.expectEmit(true, true, false, false);
        emit CallbackWhitelisted(address(mockCallback), selector);

        // Admin should be able to add to whitelist
        vm.prank(admin);
        bullaFrendLend.addToCallbackWhitelist(address(mockCallback), selector);

        // Check it was added
        assertTrue(bullaFrendLend.isCallbackWhitelisted(address(mockCallback), selector));
    }

    function testRemoveCallbackFromWhitelist() public {
        bytes4 selector = mockCallback.onLoanAccepted.selector;

        // First add to whitelist
        vm.prank(admin);
        bullaFrendLend.addToCallbackWhitelist(address(mockCallback), selector);
        assertTrue(bullaFrendLend.isCallbackWhitelisted(address(mockCallback), selector));

        // Expect event to be emitted
        vm.expectEmit(true, true, false, false);
        emit CallbackRemovedFromWhitelist(address(mockCallback), selector);

        // Admin should be able to remove from whitelist
        vm.prank(admin);
        bullaFrendLend.removeFromCallbackWhitelist(address(mockCallback), selector);

        // Check it was removed
        assertFalse(bullaFrendLend.isCallbackWhitelisted(address(mockCallback), selector));
    }

    function testOnlyAdminCanManageWhitelist() public {
        bytes4 selector = mockCallback.onLoanAccepted.selector;

        // Non-admin should not be able to add to whitelist
        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonAdmin));
        bullaFrendLend.addToCallbackWhitelist(address(mockCallback), selector);

        // Non-admin should not be able to remove from whitelist
        vm.prank(admin);
        bullaFrendLend.addToCallbackWhitelist(address(mockCallback), selector);

        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonAdmin));
        bullaFrendLend.removeFromCallbackWhitelist(address(mockCallback), selector);
    }

    function testAddMultipleCallbacksToWhitelist() public {
        bytes4 selector1 = mockCallback.onLoanAccepted.selector;
        bytes4 selector2 = mockCallback.handleLoanProcessed.selector;
        bytes4 selector3 = mockCallback.notifyLoanEvent.selector; // Use a different selector from the same contract

        vm.startPrank(admin);

        // Add multiple callbacks with different selectors
        bullaFrendLend.addToCallbackWhitelist(address(mockCallback), selector1);
        bullaFrendLend.addToCallbackWhitelist(address(mockCallback), selector2);
        bullaFrendLend.addToCallbackWhitelist(address(mockCallback2), selector1); // Use same selector but different contract

        vm.stopPrank();

        // Check all were added
        assertTrue(bullaFrendLend.isCallbackWhitelisted(address(mockCallback), selector1));
        assertTrue(bullaFrendLend.isCallbackWhitelisted(address(mockCallback), selector2));
        assertTrue(bullaFrendLend.isCallbackWhitelisted(address(mockCallback2), selector1));

        // Check that other combinations are not whitelisted
        assertFalse(bullaFrendLend.isCallbackWhitelisted(address(mockCallback), selector3));
        assertFalse(bullaFrendLend.isCallbackWhitelisted(address(mockCallback2), selector2));
        assertFalse(bullaFrendLend.isCallbackWhitelisted(address(mockCallback2), selector3));
    }

    /*//////////////////////////////////////////////////////////////
                        LOAN OFFER VALIDATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testCannotCreateLoanOfferWithNonWhitelistedCallback() public {
        bytes4 selector = mockCallback.onLoanAccepted.selector;

        // Create loan offer with non-whitelisted callback
        LoanRequestParams memory offer = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withCallback(address(mockCallback), selector).build();

        // Should revert because callback is not whitelisted
        vm.prank(creditor);
        vm.expectRevert(CallbackNotWhitelisted.selector);
        bullaFrendLend.offerLoan(offer);
    }

    function testCanCreateLoanOfferWithWhitelistedCallback() public {
        bytes4 selector = mockCallback.onLoanAccepted.selector;

        // Whitelist the callback
        vm.prank(admin);
        bullaFrendLend.addToCallbackWhitelist(address(mockCallback), selector);

        // Create loan offer with whitelisted callback
        LoanRequestParams memory offer = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withCallback(address(mockCallback), selector).build();

        // Should succeed
        vm.prank(creditor);
        uint256 offerId = bullaFrendLend.offerLoan(offer);
        assertEq(offerId, 0);
    }

    function testCannotCreateLoanOfferWithWhitelistedContractButWrongSelector() public {
        bytes4 correctSelector = mockCallback.onLoanAccepted.selector;
        bytes4 wrongSelector = mockCallback.handleLoanProcessed.selector;

        // Whitelist one selector but not the other
        vm.prank(admin);
        bullaFrendLend.addToCallbackWhitelist(address(mockCallback), correctSelector);

        // Try to create loan offer with wrong selector
        LoanRequestParams memory offer = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withCallback(address(mockCallback), wrongSelector).build();

        // Should revert because wrong selector
        vm.prank(creditor);
        vm.expectRevert(CallbackNotWhitelisted.selector);
        bullaFrendLend.offerLoan(offer);
    }

    function testCanStillCreateLoanOfferWithoutCallback() public {
        // Create loan offer without callback (should always work)
        LoanRequestParams memory offer =
            new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth)).build();

        // Should succeed regardless of whitelist
        vm.prank(creditor);
        uint256 offerId = bullaFrendLend.offerLoan(offer);
        assertEq(offerId, 0);
    }

    function testLoanOfferWithMetadataRespectsWhitelist() public {
        bytes4 selector = mockCallback.onLoanAccepted.selector;

        // Create loan offer with metadata and non-whitelisted callback
        LoanRequestParams memory offer = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withCallback(address(mockCallback), selector).build();

        ClaimMetadata memory metadata = ClaimMetadata({tokenURI: "test-uri", attachmentURI: "test-attachment"});

        // Should revert because callback is not whitelisted
        vm.prank(creditor);
        vm.expectRevert(CallbackNotWhitelisted.selector);
        bullaFrendLend.offerLoanWithMetadata(offer, metadata);

        // Whitelist the callback and try again
        vm.prank(admin);
        bullaFrendLend.addToCallbackWhitelist(address(mockCallback), selector);

        // Should succeed now
        vm.prank(creditor);
        uint256 offerId = bullaFrendLend.offerLoanWithMetadata(offer, metadata);
        assertEq(offerId, 0);
    }

    /*//////////////////////////////////////////////////////////////
                        LOAN ACCEPTANCE AND EXECUTION TESTS
    //////////////////////////////////////////////////////////////*/

    function testWhitelistedCallbackExecutesOnLoanAcceptance() public {
        bytes4 selector = mockCallback.onLoanAccepted.selector;

        // Whitelist the callback
        vm.prank(admin);
        bullaFrendLend.addToCallbackWhitelist(address(mockCallback), selector);

        // Setup approvals
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 2 ether);
        _permitAcceptLoan(debtorPK);

        // Create loan offer with whitelisted callback
        LoanRequestParams memory offer = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withCallback(address(mockCallback), selector).build();

        vm.prank(creditor);
        uint256 loanOfferId = bullaFrendLend.offerLoan(offer);

        // Accept the loan - callback should execute
        vm.prank(debtor);
        uint256 claimId = bullaFrendLend.acceptLoan{value: FEE}(loanOfferId);

        // Verify callback was executed
        MockCallbackContract.CallbackData memory data = mockCallback.getCallbackData(loanOfferId);
        assertEq(data.loanOfferId, loanOfferId);
        assertEq(data.claimId, claimId);
        assertEq(data.callCount, 1);
    }

    function testCallbackRemovedFromWhitelistBlocksNewOffers() public {
        bytes4 selector = mockCallback.onLoanAccepted.selector;

        // Whitelist the callback
        vm.prank(admin);
        bullaFrendLend.addToCallbackWhitelist(address(mockCallback), selector);

        // Create loan offer successfully
        LoanRequestParams memory offer = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withCallback(address(mockCallback), selector).build();

        vm.prank(creditor);
        uint256 offerId1 = bullaFrendLend.offerLoan(offer);
        assertEq(offerId1, 0);

        // Remove from whitelist
        vm.prank(admin);
        bullaFrendLend.removeFromCallbackWhitelist(address(mockCallback), selector);

        // Try to create another loan offer - should fail
        vm.prank(creditor);
        vm.expectRevert(CallbackNotWhitelisted.selector);
        bullaFrendLend.offerLoan(offer);
    }

    /*//////////////////////////////////////////////////////////////
                        EDGE CASE TESTS
    //////////////////////////////////////////////////////////////*/

    function testWhitelistingZeroAddressIsNoop() public {
        bytes4 selector = bytes4(0x12345678);

        // Should not revert but also should not affect validation
        vm.prank(admin);
        bullaFrendLend.addToCallbackWhitelist(address(0), selector);

        // Check that zero address is not actually whitelisted
        assertFalse(bullaFrendLend.isCallbackWhitelisted(address(0), selector));
    }

    function testWhitelistingZeroSelectorIsNoop() public {
        bytes4 zeroSelector = bytes4(0);

        // Should not revert but also should not affect validation
        vm.prank(admin);
        bullaFrendLend.addToCallbackWhitelist(address(mockCallback), zeroSelector);

        // Check that zero selector is not actually whitelisted
        assertFalse(bullaFrendLend.isCallbackWhitelisted(address(mockCallback), zeroSelector));
    }

    function testReaddingAlreadyWhitelistedCallback() public {
        bytes4 selector = mockCallback.onLoanAccepted.selector;

        // Add to whitelist
        vm.prank(admin);
        bullaFrendLend.addToCallbackWhitelist(address(mockCallback), selector);
        assertTrue(bullaFrendLend.isCallbackWhitelisted(address(mockCallback), selector));

        // Add again - should not revert and should still be whitelisted
        vm.prank(admin);
        bullaFrendLend.addToCallbackWhitelist(address(mockCallback), selector);
        assertTrue(bullaFrendLend.isCallbackWhitelisted(address(mockCallback), selector));
    }

    function testRemovingNonWhitelistedCallback() public {
        bytes4 selector = mockCallback.onLoanAccepted.selector;

        // Try to remove something that was never added - should not revert
        vm.prank(admin);
        bullaFrendLend.removeFromCallbackWhitelist(address(mockCallback), selector);
        assertFalse(bullaFrendLend.isCallbackWhitelisted(address(mockCallback), selector));
    }

    /*//////////////////////////////////////////////////////////////
                        SECURITY TESTS
    //////////////////////////////////////////////////////////////*/

    function testMaliciousCallbackCannotBeUsedWithoutWhitelisting() public {
        bytes4 selector = maliciousCallback.onLoanAccepted.selector;

        // Try to create loan offer with malicious callback (not whitelisted)
        LoanRequestParams memory offer = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withCallback(address(maliciousCallback), selector).build();

        // Should revert because callback is not whitelisted
        vm.prank(creditor);
        vm.expectRevert(CallbackNotWhitelisted.selector);
        bullaFrendLend.offerLoan(offer);
    }

    function testEvenWhitelistedMaliciousCallbackCanStillRevert() public {
        bytes4 selector = maliciousCallback.onLoanAccepted.selector;

        // Admin mistakenly whitelists malicious callback
        vm.prank(admin);
        bullaFrendLend.addToCallbackWhitelist(address(maliciousCallback), selector);

        // Setup approvals
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 2 ether);
        _permitAcceptLoan(debtorPK);

        // Create loan offer with whitelisted malicious callback
        LoanRequestParams memory offer = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withCallback(address(maliciousCallback), selector).build();

        vm.prank(creditor);
        uint256 loanOfferId = bullaFrendLend.offerLoan(offer);

        // Accept the loan - should fail because malicious callback reverts
        vm.prank(debtor);
        vm.expectRevert(); // Expecting CallbackFailed but need to check the exact format
        bullaFrendLend.acceptLoan{value: FEE}(loanOfferId);
    }
}
