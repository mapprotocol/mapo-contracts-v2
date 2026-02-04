let fs = require("fs");
let path = require("path");
import "@nomicfoundation/hardhat-ethers";
import { HardhatRuntimeEnvironment } from "hardhat/types/runtime";




export function getNetworkName(network:string) {
    if(network.indexOf("test") > 0) return network;
    let suffix = process.env.NETWORK_SUFFIX;
    if(suffix === "main") {
        return network + '_' + "main";
    } else {
        return network + '_' + "prod";
    }
}


type Deployment = {
    [network: string]: {
        [key: string]: any;
    };
};

export async function getDeploymentByKey(network:string, key:string) {
    network = getNetworkName(network)
    let deployment = await readDeploymentFromFile(network);
    let deployAddress = deployment[network][key];
    if (!deployAddress) throw `no ${key} deployment in ${network}`;
    deployAddress = deployment[network][key];
    if (!deployAddress) throw `no ${key} deployment in ${network}`;

    return deployAddress;
}

async function readDeploymentFromFile(network: string): Promise<Deployment> {
    let deployments_path = "../../deployments/";
    let deployFile = "deploy.json";
    let p = path.join(__dirname, deployments_path + deployFile);
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


export async function saveDeployment(network:string, key:string, addr:string) {
  network = getNetworkName(network)
  let deployment = await readDeploymentFromFile(network);

  deployment[network][key] = addr;
  let p = path.join(__dirname, "../../deployments/deploy.json");
  await folder("../../deployments/");
  fs.writeFileSync(p, JSON.stringify(deployment, null, "\t"));
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

type Token = {
    name: string,
    addr: string,
    decimals: string,
    bridgeAble: boolean,
    mintAble: boolean,
    burnFrom: boolean
}

type ChainToken = {
    [network: string]: {
        chainId: number,
        lastScanBlock: number,
        updateGasFeeGap: number,
        confirmCount: number,
        minGasCallOnReceive: number,
        chainType: string,
        gasToken: string,
        baseFeeToken:string,
        transferFailedReceiver:string
        tokens: Token[]
    }
}

export async function getConfigration(network:string) { 
    let filePath = getFilePath(network);
    let p = path.join(__dirname, filePath + "configration.json");
    if(!fs.existsSync(p)) throw (`file ${p} not exist`);
    let rawdata = fs.readFileSync(p, "utf-8");
    return JSON.parse(rawdata)
}

export async function getAllChainTokens(network:string) {
   let filePath = getFilePath(network); 
   let p = path.join(__dirname, filePath + "chainTokens.json");
   if(!fs.existsSync(p)) throw (`file ${p} not exist`);
   let chainTokens: ChainToken;
   let rawdata = fs.readFileSync(p, "utf-8");
   chainTokens = JSON.parse(rawdata);
   return chainTokens;
}

export async function getChainTokenByNetwork(network:string) {

   let filePath = getFilePath(network); 
   let p = path.join(__dirname, filePath + "chainTokens.json");
   if(!fs.existsSync(p)) throw (`file ${p} not exist`);
   let chainTokens: ChainToken;
   let rawdata = fs.readFileSync(p, "utf-8");
   chainTokens = JSON.parse(rawdata);
   return chainTokens[network];
}

type TokenRegister = {
    vaultFeeRate: VaultFeeRate,
    balanceFeeRate: BalanceFeeRate,
    tokens: TokenInfo[]
}

type ChainWeight = {
    chainId: number,
    weight: number
}

type RelayOutMinAmount = {
    chainId: number,
    minAmount: string
}

type TokenInfo = {
    id: number,
    name: string,
    addr: string,
    vaultToken: string,
    chainWeights: ChainWeight[],
    relayOutMinAmounts: RelayOutMinAmount[]
}

type VaultFeeRate = {
    ammVault: number,
    fromVault: number,
    toVault: number,
    reserved: number,
}

type BalanceFeeRate = {
    balanceThreshold: number,
    fixedFromBalance: number,
    fixedToBalance: number,
    minBalance: number,
    maxBalance: number,
    reserved: number,
}

export async function getVaultFeeRate(network:string) {

   let filePath = getFilePath(network);    
   let p = path.join(__dirname, filePath + "tokenRegister.json");
   if(!fs.existsSync(p)) throw (`file ${p} not exist`);
   let tokenRegister: TokenRegister;
   let rawdata = fs.readFileSync(p, "utf-8");
   tokenRegister = JSON.parse(rawdata);
   return tokenRegister.vaultFeeRate;
}

export async function getBalanceFeeRate(network:string) {

   let filePath = getFilePath(network); 
   let p = path.join(__dirname, filePath + "tokenRegister.json");
   if(!fs.existsSync(p)) throw (`file ${p} not exist`);
   let tokenRegister: TokenRegister;
   let rawdata = fs.readFileSync(p, "utf-8");
   tokenRegister = JSON.parse(rawdata);
   return tokenRegister.balanceFeeRate;
}

export async function getTokenRegsterByTokenName(network:string, tokenName:string) {

   let filePath = getFilePath(network);

   let p = path.join(__dirname, filePath + "tokenRegister.json");
   if(!fs.existsSync(p)) throw (`file ${p} not exist`);
   let tokenRegister: TokenRegister;
   let rawdata = fs.readFileSync(p, "utf-8");
   tokenRegister = JSON.parse(rawdata);
   let tokenRegisters = tokenRegister.tokens;

   for (let index = 0; index < tokenRegisters.length; index++) {
     const element = tokenRegisters[index];
     if(element.name === tokenName) {
        return element
     }
   }
   return null;
   
}


export async function getAllTokenRegster(network:string) {

   let filePath = getFilePath(network); 
   let p = path.join(__dirname, filePath + "tokenRegister.json");
   if(!fs.existsSync(p)) throw (`file ${p} not exist`);
   let tokenRegister: TokenRegister;
   let rawdata = fs.readFileSync(p, "utf-8");
   tokenRegister = JSON.parse(rawdata);
   return tokenRegister.tokens;
}

type FeeShares = {
    feeType: number,
    share: number,
    receiver: string,
}

type ProtocolFee = {
    totalRate: number
    tokens: any[],
    feeShares: FeeShares[]
}

export async function getProtocolFeeConfig(network:string) {
   let filePath = getFilePath(network); 
   let p = path.join(__dirname, filePath + "protocolFee.json");
   if(!fs.existsSync(p)) throw (`file ${p} not exist`);
   let protocolFee: ProtocolFee;
   let rawdata = fs.readFileSync(p, "utf-8");
   protocolFee = JSON.parse(rawdata);
   return protocolFee;
}

function getFilePath(network:string) {
   let filePath;  
   let e = getNetworkEnv(network);
   if(e === 'test') {
        filePath = "../../configs/testnet/"
   } else if(e === 'main'){
        filePath = "../../configs/mainnet/"
   } else {
        filePath = "../../configs/prod/"
   }
   return filePath;
}

function getNetworkEnv(network:string)  {
    if(network.indexOf("test") >= 0) {
        return "test"
    } else {
        let suffix = process.env.NETWORK_SUFFIX;
        if(suffix === "main") {
            return "main"
        }  else {
            return "prod"
        }
    }
}


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