// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {BullaFrendLendV2} from "contracts/BullaFrendLendV2.sol";
import {BullaClaimV2} from "contracts/BullaClaimV2.sol";
import {BullaControllerRegistry} from "contracts/BullaControllerRegistry.sol";
import {BullaApprovalRegistry} from "contracts/BullaApprovalRegistry.sol";

/// @title DeployFrendLend
/// @notice Script to deploy only BullaFrendLendV2 using existing BullaClaim deployment
/// @dev Reads existing deployment addresses and configuration from JSON or environment variables
contract DeployFrendLend is Script {
    // Deployment configuration
    struct FrendLendConfig {
        address bullaClaimAddress;
        address controllerRegistryAddress;
        address adminAddress;
        uint16 protocolFeeBPS;
        uint16 processingFeeBPS;
    }

    BullaFrendLendV2 public bullaFrendLend;

    function run() public returns (address) {
        console.log("=== Deploying BullaFrendLendV2 ===");
        console.log("Deployer:", msg.sender);
        console.log("Chain ID:", block.chainid);
        console.log("");

        // Load configuration from environment variables
        FrendLendConfig memory config = _loadConfig();
        _logConfig(config);

        // Validate configuration
        _validateConfig(config);

        vm.startBroadcast();

        // Deploy BullaFrendLendV2
        console.log("Deploying BullaFrendLendV2...");
        bullaFrendLend = new BullaFrendLendV2(
            config.bullaClaimAddress, config.adminAddress, config.protocolFeeBPS, config.processingFeeBPS
        );
        console.log("BullaFrendLendV2 deployed at:", address(bullaFrendLend));
        console.log("");

        // Register in ControllerRegistry if address provided
        if (config.controllerRegistryAddress != address(0)) {
            _setupControllerRegistryRegistration(config.controllerRegistryAddress);
        }

        vm.stopBroadcast();

        _logDeploymentSummary(config);
        _saveDeploymentToJson(config);

        return address(bullaFrendLend);
    }

    function _loadConfig() internal returns (FrendLendConfig memory) {
        // Required: BullaClaim address
        address bullaClaimAddress = vm.envOr("BULLA_CLAIM_ADDRESS", address(0));
        require(bullaClaimAddress != address(0), "BULLA_CLAIM_ADDRESS is required");

        // Optional: Admin address (defaults to deployer)
        address adminAddress = vm.envOr("ADMIN_ADDRESS", msg.sender);

        // Optional: Protocol fees (defaults to 0)
        uint16 protocolFeeBPS = uint16(vm.envOr("FRENDLEND_PROTOCOL_FEE_BPS", uint256(0)));
        uint16 processingFeeBPS = uint16(vm.envOr("FRENDLEND_PROCESSING_FEE_BPS", uint256(0)));

        // Optional: ControllerRegistry address for automatic registration
        address controllerRegistryAddress = vm.envOr("CONTROLLER_REGISTRY_ADDRESS", address(0));

        return FrendLendConfig({
            bullaClaimAddress: bullaClaimAddress,
            controllerRegistryAddress: controllerRegistryAddress,
            adminAddress: adminAddress,
            protocolFeeBPS: protocolFeeBPS,
            processingFeeBPS: processingFeeBPS
        });
    }

    function _validateConfig(FrendLendConfig memory config) internal view {
        console.log("=== Validating Configuration ===");

        // Check BullaClaim exists
        require(config.bullaClaimAddress.code.length > 0, "BullaClaim not deployed at provided address");
        console.log("BullaClaim verified at:", config.bullaClaimAddress);

        console.log("Configuration validation passed!");
        console.log("");
    }

    function _logConfig(FrendLendConfig memory config) internal view {
        console.log("=== Deployment Configuration ===");
        console.log("BullaClaim Address:", config.bullaClaimAddress);
        console.log("Admin Address:", config.adminAddress);
        console.log("Protocol Fee BPS:", config.protocolFeeBPS);
        console.log("Processing Fee BPS:", config.processingFeeBPS);

        if (config.controllerRegistryAddress != address(0)) {
            console.log("ControllerRegistry Address:", config.controllerRegistryAddress);
        } else {
            console.log("ControllerRegistry: Not provided (skip registration)");
        }
        console.log("");
    }

    function _setupControllerRegistryRegistration(address controllerRegistryAddress) internal {
        console.log("=== Registering in ControllerRegistry ===");

        BullaControllerRegistry controllerRegistry = BullaControllerRegistry(controllerRegistryAddress);

        console.log("Registering BullaFrendLendV2 in ControllerRegistry...");
        controllerRegistry.setControllerName(address(bullaFrendLend), "BullaFrendLendV2");
        console.log("BullaFrendLendV2 registered as 'BullaFrendLendV2'");
        console.log("");
    }

    function _logDeploymentSummary(FrendLendConfig memory config) internal view {
        console.log("=== Deployment Summary ===");
        console.log("Chain ID:", block.chainid);
        console.log("Block Number:", block.number);
        console.log("Deployer:", msg.sender);
        console.log("");
        console.log("Deployed Contracts:");
        console.log("  BullaFrendLendV2:", address(bullaFrendLend));
        console.log("");
        console.log("Configuration:");
        console.log("  BullaClaim:", config.bullaClaimAddress);
        console.log("  Admin:", config.adminAddress);
        console.log("  Protocol Fee:", config.protocolFeeBPS, "BPS");
        console.log("  Processing Fee:", config.processingFeeBPS, "BPS");
        console.log("");
    }

    function _saveDeploymentToJson(FrendLendConfig memory config) internal {
        string memory network = _getNetworkName();
        string memory timestamp = vm.toString(block.timestamp);
        string memory filename = string.concat("deployments/frendlend-", network, "-", timestamp, ".json");

        string memory json = "deployment";
        vm.serializeAddress(json, "bullaFrendLendV2", address(bullaFrendLend));
        vm.serializeAddress(json, "bullaClaimV2", config.bullaClaimAddress);
        vm.serializeAddress(json, "adminAddress", config.adminAddress);
        vm.serializeUint(json, "protocolFeeBPS", config.protocolFeeBPS);
        vm.serializeUint(json, "processingFeeBPS", config.processingFeeBPS);
        vm.serializeAddress(json, "deployer", msg.sender);
        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeUint(json, "blockNumber", block.number);
        vm.serializeUint(json, "timestamp", block.timestamp);
        string memory finalJson = vm.serializeString(json, "network", network);

        vm.writeJson(finalJson, filename);
        console.log("Deployment data saved to:", filename);

        // Also save as latest
        string memory latestFilename = string.concat("deployments/frendlend-", network, "-latest.json");
        vm.writeJson(finalJson, latestFilename);
        console.log("Deployment data saved to:", latestFilename);
    }

    function _getNetworkName() internal view returns (string memory) {
        uint256 chainId = block.chainid;

        if (chainId == 1) return "mainnet";
        if (chainId == 5) return "goerli";
        if (chainId == 11155111) return "sepolia";
        if (chainId == 8453) return "base";
        if (chainId == 84532) return "base-sepolia";
        if (chainId == 10) return "optimism";
        if (chainId == 42161) return "arbitrum";
        if (chainId == 137) return "polygon";
        if (chainId == 31337) return "localhost";

        return vm.toString(chainId);
    }
}
