import { task } from "hardhat/config";
import { getDeploymentByKey, verify, saveDeployment } from "../utils/utils"
import { FusionQuoter } from "../../typechain-types/contracts/len/FusionQuoter.sol";

task("FusionQuoter:deploy", "deploy FusionQuoter")
    .setAction(async (taskArgs, hre) => {
        const { network, ethers } = hre;
        const [deployer] = await ethers.getSigners();
        console.log("deployer address:", await deployer.getAddress())
        const FusionQuoterFactory = await ethers.getContractFactory("FusionQuoter");
        let authority = await getDeploymentByKey(network.name, "Authority");
        if(!authority || authority.length == 0) throw("authority not deploy");
        let viewController = await getDeploymentByKey(network.name, "ViewController");
        if(!viewController || viewController.length == 0) throw("viewController not deploy");
        let fusionReceiver = await getDeploymentByKey(network.name, "FusionReceiver");
        if(!fusionReceiver || fusionReceiver.length == 0) throw("FusionReceiver not deploy");
        let impl = await(await FusionQuoterFactory.deploy()).waitForDeployment();
        let init_data = FusionQuoterFactory.interface.encodeFunctionData("initialize", [authority]);
        let ContractProxy = await ethers.getContractFactory("ERC1967Proxy");
        let c = await (await ContractProxy.deploy(impl, init_data)).waitForDeployment();
        console.log("FusionQuoter deploy to :", await c.getAddress());
        let f = FusionQuoterFactory.attach(await c.getAddress()) as FusionQuoter;
        await saveDeployment(network.name, "FusionQuoter", await c.getAddress());
        let butterQuoter = "0x3970C07653C0f87B4e33524c9c7B6bea3dACB3f9";
        await (await f.set(fusionReceiver, viewController, butterQuoter)).wait();
      // await verify(hre, await c.getAddress(), [await impl.getAddress(), init_data], "contracts/ERC1967Proxy.sol:ERC1967Proxy");
       await verify(hre, await impl.getAddress(), [], "contracts/len/FusionQuoter.sol:FusionQuoter");
});