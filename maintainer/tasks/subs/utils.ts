let fs = require("fs");
let path = require("path");
import "@nomicfoundation/hardhat-ethers";
import { HardhatRuntimeEnvironment } from "hardhat/types/runtime";


let file_path = "../../deployments/";
let fileName = "deploy.json";

type Deployment = {
    [network: string]: {
        [key: string]: any;
    };
};

export async function verify(hre: HardhatRuntimeEnvironment, addr:string, args: any[], code:string) {
    console.log(args);
    const verifyArgs = args.map((arg) => (typeof arg == "string" ? `'${arg}'` : arg)).join(" ");
    console.log(`To verify, run: \n npx hardhat verify --network ${hre.network.name} --contract ${code} ${addr} ${verifyArgs}`);
    if (hre.network.config.chainId !== 22776) return;
    console.log(`verify ${code} ...`);
    console.log("addr:", addr);
    console.log("args:", args);
    await hre.run("verify:verify", {
        contract: code,
        address: addr,
        constructorArguments: args,
    });
}


export async function deployProxy(hre: HardhatRuntimeEnvironment, impl:string, authority:string) {
    let { ethers } = hre;
    // BaseImplementation
    let I = await ethers.getContractFactory("Parameters");
    let init_data = I.interface.encodeFunctionData("initialize", [authority]);

    let ContractProxy = await ethers.getContractFactory("ERC1967Proxy");
    let c = await (await ContractProxy.deploy(impl, init_data)).waitForDeployment();
    let addr = await c.getAddress()
    console.log("proxy deploy to:", addr);
  //  await verify(hre, addr, [impl, init_data], "contracts/ERC1967Proxy.sol:ERC1967Proxy");
    return c.getAddress();
}


export async function saveDeployment(network:string, key:string, addr:string) {
    let deployment = await readFromFile(network);

    if (!deployment[network][key]) {
        deployment[network][key] = {};
    }
    deployment[network][key] = addr;
    let p = path.join(__dirname, file_path + fileName);
    await folder(file_path);
    fs.writeFileSync(p, JSON.stringify(deployment, null, "\t"));
}

export async function getDeployment(network:string, key:string) {
    let deployment = await readFromFile(network);
    let deployAddress = deployment[network][key];
    if (!deployAddress) throw `no ${key} deployment in ${network}`;
    deployAddress = deployment[network][key];
    if (!deployAddress) throw `no ${key} deployment in ${network}`;

    return deployAddress;
}

async function readFromFile(network: string): Promise<Deployment> {
    let p = path.join(__dirname, file_path + fileName);
    let deploy: Deployment;
    if (!fs.existsSync(p)) {
        deploy = {};
        deploy[network] = {};
    } else {
        let rawdata = fs.readFileSync(p, "utf-8");
        deploy = JSON.parse(rawdata);
        if (!deploy[network]) {
            deploy[network] = {};
        }
    }
    return deploy;
}


const folder = async (reaPath:string) => {
    const absPath = path.resolve(__dirname, reaPath);
    try {
        await fs.promises.stat(absPath);
    } catch (e) {
        // {recursive: true}
        await fs.promises.mkdir(absPath, { recursive: true });
    }
};