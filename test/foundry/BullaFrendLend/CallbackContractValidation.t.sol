// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {WETH} from "contracts/mocks/weth.sol";
import {BullaFrendLendV2, InvalidCallback} from "contracts/BullaFrendLendV2.sol";
import {BullaClaimV2} from "contracts/BullaClaimV2.sol";
import {DeployContracts} from "script/DeployContracts.s.sol";
import {LoanRequestParams} from "contracts/interfaces/IBullaFrendLendV2.sol";
import {InterestConfig} from "contracts/libraries/CompoundInterestLib.sol";
import {LockState, ClaimMetadata} from "contracts/types/Types.sol";

/// @title Test to validate callback contract address validation
/// @notice This test ensures that callback contracts must be either zero address or valid smart contracts
contract TestCallbackContractValidation is Test {
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

    /// @notice Test that loan offers with EOA callback addresses are rejected
    function testCannotCreateLoanOfferWithEOACallbackAddress() public {
        // Create an EOA address (externally owned account)
        address eoaAddress = makeAddr("someEOA");

        LoanRequestParams memory loanParams = LoanRequestParams({
            termLength: 30 days,
            interestConfig: InterestConfig({
                interestRateBps: 500, // 5%
                numberOfPeriodsPerYear: 12
            }),
            loanAmount: 1 ether,
            creditor: creditor,
            debtor: debtor,
            description: "Loan with invalid callback",
            token: address(weth),
            impairmentGracePeriod: 7 days,
            expiresAt: 0,
            callbackContract: eoaAddress, // This is an EOA, not a contract
            callbackSelector: bytes4(keccak256("onLoanAccepted(uint256,uint256)"))
        });

        // Should revert with InvalidCallback because EOA has no code
        vm.prank(creditor);
        vm.expectRevert(InvalidCallback.selector);
        bullaFrendLend.offerLoan(loanParams);
    }

    /// @notice Test that loan offers with zero callback address work
    function testCanCreateLoanOfferWithZeroCallbackAddress() public {
        LoanRequestParams memory loanParams = LoanRequestParams({
            termLength: 30 days,
            interestConfig: InterestConfig({
                interestRateBps: 500, // 5%
                numberOfPeriodsPerYear: 12
            }),
            loanAmount: 1 ether,
            creditor: creditor,
            debtor: debtor,
            description: "Loan with no callback",
            token: address(weth),
            impairmentGracePeriod: 7 days,
            expiresAt: 0,
            callbackContract: address(0), // Zero address should be allowed
            callbackSelector: bytes4(0)
        });

        // Should work fine
        vm.prank(creditor);
        uint256 offerId = bullaFrendLend.offerLoan(loanParams);
        assertEq(offerId, 0, "Loan offer should be created successfully");
    }

    /// @notice Test that loan offers with valid smart contract callback addresses work
    function testCanCreateLoanOfferWithValidContractCallbackAddress() public {
        // Deploy a simple mock callback contract
        MockCallbackContract mockCallback = new MockCallbackContract();

        LoanRequestParams memory loanParams = LoanRequestParams({
            termLength: 30 days,
            interestConfig: InterestConfig({
                interestRateBps: 500, // 5%
                numberOfPeriodsPerYear: 12
            }),
            loanAmount: 1 ether,
            creditor: creditor,
            debtor: debtor,
            description: "Loan with valid callback",
            token: address(weth),
            impairmentGracePeriod: 7 days,
            expiresAt: 0,
            callbackContract: address(mockCallback), // Valid contract address
            callbackSelector: bytes4(keccak256("onLoanAccepted(uint256,uint256)"))
        });

        // Should work fine
        vm.prank(creditor);
        uint256 offerId = bullaFrendLend.offerLoan(loanParams);
        assertEq(offerId, 0, "Loan offer should be created successfully with valid callback contract");
    }

    /// @notice Test edge case: using a precompiled contract address
    function testCannotCreateLoanOfferWithPrecompiledContractAddress() public {
        // Use a precompiled contract address (e.g., ecrecover at 0x01)
        // These addresses have no code but are considered "contracts" by the EVM
        address precompiled = address(0x01);

        LoanRequestParams memory loanParams = LoanRequestParams({
            termLength: 30 days,
            interestConfig: InterestConfig({
                interestRateBps: 500, // 5%
                numberOfPeriodsPerYear: 12
            }),
            loanAmount: 1 ether,
            creditor: creditor,
            debtor: debtor,
            description: "Loan with precompiled callback",
            token: address(weth),
            impairmentGracePeriod: 7 days,
            expiresAt: 0,
            callbackContract: precompiled, // Precompiled contract address
            callbackSelector: bytes4(keccak256("onLoanAccepted(uint256,uint256)"))
        });

        // Should revert because precompiled contracts have no code
        vm.prank(creditor);
        vm.expectRevert(InvalidCallback.selector);
        bullaFrendLend.offerLoan(loanParams);
    }

    /// @notice Test that callback validation also applies to loan offers with metadata
    function testCallbackValidationAppliesWithMetadata() public {
        address eoaAddress = makeAddr("someEOA");

        LoanRequestParams memory loanParams = LoanRequestParams({
            termLength: 30 days,
            interestConfig: InterestConfig({
                interestRateBps: 500, // 5%
                numberOfPeriodsPerYear: 12
            }),
            loanAmount: 1 ether,
            creditor: creditor,
            debtor: debtor,
            description: "Loan with invalid callback and metadata",
            token: address(weth),
            impairmentGracePeriod: 7 days,
            expiresAt: 0,
            callbackContract: eoaAddress, // This is an EOA, not a contract
            callbackSelector: bytes4(keccak256("onLoanAccepted(uint256,uint256)"))
        });

        // Should revert even when using offerLoanWithMetadata
        vm.prank(creditor);
        vm.expectRevert(InvalidCallback.selector);
        bullaFrendLend.offerLoanWithMetadata(
            loanParams, ClaimMetadata({tokenURI: "test-uri", attachmentURI: "test-attachment"})
        );
    }
}

/**
 * @title MockCallbackContract
 * @notice Simple mock contract for testing valid callback addresses
 */
contract MockCallbackContract {
    event CallbackExecuted(uint256 loanOfferId, uint256 claimId);

    function onLoanAccepted(uint256 loanOfferId, uint256 claimId) external {
        emit CallbackExecuted(loanOfferId, claimId);
    }
}
