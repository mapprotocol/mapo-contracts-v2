import "@nomicfoundation/hardhat-toolbox";
import "@nomicfoundation/hardhat-foundry";
import { HardhatUserConfig } from "hardhat/config";
import * as dotenv from "dotenv";
import "./tasks";
dotenv.config();

const PRIVATE_KEY = process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [];
const TESTNET_PRIVATE_KEY = process.env.TESTNET_PRIVATE_KEY ? [process.env.TESTNET_PRIVATE_KEY] : [];
const TRON_PRIVATE_KEY = process.env.TRON_PRIVATE_KEY ? [process.env.TRON_PRIVATE_KEY] : [];
const ETHERSCAN_API_KEY = process.env.ETHERSCAN_API_KEY || "";

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

    // Testnets
    Mapo_test: {
      chainId: 212,
      url: "https://testnet-rpc.maplabs.io",
      accounts: TESTNET_PRIVATE_KEY,
    },
    Tron_test: {
      chainId: 3448148188,
      url: process.env.TRON_TEST_RPC_URL || "https://nile.trongrid.io/jsonrpc",
      accounts: TESTNET_PRIVATE_KEY,
    },
    Eth_test: {
      chainId: 11155111,
      url: "https://eth-sepolia.api.onfinality.io/public",
      accounts: TESTNET_PRIVATE_KEY,
    },
    Bsc_test: {
      chainId: 97,
      url: "https://api.zan.top/bsc-testnet",
      accounts: TESTNET_PRIVATE_KEY,
    },

    // Mainnets
    Mapo: {
      chainId: 22776,
      url: "https://rpc.maplabs.io",
      accounts: PRIVATE_KEY,
    },
    Eth: {
      chainId: 1,
      url: "https://eth-mainnet.public.blastapi.io",
      accounts: PRIVATE_KEY,
    },
    Bsc: {
      chainId: 56,
      url: "https://bsc-rpc.publicnode.com",
      accounts: PRIVATE_KEY,
    },
    Base: {
      chainId: 8453,
      url: "https://1rpc.io/base",
      accounts: PRIVATE_KEY,
    },
    Arb: {
      chainId: 42161,
      url: "https://arb1.arbitrum.io/rpc",
      accounts: PRIVATE_KEY,
    },
    Op: {
      chainId: 10,
      url: "https://optimism-public.nodies.app",
      accounts: PRIVATE_KEY,
    },
    Uni: {
      chainId: 130,
      url: "https://unichain.drpc.org",
      accounts: PRIVATE_KEY,
    },
    Pol: {
      chainId: 137,
      url: "https://polygon.drpc.org",
      accounts: PRIVATE_KEY,
    },
    Xlayer: {
      chainId: 196,
      url: "https://rpc.xlayer.tech",
      accounts: PRIVATE_KEY,
    },
    Tron: {
      chainId: 728126428,
      url: process.env.TRON_RPC_URL || "https://api.trongrid.io/jsonrpc",
      accounts: TRON_PRIVATE_KEY,
    },
  },
  etherscan: {
    apiKey: {
      Mapo: " ",
      Eth: ETHERSCAN_API_KEY,
      Bsc: ETHERSCAN_API_KEY,
      Base: ETHERSCAN_API_KEY,
      Arb: ETHERSCAN_API_KEY,
      Op: ETHERSCAN_API_KEY,
      Uni: ETHERSCAN_API_KEY,
      Pol: ETHERSCAN_API_KEY,
      Xlayer: " ",
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
      {
        network: "Arb",
        chainId: 42161,
        urls: {
          apiURL: "https://api.etherscan.io/v2/api?chainid=42161",
          browserURL: "https://arbiscan.io/",
        },
      },
      {
        network: "Op",
        chainId: 10,
        urls: {
          apiURL: "https://api.etherscan.io/v2/api?chainid=10",
          browserURL: "https://optimistic.etherscan.io/",
        },
      },
      {
        network: "Uni",
        chainId: 130,
        urls: {
          apiURL: "https://api.etherscan.io/v2/api?chainid=130",
          browserURL: "https://uniscan.io/",
        },
      },
      {
        network: "Pol",
        chainId: 137,
        urls: {
          apiURL: "https://api.etherscan.io/v2/api?chainid=137",
          browserURL: "https://polygonscan.com/",
        },
      },
      {
        network: "Xlayer",
        chainId: 196,
        urls: {
          apiURL: "https://www.oklink.com/api/v5/explorer/contract/verify-source-code-plugin/xlayer",
          browserURL: "https://www.oklink.com",
        },
      },
    ]
  },
};

export default config;
