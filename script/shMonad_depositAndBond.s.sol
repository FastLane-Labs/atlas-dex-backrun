// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import "../src/interfaces/IShMonad.sol";
import { BackrunDAppControl } from "src/BackrunDAppControl.sol";

contract DepositAndBondScript is Script {
    function run() external {
        console.log("\n=== DEPOSITING AND BONDING TO SHMONAD ===\n");

        uint256 deployerPrivateKey = vm.envUint("GOV_PRIVATE_KEY");
        address shmonadAddress = vm.envAddress("SHMONAD_ADDRESS");
        address auctioneer = vm.envAddress("AUCTIONEER_ADDRESS");
        uint256 userPrivateKey = vm.envUint("USER_PRIVATE_KEY");
        uint64 policyId = uint64(14);
        address deployer = vm.addr(deployerPrivateKey);
        address user = vm.addr(userPrivateKey);
        console.log("===============================");
        console.log("Deployer address:", deployer);
        console.log("shMonad address:", shmonadAddress);
        console.log("Policy ID:", policyId);
        console.log("===============================");

        vm.startBroadcast(userPrivateKey);
        IShMonad shMonad = IShMonad(shmonadAddress);
        // shMonad.depositAndBond{value: 10 ether}(policyId, user, type(uint256).max);
        
        uint256 bonded = shMonad.balanceOfBonded(policyId, user);
        console.log("Bonded balance:", bonded);

        

        vm.stopBroadcast();
    }
}


