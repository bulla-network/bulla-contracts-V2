// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

interface IBullaControllerRegistry {
    /*///////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function getControllerName(address controllerAddress) external view returns (string memory);

    function DEFAULT_CONTROLLER_NAME() external view returns (string memory);

    /*///////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function setControllerName(address controller, string calldata name) external;
}
