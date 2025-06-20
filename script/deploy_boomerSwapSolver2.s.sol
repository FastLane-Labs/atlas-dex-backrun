// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import "../src/BoomerSwapSolver2.sol";

contract DeployBoomerSwapSolver2Script is Script {
    function run() external {
        console.log("\n=== DEPLOYING BoomerSwapSolver2 ===\n");

        uint256 deployerPrivateKey = vm.envUint("SOLVER1_PRIVATE_KEY");
        address atlas = vm.envAddress("ATLAS_ADDRESS");
        address deployer = vm.addr(deployerPrivateKey);

        address wethAddress = vm.envAddress("WETH_ADDRESS");

        console.log("===============================");
        console.log("Deploying BoomerSwapSolver2...");
        console.log("Deployer address:", deployer);
        console.log("WETH address:", wethAddress);
        console.log("===============================");

        vm.startBroadcast(deployerPrivateKey);

        BoomerSwapSolver2 solver = new BoomerSwapSolver2(
            wethAddress,
            atlas
        );

        console.log("BoomerSwapSolver2 deployed to:", address(solver));

        vm.stopBroadcast();
    }
}
