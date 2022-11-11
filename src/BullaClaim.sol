//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.15;

import "contracts/types/Types.sol";
import {IBullaFeeCalculator} from "contracts/interfaces/IBullaFeeCalculator.sol";
import {IERC1271} from "contracts/interfaces/IERC1271.sol";
import {BullaExtensionRegistry} from "contracts/BullaExtensionRegistry.sol";
import {EIP712} from "openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {SafeCastLib} from "solmate/utils/SafeCastLib.sol";
import {BoringBatchable} from "contracts/libraries/BoringBatchable.sol";
import {BullaClaimPermitLib} from "contracts/libraries/BullaClaimPermitLib.sol";
import {Owned} from "solmate/auth/Owned.sol";
import {ERC721} from "solmate/tokens/ERC721.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {ClaimMetadataGenerator} from "contracts/ClaimMetadataGenerator.sol";
import "forge-std/console.sol";

contract BullaClaim is ERC721, EIP712, Owned, BoringBatchable {
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
    /// a mapping of users to operators to approvals for specific actions
    mapping(address => mapping(address => Approvals)) public approvals;
    /// The contract which calculates the fee for a specific claim - tracked via ids
    uint256 public currentFeeCalculatorId;
    mapping(uint256 => IBullaFeeCalculator) public feeCalculators;
    /// Restricts which functions can be called. Options: Unlocked, NoNewClaims, Locked:
    LockState public lockState;
    /// the address fees are forwarded to
    address public feeCollectionAddress;
    /// the total amount of claims minted
    uint256 public currentClaimId;
    /// a registry of extension names vetted by Bulla Network
    BullaExtensionRegistry public extensionRegistry;

    /*///////////////////////////////////////////////////////////////
                            ERRORS / MODIFIERS
    //////////////////////////////////////////////////////////////*/

    error PayingZero();
    error ClaimBound(uint256 claimId);
    error NotOwner();
    error CannotBindClaim();
    error InvalidSignature();
    error InvalidTimestamp(uint256 timestamp);
    error PastApprovalDeadline();
    error InvalidPaymentApproval();
    error NotCreditorOrDebtor(address sender);
    error OverPaying(uint256 paymentAmount);
    error ClaimNotPending(uint256 claimId);
    error ClaimDelegated(uint256 claimId, address delegator);
    error NotDelegator(address sender);
    error NotMinted(uint256 claimId);
    error NotApproved();
    error PaymentUnderApproved();
    error Locked();

    function _notLocked() internal view {
        if (lockState == LockState.Locked) {
            revert Locked();
        }
    }

    /*///////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event ClaimCreated(
        uint256 indexed claimId,
        address from,
        address indexed creditor,
        address indexed debtor,
        string description,
        uint256 claimAmount,
        address claimToken,
        ClaimBinding binding,
        uint256 dueBy,
        uint256 feeCalculatorId
    );

    event MetadataAdded(uint256 indexed claimId, string tokenURI, string attachmentURI);

    event ClaimPayment(
        uint256 indexed claimId, address indexed paidBy, uint256 paymentAmount, uint256 feePaymentAmount
    );

    event BindingUpdated(uint256 indexed claimId, address indexed from, ClaimBinding indexed binding);

    event ClaimRejected(uint256 indexed claimId, address indexed from, string note);

    event ClaimRescinded(uint256 indexed claimId, address indexed from, string note);

    event CreateClaimApproved(
        address indexed user,
        address indexed operator,
        CreateClaimApprovalType indexed approvalType,
        uint256 approvalCount,
        bool isBindingAllowed
    );

    event PayClaimApproved(
        address indexed user,
        address indexed operator,
        PayClaimApprovalType indexed approvalType,
        uint256 approvalDeadline,
        ClaimPaymentApprovalParam[] paymentApprovals
    );

    event UpdateBindingApproved(address indexed user, address indexed operator, uint256 approvalCount);

    event CancelClaimApproved(address indexed user, address indexed operator, uint256 approvalCount);

    constructor(address _feeCollectionAddress, address _extensionRegistry, LockState _lockState)
        ERC721("BullaClaim", "CLAIM")
        EIP712("BullaClaim", "1")
        Owned(msg.sender)
    {
        feeCollectionAddress = _feeCollectionAddress;
        extensionRegistry = BullaExtensionRegistry(_extensionRegistry);
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

    /// @notice allows an operator to create a claim on behalf of a user
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

    /// @notice allows an operator to create a claim with optional attachmentURI and / or a custom tokenURI on behalf of a user
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

        // TODO: check event order
        claimMetadata[claimId] = metadata;
        emit MetadataAdded(claimId, metadata.tokenURI, metadata.attachmentURI);

        return claimId;
    }

    /// @notice "spends" an operator's create claim approval
    /// @notice SPEC:
    /// A function can call this function to verify and "spend" `from`'s approval of `operator` to create a claim given the following:
    ///     S1. `operator` has > 0 approvalCount from the `from` address -> otherwise: reverts
    ///     S2. The creditor and debtor arguments are permissed by the `from` address, meaning:
    ///         - If the approvalType is `CreditorOnly` the `from` address must be the creditor -> otherwise: reverts
    ///         - If the approvalType is `DebtorOnly` the `from` address must be the debtor -> otherwise: reverts
    ///        Note: If the approvalType is `Approved`, the `operator` may specify the `from` address as the creditor, the debtor, _or neither_ // TODO: will be removed with creditor/debtor restrictions
    ///     S3. If the claimBinding argument is `Bound`, then the isBindingAllowed permission must be set to true -> otherwise: reverts
    ///        Note: _createClaim will always revert if the claimBinding argument is `Bound` and the `from` address is not the debtor
    ///
    /// RES1: If the above are true, and the approvalCount != type(uint64).max, decrement the approval count by 1 and return -> otherwise: no-op
    function _spendCreateClaimApproval(
        address from,
        address operator,
        address creditor,
        address debtor,
        ClaimBinding binding
    ) internal {
        CreateClaimApproval memory approval = approvals[from][operator].createClaim;

        // spec.S1
        if (approval.approvalCount == 0) revert NotApproved();

        // spec.S2
        if (
            (approval.approvalType == CreateClaimApprovalType.CreditorOnly && from != creditor)
                || (approval.approvalType == CreateClaimApprovalType.DebtorOnly && from != debtor)
        ) {
            revert NotApproved();
        }

        // spec.S3
        if (binding == ClaimBinding.Bound && !approval.isBindingAllowed) {
            revert CannotBindClaim();
        }

        // result
        if (approval.approvalCount != type(uint64).max) {
            approvals[from][operator].createClaim.approvalCount -= 1;
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
        if (lockState != LockState.Unlocked) {
            revert Locked();
        }

        if (params.delegator != address(0) && params.delegator != msg.sender) {
            revert NotDelegator(msg.sender);
        }

        // we allow dueBy to be 0 in the case of an "open" claim, or we allow a reasonable timestamp
        if (params.dueBy != 0 && params.dueBy < block.timestamp && params.dueBy < type(uint40).max) {
            //todo: fix
            revert InvalidTimestamp(params.dueBy);
        }

        // you need the permission of the debtor to bind a claim
        if (params.binding == ClaimBinding.Bound && from != params.debtor) {
            revert CannotBindClaim();
        }

        uint256 claimId;
        unchecked {
            claimId = ++currentClaimId;
        }

        ClaimStorage storage claim = claims[claimId];

        claim.claimAmount = params.claimAmount.safeCastTo128(); //TODO: is this necessary?
        claim.debtor = params.debtor;

        uint256 _currentFeeCalculatorId = currentFeeCalculatorId;
        uint16 feeCalculatorId;
        // we store the fee calculator id on the claim to make
        // sure the payer pays the fee amount when the claim was created
        if (_currentFeeCalculatorId != 0 && address(feeCalculators[_currentFeeCalculatorId]) != address(0)) {
            claim.feeCalculatorId = feeCalculatorId = uint16(_currentFeeCalculatorId);
        }
        if (params.dueBy != 0) {
            claim.dueBy = uint40(params.dueBy);
        }
        if (params.token != address(0)) {
            claim.token = params.token;
        }
        if (params.delegator != address(0)) {
            claim.delegator = params.delegator;
        }
        if (params.feePayer == FeePayer.Debtor) {
            claim.feePayer = params.feePayer;
        }
        if (params.binding != ClaimBinding.Unbound) {
            claim.binding = params.binding;
        }

        emit ClaimCreated(
            claimId,
            from,
            params.creditor,
            params.debtor,
            params.description,
            params.claimAmount,
            params.token,
            params.binding,
            params.dueBy,
            feeCalculatorId
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

    /// @notice allows an operator to pay a claim on behalf of a user
    /// @notice SPEC:
    ///     1. verify and spend msg.sender's approval to pay claims for `from`
    ///     2. call payClaim on `from`'s behalf
    function payClaimFrom(address from, uint256 claimId, uint256 amount) external payable {
        _spendPayClaimApproval(from, msg.sender, claimId, amount);

        _payClaim(from, claimId, amount);
    }

    /// @notice _spendPayClaimApproval() "spends" an operator's pay claim approval
    /// @notice SPEC:
    /// A function can call this internal function to verify and "spend" `from`'s approval of `operator` to pay a claim under the following circumstances:
    ///     SA1. The `approvalType` is not `Unapproved` -> otherwise: reverts
    ///     SA2. The contract LockStatus is not `Locked` -> otherwise: reverts
    ///
    ///     When the `approvalType` is `IsApprovedForSpecific`, then `operator` must be approved to pay that claim meaning:
    ///         AS1: `from` has approved payment for the `claimId` argument -> otherwise: reverts
    ///         AS2: `from` has approved payment for at least the `amount` argument -> otherwise: reverts
    ///         AS3: `from`'s approval has not expired, meaning:
    ///             AS3.1: If the operator has an "operator" expirary, then the operator expirary must be greater than the current block timestamp -> otherwise: reverts
    ///             AS3.2: If the operator does not have an operator expirary and instead has a claim-specific expirary,
    ///                 then the claim-specific expirary must be greater than the current block timestamp -> otherwise: reverts
    ///
    ///         AS.RES1: If the `amount` argument == the pre-approved amount on the permission, spend the permission -> otherwise: decrement the approved amount by `amount`
    ///
    ///     If the `approvalType` is `IsApprovedForAll`, then `operator` must be approved to pay, meaning:
    ///         AA1: `from`'s approval of `operator` has not expired -> otherwise: reverts
    ///
    ///         AA.RES1: This function allows execution to continue - (no storage needs to be updated)
    function _spendPayClaimApproval(address from, address operator, uint256 claimId, uint256 amount) internal {
        PayClaimApproval storage approval = approvals[from][operator].payClaim;

        if (approval.approvalType == PayClaimApprovalType.Unapproved) revert NotApproved();
        if (approval.approvalDeadline != 0 && block.timestamp > approval.approvalDeadline) {
            revert PastApprovalDeadline();
        }
        // no-op, because `operator` is approved
        if (approval.approvalType == PayClaimApprovalType.IsApprovedForAll) return;

        uint256 i;
        ClaimPaymentApproval[] memory _paymentApprovals = approval.claimApprovals;
        uint256 totalApprovals = _paymentApprovals.length;
        bool approvalFound;

        for (; i < totalApprovals; ++i) {
            // if a matching approval is found
            if (_paymentApprovals[i].claimId == claimId) {
                approvalFound = true;
                // check if the approval is expired or under approved
                if (
                    (
                        _paymentApprovals[i].approvalDeadline != 0
                            && block.timestamp > _paymentApprovals[i].approvalDeadline
                    )
                ) {
                    revert PastApprovalDeadline();
                }
                if (amount > _paymentApprovals[i].approvedAmount) revert PaymentUnderApproved();

                // if the approval is fully spent, we can delete it
                if (amount == _paymentApprovals[i].approvedAmount) {
                    // perform a swap and pop
                    // if the approval is not the last approval in the array, copy the last approval and overwrite `i`
                    if (i != totalApprovals - 1) {
                        approval.claimApprovals[i] = approval.claimApprovals[totalApprovals - 1];
                    }

                    // delete the last approval (which is either the spent approval, or the duplicated one)
                    approval.claimApprovals.pop();
                } else {
                    // otherwise we decrement it in place
                    // this cast is safe because we check if amount > approvedAmount and approvedAmount is a uint128
                    approval.claimApprovals[i].approvedAmount -= uint128(amount);
                }
                break;
            }
        }

        if (!approvalFound) revert NotApproved();
    }

    /// @notice pay a claim with tokens (WETH -> ETH included)
    /// @notice NOTE: if the claim token is address(0) (eth) then we use the eth transferred to the contract. If this function is called via PayClaimFrom,
    ///     then the calling function must either escrow `from`'s eth or transfer it to the contract while calling this function.
    /// @notice NOTE: we transfer the NFT back to whomever makes the final payment of the claim. This represents a receipt of their payment
    /// @notice NOTE: The actual amount "paid off" of the claim may be less if our fee is enabled
    ///     In other words, we treat this `amount` param as the amount the user wants to spend, and then deduct a fee from that amount
    function _payClaim(address from, uint256 claimId, uint256 paymentAmount) internal {
        _notLocked();
        Claim memory claim = getClaim(claimId);

        // We allow for claims to be "delegated". Meaning, it is another smart contract's responsibility to implement
        //      custom logic, then call these functions. We check the msg.sender against the delegator to make sure a user
        //      isn't trying to bypass delegator specific logic (eg: late fees) and by going to this contract directly.
        if (claim.delegator != address(0) && msg.sender != claim.delegator) {
            revert ClaimDelegated(claimId, claim.delegator);
        }

        // load the claim from storage
        address creditor = getCreditor(claimId);

        // make sure the the amount requested is not 0
        if (paymentAmount == 0) {
            revert PayingZero();
        }

        // make sure the claim can be paid (not completed, not rejected, not rescinded)
        if (claim.status != Status.Pending && claim.status != Status.Repaying) {
            revert ClaimNotPending(claimId);
        }

        uint256 fee = claim.feeCalculatorId != 0
            ? IBullaFeeCalculator(feeCalculators[claim.feeCalculatorId]).calculateFee(
                claimId,
                from,
                creditor,
                claim.debtor,
                paymentAmount,
                claim.claimAmount,
                claim.paidAmount,
                claim.dueBy,
                claim.binding,
                claim.feePayer
            )
            : 0;

        uint256 amountToTransferCreditor = paymentAmount - fee;

        // The actual amount paid off the claim depends on who pays the fee.
        // The creditor will always receive the param `amount` minus the fee
        // however the debtor's obligation (implicitly claimAmount - paidAmount) will be greater
        // if FeePayer == Debtor (payer)
        uint256 claimPaymentAmount = claim.feePayer == FeePayer.Debtor ? paymentAmount - fee : paymentAmount;

        uint256 newPaidAmount = claim.paidAmount + claimPaymentAmount;
        bool claimPaid = newPaidAmount == claim.claimAmount;

        if (newPaidAmount > claim.claimAmount) {
            revert OverPaying(paymentAmount);
        }

        ClaimStorage storage claimStorage = claims[claimId];

        claimStorage.paidAmount = uint128(newPaidAmount);
        // if the claim is now fully paid, update the status to paid
        // if the claim is still not fully paid, update the status to repaying
        claimStorage.status = claimPaid ? Status.Paid : Status.Repaying;

        if (fee > 0) {
            claim.token == address(0)
                ? feeCollectionAddress.safeTransferETH(fee)
                : ERC20(claim.token).safeTransferFrom(from, feeCollectionAddress, fee);
        }

        // TODO: this should happen after transfer
        emit ClaimPayment(claimId, from, claimPaymentAmount, fee);

        claim.token == address(0)
            ? creditor.safeTransferETH(amountToTransferCreditor)
            : ERC20(claim.token).safeTransferFrom(from, creditor, amountToTransferCreditor);

        // transfer the ownership of the claim NFT to the payee as a receipt of their completed payment
        if (claimPaid) {
            _transferFrom(creditor, from, claimId);
        }
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

    /// @notice allows an operator to update the binding of a claim for a creditor or debtor
    /// @notice SPEC:
    ///     1. verify and spend msg.sender's approval to update binding
    ///     2. update the claim's binding on `from`'s behalf
    function updateBindingFrom(address from, uint256 claimId, ClaimBinding binding) external {
        _spendUpdateBindingApproval(from, msg.sender);

        _updateBinding(from, claimId, binding);
    }

    /// @notice "spends" an operator's updateBinding approval
    /// @notice SPEC:
    /// A function can call this function to verify and "spend" `from`'s approval of `operator` to update a claim's binding given:
    ///     S1. `operator` has > 0 approvalCount from `from` address -> otherwise: reverts
    ///
    /// RES1: If the above is true, and the approvalCount != type(uint64).max, decrement the approval count by 1 and return
    function _spendUpdateBindingApproval(address user, address operator) internal {
        UpdateBindingApproval storage approval = approvals[user][operator].updateBinding;

        if (approval.approvalCount == 0) revert NotApproved();
        if (approval.approvalCount != type(uint64).max) approval.approvalCount--;

        return;
    }

    /// @notice allows a creditor to unbind a debtor, a debtor to bind themselves to a claim, or for either to move the status to BindingPending.
    /// @notice SPEC: TODO:
    function _updateBinding(address from, uint256 claimId, ClaimBinding binding) internal {
        _notLocked();
        Claim memory claim = getClaim(claimId);
        address creditor = getCreditor(claimId);

        // check if the claim is delegated
        if (claim.delegator != address(0) && msg.sender != claim.delegator) {
            revert ClaimDelegated(claimId, claim.delegator);
        }

        // make sure the sender is authorized
        if (from != creditor && from != claim.debtor) {
            revert NotCreditorOrDebtor(from);
        }

        // make sure the binding is valid
        if (from == creditor && binding == ClaimBinding.Bound) {
            revert CannotBindClaim();
        }

        // make sure the debtor isn't trying to unbind themselves
        if (from == claim.debtor && claim.binding == ClaimBinding.Bound) {
            revert ClaimBound(claimId);
        }

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

    /// @notice allows an operator to cancel a claim on behalf of a creditor or debtor
    /// @notice SPEC:
    ///     1. verify and spend msg.sender's approval to cancel claim
    ///     2. cancel the claim on `from`'s behalf
    function cancelClaimFrom(address from, uint256 claimId, string calldata note) external {
        _spendCancelClaimApproval(from, msg.sender);

        _cancelClaim(from, claimId, note);
    }

    /// @notice "spends" an operator's cancelClaim approval
    /// @notice SPEC:
    /// A function can call this function to verify and "spend" `from`'s approval of `operator` to cancel a claim given:
    ///     S1. `operator` has > 0 approvalCount from `from` address -> otherwise: reverts
    ///
    /// RES1: If the above is true, and the approvalCount != type(uint64).max, decrement the approval count by 1 and return
    function _spendCancelClaimApproval(address user, address operator) internal {
        CancelClaimApproval storage approval = approvals[user][operator].cancelClaim;

        if (approval.approvalCount == 0) revert NotApproved();
        if (approval.approvalCount != type(uint64).max) approval.approvalCount--;

        return;
    }

    /// @notice allows a creditor to rescind a claim or a debtor to reject a claim
    /// @notice SPEC: TODO:
    function _cancelClaim(address from, uint256 claimId, string calldata note) internal {
        _notLocked();
        // load the claim from storage
        Claim memory claim = getClaim(claimId);

        if (claim.binding == ClaimBinding.Bound && claim.debtor == from) {
            revert ClaimBound(claimId);
        }

        if (claim.delegator != address(0) && msg.sender != claim.delegator) {
            revert ClaimDelegated(claimId, claim.delegator);
        }

        // make sure the claim can be rejected (not completed, not rejected, not rescinded)
        if (claim.status != Status.Pending) {
            revert ClaimNotPending(claimId);
        }

        if (from == claim.debtor) {
            claims[claimId].status = Status.Rejected;
            emit ClaimRejected(claimId, from, note);
        } else if (from == getCreditor(claimId)) {
            claims[claimId].status = Status.Rescinded;
            emit ClaimRescinded(claimId, from, note);
        } else {
            revert NotCreditorOrDebtor(from);
        }
    }

    /**
     * /// BURN CLAIM ///
     */

    // TODO: should we require the token is paid here?
    function burn(uint256 tokenId) external {
        if (msg.sender != ownerOf(tokenId)) {
            revert NotOwner();
        }

        _burn(tokenId);
    }

    /*///////////////////////////////////////////////////////////////
                             PERMIT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice permits an operator to create claims on user's behalf
    /// @dev see BullaClaimPermitLib.permitCreateClaim for spec
    function permitCreateClaim(
        address user,
        address operator,
        CreateClaimApprovalType approvalType,
        uint64 approvalCount,
        bool isBindingAllowed,
        bytes calldata signature
    ) public {
        BullaClaimPermitLib.permitCreateClaim(
            approvals[user][operator],
            extensionRegistry,
            _domainSeparatorV4(),
            user,
            operator,
            approvalType,
            approvalCount,
            isBindingAllowed,
            signature
        );
    }

    /// @notice permits an operator to pay a claim on user's behalf
    /// @dev see BullaClaimPermitLib.permitPayClaim for spec
    function permitPayClaim(
        address user,
        address operator,
        PayClaimApprovalType approvalType,
        uint256 approvalDeadline,
        ClaimPaymentApprovalParam[] calldata paymentApprovals,
        bytes calldata signature
    ) public {
        BullaClaimPermitLib.permitPayClaim(
            approvals[user][operator],
            extensionRegistry,
            _domainSeparatorV4(),
            user,
            operator,
            approvalType,
            approvalDeadline,
            paymentApprovals,
            signature
        );
    }

    /// @notice permits an operator to update claim bindings on user's behalf
    /// @dev see BullaClaimPermitLib.permitUpdateBinding for spec
    function permitUpdateBinding(address user, address operator, uint64 approvalCount, bytes calldata signature)
        public
    {
        BullaClaimPermitLib.permitUpdateBinding(
            approvals[user][operator], extensionRegistry, _domainSeparatorV4(), user, operator, approvalCount, signature
        );
    }

    /// @notice permits an operator to cancel claims on user's behalf
    /// @dev see BullaClaimPermitLib.sol for spec
    function permitCancelClaim(address user, address operator, uint64 approvalCount, bytes calldata signature) public {
        BullaClaimPermitLib.permitCancelClaim(
            approvals[user][operator], extensionRegistry, _domainSeparatorV4(), user, operator, approvalCount, signature
        );
    }

    /*///////////////////////////////////////////////////////////////
                        VIEW / UTILITY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function getClaim(uint256 claimId) public view returns (Claim memory claim) {
        if (claimId > currentClaimId) {
            revert NotMinted(claimId);
        }
        ClaimStorage memory claimStorage = claims[claimId];
        claim = Claim({
            claimAmount: uint256(claimStorage.claimAmount),
            paidAmount: uint256(claimStorage.paidAmount),
            status: claimStorage.status,
            binding: claimStorage.binding,
            feePayer: claimStorage.feePayer,
            debtor: claimStorage.debtor,
            feeCalculatorId: claimStorage.feeCalculatorId,
            dueBy: uint256(claimStorage.dueBy),
            token: claimStorage.token,
            delegator: claimStorage.delegator
        });
    }

    /// @notice get the tokenURI generated for this claim
    function tokenURI(uint256 _claimId) public view override returns (string memory) {
        string memory uri = claimMetadata[_claimId].tokenURI;
        if (bytes(uri).length > 0) {
            return uri;
        } else {
            Claim memory claim = getClaim(_claimId);
            address creditor = getCreditor(_claimId);
            return ClaimMetadataGenerator.describe(claim, _claimId, creditor);
        }
    }

    function getCreditor(uint256 claimId) public view returns (address) {
        return _ownerOf[claimId];
    }

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function feeCalculator() public view returns (address) {
        return address(feeCalculators[currentFeeCalculatorId]);
    }

    /*///////////////////////////////////////////////////////////////
                            OWNER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function setFeeCalculator(address _feeCalculator) external onlyOwner {
        uint256 nextFeeCalculator;
        unchecked {
            nextFeeCalculator = ++currentFeeCalculatorId;
        }

        feeCalculators[nextFeeCalculator] = IBullaFeeCalculator(_feeCalculator);
    }

    function setExtensionRegistry(address _extensionRegistry) external onlyOwner {
        extensionRegistry = BullaExtensionRegistry(_extensionRegistry);
    }

    function setFeeCollectionAddress(address newFeeCollector) external onlyOwner {
        feeCollectionAddress = newFeeCollector;
    }

    function setLockState(LockState _lockState) external onlyOwner {
        lockState = _lockState;
    }
}
