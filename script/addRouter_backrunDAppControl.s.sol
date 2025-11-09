// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "forge-std/Test.sol";

import { BackrunDAppControl } from "src/BackrunDAppControl.sol";

contract AddRouterBackrunDAppControlScript is Test {
    function run() external {
        console.log("\n=== ADDING ROUTER TO BACKRUN DAPP CONTROL ===\n");

        // Support both private key and Ledger deployment
        uint256 deployerPrivateKey;
        address deployer;

        // Check if using Ledger (DEPLOYER_PRIVATE_KEY not set or empty)
        try vm.envUint("DEPLOYER_PRIVATE_KEY") returns (uint256 key) {
            deployerPrivateKey = key;
            deployer = vm.addr(deployerPrivateKey);
        } catch {
            // Ledger mode - get deployer address from environment or use msg.sender
            deployer = vm.envOr("LEDGER_ADDRESS", msg.sender);
            deployerPrivateKey = 0; // Not used with Ledger
        }

        console.log("Deployer address: \t\t\t\t", deployer);

        address backrunDAppControlAddress = vm.envAddress("BACKRUN_DAPP_CONTROL_ADDRESS");
        require(backrunDAppControlAddress != address(0), "BACKRUN_DAPP_CONTROL_ADDRESS is not set");

        console.log("Using Backrun DAppControl at: \t\t", backrunDAppControlAddress);
        console.log("\n");

        BackrunDAppControl backrunDAppControl = BackrunDAppControl(payable(backrunDAppControlAddress));

        address routerToAdd = vm.envAddress("ROUTER_TO_ADD");
        require(routerToAdd != address(0), "ROUTER_TO_ADD is not set");

        console.log("Router to add: \t\t\t\t", routerToAdd);

        // Start broadcast - use deployer address for Ledger, private key otherwise
        if (deployerPrivateKey == 0) {
            console.log("Broadcasting from Ledger Account...");
            vm.startBroadcast(deployer);
        } else {
            console.log("Broadcasting from deployer Account...");
            vm.startBroadcast(deployerPrivateKey);
        }

        // Add router
        backrunDAppControl.addRouter(routerToAdd, 1);

        // Check if router is whitelisted
        require(backrunDAppControl.isRouterWhitelisted(routerToAdd) != 0, "Router not whitelisted");

        vm.stopBroadcast();

        console.log("\nRouter successfully added to Backrun DAppControl at:", backrunDAppControlAddress);
        console.log("\n");
    }
}
