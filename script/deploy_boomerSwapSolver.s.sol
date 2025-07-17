// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import "../src/BoomerSwapSolver.sol";

contract DeployBoomerSwapSolverScript is Script {
    function run() external {
        console.log("\n=== DEPLOYING BoomerSwapSolver ===\n");

        uint256 deployerPrivateKey = vm.envUint("SOLVER1_PRIVATE_KEY");
        address atlas = vm.envAddress("ATLAS_ADDRESS");
        address shmonad = vm.envAddress("SHMONAD_ADDRESS");
        address deployer = vm.addr(deployerPrivateKey);

        address wethAddress = vm.envAddress("WETH_ADDRESS");

        console.log("===============================");
        console.log("Deploying BoomerSwapSolver...");
        console.log("Atlas address:", atlas);
        console.log("Shmonad address:", shmonad);
        console.log("Deployer address:", deployer);
        console.log("WETH address:", wethAddress);
        console.log("===============================");

        vm.startBroadcast(deployerPrivateKey);

        BoomerSwapSolver solver = new BoomerSwapSolver(
            wethAddress,
            atlas,
            shmonad
        );

        console.log("BoomerSwapSolver deployed to:", address(solver));

        vm.stopBroadcast();
    }
}
