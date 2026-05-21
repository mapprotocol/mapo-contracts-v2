/**
 * Factory deployment — deterministic contract addresses across chains.
 * EVM: CREATE3 factory at 0x6258e4d2950757A749a4d4683A7342261ce12471
 * Tron: CREATE2 factory at TJAwD5VfMYMGWwdPi2aVcoQwVBfsuw5wQt
 */
import { tronFromHex } from "./tronHelper";

// Factory contract addresses
const EVM_FACTORY = "0x6258e4d2950757A749a4d4683A7342261ce12471";
const TRON_FACTORY = "TJAwD5VfMYMGWwdPi2aVcoQwVBfsuw5wQt";

// EVM factory ABI (CREATE3 — getAddress only needs salt)
// function deploy(bytes32 salt, bytes creationCode, uint256 value)
// function getAddress(bytes32 salt) view returns (address)
const EVM_FACTORY_ABI = [
    {
        "inputs": [{"name": "salt", "type": "bytes32"}, {"name": "creationCode", "type": "bytes"}, {"name": "value", "type": "uint256"}],
        "name": "deploy",
        "outputs": [],
        "stateMutability": "nonpayable",
        "type": "function"
    },
    {
        "inputs": [{"name": "salt", "type": "bytes32"}],
        "name": "getAddress",
        "outputs": [{"name": "", "type": "address"}],
        "stateMutability": "view",
        "type": "function"
    }
];

// Tron factory ABI (CREATE2 — getAddress needs salt + codeHash)
// function deploy(bytes32 salt, bytes creationCode, uint256 value) returns (address)
// function getAddress(bytes32 salt, bytes32 codeHash) view returns (address)
// function getAddressTron(bytes32 salt, bytes32 codeHash) view returns (address)
const TRON_FACTORY_ABI = [
    {
        "inputs": [{"name": "salt", "type": "bytes32"}, {"name": "creationCode", "type": "bytes"}, {"name": "value", "type": "uint256"}],
        "name": "deploy",
        "outputs": [{"name": "addr", "type": "address"}],
        "stateMutability": "nonpayable",
        "type": "function"
    },
    {
        "inputs": [{"name": "salt", "type": "bytes32"}, {"name": "codeHash", "type": "bytes32"}],
        "name": "getAddressTron",
        "outputs": [{"name": "", "type": "address"}],
        "stateMutability": "view",
        "type": "function"
    }
];

// ============================================================
// EVM Factory (CREATE3, ethers.js)
// ============================================================

/**
 * Deploy contract via CREATE3 factory on EVM chains.
 * Address only depends on salt, not bytecode.
 * @param ethers - ethers from hardhat runtime (hre.ethers)
 * @param salt - human-readable salt string
 * @param bytecode - contract bytecode (artifact.bytecode)
 * @param constructorArgs - ABI-encoded constructor arguments
 * @returns deployed contract address
 */
export async function evmDeployByFactory(
    ethers: any,
    salt: string,
    bytecode: string,
    constructorArgs: string = "0x"
): Promise<string> {
    const [signer] = await ethers.getSigners();
    const factory = new ethers.Contract(EVM_FACTORY, EVM_FACTORY_ABI, signer);

    const code = await ethers.provider.getCode(EVM_FACTORY);
    if (code === "0x") throw new Error("factory not deployed on this chain");

    const saltHash = ethers.keccak256(ethers.toUtf8Bytes(salt));
    // Use getFunction: ethers v6 Contract has a built-in getAddress() that shadows the ABI method
    const predicted = await factory.getFunction("getAddress")(saltHash);

    const existingCode = await ethers.provider.getCode(predicted);
    if (existingCode !== "0x") {
        console.log(`already deployed at ${predicted}`);
        return predicted;
    }

    const fullBytecode = constructorArgs === "0x"
        ? bytecode
        : ethers.concat([bytecode, constructorArgs]);

    const tx = await factory.deploy(saltHash, fullBytecode, 0);
    await tx.wait();

    // Verify contract was actually deployed
    const deployedCode = await ethers.provider.getCode(predicted);
    if (deployedCode === "0x") {
        throw new Error(`factory deploy failed: no contract at predicted address ${predicted}`);
    }
    console.log(`deployed via factory at ${predicted}`);
    return predicted;
}

/**
 * Get predicted factory address for a salt on EVM (CREATE3 — only needs salt).
 * @param ethers - ethers from hardhat runtime
 * @param salt - human-readable salt string
 */
