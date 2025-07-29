#!/usr/bin/env node

// Load environment variables from .env file
require("dotenv").config();

const { spawn } = require("child_process");
const fs = require("fs");
const path = require("path");

// Network configuration
const NETWORK_CONFIG = {
  sepolia: {
    name: "sepolia",
    chainId: "11155111",
    explorerName: "Etherscan (Sepolia)",
    apiKey: process.env.ETHERSCAN_API_KEY,
  },
  mainnet: {
    name: "mainnet",
    chainId: "1",
    explorerName: "Etherscan (Mainnet)",
    apiKey: process.env.ETHERSCAN_API_KEY,
  },
  polygon: {
    name: "polygon",
    chainId: "137",
    explorerName: "PolygonScan",
    apiKey: process.env.POLYGONSCAN_API_KEY,
  },
  arbitrum: {
    name: "arbitrum",
    chainId: "42161",
    explorerName: "Arbiscan",
    apiKey: process.env.ARBISCAN_API_KEY,
  },
  optimism: {
    name: "optimism",
    chainId: "10",
    explorerName: "Optimistic Etherscan",
    apiKey: process.env.OPTIMISTIC_ETHERSCAN_API_KEY,
  },
};

// Map of all deployments we want to verify (libraries and contracts)
const DEPLOYMENTS_TO_VERIFY = [
  // Libraries (verify first as they're dependencies)
  "BullaClaimPermitLib",
  "CompoundInterestLib",
  "BullaClaimValidationLib",
  // Main contracts
  "BullaControllerRegistry",
  "WhitelistPermissions",
  "BullaApprovalRegistry",
  "BullaClaimV2",
  "BullaInvoice",
  "BullaFrendLendV2",
];

async function loadBroadcastArtifact(network) {
  const networkConfig = NETWORK_CONFIG[network];
  if (!networkConfig) {
    throw new Error(`Unsupported network: ${network}`);
  }

  const broadcastPath = path.join(
    "broadcast",
    "DeployContracts.s.sol",
    networkConfig.chainId,
    "run-latest.json"
  );

  if (!fs.existsSync(broadcastPath)) {
    throw new Error(
      `No broadcast artifact found for network: ${network}. File not found: ${broadcastPath}`
    );
  }

  const broadcastData = JSON.parse(fs.readFileSync(broadcastPath, "utf8"));
  console.log(
    `📄 Loaded broadcast artifact for ${network} (${broadcastData.transactions.length} transactions)`
  );
  return broadcastData;
}

function extractLibraryAddresses(broadcastData) {
  // Extract library addresses from broadcast artifacts
  const libraries = {};

  broadcastData.transactions.forEach((tx) => {
    if (
      (tx.transactionType === "CREATE" || tx.transactionType === "CREATE2") &&
      tx.contractName &&
      tx.contractName.endsWith("Lib")
    ) {
      libraries[tx.contractName] = tx.contractAddress.toLowerCase();
    }
  });

  console.log(
    `📚 Found ${Object.keys(libraries).length} libraries:`,
    libraries
  );
  return libraries;
}

function findContractDeployment(broadcastData, contractName) {
  // Find the deployment transaction for this contract
  const deployment = broadcastData.transactions.find(
    (tx) =>
      tx.contractName === contractName &&
      (tx.transactionType === "CREATE" || tx.transactionType === "CREATE2")
  );

  if (!deployment) {
    console.log(`⚠️  No deployment transaction found for ${contractName}`);
    return null;
  }

  return {
    contractAddress: deployment.contractAddress,
    arguments: deployment.arguments || [],
    transactionHash: deployment.hash,
  };
}

function getContractPath(contractName) {
  // Generate source path from contract name using convention
  if (contractName.endsWith("Lib")) {
    // Libraries are in src/libraries/
    return `src/libraries/${contractName}.sol:${contractName}`;
  } else {
    // Main contracts are in src/
    return `src/${contractName}.sol:${contractName}`;
  }
}

