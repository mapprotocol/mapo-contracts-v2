let TronWeb = require("tronweb");



export async function tronDeploy(contractName:string, args:any[], artifacts:any, network:string) {
  let c = await artifacts.readArtifact(contractName);
  let tronWeb = await getTronWeb(network);
  console.log("deploy address is:", tronWeb.defaultAddress);
  let contract_instance = await tronWeb.contract().new({
    abi: c.abi,
    bytecode: c.bytecode,
    feeLimit: 15000000000,
    callValue: 0,
    parameters: args,
  });
  let contract_address = tronWeb.address.fromHex(contract_instance.address);
  console.log(`${contractName} deployed on: ${contract_address} (${contract_instance.address})`);
  return "0x" + contract_instance.address.substring(2);
}

export async function getTronDeployer(hex:boolean, network:string) {
  let tronWeb = await getTronWeb(network);
  if (hex) {
    return tronWeb.defaultAddress.hex.replace(/^(41)/, "0x");
  } else {
    return tronWeb.defaultAddress;
  }
}


export async function tronFromHex(hex:string, network:string) {
  if (hex.startsWith('T') && hex.length === 34) return hex;
  let tronWeb = await getTronWeb(network);
  return tronWeb.address.fromHex(hex);
}

export async function tronToHex(addr:string, network:string) {
  if(addr.startsWith("0x") && addr.length === 42) return addr;
  let tronWeb = await getTronWeb(network);
  return tronWeb.address.toHex(addr).replace(/^(41)/, "0x");
}


export async function getTronContract(contractName:string, artifacts:any, network:string, addr:string) {
  let tronWeb = await getTronWeb(network);
  console.log("operator address is:", tronWeb.defaultAddress);
  let C = await artifacts.readArtifact(contractName);
  let c = await tronWeb.contract(C.abi, addr);
  return c;
}


export async function getTronWeb(network:string) {
  if (network === "Tron" || network === "tron_test") {
    if (network === "Tron") {
      return new TronWeb({
        fullHost: process.env.TRON_RPC_URL,
        // solidityNode: "https://api.trongrid.io/",
        // eventServer: "https://api.trongrid.io/",
        privateKey: process.env.TRON_PRIVATE_KEY
      });
    } else {
      return new TronWeb(
        "https://api.nileex.io/",
        "https://api.nileex.io/",
        "https://api.nileex.io/",
        process.env.TRON_PRIVATE_KEY,
      );
    }
  } else {
    throw "unsupport network";
  }
}