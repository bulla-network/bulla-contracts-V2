#!/usr/bin/env node

const { spawn } = require("child_process");
const readline = require("readline");
const fs = require("fs");
const path = require("path");

// Function to prompt for private key
function promptForPrivateKey() {
  return new Promise((resolve) => {
    const rl = readline.createInterface({
      input: process.stdin,
      output: process.stdout,
    });

    console.log(
      "⚠️  WARNING: Your private key input will be visible on screen."
    );
    console.log("🔒 Make sure no one is watching your screen!\n");

    rl.question("Enter your private key: ", (privateKey) => {
      rl.close();
      // Clear the screen to hide the private key
      console.clear();
      resolve(privateKey.trim());
    });
  });
}

// Function to load deployment addresses from JSON file
function loadDeploymentAddresses(network) {
  try {
    const deploymentFile = path.join(
      __dirname,
      "..",
      "deployments",
      `${network}-latest.json`
    );

    if (fs.existsSync(deploymentFile)) {
      const deployment = JSON.parse(fs.readFileSync(deploymentFile, "utf8"));
      return {
        bullaClaimV2: deployment.bullaClaimV2,
        approvalRegistry: deployment.approvalRegistry,
        controllerRegistry: deployment.controllerRegistry,
        adminAddress: deployment.adminAddress,
      };
    }
  } catch (error) {
    console.warn(
      `⚠️  Could not load deployment addresses from file: ${error.message}`
    );
  }
  return null;
}

// Function to prompt for configuration
async function promptForConfig(network, existingDeployment) {
  const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
  });

  const question = (query) =>
    new Promise((resolve) => rl.question(query, resolve));

  console.log("\n📋 Configuration Setup");
  console.log("══════════════════════\n");

  // BullaClaim address (required)
  let bullaClaimAddress =
    process.env.BULLA_CLAIM_ADDRESS ||
    (existingDeployment && existingDeployment.bullaClaimV2) ||
    "";
  if (!bullaClaimAddress) {
    bullaClaimAddress = await question("BullaClaim address (required): ");
  } else {
    console.log(`BullaClaim address: ${bullaClaimAddress}`);
  }

  // Admin address (optional)
  let adminAddress =
    process.env.ADMIN_ADDRESS ||
    (existingDeployment && existingDeployment.adminAddress) ||
    "";
  if (!adminAddress) {
    const adminInput = await question(
      "Admin address (press Enter to use deployer): "
    );
    adminAddress = adminInput.trim() || "";
  } else {
    console.log(`Admin address: ${adminAddress || "deployer"}`);
  }

  // ControllerRegistry address (optional)
  let controllerRegistryAddress =
    process.env.CONTROLLER_REGISTRY_ADDRESS ||
    (existingDeployment && existingDeployment.controllerRegistry) ||
    "";
  if (!controllerRegistryAddress) {
    const controllerInput = await question(
      "ControllerRegistry address (press Enter to skip registration): "
    );
    controllerRegistryAddress = controllerInput.trim() || "";
  } else {
    console.log(
      `ControllerRegistry address: ${controllerRegistryAddress || "none"}`
    );
  }

  // Protocol fee (optional)
  let protocolFeeBPS = process.env.FRENDLEND_PROTOCOL_FEE_BPS || "0";
  if (!process.env.FRENDLEND_PROTOCOL_FEE_BPS) {
    const protocolFeeInput = await question(
      "Protocol fee BPS (press Enter for 0): "
    );
    protocolFeeBPS = protocolFeeInput.trim() || "0";
  } else {
    console.log(`Protocol fee: ${protocolFeeBPS} BPS`);
  }

  // Processing fee (optional)
  let processingFeeBPS = process.env.FRENDLEND_PROCESSING_FEE_BPS || "0";
  if (!process.env.FRENDLEND_PROCESSING_FEE_BPS) {
    const processingFeeInput = await question(
      "Processing fee BPS (press Enter for 0): "
    );
    processingFeeBPS = processingFeeInput.trim() || "0";
  } else {
    console.log(`Processing fee: ${processingFeeBPS} BPS`);
  }

  rl.close();

  return {
    bullaClaimAddress,
    adminAddress,
    controllerRegistryAddress,
    protocolFeeBPS,
    processingFeeBPS,
  };
}

