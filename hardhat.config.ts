import "@nomicfoundation/hardhat-chai-matchers";
import "@nomicfoundation/hardhat-toolbox";
import "@nomiclabs/hardhat-ethers";
import fs from "fs";
import "hardhat-preprocessor";
import { HardhatUserConfig } from "hardhat/config";
import * as toml from "toml";

function getRemappings() {
  try {
    // Read foundry.toml and parse it
    const foundryConfig = toml.parse(fs.readFileSync("foundry.toml", "utf8"));

    // Extract remappings from the config
    const remappings = foundryConfig.profile?.default?.remappings || [];

    // Convert to the format expected by the preprocessor
    return remappings.map((remapping: string) => remapping.split("="));
  } catch (error) {
    console.error("Error reading foundry.toml:", error);
    return [];
  }
}

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.15",
    settings: { optimizer: { enabled: true, runs: 2_000_000 } },
  },
  // networks: {
  //   hardhat: {
  //     allowUnlimitedContractSize: true,
  //   },
  // },
  paths: { cache: "cache/hardhat", sources: "src", artifacts: "out/hardhat" },
  preprocess: {
    eachLine: (hre) => ({
      transform: (line: string) => {
        if (line.match(/^\s*import /i) || line.match(/} from /i)) {
          // Special handling for openzeppelin imports
          if (line.includes("openzeppelin-contracts")) {
            return line.replace(
              "openzeppelin-contracts",
              "lib/openzeppelin-contracts"
            );
          }

          for (const [from, to] of getRemappings()) {
            if (line.includes(from)) {
              line = line.replace(from, to);
              break;
            }
          }
        }
        return line;
      },
    }),
  },
};

export default config;
