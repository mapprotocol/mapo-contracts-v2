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


import { task } from "hardhat/config";
import { getDeploymentByKey, verify } from "./utils/utils"


task("upgrade", "upgrade contract")
  .addParam("contract", "contract name")
  .setAction(async (taskArgs, hre) => {
      const { network, ethers } = hre;
      let [wallet] = await ethers.getSigners();
      console.log("wallet address is: ", await wallet.getAddress());
      const ContractFactory = await ethers.getContractFactory(taskArgs.contract);
      let addr = await getDeploymentByKey(network.name, taskArgs.contract);
      if(!addr || addr.length === 0) throw("contract not deploy");
      // cast to any so TypeScript allows calling deploy on the generated factory
      let impl = await (await (ContractFactory as any).deploy()).waitForDeployment();

      let c = await ethers.getContractAt("BaseImplementation", addr, wallet);
      console.log(`pre impl `, await c.getImplementation());
      await(await c.upgradeToAndCall(await impl.getAddress(), "0x")).wait();
      console.log(`after impl `, await c.getImplementation());
      let code;
      if(
         taskArgs.contract === 'FlashSwapManager' || 
         taskArgs.contract === 'ViewController' || 
         taskArgs.contract === 'FusionQuoter' ||
         taskArgs.contract === 'FusionReceiver' ||
         taskArgs.contract === 'Configuration'
      ){
         code = `contracts/len/${taskArgs.contract}.sol:${taskArgs.contract}`
      } else {
         code = `contracts/${taskArgs.contract}.sol:${taskArgs.contract}` 
      }
      await verify(hre, await impl.getAddress(), [], code);
  })

// all before deploy vaultToken and Authority and SwapManager config in deploy.json
// steps  first Configuration protocol/configs file
// 1. deploy contract (a.deploy maintainer contract b.deploy protocol contract)  forge script
// 2. set up contract (a.set maintainer contract b.set protocol contract) forge script
// 3. gateway and relay -> gateway:updateTokens
// 4. gateway and relay -> gateway:gateway:setTransferFailedReceiver
// 5. vaultManager -> vaultManager:updateVaultFeeRate
// 6. vaultManager -> vaultManager:updateBalanceFeeRate
// 7. vaultManager -> vaultManager:registerToken
// 8. registry -> registry:registerAllChain
// 9. registry -> registry:registerAllToken
// 10. registry -> registry:mapAllToken
// 11. registry -> registry:setAllTokenNickname
// 12. relay -> relay:addAllChain
// 13. vaultManager -> vaultManager:updateAllTokenWeights
// 14. protocolFee ->  protocolFee:updateProtocolFee
// 15  vaultManager -> vaultManager:setAllMinAmount
// 16  gateway -> gateway:updateMinGasCallOnReceive
// 17  configuration -> configuration:configuration:deploy
// 18  configuration -> configuration:updateGasFeeGapFromConfig
// 19  configuration -> configuration:confirmCountFromConfig
// 20  configuration -> configuration:updateConfigrationFromConfig