// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "forge-std/Test.sol";

import { BackrunDAppControl } from "src/BackrunDAppControl.sol";
import { AtlasVerification } from "@atlas/atlas/AtlasVerification.sol";
import { IShMonad } from "src/interfaces/IShMonad.sol";

contract DeployBackrunDAppControlScript is Test {
    function run() external {
        console.log("\n=== DEPLOYING Backrun DAPP CONTROL ===\n");

        uint256 deployerPrivateKey = vm.envUint("GOV_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deployer address: \t\t\t\t", deployer);

        address atlasAddress = vm.envAddress("ATLAS_ADDRESS");
        address atlasVerificationAddress = vm.envAddress("ATLAS_VERIFICATION_ADDRESS");
        address auctioneer = vm.envAddress("AUCTIONEER_ADDRESS");
        address shMonadAddress = vm.envAddress("SHMONAD_ADDRESS");

        IShMonad shMonad = IShMonad(shMonadAddress);

        require(atlasAddress != address(0), "ATLAS_ADDRESS is not set");
        require(atlasVerificationAddress != address(0), "ATLAS_VERIFICATION_ADDRESS is not set");
        require(auctioneer != address(0), "AUCTIONEER_ADDRESS is not set");
        require(shMonadAddress != address(0), "SHMONAD_ADDRESS is not set");

        console.log("Using Atlas deployed at: \t\t\t", atlasAddress);
        console.log("Using Atlas Verification deployed at: \t", atlasVerificationAddress);
        console.log("Adding Auctioneer as whitelisted signatory: \t", auctioneer);
        console.log("\n");

        console.log("Deploying from deployer Account...");

        vm.startBroadcast(deployerPrivateKey);

        (uint64 policyId, ) = shMonad.createPolicy(10);
        console.log("policyId", policyId);
        console.log("owner", shMonad.owner());
        shMonad.depositAndBond{value: 10 ether}(policyId, deployer, type(uint256).max);

        // BackrunDAppControl backrunDAppControl = BackrunDAppControl(0x874daAdd2C6253f94fDeA28b4F8d904F470165a4);
        BackrunDAppControl backrunDAppControl = new BackrunDAppControl(shMonadAddress, atlasAddress, auctioneer, 1000, policyId);

        AtlasVerification(atlasVerificationAddress).initializeGovernance(address(backrunDAppControl));
        AtlasVerification(atlasVerificationAddress).addSignatory(address(backrunDAppControl), auctioneer);

        address SWAP_ROUTER1 = 0x88B96aF200c8a9c35442C8AC6cd3D22695AaE4F0; // Uniswap V2 Router
        address SWAP_ROUTER2 = 0xCa810D095e90Daae6e867c19DF6D9A8C56db2c89; // Uniswap V2 Router
        backrunDAppControl.addRouter(SWAP_ROUTER1);
        backrunDAppControl.addRouter(SWAP_ROUTER2);
        bool isRouterWhitelisted = backrunDAppControl.isRouterWhitelisted(SWAP_ROUTER1);
        console.log("isRouterWhitelisted", isRouterWhitelisted);
        isRouterWhitelisted = backrunDAppControl.isRouterWhitelisted(SWAP_ROUTER2);
        console.log("isRouterWhitelisted", isRouterWhitelisted);

        // shMonad.transferOwnership(payable(address(backrunDAppControl)));

        vm.stopBroadcast();

        console.log("Contracts deployed by deployer:");
        console.log("Backrun DAppControl: \t\t", address(backrunDAppControl));
        console.log("\n");
    }
}
