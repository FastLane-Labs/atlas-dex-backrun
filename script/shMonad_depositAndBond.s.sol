// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import "../src/interfaces/IShMonad.sol";

contract DepositAndBondScript is Script {
    function run() external {
        console.log("\n=== DEPOSITING AND BONDING TO SHMONAD ===\n");

        uint256 deployerPrivateKey = vm.envUint("SOLVER1_PRIVATE_KEY");
        address shmonadAddress = vm.envAddress("SHMONAD_ADDRESS");
        uint64 policyId = uint64(vm.envUint("POLICY_ID"));
        address deployer = vm.addr(deployerPrivateKey);

        console.log("===============================");
        console.log("Deployer address:", deployer);
        console.log("shMonad address:", shmonadAddress);
        console.log("Policy ID:", policyId);
        console.log("===============================");

        vm.startBroadcast(deployerPrivateKey);

        // Get shMonad interface
        IShMonad shMonad = IShMonad(shmonadAddress);

        // Deposit and bond 100 ETH worth of MON
        uint256 amountToDeposit = 100e18; // 100 ETH
        console.log("Depositing and bonding", amountToDeposit, "wei of MON");

        // Call depositAndBond with the policy ID and amount
        shMonad.depositAndBond{value: amountToDeposit}(policyId, deployer, type(uint256).max);

        // Get the bonded balance
        uint256 bonded = shMonad.balanceOfBonded(policyId, deployer);
        console.log("Bonded balance:", bonded);

        vm.stopBroadcast();
    }
}


