pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import {WETH} from "contracts/mocks/weth.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
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
import {BullaFrendLendV2, LoanRequestParams, Loan, LoanOffer, CallbackFailed} from "src/BullaFrendLendV2.sol";
import {DeployContracts} from "script/DeployContracts.s.sol";
import {BullaFrendLendTestHelper} from "test/foundry/BullaFrendLend/BullaFrendLendTestHelper.sol";
import {EIP712Helper} from "test/foundry/BullaClaim/BullaClaimTestHelper.sol";
import {LoanRequestParamsBuilder} from "test/foundry/BullaFrendLend/LoanRequestParamsBuilder.t.sol";

/**
 * @title MockCallbackContract
 * @notice Mock contract for testing callback functionality
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

    function setRevertBehavior(bool _shouldRevert, string memory _revertMessage) external {
        shouldRevert = _shouldRevert;
        revertMessage = _revertMessage;
    }

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

    function getCallbackData(uint256 loanOfferId) external view returns (CallbackData memory) {
        return callbackData[loanOfferId];
    }
}

/**
 * @title CallbackFeatureTest
 * @notice Test suite for BullaFrendLend callback functionality
 */
contract CallbackFeatureTest is BullaFrendLendTestHelper {
    MockCallbackContract public mockCallback;
    uint256 public constant FEE = 0.01 ether;

    event CallbackExecuted(bytes4 selector, uint256 loanOfferId, uint256 claimId);

    uint256 public creditorPK = uint256(0x012345);
    uint256 public debtorPK = uint256(0x09876);

    address public creditor;
    address public debtor;

    function setUp() public {
        weth = new WETH();

        creditor = vm.addr(creditorPK);
        debtor = vm.addr(debtorPK);

        // Initialize the base contracts
        DeployContracts.DeploymentResult memory deploymentResult =
            (new DeployContracts()).deployForTest(address(this), LockState.Unlocked, FEE, 0, 0, 0, address(this));
        bullaClaim = BullaClaimV2(deploymentResult.bullaClaim);
        sigHelper = new EIP712Helper(address(bullaClaim));
        approvalRegistry = bullaClaim.approvalRegistry();

        // Initialize the BullaFrendLend contract
        bullaFrendLend = new BullaFrendLendV2(address(bullaClaim), creditor, 1000, 0); // 10% protocol fee, 0 processing fee

        mockCallback = new MockCallbackContract();

        // Give both parties some ETH for gas and transactions
        vm.deal(creditor, 10 ether);
        vm.deal(debtor, 10 ether);

        // Give both parties some WETH tokens
        vm.prank(creditor);
        weth.deposit{value: 5 ether}();

        vm.prank(debtor);
        weth.deposit{value: 5 ether}();
    }

    function testLoanOfferWithValidCallback() public {
        // Whitelist the callback first
        vm.prank(creditor); // creditor is admin
        bullaFrendLend.addToCallbackWhitelist(address(mockCallback), mockCallback.onLoanAccepted.selector);

        // Create loan offer with callback
        LoanRequestParams memory offer = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withCallback(address(mockCallback), mockCallback.onLoanAccepted.selector).build();

        vm.prank(creditor);
        uint256 loanOfferId = bullaFrendLend.offerLoan(offer);

        // Verify the offer was created with callback data
        LoanOffer memory loanOffer = bullaFrendLend.getLoanOffer(loanOfferId);
        assertEq(loanOffer.params.callbackContract, address(mockCallback));
        assertEq(loanOffer.params.callbackSelector, mockCallback.onLoanAccepted.selector);
    }

    function testCallbackExecutionOnLoanAcceptance() public {
        // Whitelist the callback first
        vm.prank(creditor); // creditor is admin
        bullaFrendLend.addToCallbackWhitelist(address(mockCallback), mockCallback.onLoanAccepted.selector);

        // Setup approvals
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 2 ether);

        _permitAcceptLoan(debtorPK);

        // Create loan offer with callback
        LoanRequestParams memory offer = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withCallback(address(mockCallback), mockCallback.onLoanAccepted.selector).build();

        vm.prank(creditor);
        uint256 loanOfferId = bullaFrendLend.offerLoan(offer);

        // Expect callback event to be emitted
        vm.expectEmit(true, true, true, true);
        emit CallbackExecuted(mockCallback.onLoanAccepted.selector, loanOfferId, 0);

        // Accept the loan
        vm.prank(debtor);
        uint256 claimId = bullaFrendLend.acceptLoan{value: FEE}(loanOfferId);

        // Verify callback was executed with correct parameters
        MockCallbackContract.CallbackData memory data = mockCallback.getCallbackData(loanOfferId);
        assertEq(data.loanOfferId, loanOfferId);
        assertEq(data.claimId, claimId);
        assertEq(data.callCount, 1);
    }

    function testNoCallbackWhenNotConfigured() public {
        // Setup approvals
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 2 ether);

        _permitAcceptLoan(debtorPK);

        // Create loan offer without callback
        LoanRequestParams memory offer =
            new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor).withToken(address(weth)).build();

        vm.prank(creditor);
        uint256 loanOfferId = bullaFrendLend.offerLoan(offer);

        // Accept the loan
        vm.prank(debtor);
        bullaFrendLend.acceptLoan{value: FEE}(loanOfferId);

        // Verify no callback was executed (using a non-existent loanOfferId)
        MockCallbackContract.CallbackData memory data = mockCallback.getCallbackData(loanOfferId);
        assertEq(data.callCount, 0);
    }

    function testCallbackFailureHandling() public {
        // Whitelist the callback first
        vm.prank(creditor); // creditor is admin
        bullaFrendLend.addToCallbackWhitelist(address(mockCallback), mockCallback.onLoanAccepted.selector);

        // Setup approvals
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 2 ether);

        _permitAcceptLoan(debtorPK);

        // Configure mock to revert
        mockCallback.setRevertBehavior(true, "Callback intentionally failed");

        // Create loan offer with callback
        LoanRequestParams memory offer = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withCallback(address(mockCallback), mockCallback.onLoanAccepted.selector).build();

        vm.prank(creditor);
        uint256 loanOfferId = bullaFrendLend.offerLoan(offer);

        // Attempt to accept loan should fail due to callback revert
        vm.prank(debtor);
        vm.expectRevert(
            abi.encodeWithSelector(
                CallbackFailed.selector, abi.encodeWithSignature("Error(string)", "Callback intentionally failed")
            )
        );
        bullaFrendLend.acceptLoan{value: FEE}(loanOfferId);

        assertEq(bullaFrendLend.getLoanOffer(loanOfferId).params.creditor, creditor, "loan offer not accepted");
    }

    function testMultipleCallbackExecutions() public {
        // Whitelist the callback first
        vm.prank(creditor); // creditor is admin
        bullaFrendLend.addToCallbackWhitelist(address(mockCallback), mockCallback.onLoanAccepted.selector);

        // Setup approvals
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 4 ether);

        _permitAcceptLoan(debtorPK, 2);

        // Create first loan offer with callback
        LoanRequestParams memory offer1 = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withCallback(address(mockCallback), mockCallback.onLoanAccepted.selector).build();

        vm.prank(creditor);
        uint256 loanOfferId1 = bullaFrendLend.offerLoan(offer1);

        // Create second loan offer with same callback
        LoanRequestParams memory offer2 = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withCallback(address(mockCallback), mockCallback.onLoanAccepted.selector).build();

        vm.prank(creditor);
        uint256 loanOfferId2 = bullaFrendLend.offerLoan(offer2);

        // Accept first loan
        vm.prank(debtor);
        uint256 claimId1 = bullaFrendLend.acceptLoan{value: FEE}(loanOfferId1);

        // Verify first callback was executed
        MockCallbackContract.CallbackData memory data1 = mockCallback.getCallbackData(loanOfferId1);
        assertEq(data1.loanOfferId, loanOfferId1);
        assertEq(data1.claimId, claimId1);
        assertEq(data1.callCount, 1);

        // Accept second loan
        vm.prank(debtor);
        uint256 claimId2 = bullaFrendLend.acceptLoan{value: FEE}(loanOfferId2);

        // Verify second callback was executed
        MockCallbackContract.CallbackData memory data2 = mockCallback.getCallbackData(loanOfferId2);
        assertEq(data2.loanOfferId, loanOfferId2);
        assertEq(data2.claimId, claimId2);
        assertEq(data2.callCount, 1);
    }

    function testCallbackWithDebtorRequest() public {
        // Whitelist the callback first (admin needs to do this)
        vm.prank(creditor); // creditor is admin
        bullaFrendLend.addToCallbackWhitelist(address(mockCallback), mockCallback.onLoanAccepted.selector);

        // Setup approvals
        vm.prank(creditor);
        weth.approve(address(bullaFrendLend), 2 ether);

        _permitAcceptLoan(debtorPK);

        // Debtor creates a loan request with callback
        LoanRequestParams memory request = new LoanRequestParamsBuilder().withCreditor(creditor).withDebtor(debtor)
            .withToken(address(weth)).withCallback(address(mockCallback), mockCallback.onLoanAccepted.selector).build();

        vm.prank(debtor);
        uint256 requestId = bullaFrendLend.offerLoan(request);

        // Expect callback event to be emitted when creditor accepts
        vm.expectEmit(true, true, true, true);
        emit CallbackExecuted(mockCallback.onLoanAccepted.selector, requestId, 0);

        // Creditor accepts the loan request
        vm.prank(creditor);
        uint256 claimId = bullaFrendLend.acceptLoan{value: FEE}(requestId);

        // Verify callback was executed
        MockCallbackContract.CallbackData memory data = mockCallback.getCallbackData(requestId);
        assertEq(data.loanOfferId, requestId);
        assertEq(data.claimId, claimId);
        assertEq(data.callCount, 1);
    }
}