function getConstructorSignatureFromBroadcast(contractName, args) {
  // Use the arguments directly from broadcast artifacts with minimal type mapping
  if (!args || args.length === 0) {
    return null;
  }

  // Only override for the few contracts that need specific types
  const typeOverrides = {
    BullaInvoice: "constructor(address,address,uint16)", // Third param is uint16, not inferred uint256
    BullaFrendLendV2: "constructor(address,address,uint16)", // Third param is uint16, not inferred uint256
  };

  if (typeOverrides[contractName]) {
    return { signature: typeOverrides[contractName], args };
  }

  // For other contracts, infer types from the arguments
  const inferredSignature = `constructor(${args
    .map((arg) => {
      if (
        typeof arg === "string" &&
        arg.startsWith("0x") &&
        arg.length === 42
      ) {
        return "address";
      } else if (typeof arg === "string" && /^\d+$/.test(arg)) {
        const num = parseInt(arg);
        if (num <= 255) return "uint8";
        return "uint256";
      } else if (typeof arg === "boolean") {
        return "bool";
      } else {
        return "uint256"; // Default fallback
      }
    })
    .join(",")})`;

  return { signature: inferredSignature, args };
}

function getLibrariesForContract(contractName, libraryAddresses) {
  // Map contract names to their required libraries (using dynamic addresses)
  const contractLibraryNames = {
    // Libraries don't need other libraries
    BullaClaimPermitLib: [],
    CompoundInterestLib: [],
    BullaClaimValidationLib: [],
    // Main contracts and their library dependencies
    BullaControllerRegistry: [], // No libraries
    WhitelistPermissions: [], // No libraries
    BullaApprovalRegistry: ["BullaClaimPermitLib", "BullaClaimValidationLib"],
    BullaClaimV2: ["BullaClaimPermitLib", "BullaClaimValidationLib"],
    BullaInvoice: ["CompoundInterestLib"],
    BullaFrendLendV2: ["CompoundInterestLib"],
  };

  const requiredLibraryNames = contractLibraryNames[contractName] || [];

  // Convert library names to full library strings with addresses
  return requiredLibraryNames.map((libName) => {
    const address = libraryAddresses[libName];
    if (!address) {
      throw new Error(
        `Library ${libName} not found in broadcast artifacts for ${contractName}`
      );
    }
    return `src/libraries/${libName}.sol:${libName}:${address}`;
  });
}

async function encodeConstructorArgs(args, signature) {
  if (!args || args.length === 0 || !signature) return null;

  console.log(`🔧 Encoding constructor args: ${JSON.stringify(args)}`);
  console.log(`📝 Using signature: ${signature}`);

  // Format arguments properly for cast abi-encode
  const formattedArgs = args.map((arg) => {
    if (typeof arg === "string" && arg.startsWith("0x")) {
      return arg; // Address - keep as hex string
    }
    return arg.toString(); // Number - convert to string
  });

  return new Promise((resolve, reject) => {
    const cmd = ["cast", "abi-encode", signature, ...formattedArgs];
    console.log(`💻 Cast command: ${cmd.join(" ")}`);

    const childProcess = spawn(cmd[0], cmd.slice(1), {
      stdio: ["pipe", "pipe", "pipe"],
    });

    let output = "";
    let error = "";

    childProcess.stdout.on("data", (data) => {
      output += data.toString();
    });

    childProcess.stderr.on("data", (data) => {
      error += data.toString();
    });

    childProcess.on("close", (code) => {
      if (code === 0 && output.trim()) {
        console.log(`✅ Encoded args: ${output.trim()}`);
        resolve(output.trim());
      } else {
        console.log(`⚠️  Failed to encode constructor args: ${error}`);
        reject(new Error(`Failed to encode constructor arguments: ${error}`));
      }
    });
  });
}

