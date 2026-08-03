// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {HNTRMembership} from "../src/HNTRMembership.sol";
import {IHNTRMembership} from "../src/IHNTRMembership.sol";
import {MockERC20} from "./Mocks.sol";

contract BootstrapMembershipTest is Test {
    MockERC20 usdt;
    MockERC20 usdc;
    HNTRMembership membership;

    address owner = address(this);
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    address treasuryWallet = makeAddr("treasury");
    address leadershipWallet = makeAddr("leadership");
    address achievementWallet = makeAddr("achievement");
    address poolWallet = makeAddr("pool");
    address companyWallet = makeAddr("company");

    function setUp() public {
        usdt = new MockERC20();
        usdc = new MockERC20();
        membership = new HNTRMembership(address(usdt), address(usdc));
        membership.setWallets(treasuryWallet, leadershipWallet, achievementWallet, poolWallet);
        membership.setCompanyWallet(companyWallet);

        usdt.mint(owner, 1_000_000e6);
        usdc.mint(owner, 1_000_000e6);
        usdt.approve(address(membership), type(uint256).max);
        usdc.approve(address(membership), type(uint256).max);
    }

    function test_TwoStageBootstrap_FundThenSeedAndClaim() public {
        uint256 aliceUsdt = 120e6;
        uint256 bobUsdc = 50e6;

        // Stage 1
        membership.fundBootstrap(address(usdt), aliceUsdt);
        membership.fundBootstrap(address(usdc), bobUsdc);
        assertEq(usdt.balanceOf(address(membership)), aliceUsdt);
        assertEq(usdc.balanceOf(address(membership)), bobUsdc);

        // Stage 2a — memberships
        address[] memory accounts = new address[](2);
        accounts[0] = alice;
        accounts[1] = bob;
        IHNTRMembership.Tier[] memory tiers = new IHNTRMembership.Tier[](2);
        tiers[0] = IHNTRMembership.Tier.GOLD;
        tiers[1] = IHNTRMembership.Tier.BRONZE;
        uint256[] memory joinedAts = new uint256[](2);
        joinedAts[0] = 1_700_000_000;
        joinedAts[1] = 1_700_000_100;
        membership.seedMemberships(accounts, tiers, joinedAts);

        assertEq(uint8(membership.getUser(alice).tier), uint8(IHNTRMembership.Tier.GOLD));
        assertEq(membership.getUser(alice).joinedAt, 1_700_000_000);

        // Stage 2b — commissions
        address[] memory cAccounts = new address[](2);
        address[] memory tokens = new address[](2);
        uint256[] memory withdrawable = new uint256[](2);
        uint256[] memory locked = new uint256[](2);
        uint256[] memory lastClaimed = new uint256[](2);
        cAccounts[0] = alice;
        tokens[0] = address(usdt);
        withdrawable[0] = aliceUsdt;
        locked[0] = 30e6;
        lastClaimed[0] = 1_700_000_000;
        cAccounts[1] = bob;
        tokens[1] = address(usdc);
        withdrawable[1] = bobUsdc;
        locked[1] = 0;
        lastClaimed[1] = 1_700_000_100;
        membership.seedCommissions(cAccounts, tokens, withdrawable, locked, lastClaimed);

        assertEq(membership.withdrawableCommissions(alice, address(usdt)), aliceUsdt);
        assertEq(membership.lockedCommissions(alice, address(usdt)), 30e6);
        assertEq(membership.fundingShortfall(address(usdt)), 0);
        assertEq(membership.fundingShortfall(address(usdc)), 0);

        membership.sealBootstrap();
        assertTrue(membership.bootstrapClosed());

        vm.prank(alice);
        membership.withdrawCommissions(alice, address(usdt));
        assertEq(usdt.balanceOf(alice), aliceUsdt);
        assertEq(membership.withdrawableCommissions(alice, address(usdt)), 0);
    }

    function test_SealRevertsWhenUnderfunded() public {
        address[] memory accounts = new address[](1);
        accounts[0] = alice;
        IHNTRMembership.Tier[] memory tiers = new IHNTRMembership.Tier[](1);
        tiers[0] = IHNTRMembership.Tier.SILVER;
        uint256[] memory joinedAts = new uint256[](1);
        joinedAts[0] = 1;
        membership.seedMemberships(accounts, tiers, joinedAts);

        address[] memory cAccounts = new address[](1);
        address[] memory tokens = new address[](1);
        uint256[] memory withdrawable = new uint256[](1);
        uint256[] memory locked = new uint256[](1);
        uint256[] memory lastClaimed = new uint256[](1);
        cAccounts[0] = alice;
        tokens[0] = address(usdt);
        withdrawable[0] = 100e6;
        locked[0] = 0;
        lastClaimed[0] = 1;
        membership.seedCommissions(cAccounts, tokens, withdrawable, locked, lastClaimed);

        assertEq(membership.fundingShortfall(address(usdt)), 100e6);
        vm.expectRevert("USDT underfunded");
        membership.sealBootstrap();
    }

    function test_BootstrapClosedBlocksFurtherSeeds() public {
        membership.sealBootstrap();
        vm.expectRevert("Bootstrap closed");
        membership.fundBootstrap(address(usdt), 1);
    }
}
