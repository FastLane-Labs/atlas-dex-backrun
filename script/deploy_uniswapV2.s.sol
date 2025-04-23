// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "forge-std/Test.sol";

import { UniswapV2DAppControl } from "src/UniswapV2DAppControl.sol";
import { AtlasVerification } from "@atlas/atlas/AtlasVerification.sol";

contract DeployUniswapV2DAppControlScript is Test {
    function run() external {
        console.log("\n=== DEPLOYING UniswapV2 DAPP CONTROL ===\n");

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

        UniswapV2DAppControl uniswapV2DAppControl = new UniswapV2DAppControl(
            atlasAddress, // Atlas
            address(0), // Bid token, ETH
            deployer, // Governance payout address
            1000, // Governance percent (bps)
            1e9 // Minimum bid threshold
        );

        AtlasVerification(atlasVerificationAddress).initializeGovernance(address(uniswapV2DAppControl));
        AtlasVerification(atlasVerificationAddress).addSignatory(address(uniswapV2DAppControl), auctioneer);

        vm.stopBroadcast();

        console.log("Contracts deployed by deployer:");
        console.log("UniswapV2 DAppControl: \t\t", address(uniswapV2DAppControl));
        console.log("\n");
    }
}
