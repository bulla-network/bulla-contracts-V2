// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.14;

import "forge-std/Script.sol";
import "contracts/BullaClaim.sol";
import "contracts/BullaFeeCalculator.sol";
import "contracts/BullaExtensionRegistry.sol";

contract Deployer is Script {
    BullaClaim bullaClaim;
    BullaExtensionRegistry extensionRegistry;
    BullaFeeCalculator feeCalculator;

    function run() public {
        // load fee receiver + lock state from the bash environment
        address feeReceiver = vm.envAddress("FEE_RECEIVER");
        LockState initialLockState = LockState(vm.envUint("LOCK_STATE"));

        vm.startBroadcast();
        _deploy(feeReceiver, initialLockState);
        vm.stopBroadcast();
    }

    function deploy_test(address _deployer, address _feeReceiver, LockState _initialLockState, uint256 _feeBPS)
        public
        returns (BullaClaim, BullaFeeCalculator)
    {
        vm.startPrank(_deployer);
        _deploy(_feeReceiver, _initialLockState);
        feeCalculator = new BullaFeeCalculator(_feeBPS);

        vm.stopPrank();

        return (bullaClaim, feeCalculator);
    }

    function _deploy(address _feeReceiver, LockState _initialLockState) internal {
        extensionRegistry = new BullaExtensionRegistry();
        bullaClaim = new BullaClaim(_feeReceiver, address(extensionRegistry), _initialLockState);
    }
}
