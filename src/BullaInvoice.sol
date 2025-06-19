// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import "./interfaces/IBullaClaim.sol";
import "./interfaces/IBullaInvoice.sol";
import "./BullaClaimControllerBase.sol";
import "./types/Types.sol";
import "./libraries/CompoundInterestLib.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {ERC165} from "openzeppelin-contracts/contracts/utils/introspection/ERC165.sol";
import {BoringBatchable} from "./libraries/BoringBatchable.sol";

// Data specific to invoices and not claims
struct InvoiceDetails {
    bool requestedByCreditor;
    bool isProtocolFeeExempt;
    PurchaseOrderState purchaseOrder;
    InterestConfig lateFeeConfig;
    InterestComputationState interestComputationState;
}

error InvalidDeliveryDate();
error NotOriginalCreditor();
error PurchaseOrderAlreadyDelivered();
error InvoiceNotPending();
error NotPurchaseOrder();
error PayingZero();
error InvalidDepositAmount();
error NotAuthorizedForBinding();
error InvalidMsgValue();
error InvalidProtocolFee();
error IncorrectMsgValue();
error IncorrectFee();
error NotAdmin();
error WithdrawalFailed();
error NotCreditorOrDebtor();
error InvoiceBatchInvalidMsgValue();
error InvoiceBatchInvalidCalldata();

/**
 * @title BullaInvoice
 * @notice A wrapper contract for IBullaClaim that delegates all calls to the provided contract instance
 */
