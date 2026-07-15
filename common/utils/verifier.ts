/**
 * Contract verification — supports Etherscan, Blockscout (Mapo), and TronScan.
 * Auto-routes based on network name.
 */
import { isTronNetwork, tronFromHex } from "./tronHelper";

// TronScan API endpoints by chainId
const TRONSCAN_API: Record<number, string> = {
    728126428: "https://apilist.tronscan.org/api/solidity/contract/verify",   // mainnet
    3448148188: "https://nile.tronscan.org/api/solidity/contract/verify",     // nile testnet
};

export interface VerifyOptions {
    address: string;             // contract address (0x hex or Tron base58)
    contractName: string;        // e.g. "AuthorityManager"
    contractPath?: string;       // e.g. "contracts/AuthorityManager.sol:AuthorityManager"
    /**
     * Constructor arguments as raw values — auto-encoded via ethers `encodeDeploy`.
     * Example: ["0xAbC123...", "0xDeF456...", 200]
     * Use this for most cases. Mutually exclusive with constructorParams.
     */
    constructorArgs?: any[];
    /**
     * Pre-encoded constructor params as hex string (without 0x prefix).
     * Use this when you already have the ABI-encoded bytes, e.g. from `cast abi-encode`.
     * Takes priority over constructorArgs if both are provided.
     */
    constructorParams?: string;
    compiler?: string;           // override solc version (auto-read from build-info if omitted)
    optimizer?: boolean;         // override optimizer enabled (auto-read from build-info if omitted)
    optimizerRuns?: number;      // override optimizer runs (auto-read from build-info if omitted)
    /**
     * Reuse an existing verify-output/<contract>_flatten.sol instead of regenerating it.
     * Off by default: the flatten is always regenerated from current source, because a
     * cached file keyed only on the contract name silently verifies STALE source after
     * the contract changes. Only enable this when you intentionally hand-edited the flatten.
     */
    reuseFlatten?: boolean;
}

/**
 * Unified contract verification — auto-routes to EVM (hardhat verify) or Tron (TronScan API)
 */
export async function verify(hre: any, opts: VerifyOptions): Promise<void> {
    const network = hre.network.name;

    if (isTronNetwork(network)) {
        await verifyTron(hre, opts);
    } else {
        await verifyEvm(hre, opts);
    }
}

// ============================================================
// EVM verification via hardhat-verify
// ============================================================

async function verifyEvm(hre: any, opts: VerifyOptions): Promise<void> {
    // Resolve contractPath from hardhat artifact (authoritative) instead of guessing
    let contractPath = opts.contractPath;
    if (!contractPath) {
        try {
            const artifact = await hre.artifacts.readArtifact(opts.contractName);
            contractPath = `${artifact.sourceName}:${opts.contractName}`;
        } catch {
            contractPath = `contracts/${opts.contractName}.sol:${opts.contractName}`;
        }
    }

    console.log(`verifying ${opts.contractName} at ${opts.address} ...`);

    try {
        await hre.run("verify:verify", {
            contract: contractPath,
            address: opts.address,
            constructorArguments: opts.constructorArgs || [],
        });
        console.log(`${opts.contractName} verified`);
    } catch (e: any) {
        if (e.message?.includes("Already Verified")) {
            console.log(`${opts.contractName} already verified`);
        } else {
            console.log(`verification failed: ${e.message || e}`);
            // Print manual command as fallback
            const args = (opts.constructorArgs || []).map((a: any) => typeof a === "string" ? `'${a}'` : a).join(" ");
            console.log(`manual: npx hardhat verify --network ${hre.network.name} --contract ${contractPath} ${opts.address} ${args}`);
        }
    }
}

// ============================================================
// Tron verification via TronScan API
// ============================================================

