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

        // Local Anvil (31337) -> deploy fresh mocks. Sepolia (11155111) and any other
        // non-local chain -> read USDT/USDC addresses from env. The Sepolia addresses
        // below match the frontend .env.local values used by hntr-web-nextjs.
        //   USDT: 0x27ac10AEEAea707C4843c8aF4DB52C244D0D8E95
        //   USDC: 0xEF1b555b3130A3AD46a3161F314b1189b5453D15
        bool isLocal = block.chainid == 31337;

        vm.startBroadcast(deployerPrivateKey);

        if (isLocal) {
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

        // --- Configure protocol wallets ---------------------------------------------
        // Without this step treasuryWallet/leadershipWallet/achievementWallet/poolWallet/
        // companyWallet all default to address(0), so every ERC20 transfer to an unset
        // wallet would revert and the contract would be unusable.
        //
        // On local chains, any wallet left unset in the environment falls back to the
        // deployer address so a bare `forge script` run is immediately usable. On any
        // other chain, ALL five addresses are required and the script reverts if missing.
        address treasuryWallet;
        address leadershipWallet;
        address achievementWallet;
        address poolWallet;
        address companyWallet;

        if (isLocal) {
            treasuryWallet = vm.envOr("TREASURY_WALLET", deployer);
            leadershipWallet = vm.envOr("LEADERSHIP_WALLET", deployer);
            achievementWallet = vm.envOr("ACHIEVEMENT_WALLET", deployer);
            poolWallet = vm.envOr("POOL_WALLET", deployer);
            companyWallet = vm.envOr("COMPANY_WALLET", deployer);
        } else {
            treasuryWallet = vm.envAddress("TREASURY_WALLET");
            leadershipWallet = vm.envAddress("LEADERSHIP_WALLET");
            achievementWallet = vm.envAddress("ACHIEVEMENT_WALLET");
            poolWallet = vm.envAddress("POOL_WALLET");
            companyWallet = vm.envAddress("COMPANY_WALLET");
        }

        membership.setWallets(treasuryWallet, leadershipWallet, achievementWallet, poolWallet);
        membership.setCompanyWallet(companyWallet);

        // Optional: hand ownership to a Safe multisig (Ownable2Step).
        // Set OWNER_MULTISIG in the environment; the multisig must then call acceptOwnership().
        address ownerMultisig = vm.envOr("OWNER_MULTISIG", address(0));
        if (ownerMultisig != address(0)) {
            membership.transferOwnership(ownerMultisig);
            console2.log("Ownership transfer started ->", ownerMultisig);
            console2.log("Multisig must call acceptOwnership()");
        }

        vm.stopBroadcast();

        console2.log("--- Post-deploy configuration ---");
        console2.log("Treasury Wallet:   ", treasuryWallet);
        console2.log("Leadership Wallet: ", leadershipWallet);
        console2.log("Achievement Wallet:", achievementWallet);
        console2.log("Pool Wallet:       ", poolWallet);
        console2.log("Company Wallet:    ", companyWallet);
        console2.log("Owner:             ", membership.owner());

        // Sanity check: fail loudly if a critical wallet somehow ended up unset.
        require(membership.companyWallet() != address(0), "DEPLOY: companyWallet not configured");
        require(membership.treasuryWallet() != address(0), "DEPLOY: treasuryWallet not configured");
    }
}
