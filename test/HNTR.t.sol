// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {HNTRMembership} from "../src/HNTRMembership.sol";
import {IHNTRMembership} from "../src/IHNTRMembership.sol";
import {MockERC20, MockFeeOnTransferERC20} from "./Mocks.sol";
import {MessageHashUtils} from "openzeppelin-contracts/contracts/utils/cryptography/MessageHashUtils.sol";

contract HNTRMembershipTest is Test {
    using MessageHashUtils for bytes32;

    MockERC20 usdt;
    MockERC20 usdc;
    HNTRMembership membership;

    uint256 companyPk = 0xA11CE;
    address companySigner;

    address owner = address(this);
    address treasuryWallet = address(2);
    address leadershipWallet = address(3);
    address achievementWallet = address(4);
    address poolWallet = address(5);

    address rootUser = address(10);
    address user1 = address(11);
    address user2 = address(12);
    address user3 = address(13);

    bytes32 constant PURCHASE_OP = keccak256("PURCHASE");
    bytes32 constant UPGRADE_OP = keccak256("UPGRADE");

    function setUp() public {
        companySigner = vm.addr(companyPk);

        usdt = new MockERC20();
        usdc = new MockERC20();

        membership = new HNTRMembership(address(usdt), address(usdc));
        membership.setWallets(treasuryWallet, leadershipWallet, achievementWallet, poolWallet);
        membership.setCompanyWallet(companySigner);

        address[4] memory users = [rootUser, user1, user2, user3];
        for (uint256 i = 0; i < users.length; i++) {
            usdt.mint(users[i], 100_000 * 1e6);
            usdc.mint(users[i], 100_000 * 1e6);
            vm.prank(users[i]);
            usdt.approve(address(membership), type(uint256).max);
            vm.prank(users[i]);
            usdc.approve(address(membership), type(uint256).max);
        }

        // Root: Diamond
        _purchase(rootUser, IHNTRMembership.Tier.DIAMOND, new address[](0), new uint8[](0));

        // user1: Diamond, upline root at Hunter
        {
            address[] memory up = new address[](1);
            up[0] = rootUser;
            uint8[] memory ranks = new uint8[](1);
            ranks[0] = uint8(IHNTRMembership.Rank.HUNTER);
            _purchase(user1, IHNTRMembership.Tier.DIAMOND, up, ranks);
        }

        // user2: Bronze, uplines user1 then root
        {
            address[] memory up = new address[](2);
            up[0] = user1;
            up[1] = rootUser;
            uint8[] memory ranks = new uint8[](2);
            ranks[0] = uint8(IHNTRMembership.Rank.HUNTER);
            ranks[1] = uint8(IHNTRMembership.Rank.HUNTER);
            _purchase(user2, IHNTRMembership.Tier.BRONZE, up, ranks);
        }
    }

    function _authHash(
        address m,
        address user,
        uint8 tier,
        address[] memory uplines,
        uint8[] memory ranks,
        address token,
        uint256 deadline,
        uint256 nonce,
        uint256 epoch,
        bytes32 operation
    ) internal view returns (bytes32) {
        bytes32 uplinesHash = keccak256(abi.encode(uplines));
        bytes32 ranksHash = keccak256(abi.encode(ranks));
        return keccak256(
            abi.encode(user, tier, uplinesHash, ranksHash, token, deadline, nonce, epoch, block.chainid, m, operation)
        );
    }

    function _signAuth(
        address user,
        uint8 tier,
        address[] memory uplines,
        uint8[] memory ranks,
        address token,
        uint256 deadline,
        bytes32 operation
    ) internal view returns (bytes memory) {
        bytes32 structHash = _authHash(
            address(membership),
            user,
            tier,
            uplines,
            ranks,
            token,
            deadline,
            membership.nonces(user),
            membership.signatureEpoch(),
            operation
        );
        bytes32 digest = structHash.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(companyPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _purchase(
        address user,
        IHNTRMembership.Tier tier,
        address[] memory uplines,
        uint8[] memory ranks
    ) internal {
        uint256 deadline = block.timestamp + 600;
        bytes memory sig =
            _signAuth(user, uint8(tier), uplines, ranks, address(usdt), deadline, PURCHASE_OP);
        vm.prank(user);
        membership.purchaseMembership(user, tier, uplines, ranks, address(usdt), deadline, sig);
    }

    function _upgrade(
        address user,
        IHNTRMembership.Tier newTier,
        address[] memory uplines,
        uint8[] memory ranks
    ) internal {
        uint256 deadline = block.timestamp + 600;
        bytes memory sig =
            _signAuth(user, uint8(newTier), uplines, ranks, address(usdt), deadline, UPGRADE_OP);
        vm.prank(user);
        membership.upgradeMembership(user, newTier, uplines, ranks, address(usdt), deadline, sig);
    }

    function test_PurchaseDistribution() public {
        uint256 treasuryStart = usdt.balanceOf(treasuryWallet);
        uint256 leadershipStart = usdt.balanceOf(leadershipWallet);
        uint256 achievementStart = usdt.balanceOf(achievementWallet);
        uint256 u1LiquidStart = membership.withdrawableCommissions(user1, address(usdt));

        address[] memory uplines = new address[](3);
        uplines[0] = user2;
        uplines[1] = user1;
        uplines[2] = rootUser;
        uint8[] memory ranks = new uint8[](3);
        ranks[0] = uint8(IHNTRMembership.Rank.HUNTER);
        ranks[1] = uint8(IHNTRMembership.Rank.HUNTER);
        ranks[2] = uint8(IHNTRMembership.Rank.HUNTER);

        _purchase(user3, IHNTRMembership.Tier.DIAMOND, uplines, ranks);

        uint256 price = 2500 * 1e6;
        assertEq(usdt.balanceOf(leadershipWallet) - leadershipStart, (price * 5) / 100);
        assertEq(usdt.balanceOf(achievementWallet) - achievementStart, (price * 5) / 100);

        // L1 15% user2, L2 15% user1, L3 8% root = 38%; breakage 27%; treasury 25%+27%=52%
        assertEq(usdt.balanceOf(treasuryWallet) - treasuryStart, (price * 52) / 100);

        // user1 L2 = 15% of 2500 = 375; liquid 80% = 300
        assertEq(membership.withdrawableCommissions(user1, address(usdt)) - u1LiquidStart, 300 * 1e6);
    }

    function test_PauseBlocksPurchaseButNotWithdraw() public {
        uint256 liquid = membership.withdrawableCommissions(user1, address(usdt));
        require(liquid > 0, "need liquid");

        membership.pause();

        address[] memory up = new address[](1);
        up[0] = rootUser;
        uint8[] memory ranks = new uint8[](1);
        ranks[0] = uint8(IHNTRMembership.Rank.HUNTER);

        uint256 deadline = block.timestamp + 600;
        bytes memory sig =
            _signAuth(address(0xBEEF), uint8(IHNTRMembership.Tier.BRONZE), up, ranks, address(usdt), deadline, PURCHASE_OP);
        usdt.mint(address(0xBEEF), 1000 * 1e6);
        vm.prank(address(0xBEEF));
        usdt.approve(address(membership), type(uint256).max);

        vm.prank(address(0xBEEF));
        vm.expectRevert();
        membership.purchaseMembership(
            address(0xBEEF), IHNTRMembership.Tier.BRONZE, up, ranks, address(usdt), deadline, sig
        );

        // Withdrawals remain available while paused.
        vm.prank(user1);
        membership.withdrawCommissions(user1, address(usdt));
        assertEq(membership.withdrawableCommissions(user1, address(usdt)), 0);
    }

    function test_Ownable2StepTransfer() public {
        address newOwner = address(0xABCD);
        membership.transferOwnership(newOwner);
        assertEq(membership.pendingOwner(), newOwner);
        assertEq(membership.owner(), address(this));

        vm.prank(newOwner);
        membership.acceptOwnership();
        assertEq(membership.owner(), newOwner);
    }

    function test_NoncePreventsReplay() public {
        address buyer = address(0xC0FFEE);
        usdt.mint(buyer, 1000 * 1e6);
        vm.prank(buyer);
        usdt.approve(address(membership), type(uint256).max);

        address[] memory up = new address[](1);
        up[0] = rootUser;
        uint8[] memory ranks = new uint8[](1);
        ranks[0] = uint8(IHNTRMembership.Rank.HUNTER);

        uint256 deadline = block.timestamp + 600;
        bytes memory sig =
            _signAuth(buyer, uint8(IHNTRMembership.Tier.BRONZE), up, ranks, address(usdt), deadline, PURCHASE_OP);

        vm.prank(buyer);
        membership.purchaseMembership(buyer, IHNTRMembership.Tier.BRONZE, up, ranks, address(usdt), deadline, sig);

        // Prove nonce: sign upgrade with stale nonce=0 while current nonce=1.
        uint256 staleNonce = 0;
        bytes32 structHash = _authHash(
            address(membership),
            buyer,
            uint8(IHNTRMembership.Tier.SILVER),
            up,
            ranks,
            address(usdt),
            deadline,
            staleNonce,
            membership.signatureEpoch(),
            UPGRADE_OP
        );
        bytes32 digest = structHash.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(companyPk, digest);
        bytes memory staleSig = abi.encodePacked(r, s, v);

        vm.prank(buyer);
        vm.expectRevert("Invalid signature");
        membership.upgradeMembership(
            buyer, IHNTRMembership.Tier.SILVER, up, ranks, address(usdt), deadline, staleSig
        );
    }

    function test_InvalidateSignatures() public {
        address buyer = address(0xD00D);
        usdt.mint(buyer, 1000 * 1e6);
        vm.prank(buyer);
        usdt.approve(address(membership), type(uint256).max);

        address[] memory up = new address[](1);
        up[0] = rootUser;
        uint8[] memory ranks = new uint8[](1);
        ranks[0] = uint8(IHNTRMembership.Rank.HUNTER);

        uint256 deadline = block.timestamp + 600;
        bytes memory sig =
            _signAuth(buyer, uint8(IHNTRMembership.Tier.BRONZE), up, ranks, address(usdt), deadline, PURCHASE_OP);

        membership.invalidateSignatures();

        vm.prank(buyer);
        vm.expectRevert("Invalid signature");
        membership.purchaseMembership(buyer, IHNTRMembership.Tier.BRONZE, up, ranks, address(usdt), deadline, sig);

        // Fresh signature at new epoch works.
        _purchase(buyer, IHNTRMembership.Tier.BRONZE, up, ranks);
        assertEq(uint8(membership.getUser(buyer).tier), uint8(IHNTRMembership.Tier.BRONZE));
    }

    function test_RejectSelfAndDuplicateUplines() public {
        address buyer = address(0x5E1F);
        usdt.mint(buyer, 1000 * 1e6);
        vm.prank(buyer);
        usdt.approve(address(membership), type(uint256).max);

        address[] memory selfUp = new address[](1);
        selfUp[0] = buyer;
        uint8[] memory ranks = new uint8[](1);
        ranks[0] = uint8(IHNTRMembership.Rank.HUNTER);

        uint256 deadline = block.timestamp + 600;
        bytes memory sig =
            _signAuth(buyer, uint8(IHNTRMembership.Tier.BRONZE), selfUp, ranks, address(usdt), deadline, PURCHASE_OP);

        vm.prank(buyer);
        vm.expectRevert("Self upline");
        membership.purchaseMembership(buyer, IHNTRMembership.Tier.BRONZE, selfUp, ranks, address(usdt), deadline, sig);

        address[] memory dup = new address[](2);
        dup[0] = rootUser;
        dup[1] = rootUser;
        uint8[] memory ranks2 = new uint8[](2);
        ranks2[0] = uint8(IHNTRMembership.Rank.HUNTER);
        ranks2[1] = uint8(IHNTRMembership.Rank.HUNTER);
        bytes memory sig2 =
            _signAuth(buyer, uint8(IHNTRMembership.Tier.BRONZE), dup, ranks2, address(usdt), deadline, PURCHASE_OP);

        vm.prank(buyer);
        vm.expectRevert("Duplicate upline");
        membership.purchaseMembership(buyer, IHNTRMembership.Tier.BRONZE, dup, ranks2, address(usdt), deadline, sig2);
    }

    function test_RescueCannotDipBelowLiabilities() public {
        uint256 liability = membership.totalWithdrawable(address(usdt));
        assertGt(liability, 0);

        uint256 bal = usdt.balanceOf(address(membership));
        // Try to rescue everything — must fail.
        vm.expectRevert("Below liabilities");
        membership.rescueToken(address(usdt), owner, bal);

        // Rescue dust above liabilities is OK if any.
        if (bal > liability) {
            uint256 excess = bal - liability;
            membership.rescueToken(address(usdt), owner, excess);
            assertEq(usdt.balanceOf(address(membership)), liability);
        }
    }

    function test_FeeOnTransferUsesReceivedAmount() public {
        // Deploy a separate membership wired to a fee-on-transfer token as both usdt/usdc.
        MockFeeOnTransferERC20 feeToken = new MockFeeOnTransferERC20(10); // 0.1%
        MockFeeOnTransferERC20 feeToken2 = new MockFeeOnTransferERC20(10);
        // Need two 6-decimal tokens for constructor; mint/approve via feeToken as USDT.
        // Constructor requires decimals==6 on both — feeToken2 is also 6.
        HNTRMembership feeMembership = new HNTRMembership(address(feeToken), address(feeToken2));
        feeMembership.setWallets(treasuryWallet, leadershipWallet, achievementWallet, poolWallet);
        feeMembership.setCompanyWallet(companySigner);

        address buyer = address(0xFEE1);
        address upline = address(0xA011);
        feeToken.mint(buyer, 10_000 * 1e6);
        feeToken.mint(upline, 10_000 * 1e6);
        vm.prank(buyer);
        feeToken.approve(address(feeMembership), type(uint256).max);
        vm.prank(upline);
        feeToken.approve(address(feeMembership), type(uint256).max);

        // Upline buys first (empty uplines).
        {
            uint256 deadline = block.timestamp + 600;
            address[] memory empty = new address[](0);
            uint8[] memory emptyR = new uint8[](0);
            bytes32 structHash = _authHash(
                address(feeMembership),
                upline,
                uint8(IHNTRMembership.Tier.DIAMOND),
                empty,
                emptyR,
                address(feeToken),
                deadline,
                feeMembership.nonces(upline),
                feeMembership.signatureEpoch(),
                PURCHASE_OP
            );
            bytes32 digest = structHash.toEthSignedMessageHash();
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(companyPk, digest);
            vm.prank(upline);
            feeMembership.purchaseMembership(
                upline,
                IHNTRMembership.Tier.DIAMOND,
                empty,
                emptyR,
                address(feeToken),
                deadline,
                abi.encodePacked(r, s, v)
            );
        }

        address[] memory up = new address[](1);
        up[0] = upline;
        uint8[] memory ranks = new uint8[](1);
        ranks[0] = uint8(IHNTRMembership.Rank.HUNTER);

        uint256 price = 50 * 1e6; // Bronze
        uint256 expectedReceived = price - (price * 10) / 10_000;

        uint256 deadline2 = block.timestamp + 600;
        bytes32 structHash2 = _authHash(
            address(feeMembership),
            buyer,
            uint8(IHNTRMembership.Tier.BRONZE),
            up,
            ranks,
            address(feeToken),
            deadline2,
            feeMembership.nonces(buyer),
            feeMembership.signatureEpoch(),
            PURCHASE_OP
        );
        bytes32 digest2 = structHash2.toEthSignedMessageHash();
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(companyPk, digest2);

        uint256 contractBefore = feeToken.balanceOf(address(feeMembership));
        vm.prank(buyer);
        feeMembership.purchaseMembership(
            buyer,
            IHNTRMembership.Tier.BRONZE,
            up,
            ranks,
            address(feeToken),
            deadline2,
            abi.encodePacked(r2, s2, v2)
        );

        // Solvency: contract balance >= totalWithdrawable
        assertGe(feeToken.balanceOf(address(feeMembership)), feeMembership.totalWithdrawable(address(feeToken)));

        // Upline L1 liquid = 80% of 15% of received
        uint256 levelCut = (expectedReceived * 15) / 100;
        uint256 liquid = (levelCut * 80) / 100;
        assertEq(feeMembership.withdrawableCommissions(upline, address(feeToken)), liquid);

        // Contract should not have gone insolvent vs requested amount accounting
        assertTrue(feeToken.balanceOf(address(feeMembership)) + 1 >= contractBefore); // smoke
    }

    function test_ZeroWalletRejected() public {
        vm.expectRevert("Zero wallet");
        membership.setCompanyWallet(address(0));

        vm.expectRevert("Zero wallet");
        membership.setWallets(address(0), leadershipWallet, achievementWallet, poolWallet);
    }

    function test_UpgradeUsesPriceDiff() public {
        address[] memory up = new address[](1);
        up[0] = rootUser;
        uint8[] memory ranks = new uint8[](1);
        ranks[0] = uint8(IHNTRMembership.Rank.HUNTER);

        uint256 treasuryBefore = usdt.balanceOf(treasuryWallet);
        _upgrade(user2, IHNTRMembership.Tier.SILVER, up, ranks);

        // Silver 250 - Bronze 50 = 200; treasury gets at least 25% of 200
        assertGe(usdt.balanceOf(treasuryWallet) - treasuryBefore, (200 * 1e6 * 25) / 100);
        assertEq(uint8(membership.getUser(user2).tier), uint8(IHNTRMembership.Tier.SILVER));
    }
}
