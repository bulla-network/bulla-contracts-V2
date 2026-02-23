#!/usr/bin/env node

/**
 * Multi-network deployer for Bulla V2 contracts.
 * Prompts for the private key once, checks gas balances on all target
 * networks, then deploys sequentially to every network that has sufficient
 * funds.
 *
 * RPC URLs are sourced from bulla-banker/src/data-lib/networks.ts.
 * Pass --check-only to print balances without deploying.
 *
 * Usage:
 *   yarn deploy:all            – check balances then deploy
 *   yarn check:gas             – balance check only
 */

const { ethers } = require("ethers");
const { spawn } = require("child_process");
const readline = require("readline");
const fs = require("fs");
const path = require("path");

// ---------------------------------------------------------------------------
// Network definitions (RPC URLs from bulla-banker/src/data-lib/networks.ts)
// ---------------------------------------------------------------------------
const NETWORKS = [
  {
    name: "sepolia",
    chainId: 11155111,
    displayName: "Sepolia",
    rpcUrl: process.env.SEPOLIA_RPC_URL || "https://rpc.ankr.com/eth_sepolia/ba1559bd45627ea35b516452751976567e0fd8864450470f207b8d01cbc3f4dc",
    nativeToken: "ETH",
  },
  {
    name: "base",
    chainId: 8453,
    displayName: "Base",
    rpcUrl: process.env.BASE_RPC_URL || "https://rpc.ankr.com/base/ba1559bd45627ea35b516452751976567e0fd8864450470f207b8d01cbc3f4dc",
    nativeToken: "ETH",
  },
  {
    name: "mainnet",
    chainId: 1,
    displayName: "Ethereum",
    rpcUrl: process.env.MAINNET_RPC_URL || "https://rpc.ankr.com/eth/ba1559bd45627ea35b516452751976567e0fd8864450470f207b8d01cbc3f4dc",
    nativeToken: "ETH",
  },
  {
    name: "optimism",
    chainId: 10,
    displayName: "Optimism",
    rpcUrl: process.env.OPTIMISM_RPC_URL || "https://opt-mainnet.g.alchemy.com/v2/AgPafMyolA8rbO9wspKBfpYqusTimQkP",
    nativeToken: "ETH",
  },
  {
    name: "bsc",
    chainId: 56,
    displayName: "BNB Chain",
    rpcUrl: process.env.BSC_RPC_URL || "https://bsc.publicnode.com",
    nativeToken: "BNB",
  },
  {
    name: "gnosis",
    chainId: 100,
    displayName: "Gnosis",
    rpcUrl: process.env.GNOSIS_RPC_URL || "https://rpc.gnosischain.com",
    nativeToken: "XDAI",
  },
  {
    name: "polygon",
    chainId: 137,
    displayName: "Polygon",
    rpcUrl: process.env.POLYGON_RPC_URL || "https://rpc.ankr.com/polygon/ba1559bd45627ea35b516452751976567e0fd8864450470f207b8d01cbc3f4dc",
    nativeToken: "MATIC",
  },
  {
    name: "arbitrum",
    chainId: 42161,
    displayName: "Arbitrum",
    rpcUrl: process.env.ARBITRUM_RPC_URL || "https://arb1.arbitrum.io/rpc",
    nativeToken: "ETH",
  },
  {
    name: "celo",
    chainId: 42220,
    displayName: "Celo",
    rpcUrl: process.env.CELO_RPC_URL || "https://forno.celo.org",
    nativeToken: "CELO",
  },
  {
    name: "avalanche",
    chainId: 43114,
    displayName: "Avalanche",
    rpcUrl: process.env.AVALANCHE_RPC_URL || "https://avalanche-mainnet.core.chainstack.com/ext/bc/C/rpc/c3e5daa97eb95ebd06b9b1b553ca0ebe",
    nativeToken: "AVAX",
  },
];

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function hasExistingBroadcast(network) {
  const broadcastDir = path.join(
    __dirname,
    "..",
    "broadcast",
    "DeployContracts.s.sol",
    String(network.chainId)
  );
  return fs.existsSync(path.join(broadcastDir, "run-latest.json"));
}

