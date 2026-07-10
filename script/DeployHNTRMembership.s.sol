// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {HNTRMembership} from "../src/HNTRMembership.sol";
import {MockERC20} from "../test/Mocks.sol";

contract DeployHNTRMembership is Script {
    function run() public {
        // Read deployment parameters strictly from environment variables
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        address usdt;
        address usdc;

        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);

        if (block.chainid == 31337 || block.chainid == 11155111) { // Local network or Sepolia testnet
            console2.log("--- Deploying Mock Tokens ---");
            MockERC20 mockUSDT = new MockERC20();
            mockUSDT.mint(vm.addr(deployerPrivateKey), 1000000 * 10**6);
            usdt = address(mockUSDT);

            MockERC20 mockUSDC = new MockERC20();
            mockUSDC.mint(vm.addr(deployerPrivateKey), 1000000 * 10**6);
            usdc = address(mockUSDC);
        } else {
            usdt = vm.envAddress("USDT_ADDRESS");
            usdc = vm.envAddress("USDC_ADDRESS");
        }

        console2.log("--- Deploying HNTRMembership ---");
        console2.log("USDT Address:", usdt);
        console2.log("USDC Address:", usdc);

        HNTRMembership membership = new HNTRMembership(
            usdt,
            usdc
        );

        vm.stopBroadcast();

        console2.log("HNTRMembership deployed at:", address(membership));
    }
}
