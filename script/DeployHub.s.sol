// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {FluxionVault} from "../src/hub/FluxionVault.sol";
import {PoolRegistry} from "../src/hub/PoolRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DeployHub is Script {
    // OFFICIAL CCIP ADDRESSES (Sepolia)
    address constant ROUTER_SEPOLIA = 0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59;
    address constant USDC_SEPOLIA = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        address deployer = vm.addr(pk);

        // 1. Deploy Registry
        PoolRegistry registry = new PoolRegistry(deployer);
        
        // 2. Deploy Vault using Official USDC
        FluxionVault vault = new FluxionVault(
            IERC20(USDC_SEPOLIA), 
            "Fluxion Vault", 
            "FLUX", 
            ROUTER_SEPOLIA, 
            address(registry), 
            deployer
        );

        // 3. Setup Roles
        // We grant BALANCER_ROLE to deployer so you can manually adjust state if needed
        vault.grantRole(vault.BALANCER_ROLE(), deployer);
        
        // 4. Funding for CCIP Fees
        // The Vault needs ETH to pay for the outgoing CCIP messages (Recalls/Pushes)
        (bool ok,) = address(vault).call{value: 0.1 ether}("");
        require(ok, "ETH funding failed");
        console.log("Vault funded with 0.1 ETH for CCIP operations");

        console.log("--- DEPLOYMENT COMPLETE ---");
        console.log("VAULT_ADDRESS:", address(vault));
        console.log("REGISTRY_ADDRESS:", address(registry));
        console.log("ASSET_USDC:", USDC_SEPOLIA);
        console.log("---------------------------");
        console.log("Next: Add Pools to Registry, then Deploy Brain.");

        vm.stopBroadcast();
    }
}