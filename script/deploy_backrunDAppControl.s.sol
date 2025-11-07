// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "forge-std/Test.sol";

import { BackrunDAppControl } from "src/BackrunDAppControl.sol";
import { AtlasVerification } from "@atlas/atlas/AtlasVerification.sol";

contract DeployBackrunDAppControlScript is Test {
    function run() external {
        console.log("\n=== DEPLOYING Backrun DAPP CONTROL ===\n");

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

        address atlasAddress = vm.envAddress("ATLAS_ADDRESS");
        address atlasVerificationAddress = vm.envAddress("ATLAS_VERIFICATION_ADDRESS");
        address auctioneer = vm.envAddress("AUCTIONEER_ADDRESS");
        address govPayoutAddr = vm.envAddress("GOV_PAYOUT_ADDRESS");

        require(atlasAddress != address(0), "ATLAS_ADDRESS is not set");
        require(atlasVerificationAddress != address(0), "ATLAS_VERIFICATION_ADDRESS is not set");
        require(auctioneer != address(0), "AUCTIONEER_ADDRESS is not set");
        require(govPayoutAddr != address(0), "GOV_PAYOUT_ADDRESS is not set");

        console.log("Using Atlas deployed at: \t\t\t", atlasAddress);
        console.log("Using Atlas Verification deployed at: \t", atlasVerificationAddress);
        console.log("Adding Auctioneer as whitelisted signatory: \t", auctioneer);
        console.log("Using Governance Payout Address: \t\t", govPayoutAddr);
        console.log("\n");

        // Start broadcast - use deployer address for Ledger, private key otherwise
        if (deployerPrivateKey == 0) {
            console.log("Deploying from Ledger Account...");
            vm.startBroadcast(deployer);
        } else {
            console.log("Deploying from deployer Account...");
            vm.startBroadcast(deployerPrivateKey);
        }

        BackrunDAppControl backrunDAppControl = new BackrunDAppControl(atlasAddress, govPayoutAddr, 1000);

        AtlasVerification(atlasVerificationAddress).initializeGovernance(address(backrunDAppControl));
        AtlasVerification(atlasVerificationAddress).addSignatory(address(backrunDAppControl), auctioneer);

        vm.stopBroadcast();

        console.log("Contracts deployed by deployer:");
        console.log("Backrun DAppControl: \t\t", address(backrunDAppControl));
        console.log("\n");
    }
}
