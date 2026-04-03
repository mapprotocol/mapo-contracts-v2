import { task } from "hardhat/config";
import { Gateway, VaultManager } from "../../typechain-types/contracts"
import { getDeploymentByKey, getChainTokenByNetwork, getAllChainTokens, saveDeployment} from "../utils/utils"
import { tronDeploy, tronFromHex, tronToHex, getTronContract } from "../utils/tronUtil"
import { addressToHex } from "../utils/addressUtil"


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
            let c = await getTronContract("Gateway", hre.artifacts, network.name, await tronFromHex(addr, network.name));
            let currentWtoken = await tronFromHex(await c.wToken().call(), network.name);
            if (currentWtoken.toLowerCase() === wtoken.toLowerCase()) {
                console.log(`wtoken already set to ${currentWtoken}, skipping`);
                return;
            }
            console.log(`on-chain wtoken: ${currentWtoken}, config wtoken: ${wtoken}, updating...`);
            await c.setWtoken(await tronToHex(wtoken, network.name)).send();
            console.log(`after wtoken address is: `, await tronFromHex(await c.wToken().call(), network.name))
        } else {
            const [deployer] = await ethers.getSigners();
            console.log("deployer address:", await deployer.getAddress())
            const GatewayFactory = await ethers.getContractFactory("Gateway");
            const gateway = GatewayFactory.attach(addr) as Gateway;
            let currentWtoken = await gateway.wToken();
            if (currentWtoken.toLowerCase() === wtoken.toLowerCase()) {
                console.log(`wtoken already set to ${currentWtoken}, skipping`);
                return;
            }
            console.log(`on-chain wtoken: ${currentWtoken}, config wtoken: ${wtoken}, updating...`);
            await(await gateway.setWtoken(wtoken)).wait();
            console.log(`after wtoken address is: `, await gateway.wToken())
        }
});

task("gateway:setTssAddress", "set tss pubkey")
    .setAction(async (taskArgs, hre) => {
        const { network, ethers } = hre;
        const [deployer] = await ethers.getSigners();

        let addr = await getDeploymentByKey(network.name, "Gateway");

        let tssPubkey = await getPubkey(network.name, ethers);
        
        if(!tssPubkey) throw("tss not active yet, cannot get pubkey");
        if(tssPubkey.length !== 130) throw("invalid pubkey length");
        console.log(`current active tss pubkey is ${tssPubkey}`);

        if(isTronNetwork(network.name)) {
            let c = await getTronContract("Gateway", hre.artifacts, network.name, await tronFromHex(addr, network.name));
            let currentPubkey = await c.activeTss().call();
            if (currentPubkey.toLowerCase() === tssPubkey.toLowerCase()) {
                console.log(`pubkey already set to ${currentPubkey}, skipping`);
                return;
            }
            console.log(`on-chain pubkey: ${currentPubkey}, config pubkey: ${tssPubkey}, updating...`);
            await c.setTssAddress(tssPubkey).send();
            console.log(`after pubkey is: `, await c.activeTss().call())
        } else {
            console.log("deployer address:", await deployer.getAddress())
            const GatewayFactory = await ethers.getContractFactory("Gateway");
            const gateway = GatewayFactory.attach(addr) as Gateway;
            let currentPubkey = await gateway.activeTss();
            if (currentPubkey.toLowerCase() === tssPubkey.toLowerCase()) {
                console.log(`pubkey already set to ${currentPubkey}, skipping`);
                return;
            }
            console.log(`on-chain pubkey: ${currentPubkey}, config pubkey: ${tssPubkey}, updating...`);
            await(await gateway.setTssAddress(tssPubkey)).wait();
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
            let c = await getTronContract("Gateway", hre.artifacts, network.name, await tronFromHex(addr, network.name));
            let currentReceiver = await tronFromHex(await c.transferFailedReceiver().call(), network.name);
            if (currentReceiver.toLowerCase() === transferFailedReceiver.toLowerCase()) {
                console.log(`transferFailedReceiver already set to ${currentReceiver}, skipping`);
                return;
            }
            console.log(`on-chain transferFailedReceiver: ${currentReceiver}, config: ${transferFailedReceiver}, updating...`);
            await c.setTransferFailedReceiver(await tronToHex(transferFailedReceiver, network.name)).send();
            console.log(`after transferFailedReceiver is: `, await tronFromHex(await c.transferFailedReceiver().call(), network.name))
        } else {
            const [deployer] = await ethers.getSigners();
            console.log("deployer address:", await deployer.getAddress())
            const GatewayFactory = await ethers.getContractFactory("Gateway");
            const gateway = GatewayFactory.attach(addr) as Gateway;
            let currentReceiver = await gateway.transferFailedReceiver();
            if (currentReceiver.toLowerCase() === transferFailedReceiver.toLowerCase()) {
                console.log(`transferFailedReceiver already set to ${currentReceiver}, skipping`);
                return;
            }
            console.log(`on-chain transferFailedReceiver: ${currentReceiver}, config: ${transferFailedReceiver}, updating...`);
            await(await gateway.setTransferFailedReceiver(transferFailedReceiver)).wait();
            console.log(`${network.name} transferFailedReceiver is:`, await gateway.transferFailedReceiver());
        }

});