async function verifyTron(hre: any, opts: VerifyOptions): Promise<void> {
    const chainId = hre.network.config.chainId;
    const fs = require("fs");
    const path = require("path");

    // Compiler settings: opts > build-info > hardhat config (no hardcoded defaults)
    const solcConfig = hre.config?.solidity?.compilers?.[0] || hre.config?.solidity || {};
    let compiler = opts.compiler || solcConfig.version || "";
    let optimizer = opts.optimizer ?? solcConfig.settings?.optimizer?.enabled;
    let optimizerRuns = opts.optimizerRuns ?? solcConfig.settings?.optimizer?.runs;
    let evmVersion = solcConfig.settings?.evmVersion || "";
    let viaIR = solcConfig.settings?.viaIR ? "1" : "0";

    // Convert address to Tron format
    let address = opts.address;
    if (address.startsWith("0x")) {
        address = tronFromHex(address);
    }

    // Generate flattened source
    const outputDir = path.join(process.cwd(), "verify-output");
    const flattenPath = path.join(outputDir, `${opts.contractName}_flatten.sol`);

    if (opts.reuseFlatten && fs.existsSync(flattenPath)) {
        console.log(`reusing existing flatten: ${flattenPath}`);
    } else {
        console.log(`generating flatten for ${opts.contractName}...`);
        let sourcePath = "";
        try {
            const artifact = await hre.artifacts.readArtifact(opts.contractName);
            sourcePath = artifact.sourceName;
            let flattenedSource = await hre.run("flatten:get-flattened-sources", {
                files: [sourcePath],
            });
            flattenedSource = removeDuplicateSPDX(flattenedSource);
            fs.mkdirSync(outputDir, { recursive: true });
            fs.writeFileSync(flattenPath, flattenedSource);
            console.log(`flatten saved to: ${flattenPath}`);
        } catch (e) {
            const hint = sourcePath || `contracts/${opts.contractName}.sol`;
            console.log(`flatten failed, generate manually: npx hardhat flatten ${hint} > ${flattenPath}`);
            return;
        }
    }

    // Submit to TronScan API
    const apiUrl = TRONSCAN_API[chainId];
    if (!apiUrl) {
        console.log(`no TronScan API for chainId ${chainId}, printing manual instructions instead`);
        printTronVerifyInfo(address, opts.contractName, compiler, optimizer, optimizerRuns, evmVersion, flattenPath, chainId);
        return;
    }

    console.log(`submitting verification to TronScan for ${address}...`);
    try {
        const FormData = require("form-data");
        const form = new FormData();
        form.append("contractAddress", address);
        form.append("contractName", opts.contractName);
        // Read compiler settings from build-info that contains this contract
        let fullCompiler = `v${compiler}`;
        try {
            const buildInfoDir = path.join(process.cwd(), "artifacts/build-info");
            const buildInfoFiles = fs.readdirSync(buildInfoDir).filter((f: string) => f.endsWith(".json"));
            const artifact = await hre.artifacts.readArtifact(opts.contractName);
            const sourceName = artifact.sourceName;

            for (const file of buildInfoFiles) {
                const buildInfo = JSON.parse(fs.readFileSync(path.join(buildInfoDir, file), "utf-8"));
                if (buildInfo.output?.contracts?.[sourceName]?.[opts.contractName]) {
                    if (buildInfo.solcLongVersion) {
                        fullCompiler = `v${buildInfo.solcLongVersion}`;
                    }
                    // Override settings from actual build-info input
                    const settings = buildInfo.input?.settings;
                    if (settings) {
                        if (settings.evmVersion) evmVersion = settings.evmVersion;
                        if (settings.optimizer != null) {
                            optimizer = settings.optimizer.enabled ?? optimizer;
                            optimizerRuns = settings.optimizer.runs ?? optimizerRuns;
                        }
                        if (settings.viaIR != null) viaIR = settings.viaIR ? "1" : "0";
                    }
                    break;
                }
            }
        } catch (e: any) {
            console.log(`[warn] could not read build-info: ${e.message}`);
        }
        if (!fullCompiler.includes("+commit.")) {
            console.log(`[error] could not determine full compiler version (got: ${fullCompiler}). Run 'npx hardhat compile' to generate build-info.`);
            printTronVerifyInfo(address, opts.contractName, fullCompiler, !!optimizer, optimizerRuns || 200, evmVersion || "london", flattenPath, chainId);
            return;
        }
        form.append("compiler", fullCompiler);
        form.append("license", "3"); // MIT
        form.append("optimizer", optimizer ? "1" : "0");
        form.append("runs", String(optimizerRuns ?? 200));
        form.append("viaIR", viaIR);
        form.append("evmVersion", evmVersion || "london");
        // Encode constructor params from ABI if not pre-encoded
        let constructorParams = opts.constructorParams || "";
        if (!constructorParams && opts.constructorArgs && opts.constructorArgs.length > 0) {
            const { Interface } = require("ethers");
            const artifact = await hre.artifacts.readArtifact(opts.contractName);
            const iface = new Interface(artifact.abi);
            const encoded = iface.encodeDeploy(opts.constructorArgs);
            constructorParams = encoded.slice(2); // remove 0x
        }
        form.append("constructorParams", constructorParams);
        form.append("files", fs.createReadStream(flattenPath), {
            filename: `${opts.contractName}.flat.tron.sol`,
            contentType: "application/octet-stream",
        });

        const result: any = await new Promise((resolve, reject) => {
            const url = new URL(apiUrl);
            const https = require("https");
            const req = https.request({
                hostname: url.hostname,
                path: url.pathname,
                method: "POST",
                headers: form.getHeaders(),
            }, (res: any) => {
                let data = "";
                res.on("data", (chunk: string) => data += chunk);
                res.on("end", () => {
                    try { resolve(JSON.parse(data)); } catch { resolve({ code: -1, errmsg: data }); }
                });
            });
            req.on("error", reject);
            form.pipe(req);
        });

        console.log(`TronScan raw response:`, JSON.stringify(result, null, 2));
        const status = result.data?.status;
        if ((result.code === 200 && (status === 200 || status === 2006)) || result.success) {
            console.log(`${opts.contractName} verified on TronScan`);
        } else {
            console.log(`verification failed (status: ${status}): ${result.data?.message || "unknown"}`);
            console.log(`  compiler: ${fullCompiler}, evmVersion: ${evmVersion}, optimizer: ${optimizer}, runs: ${optimizerRuns}, viaIR: ${viaIR}`);
            printTronVerifyInfo(address, opts.contractName, fullCompiler, optimizer, optimizerRuns, evmVersion, flattenPath, chainId);
        }
    } catch (e: any) {
        console.log(`TronScan API error: ${e.message || e}`);
        printTronVerifyInfo(address, opts.contractName, `v${compiler}`, optimizer, optimizerRuns, evmVersion, flattenPath, chainId);
    }
}

function printTronVerifyInfo(
    address: string, contractName: string, compiler: string,
    optimizer: boolean, runs: number, evmVersion: string,
    flattenPath: string, chainId: number
) {
    const isMainnet = chainId === 728126428;
    const tronscanUrl = isMainnet
        ? `https://tronscan.org/#/contract/${address}/code`
        : `https://nile.tronscan.org/#/contract/${address}/code`;

    console.log(`\n=== Verify manually on TronScan ===`);
    console.log(`Address:    ${address}`);
    console.log(`Contract:   ${contractName}`);
    console.log(`Compiler:   ${compiler}`);
    console.log(`Optimizer:  ${optimizer ? "enabled" : "disabled"}, runs: ${runs}`);
    console.log(`EVM:        ${evmVersion}`);
    console.log(`Flatten:    ${flattenPath}`);
    console.log(`URL:        ${tronscanUrl}`);
    console.log(`=====================================\n`);
}

function removeDuplicateSPDX(source: string): string {
    let found = false;
    return source.split("\n").filter(line => {
        if (line.includes("SPDX-License-Identifier")) {
            if (found) return false;
            found = true;
        }
        return true;
    }).join("\n");
}