export async function evmGetFactoryAddress(ethers: any, salt: string): Promise<string> {
    const factory = new ethers.Contract(EVM_FACTORY, EVM_FACTORY_ABI, await ethers.provider);
    const saltHash = ethers.keccak256(ethers.toUtf8Bytes(salt));
    // Use getFunction: ethers v6 Contract has a built-in getAddress() that shadows the ABI method
    return factory.getFunction("getAddress")(saltHash);
}

// ============================================================
// Tron Factory (CREATE2, tronweb)
// ============================================================

/**
 * Deploy contract via CREATE2 factory on Tron.
 * Address depends on salt + creationCode (bytecode + constructor args).
 * @param tronWeb - initialized tronweb instance
 * @param artifacts - hardhat artifacts
 * @param contractName - contract name to deploy
 * @param salt - human-readable salt string
 * @param args - constructor arguments array
 * @param feeLimit - tron fee limit
 * @returns deployed contract address (0x-prefixed hex)
 */
export async function tronDeployByFactory(
    tronWeb: any,
    artifacts: any,
    contractName: string,
    salt: string,
    args: any[] = [],
    feeLimit: number = 15_000_000_000
): Promise<string> {
    const factory = await tronWeb.contract(TRON_FACTORY_ABI, TRON_FACTORY);
    const saltHash = tronWeb.sha3(salt);

    // Build creation code with constructor args
    const artifact = await artifacts.readArtifact(contractName);
    let creationCode = artifact.bytecode;
    if (args.length > 0) {
        const iface = new (require("ethers").Interface)(artifact.abi);
        const encoded = iface.encodeDeploy(args);
        creationCode = creationCode + encoded.slice(2);
    }

    // Check if already deployed
    const codeHash = tronWeb.sha3(creationCode);
    const predicted = await factory.getAddressTron(saltHash, codeHash).call();
    const predictedHex = predicted.replace(/^41/, "0x");
    try {
        const existing = await tronWeb.trx.getContract(tronWeb.address.fromHex(predicted));
        if (existing && existing.bytecode) {
            console.log(`already deployed at ${tronFromHex(predicted)}`);
            return predictedHex;
        }
    } catch {}

    // Deploy
    console.log(`deploying ${contractName} via factory with salt "${salt}"...`);
    const { sendAndWait } = require("./tronHelper");
    const txResult = await sendAndWait(factory.deploy(saltHash, creationCode, 0), tronWeb, { feeLimit });

    // Read actual address from Deployed event
    let addrHex = predictedHex; // fallback to predicted
    if (txResult.log && txResult.log.length > 0) {
        // Deployed(address indexed addr, bytes32 indexed salt)
        // First topic = event sig, second topic = addr
        const addrTopic = txResult.log[0].topics?.[1];
        if (addrTopic) {
            addrHex = "0x" + addrTopic.slice(24); // last 20 bytes
        }
    }

    // Verify contract was actually deployed
    const addrBase58 = tronFromHex(addrHex);
    try {
        const deployed = await tronWeb.trx.getContract(addrBase58);
        if (!deployed || !deployed.bytecode) {
            throw new Error(`factory deploy failed: no contract at ${addrBase58}`);
        }
    } catch (e: any) {
        if (e.message?.includes("factory deploy failed")) throw e;
        // Contract might not be indexed yet, wait and retry
        await new Promise(r => setTimeout(r, 3000));
        const deployed = await tronWeb.trx.getContract(addrBase58);
        if (!deployed || !deployed.bytecode) {
            throw new Error(`factory deploy failed: no contract at ${addrBase58}`);
        }
    }

    console.log(`${contractName} deployed: ${addrBase58} (${addrHex})`);
    return addrHex;
}

/**
 * Get predicted factory address for a salt on Tron (CREATE2 — needs salt + codeHash).
 * @param tronWeb - initialized tronweb instance
 * @param salt - human-readable salt string
 * @param codeHash - keccak256 of creationCode (bytecode + constructor args)
 * @returns address in base58 format
 */
export async function tronGetFactoryAddress(tronWeb: any, salt: string, codeHash: string): Promise<string> {
    const factory = await tronWeb.contract(TRON_FACTORY_ABI, TRON_FACTORY);
    const saltHash = tronWeb.sha3(salt);
    const addr = await factory.getAddressTron(saltHash, codeHash).call();
    return tronFromHex(addr);
}
