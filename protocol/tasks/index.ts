import "./subs/Gateway";
import "./subs/vaultManager";
import "./subs/vaultToken";
import "./subs/registry";
import "./subs/protocolFee";
import "./subs/gasService";
import "./subs/relay";
import "./subs/swapManager";
import "./subs/fusionQuoter";
import "./subs/fusionReceiver";
import "./subs/configuration";
import "./subs/setup";
import "./subs/pause";


import { task, types } from "hardhat/config";
import { getDeploymentByKey, verify } from "./utils/utils"


task("verify-contract", "verify a deployed contract on block explorer")
    .addParam("contract", "contract name (e.g. Gateway, ERC1967Proxy)")
    .addParam("address", "deployed contract address")
    .addOptionalParam("args", "constructor args as JSON array (e.g. '[\"0x...\"]')", "[]", types.string)
    .addOptionalParam("params", "pre-encoded constructor params hex (no 0x prefix)", "", types.string)
    .setAction(async (taskArgs, hre) => {
        const { verify: verifyFn } = require("@mapprotocol/common-contracts/utils/verifier");
        let constructorArgs: any[] = [];
        try {
            constructorArgs = JSON.parse(taskArgs.args);
        } catch {}

        await verifyFn(hre, {
            contractName: taskArgs.contract,
            address: taskArgs.address,
            constructorArgs: constructorArgs.length > 0 ? constructorArgs : undefined,
            constructorParams: taskArgs.params || undefined,
        });
    });


task("upgrade", "upgrade contract")
  .addParam("contract", "contract name")
  .addParam("verify", "verify new impl after upgrade (true/false)", undefined, types.string)
  .setAction(async (taskArgs, hre) => {
      const { network } = hre;
      const { createDeployer } = require("@mapprotocol/common-contracts/utils/deployer");
      let addr = await getDeploymentByKey(network.name, taskArgs.contract);
      if(!addr || addr.length === 0) throw("contract not deploy");
      const deployer = createDeployer(hre, { autoVerify: taskArgs.verify === "true" });
      let result = await deployer.upgrade(taskArgs.contract, addr);
      console.log(`${taskArgs.contract} upgraded, new impl:`, result.address);
  })

// ============================================================
// Deployment & Initialization Guide
// ============================================================
//
// Prerequisites:
//   - Configure protocol/configs/ (chainTokens, tokenRegister, etc.)
//   - Set deploy.json with Authority, wToken, SwapManager, AffiliateManager addresses
//   - Set .env with PRIVATE_KEY, GATEWAY_SALT, ETHERSCAN_API_KEY
//
// === Step 1: Deploy (Forge) ===
//   make deploy CHAIN=Mapo                  # Relay chain (deploys Relay + VaultManager + Registry + ...)
//   make deploy CHAIN=Bsc                   # External chain (deploys Gateway)
//
// === Step 2: Upgrade (Forge) ===
//   make upgrade CHAIN=Bsc CONTRACT=Gateway
//   make upgrade CHAIN=Mapo CONTRACT=Relay
//   npx hardhat upgrade --contract Gateway --network Bsc   # alternative via hardhat
//
// === Step 3: Full Initialization (Hardhat - run on Mapo) ===
//   npx hardhat setup:init --network Mapo                  # dry-run (default)
//   npx hardhat setup:init --dryrun false --network Mapo   # execute
//
//   This runs steps 3-16 below in order:
//    3. gateway:updateTokens
//    4. gateway:setTransferFailedReceiver
//    5. gateway:updateMinGasCallOnReceive
//    6. vaultManager:updateVaultFeeRate
//    7. vaultManager:updateBalanceFeeRate
//    8. vaultManager:registerToken
//    9. registry:registerAllChains
//   10. registry:registerAllTokens
//   11. registry:mapAllTokens
//   12. registry:setAllTokenTicker
//   13. relay:addAllChains
//   14. vaultManager:updateAllTokenWeights
//   15. vaultManager:setAllMinAmount
//
// === Step 4: Add a New Chain (Hardhat - run on Mapo) ===
//   npx hardhat setup:addChain --chain Eth --network Mapo                 # dry-run
//   npx hardhat setup:addChain --chain Eth --dryrun false --network Mapo  # execute
//
//   This runs: registerChain -> mapTokens -> setTokenTickers -> relay:addChain
//
// === External Chain Config (Hardhat - run on target chain) ===
//   npx hardhat gateway:updateTokens --dryrun false --network Bsc
//   npx hardhat gateway:setWtoken --network Bsc
//   npx hardhat gateway:setTssAddress --pubkey <key> --network Bsc
//   npx hardhat gateway:setTransferFailedReceiver --network Bsc
//   npx hardhat gateway:updateMinGasCallOnReceive --network Bsc
//
// === Verification (Forge) ===
//   make gen-verify CONTRACT=Gateway        # generate standard json input
//   make gen-verify-all                     # generate for all contracts
//
// === Other Config ===
//   npx hardhat protocolFee:updateProtocolFee --network Mapo
//   npx hardhat configuration:deploy --network Mapo
//   npx hardhat configuration:updateGasFeeGapFromConfig --network Mapo
//   npx hardhat configuration:confirmCountFromConfig --network Mapo
//   npx hardhat configuration:updateConfigrationFromConfig --network Mapo