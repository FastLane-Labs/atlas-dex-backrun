// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "forge-std/Test.sol";

import { UniswapV2DAppControl } from "src/UniswapV2DAppControl.sol";
import { AtlasVerification } from "@atlas/atlas/AtlasVerification.sol";

contract DeployUniswapV2DAppControlScript is Test {
    function run() external {
        console.log("\n=== DEPLOYING UniswapV2 DAPP CONTROL ===\n");

        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address routerAddress = vm.envAddress("ROUTER_ADDRESS");
        address bidToken = vm.envAddress("BID_TOKEN");
        address dAppPayoutAddress = vm.envAddress("DAPP_PAYOUT_ADDRESS");
        uint256 dAppPayoutShare = vm.envUint("DAPP_PAYOUT_SHARE");
        uint256 minBid = vm.envUint("MIN_BID");
        address atlasAddress = vm.envAddress("ATLAS_ADDRESS");
        address atlasVerificationAddress = vm.envAddress("ATLAS_VERIFICATION_ADDRESS");

        require(routerAddress != address(0), "ROUTER_ADDRESS is not set");
        require(dAppPayoutAddress != address(0), "DAPP_PAYOUT_ADDRESS is not set");
        require(atlasAddress != address(0), "ATLAS_ADDRESS is not set");
        require(atlasVerificationAddress != address(0), "ATLAS_VERIFICATION_ADDRESS is not set");

        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deployer address: \t\t\t\t", deployer);
        console.log("Using Router address: \t\t\t\t", routerAddress);
        console.log("Using Bid token: \t\t\t\t", bidToken);
        console.log("Using DApp payout address: \t\t\t", dAppPayoutAddress);
        console.log("Using DApp payout share: \t\t\t", dAppPayoutShare);
        console.log("Using Min Bid: \t\t\t\t", minBid);
        console.log("Using Atlas deployed at: \t\t\t", atlasAddress);
        console.log("Using Atlas Verification deployed at: \t", atlasVerificationAddress);
        console.log("\n");

        console.log("Deploying from deployer Account...");

        vm.startBroadcast(deployerPrivateKey);

        UniswapV2DAppControl uniswapV2DAppControl = new UniswapV2DAppControl(
            atlasAddress,
            routerAddress,
            bidToken,
            dAppPayoutAddress,
            dAppPayoutShare, // bps
            minBid // wei
        );

        AtlasVerification(atlasVerificationAddress).initializeGovernance(address(uniswapV2DAppControl));

        vm.stopBroadcast();

        console.log("Contracts deployed by deployer:");
        console.log("UniswapV2 DAppControl: \t\t", address(uniswapV2DAppControl));
        console.log("\n");
    }
}
