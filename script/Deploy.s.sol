// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script, console} from "forge-std/Script.sol";
import {Factory} from "../contracts/core/Factory.sol";
import {Router} from "../contracts/periphery/Router.sol";
import {TreasuryAndFees} from "../contracts/core/TreasuryAndFees.sol";

contract DeployScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        Factory factory = new Factory();
        Router router = new Router(address(factory));
        TreasuryAndFees treasury = new TreasuryAndFees();

        console.log("Factory deployed at:", address(factory));
        console.log("Router deployed at:", address(router));
        console.log("Treasury deployed at:", address(treasury));

        vm.stopBroadcast();
    }
}
