import fs from "fs";
import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "hardhat-preprocessor";
import "@nomicfoundation/hardhat-chai-matchers";
import "@nomiclabs/hardhat-ethers";

function getRemappings() {
  return fs
    .readFileSync("remappings.txt", "utf8")
    .split("\n")
    .filter(Boolean)
    .map((line: string) => line.trim().split("="));
}

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.15",
    settings: { optimizer: { enabled: true, runs: 2_000_000 } },
  },
  networks: {
    hardhat: {
      allowUnlimitedContractSize: true,
    },
  },
  paths: { cache: "cache/hardhat", sources: "src", artifacts: "out/hardhat" },
  preprocess: {
    eachLine: () => ({
      transform: (line: string) => {
        if (line.match(/^\s*import /i) || line.match(/} from /i)) {
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
