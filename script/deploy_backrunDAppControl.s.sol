// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "forge-std/Test.sol";

import { BackrunDAppControl } from "src/BackrunDAppControl.sol";
import { AtlasVerification } from "@atlas/atlas/AtlasVerification.sol";


contract DeployBackrunDAppControlScript is Test {
    function run() external {
        console.log("\n=== DEPLOYING Backrun DAPP CONTROL ===\n");

        uint256 deployerPrivateKey = vm.envUint("GOV_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deployer address: \t\t\t\t", deployer);

        address atlasAddress = vm.envAddress("ATLAS_ADDRESS");
        address atlasVerificationAddress = vm.envAddress("ATLAS_VERIFICATION_ADDRESS");
        address auctioneer = vm.envAddress("AUCTIONEER_ADDRESS");
        


        require(atlasAddress != address(0), "ATLAS_ADDRESS is not set");
        require(atlasVerificationAddress != address(0), "ATLAS_VERIFICATION_ADDRESS is not set");
        require(auctioneer != address(0), "AUCTIONEER_ADDRESS is not set");

        console.log("Using Atlas deployed at: \t\t\t", atlasAddress);
        console.log("Using Atlas Verification deployed at: \t", atlasVerificationAddress);
        console.log("Adding Auctioneer as whitelisted signatory: \t", auctioneer);
        console.log("\n");

        console.log("Deploying from deployer Account...");

        vm.startBroadcast(deployerPrivateKey);

        BackrunDAppControl backrunDAppControl = new BackrunDAppControl(atlasAddress, auctioneer, 1000);

        AtlasVerification(atlasVerificationAddress).initializeGovernance(address(backrunDAppControl));
        AtlasVerification(atlasVerificationAddress).addSignatory(address(backrunDAppControl), auctioneer);

        address ambientRouter = 0x88B96aF200c8a9c35442C8AC6cd3D22695AaE4F0; // Ambient
        address beanRouter = 0xCa810D095e90Daae6e867c19DF6D9A8C56db2c89; // Bean
        address atlantisRouter = 0x0000000000001fF3684f28c67538d4D072C22734; // Atlantis
        address bubblefiRouter = 0x0f2D067f8438869da670eFc855eACAC71616ca31; // Bubblefi
        address cloberRouter = 0xfD845859628946B317A78A9250DA251114FbD846; // Clober
        address octoswapRouter = 0x8B1fb7B1da49F111A2C0C11925D5bB86a2fab88E; // Octoswap
        
        //add routers
        backrunDAppControl.addRouter(ambientRouter);
        backrunDAppControl.addRouter(beanRouter);
        backrunDAppControl.addRouter(atlantisRouter);
        backrunDAppControl.addRouter(bubblefiRouter);
        backrunDAppControl.addRouter(octoswapRouter);
        backrunDAppControl.addRouter(cloberRouter);

        //check if routers are whitelisted
        require(backrunDAppControl.isRouterWhitelisted(ambientRouter), "Ambient router not whitelisted");
        require(backrunDAppControl.isRouterWhitelisted(beanRouter), "Bean router not whitelisted");
        require(backrunDAppControl.isRouterWhitelisted(atlantisRouter), "Atlantis router not whitelisted");
        require(backrunDAppControl.isRouterWhitelisted(bubblefiRouter), "Bubblefi router not whitelisted");
        require(backrunDAppControl.isRouterWhitelisted(octoswapRouter), "Octoswap router not whitelisted");
        require(backrunDAppControl.isRouterWhitelisted(cloberRouter), "Clober router not whitelisted");
        
        vm.stopBroadcast();

        console.log("Contracts deployed by deployer:");
        console.log("Backrun DAppControl: \t\t", address(backrunDAppControl));
        console.log("\n");
    }
}