contract BullaInvoice is BullaClaimControllerBase, BoringBatchable, ERC165, IBullaInvoice {
    using SafeTransferLib for address;
    using SafeTransferLib for ERC20;

    address public admin;
    uint256 public protocolFeeBPS;

    ClaimMetadata public EMPTY_METADATA = ClaimMetadata({attachmentURI: "", tokenURI: ""});

    address[] public protocolFeeTokens;
    mapping(address => uint256) public protocolFeesByToken;
    mapping(address => bool) private _tokenExists;

    mapping(uint256 => InvoiceDetails) private _invoiceDetailsByClaimId;

    // Track if we're currently in a batch operation to skip individual fee validation
    bool private _inBatchOperation;

    event InvoiceCreated(uint256 indexed claimId, InvoiceDetails invoiceDetails);
    event InvoicePaid(uint256 indexed claimId, uint256 grossInterestPaid, uint256 principalPaid, uint256 protocolFee);
    event ProtocolFeeUpdated(uint256 oldFee, uint256 newFee);
    event PurchaseOrderDelivered(uint256 indexed claimId);
    event FeeWithdrawn(address indexed admin, address indexed token, uint256 amount);
    /**
     * @notice Constructor
     * @param bullaClaim Address of the IBullaClaim contract to delegate calls to
     * @param _admin Address of the contract administrator
     * @param _protocolFeeBPS Protocol fee in basis points taken from interest payments
     */

    constructor(address bullaClaim, address _admin, uint256 _protocolFeeBPS) BullaClaimControllerBase(bullaClaim) {
        admin = _admin;
        if (_protocolFeeBPS > MAX_BPS) revert InvalidProtocolFee();
        protocolFeeBPS = _protocolFeeBPS;
    }

    /**
     * @notice Get an invoice
     * @param claimId The ID of the invoice to get
     * @return The invoice
     */
    function getInvoice(uint256 claimId) external view returns (Invoice memory) {
        Claim memory claim = _bullaClaim.getClaim(claimId);
        _checkController(claim.controller);

        InvoiceDetails memory invoiceDetails = _invoiceDetailsByClaimId[claimId];

        if (claim.status == Status.Pending || claim.status == Status.Repaying || claim.status == Status.Impaired) {
            invoiceDetails.interestComputationState = CompoundInterestLib.computeInterest(
                claim.claimAmount - claim.paidAmount,
                claim.dueBy,
                invoiceDetails.lateFeeConfig,
                invoiceDetails.interestComputationState
            );
        }

        return Invoice({
            claimAmount: claim.claimAmount,
            paidAmount: claim.paidAmount,
            status: claim.status,
            binding: claim.binding,
            payerReceivesClaimOnPayment: claim.payerReceivesClaimOnPayment,
            debtor: claim.debtor,
            creditor: claim.creditor,
            token: claim.token,
            dueBy: claim.dueBy,
            purchaseOrder: invoiceDetails.purchaseOrder,
            lateFeeConfig: invoiceDetails.lateFeeConfig,
            interestComputationState: invoiceDetails.interestComputationState
        });
    }

    /**
     * @notice Get the total amount needed to complete a purchase order deposit (including accrued interest)
     * @param claimId The ID of the invoice/purchase order
     * @return The total amount needed to pay to complete the deposit
     */
    function getTotalAmountNeededForPurchaseOrderDeposit(uint256 claimId) external returns (uint256) {
        Claim memory claim = _bullaClaim.getClaim(claimId);
        _checkController(claim.controller);

        InvoiceDetails memory invoiceDetails = _invoiceDetailsByClaimId[claimId];

        // Check if this is a purchase order that hasn't been delivered yet
        if (invoiceDetails.purchaseOrder.deliveryDate != 0 && !invoiceDetails.purchaseOrder.isDelivered) {
            if (invoiceDetails.purchaseOrder.depositAmount > claim.paidAmount) {
                // Calculate accrued interest and update the stored state for active claims
                InterestComputationState memory interestComputationState = CompoundInterestLib.computeInterest(
                    claim.claimAmount - claim.paidAmount,
                    claim.dueBy,
                    invoiceDetails.lateFeeConfig,
                    invoiceDetails.interestComputationState
                );

                if (invoiceDetails.lateFeeConfig.interestRateBps > 0) {
                    _invoiceDetailsByClaimId[claimId].interestComputationState = interestComputationState;
                }

                return
                    _getTotalAmountNeededForPurchaseOrderDepositUnsafe(claim, invoiceDetails, interestComputationState);
            }
        }

        return 0; // No remaining deposit amount needed
    }

    /**
     * @notice Private function to get total amount needed without recalculating interest
     * @param claim The claim data
     * @param invoiceDetails The invoice details
     * @param interestComputationState The current interest computation state
     * @return The total amount needed to pay to complete the deposit
     */
    function _getTotalAmountNeededForPurchaseOrderDepositUnsafe(
        Claim memory claim,
        InvoiceDetails memory invoiceDetails,
        InterestComputationState memory interestComputationState
    ) private pure returns (uint256) {
        if (invoiceDetails.purchaseOrder.deliveryDate != 0 && !invoiceDetails.purchaseOrder.isDelivered) {
            if (invoiceDetails.purchaseOrder.depositAmount > claim.paidAmount) {
                uint256 remainingPrincipalDeposit = invoiceDetails.purchaseOrder.depositAmount - claim.paidAmount;

                // Total amount needed = all accrued interest + remaining principal deposit
                // payInvoice will pay interest first, then principal
                return interestComputationState.accruedInterest + remainingPrincipalDeposit;
            }
        }

        return 0; // No remaining deposit amount needed
    }
    /**
     * @notice Creates an invoice
     * @param params The parameters for creating an invoice
     * @return The ID of the created invoice
     */

    function createInvoice(CreateInvoiceParams memory params) external payable returns (uint256) {
        return _createInvoice(params, EMPTY_METADATA);
    }

    /**
     * @notice Creates an invoice with metadata
     * @param params The parameters for creating an invoice
     * @param metadata The metadata for the invoice
     * @return The ID of the created invoice
     */
    function createInvoiceWithMetadata(CreateInvoiceParams memory params, ClaimMetadata memory metadata)
        external
        payable
        returns (uint256)
    {
        return _createInvoice(params, metadata);
    }

    function _createInvoice(CreateInvoiceParams memory params, ClaimMetadata memory metadata)
        private
        returns (uint256)
    {
        bool isProtocolFeeExempt = _bullaClaim.feeExemptions().isAllowed(params.debtor)
            || _bullaClaim.feeExemptions().isAllowed(params.creditor);

        uint256 fee = isProtocolFeeExempt ? 0 : _bullaClaim.CORE_PROTOCOL_FEE();
        _validateCreateInvoiceParams(params, fee);

        CreateClaimParams memory createClaimParams = CreateClaimParams({
            creditor: params.creditor,
            debtor: params.debtor,
            claimAmount: params.claimAmount,
            description: params.description,
            token: params.token,
            binding: params.binding,
            payerReceivesClaimOnPayment: params.payerReceivesClaimOnPayment,
            dueBy: params.dueBy,
            impairmentGracePeriod: params.impairmentGracePeriod
        });

        uint256 claimId = bytes(metadata.attachmentURI).length > 0 && bytes(metadata.tokenURI).length > 0
            ? _bullaClaim.createClaimWithMetadataFrom{value: fee}(msg.sender, createClaimParams, metadata)
            : _bullaClaim.createClaimFrom{value: fee}(msg.sender, createClaimParams);

        InvoiceDetails memory invoiceDetails = InvoiceDetails({
            purchaseOrder: PurchaseOrderState({
                deliveryDate: params.deliveryDate,
                isDelivered: false,
                depositAmount: params.depositAmount
            }),
            lateFeeConfig: params.lateFeeConfig,
            interestComputationState: InterestComputationState({accruedInterest: 0, latestPeriodNumber: 0}),
            requestedByCreditor: msg.sender == params.creditor,
            isProtocolFeeExempt: isProtocolFeeExempt
        });

        _invoiceDetailsByClaimId[claimId] = invoiceDetails;

        emit InvoiceCreated(claimId, invoiceDetails);

        return claimId;
    }

    function deliverPurchaseOrder(uint256 claimId) external {
        Claim memory claim = _bullaClaim.getClaim(claimId);
        _checkController(claim.controller);

        InvoiceDetails memory invoiceDetails = _invoiceDetailsByClaimId[claimId];

        if (claim.originalCreditor != msg.sender) {
            revert NotOriginalCreditor();
        }

        if (invoiceDetails.purchaseOrder.deliveryDate == 0) {
            revert NotPurchaseOrder();
        }

        if (invoiceDetails.purchaseOrder.isDelivered) {
            revert PurchaseOrderAlreadyDelivered();
        }

        if (claim.status != Status.Pending && claim.status != Status.Repaying) {
            revert InvoiceNotPending();
        }

        _invoiceDetailsByClaimId[claimId].purchaseOrder.isDelivered = true;

        emit PurchaseOrderDelivered(claimId);
    }

    /**
     * @notice Pays an invoice and updates interest before processing the payment
     * @param claimId The ID of the invoice to pay
     * @param paymentAmount The amount to pay
     */
    function payInvoice(uint256 claimId, uint256 paymentAmount) public payable {
        Claim memory claim = _bullaClaim.getClaim(claimId);
        _checkController(claim.controller);

        InvoiceDetails memory invoiceDetails = _invoiceDetailsByClaimId[claimId];

        InterestComputationState memory interestComputationState = CompoundInterestLib.computeInterest(
            claim.claimAmount - claim.paidAmount,
            claim.dueBy,
            invoiceDetails.lateFeeConfig,
            invoiceDetails.interestComputationState
        );

        uint256 grossInterestBeingPaid = Math.min(paymentAmount, interestComputationState.accruedInterest);
        uint256 principalBeingPaid =
            Math.min(paymentAmount - grossInterestBeingPaid, claim.claimAmount - claim.paidAmount);
        paymentAmount = principalBeingPaid + grossInterestBeingPaid;

        if (paymentAmount == 0) {
            revert PayingZero();
        }

        // need to check this because calling bulla claim since it might transfer the claim to the creditor if `payerReceivesClaimOnPayment` is true
        address creditor = _bullaClaim.ownerOf(claimId);

        // Calculate protocol fee from interest only
        uint256 protocolFee = invoiceDetails.isProtocolFeeExempt ? 0 : _calculateProtocolFee(grossInterestBeingPaid);
        uint256 creditorInterest = grossInterestBeingPaid - protocolFee;
        uint256 creditorTotal = creditorInterest + principalBeingPaid;

        // Update claim state in BullaClaim BEFORE transfers (for re-entrancy protection)
        if (principalBeingPaid > 0) {
            _bullaClaim.payClaimFromControllerWithoutTransfer(msg.sender, claimId, principalBeingPaid);
        }

        // Update interest computation state
        if (invoiceDetails.lateFeeConfig.interestRateBps > 0) {
            _invoiceDetailsByClaimId[claimId].interestComputationState = InterestComputationState({
                accruedInterest: interestComputationState.accruedInterest - grossInterestBeingPaid,
                latestPeriodNumber: interestComputationState.latestPeriodNumber
            });
        }

        if (paymentAmount > 0) {
            if (claim.token == address(0)) {
                if (msg.value != paymentAmount) {
                    revert IncorrectMsgValue();
                }

                // Handle ETH payments
                // Protocol fee for ETH stays in contract for admin withdrawal
                if (creditorTotal > 0) {
                    creditor.safeTransferETH(creditorTotal);
                }
            } else {
                // Track protocol fee for this token if any interest was paid
                // No need to track gas fee as it is the balance of the contract
                if (protocolFee > 0) {
                    if (!_tokenExists[claim.token]) {
                        protocolFeeTokens.push(claim.token);
                        _tokenExists[claim.token] = true;
                    }
                    protocolFeesByToken[claim.token] += protocolFee;
                }
                // Handle ERC20 payments
                // Transfer the total amount from sender to this contract first
                ERC20(claim.token).safeTransferFrom(msg.sender, address(this), paymentAmount);

                if (creditorTotal > 0) {
                    // Transfer interest (minus protocol fee) and principal to creditor
                    ERC20(claim.token).safeTransfer(creditor, creditorTotal);
                }
            }

            emit InvoicePaid(claimId, grossInterestBeingPaid, principalBeingPaid, protocolFee);
        }
    }

    /**
     * @notice Updates the binding of an invoice
     * @param claimId The ID of the invoice to update
     * @param binding The new binding for the invoice
     */
    function updateBinding(uint256 claimId, ClaimBinding binding) external {
        Claim memory claim = _bullaClaim.getClaim(claimId);
        _checkController(claim.controller);

        return _bullaClaim.updateBindingFrom(msg.sender, claimId, binding);
    }

    /**
     * @notice Cancels an invoice
     * @param claimId The ID of the invoice to cancel
     * @param note The note to cancel the invoice with
     */
    function cancelInvoice(uint256 claimId, string memory note) external {
        Claim memory claim = _bullaClaim.getClaim(claimId);
        _checkController(claim.controller);

        return _bullaClaim.cancelClaimFrom(msg.sender, claimId, note);
    }

    /**
     * @notice Impairs an invoice
     * @param claimId The ID of the invoice to impair
     */
    function impairInvoice(uint256 claimId) external {
        Claim memory claim = _bullaClaim.getClaim(claimId);
        _checkController(claim.controller);

        return _bullaClaim.impairClaimFrom(msg.sender, claimId);
    }

    /**
     * @notice Allows a creditor to manually mark an invoice as paid
     * @param claimId The ID of the invoice to mark as paid
     */
    function markInvoiceAsPaid(uint256 claimId) external {
        Claim memory claim = _bullaClaim.getClaim(claimId);
        _checkController(claim.controller);

        return _bullaClaim.markClaimAsPaidFrom(msg.sender, claimId);
    }

    /**
     * @notice Accepts a purchase order by paying the remaining deposit amount and binding the invoice
     * @param claimId The ID of the invoice to accept
     * @param depositAmount The deposit amount to pay
     */
    function acceptPurchaseOrder(uint256 claimId, uint256 depositAmount) external payable {
        Claim memory claim = _bullaClaim.getClaim(claimId);
        _checkController(claim.controller);

        InvoiceDetails memory invoiceDetails = _invoiceDetailsByClaimId[claimId];

        // Check if this is actually a purchase order (has delivery date)
        if (invoiceDetails.purchaseOrder.deliveryDate == 0) {
            revert NotPurchaseOrder();
        }

        // Only the debtor can call this function for binding operations
        if (msg.sender != claim.debtor) {
            revert NotAuthorizedForBinding();
        }

        // Validate that the payment amount doesn't exceed what's left to pay on the claim
        uint256 amountLeftToPay = claim.claimAmount - claim.paidAmount;
        if (depositAmount > amountLeftToPay) {
            revert InvalidDepositAmount();
        }

        // Calculate and store interest computation state
        InterestComputationState memory interestComputationState = CompoundInterestLib.computeInterest(
            claim.claimAmount - claim.paidAmount,
            claim.dueBy,
            invoiceDetails.lateFeeConfig,
            invoiceDetails.interestComputationState
        );

        if (invoiceDetails.lateFeeConfig.interestRateBps > 0) {
            _invoiceDetailsByClaimId[claimId].interestComputationState = interestComputationState;
        }

        // Pay the deposit amount if any
        if (depositAmount > 0) {
            // Validate msg.value based on token type
            if (claim.token == address(0)) {
                // For ETH claims, msg.value should equal the deposit amount
                if (msg.value != depositAmount) {
                    revert InvalidMsgValue();
                }
            } else {
                // For ERC20 claims, msg.value should be 0
                if (msg.value != 0) {
                    revert InvalidMsgValue();
                }
            }

            // Use payInvoice to handle payment (interest already calculated and stored above)
            payInvoice(claimId, depositAmount);

            // After payment, get updated claim data and use unsafe version
            Claim memory updatedClaim = _bullaClaim.getClaim(claimId);
            InvoiceDetails memory updatedInvoiceDetails = _invoiceDetailsByClaimId[claimId];

            uint256 totalAmountNeeded = _getTotalAmountNeededForPurchaseOrderDepositUnsafe(
                updatedClaim, updatedInvoiceDetails, updatedInvoiceDetails.interestComputationState
            );

            if (totalAmountNeeded == 0) {
                _bullaClaim.updateBindingFrom(msg.sender, claimId, ClaimBinding.Bound);
            }
        } else {
            // If no payment needed, msg.value should be 0
            if (msg.value != 0) {
                revert InvalidMsgValue();
            }

            // Use the already calculated interest computation state
            uint256 totalAmountNeeded =
                _getTotalAmountNeededForPurchaseOrderDepositUnsafe(claim, invoiceDetails, interestComputationState);

            if (totalAmountNeeded == 0) {
                _bullaClaim.updateBindingFrom(msg.sender, claimId, ClaimBinding.Bound);
            }
        }
    }

    /**
     * @notice Allows admin to withdraw accumulated protocol fees
     */
    function withdrawAllFees() external {
        if (msg.sender != admin) revert NotAdmin();

        uint256 ethBalance = address(this).balance;
        // Withdraw protocol fees in ETH
        if (ethBalance > 0) {
            admin.safeTransferETH(ethBalance);
            emit FeeWithdrawn(admin, address(0), ethBalance);
        }

        // Withdraw protocol fees in all tracked tokens
        for (uint256 i = 0; i < protocolFeeTokens.length; i++) {
            address token = protocolFeeTokens[i];
            uint256 feeAmount = protocolFeesByToken[token];

            if (feeAmount > 0) {
                protocolFeesByToken[token] = 0; // Reset fee amount before transfer
                ERC20(token).safeTransfer(admin, feeAmount);
                emit FeeWithdrawn(admin, token, feeAmount);
            }
        }
    }

    /**
     * @notice Allows admin to set the protocol fee percentage
     * @param _protocolFeeBPS New protocol fee in basis points
     */
    function setProtocolFee(uint256 _protocolFeeBPS) external {
        if (msg.sender != admin) revert NotAdmin();
        if (_protocolFeeBPS > MAX_BPS) revert InvalidProtocolFee();

        uint256 oldFee = protocolFeeBPS;
        protocolFeeBPS = _protocolFeeBPS;

        emit ProtocolFeeUpdated(oldFee, _protocolFeeBPS);
    }

    /**
     * @notice Batch create multiple invoices with proper msg.value handling
     * @param calls Array of encoded createInvoice or createInvoiceWithMetadata calls
     */
    function batchCreateInvoices(bytes[] calldata calls) external payable {
        if (calls.length == 0) return;

        uint256 totalRequiredFee = 0;
        uint256 baseFee = _bullaClaim.CORE_PROTOCOL_FEE();
        CreateInvoiceParams memory params;

        // Calculate total required fees by decoding each call and checking exemptions
        for (uint256 i = 0; i < calls.length; i++) {
            bytes4 selector = bytes4(calls[i][:4]);

            if (selector == this.createInvoice.selector) {
                // Decode CreateInvoiceParams from the call
                (params) = abi.decode(calls[i][4:], (CreateInvoiceParams));
            } else if (selector == this.createInvoiceWithMetadata.selector) {
                // Decode CreateInvoiceParams and ClaimMetadata from the call
                (params,) = abi.decode(calls[i][4:], (CreateInvoiceParams, ClaimMetadata));
            } else {
                revert InvoiceBatchInvalidCalldata();
            }

            // Check if either creditor or debtor is exempt
            bool isExempt = _bullaClaim.feeExemptions().isAllowed(params.creditor)
                || _bullaClaim.feeExemptions().isAllowed(params.debtor);

            if (!isExempt) {
                totalRequiredFee += baseFee;
            }
        }

        // Validate total msg.value matches required fees
        if (msg.value != totalRequiredFee) {
            revert InvoiceBatchInvalidMsgValue();
        }

        // Set batch operation flag before executing calls
        _inBatchOperation = true;

        // Execute each call
        for (uint256 i = 0; i < calls.length; i++) {
            (bool success, bytes memory result) = address(this).delegatecall(calls[i]);
            if (!success) {
                _inBatchOperation = false; // Reset flag before reverting
                revert(_getRevertMsg(result));
            }
        }

        // Reset batch operation flag after successful execution
        _inBatchOperation = false;
    }

    /// PRIVATE FUNCTIONS ///

    /**
     * @notice Validates the parameters for creating an invoice
     * @param params The parameters for creating an invoice
     */
    function _validateCreateInvoiceParams(CreateInvoiceParams memory params, uint256 fee) private view {
        if (msg.sender != params.debtor && msg.sender != params.creditor) {
            revert NotCreditorOrDebtor();
        }

        if (
            params.deliveryDate != 0
                && (params.deliveryDate < block.timestamp || params.deliveryDate > type(uint40).max)
        ) {
            revert InvalidDeliveryDate();
        }

        if (params.depositAmount > params.claimAmount) {
            revert InvalidDepositAmount();
        }

        // Skip fee validation when in batch operation (fees are validated at batch level)
        if (!_inBatchOperation) {
            if (msg.value != fee) {
                revert IncorrectFee();
            }
        }

        CompoundInterestLib.validateInterestConfig(params.lateFeeConfig);
    }

    /**
     * @notice Calculate the protocol fee amount based on interest payment
     * @param grossInterestAmount The interest amount to calculate fee from
     * @return The protocol fee amount
     */
    function _calculateProtocolFee(uint256 grossInterestAmount) private view returns (uint256) {
        return Math.mulDiv(grossInterestAmount, protocolFeeBPS, MAX_BPS);
    }

    /**
     * @notice Returns true if this contract implements the interface defined by interfaceId
     * @param interfaceId The interface identifier, as specified in ERC-165
     * @return True if the contract implements interfaceId
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IBullaInvoice).interfaceId || super.supportsInterface(interfaceId);
    }
}
