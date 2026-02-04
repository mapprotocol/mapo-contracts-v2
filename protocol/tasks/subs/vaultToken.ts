import { task } from "hardhat/config";
import { VaultToken } from "../../typechain-types/contracts"
import { getDeploymentByKey, verify } from "../utils/utils"

task("vaultToken:deploy", "deploy vault token")
    .addParam("token", "asset address")
    .addParam("name", "vault token name")
    .addParam("symbol", "vault token symbol")
    .setAction(async (taskArgs, hre) => {
        const { network, ethers } = hre;
        const [deployer] = await ethers.getSigners();
        console.log("deployer address:", await deployer.getAddress())
        const VaultTokenFactory = await ethers.getContractFactory("VaultToken");
        let authority = await getDeploymentByKey(network.name, "Authority");
        if(!authority || authority.length == 0) throw("authority not deploy");
        let vaultManager = await getDeploymentByKey(network.name, "VaultManager");
        if(!vaultManager || vaultManager.length == 0) throw("vaultManager not deploy");

        let impl = await(await VaultTokenFactory.deploy()).waitForDeployment();
        let init_data = VaultTokenFactory.interface.encodeFunctionData("initialize", [authority, taskArgs.token, taskArgs.name, taskArgs.symbol]);
        let ContractProxy = await ethers.getContractFactory("ERC1967Proxy");
        let c = await (await ContractProxy.deploy(await impl.getAddress(), init_data)).waitForDeployment();
        console.log("vaultToken deploy to :", await c.getAddress());

        let v = VaultTokenFactory.attach(await c.getAddress()) as VaultToken;
        console.log("pre vaultManager address is: ", await v.vaultManager());
        await (await v.setVaultManager(vaultManager)).wait()
        console.log("after vaultManager address is: ", await v.vaultManager());
    //    await verify(hre, await c.getAddress(), [await impl.getAddress(), init_data], "contracts/ERC1967Proxy.sol:ERC1967Proxy");
        await verify(hre, await impl.getAddress(), [], "contracts/VaultToken.sol:VaultToken");
    });



task("vaultToken:upgrapde", "upgrapde vault token contract")
    .addParam("addr", "vault token address")
    .setAction(async (taskArgs, hre) => {
        const { network, ethers } = hre;
        const [deployer] = await ethers.getSigners();
        console.log("deployer address:", await deployer.getAddress())
        const VaultTokenFactory = await ethers.getContractFactory("VaultToken");
        let impl = await(await VaultTokenFactory.deploy()).waitForDeployment();
        let v = VaultTokenFactory.attach(taskArgs.addr) as VaultToken;
        console.log("pre impl address is:", await v.getImplementation())
        await(await v.upgradeToAndCall(await impl.getAddress(), "0x")).wait()
        console.log("pre impl address is:", await v.getImplementation())
        await verify(hre, await impl.getAddress(), [], "/contracts/VaultToken.sol:VaultToken");
    })


task("vaultToken:setVaultManager", "set Vault Manager address")
    .addParam("addr", "vault token address")
    .setAction(async (taskArgs, hre) => {
        const { network, ethers } = hre;
        const [deployer] = await ethers.getSigners();
        console.log("deployer address:", await deployer.getAddress())
        const VaultTokenFactory = await ethers.getContractFactory("VaultToken");
        let v = VaultTokenFactory.attach(taskArgs.addr) as VaultToken;
        let vaultManager = await getDeploymentByKey(network.name, "VaultManager");
        if(!vaultManager || vaultManager.length == 0) throw("vaultManager not deploy");
        console.log("pre vaultManager address is: ", await v.vaultManager());
        await (await v.setVaultManager(vaultManager)).wait()
        console.log("after vaultManager address is: ", await v.vaultManager());
    })
