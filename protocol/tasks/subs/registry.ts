import { task } from "hardhat/config";
import { Registry } from "../../typechain-types/contracts"
import { 
    getDeploymentByKey, 
    getAllChainTokens, 
    getChainTokenByNetwork,
    getTokenRegsterByTokenName,
    getAllTokenRegster
} from "../utils/utils"

task("registry:registerAllChain", "register Chain info")
    .setAction(async (taskArgs, hre) => {
        const { network, ethers } = hre;
        const [deployer] = await ethers.getSigners();
        console.log("deployer address:", await deployer.getAddress())
        const RegistryFactory = await ethers.getContractFactory("Registry");
        let addr = await getDeploymentByKey(network.name, "Registry");
        const registry = RegistryFactory.attach(addr) as Registry;

        let chainTokens = await getAllChainTokens(network.name);
        if(!chainTokens) throw("no chain token configs");
        let keys = Object.keys(chainTokens);
        for (let index = 0; index < keys.length; index++) {
            const name = keys[index];
            await registerChain(name, registry, chainTokens[name]);
        }
        
});

task("registry:registerChainByNetwork", "register Chain info By Network name")
    .addParam("name", "chain name")
    .setAction(async (taskArgs, hre) => {
        const { network, ethers } = hre;
        const [deployer] = await ethers.getSigners();
        console.log("deployer address:", await deployer.getAddress())
        const RegistryFactory = await ethers.getContractFactory("Registry");
        let addr = await getDeploymentByKey(network.name, "Registry");
        const registry = RegistryFactory.attach(addr) as Registry;

        let chainToken = await getChainTokenByNetwork(taskArgs.name);
        if(!chainToken) throw("chain info not set");
        await registerChain(taskArgs.name, registry, chainToken)
});

task("registry:deregisterChain", "deregisterChain")
    .addParam("chain", "chain id")
    .setAction(async (taskArgs, hre) => {
        const { network, ethers } = hre;
        const [deployer] = await ethers.getSigners();
        console.log("deployer address:", await deployer.getAddress())
        const RegistryFactory = await ethers.getContractFactory("Registry");
        let addr = await getDeploymentByKey(network.name, "Registry");
        const registry = RegistryFactory.attach(addr) as Registry;
        console.log(`removeChain chain(${taskArgs.chain})`);
        await(await registry.deregisterChain(taskArgs.chain)).wait();
});

task("registry:registerToken", "register Chain info by token name")
    .addParam("name", "token name")
    .setAction(async (taskArgs, hre) => {
        const { network, ethers } = hre;
        const [deployer] = await ethers.getSigners();
        console.log("deployer address:", await deployer.getAddress())
        const RegistryFactory = await ethers.getContractFactory("Registry");
        let addr = await getDeploymentByKey(network.name, "Registry");
        const registry = RegistryFactory.attach(addr) as Registry;
        let token = await getTokenRegsterByTokenName(network.name, taskArgs.name);
        if(!token || token === null) throw("token not set");
        console.log(`registerToken ${token.name} id(${token.id}), addr(${token.addr}, vaultToken(${token.vaultToken}))`);
        await(await registry.registerToken(token.id, token.addr)).wait();
});

task("registry:registerAllToken", "register Chain info")
    .setAction(async (taskArgs, hre) => {
        const { network, ethers } = hre;
        const [deployer] = await ethers.getSigners();
        console.log("deployer address:", await deployer.getAddress())
        const RegistryFactory = await ethers.getContractFactory("Registry");
        let addr = await getDeploymentByKey(network.name, "Registry");
        const registry = RegistryFactory.attach(addr) as Registry;
        let tokens = await getAllTokenRegster(network.name);
        if(!tokens || tokens.length === 0) throw("token not set");
        for (let index = 0; index < tokens.length; index++) {
            const token = tokens[index];
            console.log(`registerToken ${token.name} id(${token.id}), addr(${token.addr})`);
            await(await registry.registerToken(token.id, token.addr)).wait();
        }
});



task("registry:setTokenTicker", "set TokenNick name")
    .addParam("chain", "chain id")
    .addParam("addr", "token address")
    .addParam("name", "token nickname")
    .setAction(async (taskArgs, hre) => {
        const { network, ethers } = hre;
        const [deployer] = await ethers.getSigners();
        console.log("deployer address:", await deployer.getAddress())
        const RegistryFactory = await ethers.getContractFactory("Registry");
        let addr = await getDeploymentByKey(network.name, "Registry");
        const registry = RegistryFactory.attach(addr) as Registry;
        console.log(`set Token Nickname  chain(${taskArgs.chain}), addr(${taskArgs.addr}, name(${taskArgs.name}))`);
        await(await registry.setTokenTicker(taskArgs.chain, taskArgs.addr, taskArgs.name)).wait();
});

