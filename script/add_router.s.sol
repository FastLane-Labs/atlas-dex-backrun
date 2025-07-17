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

        BackrunDAppControl backrunDAppControl =  BackrunDAppControl(payable(0x9d5b348112071c4c1E6095eAeCbf6e12c88F8381));

        address SWAP_ROUTER = 0x8B1fb7B1da49F111A2C0C11925D5bB86a2fab88E;
        // address SWAP_ROUTER2 = 0x0f2D067f8438869da670eFc855eACAC71616ca31; 
        backrunDAppControl.addRouter(SWAP_ROUTER);
        // backrunDAppControl.addRouter(SWAP_ROUTER2);
        bool isRouterWhitelisted = backrunDAppControl.isRouterWhitelisted(SWAP_ROUTER);
        console.log("isRouterWhitelisted", isRouterWhitelisted);
        // isRouterWhitelisted = backrunDAppControl.isRouterWhitelisted(SWAP_ROUTER2);
        // console.log("isRouterWhitelisted", isRouterWhitelisted);

        vm.stopBroadcast();

        console.log("Contracts deployed by deployer:");
        console.log("Backrun DAppControl: \t\t", address(backrunDAppControl));
        console.log("\n");
    }
}
