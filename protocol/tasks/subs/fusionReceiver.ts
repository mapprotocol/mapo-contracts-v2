import { task } from "hardhat/config";
import { getDeploymentByKey, verify, saveDeployment } from "../utils/utils"
import { FusionReceiver } from "../../typechain-types/contracts/len/FusionReceiver.sol";


task("FusionReceiver:deploy", "deploy FusionReceiver")
    .setAction(async (taskArgs, hre) => {
        const { network, ethers } = hre;
        const [deployer] = await ethers.getSigners();
        console.log("deployer address:", await deployer.getAddress())
        const FusionReceiverFactory = await ethers.getContractFactory("FusionReceiver");
        let authority = await getDeploymentByKey(network.name, "Authority");
        if(!authority || authority.length == 0) throw("authority not deploy");
        let relay = await getDeploymentByKey(network.name, "Relay");
        if(!relay || relay.length == 0) throw("relay not deploy");
        let impl = await(await FusionReceiverFactory.deploy()).waitForDeployment();
        let init_data = FusionReceiverFactory.interface.encodeFunctionData("initialize", [authority]);
        let ContractProxy = await ethers.getContractFactory("ERC1967Proxy");
        let c = await (await ContractProxy.deploy(impl, init_data)).waitForDeployment();
        console.log("FusionReceiver deploy to :", await c.getAddress());
        let f = FusionReceiverFactory.attach(await c.getAddress()) as FusionReceiver;
        await saveDeployment(network.name, "FusionReceiver", await c.getAddress());
        let mos = "0x0000317Bec33Af037b5fAb2028f52d14658F6A56";
        await (await f.set(mos, relay)).wait();
      // await verify(hre, await c.getAddress(), [await impl.getAddress(), init_data], "contracts/ERC1967Proxy.sol:ERC1967Proxy");
       await verify(hre, await impl.getAddress(), [], "contracts/len/FusionReceiver.sol:FusionReceiver");
});
