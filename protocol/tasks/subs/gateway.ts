import { task } from "hardhat/config";
import { Gateway } from "../../typechain-types/contracts"
import { getDeploymentByKey, getChainTokenByNetwork,  saveDeployment} from "../utils/utils"
import { tronDeploy, tronFromHex, tronToHex, getTronContract } from "../utils/tronUtil"


task("gateway:tronDeploy", "set wtoken address")
    .setAction(async (taskArgs, hre) => {
        const { network, ethers } = hre;
        if(network.name !== "Tron" && network.name !== "tron_test") {
            throw ("only support tron");
        }

        let authority = await getDeploymentByKey(network.name, "Authority");
        if(!authority || authority.length === 0) throw("authority not set");

        let impl = await tronDeploy("Gateway", [], hre.artifacts, network.name);

        const GatewayFactory = await ethers.getContractFactory("Gateway");

        let data = GatewayFactory.interface.encodeFunctionData("initialize", [await tronToHex(authority, network.name)]);

        let addr = await tronDeploy("ERC1967Proxy", [impl, data], hre.artifacts, network.name);
        
        await saveDeployment(network.name, "Gateway", await tronFromHex(addr, network.name));
        let wtoken = await getDeploymentByKey(network.name, "wToken");
        if(wtoken && wtoken.length > 0) {
            let c = await getTronContract("Gateway", hre.artifacts, network.name, await tronFromHex(addr, network.name));
            console.log(`pre wtoken address is: `, await tronFromHex(await c.wToken().call(), network.name));
            await c.setWtoken(await tronToHex(wtoken, network.name)).send();
            console.log(`after wtoken address is: `, await tronFromHex(await c.wToken().call(), network.name))
        }
});

task("gateway:setWtoken", "set wtoken address")
    .setAction(async (taskArgs, hre) => {
        const { network, ethers } = hre;
        let wtoken = await getDeploymentByKey(network.name, "wToken");
        let addr;
        if(isRelayChain(network.name)) {
            addr = await getDeploymentByKey(network.name, "Relay");
        } else {
            addr = await getDeploymentByKey(network.name, "Gateway");
        }
        if(isTronNetwork(network.name)) {
            let c = await getTronContract("Gateway", hre.artifacts, network.name, addr);
            console.log(`pre wtoken address is: `, await tronFromHex(await c.wToken().call(), network.name));
            await c.setWtoken(await tronToHex(wtoken, network.name)).send();
            console.log(`after wtoken address is: `, await tronFromHex(await c.wToken().call(), network.name))
        } else {
            const [deployer] = await ethers.getSigners();
            console.log("deployer address:", await deployer.getAddress())
            const GatewayFactory = await ethers.getContractFactory("Gateway");
            const gateway = GatewayFactory.attach(addr) as Gateway;

            console.log(`pre wtoken address is: `, await gateway.wToken())
            await(await gateway.setWtoken(wtoken)).wait();
            console.log(`after wtoken address is: `, await gateway.wToken())
        }
});

task("gateway:setTssAddress", "set tss pubkey")
    .addParam("pubkey", "tss pubkey")
    .setAction(async (taskArgs, hre) => {
        const { network, ethers } = hre;
        const [deployer] = await ethers.getSigners();

        let addr = await getDeploymentByKey(network.name, "Gateway");
        if(isTronNetwork(network.name)) {
            let c = await getTronContract("Gateway", hre.artifacts, network.name, addr);
            console.log(`pre pubkey is: `, await c.activeTss().call())
            await c.setTssAddress(taskArgs.pubkey).send();
            console.log(`after pubkey is: `, await c.activeTss().call())
        } else {
            console.log("deployer address:", await deployer.getAddress())
            const GatewayFactory = await ethers.getContractFactory("Gateway");
            const gateway = GatewayFactory.attach(addr) as Gateway;
            console.log(`pre pubkey is: `, await gateway.activeTss())
            await(await gateway.setTssAddress(taskArgs.pubkey)).wait();
            console.log(`after pubkey is: `, await gateway.activeTss())
        }

});

