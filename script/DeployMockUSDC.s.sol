// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {MockERC20} from "../test/Mocks.sol";

contract DeployMockUSDC is Script {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        console2.log("--- Deploying Mock USDC ---");

        vm.startBroadcast(deployerPrivateKey);

        MockERC20 mockUSDC = new MockERC20();
        
        // Mint 1,000,000 Fake USDC to the deployer for testing!
        mockUSDC.mint(vm.addr(deployerPrivateKey), 1000000 * 10**6);

        vm.stopBroadcast();

        console2.log("Mock USDC Deployed At:", address(mockUSDC));
        console2.log("Minted 1,000,000 Mock USDC to Deployer:", vm.addr(deployerPrivateKey));
    }
}
