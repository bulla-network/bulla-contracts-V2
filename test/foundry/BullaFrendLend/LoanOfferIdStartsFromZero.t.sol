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

/// @title Test to validate LoanOfferId behavior - whether first offerId starts from 0
/// @notice This test demonstrates the FIXED behavior where first offerId = 0
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
            address(this) // admin
        );

        BullaClaimV2 bullaClaim = BullaClaimV2(result.bullaClaim);
        bullaFrendLend = new BullaFrendLendV2(address(bullaClaim), address(this), 500);

        weth = new WETH();

        // Fund creditor with WETH
        vm.deal(creditor, 10 ether);
        vm.prank(creditor);
        weth.deposit{value: 5 ether}();
    }

    /// @notice Test that validates first loanOfferId = 0 and sequential assignment
    function testFirstLoanOfferIdIsZero() public {
        // Verify initial state
        assertEq(bullaFrendLend.loanOfferCount(), 0, "Initial loanOfferCount should be 0");

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

        // Create first loan offer - should get offerId = 0 (FIXED behavior with post-increment)
        vm.prank(creditor);
        uint256 firstOfferId = bullaFrendLend.offerLoan(loanParams);
        assertEq(firstOfferId, 0, "First loan offer should have offerId = 0 (FIXED behavior)");
        assertEq(bullaFrendLend.loanOfferCount(), 1, "loanOfferCount should be 1 after first offer");

        // Verify offer exists and can be retrieved
        LoanOffer memory retrievedOffer = bullaFrendLend.getLoanOffer(0);
        assertEq(retrievedOffer.params.loanAmount, 1 ether, "First offer should be retrievable");
        assertEq(retrievedOffer.params.creditor, creditor, "Creditor should match");
        assertEq(retrievedOffer.requestedByCreditor, true, "Should be requested by creditor");

        // Create second loan offer - should get offerId = 1
        loanParams.loanAmount = 2 ether;
        loanParams.description = "Second loan offer";

        vm.prank(creditor);
        uint256 secondOfferId = bullaFrendLend.offerLoan(loanParams);
        assertEq(secondOfferId, 1, "Second loan offer should have offerId = 1");
        assertEq(bullaFrendLend.loanOfferCount(), 2, "loanOfferCount should be 2 after second offer");

        // Verify second offer exists and can be retrieved
        LoanOffer memory secondOffer = bullaFrendLend.getLoanOffer(1);
        assertEq(secondOffer.params.loanAmount, 2 ether, "Second offer should be retrievable");
        assertEq(secondOffer.params.description, "Second loan offer", "Description should match");
    }

    /// @notice Test boundary checking for getLoanOffer function
    function testGetLoanOfferBoundaryChecking() public {
        // Initially no offers exist, loanOfferCount = 0
        assertEq(bullaFrendLend.loanOfferCount(), 0);

        vm.expectRevert(LoanOfferNotFound.selector);
        bullaFrendLend.getLoanOffer(0);

        vm.expectRevert(LoanOfferNotFound.selector);
        bullaFrendLend.getLoanOfferMetadata(0);

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

        // Now offerId = 0 should work (actual offer exists)
        LoanOffer memory validOffer = bullaFrendLend.getLoanOffer(0);
        assertEq(validOffer.params.loanAmount, 1 ether, "Valid offer should be retrievable");
        assertEq(validOffer.params.creditor, creditor, "Creditor should match");
    }
}
