// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import "forge-std/console.sol";

contract VerifyContracts is Script {
    struct VerificationConfig {
        address bullaClaim;
        address bullaInvoice;
        address bullaFrendLend;
        address controllerRegistry;
        address whitelistPermissions;
        address approvalRegistry;
        string network;
        // Constructor args
        uint256 lockState;
        uint256 coreProtocolFee;
        address adminAddress;
        uint256 invoiceProtocolFeeBPS;
        uint256 frendLendProtocolFeeBPS;
    }

    function run() public {
        console.log("=== Starting Contract Verification ===");

        VerificationConfig memory config = _loadConfig();
        _validateConfig(config);
        _verifyAllContracts(config);

        console.log("=== Verification Complete ===");
    }

    function _loadConfig() internal returns (VerificationConfig memory) {
        return VerificationConfig({
            bullaClaim: vm.envAddress("BULLA_CLAIM_ADDRESS"),
            bullaInvoice: vm.envAddress("BULLA_INVOICE_ADDRESS"),
            bullaFrendLend: vm.envAddress("BULLA_FRENDLEND_ADDRESS"),
            controllerRegistry: vm.envAddress("CONTROLLER_REGISTRY_ADDRESS"),
            whitelistPermissions: vm.envAddress("WHITELIST_PERMISSIONS_ADDRESS"),
            approvalRegistry: vm.envAddress("APPROVAL_REGISTRY_ADDRESS"),
            network: vm.envString("NETWORK"),
            lockState: vm.envOr("LOCK_STATE", uint256(0)),
            coreProtocolFee: vm.envOr("CORE_PROTOCOL_FEE", uint256(0)),
            adminAddress: vm.envOr("ADMIN_ADDRESS", msg.sender),
            invoiceProtocolFeeBPS: vm.envOr("INVOICE_PROTOCOL_FEE_BPS", uint256(0)),
            frendLendProtocolFeeBPS: vm.envOr("FRENDLEND_PROTOCOL_FEE_BPS", uint256(0))
        });
    }

    function _validateConfig(VerificationConfig memory config) internal pure {
        require(config.bullaClaim != address(0), "BULLA_CLAIM_ADDRESS not set");
        require(config.bullaInvoice != address(0), "BULLA_INVOICE_ADDRESS not set");
        require(config.bullaFrendLend != address(0), "BULLA_FRENDLEND_ADDRESS not set");
        require(config.controllerRegistry != address(0), "CONTROLLER_REGISTRY_ADDRESS not set");
        require(config.whitelistPermissions != address(0), "WHITELIST_PERMISSIONS_ADDRESS not set");
        require(config.approvalRegistry != address(0), "APPROVAL_REGISTRY_ADDRESS not set");
        require(bytes(config.network).length > 0, "NETWORK not set");
    }

    function _verifyAllContracts(VerificationConfig memory config) internal {
        console.log("Network:", config.network);
        console.log("");

        _verifyBullaControllerRegistry(config);
        _verifyWhitelistPermissions(config);
        _verifyBullaApprovalRegistry(config);
        _verifyBullaClaim(config);
        _verifyBullaInvoice(config);
        _verifyBullaFrendLend(config);
    }

    function _verifyBullaControllerRegistry(VerificationConfig memory config) internal {
        console.log("Verifying BullaControllerRegistry...");

        string[] memory args = new string[](4);
        args[0] = "forge";
        args[1] = "verify-contract";
        args[2] = vm.toString(config.controllerRegistry);
        args[3] = string.concat("src/BullaControllerRegistry.sol:BullaControllerRegistry --chain ", config.network);

        _executeVerification("BullaControllerRegistry", args);
    }

    function _verifyWhitelistPermissions(VerificationConfig memory config) internal {
        console.log("Verifying WhitelistPermissions...");

        string[] memory args = new string[](4);
        args[0] = "forge";
        args[1] = "verify-contract";
        args[2] = vm.toString(config.whitelistPermissions);
        args[3] = string.concat("src/WhitelistPermissions.sol:WhitelistPermissions --chain ", config.network);

        _executeVerification("WhitelistPermissions", args);
    }

    function _verifyBullaApprovalRegistry(VerificationConfig memory config) internal {
        console.log("Verifying BullaApprovalRegistry...");

        // Encode constructor args
        bytes memory constructorArgs = abi.encode(config.controllerRegistry);
        string memory encodedArgs = vm.toString(constructorArgs);

        string[] memory args = new string[](6);
        args[0] = "forge";
        args[1] = "verify-contract";
        args[2] = vm.toString(config.approvalRegistry);
        args[3] = string.concat("src/BullaApprovalRegistry.sol:BullaApprovalRegistry --chain ", config.network);
        args[4] = "--constructor-args";
        args[5] = encodedArgs;

        _executeVerification("BullaApprovalRegistry", args);
    }

    function _verifyBullaClaim(VerificationConfig memory config) internal {
        console.log("Verifying BullaClaimV2...");

        // Encode constructor args: (address,uint8,uint256,address)
        bytes memory constructorArgs = abi.encode(
            config.approvalRegistry, uint8(config.lockState), config.coreProtocolFee, config.whitelistPermissions
        );
        string memory encodedArgs = vm.toString(constructorArgs);

        string[] memory args = new string[](6);
        args[0] = "forge";
        args[1] = "verify-contract";
        args[2] = vm.toString(config.bullaClaim);
        args[3] = string.concat("src/BullaClaimV2.sol:BullaClaimV2 --chain ", config.network);
        args[4] = "--constructor-args";
        args[5] = encodedArgs;

        _executeVerification("BullaClaimV2", args);
    }

    function _verifyBullaInvoice(VerificationConfig memory config) internal {
        console.log("Verifying BullaInvoice...");

        // Encode constructor args: (address,address,uint16)
        bytes memory constructorArgs =
            abi.encode(config.bullaClaim, config.adminAddress, uint16(config.invoiceProtocolFeeBPS));
        string memory encodedArgs = vm.toString(constructorArgs);

        string[] memory args = new string[](6);
        args[0] = "forge";
        args[1] = "verify-contract";
        args[2] = vm.toString(config.bullaInvoice);
        args[3] = string.concat("src/BullaInvoice.sol:BullaInvoice --chain ", config.network);
        args[4] = "--constructor-args";
        args[5] = encodedArgs;

        _executeVerification("BullaInvoice", args);
    }

    function _verifyBullaFrendLend(VerificationConfig memory config) internal {
        console.log("Verifying BullaFrendLendV2...");

        // Encode constructor args: (address,address,uint16)
        bytes memory constructorArgs =
            abi.encode(config.bullaClaim, config.adminAddress, uint16(config.frendLendProtocolFeeBPS));
        string memory encodedArgs = vm.toString(constructorArgs);

        string[] memory args = new string[](6);
        args[0] = "forge";
        args[1] = "verify-contract";
        args[2] = vm.toString(config.bullaFrendLend);
        args[3] = string.concat("src/BullaFrendLendV2.sol:BullaFrendLendV2 --chain ", config.network);
        args[4] = "--constructor-args";
        args[5] = encodedArgs;

        _executeVerification("BullaFrendLendV2", args);
    }

    function _executeVerification(string memory contractName, string[] memory args) internal {
        console.log("Executing verification for", contractName);

        // Print the command that would be executed
        string memory command = "";
        for (uint256 i = 0; i < args.length; i++) {
            command = string.concat(command, args[i], " ");
        }
        console.log("Command:", command);

        console.log("Note: Execute the above command manually or use the deployment script's output");
        console.log("");
    }

    // Helper function to verify a single contract by address
    function verifySingleContract(
        address contractAddress,
        string memory contractPath,
        bytes memory constructorArgs,
        string memory network
    ) external view {
        console.log("Manual verification command for contract at:", contractAddress);
        console.log("Contract path:", contractPath);
        console.log("Network:", network);
        console.log("Constructor args (hex):", vm.toString(constructorArgs));
        console.log("");

        if (constructorArgs.length > 0) {
            console.log("Verification command:");
            console.log("Contract address:", contractAddress);
            console.log("Contract path:", contractPath);
            console.log("Network:", network);
            console.log("Constructor args:", vm.toString(constructorArgs));
        } else {
            console.log("Verification command:");
            console.log("Contract address:", contractAddress);
            console.log("Contract path:", contractPath);
            console.log("Network:", network);
        }
    }
}