task("gateway:updateMinGasCallOnReceive", "update MinGas CallOnReceive")
    .setAction(async (taskArgs, hre) => {
        const { network, ethers } = hre;

        let addr;
        if(isRelayChain(network.name)) {
            addr = await getDeploymentByKey(network.name, "Relay");
        } else {
            addr = await getDeploymentByKey(network.name, "Gateway");
        }
        let minGasCallOnReceive = (await getChainTokenByNetwork(network.name)).minGasCallOnReceive
        if(!minGasCallOnReceive || minGasCallOnReceive === 0) return;

        if(isTronNetwork(network.name)) {
            let c = await getTronContract("Gateway", hre.artifacts, network.name, await tronFromHex(addr, network.name));
            let currentMinGas = await c.minGasCallOnReceive().call();
            if (currentMinGas === BigInt(minGasCallOnReceive)) {
                console.log(`minGasCallOnReceive already set to ${currentMinGas}, skipping`);
                return;
            }
            console.log(`on-chain minGasCallOnReceive: ${currentMinGas}, config: ${minGasCallOnReceive}, updating...`);
            await c.updateMinGasCallOnReceive(minGasCallOnReceive).send();
            console.log(`after minGasCallOnReceive is: `, await c.minGasCallOnReceive().call())
        } else {
            const [deployer] = await ethers.getSigners();
            console.log("deployer address:", await deployer.getAddress())
            const GatewayFactory = await ethers.getContractFactory("Gateway");
            const gateway = GatewayFactory.attach(addr) as Gateway;
            let currentMinGas = await gateway.minGasCallOnReceive();
            if (currentMinGas === BigInt(minGasCallOnReceive)) {
                console.log(`minGasCallOnReceive already set to ${currentMinGas}, skipping`);
                return;
            }
            console.log(`on-chain minGasCallOnReceive: ${currentMinGas}, config: ${minGasCallOnReceive}, updating...`);
            await(await gateway.updateMinGasCallOnReceive(minGasCallOnReceive)).wait();
            console.log(`${network.name} minGasCallOnReceive is:`, await gateway.minGasCallOnReceive());
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
            let c = await getTronContract("Gateway", hre.artifacts, network.name, await tronFromHex(addr, network.name));
           for (let index = 0; index < tokens.length; index++) {
                const element = tokens[index];
                let feature = 0;
                if(element.bridgeAble) feature = feature | 1;
                if(element.mintAble) feature = feature | 2;
                if(element.burnFrom) feature = feature | 4;
                let pre = await c.tokenFeatureList(addressToHex(element.addr)).call();
                if(pre ===  BigInt(feature)) {
                    console.log(`${element.name} tokenFeature already set to ${pre}, skipping`);
                    continue;
                }
                console.log(`${element.name} on-chain tokenFeature: ${pre}, config: ${feature}, updating...`);
                await c.updateTokens([addressToHex(element.addr)], feature).send();
                console.log(`${element.name} after tokenFeature`, await c.tokenFeatureList(addressToHex(element.addr)).call());
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
                if(pre ===  BigInt(feature)) {
                    console.log(`${element.name} tokenFeature already set to ${pre}, skipping`);
                    continue;
                }
                console.log(`${element.name} on-chain tokenFeature: ${pre}, config: ${feature}, updating...`);
                await(await gateway.updateTokens([element.addr], feature)).wait();
                console.log(`${element.name} after tokenFeature`, await gateway.tokenFeatureList(element.addr));
            } 
        }
});


