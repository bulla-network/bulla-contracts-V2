// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {Claim} from "../types/Types.sol";

/// @title IClaimMetadataGenerator
/// @notice Interface for claim metadata generation contracts
interface IClaimMetadataGenerator {
    /// @notice Generates tokenURI metadata for a claim
    /// @param claim The claim data structure
    /// @param claimId The ID of the claim
    /// @param creditor The creditor address
    /// @return The base64 encoded JSON metadata string
    function tokenURI(Claim memory claim, uint256 claimId, address creditor) external pure returns (string memory);
}
