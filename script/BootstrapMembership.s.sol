// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {HNTRMembership} from "../src/HNTRMembership.sol";
import {IHNTRMembership} from "../src/IHNTRMembership.sol";

interface IMintableERC20 is IERC20 {
    function mint(address to, uint256 amount) external;
}

/**
 * Two-stage bootstrap after a membership redeploy.
 *
 * Prefer the backend script (`npx tsx src/scripts/bootstrap-contract.ts`) which
 * builds the snapshot from Mongo + the old contract. This Foundry script applies
 * an existing snapshot on-chain.
 *
 * Stage 1 — mint (if owner short) + fund:
 *   BOOTSTRAP_STAGE=1 NEW_CONTRACT_ADDRESS=0x... \
 *   BOOTSTRAP_USDT_AMOUNT=... BOOTSTRAP_USDC_AMOUNT=... \
 *   forge script script/BootstrapMembership.s.sol:BootstrapMembership --broadcast
 *
 * Stage 2 — seed + seal (snapshot from backend):
 *   BOOTSTRAP_STAGE=2 NEW_CONTRACT_ADDRESS=0x... \
 *   BOOTSTRAP_SNAPSHOT_PATH=./bootstrap-snapshot.json \
 *   forge script script/BootstrapMembership.s.sol:BootstrapMembership --broadcast
 */
contract BootstrapMembership is Script {
    function run() public {
        uint256 stage = vm.envUint("BOOTSTRAP_STAGE");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        HNTRMembership membership = HNTRMembership(vm.envAddress("NEW_CONTRACT_ADDRESS"));
        require(!membership.bootstrapClosed(), "Bootstrap already sealed");

        if (stage == 1) {
            _stage1Fund(pk, membership);
        } else if (stage == 2) {
            _stage2SeedAndSeal(pk, membership);
        } else {
            revert("BOOTSTRAP_STAGE must be 1 or 2");
        }
    }

    function _ensureMint(IMintableERC20 token, address owner, uint256 needed, string memory label) internal {
        if (needed == 0) return;
        uint256 bal = token.balanceOf(owner);
        if (bal >= needed) {
            console2.log(label, "owner balance ok:", bal);
            return;
        }
        uint256 mintAmt = needed - bal;
        console2.log(label, "minting to owner:", mintAmt);
        token.mint(owner, mintAmt);
    }

    function _stage1Fund(uint256 pk, HNTRMembership membership) internal {
        uint256 usdtAmount = vm.envOr("BOOTSTRAP_USDT_AMOUNT", uint256(0));
        uint256 usdcAmount = vm.envOr("BOOTSTRAP_USDC_AMOUNT", uint256(0));
        require(usdtAmount > 0 || usdcAmount > 0, "Set BOOTSTRAP_USDT_AMOUNT and/or BOOTSTRAP_USDC_AMOUNT");

        IMintableERC20 usdt = IMintableERC20(membership.usdt());
        IMintableERC20 usdc = IMintableERC20(membership.usdc());
        address owner = vm.addr(pk);

        console2.log("--- Stage 1: mint (if needed) + fundBootstrap ---");
        console2.log("Contract:", address(membership));
        console2.log("Owner:   ", owner);
        console2.log("USDT amt:", usdtAmount);
        console2.log("USDC amt:", usdcAmount);

        vm.startBroadcast(pk);
        _ensureMint(usdt, owner, usdtAmount, "USDT");
        _ensureMint(usdc, owner, usdcAmount, "USDC");

        if (usdtAmount > 0) {
            usdt.approve(address(membership), usdtAmount);
            membership.fundBootstrap(address(usdt), usdtAmount);
        }
        if (usdcAmount > 0) {
            usdc.approve(address(membership), usdcAmount);
            membership.fundBootstrap(address(usdc), usdcAmount);
        }
        vm.stopBroadcast();

        console2.log("USDT balance:", usdt.balanceOf(address(membership)));
        console2.log("USDC balance:", usdc.balanceOf(address(membership)));
    }

    function _stage2SeedAndSeal(uint256 pk, HNTRMembership membership) internal {
        string memory raw = vm.readFile(vm.envString("BOOTSTRAP_SNAPSHOT_PATH"));
        uint256 membershipCount = vm.parseJsonUint(raw, ".membershipCount");
        uint256 commissionCount = vm.parseJsonUint(raw, ".commissionCount");

        console2.log("--- Stage 2: seed + seal ---");
        console2.log("Memberships:", membershipCount);
        console2.log("Commission rows:", commissionCount);

        address[] memory accounts = new address[](membershipCount);
        IHNTRMembership.Tier[] memory tiers = new IHNTRMembership.Tier[](membershipCount);
        uint256[] memory joinedAts = new uint256[](membershipCount);
        for (uint256 i = 0; i < membershipCount; i++) {
            string memory base = string.concat(".memberships[", vm.toString(i), "]");
            accounts[i] = vm.parseJsonAddress(raw, string.concat(base, ".account"));
            tiers[i] = IHNTRMembership.Tier(uint8(vm.parseJsonUint(raw, string.concat(base, ".tier"))));
            joinedAts[i] = vm.parseJsonUint(raw, string.concat(base, ".joinedAt"));
        }

        address[] memory cAccounts = new address[](commissionCount);
        address[] memory cTokens = new address[](commissionCount);
        uint256[] memory withdrawable = new uint256[](commissionCount);
        uint256[] memory locked = new uint256[](commissionCount);
        uint256[] memory lastClaimed = new uint256[](commissionCount);
        for (uint256 i = 0; i < commissionCount; i++) {
            string memory base = string.concat(".commissions[", vm.toString(i), "]");
            cAccounts[i] = vm.parseJsonAddress(raw, string.concat(base, ".account"));
            cTokens[i] = vm.parseJsonAddress(raw, string.concat(base, ".token"));
            withdrawable[i] = vm.parseJsonUint(raw, string.concat(base, ".withdrawable"));
            locked[i] = vm.parseJsonUint(raw, string.concat(base, ".locked"));
            lastClaimed[i] = vm.parseJsonUint(raw, string.concat(base, ".lastClaimed"));
        }

        vm.startBroadcast(pk);
        if (membershipCount > 0) {
            membership.seedMemberships(accounts, tiers, joinedAts);
        }
        if (commissionCount > 0) {
            membership.seedCommissions(cAccounts, cTokens, withdrawable, locked, lastClaimed);
        }

        uint256 usdtShort = membership.fundingShortfall(membership.usdt());
        uint256 usdcShort = membership.fundingShortfall(membership.usdc());
        console2.log("USDT shortfall:", usdtShort);
        console2.log("USDC shortfall:", usdcShort);
        require(usdtShort == 0 && usdcShort == 0, "Underfunded - rerun stage 1");

        membership.sealBootstrap();
        vm.stopBroadcast();
        console2.log("Bootstrap sealed.");
    }
}
