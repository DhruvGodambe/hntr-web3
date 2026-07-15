// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {HNTRMembership} from "../src/HNTRMembership.sol";
import {IHNTRMembership} from "../src/IHNTRMembership.sol";
import {MockERC20} from "./Mocks.sol";

contract HNTRMembershipTest is Test {
    MockERC20 usdt;
    MockERC20 usdc;
    HNTRMembership membership;

    address owner = address(1);
    
    address treasuryWallet = address(2);
    address leadershipWallet = address(3);
    address achievementWallet = address(4);
    address poolWallet = address(5);
    address burner = address(6); // relayer wallet - only address allowed to call purchase/upgrade/withdraw

    address rootUser = address(10);
    address user1 = address(11); // Will be an Apex
    address user2 = address(12); // Will be a Scout
    address user3 = address(13); // New buyer

    function setUp() public {
        vm.startPrank(owner);

        usdt = new MockERC20();
        usdc = new MockERC20();
        
        membership = new HNTRMembership(
            address(usdt),
            address(usdc)
        );
        membership.setWallets(treasuryWallet, leadershipWallet, achievementWallet, poolWallet);
        membership.setBurnerWallet(burner);

        // Mint and approve for all users
        address[4] memory users = [rootUser, user1, user2, user3];
        for (uint i = 0; i < users.length; i++) {
            usdt.mint(users[i], 100000 * 1e6);
            usdc.mint(users[i], 100000 * 1e6);
            vm.stopPrank();
            vm.prank(users[i]);
            usdt.approve(address(membership), type(uint256).max);
            vm.prank(users[i]);
            usdc.approve(address(membership), type(uint256).max);
            vm.startPrank(owner);
        }

        vm.stopPrank();

        // 1. Root buys APEX ($2500)
        vm.prank(burner);
        membership.purchaseMembership(rootUser, IHNTRMembership.Tier.APEX, new address[](0), address(usdt));

        // 2. User1 buys APEX ($2500), upline: root
        address[] memory uplines1 = new address[](1);
        uplines1[0] = rootUser;
        vm.prank(burner);
        membership.purchaseMembership(user1, IHNTRMembership.Tier.APEX, uplines1, address(usdt));

        // 3. User2 buys SCOUT ($50), upline: user1, root
        address[] memory uplines2 = new address[](2);
        uplines2[0] = user1;
        uplines2[1] = rootUser;
        vm.prank(burner);
        membership.purchaseMembership(user2, IHNTRMembership.Tier.SCOUT, uplines2, address(usdt));
    }

    function test_PurchaseDistribution() public {
        // Clear balances to measure exact diffs
        uint256 treasuryStart = usdt.balanceOf(treasuryWallet);
        uint256 leadershipStart = usdt.balanceOf(leadershipWallet);
        uint256 achievementStart = usdt.balanceOf(achievementWallet);

        uint256 u1LiquidStart = membership.withdrawableCommissions(user1, address(usdt));
        uint256 u1LockedStart = membership.lockedCommissions(user1, address(usdt));

        // User 3 buys APEX ($2500)
        // Upline array: user2 (Level 1), user1 (Level 2), rootUser (Level 3)
        address[] memory uplines = new address[](3);
        uplines[0] = user2; // SCOUT
        uplines[1] = user1; // APEX
        uplines[2] = rootUser; // APEX

        vm.prank(burner);
        membership.purchaseMembership(user3, IHNTRMembership.Tier.APEX, uplines, address(usdt));

        uint256 price = 2500 * 1e6;

        // Treasury should get 25% + Breakage
        // Leadership gets 5%
        // Achievement gets 5%
        assertEq(usdt.balanceOf(leadershipWallet) - leadershipStart, (price * 5) / 100);
        assertEq(usdt.balanceOf(achievementWallet) - achievementStart, (price * 5) / 100);

        // Commissions:
        // L1 (20%): user2 (SCOUT - max depth 3). Qualifies.
        // L2 (10%): user1 (APEX). Qualifies.
        // L3 (8%): rootUser (APEX). Qualifies.
        // Total paid = 38%. Breakage = 65% - 38% = 27%.
        // Treasury = 25% + 27% = 52%.

        assertEq(usdt.balanceOf(treasuryWallet) - treasuryStart, (price * 52) / 100);

        // Verify User1 (Level 2 = 10% = $250)
        // Liquid: 80% of 250 = 200
        // Locked: 20% of 250 = 50
        assertEq(membership.withdrawableCommissions(user1, address(usdt)) - u1LiquidStart, 200 * 1e6);
        assertEq(membership.lockedCommissions(user1, address(usdt)) - u1LockedStart, 50 * 1e6);
    }

    function test_DynamicCompression() public {
        // Create an array of 5 users, but the first 4 are SCOUTS.
        // Then user6 buys APEX.
        // L4 commission should compress past the SCOUTS (since Scout max level is 3).
        
        address scoutA = address(100);
        address scoutB = address(101);
        address scoutC = address(102);
        address scoutD = address(103);
        address apexLeader = address(104);
        address buyer = address(105);

        address[6] memory newUsers = [scoutA, scoutB, scoutC, scoutD, apexLeader, buyer];
        for (uint i = 0; i < newUsers.length; i++) {
            usdt.mint(newUsers[i], 100000 * 1e6);
            vm.prank(newUsers[i]);
            usdt.approve(address(membership), type(uint256).max);
        }

        vm.prank(burner); membership.purchaseMembership(apexLeader, IHNTRMembership.Tier.APEX, new address[](0), address(usdt));
        
        address[] memory upD = new address[](1); upD[0] = apexLeader;
        vm.prank(burner); membership.purchaseMembership(scoutD, IHNTRMembership.Tier.SCOUT, upD, address(usdt));

        address[] memory upC = new address[](2); upC[0] = scoutD; upC[1] = apexLeader;
        vm.prank(burner); membership.purchaseMembership(scoutC, IHNTRMembership.Tier.SCOUT, upC, address(usdt));

        address[] memory upB = new address[](3); upB[0] = scoutC; upB[1] = scoutD; upB[2] = apexLeader;
        vm.prank(burner); membership.purchaseMembership(scoutB, IHNTRMembership.Tier.SCOUT, upB, address(usdt));

        address[] memory upA = new address[](4); upA[0] = scoutB; upA[1] = scoutC; upA[2] = scoutD; upA[3] = apexLeader;
        vm.prank(burner); membership.purchaseMembership(scoutA, IHNTRMembership.Tier.SCOUT, upA, address(usdt));

        uint256 apexLiquidBefore = membership.withdrawableCommissions(apexLeader, address(usdt));

        // Buyer buys APEX ($2500)
        // Array order (bottom-up): scoutA, scoutB, scoutC, scoutD, apexLeader
        address[] memory buyerUps = new address[](5);
        buyerUps[0] = scoutA; // Tries for L1 (Qualifies, max 3) => Gets L1 (20%)
        buyerUps[1] = scoutB; // Tries for L2 (Qualifies, max 3) => Gets L2 (10%)
        buyerUps[2] = scoutC; // Tries for L3 (Qualifies, max 3) => Gets L3 (8%)
        buyerUps[3] = scoutD; // Tries for L4 (FAILS, max 3) => SKIPPED
        buyerUps[4] = apexLeader; // Tries for L4 (Qualifies, max 12) => Gets L4 (5%)

        vm.prank(burner);
        membership.purchaseMembership(buyer, IHNTRMembership.Tier.APEX, buyerUps, address(usdt));

        // ApexLeader gets L4 commission = 5% = $125
        // 80% liquid = $100
        assertEq(membership.withdrawableCommissions(apexLeader, address(usdt)) - apexLiquidBefore, 100 * 1e6);
    }
}
