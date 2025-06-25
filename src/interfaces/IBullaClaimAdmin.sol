// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import "../types/Types.sol";
import {IPermissions} from "./IPermissions.sol";

interface IBullaClaimAdmin {
    /*///////////////////////////////////////////////////////////////
                            EVENTS
    //////////////////////////////////////////////////////////////*/

    event FeeWithdrawn(address indexed owner, uint256 amount);

    /*///////////////////////////////////////////////////////////////
                        VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function owner() external view returns (address);

    function feeExemptions() external view returns (IPermissions);

    /*///////////////////////////////////////////////////////////////
                        ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function setLockState(LockState _lockState) external;

    function setCoreProtocolFee(uint256 _coreProtocolFee) external;

    function setFeeExemptions(address _feeExemptions) external;

    function withdrawAllFees() external;
}