async function deployFrendLend() {
  try {
    // Get network from environment variable
    const network = process.env.NETWORK;

    if (!network) {
      console.error("❌ NETWORK environment variable is required");
      console.error("   Set NETWORK in your .env file or use:");
      console.error(
        "   dotenv -e .env -- cross-env NETWORK=sepolia node script/deploy-frendlend.js"
      );
      console.error("\nAvailable networks:");
      console.error("   - sepolia");
      console.error("   - base");
      console.error("   - base-sepolia");
      process.exit(1);
    }

    console.log(`🚀 Deploying BullaFrendLendV2 to ${network} network...\n`);

    // Try to load existing deployment addresses
    const existingDeployment = loadDeploymentAddresses(network);
    if (existingDeployment) {
      console.log("✅ Found existing deployment configuration");
    }

    // Get configuration
    const config = await promptForConfig(network, existingDeployment);

    // Validate required fields
    if (!config.bullaClaimAddress) {
      console.error("❌ BullaClaim address is required");
      process.exit(1);
    }

    // Display final configuration
    console.log("\n📝 Deployment Configuration:");
    console.log("═══════════════════════════");
    console.log(`Network: ${network}`);
    console.log(`BullaClaim: ${config.bullaClaimAddress}`);
    console.log(`Admin: ${config.adminAddress || "deployer"}`);
    console.log(`Protocol Fee: ${config.protocolFeeBPS} BPS`);
    console.log(`Processing Fee: ${config.processingFeeBPS} BPS`);
    console.log(
      `ControllerRegistry: ${config.controllerRegistryAddress || "not set"}`
    );
    console.log("");

    // Prompt for private key
    const privateKey = await promptForPrivateKey();

    if (!privateKey) {
      console.error("❌ Private key is required");
      process.exit(1);
    }

    // Validate private key format (basic check)
    if (!privateKey.match(/^(0x)?[a-fA-F0-9]{64}$/)) {
      console.error(
        "❌ Invalid private key format. Should be 64 hex characters (with or without 0x prefix)"
      );
      process.exit(1);
    }

    // Ensure 0x prefix
    const formattedPrivateKey = privateKey.startsWith("0x")
      ? privateKey
      : `0x${privateKey}`;

    console.log(`📡 Starting deployment to ${network}...\n`);

    // Prepare the forge command
    const forgeArgs = [
      "script",
      "script/DeployFrendLend.s.sol:DeployFrendLend",
      "--rpc-url",
      network,
      "--broadcast",
      "--verify",
      "--private-key",
      formattedPrivateKey,
    ];

    // Set environment variables
    const env = {
      ...process.env,
      NETWORK: network,
      PRIVATE_KEY: formattedPrivateKey,
      BULLA_CLAIM_ADDRESS: config.bullaClaimAddress,
      FRENDLEND_PROTOCOL_FEE_BPS: config.protocolFeeBPS,
      FRENDLEND_PROCESSING_FEE_BPS: config.processingFeeBPS,
    };

    // Add optional addresses if provided
    if (config.adminAddress) {
      env.ADMIN_ADDRESS = config.adminAddress;
    }
    if (config.controllerRegistryAddress) {
      env.CONTROLLER_REGISTRY_ADDRESS = config.controllerRegistryAddress;
    }

    console.log("🔧 Running forge script...");
    console.log(`📄 Script: DeployFrendLend.s.sol`);
    console.log(`🌐 Network: ${network}`);
    console.log(`🚀 Broadcasting: Yes`);
    console.log(`✅ Verification: Enabled\n`);

    // Spawn the forge process
    const forgeProcess = spawn("forge", forgeArgs, {
      env,
      stdio: "inherit",
    });

    forgeProcess.on("close", (code) => {
      if (code === 0) {
        console.log("\n✅ Deployment completed successfully!");
        console.log("🎉 BullaFrendLendV2 is now live!");
        console.log(
          `\n📁 Deployment data saved to: deployments/frendlend-${network}-latest.json`
        );
      } else {
        console.error(`\n❌ Deployment failed with exit code ${code}`);
        process.exit(code);
      }
    });

    forgeProcess.on("error", (error) => {
      if (error.code === "ENOENT") {
        console.error(
          "❌ Forge not found. Make sure Foundry is installed and in your PATH."
        );
        console.error("   Install from: https://getfoundry.sh/");
      } else {
        console.error("❌ Failed to start forge:", error.message);
      }
      process.exit(1);
    });
  } catch (error) {
    console.error("❌ Deployment error:", error.message);
    process.exit(1);
  }
}

// Handle Ctrl+C gracefully
process.on("SIGINT", () => {
  console.log("\n\n⚠️  Deployment interrupted by user");
  process.exit(0);
});

// Run the deployment
deployFrendLend();
