//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.15;

import "contracts/types/Types.sol";
import {IBullaFeeCalculator} from "contracts/interfaces/IBullaFeeCalculator.sol";
import {BullaExtensionRegistry} from "contracts/BullaExtensionRegistry.sol";
import {EIP712} from "openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {SafeCastLib} from "solmate/utils/SafeCastLib.sol";
import {BoringBatchable} from "contracts/libraries/BoringBatchable.sol";
import {BullaClaimEIP712} from "contracts/libraries/BullaClaimEIP712.sol";
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
    error IncorrectDueDate(uint256 dueBy);
    error ClaimBound(uint256 claimId);
    error NotOwner();
    error CannotBindClaim();
    error InvalidSignature();
    error NotCreditorOrDebtor(address sender);
    error OverPaying(uint256 paymentAmount);
    error ClaimNotPending(uint256 claimId);
    error ClaimDelegated(uint256 claimId, address delegator);
    error NotDelegator(address sender);
    error NotMinted(uint256 claimId);
    error NotApproved(address operator);
    error Unauthorized();
    error Locked();

    modifier notLocked() {
        if (lockState == LockState.Locked) {
            revert Locked();
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

    event CreateClaimApproved(
        address indexed owner,
        address indexed operator,
        CreateClaimApprovalType indexed approvalType,
        uint256 approvalCount,
        bool isBindingAllowed
    );

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

    /// @notice allows a user to create a claim from their address
    function createClaim(CreateClaimParams calldata params) external returns (uint256) {
        return _createClaim(msg.sender, params);
    }

    /// @notice same as createClaim but allows a caller (operator) to create a claim on behalf of a user
    /// @notice SPEC:
    ///     1. verify and spend msg.sender's approval to create claims
    ///     2. create a claim on `from`'s behalf
    function createClaimFrom(address from, CreateClaimParams calldata params) external returns (uint256) {
        _spendCreateClaimApproval(from, msg.sender, params.creditor, params.debtor, params.binding);

        return _createClaim(from, params);
    }

    /// @notice same as createClaim() but with a token/attachmentURI
    function createClaimWithMetadata(CreateClaimParams calldata params, ClaimMetadata calldata metadata)
        external
        returns (uint256)
    {
        return _createClaimWithMetadata(msg.sender, params, metadata);
    }

    /// @notice same as createClaimFrom() but with a token/attachmentURI
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

    /// @notice "spends" an operator's create claim approval
    /// @notice SPEC:
    /// A function can call this function to verify and "spend" `from`'s approval of `operator` to create a claim:
    ///     S1. `operator` has > 0 approvalCount from `from` address -> otherwise: reverts
    ///     S2. The creditor and debtor parameters are permissed by the `from` address
    ///        Meaning:
    ///         - If the approvalType is `CreditorOnly` the `from` address must be the creditor -> otherwise: reverts
    ///         - If the approvalType is `DebtorOnly` the `from` address must be the debtor -> otherwise: reverts
    ///        Note: If the approvalType is `Approved`, the `operator` may specify the `from` address as the creditor, the debtor, _or neither_
    ///     S3. If the claimBinding parameter is `Bound`, then the isBindingAllowed permission must be set to true -> otherwise: reverts
    ///        Note: _createClaim will always revert if the claimBinding parameter is `Bound` and the `from` address is not the debtor
    ///
    /// Result: If the above are true, and the approvalCount != type(uint64).max, decrement the approval count by 1 and return
    function _spendCreateClaimApproval(
        address from,
        address operator,
        address creditor,
        address debtor,
        ClaimBinding binding
    ) internal {
        CreateClaimApproval memory approval = approvals[from][operator].createClaim;

        // spec.S1
        if (approval.approvalCount == 0) revert NotApproved(operator);

        // spec.S2
        if (
            (approval.approvalType == CreateClaimApprovalType.CreditorOnly && from != creditor)
                || (approval.approvalType == CreateClaimApprovalType.DebtorOnly && from != debtor)
        ) {
            revert Unauthorized();
        }

        // spec.S3
        if (binding == ClaimBinding.Bound && !approval.isBindingAllowed) {
            revert Unauthorized();
        }

        // result
        if (approval.approvalCount != type(uint64).max) {
            approvals[from][operator].createClaim.approvalCount -= 1;
        }

        return;
    }

    /// @notice Creates a claim between two addresses for a certain amount and token
    /// @notice the claim NFT is minted to the creditor - in other words: the wallet owed money holds the NFT.
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
            revert IncorrectDueDate(params.dueBy);
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
                             PERMIT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice allows a user - via a signature - to appove an operator to call createClaim on their behalf
    /// @notice SPEC:
    /// Anyone can call this function with a valid signature to modify the `owner`'s CreateClaimApproval of `operator` to the provided parameters
    /// This function can _approve_ an operator given:
    ///     A1. The recovered signer from the EIP712 signature == `owner` TODO: OR if `owner.code.length` > 0, an EIP-1271 signature lookup is valid
    ///     A2. `owner` is not a 0 address
    ///     A3. 0 < `approvalCount` < type(uint64).max
    ///     A4. `extensionRegistry` is not address(0)
    /// This function can _revoke_ an operator given:
    ///     R1. The recovered signer from the EIP712 signature == `owner`
    ///     R2. `owner` is not a 0 address
    ///     R3. `approvalCount` == 0
    ///     R4. `extensionRegistry` is not address(0)
    ///
    /// A valid approval signature is defined as: a signed EIP712 hash digest of the following parameters:
    ///     S1. The hash of the EIP712 typedef string
    ///     S2. The `owner` address
    ///     S3. The `operator` address
    ///     S4. A verbose approval message: see `BullaClaimEIP712.getPermitCreateClaimMessage`
    ///     S5. The `approvalType` enum as a uint8
    ///     S6. The `approvalCount`
    ///     S7. The `isBindingAllowed` boolean flag
    ///     S8. The stored signing nonce found in `owner`'s CreateClaimApproval struct for `operator`

    /// Result: If the above conditions are met:
    ///     RES1: The nonce is incremented
    ///     RES2: The `owner`'s approval of `operator` is updated
    ///     RES3: A CreateClaimApproved event is emitted with the approval parameters
    function permitCreateClaim(
        address owner, // todo: rename owner -> user?
        address operator,
        CreateClaimApprovalType approvalType,
        uint64 approvalCount,
        bool isBindingAllowed,
        Signature calldata signature
    ) public {
        // TODO: EIP-1271 smart contract signatures
        bytes32 digest;
        {
            uint256 nonce = approvals[owner][operator].createClaim.nonce++; // spec.RES1
            digest = _hashTypedDataV4(
                keccak256(
                    abi.encode(
                        BullaClaimEIP712.CREATE_CLAIM_TYPEHASH, // spec.S1
                        owner, // spec.S2
                        operator, // spec.S3
                        // spec.S4
                        BullaClaimEIP712.getPermitCreateClaimMessageDigest(
                            extensionRegistry, // spec.A4 // spec.R4 /// WARNING: this could revert!
                            operator,
                            approvalType,
                            approvalCount,
                            isBindingAllowed
                        ),
                        approvalType, // spec.S5
                        approvalCount, // spec.S6
                        isBindingAllowed, // spec.S7
                        nonce // spec.S8
                    )
                )
            );
        }

        address signer = ecrecover(digest, signature.v, signature.r, signature.s);
        // address 0 check to prevent approval of the 0 address
        if (
            signer != owner // spec.A1 // spec.R1
                || signer == address(0) // spec.A2 // spec.R2
        ) revert InvalidSignature();

        // revoke case // spec.R3
        if (approvalCount == 0) {
            // spec.RES2
            delete approvals[owner][operator].createClaim.isBindingAllowed;
            delete approvals[owner][operator].createClaim.approvalType;
            delete approvals[owner][operator].createClaim.approvalCount;
        } else {
            // approve case
            // spec.RES2
            approvals[owner][operator].createClaim.isBindingAllowed = isBindingAllowed;
            approvals[owner][operator].createClaim.approvalType = approvalType;
            approvals[owner][operator].createClaim.approvalCount = approvalCount;
        }

        // spec.RES3
        emit CreateClaimApproved(owner, operator, approvalType, approvalCount, isBindingAllowed);
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

    /*///////////////////////////////////////////////////////////////
                        VIEW / UTILITY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return _domainSeparatorV4();
    }

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