function promptLine(question) {
  return new Promise((resolve) => {
    const rl = readline.createInterface({
      input: process.stdin,
      output: process.stdout,
    });
    rl.question(question, (answer) => {
      rl.close();
      resolve(answer.trim());
    });
  });
}

async function checkBalances(deployerAddress, networks) {
  console.log("\n=== Checking gas balances ===\n");

  const results = [];

  for (const network of networks) {
    try {
      const provider = new ethers.providers.JsonRpcProvider(network.rpcUrl);
      // Short timeout so a dead RPC doesn't stall the whole check
      const balancePromise = provider.getBalance(deployerAddress);
      const timeoutPromise = new Promise((_, reject) =>
        setTimeout(() => reject(new Error("timeout")), 8000)
      );

      const balance = await Promise.race([balancePromise, timeoutPromise]);
      const formatted = parseFloat(ethers.utils.formatEther(balance)).toFixed(6);
      const hasBalance = balance.gt(ethers.utils.parseEther("0.001")); // rough minimum
      const icon = hasBalance ? "✅" : "⚠️ ";

      console.log(
        `  ${icon}  ${network.displayName.padEnd(12)}  ${formatted.padStart(14)} ${network.nativeToken}`
      );
      results.push({ ...network, balance, hasBalance });
    } catch (err) {
      console.log(
        `  ❌  ${network.displayName.padEnd(12)}  failed (${err.message})`
      );
      results.push({ ...network, balance: null, hasBalance: false, error: err.message });
    }
  }

  return results;
}

function deployToNetwork(network, privateKey) {
  return new Promise((resolve) => {
    const separator = "─".repeat(60);
    console.log(`\n${separator}`);
    console.log(`  Deploying to ${network.displayName}  (${network.name})`);
    console.log(`${separator}\n`);

    const forgeArgs = [
      "script",
      "script/DeployContracts.s.sol:DeployContracts",
      "--rpc-url",
      network.rpcUrl,
      "--broadcast",
      "--private-key",
      privateKey,
    ];

    const env = {
      ...process.env,
      NETWORK: network.name,
      PRIVATE_KEY: privateKey,
    };

    const proc = spawn("forge", forgeArgs, { env, stdio: "inherit" });

    proc.on("close", (code) => {
      if (code === 0) {
        console.log(`\n✅ Deployed to ${network.displayName}`);
        resolve(true);
      } else {
        console.error(`\n❌ Deployment to ${network.displayName} failed (exit code ${code})`);
        resolve(false);
      }
    });

    proc.on("error", (err) => {
      if (err.code === "ENOENT") {
        console.error("❌ forge not found. Install Foundry: https://getfoundry.sh/");
      } else {
        console.error(`❌ Error: ${err.message}`);
      }
      resolve(false);
    });
  });
}

