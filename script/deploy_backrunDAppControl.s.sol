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

        // address ambientRouter = 0x88B96aF200c8a9c35442C8AC6cd3D22695AaE4F0; // Ambient
        // address beanRouter = 0xCa810D095e90Daae6e867c19DF6D9A8C56db2c89; // Bean
        // address atlantisRouter = 0x0000000000001fF3684f28c67538d4D072C22734; // Atlantis
        // address bubblefiRouter = 0x0f2D067f8438869da670eFc855eACAC71616ca31; // Bubblefi
        // address cloberRouter = 0xfD845859628946B317A78A9250DA251114FbD846; // Clober
        // address octoswapRouter = 0x8B1fb7B1da49F111A2C0C11925D5bB86a2fab88E; // Octoswap
        // address monorailRouter = 0x525B929fCd6a64AfF834f4eeCc6E860486cED700; // Monorail
        // address nitroRouter = 0xFF5DDCF0774006C9B263858F1ad11962bAaaE41C; // Nitro
        // address zkSwapRouter = 0xcF9FB929FA29eC1C1A216717200232c5B0C3d744; // ZKSwap
        // address swyrlRouter = 0xB953485c5e24facf79f20Cb36454680bc387bB2c; // Swyrl

        
        // //add routers
        // backrunDAppControl.addRouter(ambientRouter, 1);
        // backrunDAppControl.addRouter(beanRouter, 1);
        // backrunDAppControl.addRouter(atlantisRouter, 1);
        // backrunDAppControl.addRouter(bubblefiRouter, 1);
        // backrunDAppControl.addRouter(octoswapRouter, 2);
        // backrunDAppControl.addRouter(cloberRouter, 1);
        // backrunDAppControl.addRouter(monorailRouter, 1);
        // backrunDAppControl.addRouter(nitroRouter, 1);
        // backrunDAppControl.addRouter(zkSwapRouter, 1);
        // backrunDAppControl.addRouter(swyrlRouter, 1);
        // //check if routers are whitelisted
        // require(backrunDAppControl.isRouterWhitelisted(ambientRouter) != 0, "Ambient router not whitelisted");
        // require(backrunDAppControl.isRouterWhitelisted(beanRouter) != 0, "Bean router not whitelisted");
        // require(backrunDAppControl.isRouterWhitelisted(atlantisRouter) != 0, "Atlantis router not whitelisted");
        // require(backrunDAppControl.isRouterWhitelisted(bubblefiRouter) != 0, "Bubblefi router not whitelisted");
        // require(backrunDAppControl.isRouterWhitelisted(octoswapRouter) != 0, "Octoswap router not whitelisted");
        // require(backrunDAppControl.isRouterWhitelisted(cloberRouter) != 0, "Clober router not whitelisted");
        // require(backrunDAppControl.isRouterWhitelisted(monorailRouter) != 0, "Monorail router not whitelisted");
        // require(backrunDAppControl.isRouterWhitelisted(nitroRouter) != 0, "Nitro router not whitelisted");
        // require(backrunDAppControl.isRouterWhitelisted(zkSwapRouter) != 0, "ZKSwap router not whitelisted");
        // require(backrunDAppControl.isRouterWhitelisted(swyrlRouter) != 0, "Swyrl router not whitelisted");
        
        vm.stopBroadcast();

        console.log("Contracts deployed by deployer:");
        console.log("Backrun DAppControl: \t\t", address(backrunDAppControl));
        console.log("\n");
    }
}
