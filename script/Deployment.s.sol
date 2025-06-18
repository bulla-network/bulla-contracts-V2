// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.14;

import "forge-std/Script.sol";
import "contracts/BullaClaim.sol";
import "contracts/BullaControllerRegistry.sol";
import "contracts/WhitelistPermissions.sol";

contract Deployer is Script {
    BullaClaim bullaClaim;
    BullaControllerRegistry controllerRegistry;
    uint256 coreProtocolFee;
    WhitelistPermissions whitelistPermissions;

    function run() public {
        // load fee receiver + lock state from the bash environment
        LockState initialLockState = LockState(vm.envUint("LOCK_STATE"));

        vm.startBroadcast();
        _deploy(initialLockState, 0);
        vm.stopBroadcast();
    }

    function deploy_test(address _deployer, LockState _initialLockState, uint256 _coreProtocolFee)
        public
        returns (BullaClaim)
    {
        vm.startPrank(_deployer);
        _deploy(_initialLockState, _coreProtocolFee);

        vm.stopPrank();

        return bullaClaim;
    }

    function _deploy(LockState _initialLockState, uint256 _coreProtocolFee) internal {
        controllerRegistry = new BullaControllerRegistry();
        whitelistPermissions = new WhitelistPermissions();
        bullaClaim = new BullaClaim(
            address(controllerRegistry), _initialLockState, _coreProtocolFee, address(whitelistPermissions)
        );
    }
}
