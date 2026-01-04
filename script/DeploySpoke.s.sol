// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {FluxionExecutor} from "../src/spoke/FluxionExecutor.sol";
import {MockAdapter} from "../src/spoke/adapters/MockAdapter.sol";
import {MockLendingPool} from "../src/mocks/MockLendingPool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DeploySpoke is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        
        // Configuration from Environment
        uint64 hubSel = uint64(vm.envUint("HUB_SELECTOR"));
        address hubAddr = vm.envAddress("HUB_ADDR");
        address router = vm.envAddress("SPOKE_ROUTER_AMOY");
        address officialUsdc = vm.envAddress("USDC_AMOY"); // Use the CCIP USDC address
        uint256 initialApy = 8; 

        vm.startBroadcast(pk);

        // 1. Deploy the "Authentic" Mock Pool (Using official USDC as the underlying)
        // Rate is RAY-scaled (e.g., 5% = 0.05 * 10^27)
        MockLendingPool pool = new MockLendingPool(officialUsdc, initialApy * 10**25); 
        
        // 2. Deploy Executor pointing to Hub & Official USDC (only deploy once per chain)
        // FluxionExecutor exec = new FluxionExecutor(
        //     router, 
        //     hubAddr, 
        //     hubSel, 
        //     officialUsdc
        // );

        // 3. Deploy Adapter
        MockAdapter adapt = new MockAdapter(address(pool), officialUsdc);

        // 4. Funding the Executor for CCIP Fees
        // The Executor pays the fee when sending tokens BACK to the Hub.
        payable(address(0xB5Eff5BA8EaAbaAfEb1a631Ee0d504D5dDeb8549)).transfer(0.1 ether);

        console.log("--- SPOKE DEPLOYED ---");
        // console.log("EXECUTOR:", address(exec));
        console.log("ADAPTER:", address(adapt));
        console.log("POOL:", address(pool));
        console.log("USING_USDC:", officialUsdc);
        console.log("----------------------");

        vm.stopBroadcast();
    }
}