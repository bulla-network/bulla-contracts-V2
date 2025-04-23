// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.14;

import "forge-std/Script.sol";
import "contracts/BullaClaim.sol";
import "contracts/BullaExtensionRegistry.sol";

contract Deployer is Script {
    BullaClaim bullaClaim;
    BullaExtensionRegistry extensionRegistry;

    function run() public {
        // load fee receiver + lock state from the bash environment
        LockState initialLockState = LockState(vm.envUint("LOCK_STATE"));

        vm.startBroadcast();
        _deploy(initialLockState);
        vm.stopBroadcast();
    }

    function deploy_test(address _deployer, LockState _initialLockState)
        public
        returns (BullaClaim)
    {
        vm.startPrank(_deployer);
        _deploy(_initialLockState);

        vm.stopPrank();

        return bullaClaim;
    }

    function _deploy(LockState _initialLockState) internal {
        extensionRegistry = new BullaExtensionRegistry();
        bullaClaim = new BullaClaim(address(extensionRegistry), _initialLockState);
    }
}
