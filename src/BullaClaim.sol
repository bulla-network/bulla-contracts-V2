//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.15;

import "contracts/types/Types.sol";
import {IBullaFeeCalculator} from "contracts/interfaces/IBullaFeeCalculator.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {SafeCastLib} from "solmate/utils/SafeCastLib.sol";
import {BoringBatchable} from "./libraries/BoringBatchable.sol";
import {Owned} from "solmate/auth/Owned.sol";
import {ERC721} from "solmate/tokens/ERC721.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {ClaimMetadataGenerator} from "contracts/ClaimMetadataGenerator.sol";
import "forge-std/console.sol";

contract BullaClaim is ERC721, Owned, BoringBatchable {
    using SafeTransferLib for *;
    using SafeCastLib for uint256;

    /*///////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// a mapping of claimId to a packed struct
    mapping(uint256 => ClaimStorage) private claims;
    /// a mapping of claimId to token metadata if exists - both attachmentURIs and tokenURIs
    mapping(uint256 => ClaimMetadata) public claimMetadata;
    /// a mapping of enabled "extensions" have have special access to the `*From` functions - gets around msg.sender limitations
    mapping(address => bool) public bullaExtensions;
    /// The contract which calculates the fee for a specific claim - tracked via ids
    uint256 public currentFeeCalculatorId;
    mapping(uint256 => IBullaFeeCalculator) public feeCalculators;
    /// Restricts which functions can be called. Options: Unlocked, NoNewClaims, Locked:
    LockState public lockState;
    /// the address fees are forwarded to
    address public feeCollectionAddress;
    /// the total amount of claims minted
    uint256 public currentClaimId;

    /*///////////////////////////////////////////////////////////////
                            ERRORS / MODIFIERS
    //////////////////////////////////////////////////////////////*/

    error PayingZero();
    error PastDueDate(uint256 dueBy);
    error ClaimBound(uint256 claimId);
    error NotOwner();
    error NotExtension(address sender);
    error CannotBindClaim();
    error NotCreditorOrDebtor(address sender);
    error OverPaying(uint256 paymentAmount);
    error ClaimNotPending(uint256 claimId);
    error ClaimDelegated(uint256 claimId, address delegator);
    error NotDelegator(address sender);
    error NotMinted(uint256 claimId);
    error Locked();

    modifier notLocked() {
        if (lockState == LockState.Locked) {
            revert Locked();
        }
        _;
    }

    modifier onlyExtension() {
        if (!bullaExtensions[msg.sender]) {
            revert NotExtension(msg.sender);
        }
        _;
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

    constructor(address _feeCollectionAddress, LockState _lockState) ERC721("BullaClaim", "CLAIM") Owned(msg.sender) {
        feeCollectionAddress = _feeCollectionAddress;
        lockState = _lockState;
    }

    /*///////////////////////////////////////////////////////////////
                    CLAIM CREATION / UPDATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * /// CREATE FUNCTIONS ///
     */
    function createClaim(CreateClaimParams calldata params) external returns (uint256) {
        // we allow dueBy to be 0 in the case of an "open" claim, or we allow a reasonable timestamp
        if (params.dueBy != 0 && params.dueBy < block.timestamp && params.dueBy < type(uint40).max) {
            revert PastDueDate(params.dueBy);
        }
        // you need the permission of the debtor to bind a claim
        if (params.binding == ClaimBinding.Bound && msg.sender != params.debtor) {
            revert CannotBindClaim();
        }

        return _createClaim(msg.sender, params);
    }

    /// @notice for permissioned extensions
    function createClaimFrom(address from, CreateClaimParams calldata params)
        external
        onlyExtension
        returns (uint256)
    {
        return _createClaim(from, params);
    }

    /// @notice same as createClaim() but with a token/attachmentURI
    function createClaimWithMetadata(CreateClaimParams calldata params, ClaimMetadata calldata metadata)
        external
        returns (uint256)
    {
        if (params.dueBy != 0 && params.dueBy < block.timestamp) {
            revert PastDueDate(params.dueBy);
        }
        if (params.binding == ClaimBinding.Bound && msg.sender != params.debtor) {
            revert CannotBindClaim();
        }

        return _createClaimWithMetadata(msg.sender, params, metadata);
    }

    function createClaimWithMetadataFrom(
        address from,
        CreateClaimParams calldata params,
        ClaimMetadata calldata metadata
    ) external onlyExtension returns (uint256) {
        return _createClaimWithMetadata(from, params, metadata);
    }

    /// @notice the same logic as the createClaim function, but stores a link to an attachmentURI (for any attachment), and a tokenURI (custom metadata) - indexed to the claimID
    /// @return The newly created tokenId
    function _createClaimWithMetadata(address from, CreateClaimParams calldata params, ClaimMetadata calldata metadata)
        internal
        notLocked
        returns (uint256)
    {
        uint256 claimId = _createClaim(from, params);

        claimMetadata[claimId] = metadata;
        emit MetadataAdded(claimId, metadata.tokenURI, metadata.attachmentURI);
        return claimId;
    }

    /// @notice creates a claim between two parties for a certain amount
    /// @notice we mint the claim to the creditor - in other words: the wallet owed money holds the NFT.
    ///         The holder of the NFT will receive the payment from the debtor - See `payClaim` functions for more details.
    /// @notice NOTE: if the `token` param is address(0) then we consider the claim to be denominated in ETH - (native token)
    /// @return The newly created tokenId
    function _createClaim(address from, CreateClaimParams calldata params) internal returns (uint256) {
        if (lockState != LockState.Unlocked) {
            revert Locked();
        }
        if (params.delegator != address(0) && params.delegator != msg.sender) {
            revert NotDelegator(msg.sender);
        }

        uint256 claimId;
        unchecked {
            claimId = ++currentClaimId;
        }

        ClaimStorage storage claim = claims[claimId];

        claim.claimAmount = params.claimAmount.safeCastTo128();
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
     * /// UPDATE BINDING ///
     */

    function updateBinding(uint256 claimId, ClaimBinding binding) external {
        Claim memory claim = getClaim(claimId);
        address creditor = getCreditor(claimId);

        // check if the claim is delegated
        if (claim.delegator != address(0) && msg.sender != claim.delegator) {
            revert ClaimDelegated(claimId, claim.delegator);
        }

        // make sure the sender is authorized
        if (msg.sender != creditor && msg.sender != claim.debtor) {
            revert NotCreditorOrDebtor(msg.sender);
        }

        // make sure the binding is valid
        if (msg.sender == creditor && binding == ClaimBinding.Bound) {
            revert CannotBindClaim();
        }

        // make sure the debtor isn't trying to unbind themselves
        if (msg.sender == claim.debtor && claim.binding == ClaimBinding.Bound) {
            revert ClaimBound(claimId);
        }

        _updateBinding(msg.sender, claimId, binding);
    }

    function updateBindingFrom(address from, uint256 claimId, ClaimBinding binding) external onlyExtension {
        _updateBinding(from, claimId, binding);
    }

    function _updateBinding(address from, uint256 claimId, ClaimBinding binding) internal notLocked {
        claims[claimId].binding = binding;

        emit BindingUpdated(claimId, from, binding);
    }

    /**
     * /// CANCEL CLAIM ///
     */

    function cancelClaim(uint256 claimId, string calldata note) external {
        Claim memory claim = getClaim(claimId);

        if (claim.binding == ClaimBinding.Bound && claim.debtor == msg.sender) {
            revert ClaimBound(claimId);
        }

        if (claim.delegator != address(0) && msg.sender != claim.delegator) {
            revert ClaimDelegated(claimId, claim.delegator);
        }

        _cancelClaim(msg.sender, claimId, note);
    }

    function cancelClaimFrom(address from, uint256 claimId, string calldata note) external onlyExtension {
        _cancelClaim(from, claimId, note);
    }

    function _cancelClaim(address from, uint256 claimId, string calldata note) internal notLocked {
        // load the claim from storage
        Claim memory claim = getClaim(claimId);

        // make sure the claim can be rejected (not completed, not rejected, not rescinded)
        if (claim.status != Status.Pending) {
            revert ClaimNotPending(claimId);
        }

        if (from == getCreditor(claimId)) {
            claims[claimId].status = Status.Rescinded;
            emit ClaimRescinded(claimId, from, note);
        } else if (from == claims[claimId].debtor) {
            claims[claimId].status = Status.Rejected;
            emit ClaimRejected(claimId, from, note);
        } else {
            revert NotCreditorOrDebtor(from);
        }
    }

    function payClaim(uint256 claimId, uint256 amount) external payable {
        Claim memory claim = getClaim(claimId);
        // We allow for claims to be "delegated". Meaning, it is another smart contract's responsibility to implement
        //      custom logic, then call these functions. We check the msg.sender against the delegator to make sure a user
        //      isn't trying to bypass delegator specific logic (eg: late fees) and by going to this contract directly.
        if (claim.delegator != address(0) && msg.sender != claim.delegator) {
            revert ClaimDelegated(claimId, claim.delegator);
        }

        _payClaim(msg.sender, claimId, claim, amount);
    }

    function payClaimFrom(address from, uint256 claimId, uint256 amount) external payable onlyExtension {
        Claim memory claim = getClaim(claimId);

        _payClaim(from, claimId, claim, amount);
    }

    /// @notice pay a claim with tokens (WETH -> ETH included)
    /// @notice NOTE: if the claim token is address(0) (eth) then we use the eth transferred to the contract
    /// @notice NOTE: we transfer the NFT back to whomever makes the final payment of the claim. This represents a receipt of their payment
    /// @notice NOTE: The actual amount "paid off" of the claim may be less if our fee is enabled
    ///              In other words, we treat this `amount` param as the amount the user wants to spend, and then deduct a fee from that amount
    function _payClaim(address from, uint256 claimId, Claim memory claim, uint256 paymentAmount) internal notLocked {
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
     * /// BURN CLAIM ///
     */

    //TODO: should we require the token is paid here?
    function burn(uint256 tokenId) external {
        if (msg.sender != ownerOf(tokenId)) {
            revert NotOwner();
        }

        _burn(tokenId);
    }

    /*///////////////////////////////////////////////////////////////
                            OWNER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function registerExtension(address extension) external onlyOwner {
        bullaExtensions[extension] = true;
    }

    function unregisterExtension(address extension) external onlyOwner {
        delete bullaExtensions[extension];
    }

    function setFeeCalculator(address _feeCalculator) external onlyOwner {
        uint256 nextFeeCalculator;
        unchecked {
            nextFeeCalculator = ++currentFeeCalculatorId;
        }

        feeCalculators[nextFeeCalculator] = IBullaFeeCalculator(_feeCalculator);
    }

    function setFeeCollectionAddress(address newFeeCollector) external onlyOwner {
        feeCollectionAddress = newFeeCollector;
    }

    function setLockState(LockState _lockState) external onlyOwner {
        lockState = _lockState;
    }

    /*///////////////////////////////////////////////////////////////
                        VIEW / UTILITY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function feeCalculator() public view returns (address) {
        return address(feeCalculators[currentFeeCalculatorId]);
    }

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
}