function verifyNetwork(network) {
  return new Promise((resolve) => {
    console.log(`\n🔍 Running verification for ${network.displayName}...`);
    const proc = spawn("node", ["script/verify-broadcast.js"], {
      env: { ...process.env, NETWORK: network.name },
      stdio: "inherit",
    });
    proc.on("close", (code) => {
      if (code === 0) {
        console.log(`✅ Verification complete for ${network.displayName}`);
      } else {
        console.log(
          `⚠️  Verification had issues for ${network.displayName} (exit code ${code})`
        );
      }
      resolve(code === 0);
    });
    proc.on("error", (err) => {
      console.log(`⚠️  Could not run verification script: ${err.message}`);
      resolve(false);
    });
  });
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  const checkOnly = process.argv.includes("--check-only");

  console.log("╔══════════════════════════════════════╗");
  console.log("║   Bulla V2 Multi-Network Deployer    ║");
  console.log("╚══════════════════════════════════════╝");

  const alreadyDeployed = NETWORKS.filter((n) => hasExistingBroadcast(n));
  const targets = NETWORKS.filter((n) => !hasExistingBroadcast(n));

  if (alreadyDeployed.length) {
    console.log("\nAlready deployed (skipping):");
    alreadyDeployed.forEach((n) => console.log(`  ⏭️  ${n.displayName}`));
  }

  console.log("\nTarget networks:");
  if (targets.length === 0) {
    console.log("  (none – all networks already deployed)");
    process.exit(0);
  }
  targets.forEach((n) => console.log(`  • ${n.displayName}`));

  // ── Private key prompt ──────────────────────────────────────────────────
  console.log("\n⚠️  Your private key input will be visible on screen.");
  console.log("🔒 Make sure no one is watching!\n");

  const rawKey = await promptLine("Enter your private key: ");
  console.clear();

  if (!rawKey.match(/^(0x)?[a-fA-F0-9]{64}$/)) {
    console.error("❌ Invalid private key format (expected 64 hex chars).");
    process.exit(1);
  }

  const privateKey = rawKey.startsWith("0x") ? rawKey : `0x${rawKey}`;
  const wallet = new ethers.Wallet(privateKey);
  console.log(`\n📍 Deployer: ${wallet.address}`);

  // ── Balance check ────────────────────────────────────────────────────────
  const balances = await checkBalances(wallet.address, targets);

  const ready = balances.filter((b) => b.hasBalance);
  const low   = balances.filter((b) => b.balance && !b.hasBalance);
  const dead  = balances.filter((b) => b.balance === null);

  console.log("\n=== Summary ===\n");
  if (ready.length)
    console.log(`  ✅ Ready:            ${ready.map((n) => n.displayName).join(", ")}`);
  if (low.length)
    console.log(`  ⚠️  Low/zero balance: ${low.map((n) => n.displayName).join(", ")}`);
  if (dead.length)
    console.log(`  ❌ RPC unreachable:  ${dead.map((n) => n.displayName).join(", ")}`);

  if (checkOnly) {
    console.log("\n(--check-only mode, exiting without deploying)");
    process.exit(0);
  }

  if (ready.length === 0) {
    console.error("\n❌ No networks have sufficient balance. Fund the deployer and retry.");
    process.exit(1);
  }

  // ── Confirmation ─────────────────────────────────────────────────────────
  const confirm = await promptLine(
    `\nProceed with deployment to ${ready.length} network(s)? (yes/no): `
  );

  if (confirm.toLowerCase() !== "yes") {
    console.log("Aborted.");
    process.exit(0);
  }

  // ── Deploy + Verify ──────────────────────────────────────────────────────
  const results = [];
  for (const network of ready) {
    const deployed = await deployToNetwork(network, privateKey);
    let verified = null;
    if (deployed) {
      verified = await verifyNetwork(network);
    }
    results.push({ displayName: network.displayName, deployed, verified });
  }

  // ── Final report ─────────────────────────────────────────────────────────
  const line = "═".repeat(60);
  console.log(`\n${line}`);
  console.log("  DEPLOYMENT SUMMARY");
  console.log(line);
  console.log(`  ${"Network".padEnd(14)} ${"Deploy".padEnd(10)} Verify`);
  console.log(`  ${"─".repeat(12)} ${"─".repeat(8)} ${"─".repeat(8)}`);
  results.forEach((r) => {
    const deployIcon = r.deployed ? "✅" : "❌";
    const verifyIcon = r.verified === null ? "—" : r.verified ? "✅" : "⚠️ ";
    console.log(`  ${r.displayName.padEnd(14)} ${deployIcon.padEnd(10)} ${verifyIcon}`);
  });
  const succeeded = results.filter((r) => r.deployed).length;
  const failed    = results.filter((r) => !r.deployed).length;
  console.log(`\n  Deployed: ${succeeded} succeeded, ${failed} failed`);
  console.log(line);
}

process.on("SIGINT", () => {
  console.log("\n\n⚠️  Interrupted by user.");
  process.exit(0);
});

main().catch((err) => {
  console.error("Fatal error:", err);
  process.exit(1);
});
