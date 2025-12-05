// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BaseScript, console} from "./Base.s.sol";
import {Maintainers} from "../../contracts/Maintainers.sol";
import {Parameters} from "../../contracts/Parameters.sol";
import {TSSManager} from "../../contracts/TSSManager.sol";


contract DeployAndSetUp is BaseScript {
     
    function run() public virtual broadcast {
          // deploy();
          set();
    } 

    function deploy() internal returns (Parameters parameters, Maintainers maintainers, TSSManager manager) {
        string memory networkName = getNetworkName();
        address authority = readConfigAddr(networkName, "Authority");
        console.log("Authority address:", authority);
        parameters = deployParameters(networkName, authority);
        maintainers = deployMaintainer(networkName, authority);
        manager = deployTSSManager(networkName, authority);
    }

    function set() internal {
        string memory networkName = getNetworkName();
        setUp(networkName);
        setUpParameters(networkName);
    }

   function deployMaintainer(string memory networkName, address authority) internal returns(Maintainers maintainers) {
        Maintainers impl = new Maintainers();
        bytes memory initData = abi.encodeWithSelector(Maintainers.initialize.selector, authority);
        address m = deployProxy(address(impl), initData);
        maintainers = Maintainers(payable(m));

        console.log("Maintainers address:", m);
        saveConfig(networkName, "Maintainers", m);
   }

   function deployParameters(string memory networkName, address authority) internal returns(Parameters parameters) {
        Parameters impl = new Parameters();
        bytes memory initData = abi.encodeWithSelector(Parameters.initialize.selector, authority);
        address p = deployProxy(address(impl), initData);
        parameters = Parameters(p);

        console.log("parameters address:", p);
        saveConfig(networkName, "Parameters", p);
   }

    function deployTSSManager(string memory networkName, address authority) internal returns(TSSManager manager) {
        TSSManager impl = new TSSManager();
        bytes memory initData = abi.encodeWithSelector(TSSManager.initialize.selector, authority);
        address m = deployProxy(address(impl), initData);
        manager = TSSManager(m);

        console.log("TSSManager address:", m);
        saveConfig(networkName, "TSSManager", m);
   }

   function setUp(string memory networkName) internal {
        address maintainer_addr = readConfigAddr(networkName, "Maintainers");
        console.log("Maintainers address:", maintainer_addr);
        address manager_addr = readConfigAddr(networkName, "TSSManager");
        console.log("TSSManager address:", manager_addr);
        address parameters_addr = readConfigAddr(networkName, "Parameters");
        console.log("Parameters address:", parameters_addr);
        address relay_addr = readConfigAddr(networkName, "Relay");
        console.log("Relay address:", relay_addr);

        Maintainers m = Maintainers(payable(maintainer_addr));
        m.set(manager_addr, parameters_addr);

        TSSManager t = TSSManager(manager_addr);
        t.set(maintainer_addr, relay_addr, parameters_addr);
   }

    struct Config {
        string key;
        uint256 value;
    }

   function setUpParameters(string memory networkName) internal {
          address parameters_addr = readConfigAddr(networkName, "Parameters");
          Parameters p = Parameters(parameters_addr);
          string memory json = vm.readFile("config/parameters.json");
          bytes memory data = vm.parseJson(json);
          Config[] memory configs = abi.decode(data, (Config[]));
          for (uint i = 0; i < configs.length; i++) {
               console.log("Key: %s, Value: %s", configs[i].key, configs[i].value);
               p.set(configs[i].key, configs[i].value);
          }
   }

   function upgrade(string memory c) internal {
          string memory networkName = getNetworkName();
          if(keccak256(bytes(c)) == keccak256(bytes("Parameters"))){
               address parameters_addr = readConfigAddr(networkName, "Parameters");
               Parameters p = Parameters(parameters_addr);
               Parameters impl = new Parameters();
               p.upgradeToAndCall(address(impl), bytes(""));
          } else if(keccak256(bytes(c)) == keccak256(bytes("Maintainers"))) {
               address Maintainers_addr = readConfigAddr(networkName, "Maintainers");
               Maintainers maintainer = Maintainers(payable(Maintainers_addr));
               Maintainers impl = new Maintainers();
               maintainer.upgradeToAndCall(address(impl), bytes(""));
          } else {
               address manager_addr = readConfigAddr(networkName, "TSSManager");
               TSSManager manager = TSSManager(manager_addr);
               TSSManager impl = new TSSManager();
               manager.upgradeToAndCall(address(impl), bytes(""));
          }
   } 

   function updateMaintainerLimit(uint256 limit) internal {
          string memory networkName = getNetworkName();
          address Maintainers_addr = readConfigAddr(networkName, "Maintainers");
          Maintainers maintainer = Maintainers(payable(Maintainers_addr));
          maintainer.updateMaintainerLimit(limit);
   }
}