task("gateway:bridgeOut", "bridge out tokens to another chain")
    .addParam("token", "token name (e.g., USDT, BTC) or address")
    .addParam("amount", "amount to bridge (e.g., 1.5)")
    .addParam("tochain", "destination chain name (e.g., Bsc, Mapo)")
    .addOptionalParam("to", "receiver address on destination chain (default: sender)")
    .addOptionalParam("refund", "refund address (default: sender)")
    .addOptionalParam("payload", "payload data (default: 0x)")
    .addOptionalParam("deadline", "deadline timestamp (default: current time + 1 hour)")
    .setAction(async (taskArgs, hre) => {
        const { network, ethers } = hre;
        const [deployer] = await ethers.getSigners();
        const senderAddress = await deployer.getAddress();
        console.log("deployer address:", senderAddress);

        let addr;
        if (isRelayChain(network.name)) {
            addr = await getDeploymentByKey(network.name, "Relay");
        } else {
            addr = await getDeploymentByKey(network.name, "Gateway");
        }

        // Get token info
        const tokenInfo = await getTokenInfo(network.name, taskArgs.token);
        const token = tokenInfo.addr;
        const decimals = tokenInfo.decimals;
        const amount = ethers.parseUnits(taskArgs.amount, decimals);
        console.log(`Token: ${tokenInfo.name}, address: ${token}, decimals: ${decimals}, amount: ${amount}`);

        // Get destination chain info
        const toChainInfo = await getChainInfoByName(network.name, taskArgs.tochain);
        const toChainId = BigInt(toChainInfo.chainId);
        console.log(`Destination chain: ${taskArgs.tochain}, chainId: ${toChainId}`);

        // Set receiver address (default to sender)
        const toAddress = taskArgs.to || senderAddress;
        const to = addressToHex(toAddress, taskArgs.tochain);
        console.log(`Receiver: ${toAddress}, bytes: ${to}`);

        const refundAddr = taskArgs.refund || senderAddress;
        let payload = taskArgs.payload || "0x";
        const deadline = taskArgs.deadline || Math.floor(Date.now() / 1000) + 3600;

        const isNativeToken = token === "0x0000000000000000000000000000000000000000";

        if (isTronNetwork(network.name)) {
            let c = await getTronContract("Gateway", hre.artifacts, network.name, await tronFromHex(addr, network.name));

            if (!isNativeToken) {
                const tokenContract = await getTronContract("IERC20", hre.artifacts, network.name, await tronFromHex(token, network.name));
                console.log("Approving token...");
                await tokenContract.approve(await tronToHex(addr, network.name), amount).send();
            }

            console.log(`Bridging out ${taskArgs.amount} ${tokenInfo.name} to ${taskArgs.tochain}...`);
            const tx = await c.bridgeOut(
                await tronToHex(token, network.name),
                amount,
                toChainId,
                to,
                await tronToHex(refundAddr, network.name),
                payload,
                deadline
            ).send({ callValue: isNativeToken ? amount : 0 });

            console.log("Bridge out tx:", tx);
        } else {
            const GatewayFactory = await ethers.getContractFactory("Gateway");
            const gateway = GatewayFactory.attach(addr) as Gateway;

            if (!isNativeToken) {
                const tokenContract = await ethers.getContractAt("IERC20", token);
                console.log("Approving token...");
                await (await tokenContract.approve(addr, amount)).wait();
            }

            console.log(`Bridging out ${taskArgs.amount} ${tokenInfo.name} to ${taskArgs.tochain}...`);
            if(payload === "0x" && network.name.indexOf("Mapo") !== -1) { 
                payload = ethers.AbiCoder.defaultAbiCoder().encode(["bytes", "bytes", "bytes"], ["0x", "0x", "0x"]);
            }
            const tx = await gateway.bridgeOut(
                token,
                amount,
                toChainId,
                to,
                refundAddr,
                payload,
                deadline,
                { value: isNativeToken ? amount : 0 }
            );
            const receipt = await tx.wait();
            console.log("Bridge out tx hash:", receipt?.hash);

            const bridgeOutEvent = receipt?.logs.find(log => {
                try {
                    const parsed = gateway.interface.parseLog({ topics: log.topics as string[], data: log.data });
                    return parsed?.name === "BridgeOut";
                } catch {
                    return false;
                }
            });

            if (bridgeOutEvent) {
                const parsed = gateway.interface.parseLog({ topics: bridgeOutEvent.topics as string[], data: bridgeOutEvent.data });
                console.log("Order ID:", parsed?.args[0]);
            }
        }
});

