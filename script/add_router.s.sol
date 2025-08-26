// // SPDX-License-Identifier: UNLICENSED
// pragma solidity 0.8.28;

// import "forge-std/Script.sol";
// import "forge-std/Test.sol";

// import { BackrunDAppControl } from "src/BackrunDAppControl.sol";
// import { AtlasVerification } from "@atlas/atlas/AtlasVerification.sol";

// contract DeployBackrunDAppControlScript is Test {
//     function run() external {
//         console.log("\n=== DEPLOYING Backrun DAPP CONTROL ===\n");

//         uint256 deployerPrivateKey = vm.envUint("GOV_PRIVATE_KEY");
//         address deployer = vm.addr(deployerPrivateKey);

//         console.log("Deployer address: \t\t\t\t", deployer);

//         address atlasAddress = vm.envAddress("ATLAS_ADDRESS");
//         address atlasVerificationAddress = vm.envAddress("ATLAS_VERIFICATION_ADDRESS");
//         address auctioneer = vm.envAddress("AUCTIONEER_ADDRESS");

//         require(atlasAddress != address(0), "ATLAS_ADDRESS is not set");
//         require(atlasVerificationAddress != address(0), "ATLAS_VERIFICATION_ADDRESS is not set");
//         require(auctioneer != address(0), "AUCTIONEER_ADDRESS is not set");

//         console.log("Using Atlas deployed at: \t\t\t", atlasAddress);
//         console.log("Using Atlas Verification deployed at: \t", atlasVerificationAddress);
//         console.log("Adding Auctioneer as whitelisted signatory: \t", auctioneer);
//         console.log("\n");

//         console.log("Deploying from deployer Account...");

//         vm.startBroadcast(deployerPrivateKey);

//         BackrunDAppControl backrunDAppControl =  BackrunDAppControl(payable(0x26E07BA2c7074A06AEAb50403Dd535F627A2c5D6));

//         address SWAP_ROUTER = 0xB953485c5e24facf79f20Cb36454680bc387bB2c;
//         backrunDAppControl.addRouter(SWAP_ROUTER, 1); // 2 = ROUTER_TYPE_DIRECT
//         uint8 isRouterWhitelisted = backrunDAppControl.isRouterWhitelisted(SWAP_ROUTER);
//         console.log("isRouterWhitelisted", isRouterWhitelisted);

//         vm.stopBroadcast();

//         console.log("Contracts deployed by deployer:");
//         console.log("Backrun DAppControl: \t\t", address(backrunDAppControl));
//         console.log("\n");
//     }
// }
