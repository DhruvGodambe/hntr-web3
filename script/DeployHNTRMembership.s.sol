// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {HNTRMembership} from "../src/HNTRMembership.sol";
import {MockERC20} from "../test/Mocks.sol";

contract DeployHNTRMembership is Script {
    function run() public {
        // Read deployment parameters strictly from environment variables
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address usdt;
        address usdc;
        bool isLocalOrTestnet = block.chainid == 31337 || block.chainid == 11155111;

        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);

        if (isLocalOrTestnet) {
            console2.log("--- Deploying Mock Tokens ---");
            MockERC20 mockUSDT = new MockERC20();
            mockUSDT.mint(deployer, 1000000 * 10 ** 6);
            usdt = address(mockUSDT);

            MockERC20 mockUSDC = new MockERC20();
            mockUSDC.mint(deployer, 1000000 * 10 ** 6);
            usdc = address(mockUSDC);
        } else {
            usdt = vm.envAddress("USDT_ADDRESS");
            usdc = vm.envAddress("USDC_ADDRESS");
        }

        console2.log("--- Deploying HNTRMembership ---");
        console2.log("USDT Address:", usdt);
        console2.log("USDC Address:", usdc);

        HNTRMembership membership = new HNTRMembership(usdt, usdc);
        console2.log("HNTRMembership deployed at:", address(membership));

        // --- Configure wallets & the burner relayer -------------------------------------
        // Without this step burnerWallet/treasuryWallet/... all default to address(0),
        // which means onlyBurnerWallet can NEVER be satisfied (msg.sender is never 0x0)
        // and every ERC20 transfer to the unset wallets would revert -> every purchase,
        // upgrade and commission withdrawal would permanently fail on a "raw" deployment.
        //
        // On local/testnet chains, any wallet left unset in the environment falls back to
        // the deployer address so a bare `forge script` run is immediately usable. On any
        // other chain, ALL five addresses are required and the script reverts if missing.
        address treasuryWallet;
        address leadershipWallet;
        address achievementWallet;
        address poolWallet;
        address burnerWallet;

        if (isLocalOrTestnet) {
            treasuryWallet = vm.envOr("TREASURY_WALLET", deployer);
            leadershipWallet = vm.envOr("LEADERSHIP_WALLET", deployer);
            achievementWallet = vm.envOr("ACHIEVEMENT_WALLET", deployer);
            poolWallet = vm.envOr("POOL_WALLET", deployer);
            burnerWallet = vm.envOr("BURNER_WALLET", deployer);
        } else {
            treasuryWallet = vm.envAddress("TREASURY_WALLET");
            leadershipWallet = vm.envAddress("LEADERSHIP_WALLET");
            achievementWallet = vm.envAddress("ACHIEVEMENT_WALLET");
            poolWallet = vm.envAddress("POOL_WALLET");
            burnerWallet = vm.envAddress("BURNER_WALLET");
        }

        membership.setWallets(treasuryWallet, leadershipWallet, achievementWallet, poolWallet);
        membership.setBurnerWallet(burnerWallet);

        vm.stopBroadcast();

        console2.log("--- Post-deploy configuration ---");
        console2.log("Treasury Wallet:   ", treasuryWallet);
        console2.log("Leadership Wallet: ", leadershipWallet);
        console2.log("Achievement Wallet:", achievementWallet);
        console2.log("Pool Wallet:       ", poolWallet);
        console2.log("Burner Wallet:     ", burnerWallet);

        // Sanity check: fail loudly (rather than silently deploying a bricked contract)
        // if the burner wallet somehow ended up unset.
        require(membership.burnerWallet() != address(0), "DEPLOY: burnerWallet not configured");
        require(membership.treasuryWallet() != address(0), "DEPLOY: treasuryWallet not configured");
    }
}
