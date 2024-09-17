// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/DCAOrderBot.sol"; // Update the path if your contract is located elsewhere

contract DCAOrderBotScript is Script {
    function run() external {
        // Load environment variables for private key if needed
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);

        // Deploy the DCAOrderBot contract
        DCAOrderBot dcaOrderBot = new DCAOrderBot();

        // Log the address of the deployed contract
        console.log("DCAOrderBot deployed to:", address(dcaOrderBot));

        // Stop broadcasting transactions
        vm.stopBroadcast();
    }
}
