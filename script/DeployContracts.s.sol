// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {BullaClaim} from "contracts/BullaClaim.sol";
import {BullaInvoice} from "contracts/BullaInvoice.sol";
import {BullaFrendLend} from "contracts/BullaFrendLend.sol";
import "contracts/BullaControllerRegistry.sol";
import "contracts/WhitelistPermissions.sol";
import "contracts/BullaApprovalRegistry.sol";
import "contracts/interfaces/IBullaApprovalRegistry.sol";
import "contracts/types/Types.sol";

contract DeployContracts is Script {
    // Deployment configuration
    struct DeploymentConfig {
        LockState initialLockState;
        uint256 coreProtocolFee;
        uint16 invoiceProtocolFeeBPS;
        uint16 frendLendProtocolFeeBPS;
        address admin;
    }

    // Deployed contracts
    BullaClaim public bullaClaim;
    BullaInvoice public bullaInvoice;
    BullaFrendLend public bullaFrendLend;
    BullaControllerRegistry public controllerRegistry;
    WhitelistPermissions public whitelistPermissions;
    BullaApprovalRegistry public approvalRegistry;

    // Deployment results for verification
    struct DeploymentResult {
        address bullaClaim;
        address bullaInvoice;
        address bullaFrendLend;
        address controllerRegistry;
        address whitelistPermissions;
        address approvalRegistry;
    }

    function run() public returns (DeploymentResult memory) {
        console.log("=== Starting Bulla Contracts V2 Deployment ===");
        console.log("Deployer:", msg.sender);
        console.log("Chain ID:", block.chainid);
        console.log("");

        // Load configuration from environment variables
        DeploymentConfig memory config = _loadConfig();
        _logConfig(config);

        vm.startBroadcast();

        DeploymentResult memory result = _deployAll(config);

        vm.stopBroadcast();

        _logDeploymentResults(result);
        _verifyContracts(result, config);
        _saveDeploymentToJson(result, config);

        return result;
    }

    function _loadConfig() internal returns (DeploymentConfig memory) {
        return DeploymentConfig({
            initialLockState: LockState(vm.envOr("LOCK_STATE", uint256(0))),
            coreProtocolFee: vm.envOr("CORE_PROTOCOL_FEE", uint256(0)),
            invoiceProtocolFeeBPS: uint16(vm.envOr("INVOICE_PROTOCOL_FEE_BPS", uint256(0))),
            frendLendProtocolFeeBPS: uint16(vm.envOr("FRENDLEND_PROTOCOL_FEE_BPS", uint256(0))),
            admin: vm.envOr("ADMIN_ADDRESS", msg.sender)
        });
    }

    function _logConfig(DeploymentConfig memory config) internal view {
        console.log("=== Deployment Configuration ===");
        console.log("Initial Lock State:", uint256(config.initialLockState));
        console.log("Core Protocol Fee:", config.coreProtocolFee);
        console.log("Invoice Protocol Fee BPS:", config.invoiceProtocolFeeBPS);
        console.log("FrendLend Protocol Fee BPS:", config.frendLendProtocolFeeBPS);
        console.log("Admin Address:", config.admin);
        console.log("");
    }

    function _deployAll(DeploymentConfig memory config) internal returns (DeploymentResult memory) {
        // Deploy dependencies first
        _deployDependencies();

        // Deploy main contracts
        _deployMainContracts(config);

        // Setup authorizations
        _setupAuthorizations();

        return DeploymentResult({
            bullaClaim: address(bullaClaim),
            bullaInvoice: address(bullaInvoice),
            bullaFrendLend: address(bullaFrendLend),
            controllerRegistry: address(controllerRegistry),
            whitelistPermissions: address(whitelistPermissions),
            approvalRegistry: address(approvalRegistry)
        });
    }

    function _deployDependencies() internal {
        console.log("=== Deploying Dependencies ===");

        // Deploy BullaControllerRegistry
        console.log("Deploying BullaControllerRegistry...");
        controllerRegistry = new BullaControllerRegistry();
        console.log("BullaControllerRegistry deployed at:", address(controllerRegistry));

        // Deploy WhitelistPermissions
        console.log("Deploying WhitelistPermissions...");
        whitelistPermissions = new WhitelistPermissions();
        console.log("WhitelistPermissions deployed at:", address(whitelistPermissions));

        // Deploy BullaApprovalRegistry
        console.log("Deploying BullaApprovalRegistry...");
        approvalRegistry = new BullaApprovalRegistry(address(controllerRegistry));
        console.log("BullaApprovalRegistry deployed at:", address(approvalRegistry));

        console.log("");
    }

    function _deployMainContracts(DeploymentConfig memory config) internal {
        console.log("=== Deploying Main Contracts ===");

        // Deploy BullaClaim
        console.log("Deploying BullaClaim...");
        bullaClaim = new BullaClaim(
            address(approvalRegistry), config.initialLockState, config.coreProtocolFee, address(whitelistPermissions)
        );
        console.log("BullaClaim deployed at:", address(bullaClaim));

        console.log("Authorizing BullaClaim in ApprovalRegistry...");
        approvalRegistry.setAuthorizedContract(address(bullaClaim), true);
        console.log("BullaClaim authorized in ApprovalRegistry");

        // Deploy BullaInvoice
        console.log("Deploying BullaInvoice...");
        bullaInvoice = new BullaInvoice(address(bullaClaim), config.admin, config.invoiceProtocolFeeBPS);
        console.log("BullaInvoice deployed at:", address(bullaInvoice));

        // Deploy BullaFrendLend
        console.log("Deploying BullaFrendLend...");
        bullaFrendLend = new BullaFrendLend(address(bullaClaim), config.admin, config.frendLendProtocolFeeBPS);
        console.log("BullaFrendLend deployed at:", address(bullaFrendLend));

        console.log("");
    }

    function _setupAuthorizations() internal {
        console.log("=== Setting up Authorizations ===");

        // Authorize BullaInvoice to create claims
        console.log("Authorizing BullaInvoice in ApprovalRegistry...");
        approvalRegistry.setAuthorizedContract(address(bullaInvoice), true);

        // Authorize BullaFrendLend to create claims
        console.log("Authorizing BullaFrendLend in ApprovalRegistry...");
        approvalRegistry.setAuthorizedContract(address(bullaFrendLend), true);

        // Register controllers in the registry with descriptive names
        console.log("Registering controllers in ControllerRegistry...");
        controllerRegistry.setControllerName(address(bullaInvoice), "BullaInvoice");
        controllerRegistry.setControllerName(address(bullaFrendLend), "BullaFrendLend");

        console.log("Authorizations setup complete!");
        console.log("");
    }

    function _logDeploymentResults(DeploymentResult memory result) internal view {
        console.log("=== Deployment Complete ===");
        console.log("BullaClaim:", result.bullaClaim);
        console.log("BullaInvoice:", result.bullaInvoice);
        console.log("BullaFrendLend:", result.bullaFrendLend);
        console.log("BullaControllerRegistry:", result.controllerRegistry);
        console.log("WhitelistPermissions:", result.whitelistPermissions);
        console.log("BullaApprovalRegistry:", result.approvalRegistry);
        console.log("");
    }

    function _saveDeploymentToJson(DeploymentResult memory result, DeploymentConfig memory config) internal {
        string memory networkName = vm.envOr("NETWORK", string("sepolia"));

        // Create deployment info JSON structure
        string memory json = "deployment";

        // Add metadata
        vm.serializeAddress(json, "deployer", msg.sender);
        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeUint(json, "blockNumber", block.number);
        vm.serializeUint(json, "timestamp", block.timestamp);
        vm.serializeString(json, "network", networkName);

        // Add configuration used
        vm.serializeUint(json, "lockState", uint256(config.initialLockState));
        vm.serializeUint(json, "coreProtocolFee", config.coreProtocolFee);
        vm.serializeUint(json, "invoiceProtocolFeeBPS", config.invoiceProtocolFeeBPS);
        vm.serializeUint(json, "frendLendProtocolFeeBPS", config.frendLendProtocolFeeBPS);
        vm.serializeAddress(json, "adminAddress", config.admin);

        // Add contract addresses
        vm.serializeAddress(json, "bullaClaim", result.bullaClaim);
        vm.serializeAddress(json, "bullaInvoice", result.bullaInvoice);
        vm.serializeAddress(json, "bullaFrendLend", result.bullaFrendLend);
        vm.serializeAddress(json, "controllerRegistry", result.controllerRegistry);
        vm.serializeAddress(json, "whitelistPermissions", result.whitelistPermissions);
        string memory finalJson = vm.serializeAddress(json, "approvalRegistry", result.approvalRegistry);

        // Create filename with timestamp and network
        string memory filename = string.concat("deployments/", networkName, "-", vm.toString(block.timestamp), ".json");

        // Write JSON to file
        vm.writeFile(filename, finalJson);

        console.log("=== Deployment Saved ===");
        console.log("Deployment info saved to:", filename);
        console.log("");

        // Also create/update a latest deployment file for easy access
        string memory latestFilename = string.concat("deployments/", networkName, "-latest.json");
        vm.writeFile(latestFilename, finalJson);
        console.log("Latest deployment updated:", latestFilename);
        console.log("");
    }

    function _verifyContracts(DeploymentResult memory result, DeploymentConfig memory config) internal {
        string memory networkName = vm.envOr("NETWORK", string(""));
        if (bytes(networkName).length == 0) {
            console.log("=== Skipping Verification ===");
            console.log("NETWORK environment variable not set. Skipping automatic verification.");
            console.log("Run verification manually using the commands below:");
            _printVerificationCommands(result);
            return;
        }

        console.log("=== Starting Automatic Verification ===");
        console.log("Network:", networkName);
        console.log("");

        // Verify each contract
        _verifyContract(
            "BullaControllerRegistry",
            result.controllerRegistry,
            "src/BullaControllerRegistry.sol:BullaControllerRegistry",
            "",
            networkName
        );

        _verifyContract(
            "WhitelistPermissions",
            result.whitelistPermissions,
            "src/WhitelistPermissions.sol:WhitelistPermissions",
            "",
            networkName
        );

        _verifyContract(
            "BullaApprovalRegistry",
            result.approvalRegistry,
            "src/BullaApprovalRegistry.sol:BullaApprovalRegistry",
            _encodeConstructorArgs(abi.encode(result.controllerRegistry)),
            networkName
        );

        _verifyContract(
            "BullaClaim",
            result.bullaClaim,
            "src/BullaClaim.sol:BullaClaim",
            _encodeConstructorArgs(
                abi.encode(
                    result.approvalRegistry,
                    uint8(config.initialLockState),
                    config.coreProtocolFee,
                    result.whitelistPermissions
                )
            ),
            networkName
        );

        _verifyContract(
            "BullaInvoice",
            result.bullaInvoice,
            "src/BullaInvoice.sol:BullaInvoice",
            _encodeConstructorArgs(abi.encode(result.bullaClaim, config.admin, config.invoiceProtocolFeeBPS)),
            networkName
        );

        _verifyContract(
            "BullaFrendLend",
            result.bullaFrendLend,
            "src/BullaFrendLend.sol:BullaFrendLend",
            _encodeConstructorArgs(abi.encode(result.bullaClaim, config.admin, config.frendLendProtocolFeeBPS)),
            networkName
        );

        console.log("=== Verification Complete ===");
        console.log("");
    }

    function _verifyContract(
        string memory contractName,
        address contractAddress,
        string memory contractPath,
        string memory constructorArgs,
        string memory network
    ) internal {
        console.log("Verifying", contractName, "at", contractAddress);

        string[] memory cmd = new string[](bytes(constructorArgs).length > 0 ? 7 : 5);
        cmd[0] = "forge";
        cmd[1] = "verify-contract";
        cmd[2] = vm.toString(contractAddress);
        cmd[3] = contractPath;
        cmd[4] = string.concat("--chain=", network);

        if (bytes(constructorArgs).length > 0) {
            cmd[5] = "--constructor-args";
            cmd[6] = constructorArgs;
        }

        try vm.ffi(cmd) {
            console.log("[SUCCESS]", contractName, "verified successfully");
        } catch {
            console.log("[FAILED]", contractName, "verification failed");
            console.log("Manual command:");
            string memory command = "";
            for (uint256 i = 0; i < cmd.length; i++) {
                command = string.concat(command, cmd[i], " ");
            }
            console.log(command);
        }
        console.log("");
    }

    function _encodeConstructorArgs(bytes memory args) internal pure returns (string memory) {
        return vm.toString(args);
    }

    function _printVerificationCommands(DeploymentResult memory result) internal {
        string memory networkName = vm.envOr("NETWORK", string(""));
        if (bytes(networkName).length == 0) {
            console.log("=== Manual Verification Commands ===");
            console.log("Set NETWORK environment variable to generate verification commands");
            return;
        }

        console.log("=== Manual Verification Commands (if needed) ===");
        console.log("If automatic verification failed, run these commands manually:");
        console.log("");

        // BullaControllerRegistry (no constructor args)
        console.log("BullaControllerRegistry verification:");
        console.log(result.controllerRegistry);

        // WhitelistPermissions (no constructor args)
        console.log("WhitelistPermissions verification:");
        console.log(result.whitelistPermissions);

        // BullaApprovalRegistry
        console.log("BullaApprovalRegistry verification:");
        console.log(result.approvalRegistry);

        // BullaClaim
        console.log("BullaClaim verification:");
        console.log(result.bullaClaim);

        // BullaInvoice
        console.log("BullaInvoice verification:");
        console.log(result.bullaInvoice);

        // BullaFrendLend
        console.log("BullaFrendLend verification:");
        console.log(result.bullaFrendLend);

        console.log("");
    }

    // Test helper function for integration tests
    function deployForTest(
        address deployer,
        LockState initialLockState,
        uint256 coreProtocolFee,
        uint16 invoiceProtocolFeeBPS,
        uint16 frendLendProtocolFeeBPS,
        address admin
    ) public returns (DeploymentResult memory) {
        vm.startPrank(deployer);

        DeploymentConfig memory config = DeploymentConfig({
            initialLockState: initialLockState,
            coreProtocolFee: coreProtocolFee,
            invoiceProtocolFeeBPS: invoiceProtocolFeeBPS,
            frendLendProtocolFeeBPS: frendLendProtocolFeeBPS,
            admin: admin
        });

        DeploymentResult memory result = _deployAll(config);

        vm.stopPrank();

        return result;
    }
}