task("gateway:setTransferFailedReceiver", "set Transfer Failed Receiver")
    .setAction(async (taskArgs, hre) => {
        const { network, ethers } = hre;

        let addr;
        if(isRelayChain(network.name)) {
            addr = await getDeploymentByKey(network.name, "Relay");
        } else {
            addr = await getDeploymentByKey(network.name, "Gateway");
        }
        let transferFailedReceiver = (await getChainTokenByNetwork(network.name)).transferFailedReceiver
        if(!transferFailedReceiver || transferFailedReceiver.length == 0) return;

        if(isTronNetwork(network.name)) {
            let c = await getTronContract("Gateway", hre.artifacts, network.name, addr);
            console.log(`pre transferFailedReceiver is: `, await c.transferFailedReceiver().call())
            await c.setTransferFailedReceiver(await tronToHex(transferFailedReceiver, network.name)).send();
            console.log(`after transferFailedReceiver is: `, await c.transferFailedReceiver().call())
        } else {
            const [deployer] = await ethers.getSigners();
            console.log("deployer address:", await deployer.getAddress())
            const GatewayFactory = await ethers.getContractFactory("Gateway");
            const gateway = GatewayFactory.attach(addr) as Gateway;
            await(await gateway.setTransferFailedReceiver(transferFailedReceiver)).wait();
            console.log(`${network.name} transferFailedReceiver is:`, await gateway.transferFailedReceiver());
        }

});


task("gateway:updateTokens", "update Tokens")
    .setAction(async (taskArgs, hre) => {
        const { network, ethers } = hre;

        let addr;
        if(isRelayChain(network.name)) {
            addr = await getDeploymentByKey(network.name, "Relay");
        } else {
            addr = await getDeploymentByKey(network.name, "Gateway");
        }
        let tokens = (await getChainTokenByNetwork(network.name)).tokens
        if(!tokens || tokens.length == 0) return;


        if(isTronNetwork(network.name)) {
            let c = await getTronContract("Gateway", hre.artifacts, network.name, addr);
           for (let index = 0; index < tokens.length; index++) {
                const element = tokens[index];
                let feature = 0;
                if(element.bridgeAble) feature = feature | 1;
                if(element.mintAble) feature = feature | 2;
                if(element.burnFrom) feature = feature | 4;
                let pre = await c.tokenFeatureList(element.addr).call();
                console.log(`${element.name} pre tokenFeature`, pre);
                if(pre !==  BigInt(feature)) {
                    await c.updateTokens([element.addr], feature).send();
                    console.log(`${element.name} after tokenFeature`, await c.tokenFeatureList(element.addr).call());
                }
            } 
        } else {
            const [deployer] = await ethers.getSigners();
            console.log("deployer address:", await deployer.getAddress())
            const GatewayFactory = await ethers.getContractFactory("Gateway");
            const gateway = GatewayFactory.attach(addr) as Gateway;
            for (let index = 0; index < tokens.length; index++) {
                const element = tokens[index];
                let feature = 0;
                if(element.bridgeAble) feature = feature | 1;
                if(element.mintAble) feature = feature | 2;
                if(element.burnFrom) feature = feature | 4;
                let pre = await gateway.tokenFeatureList(element.addr);
                console.log(`${element.name} pre tokenFeature`, pre);
                if(pre !==  BigInt(feature)) {
                    await(await gateway.updateTokens([element.addr], feature)).wait();
                    console.log(`${element.name} after tokenFeature`, await gateway.tokenFeatureList(element.addr));
                }
            } 
        }
});


function isTronNetwork(network:string) {
    return (network === "Tron" || network === "tron_test")
}

function isRelayChain(network:string) {
    return (network === "Mapo" || network === "Mapo_test")
}