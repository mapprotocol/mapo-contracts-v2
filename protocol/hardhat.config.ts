import "@nomicfoundation/hardhat-toolbox";
import "@nomicfoundation/hardhat-foundry";
import { HardhatUserConfig } from "hardhat/config";
import * as dotenv from "dotenv";
import "./tasks";
dotenv.config();



const config: HardhatUserConfig = {
  paths: {
    cache: "cache_hardhat"
  },
  solidity: {
    version: "0.8.25",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
      evmVersion: "london"
    },
  },
  networks: {
    hardhat: {
      chainId: 1337,
    },
    localhost: {
      url: "http://127.0.0.1:8545",
    },

    Mapo_test: {
      chainId: 212,
      url: "https://testnet-rpc.maplabs.io",
      accounts: process.env.TESTNET_PRIVATE_KEY !== undefined ? [process.env.TESTNET_PRIVATE_KEY] : [],
    },

    Tron_test: {
      url: `https://nile.trongrid.io/jsonrpc`,
      chainId: 3448148188,
      accounts: process.env.TESTNET_PRIVATE_KEY !== undefined ? [process.env.TESTNET_PRIVATE_KEY] : [],
    },

    Eth_test: {
      url: `https://eth-sepolia.api.onfinality.io/public`,
      chainId: 11155111,
      accounts: process.env.PRIVATE_KEY !== undefined ? [process.env.PRIVATE_KEY] : [],
    },

    Bsc_test: {
      url: `https://api.zan.top/bsc-testnet`,
      chainId: 97,
      accounts: process.env.PRIVATE_KEY !== undefined ? [process.env.PRIVATE_KEY] : [],
    },

    Mapo: {
      chainId: 22776,
      url: "https://rpc.maplabs.io",
      accounts: process.env.PRIVATE_KEY !== undefined ? [process.env.PRIVATE_KEY] : [],
    },

    Eth: {
      url: "https://eth-mainnet.public.blastapi.io",
      chainId: 1,
      accounts:
        process.env.PRIVATE_KEY !== undefined ? [process.env.PRIVATE_KEY] : [],
    },

    Bsc: {
      url: `https://bsc-rpc.publicnode.com`,
      chainId: 56,
      accounts:
        process.env.PRIVATE_KEY !== undefined ? [process.env.PRIVATE_KEY] : [],
    },

    Base: {
      url: `https://1rpc.io/base`,
      chainId: 8453,
      accounts:
        process.env.PRIVATE_KEY !== undefined ? [process.env.PRIVATE_KEY] : [],
    },

    Tron: {
      url: `https://api.trongrid.io/jsonrpc`,
      chainId: 728126428,
      accounts: process.env.TRON_PRIVATE_KEY !== undefined ? [process.env.TRON_PRIVATE_KEY] : [],
    },
  },
  etherscan: {
    apiKey: {
      Mapo: " ",
      Eth: process.env.ETHERSCAN_API_KEY || "",
      Bsc: process.env.ETHERSCAN_API_KEY || "",
      Base: process.env.ETHERSCAN_API_KEY || ""
    },
    customChains: [
      {
        network: "Mapo",
        chainId: 22776,
        urls: {
          apiURL: "https://explorer-api.chainservice.io/api",
          browserURL: "https://explorer.mapprotocol.io"
        },
      },
      {
        network: "Eth",
        chainId: 1,
        urls: {
          apiURL: "https://api.etherscan.io/v2/api?chainid=1",
          browserURL: "https://etherscan.com/",
        },
      },
      {
        network: "Bsc",
        chainId: 56,
        urls: {
          apiURL: "https://api.etherscan.io/v2/api?chainid=56",
          browserURL: "https://bscscan.com/",
        },
      },

      {
        network: "Base",
        chainId: 8453,
        urls: {
          apiURL: "https://api.etherscan.io/v2/api?chainid=8453",
          browserURL: "https://basescan.com/",
        },
      },
    ]
  },
};

export default config;
