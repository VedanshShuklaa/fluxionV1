// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {FluxionBrain} from "../src/reactive/FluxionBrain.sol";

contract DeployBrain is Script {

    // Hub chain (Sepolia) CHAIN ID
    uint64 constant CHAIN_SEPOLIA = 11155111;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address hub = vm.envAddress("HUB_ADDR");

        vm.startBroadcast(pk);

        FluxionBrain brain = new FluxionBrain(
            CHAIN_SEPOLIA,
            hub,
            1e4 // minLiquidityBuffer (demo-friendly)
        );
        

        console.log("BRAIN_ADDR:", address(brain));
        console.log("HUB_ADDR:", hub);
        console.log("DEPLOYMENT COMPLETE");
        console.log("Brain deployed at:", address(brain));
        console.log("Hub configured at:", hub);

        vm.stopBroadcast();
    }
}