task("gateway:deposit", "deposit tokens to vault")
    .addParam("token", "token name (e.g., USDT, BTC) or address")
    .addParam("amount", "amount to deposit (e.g., 1.5)")
    .addOptionalParam("to", "receiver address (default: sender)")
    .addOptionalParam("refund", "refund address (default: sender)")
    .addOptionalParam("deadline", "deadline timestamp (default: current time + 1 hour)")
    .setAction(async (taskArgs, hre) => {
        const { network, ethers } = hre;
        const [deployer] = await ethers.getSigners();
        const senderAddress = await deployer.getAddress();
        console.log("deployer address:", senderAddress);

        let addr;
        if (isRelayChain(network.name)) {
            addr = await getDeploymentByKey(network.name, "Relay");
        } else {
            addr = await getDeploymentByKey(network.name, "Gateway");
        }

        // Get token info
        const tokenInfo = await getTokenInfo(network.name, taskArgs.token);
        const token = tokenInfo.addr;
        const decimals = tokenInfo.decimals;
        const amount = ethers.parseUnits(taskArgs.amount, decimals);
        console.log(`Token: ${tokenInfo.name}, address: ${token}, decimals: ${decimals}, amount: ${amount}`);

        // Set receiver address (default to sender)
        const toAddress = taskArgs.to || senderAddress;
        console.log(`Receiver: ${toAddress}`);

        const refundAddr = taskArgs.refund || senderAddress;
        const deadline = taskArgs.deadline || Math.floor(Date.now() / 1000) + 3600;

        const isNativeToken = token === "0x0000000000000000000000000000000000000000";

        if (isTronNetwork(network.name)) {
            let c = await getTronContract("Gateway", hre.artifacts, network.name, await tronFromHex(addr, network.name));

            if (!isNativeToken) {
                const tokenContract = await getTronContract("IERC20", hre.artifacts, network.name, await tronFromHex(token, network.name));
                console.log("Approving token...");
                await tokenContract.approve(await tronToHex(addr, network.name), amount).send();
            }

            console.log(`Depositing ${taskArgs.amount} ${tokenInfo.name}...`);
            const tx = await c.deposit(
                await tronToHex(token, network.name),
                amount,
                await tronToHex(toAddress, network.name),
                await tronToHex(refundAddr, network.name),
                deadline
            ).send({ callValue: isNativeToken ? amount : 0 });

            console.log("Deposit tx:", tx);
        } else {
            const GatewayFactory = await ethers.getContractFactory("Gateway");
            const gateway = GatewayFactory.attach(addr) as Gateway;

            if (!isNativeToken) {
                const tokenContract = await ethers.getContractAt("IERC20", token);
                console.log("Approving token...");
                await (await tokenContract.approve(addr, amount)).wait();
            }

            console.log(`Depositing ${taskArgs.amount} ${tokenInfo.name}...`);
            const tx = await gateway.deposit(
                token,
                amount,
                toAddress,
                refundAddr,
                deadline,
                { value: isNativeToken ? amount : 0 }
            );
            const receipt = await tx.wait();
            console.log("Deposit tx hash:", receipt?.hash);

            const bridgeOutEvent = receipt?.logs.find(log => {
                try {
                    const parsed = gateway.interface.parseLog({ topics: log.topics as string[], data: log.data });
                    return parsed?.name === "BridgeOut";
                } catch {
                    return false;
                }
            });

            if (bridgeOutEvent) {
                const parsed = gateway.interface.parseLog({ topics: bridgeOutEvent.topics as string[], data: bridgeOutEvent.data });
                console.log("Order ID:", parsed?.args[0]);
            }
        }
});

function isTronNetwork(network:string) {
    return (network === "Tron" || network === "tron_test")
}

function isRelayChain(network:string) {
    return (network === "Mapo" || network === "Mapo_test")
}

async function getTokenInfo(network: string, tokenNameOrAddr: string) {
    const chainConfig = await getChainTokenByNetwork(network);
    const tokens = chainConfig.tokens;

    // Try to find by name first
    for (const token of tokens) {
        if (token.name.toLowerCase() === tokenNameOrAddr.toLowerCase()) {
            return token;
        }
    }

    // Try to find by address
    for (const token of tokens) {
        if (token.addr.toLowerCase() === tokenNameOrAddr.toLowerCase()) {
            return token;
        }
    }

    throw new Error(`Token ${tokenNameOrAddr} not found in ${network} config`);
}

async function getChainIdByName(currentNetwork: string, chainName: string) {
    const allChains = await getAllChainTokens(currentNetwork);

    if (allChains[chainName]) {
        return BigInt(allChains[chainName].chainId);
    }

    throw new Error(`Chain ${chainName} not found in config`);
}

async function getChainInfoByName(currentNetwork: string, chainName: string) {
    const allChains = await getAllChainTokens(currentNetwork);

    if (allChains[chainName]) {
        return allChains[chainName];
    }

    throw new Error(`Chain ${chainName} not found in config`);
}

async function getPubkey(chainName: string , ethers: any) {
    const VaultManagerFactory = await ethers.getContractFactory("VaultManager");
    if(chainName.indexOf("test") > 0) {
        let addr = await getDeploymentByKey("Mapo_test", "VaultManager");
        let provider = new ethers.JsonRpcProvider("https://testnet-rpc.maplabs.io");
        const v = VaultManagerFactory.attach(addr) as VaultManager;
        return v.connect(provider).getActiveVault();
    } else {
        let addr = await getDeploymentByKey("Mapo", "VaultManager");
        let provider = new ethers.JsonRpcProvider("https://rpc.maplabs.io");
        const v = VaultManagerFactory.attach(addr) as VaultManager;
        return v.connect(provider).getActiveVault();
    }
}       