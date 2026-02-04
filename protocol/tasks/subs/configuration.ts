import { task } from "hardhat/config";
import { Configuration } from "../../typechain-types/contracts/len"
import { getDeploymentByKey, verify, saveDeployment, getAllChainTokens, getConfigration } from "../utils/utils"

task("configuration:deploy", "deploy configuration contract")
    .setAction(async (taskArgs, hre) => {
        const { network, ethers } = hre;
        const [deployer] = await ethers.getSigners();
        console.log("deployer address:", await deployer.getAddress())
        const ConfigurationFactory = await ethers.getContractFactory("Configuration");
        let authority = await getDeploymentByKey(network.name, "Authority");
        if(!authority || authority.length == 0) throw("authority not deploy");

        let impl = await(await ConfigurationFactory.deploy()).waitForDeployment();
        let init_data = ConfigurationFactory.interface.encodeFunctionData("initialize", [authority]);
        let ContractProxy = await ethers.getContractFactory("ERC1967Proxy");
        let c = await (await ContractProxy.deploy(impl, init_data)).waitForDeployment();
        console.log("Configuration deploy to :", await c.getAddress());
        let v = ConfigurationFactory.attach(await c.getAddress()) as Configuration;
        await saveDeployment(network.name, "Configuration", await c.getAddress());
      // await verify(hre, await c.getAddress(), [await impl.getAddress(), init_data], "contracts/ERC1967Proxy.sol:ERC1967Proxy");
       await verify(hre, await impl.getAddress(), [], "contracts/len/Configuration.sol:Configuration");
});

task("configuration:updateConfigrationFromConfig", "updateConfigrationFromConfig")
    .setAction(async (taskArgs, hre) => {
        const { network, ethers } = hre;
        const [deployer] = await ethers.getSigners();
        console.log("deployer address:", await deployer.getAddress())
        const ConfigurationFactory = await ethers.getContractFactory("Configuration");
        let addr = await getDeploymentByKey(network.name, "Configuration");
        if(!addr || addr.length == 0) throw("configuration not deploy");
        let v = ConfigurationFactory.attach(addr) as Configuration;
        let config = await getConfigration(network.name);
        if(!config) throw("no configs");
        let types = Object.keys(config);
        for (let index = 0; index < types.length; index++) {
            const name = types[index];
            console.log(`Processing config type: ${name}`);
            let keys = Object.keys(config[name]);
            let values = Object.values(config[name]);
            if(keys.length == 0) continue;
            if(name === "intValue") {
                await v.batchSetIntValue(keys, values.map(value=>BigInt((value || 0).toString())));
            } else if(name === "stringValue") {
                await v.batchSetStringValue(keys, values.map(value=>(value || " ").toString()));
            } else if(name === "bytesValue") {
                await v.batchSetBytesValue(keys, values.map(value=>(value || " ").toString()));
            } else if(name === "addressValue") {
                await v.batchSetAddressValue(keys, values.map(value=>(value || " ").toString()));
            } else if(name === "boolValue") {
                await v.batchSetBoolValue(keys, values.map(value=>Boolean(value || false)));
            } else {
                throw("unknown config type:" + name);
            }
        }
    })

task("configuration:updateGasFeeGapFromConfig", "updateGasFeeGapFromConfig")
    .setAction(async (taskArgs, hre) => {
        const { network, ethers } = hre;
        const [deployer] = await ethers.getSigners();
        console.log("deployer address:", await deployer.getAddress())
        const ConfigurationFactory = await ethers.getContractFactory("Configuration");
        let addr = await getDeploymentByKey(network.name, "Configuration");
        if(!addr || addr.length == 0) throw("configuration not deploy");
        let v = ConfigurationFactory.attach(addr) as Configuration;
        let chainTokens = await getAllChainTokens(network.name);
        if(!chainTokens) throw("no chain token configs");
        let keys = Object.keys(chainTokens);
        for (let index = 0; index < keys.length; index++) {
            const name = keys[index];
            let element = chainTokens[name]
            let key = `${element.chainId}_GAS_FEE_GAP`;
            await setValue(v, key, element.updateGasFeeGap.toString(), "int");
        }
    })

task("configuration:confirmCountFromConfig", "confirmCountFromConfig")
    .setAction(async (taskArgs, hre) => {
        const { network, ethers } = hre;
        const [deployer] = await ethers.getSigners();
        console.log("deployer address:", await deployer.getAddress())
        const ConfigurationFactory = await ethers.getContractFactory("Configuration");
        let addr = await getDeploymentByKey(network.name, "Configuration");
        if(!addr || addr.length == 0) throw("configuration not deploy");
        let v = ConfigurationFactory.attach(addr) as Configuration;
        let chainTokens = await getAllChainTokens(network.name);
        if(!chainTokens) throw("no chain token configs");
        let keys = Object.keys(chainTokens);
        for (let index = 0; index < keys.length; index++) {
            const name = keys[index];
            let element = chainTokens[name]
            let key = `${element.chainId}_CONFIRM_COUNT`;
            await setValue(v, key, element.confirmCount.toString(), "int");
        }
    })

task("configuration:setValue", "setValue")
    .addParam("key", "configuration key")
    .addParam("value", "configuration value")
    .addParam("valuetype", "int, bytes, string, address, bool")
    .setAction(async (taskArgs, hre) => {
        const { network, ethers } = hre;
        const [deployer] = await ethers.getSigners();
        console.log("deployer address:", await deployer.getAddress())
        const ConfigurationFactory = await ethers.getContractFactory("Configuration");
        let addr = await getDeploymentByKey(network.name, "Configuration");
        if(!addr || addr.length == 0) throw("configuration not deploy");
        let v = ConfigurationFactory.attach(addr) as Configuration;
        await setValue(v, taskArgs.key, taskArgs.value, taskArgs.valuetype);
    })

async function setValue(v: Configuration, key: string, value: string, valuetype: string) { 
    console.log(`set key:${key}, value:${value}, type:${valuetype}`);    
    if(valuetype == "int") {
        let beforeValue = await v.getIntValue(key);
        if(beforeValue.toString() == value) {
            console.log("value no change:", beforeValue.toString());
            return;
        }
        await (await v.setIntValue(key, value)).wait();
        console.log("after value:", await v.getIntValue(key));
    } else if(valuetype == "bytes"){
        let beforeValue = await v.getBytesValue(key);
        if(beforeValue.toString() == value) {
            console.log("value no change:", beforeValue.toString());
            return;
        }
        await (await v.setBytesValue(key, value)).wait();
        console.log("after value:", await v.getBytesValue(key));
    } else if(valuetype == "string"){
        let beforeValue = await v.getStringValue(key);
        if(beforeValue.toString() == value) {
            console.log("value no change:", beforeValue.toString());
            return;
        }
        await (await v.setStringValue(key, value)).wait();
        console.log("after value:", await v.getStringValue(key));
    } else if(valuetype == "address"){
        let beforeValue = await v.getAddressValue(key);
        if(beforeValue.toString() == value) {
            console.log("value no change:", beforeValue.toString());
            return;
        }
        await (await v.setAddressValue(key, value)).wait();
        console.log("after value:", await v.getAddressValue(key));
    } else if(valuetype == "bool"){
        let beforeValue = await v.getBoolValue(key);
        if(beforeValue.toString() == value) { 
            console.log("value no change:", beforeValue.toString());
            return;
        }
        await (await v.setBoolValue(key, value.toLowerCase() == "true")).wait();
        console.log("after value:", await v.getBoolValue(key));
    } else {
        throw("unknown value type:" + valuetype);
    }
}