async function verifyContractWithBroadcast(
  contractName,
  deployment,
  networkConfig,
  libraryAddresses
) {
  if (!deployment) {
    console.log(`❌ Skipping ${contractName} - no deployment found`);
    return false;
  }

  const contractPath = getContractPath(contractName);
  if (!contractPath) {
    console.log(`❌ Skipping ${contractName} - no contract path mapping`);
    return false;
  }

  // Ensure contract address is properly formatted as a string (fix scientific notation issue)
  const contractAddress = String(deployment.contractAddress).toLowerCase();

  console.log(`🔍 Verifying ${contractName} at ${contractAddress}...`);
  console.log(`   📁 Path: ${contractPath}`);
  console.log(
    `   🏗️  Constructor args: ${JSON.stringify(deployment.arguments)}`
  );
  console.log(`   🔗 Deploy tx: ${deployment.transactionHash}`);

  // Get required libraries for this contract
  const libraries = getLibrariesForContract(contractName, libraryAddresses);
  if (libraries.length > 0) {
    console.log(`   📚 Libraries: ${libraries.length} required`);
    libraries.forEach((lib) => console.log(`       ${lib}`));
  }

  // Prepare the command
  const cmd = ["forge", "verify-contract"];
  cmd.push(contractAddress);
  cmd.push(contractPath);
  cmd.push(`--chain=${networkConfig.name}`);
  cmd.push("--verifier=etherscan");

  if (networkConfig.apiKey) {
    cmd.push(`--etherscan-api-key=${networkConfig.apiKey}`);
  }

  // Add libraries if required (each library needs its own --libraries flag)
  if (libraries.length > 0) {
    libraries.forEach((library) => {
      cmd.push("--libraries");
      cmd.push(library);
    });
    // Force reverification for contracts with libraries to ensure correct library linkage
    cmd.push("--skip-is-verified-check");
    console.log(`   🔄 Forcing reverification due to library dependencies`);
  }

  // Add constructor arguments if present
  if (deployment.arguments && deployment.arguments.length > 0) {
    try {
      const constructorInfo = getConstructorSignatureFromBroadcast(
        contractName,
        deployment.arguments
      );
      if (constructorInfo) {
        console.log(
          `🔧 Encoding constructor args: ${JSON.stringify(
            constructorInfo.args
          )}`
        );
        console.log(`📝 Using signature: ${constructorInfo.signature}`);

        const encodedArgs = await encodeConstructorArgs(
          constructorInfo.args,
          constructorInfo.signature
        );
        if (encodedArgs) {
          cmd.push("--constructor-args");
          cmd.push(encodedArgs);
        }
      }
    } catch (error) {
      console.log(
        `⚠️  Failed to encode constructor args for ${contractName}: ${error.message}`
      );
      console.log(`💡 Skipping verification for this contract`);
      return false;
    }
  }

  return new Promise((resolve) => {
    console.log(`💻 Forge command: ${cmd.join(" ")}`);
    console.log("");

    const childProcess = spawn(cmd[0], cmd.slice(1), {
      stdio: ["pipe", "pipe", "pipe"],
    });

    let output = "";
    let error = "";

    childProcess.stdout.on("data", (data) => {
      output += data.toString();
    });

    childProcess.stderr.on("data", (data) => {
      error += data.toString();
    });

    childProcess.on("close", (code) => {
      if (code === 0) {
        if (
          output.includes("Contract successfully verified") ||
          output.includes("Already verified") ||
          output.includes("is already verified")
        ) {
          console.log(
            `✅ ${contractName} is VERIFIED on ${networkConfig.explorerName}`
          );
          resolve(true);
        } else if (
          output.includes("Response: `OK`") &&
          output.includes("GUID:")
        ) {
          console.log(
            `🔄 ${contractName} verification SUBMITTED to ${networkConfig.explorerName}`
          );
          const guidMatch = output.match(/GUID: `([^`]+)`/);
          if (guidMatch) {
            console.log(`   📋 GUID: ${guidMatch[1]}`);
          }
          resolve(true);
        } else {
          console.log(`⚠️  ${contractName} verification unclear:`);
          console.log(`   📤 Output: ${output.substring(0, 200)}...`);
          resolve(false);
        }
      } else {
        console.log(
          `❌ ${contractName} verification FAILED (exit code ${code})`
        );
        if (error.includes("Invalid constructor arguments provided")) {
          console.log(
            `   🚨 Constructor arguments error - check broadcast artifact`
          );
        }
        console.log(`   📤 Error: ${error.substring(0, 200)}...`);
        resolve(false);
      }
      console.log(""); // Add spacing
    });

    childProcess.on("error", (error) => {
      console.log(
        `❌ Error running forge for ${contractName}: ${error.message}`
      );
      resolve(false);
    });
  });
}

async function verifyAllContracts() {
  try {
    // Get network from environment variable
    const network = process.env.NETWORK;

    if (!network) {
      console.error("❌ NETWORK environment variable is required");
      console.error("   Set NETWORK in your .env file or use:");
      console.error(
        "   dotenv -e .env -- cross-env NETWORK=sepolia node script/verify-broadcast.js"
      );
      process.exit(1);
    }

    const networkConfig = NETWORK_CONFIG[network];
    if (!networkConfig) {
      console.error(`❌ Unsupported network: ${network}`);
      console.error(
        "   Supported networks:",
        Object.keys(NETWORK_CONFIG).join(", ")
      );
      process.exit(1);
    }

    console.log(
      `🚀 Verifying contracts using broadcast artifacts on ${networkConfig.explorerName}...\n`
    );

    // Load broadcast artifact
    const broadcastData = await loadBroadcastArtifact(network);

    // Extract library addresses from broadcast artifacts
    const libraryAddresses = extractLibraryAddresses(broadcastData);

    // Check if API key is available
    if (!networkConfig.apiKey) {
      console.log(
        `⚠️  Warning: No API key found for ${networkConfig.explorerName}`
      );
      console.log(`   Verification may fail without an API key`);
      console.log("");
    }

    // Verify each deployment (libraries and contracts)
    let successCount = 0;
    let totalCount = DEPLOYMENTS_TO_VERIFY.length;

    for (const deploymentName of DEPLOYMENTS_TO_VERIFY) {
      const deployment = findContractDeployment(broadcastData, deploymentName);
      const success = await verifyContractWithBroadcast(
        deploymentName,
        deployment,
        networkConfig,
        libraryAddresses
      );
      if (success) successCount++;

      // Add delay between verification requests to avoid rate limiting
      if (
        DEPLOYMENTS_TO_VERIFY.indexOf(deploymentName) <
        DEPLOYMENTS_TO_VERIFY.length - 1
      ) {
        console.log("⏳ Waiting 3 seconds to avoid rate limiting...\n");
        await new Promise((resolve) => setTimeout(resolve, 3000));
      }
    }

    // Summary
    console.log("=".repeat(50));
    console.log(`📊 Verification Summary:`);
    console.log(
      `   ✅ Successfully verified/submitted: ${successCount}/${totalCount}`
    );
    console.log(`   ❌ Failed: ${totalCount - successCount}/${totalCount}`);
    console.log(`   🌐 Network: ${networkConfig.explorerName}`);

    if (successCount === totalCount) {
      console.log("\n🎉 All libraries and contracts verification completed!");
    } else if (successCount > 0) {
      console.log(
        "\n⚠️  Some libraries/contracts had verification issues. Check the output above."
      );
    } else {
      console.log("\n💥 No libraries or contracts were successfully verified.");
    }
  } catch (error) {
    console.error("❌ Error during verification:", error.message);
    process.exit(1);
  }
}

// Handle Ctrl+C gracefully
process.on("SIGINT", () => {
  console.log("\n\n⚠️  Verification interrupted by user");
  process.exit(0);
});

// Run the verification
verifyAllContracts();
