#!/usr/bin/env node

const { spawn } = require("child_process");
const readline = require("readline");

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

async function deployContracts() {
  try {
    // Get network from environment variable
    const network = process.env.NETWORK;

    if (!network) {
      console.error("❌ NETWORK environment variable is required");
      console.error("   Set NETWORK in your .env file or use:");
      console.error(
        "   dotenv -e .env -- cross-env NETWORK=sepolia node script/deploy.js"
      );
      process.exit(1);
    }

    console.log(`🚀 Deploying contracts to ${network} network...\n`);

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
      "script/DeployContracts.s.sol:DeployContracts",
      "--rpc-url",
      network,
      "--broadcast",
      "--private-key",
      formattedPrivateKey,
      "--ffi",
    ];

    // Set environment variables
    const env = {
      ...process.env,
      NETWORK: network,
      PRIVATE_KEY: formattedPrivateKey,
    };

    console.log("🔧 Running forge script...");
    console.log(`📄 Script: DeployContracts.s.sol`);
    console.log(`🌐 Network: ${network}`);
    console.log(`🚀 Broadcasting: Yes\n`);

    // Spawn the forge process
    const forgeProcess = spawn("forge", forgeArgs, {
      env,
      stdio: "inherit",
    });

    forgeProcess.on("close", (code) => {
      if (code === 0) {
        console.log("\n✅ Deployment completed successfully!");
        console.log("🎉 Your contracts are now live on Sepolia!");
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
deployContracts();
