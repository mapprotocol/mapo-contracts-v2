import { task } from "hardhat/config";
import { getDeploymentByKey } from "../utils/utils"

// Minimal ABI shared by all contracts inheriting BaseImplementation.
// trigger() toggles the paused state; restricted to authorized roles.
const PAUSABLE_ABI = [
    "function paused() view returns (bool)",
    "function trigger() external",
];

// Resolve a deployed contract by name (key in deploy.json) into a Pausable handle.
async function attachPausable(hre: any, contractName: string) {
    const { network, ethers } = hre;
    let addr = await getDeploymentByKey(network.name, contractName);
    if (!addr || addr.length === 0) throw(`contract ${contractName} not deployed on ${network.name}`);
    return { addr, contract: await ethers.getContractAt(PAUSABLE_ABI, addr) };
}

task("pause:status", "show the paused state of a deployed contract")
    .addParam("contract", "contract name as in deploy.json (e.g. Relay, Gateway, VaultManager)")
    .setAction(async (taskArgs, hre) => {
        const { network } = hre;
        const { addr, contract } = await attachPausable(hre, taskArgs.contract);
        const isPaused = await contract.paused();
        console.log(`${taskArgs.contract} (${addr}) on ${network.name}: paused = ${isPaused}`);
    });

task("pause:set", "pause or unpause a deployed contract via trigger()")
    .addParam("contract", "contract name as in deploy.json (e.g. Relay, Gateway, VaultManager)")
    .addParam("paused", "desired paused state: true to pause, false to unpause")
    .setAction(async (taskArgs, hre) => {
        const { network, ethers } = hre;

        const desired = taskArgs.paused === "true";
        if (taskArgs.paused !== "true" && taskArgs.paused !== "false") {
            throw("--paused must be 'true' or 'false'");
        }

        const [deployer] = await ethers.getSigners();
        console.log("deployer address:", await deployer.getAddress());

        const { addr, contract } = await attachPausable(hre, taskArgs.contract);

        const current = await contract.paused();
        if (current === desired) {
            console.log(`${taskArgs.contract} (${addr}) already paused = ${current}, skipping`);
            return;
        }

        console.log(`${taskArgs.contract} (${addr}): paused ${current} -> ${desired}, calling trigger()...`);
        await(await contract.trigger()).wait();
        console.log(`after: paused = ${await contract.paused()}`);
    });
