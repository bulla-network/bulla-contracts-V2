// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {Claim, Status} from "./types/Types.sol";
import {Base64} from "./libraries/Base64.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

/// @notice a barebones on-chain svg generator showing a claim's status
contract ClaimMetadataGenerator {
    function getStatusText(Status status) internal pure returns (string memory) {
        if (status == Status.Pending) {
            return "Pending";
        } else if (status == Status.Repaying) {
            return "Repaying";
        } else if (status == Status.Paid) {
            return "Paid";
        } else if (status == Status.Rejected) {
            return "Rejected";
        } else if (status == Status.Rescinded) {
            return "Rescinded";
        } else if (status == Status.Impaired) {
            return "Impaired";
        } else {
            return "";
        }
    }

    function getImage(Claim memory claim, uint256 claimId, address creditor) internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                '<svg class="svgBody"width="300"height="300"viewBox="0 0 300 300"xmlns="http://www.w3.org/2000/svg">',
                '<text x="15" y="15" class="medium">BULLA CLAIM #',
                claimId,
                "</text>",
                '<text x="15" y="45" class="medium">Creditor: ',
                creditor,
                "</text>",
                '<text x="15" y="75" class="medium">Debtor: ',
                claim.debtor,
                "</text>",
                '<text x="15" y="135" class="medium">Status ',
                getStatusText(claim.status),
                "</text>",
                '<style>.svgBody {font-family: "Courier New";}.tiny {font-size: 6px;}.small {font-size: 12px;}.medium {font-size: 18px;}</style>',
                "</svg>"
            )
        );
    }

    function tokenURI(Claim memory claim, uint256 claimId, address creditor) public pure returns (string memory) {
        string memory image = Base64.encode(bytes(getImage(claim, claimId, creditor)));

        return string(
            abi.encodePacked(
                "data:application/json;base64,",
                Base64.encode(
                    bytes(
                        abi.encodePacked(
                            '{"name":"Bulla Claim #',
                            claimId,
                            '", "description":"A claim between',
                            creditor,
                            " and ",
                            claim.debtor,
                            '", "image": "',
                            "data:image/svg+xml;base64,",
                            image,
                            '"}'
                        )
                    )
                )
            )
        );
    }
}
