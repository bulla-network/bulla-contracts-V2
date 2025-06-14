// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.15;

import "contracts/types/Types.sol";
import {IERC1271} from "contracts/interfaces/IERC1271.sol";
import {BullaControllerRegistry} from "contracts/BullaControllerRegistry.sol";
import {EIP712} from "openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {SafeCastLib} from "solmate/utils/SafeCastLib.sol";
import {BoringBatchable} from "contracts/libraries/BoringBatchable.sol";
import {BullaClaimPermitLib} from "contracts/libraries/BullaClaimPermitLib.sol";
import {BullaClaimValidationLib} from "contracts/libraries/BullaClaimValidationLib.sol";
import {ERC721} from "solmate/tokens/ERC721.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {ClaimMetadataGenerator} from "contracts/ClaimMetadataGenerator.sol";
import "forge-std/console.sol";

contract BullaClaim is ERC721, EIP712, Ownable, BoringBatchable {
    using SafeTransferLib for ERC20;
    using SafeTransferLib for address;
    using SafeCastLib for uint256;

    /*///////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// a mapping of claimId to a packed struct
    mapping(uint256 => ClaimStorage) private claims;
    /// a mapping of claimId to token metadata if exists - both attachmentURIs and tokenURIs
    mapping(uint256 => ClaimMetadata) public claimMetadata;
    /// a mapping of users to controllers to approvals for specific actions
    mapping(address => mapping(address => Approvals)) public approvals;
    /// Restricts which functions can be called. Options: Unlocked, NoNewClaims, Locked:
    LockState public lockState;
    /// the total amount of claims minted
    uint256 public currentClaimId;
    /// a registry of controller names vetted by Bulla Network
    BullaControllerRegistry public controllerRegistry;
    /// a contract to generate an on-chain SVG with a claim's status
    ClaimMetadataGenerator public claimMetadataGenerator;

    /*///////////////////////////////////////////////////////////////
                            ERRORS / MODIFIERS
    //////////////////////////////////////////////////////////////*/

    error Locked();
    error InvalidApproval();
    error InvalidSignature();
    error PastApprovalDeadline();
    error NotOwner();
    error NotController(address sender);
    error ClaimPending();
    error NotMinted();
    error PaymentUnderApproved();

    function _notLocked() internal view {
        if (lockState == LockState.Locked) revert Locked();
    }

    /*///////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

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

    event MetadataAdded(uint256 indexed claimId, string tokenURI, string attachmentURI);

    event ClaimPayment(uint256 indexed claimId, address indexed paidBy, uint256 paymentAmount, uint256 totalPaidAmount);

    event BindingUpdated(uint256 indexed claimId, address indexed from, ClaimBinding indexed binding);

    event ClaimRejected(uint256 indexed claimId, address indexed from, string note);

    event ClaimRescinded(uint256 indexed claimId, address indexed from, string note);

    event ClaimImpaired(uint256 indexed claimId);

    event ClaimMarkedAsPaid(uint256 indexed claimId);

    event CreateClaimApproved(
        address indexed user,
        address indexed controller,
        CreateClaimApprovalType indexed approvalType,
        uint256 approvalCount,
        bool isBindingAllowed
    );

    event PayClaimApproved(
        address indexed user,
        address indexed controller,
        PayClaimApprovalType indexed approvalType,
        uint256 approvalDeadline,
        ClaimPaymentApprovalParam[] paymentApprovals
    );

    event UpdateBindingApproved(address indexed user, address indexed controller, uint256 approvalCount);

    event CancelClaimApproved(address indexed user, address indexed controller, uint256 approvalCount);

    event ImpairClaimApproved(address indexed user, address indexed controller, uint256 approvalCount);

    event MarkAsPaidApproved(address indexed user, address indexed controller, uint256 approvalCount);

    constructor(address _controllerRegistry, LockState _lockState)
        ERC721("BullaClaim", "CLAIM")
        EIP712("BullaClaim", "1")
    {
        controllerRegistry = BullaControllerRegistry(_controllerRegistry);
        lockState = _lockState;
    }

    /*///////////////////////////////////////////////////////////////
                    CLAIM CREATION / UPDATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * /// CREATE FUNCTIONS ///
     */

    /// @notice allows a user to create a claim
    /// @notice SPEC:
    ///     1. create a claim from the msg.sender
    function createClaim(CreateClaimParams calldata params) external returns (uint256) {
        return _createClaim(msg.sender, params);
    }

    /// @notice allows a controller to create a claim on behalf of a user
    /// @notice SPEC:
    ///     1. verify and spend msg.sender's approval to create claims
    ///     2. create a claim on `from`'s behalf
    function createClaimFrom(address from, CreateClaimParams calldata params) external returns (uint256) {
        _spendCreateClaimApproval(from, msg.sender, params.creditor, params.debtor, params.binding);

        return _createClaim(from, params);
    }

    /// @notice allows a user to create a claim with optional attachmentURI and / or a custom tokenURI
    /// @notice SPEC:
    ///     1. create a claim with metadata from the msg.sender
    function createClaimWithMetadata(CreateClaimParams calldata params, ClaimMetadata calldata metadata)
        external
        returns (uint256)
    {
        return _createClaimWithMetadata(msg.sender, params, metadata);
    }

    /// @notice allows a controller to create a claim with optional attachmentURI and / or a custom tokenURI on behalf of a user
    /// @notice SPEC:
    ///     1. verify and spend msg.sender's approval to create claims
    ///     2. create a claim with metadata on `from`'s behalf
    function createClaimWithMetadataFrom(
        address from,
        CreateClaimParams calldata params,
        ClaimMetadata calldata metadata
    ) external returns (uint256) {
        _spendCreateClaimApproval(from, msg.sender, params.creditor, params.debtor, params.binding);

        return _createClaimWithMetadata(from, params, metadata);
    }

    /// @notice stores an attachmentURI, and / or a tokenURI indexed to the claimID, and creates a claim
    /// @return The newly created tokenId
    function _createClaimWithMetadata(address from, CreateClaimParams calldata params, ClaimMetadata calldata metadata)
        internal
        returns (uint256)
    {
        uint256 claimId = _createClaim(from, params);

        claimMetadata[claimId] = metadata;
        emit MetadataAdded(claimId, metadata.tokenURI, metadata.attachmentURI);

        return claimId;
    }

    /// @notice "spends" a controller's create claim approval
    /// @notice SPEC:
    /// A function can call this function to verify and "spend" `from`'s approval of `controller` to create a claim given the following:
    ///     S1. `controller` has > 0 approvalCount from the `from` address -> otherwise: reverts
    ///     S2. The creditor and debtor arguments are permissed by the `from` address, meaning:
    ///         - If the approvalType is `CreditorOnly` the `from` address must be the creditor -> otherwise: reverts
    ///         - If the approvalType is `DebtorOnly` the `from` address must be the debtor -> otherwise: reverts
    ///        Note: If the approvalType is `Approved`, the `controller` may specify the `from` address as the creditor, or the debtor
    ///     S3. If the claimBinding argument is `Bound`, then the isBindingAllowed permission must be set to true -> otherwise: reverts
    ///        Note: _createClaim will always revert if the claimBinding argument is `Bound` and the `from` address is not the debtor
    ///
    /// RES1: If the above are true, and the approvalCount != type(uint64).max, decrement the approval count by 1 and return -> otherwise: no-op
    /// RES2: If the approval count will be 0, then also set the approval to unapproved
    function _spendCreateClaimApproval(
        address from,
        address controller,
        address creditor,
        address debtor,
        ClaimBinding binding
    ) internal {
        CreateClaimApproval memory approval = approvals[from][controller].createClaim;

        // Use validation library for approval validation
        BullaClaimValidationLib.validateCreateClaimApproval(approval, from, creditor, debtor, binding);

        if (approval.approvalCount != type(uint64).max) {
            // spec.RES1, spec.RES2
            if (approval.approvalCount == 1) {
                approvals[from][controller].createClaim.approvalType = CreateClaimApprovalType.Unapproved;
            }
            approvals[from][controller].createClaim.approvalCount -= 1;
        }

        return;
    }

    /// @notice Creates a claim between two addresses for a certain amount and token
    /// @notice The claim NFT is minted to the creditor - in other words: the wallet owed money holds the NFT.
    ///         The holder of the NFT will receive the payment from the debtor - See `_payClaim()` for more details.
    /// @notice SPEC:
    ///         TODO
    /// @dev if the `token` param is address(0) then we consider the claim to be denominated in ETH - (native token)
    /// @return The newly created tokenId
    function _createClaim(address from, CreateClaimParams calldata params) internal returns (uint256) {
        if (lockState != LockState.Unlocked) revert Locked();

        // Use validation library for parameter validation
        BullaClaimValidationLib.validateCreateClaimParams(from, params);

        uint256 claimId;
        // from is only != to msg.sender if the claim is delegated
        address controller = msg.sender == from ? address(0) : msg.sender;
        {
            unchecked {
                claimId = ++currentClaimId;
            }

            ClaimStorage storage claim = claims[claimId];

            claim.claimAmount = params.claimAmount.safeCastTo128(); //TODO: is this necessary?
            claim.debtor = params.debtor;
            claim.originalCreditor = params.creditor;

            if (params.token != address(0)) claim.token = params.token;
            if (controller != address(0)) claim.controller = controller;
            if (params.binding != ClaimBinding.Unbound) claim.binding = params.binding;
            if (params.payerReceivesClaimOnPayment) claim.payerReceivesClaimOnPayment = true;
            if (params.dueBy != 0) claim.dueBy = uint40(params.dueBy);
            if (params.impairmentGracePeriod != 0) claim.impairmentGracePeriod = uint40(params.impairmentGracePeriod);
        }

        emit ClaimCreated(
            claimId,
            from,
            params.creditor,
            params.debtor,
            params.claimAmount,
            params.description,
            params.token,
            controller,
            params.binding
        );

        // mint the NFT to the creditor
        _mint(params.creditor, claimId);

        return claimId;
    }

    /**
     * /// PAY CLAIM ///
     */

    /// @notice allows any user to pay a claim
    /// @notice SPEC:
    ///     1. call payClaim on behalf of the msg.sender
    function payClaim(uint256 claimId, uint256 amount) external payable {
        _payClaim(msg.sender, claimId, amount);
    }

    /// @notice allows a controller to pay a claim on behalf of a user
    /// @notice SPEC:
    ///     1. verify and spend msg.sender's approval to pay claims for `from`
    ///     2. call payClaim on `from`'s behalf
    function payClaimFrom(address from, uint256 claimId, uint256 amount) external payable {
        _spendPayClaimApproval(from, msg.sender, claimId, amount);

        _payClaim(from, claimId, amount);
    }

    /// @notice Allows a controller to pay a claim without transferring tokens
    /// @dev This function is only callable by the controller of the claim
    /// @param from The address that is paying the claim
    /// @param claimId The ID of the claim to pay
    /// @param amount The amount to pay
    function payClaimFromControllerWithoutTransfer(address from, uint256 claimId, uint256 amount) external {
        _spendPayClaimApproval(from, msg.sender, claimId, amount);

        Claim memory claim = getClaim(claimId);

        // Only the controller can call this function
        if (claim.controller != msg.sender) revert NotController(msg.sender);

        _updateClaimPaymentState(from, claimId, amount);
    }

    /// @notice _spendPayClaimApproval() "spends" a controller's pay claim approval
    /// @notice SPEC:
    /// A function can call this internal function to verify and "spend" `from`'s approval of `controller` to pay a claim under the following circumstances:
    ///     SA1. The `approvalType` is not `Unapproved` -> otherwise: reverts
    ///     SA2. The contract LockStatus is not `Locked` -> otherwise: reverts
    ///
    ///     When the `approvalType` is `IsApprovedForSpecific`, then `controller` must be approved to pay that claim meaning:
    ///         AS1: `from` has approved payment for the `claimId` argument -> otherwise: reverts
    ///         AS2: `from` has approved payment for at least the `amount` argument -> otherwise: reverts
    ///         AS3: `from`'s approval has not expired, meaning:
    ///             AS3.1: If the controller has a "controller" expirary, then the controller expirary must be greater than the current block timestamp -> otherwise: reverts
    ///             AS3.2: If the controller does not have a controller expirary and instead has a claim-specific expirary,
    ///                 then the claim-specific expirary must be greater than the current block timestamp -> otherwise: reverts
    ///
    ///         AS.RES1: If the `amount` argument == the pre-approved amount on the permission, spend the permission -> otherwise: decrement the approved amount by `amount`
    ///
    ///     If the `approvalType` is `IsApprovedForAll`, then `controller` must be approved to pay, meaning:
    ///         AA1: `from`'s approval of `controller` has not expired -> otherwise: reverts
    ///
    ///         AA.RES1: This function allows execution to continue - (no storage needs to be updated)
    function _spendPayClaimApproval(address from, address controller, uint256 claimId, uint256 amount) internal {
        PayClaimApproval storage approval = approvals[from][controller].payClaim;

        // Use validation library for approval validation
        (uint256 approvalIndex,) = BullaClaimValidationLib.validatePayClaimApproval(approval, claimId, amount);

        // If approved for all, no storage updates needed
        if (approval.approvalType == PayClaimApprovalType.IsApprovedForAll) return;

        // Handle specific approval spending
        uint256 i = approvalIndex;
        if (amount == approval.claimApprovals[i].approvedAmount) {
            // Approval is fully spent, remove it
            uint256 totalApprovals = approval.claimApprovals.length;
            if (i != totalApprovals - 1) {
                approval.claimApprovals[i] = approval.claimApprovals[totalApprovals - 1];
            }
            approval.claimApprovals.pop();
        } else {
            // Partially spend the approval
            approval.claimApprovals[i].approvedAmount -= uint128(amount);
        }
    }

    /// @notice Allows any user to pay a claim with the token the claim is denominated in
    /// @notice NOTE: if the claim token is address(0) (eth) then we use the eth transferred to the contract. If this function is called via PayClaimFrom,
    ///     then the calling function must handle the sending of `from`'s eth to contract and then call this function.
    /// @notice SPEC:
    ///     Allow a user to pay a claim given:
    ///         1. The contract is not locked
    ///         2. The claim is minted and not burned
    ///         ... TODO
    function _payClaim(address from, uint256 claimId, uint256 paymentAmount) internal {
        Claim memory claim = getClaim(claimId);
        address creditor = _ownerOf[claimId];

        // We allow for claims to be "controlled". Meaning, it is another smart contract's responsibility to implement
        //      custom logic, then call these functions. We check the msg.sender against the controller to make sure a user
        //      isn't trying to bypass controller specific logic (eg: late fees) and by going to this contract directly.
        if (claim.controller != address(0) && msg.sender != claim.controller) revert NotController(msg.sender);

        // Update payment state first to follow checks-effects-interactions pattern
        _updateClaimPaymentState(from, claimId, paymentAmount);

        // Process token transfer after state is updated
        claim.token == address(0)
            ? creditor.safeTransferETH(paymentAmount)
            : ERC20(claim.token).safeTransferFrom(from, creditor, paymentAmount);
    }

    /// @notice Updates claim payment state without transferring tokens
    /// @param from The address that is paying the claim
    /// @param claimId The ID of the claim to pay
    /// @param paymentAmount The amount to pay
    function _updateClaimPaymentState(address from, uint256 claimId, uint256 paymentAmount) internal {
        _notLocked();
        Claim memory claim = getClaim(claimId);
        address creditor = _ownerOf[claimId];

        // Use validation library for payment validation and calculation
        (uint256 totalPaidAmount, bool claimPaid) =
            BullaClaimValidationLib.validateAndCalculatePayment(claim, paymentAmount);

        ClaimStorage storage claimStorage = claims[claimId];

        claimStorage.paidAmount = uint128(totalPaidAmount);
        // if the claim is now fully paid, update the status to paid
        // if the claim is still not fully paid, update the status to repaying
        claimStorage.status = claimPaid ? Status.Paid : Status.Repaying;

        emit ClaimPayment(claimId, from, paymentAmount, totalPaidAmount);

        // transfer the ownership of the claim NFT to the payee as a receipt of their completed payment
        if (claim.payerReceivesClaimOnPayment && claimPaid) _transferFrom(creditor, from, claimId);
    }

    /**
     * /// UPDATE BINDING ///
     */

    /// @notice allows a creditor to unbind a debtor, or a debtor to bind themselves to a claim
    /// @notice SPEC:
    ///     1. call updateBinding on behalf of the msg.sender
    function updateBinding(uint256 claimId, ClaimBinding binding) external {
        _updateBinding(msg.sender, claimId, binding);
    }

    /// @notice allows a controller to update the binding of a claim for a creditor or debtor
    /// @notice SPEC:
    ///     1. verify and spend msg.sender's approval to update bindings
    ///     2. update the binding on `from`'s behalf
    function updateBindingFrom(address from, uint256 claimId, ClaimBinding binding) external {
        _spendUpdateBindingApproval(from, msg.sender);

        _updateBinding(from, claimId, binding);
    }

    /// @notice "spends" a controller's updateBinding approval
    /// @notice SPEC:
    /// A function can call this function to verify and "spend" `from`'s approval of `controller` to update a claim's binding given:
    ///     S1. `controller` has > 0 approvalCount from `from` address -> otherwise: reverts
    ///
    /// RES1: If the above is true, and the approvalCount != type(uint64).max, decrement the approval count by 1 and return
    function _spendUpdateBindingApproval(address user, address controller) internal {
        UpdateBindingApproval storage approval = approvals[user][controller].updateBinding;

        // Use validation library for approval validation
        BullaClaimValidationLib.validateSimpleApproval(approval.approvalCount);

        if (approval.approvalCount != type(uint64).max) approval.approvalCount--;

        return;
    }

    /// @notice allows a creditor to unbind a debtor, a debtor to bind themselves to a claim, or for either to move the status to BindingPending.
    /// @notice SPEC:
    ///     This will update the status given the following:
    ///     1. The contract is not locked
    ///     2. The claim exists and is not burned
    ///     ...TODO:
    function _updateBinding(address from, uint256 claimId, ClaimBinding binding) internal {
        _notLocked();
        Claim memory claim = getClaim(claimId);
        address creditor = _ownerOf[claimId];

        // check if the claim is controlled
        if (claim.controller != address(0) && msg.sender != claim.controller) revert NotController(msg.sender);

        // Use validation library for binding update validation
        BullaClaimValidationLib.validateBindingUpdate(from, claim, creditor, binding);

        claims[claimId].binding = binding;

        emit BindingUpdated(claimId, from, binding);
    }

    /**
     * /// CANCEL CLAIM ///
     */

    /// @notice allows a creditor to rescind a claim or a debtor to reject a claim
    /// @notice SPEC:
    ///     1. call cancelClaim on behalf of the msg.sender
    function cancelClaim(uint256 claimId, string calldata note) external {
        _cancelClaim(msg.sender, claimId, note);
    }

    /// @notice allows a controller to cancel a claim on behalf of a creditor or debtor
    /// @notice SPEC:
    ///     1. verify and spend msg.sender's approval to cancel claims
    ///     2. cancel the claim on `from`'s behalf
    function cancelClaimFrom(address from, uint256 claimId, string calldata note) external {
        _spendCancelClaimApproval(from, msg.sender);

        _cancelClaim(from, claimId, note);
    }

    /// @notice "spends" a controller's cancelClaim approval
    /// @notice SPEC:
    /// A function can call this function to verify and "spend" `from`'s approval of `controller` to cancel a claim given:
    ///     S1. `controller` has > 0 approvalCount from `from` address -> otherwise: reverts
    ///
    /// RES1: If the above is true, and the approvalCount != type(uint64).max, decrement the approval count by 1 and return
    function _spendCancelClaimApproval(address user, address controller) internal {
        CancelClaimApproval storage approval = approvals[user][controller].cancelClaim;

        // Use validation library for approval validation
        BullaClaimValidationLib.validateSimpleApproval(approval.approvalCount);

        if (approval.approvalCount != type(uint64).max) approval.approvalCount--;

        return;
    }

    /// @notice allows a creditor to rescind a claim or a debtor to reject a claim
    /// @notice SPEC:
    ///     this function will rescind or reject a claim given:
    ///     1. The contract is not locked
    ///     2. The claim exists and is not burned
    ///     ...TODO
    function _cancelClaim(address from, uint256 claimId, string calldata note) internal {
        _notLocked();
        // load the claim from storage
        Claim memory claim = getClaim(claimId);
        address creditor = _ownerOf[claimId];

        if (claim.controller != address(0) && msg.sender != claim.controller) revert NotController(msg.sender);

        // Use validation library for cancellation validation
        BullaClaimValidationLib.validateClaimCancellation(from, claim, creditor);

        if (from == claim.debtor) {
            claims[claimId].status = Status.Rejected;
            emit ClaimRejected(claimId, from, note);
        } else {
            claims[claimId].status = Status.Rescinded;
            emit ClaimRescinded(claimId, from, note);
        }
    }

    /**
     * /// IMPAIR CLAIM ///
     */

    /// @notice allows a creditor to impair a claim
    /// @notice SPEC:
    ///     1. call impairClaim on behalf of the msg.sender
    function impairClaim(uint256 claimId) external {
        _impairClaim(msg.sender, claimId);
    }

    /// @notice allows a controller to impair a claim on behalf of a creditor
    /// @notice SPEC:
    ///     1. verify and spend msg.sender's approval to impair claims
    ///     2. impair the claim on `from`'s behalf
    function impairClaimFrom(address from, uint256 claimId) external {
        _spendImpairClaimApproval(from, msg.sender);

        _impairClaim(from, claimId);
    }

    /// @notice "spends" a controller's impairClaim approval
    /// @notice SPEC:
    /// A function can call this function to verify and "spend" `from`'s approval of `controller` to impair a claim given:
    ///     S1. `controller` has > 0 approvalCount from `from` address -> otherwise: reverts
    ///
    /// RES1: If the above is true, and the approvalCount != type(uint64).max, decrement the approval count by 1 and return
    function _spendImpairClaimApproval(address user, address controller) internal {
        ImpairClaimApproval storage approval = approvals[user][controller].impairClaim;

        // Use validation library for approval validation
        BullaClaimValidationLib.validateSimpleApproval(approval.approvalCount);

        if (approval.approvalCount != type(uint64).max) approval.approvalCount--;

        return;
    }

    /// @notice allows a creditor to impair a claim
    /// @notice SPEC:
    ///     this function will impair a claim given:
    ///     1. The contract is not locked
    ///     2. The claim exists and is not burned
    ///     3. The caller is the creditor (owner of the claim NFT)
    ///     4. The claim is in pending or repaying status
    ///     5. If claim has a dueBy date, the grace period must have passed
    ///     6. If claim has no dueBy date (dueBy = 0), it cannot be impaired
    function _impairClaim(address from, uint256 claimId) internal {
        _notLocked();
        // load the claim from storage
        Claim memory claim = getClaim(claimId);
        address creditor = _ownerOf[claimId];

        if (claim.controller != address(0) && msg.sender != claim.controller) revert NotController(msg.sender);

        // Use validation library for impairment validation
        BullaClaimValidationLib.validateClaimImpairment(from, claim, creditor);

        claims[claimId].status = Status.Impaired;
        emit ClaimImpaired(claimId);
    }

    /**
     * /// MARK CLAIM AS PAID ///
     */

    /// @notice "spends" a controller's markAsPaid approval
    /// @notice SPEC:
    /// A function can call this function to verify and "spend" `from`'s approval of `controller` to mark a claim as paid given:
    ///     S1. `controller` has > 0 approvalCount from `from` address -> otherwise: reverts
    ///
    /// RES1: If the above is true, and the approvalCount != type(uint64).max, decrement the approval count by 1 and return
    function _spendMarkAsPaidApproval(address user, address controller) internal {
        MarkAsPaidApproval storage approval = approvals[user][controller].markAsPaid;

        // Use validation library for approval validation
        BullaClaimValidationLib.validateSimpleApproval(approval.approvalCount);

        if (approval.approvalCount != type(uint64).max) approval.approvalCount--;

        return;
    }

    /// @notice allows a creditor to manually mark a claim as paid even if not fully paid
    /// @notice SPEC:
    ///     1. call markClaimAsPaid on behalf of the msg.sender
    function markClaimAsPaid(uint256 claimId) external {
        _markClaimAsPaid(msg.sender, claimId);
    }

    /// @notice allows a controller to mark a claim as paid on behalf of a creditor
    /// @notice SPEC:
    ///     1. verify and spend msg.sender's approval to mark claims as paid
    ///     2. mark the claim as paid on `from`'s behalf
    function markClaimAsPaidFrom(address from, uint256 claimId) external {
        _spendMarkAsPaidApproval(from, msg.sender);

        _markClaimAsPaid(from, claimId);
    }

    /// @notice allows a creditor to manually mark a claim as paid even if not fully paid
    /// @notice SPEC:
    ///     this function will mark a claim as paid given:
    ///     1. The contract is not locked
    ///     2. The claim exists and is not burned
    ///     3. The caller is the creditor (owner of the claim NFT)
    ///     4. The claim is in pending, repaying, or impaired status
    function _markClaimAsPaid(address from, uint256 claimId) internal {
        _notLocked();
        // load the claim from storage
        Claim memory claim = getClaim(claimId);
        address creditor = _ownerOf[claimId];

        if (claim.controller != address(0) && msg.sender != claim.controller) revert NotController(msg.sender);

        // Use validation library for mark as paid validation
        BullaClaimValidationLib.validateMarkAsPaid(from, claim, creditor);

        claims[claimId].status = Status.Paid;

        emit ClaimMarkedAsPaid(claimId);
    }

    /*///////////////////////////////////////////////////////////////
                             PERMIT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice permits a controller to create claims on user's behalf
    /// @dev see BullaClaimPermitLib.permitCreateClaim for spec
    function permitCreateClaim(
        address user,
        address controller,
        CreateClaimApprovalType approvalType,
        uint64 approvalCount,
        bool isBindingAllowed,
        bytes calldata signature
    ) public {
        BullaClaimPermitLib.permitCreateClaim(
            approvals[user][controller],
            controllerRegistry,
            _domainSeparatorV4(),
            user,
            controller,
            approvalType,
            approvalCount,
            isBindingAllowed,
            signature
        );
    }

    /// @notice permits a controller to pay a claim on user's behalf
    /// @dev see BullaClaimPermitLib.permitPayClaim for spec
    function permitPayClaim(
        address user,
        address controller,
        PayClaimApprovalType approvalType,
        uint256 approvalDeadline,
        ClaimPaymentApprovalParam[] calldata paymentApprovals,
        bytes calldata signature
    ) public {
        BullaClaimPermitLib.permitPayClaim(
            approvals[user][controller],
            controllerRegistry,
            _domainSeparatorV4(),
            user,
            controller,
            approvalType,
            approvalDeadline,
            paymentApprovals,
            signature
        );
    }

    /// @notice permits a controller to update claim bindings on user's behalf
    /// @dev see BullaClaimPermitLib.permitUpdateBinding for spec
    function permitUpdateBinding(address user, address controller, uint64 approvalCount, bytes calldata signature)
        public
    {
        BullaClaimPermitLib.permitUpdateBinding(
            approvals[user][controller],
            controllerRegistry,
            _domainSeparatorV4(),
            user,
            controller,
            approvalCount,
            signature
        );
    }

    /// @notice permits a controller to cancel claims on user's behalf
    /// @dev see BullaClaimPermitLib.sol for spec
    function permitCancelClaim(address user, address controller, uint64 approvalCount, bytes calldata signature)
        public
    {
        BullaClaimPermitLib.permitCancelClaim(
            approvals[user][controller],
            controllerRegistry,
            _domainSeparatorV4(),
            user,
            controller,
            approvalCount,
            signature
        );
    }

    /// @notice permits a controller to impair claims on user's behalf
    /// @dev see BullaClaimPermitLib.sol for spec
    function permitImpairClaim(address user, address controller, uint64 approvalCount, bytes calldata signature)
        public
    {
        BullaClaimPermitLib.permitImpairClaim(
            approvals[user][controller],
            controllerRegistry,
            _domainSeparatorV4(),
            user,
            controller,
            approvalCount,
            signature
        );
    }

    /// @notice permits a controller to mark claims as paid on user's behalf
    function permitMarkAsPaid(address user, address controller, uint64 approvalCount, bytes calldata signature)
        public
    {
        BullaClaimPermitLib.permitMarkAsPaid(
            approvals[user][controller],
            controllerRegistry,
            _domainSeparatorV4(),
            user,
            controller,
            approvalCount,
            signature
        );
    }

    /*///////////////////////////////////////////////////////////////
                        VIEW / UTILITY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function getClaim(uint256 claimId) public view returns (Claim memory claim) {
        if (claimId > currentClaimId) revert NotMinted();

        ClaimStorage memory claimStorage = claims[claimId];
        claim = Claim({
            claimAmount: uint256(claimStorage.claimAmount),
            paidAmount: uint256(claimStorage.paidAmount),
            status: claimStorage.status,
            binding: claimStorage.binding,
            payerReceivesClaimOnPayment: claimStorage.payerReceivesClaimOnPayment,
            debtor: claimStorage.debtor,
            creditor: _ownerOf[claimId],
            token: claimStorage.token,
            controller: claimStorage.controller,
            originalCreditor: claimStorage.originalCreditor,
            dueBy: claimStorage.dueBy,
            impairmentGracePeriod: claimStorage.impairmentGracePeriod
        });
    }

    /// @notice get the tokenURI generated for this claim
    function tokenURI(uint256 claimId) public view override returns (string memory) {
        string memory uri = claimMetadata[claimId].tokenURI;
        if (bytes(uri).length > 0) {
            return uri;
        } else {
            Claim memory claim = getClaim(claimId);
            address owner = _ownerOf[claimId];
            return claimMetadataGenerator.tokenURI(claim, claimId, owner);
        }
    }

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /*///////////////////////////////////////////////////////////////
                            OWNER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function setControllerRegistry(address _controllerRegistry) external onlyOwner {
        controllerRegistry = BullaControllerRegistry(_controllerRegistry);
    }

    function setClaimMetadataGenerator(address _metadataGenerator) external onlyOwner {
        claimMetadataGenerator = ClaimMetadataGenerator(_metadataGenerator);
    }

    function setLockState(LockState _lockState) external onlyOwner {
        lockState = _lockState;
    }
}