task("registry:setAllTokenNickname", "set TokenNick name")
    .setAction(async (taskArgs, hre) => {
        const { network, ethers } = hre;
        const [deployer] = await ethers.getSigners();
        console.log("deployer address:", await deployer.getAddress())
        const RegistryFactory = await ethers.getContractFactory("Registry");
        let addr = await getDeploymentByKey(network.name, "Registry");
        const registry = RegistryFactory.attach(addr) as Registry;
        let chainTokens = await getAllChainTokens(network.name);
        if(!chainTokens) throw("no chain token configs");
        let keys = Object.keys(chainTokens);
        for (let index = 0; index < keys.length; index++) {
            const name = keys[index];
            let element = chainTokens[name]
            let tokens = element.tokens;
            if(!tokens || tokens.length === 0) continue;
            for (let j = 0; j < tokens.length; j++) {
                const token = tokens[j];
                let preNickname = await registry.getTokenNickname(element.chainId, token.addr);
                if(preNickname !== token.name) {
                   console.log(`update Token Nickname  chain(${element.chainId}), addr(${token.addr}, name(${token.name})`); 
                   await(await registry.setTokenTicker(element.chainId, token.addr, token.name)).wait();
                }
            }
            
        }
});


task("registry:unmapToken", "unmap Token")
    .addParam("chain", "chain id")
    .addParam("addr", "token address")
    .setAction(async (taskArgs, hre) => {
        const { network, ethers } = hre;
        const [deployer] = await ethers.getSigners();
        console.log("deployer address:", await deployer.getAddress())
        const RegistryFactory = await ethers.getContractFactory("Registry");
        let addr = await getDeploymentByKey(network.name, "Registry");
        const registry = RegistryFactory.attach(addr) as Registry;
        console.log(`unmap Token: chain(${taskArgs.chain}),  addr(${taskArgs.addr})`);
        await(await registry.unmapToken(taskArgs.chain, taskArgs.addr)).wait();
});

task("registry:mapAllToken", "map all Token")
    .setAction(async (taskArgs, hre) => {
        const { network, ethers } = hre;
        let tokens = await getAllTokenRegster(network.name);
        if(!tokens || tokens.length === 0) throw("token not set");
        for (let index = 0; index < tokens.length; index++) {
            const token = tokens[index];
            await hre.run("registry:mapTokenByTokenName", {
                token: token.name
            })
        }
});

task("registry:mapTokenByTokenName", "map Token by token name")
    .addParam("token", "token name")
    .setAction(async (taskArgs, hre) => {
        const { network, ethers } = hre;
        const [deployer] = await ethers.getSigners();
        console.log("deployer address:", await deployer.getAddress())
        const RegistryFactory = await ethers.getContractFactory("Registry");
        let addr = await getDeploymentByKey(network.name, "Registry");
        const registry = RegistryFactory.attach(addr) as Registry;

        let relayToken = await getTokenRegsterByTokenName(network.name, taskArgs.token);
        if(!relayToken || relayToken === null) throw("token not set");

        let chainTokens = await getAllChainTokens(network.name);
        if(!chainTokens) throw("no chain token configs");
        let keys = Object.keys(chainTokens);

        for (let index = 0; index < keys.length; index++) {
            let key = keys[index]
            if(key === network.name) continue;
            let element = chainTokens[key]
            const tokens = element.tokens;
            if(!tokens || tokens.length === 0) continue;
            for (let j = 0; j < tokens.length; j++) {
                const token = tokens[j];
                if(token.name === taskArgs.token) {
                    console.log(`map token ${token.name}: ${relayToken.addr}, chain(${element.chainId}), addr(${token.addr}), decimals(${token.decimals})`);
                    await(await registry.mapToken(relayToken.addr, element.chainId, token.addr, token.decimals)).wait();
                }
            }
        }

});

task("registry:mapToken", "map Token")
    .addParam("token", "relay chain token address")
    .addParam("chain", "from chain id")
    .addParam("addr", "from token address")
    .addParam("decimals", "from token decimals")
    .setAction(async (taskArgs, hre) => {
        const { network, ethers } = hre;
        const [deployer] = await ethers.getSigners();
        console.log("deployer address:", await deployer.getAddress())
        const RegistryFactory = await ethers.getContractFactory("Registry");
        let addr = await getDeploymentByKey(network.name, "Registry");
        const registry = RegistryFactory.attach(addr) as Registry;
        console.log(`map token ${taskArgs.token}, chain(${taskArgs.chain}), addr(${taskArgs.addr}, decimals(${taskArgs.decimals})`);
        await(await registry.mapToken(taskArgs.token, taskArgs.chain, taskArgs.addr, taskArgs.decimals)).wait();
});


async function registerChain(network: string, registry: Registry, chainToken: {
        chainId: number,
        lastScanBlock: number,
        chainType: string,
        gasToken: string,
        baseFeeToken:string,
        tokens: any[]}) {
    
        let chainType = (chainToken.chainType === "contract") ? 0 : 1;

        let router = await getRouter(network);
        console.log(
            `registerChain ${network} chain(${chainToken.chainId}), chainType(${chainType}), router(${router}), gasToken(${chainToken.gasToken}), baseFeeToken(${chainToken.baseFeeToken})`
        );
        await(await registry.registerChain(
            chainToken.chainId,
            chainType,
            router,
            chainToken.gasToken,
            chainToken.baseFeeToken,
            network
        )).wait()
}

async function getRouter(network:string) {
        let router;
        if(network === "Mapo_test" || network === "Mapo") {
            router = await getDeploymentByKey(network, "Relay");
        } else {
            try {
                router = await getDeploymentByKey(network, "Gateway");
            } catch (error) {
                router = "0x";
            }
        }
        return router;
}
