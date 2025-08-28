// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import "./types/Types.sol";
import {IERC1271} from "./interfaces/IERC1271.sol";
import {IBullaControllerRegistry} from "./interfaces/IBullaControllerRegistry.sol";
import {IBullaApprovalRegistry} from "./interfaces/IBullaApprovalRegistry.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {SafeCastLib} from "solmate/utils/SafeCastLib.sol";

import {BullaClaimValidationLib} from "./libraries/BullaClaimValidationLib.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {IClaimMetadataGenerator} from "./interfaces/IClaimMetadataGenerator.sol";
import {IPermissions} from "./interfaces/IPermissions.sol";
import {IBullaClaimV2} from "./interfaces/IBullaClaimV2.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IBullaClaimAdmin} from "./interfaces/IBullaClaimAdmin.sol";
import {ERC721Utils} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Utils.sol";

contract BullaClaimV2 is ERC721, Ownable, IBullaClaimV2 {
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
    /// Restricts which functions can be called. Options: Unlocked, NoNewClaims, Locked:
    LockState public lockState;
    /// the total amount of claims minted
    uint256 public currentClaimId;
    /// approval registry for managing user approvals
    IBullaApprovalRegistry public approvalRegistry;
    /// a contract to generate an on-chain SVG with a claim's status
    IClaimMetadataGenerator public claimMetadataGenerator;
    /// Core protocol fee for creating claims
    uint256 public CORE_PROTOCOL_FEE;
    IPermissions public feeExemptions;

    /*///////////////////////////////////////////////////////////////
                           MODIFIERS
    //////////////////////////////////////////////////////////////*/

    function _notLocked() internal view {
        if (lockState == LockState.Locked) revert Locked();
    }

    constructor(address _approvalRegistry, LockState _lockState, uint256 _coreProtocolFee, address _feeExemptions)
        ERC721("BullaClaimV2", "CLAIM")
        Ownable(msg.sender)
    {
        approvalRegistry = IBullaApprovalRegistry(_approvalRegistry);
        lockState = _lockState;
        CORE_PROTOCOL_FEE = _coreProtocolFee;
        feeExemptions = IPermissions(_feeExemptions);
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
    function createClaim(CreateClaimParams calldata params) external payable returns (uint256) {
        return _createClaim(msg.sender, params);
    }

    /// @notice allows a controller to create a claim on behalf of a user
    /// @notice SPEC:
    ///     1. verify and spend msg.sender's approval to create claims
    ///     2. create a claim on `from`'s behalf
    function createClaimFrom(address from, CreateClaimParams calldata params) external payable returns (uint256) {
        approvalRegistry.spendCreateClaimApproval(from, msg.sender, params.creditor, params.debtor, params.binding);

        return _createClaim(from, params);
    }

    /// @notice allows a user to create a claim with optional attachmentURI and / or a custom tokenURI
    /// @notice SPEC:
    ///     1. create a claim with metadata from the msg.sender
    function createClaimWithMetadata(CreateClaimParams calldata params, ClaimMetadata calldata metadata)
        external
        payable
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
    ) external payable returns (uint256) {
        approvalRegistry.spendCreateClaimApproval(from, msg.sender, params.creditor, params.debtor, params.binding);

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
        BullaClaimValidationLib.validateCreateClaimParams(from, params, feeExemptions, CORE_PROTOCOL_FEE, msg.value);

        uint256 claimId;
        // from is only != to msg.sender if the claim is delegated
        address controller = msg.sender == from ? address(0) : msg.sender;
        {
            unchecked {
                claimId = currentClaimId++;
            }

            ClaimStorage storage claim = claims[claimId];

            claim.claimAmount = params.claimAmount.safeCastTo128(); //TODO: is this necessary?
            claim.debtor = params.debtor;
            claim.originalCreditor = params.creditor;

            if (params.token != address(0)) claim.token = params.token;
            if (controller != address(0)) claim.controller = controller;
            if (params.binding != ClaimBinding.Unbound) claim.binding = params.binding;
            if (params.dueBy != 0) claim.dueBy = uint40(params.dueBy);
            if (params.impairmentGracePeriod != 0) claim.impairmentGracePeriod = uint40(params.impairmentGracePeriod);
        }

        emit ClaimCreated(
            claimId,
            from,
            params.creditor,
            params.debtor,
            params.claimAmount,
            params.dueBy,
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
        Claim memory claim = getClaim(claimId);
        _payClaim(msg.sender, claimId, claim, amount);
    }

    /// @notice allows a controller to pay a claim on behalf of a user
    /// @notice SPEC:
    ///     1. verify the claim is controlled
    ///     2. call payClaim on `from`'s behalf
    function payClaimFrom(address from, uint256 claimId, uint256 amount) external payable {
        Claim memory claim = getClaim(claimId);
        if (claim.controller == address(0)) revert MustBeControlledClaim();

        _payClaim(from, claimId, claim, amount);
    }

    /// @notice Allows a controller to pay a claim without transferring tokens
    /// @dev This function is only callable by the controller of the claim
    /// @param from The address that is paying the claim
    /// @param claimId The ID of the claim to pay
    /// @param amount The amount to pay
    function payClaimFromControllerWithoutTransfer(address from, uint256 claimId, uint256 amount) external {
        Claim memory claim = getClaim(claimId);

        // Only controlled claims can use this function
        if (claim.controller == address(0)) revert MustBeControlledClaim();

        // Only the controller can call this function
        if (claim.controller != msg.sender) revert NotController(msg.sender);

        _updateClaimPaymentState(from, claimId, claim, amount);
    }

    /// @notice Allows any user to pay a claim with the token the claim is denominated in
    /// @notice NOTE: if the claim token is address(0) (eth) then we use the eth transferred to the contract. If this function is called via PayClaimFrom,
    ///     then the calling function must handle the sending of `from`'s eth to contract and then call this function.
    /// @notice SPEC:
    ///     Allow a user to pay a claim given:
    ///         1. The contract is not locked
    ///         2. The claim is minted and not burned
    ///         ... TODO
    function _payClaim(address from, uint256 claimId, Claim memory claim, uint256 paymentAmount) internal {
        // We allow for claims to be "controlled". Meaning, it is another smart contract's responsibility to implement
        //      custom logic, then call these functions. We check the msg.sender against the controller to make sure a user
        //      isn't trying to bypass controller specific logic (eg: late fees) and by going to this contract directly.
        if (claim.controller != address(0) && msg.sender != claim.controller) revert NotController(msg.sender);

        // Validate msg.value for ETH payments to prevent underpayment vulnerability
        if (claim.token == address(0)) {
            if (msg.value != paymentAmount) {
                revert IncorrectMsgValue();
            }
        }

        // Update payment state first to follow checks-effects-interactions pattern
        _updateClaimPaymentState(from, claimId, claim, paymentAmount);

        // Process token transfer after state is updated
        claim.token == address(0)
            ? claim.creditor.safeTransferETH(paymentAmount)
            : ERC20(claim.token).safeTransferFrom(from, claim.creditor, paymentAmount);
    }

    /// @notice Updates claim payment state without transferring tokens
    /// @param from The address that is paying the claim
    /// @param claimId The ID of the claim to pay
    /// @param claim The claim to pay
    /// @param paymentAmount The amount to pay
    function _updateClaimPaymentState(address from, uint256 claimId, Claim memory claim, uint256 paymentAmount)
        internal
    {
        _notLocked();

        // Use validation library for payment validation and calculation
        (uint256 totalPaidAmount, bool claimPaid) =
            BullaClaimValidationLib.validateAndCalculatePayment(from, claim, paymentAmount);

        ClaimStorage storage claimStorage = claims[claimId];

        claimStorage.paidAmount = uint128(totalPaidAmount);
        // if the claim is now fully paid, update the status to paid
        // if the claim is still not fully paid, update the status to repaying
        claimStorage.status = claimPaid ? Status.Paid : Status.Repaying;

        emit ClaimPayment(claimId, from, paymentAmount, totalPaidAmount);
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
    ///     1. verify the claim is controlled
    ///     2. update the binding on `from`'s behalf
    function updateBindingFrom(address from, uint256 claimId, ClaimBinding binding) external {
        if (getClaim(claimId).controller == address(0)) revert MustBeControlledClaim();

        _updateBinding(from, claimId, binding);
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
        address creditor = _ownerOf(claimId);

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
    ///     1. verify the claim is controlled
    ///     2. cancel the claim on `from`'s behalf
    function cancelClaimFrom(address from, uint256 claimId, string calldata note) external {
        if (getClaim(claimId).controller == address(0)) revert MustBeControlledClaim();

        _cancelClaim(from, claimId, note);
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
        address creditor = _ownerOf(claimId);

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
    ///     1. verify the claim is controlled
    ///     2. impair the claim on `from`'s behalf
    function impairClaimFrom(address from, uint256 claimId) external {
        if (getClaim(claimId).controller == address(0)) revert MustBeControlledClaim();

        _impairClaim(from, claimId);
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
        address creditor = _ownerOf(claimId);

        if (claim.controller != address(0) && msg.sender != claim.controller) revert NotController(msg.sender);

        // Use validation library for impairment validation
        BullaClaimValidationLib.validateClaimImpairment(from, claim, creditor);

        claims[claimId].status = Status.Impaired;
        emit ClaimImpaired(claimId);
    }

    /**
     * /// MARK CLAIM AS PAID ///
     */

    /// @notice allows a creditor to manually mark a claim as paid even if not fully paid
    /// @notice SPEC:
    ///     1. call markClaimAsPaid on behalf of the msg.sender
    function markClaimAsPaid(uint256 claimId) external {
        _markClaimAsPaid(msg.sender, claimId);
    }

    /// @notice allows a controller to mark a claim as paid on behalf of a creditor
    /// @notice SPEC:
    ///     1. verify the claim is controlled
    ///     2. mark the claim as paid on `from`'s behalf
    function markClaimAsPaidFrom(address from, uint256 claimId) external {
        if (getClaim(claimId).controller == address(0)) revert MustBeControlledClaim();

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
        address creditor = _ownerOf(claimId);

        if (claim.controller != address(0) && msg.sender != claim.controller) revert NotController(msg.sender);

        // Use validation library for mark as paid validation
        BullaClaimValidationLib.validateMarkAsPaid(from, claim, creditor);

        claims[claimId].status = Status.Paid;

        emit ClaimMarkedAsPaid(claimId);
    }

    /*///////////////////////////////////////////////////////////////
                       VIEW / UTILITY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function getClaim(uint256 claimId) public view returns (Claim memory claim) {
        if (claimId >= currentClaimId) revert NotMinted();

        ClaimStorage memory claimStorage = claims[claimId];
        claim = Claim({
            claimAmount: uint256(claimStorage.claimAmount),
            paidAmount: uint256(claimStorage.paidAmount),
            status: claimStorage.status,
            binding: claimStorage.binding,
            debtor: claimStorage.debtor,
            creditor: _ownerOf(claimId),
            token: claimStorage.token,
            controller: claimStorage.controller,
            originalCreditor: claimStorage.originalCreditor,
            dueBy: claimStorage.dueBy,
            impairmentGracePeriod: claimStorage.impairmentGracePeriod
        });
    }

    /*///////////////////////////////////////////////////////////////
                           ERC721 FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice get the tokenURI generated for this claim
    function tokenURI(uint256 claimId) public view override(ERC721) returns (string memory) {
        string memory uri = claimMetadata[claimId].tokenURI;
        if (bytes(uri).length > 0) {
            return uri;
        } else {
            Claim memory claim = getClaim(claimId);
            address _owner = _ownerOf(claimId);
            return claimMetadataGenerator.tokenURI(claim, claimId, _owner);
        }
    }

    function ownerOf(uint256 claimId) public view override(ERC721, IERC721) returns (address) {
        return _ownerOf(claimId);
    }

    function safeTransferFromFrom(
        address fromAkaOriginalMsgSender,
        address fromAkaNftOwner,
        address to,
        uint256 claimId,
        bytes memory data
    ) public {
        // Check if this is a controlled claim
        Claim memory claim = getClaim(claimId);
        if (claim.controller == address(0)) revert MustBeControlledClaim();

        _safeTransferFromFrom(fromAkaOriginalMsgSender, fromAkaNftOwner, to, claimId, data);
    }

    function safeTransferFrom(address from, address to, uint256 claimId, bytes memory data)
        public
        override(ERC721, IERC721)
    {
        _safeTransferFromFrom(msg.sender, from, to, claimId, data);
    }

    /// @notice Copied the super implementation but replaced _msgSender with fromAkaOriginalMsgSender
    function _safeTransferFromFrom(
        address fromAkaOriginalMsgSender,
        address fromAkaNftOwner,
        address to,
        uint256 claimId,
        bytes memory data
    ) private {
        _transferFrom(fromAkaOriginalMsgSender, fromAkaNftOwner, to, claimId);
        ERC721Utils.checkOnERC721Received(fromAkaOriginalMsgSender, fromAkaNftOwner, to, claimId, data);
    }

    function transferFromFrom(address fromAkaOriginalMsgSender, address fromAkaNftOwner, address to, uint256 claimId)
        public
    {
        // Check if this is a controlled claim
        Claim memory claim = getClaim(claimId);
        if (claim.controller == address(0)) revert MustBeControlledClaim();

        _transferFrom(fromAkaOriginalMsgSender, fromAkaNftOwner, to, claimId);
    }

    function transferFrom(address from, address to, uint256 claimId) public override(ERC721, IERC721) {
        _transferFrom(msg.sender, from, to, claimId);
    }

    function _transferFrom(address fromAkaOriginalMsgSender, address fromAkaNftOwner, address to, uint256 claimId)
        private
    {
        Claim memory claim = getClaim(claimId);
        if (claim.controller != address(0) && msg.sender != claim.controller) revert NotController(msg.sender);

        if (to == address(0)) {
            revert ERC721InvalidReceiver(address(0));
        }

        // Copied the super implementation but replaced _msgSender with fromAkaOriginalMsgSender
        address previousOwner = _update(to, claimId, fromAkaOriginalMsgSender);
        if (previousOwner != fromAkaNftOwner) {
            revert ERC721IncorrectOwner(fromAkaNftOwner, claimId, previousOwner);
        }
    }

    function approveFrom(address from, address to, uint256 claimId) public {
        // Check if this is a controlled claim
        Claim memory claim = getClaim(claimId);
        if (claim.controller == address(0)) revert MustBeControlledClaim();

        _approveFrom(from, to, claimId);
    }

    function approve(address to, uint256 claimId) public override(ERC721, IERC721) {
        _approveFrom(msg.sender, to, claimId);
    }

    function _approveFrom(address from, address to, uint256 claimId) private {
        // Check if this is a controlled claim
        Claim memory claim = getClaim(claimId);
        if (claim.controller != address(0) && msg.sender != claim.controller) revert NotController(msg.sender);

        super._approve(to, claimId, from);
    }

    function setApprovalForAll(address, bool) public pure override(ERC721, IERC721) {
        // This is physically impossible, because users will have multiple claim types, so we can't set approval for all
        // claims at once.
        revert NotSupported();
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, IERC165) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    /*///////////////////////////////////////////////////////////////
                           OWNER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function owner() public view override(Ownable, IBullaClaimAdmin) returns (address) {
        return super.owner();
    }

    function setClaimMetadataGenerator(address _metadataGenerator) external onlyOwner {
        claimMetadataGenerator = IClaimMetadataGenerator(_metadataGenerator);
    }

    function setLockState(LockState _lockState) external onlyOwner {
        lockState = _lockState;
    }

    function setCoreProtocolFee(uint256 _coreProtocolFee) external onlyOwner {
        CORE_PROTOCOL_FEE = _coreProtocolFee;
    }

    function setFeeExemptions(address _feeExemptions) external onlyOwner {
        feeExemptions = IPermissions(_feeExemptions);
    }

    /**
     * @notice Allows owner to withdraw accumulated core protocol fees
     */
    function withdrawAllFees() external onlyOwner {
        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            (bool success,) = payable(owner()).call{value: ethBalance}("");
            if (!success) revert WithdrawalFailed();
            emit FeeWithdrawn(owner(), ethBalance);
        }
    }
}
