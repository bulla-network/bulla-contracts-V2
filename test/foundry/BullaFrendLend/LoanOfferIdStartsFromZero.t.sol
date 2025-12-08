// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {WETH} from "contracts/mocks/weth.sol";
import {BullaFrendLendV2, LoanOfferNotFound} from "contracts/BullaFrendLendV2.sol";
import {BullaClaimV2} from "contracts/BullaClaimV2.sol";
import {DeployContracts} from "script/DeployContracts.s.sol";
import {LoanRequestParams, LoanOffer} from "contracts/interfaces/IBullaFrendLendV2.sol";
import {InterestConfig} from "contracts/libraries/CompoundInterestLib.sol";
import {LockState} from "contracts/types/Types.sol";

/// @title Test to validate hash-based LoanOfferId behavior
/// @notice This test validates that offer IDs are unique and reorg-resistant
contract TestLoanOfferIdStartsFromZero is Test {
    BullaFrendLendV2 internal bullaFrendLend;
    WETH internal weth;

    address creditor = makeAddr("creditor");
    address debtor = makeAddr("debtor");

    function setUp() public {
        DeployContracts deployer = new DeployContracts();
        DeployContracts.DeploymentResult memory result = deployer.deployForTest(
            address(this), // deployer
            LockState.Unlocked, // initialLockState
            10000000000000000, // coreProtocolFee (0.01 ETH)
            500, // invoiceProtocolFeeBPS (5%)
            500, // frendLendProtocolFeeBPS (5%)
            0, // frendLendProcessingFeeBPS
            address(this) // admin
        );

        BullaClaimV2 bullaClaim = BullaClaimV2(result.bullaClaim);
        bullaFrendLend = new BullaFrendLendV2(address(bullaClaim), address(this), 500, 0); // 5% protocol fee, 0 processing fee

        weth = new WETH();

        // Fund creditor with WETH
        vm.deal(creditor, 10 ether);
        vm.prank(creditor);
        weth.deposit{value: 5 ether}();
    }

    /// @notice Test that validates hash-based offer IDs are unique
    function testHashBasedOfferIds() public {
        // Verify initial nonce state
        assertEq(bullaFrendLend.loanOfferNonces(creditor), 0, "Initial nonce should be 0");

        LoanRequestParams memory loanParams = LoanRequestParams({
            termLength: 30 days,
            interestConfig: InterestConfig({
                interestRateBps: 500, // 5%
                numberOfPeriodsPerYear: 12
            }),
            loanAmount: 1 ether,
            creditor: creditor,
            debtor: debtor,
            description: "First loan offer",
            token: address(weth),
            impairmentGracePeriod: 7 days,
            expiresAt: 0,
            callbackContract: address(0),
            callbackSelector: bytes4(0)
        });

        // Approve the contract to spend creditor's WETH (needed for when loan is accepted)
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 2 ether);

        // Create first loan offer
        vm.prank(creditor);
        uint256 firstOfferId = bullaFrendLend.offerLoan(loanParams);

        assertEq(bullaFrendLend.loanOfferNonces(creditor), 1, "Nonce should be 1 after first offer");

        // Verify offer exists and can be retrieved
        LoanOffer memory retrievedOffer = bullaFrendLend.getLoanOffer(firstOfferId);
        assertEq(retrievedOffer.params.loanAmount, 1 ether, "First offer should be retrievable");
        assertEq(retrievedOffer.params.creditor, creditor, "Creditor should match");
        assertEq(retrievedOffer.requestedByCreditor, true, "Should be requested by creditor");

        // Create second loan offer with different params - should get different ID
        loanParams.loanAmount = 2 ether;
        loanParams.description = "Second loan offer";

        vm.prank(creditor);
        uint256 secondOfferId = bullaFrendLend.offerLoan(loanParams);

        assertEq(bullaFrendLend.loanOfferNonces(creditor), 2, "Nonce should be 2 after second offer");
        assertTrue(firstOfferId != secondOfferId, "Different offers should have different IDs");

        // Verify second offer exists and can be retrieved
        LoanOffer memory secondOffer = bullaFrendLend.getLoanOffer(secondOfferId);
        assertEq(secondOffer.params.loanAmount, 2 ether, "Second offer should be retrievable");
        assertEq(secondOffer.params.description, "Second loan offer", "Description should match");
    }

    /// @notice Test that different users can have same nonce but get different offer IDs
    function testDifferentUsersGetDifferentOfferIds() public {
        address creditor2 = makeAddr("creditor2");

        // Fund second creditor
        vm.deal(creditor2, 10 ether);
        vm.prank(creditor2);
        weth.deposit{value: 5 ether}();
        vm.prank(creditor2);
        weth.approve(address(bullaFrendLend), 2 ether);

        LoanRequestParams memory loanParams = LoanRequestParams({
            termLength: 30 days,
            interestConfig: InterestConfig({interestRateBps: 500, numberOfPeriodsPerYear: 12}),
            loanAmount: 1 ether,
            creditor: creditor, // Will be changed for each user
            debtor: debtor,
            description: "Test loan",
            token: address(weth),
            impairmentGracePeriod: 7 days,
            expiresAt: 0,
            callbackContract: address(0),
            callbackSelector: bytes4(0)
        });

        // Creditor 1 creates offer
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 1 ether);
        vm.prank(creditor);
        uint256 offerId1 = bullaFrendLend.offerLoan(loanParams);

        // Creditor 2 creates offer with same params but different creditor
        loanParams.creditor = creditor2;
        vm.prank(creditor2);
        uint256 offerId2 = bullaFrendLend.offerLoan(loanParams);

        // Both users have nonce 1 now
        assertEq(bullaFrendLend.loanOfferNonces(creditor), 1, "Creditor 1 nonce should be 1");
        assertEq(bullaFrendLend.loanOfferNonces(creditor2), 1, "Creditor 2 nonce should be 1");

        // But offer IDs should be different (different offerer in hash)
        assertTrue(offerId1 != offerId2, "Different creditors should get different offer IDs even with same params");
    }

    /// @notice Test that non-existent offer IDs revert correctly
    function testGetNonExistentOfferReverts() public {
        // Initially no offers exist
        assertEq(bullaFrendLend.loanOfferNonces(creditor), 0, "Initial nonce should be 0");

        // Random offer ID that doesn't exist should revert
        uint256 randomId = 12345;
        vm.expectRevert(LoanOfferNotFound.selector);
        bullaFrendLend.getLoanOffer(randomId);

        vm.expectRevert(LoanOfferNotFound.selector);
        bullaFrendLend.getLoanOfferMetadata(randomId);

        // Create one offer
        LoanRequestParams memory loanParams = LoanRequestParams({
            termLength: 30 days,
            interestConfig: InterestConfig({
                interestRateBps: 500, // 5%
                numberOfPeriodsPerYear: 12
            }),
            loanAmount: 1 ether,
            creditor: creditor,
            debtor: debtor,
            description: "Test offer",
            token: address(weth),
            impairmentGracePeriod: 7 days,
            expiresAt: 0,
            callbackContract: address(0),
            callbackSelector: bytes4(0)
        });

        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 1 ether);

        vm.prank(creditor);
        uint256 offerId = bullaFrendLend.offerLoan(loanParams);

        // Now the actual offer ID should work
        LoanOffer memory validOffer = bullaFrendLend.getLoanOffer(offerId);
        assertEq(validOffer.params.loanAmount, 1 ether, "Valid offer should be retrievable");
        assertEq(validOffer.params.creditor, creditor, "Creditor should match");

        // But a different random ID should still revert
        vm.expectRevert(LoanOfferNotFound.selector);
        bullaFrendLend.getLoanOffer(randomId);
    }

    /// @notice Test that same parameters with different nonce produce different ID (reorg protection)
    function testSameParametersProduceDifferentIdWithDifferentNonce() public {
        LoanRequestParams memory loanParams = LoanRequestParams({
            termLength: 30 days,
            interestConfig: InterestConfig({interestRateBps: 500, numberOfPeriodsPerYear: 12}),
            loanAmount: 1 ether,
            creditor: creditor,
            debtor: debtor,
            description: "Test offer",
            token: address(weth),
            impairmentGracePeriod: 7 days,
            expiresAt: 0,
            callbackContract: address(0),
            callbackSelector: bytes4(0)
        });

        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 2 ether);

        // Create first offer
        vm.prank(creditor);
        uint256 offerId1 = bullaFrendLend.offerLoan(loanParams);

        // Create second offer with EXACTLY same params
        // The nonce has incremented automatically, so the ID WILL be different
        vm.prank(creditor);
        uint256 offerId2 = bullaFrendLend.offerLoan(loanParams);

        // IDs should be different because nonce incremented
        assertTrue(offerId1 != offerId2, "Same params but different nonce should produce different ID");
    }
}
