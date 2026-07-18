// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {HNTRMembership} from "../src/HNTRMembership.sol";
import {IHNTRMembership} from "../src/IHNTRMembership.sol";
import {MockERC20, MockFeeOnTransferERC20} from "./Mocks.sol";
import {MessageHashUtils} from "openzeppelin-contracts/contracts/utils/cryptography/MessageHashUtils.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/// @dev 18-decimal token used only to assert constructor decimal guard.
contract MockERC20_18 is ERC20 {
    constructor() ERC20("Bad", "BAD") {}

    function decimals() public pure override returns (uint8) {
        return 18;
    }
}

contract HNTRMembershipTest is Test {
    using MessageHashUtils for bytes32;

    MockERC20 usdt;
    MockERC20 usdc;
    HNTRMembership membership;

    uint256 companyPk = 0xA11CE;
    address companySigner;

    address treasuryWallet = makeAddr("treasury");
    address leadershipWallet = makeAddr("leadership");
    address achievementWallet = makeAddr("achievement");
    address poolWallet = makeAddr("pool");

    address rootUser = makeAddr("root");
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");
    address user3 = makeAddr("user3");

    bytes32 constant PURCHASE_OP = keccak256("PURCHASE");
    bytes32 constant UPGRADE_OP = keccak256("UPGRADE");

    uint8 constant HUNTER = uint8(IHNTRMembership.Rank.HUNTER);
    uint8 constant SCOUT = uint8(IHNTRMembership.Rank.SCOUT);
    uint8 constant TRACKER = uint8(IHNTRMembership.Rank.TRACKER);
    uint8 constant RANGER = uint8(IHNTRMembership.Rank.RANGER);
    uint8 constant RANK_NONE = uint8(IHNTRMembership.Rank.NONE);

    function setUp() public {
        companySigner = vm.addr(companyPk);

        usdt = new MockERC20();
        usdc = new MockERC20();

        membership = new HNTRMembership(address(usdt), address(usdc));
        membership.setWallets(treasuryWallet, leadershipWallet, achievementWallet, poolWallet);
        membership.setCompanyWallet(companySigner);

        _fundAndApprove(rootUser);
        _fundAndApprove(user1);
        _fundAndApprove(user2);
        _fundAndApprove(user3);

        _purchase(rootUser, IHNTRMembership.Tier.DIAMOND, _emptyAddrs(), _emptyRanks());

        {
            (address[] memory up, uint8[] memory ranks) = _oneUpline(rootUser, HUNTER);
            _purchase(user1, IHNTRMembership.Tier.DIAMOND, up, ranks);
        }
        {
            address[] memory up = new address[](2);
            up[0] = user1;
            up[1] = rootUser;
            uint8[] memory ranks = new uint8[](2);
            ranks[0] = HUNTER;
            ranks[1] = HUNTER;
            _purchase(user2, IHNTRMembership.Tier.BRONZE, up, ranks);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Helpers
    // ═══════════════════════════════════════════════════════════════════════

    function _fundAndApprove(address user) internal {
        usdt.mint(user, 1_000_000 * 1e6);
        usdc.mint(user, 1_000_000 * 1e6);
        vm.startPrank(user);
        usdt.approve(address(membership), type(uint256).max);
        usdc.approve(address(membership), type(uint256).max);
        vm.stopPrank();
    }

    function _emptyAddrs() internal pure returns (address[] memory a) {
        a = new address[](0);
    }

    function _emptyRanks() internal pure returns (uint8[] memory r) {
        r = new uint8[](0);
    }

    function _oneUpline(address upline, uint8 rank)
        internal
        pure
        returns (address[] memory up, uint8[] memory ranks)
    {
        up = new address[](1);
        up[0] = upline;
        ranks = new uint8[](1);
        ranks[0] = rank;
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
        return keccak256(
            abi.encode(
                user,
                tier,
                keccak256(abi.encode(uplines)),
                keccak256(abi.encode(ranks)),
                token,
                deadline,
                nonce,
                epoch,
                block.chainid,
                m,
                operation
            )
        );
    }

    function _signFor(
        HNTRMembership m,
        address user,
        uint8 tier,
        address[] memory uplines,
        uint8[] memory ranks,
        address token,
        uint256 deadline,
        bytes32 operation
    ) internal view returns (bytes memory) {
        bytes32 digest = _authHash(
            address(m),
            user,
            tier,
            uplines,
            ranks,
            token,
            deadline,
            m.nonces(user),
            m.signatureEpoch(),
            operation
        ).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(companyPk, digest);
        return abi.encodePacked(r, s, v);
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
        return _signFor(membership, user, tier, uplines, ranks, token, deadline, operation);
    }

    function _purchase(
        address user,
        IHNTRMembership.Tier tier,
        address[] memory uplines,
        uint8[] memory ranks
    ) internal {
        _purchaseToken(user, tier, uplines, ranks, address(usdt));
    }

    function _purchaseToken(
        address user,
        IHNTRMembership.Tier tier,
        address[] memory uplines,
        uint8[] memory ranks,
        address token
    ) internal {
        uint256 deadline = block.timestamp + 600;
        bytes memory sig = _signAuth(user, uint8(tier), uplines, ranks, token, deadline, PURCHASE_OP);
        vm.prank(user);
        membership.purchaseMembership(user, tier, uplines, ranks, token, deadline, sig);
    }

    function _upgrade(
        address user,
        IHNTRMembership.Tier newTier,
        address[] memory uplines,
        uint8[] memory ranks
    ) internal {
        uint256 deadline = block.timestamp + 600;
        bytes memory sig = _signAuth(user, uint8(newTier), uplines, ranks, address(usdt), deadline, UPGRADE_OP);
        vm.prank(user);
        membership.upgradeMembership(user, newTier, uplines, ranks, address(usdt), deadline, sig);
    }

    function _assertSolvent() internal view {
        assertGe(usdt.balanceOf(address(membership)), membership.totalWithdrawable(address(usdt)));
        assertGe(usdc.balanceOf(address(membership)), membership.totalWithdrawable(address(usdc)));
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Protocol constants / configuration
    // ═══════════════════════════════════════════════════════════════════════

    function test_TierPrices() public view {
        assertEq(membership.tierPrices(IHNTRMembership.Tier.BRONZE), 50 * 1e6);
        assertEq(membership.tierPrices(IHNTRMembership.Tier.SILVER), 250 * 1e6);
        assertEq(membership.tierPrices(IHNTRMembership.Tier.GOLD), 750 * 1e6);
        assertEq(membership.tierPrices(IHNTRMembership.Tier.PLATINUM), 1500 * 1e6);
        assertEq(membership.tierPrices(IHNTRMembership.Tier.DIAMOND), 2500 * 1e6);
    }

    function test_LevelPercentagesSumTo65() public view {
        uint256 sum;
        for (uint256 i = 0; i < 12; i++) {
            sum += membership.levelPercentages(i);
        }
        assertEq(sum, 65);
    }

    function test_ConstructorRejectsNon6DecimalTokens() public {
        MockERC20_18 bad = new MockERC20_18();
        vm.expectRevert("USDT must be 6 decimals");
        new HNTRMembership(address(bad), address(usdc));
    }

    function test_ConstructorRejectsZeroToken() public {
        vm.expectRevert("Invalid token");
        new HNTRMembership(address(0), address(usdc));
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Purchase / upgrade access & validation
    // ═══════════════════════════════════════════════════════════════════════

    function test_OnlyMsgSenderCanPurchase() public {
        address buyer = makeAddr("buyer");
        _fundAndApprove(buyer);
        (address[] memory up, uint8[] memory ranks) = _oneUpline(rootUser, HUNTER);
        uint256 deadline = block.timestamp + 600;
        bytes memory sig =
            _signAuth(buyer, uint8(IHNTRMembership.Tier.BRONZE), up, ranks, address(usdt), deadline, PURCHASE_OP);

        vm.prank(user1);
        vm.expectRevert("Not authorized");
        membership.purchaseMembership(buyer, IHNTRMembership.Tier.BRONZE, up, ranks, address(usdt), deadline, sig);
    }

    function test_CannotPurchaseTwice() public {
        (address[] memory up, uint8[] memory ranks) = _oneUpline(rootUser, HUNTER);
        uint256 deadline = block.timestamp + 600;
        bytes memory sig =
            _signAuth(user2, uint8(IHNTRMembership.Tier.SILVER), up, ranks, address(usdt), deadline, PURCHASE_OP);
        // user2 already bronze from setUp
        vm.prank(user2);
        vm.expectRevert("Already a member");
        membership.purchaseMembership(user2, IHNTRMembership.Tier.SILVER, up, ranks, address(usdt), deadline, sig);
    }

    function test_CannotPurchaseNoneTier() public {
        address buyer = makeAddr("noneTier");
        _fundAndApprove(buyer);
        uint256 deadline = block.timestamp + 600;
        bytes memory sig = _signAuth(
            buyer, uint8(IHNTRMembership.Tier.NONE), _emptyAddrs(), _emptyRanks(), address(usdt), deadline, PURCHASE_OP
        );
        vm.prank(buyer);
        vm.expectRevert("Invalid tier");
        membership.purchaseMembership(
            buyer, IHNTRMembership.Tier.NONE, _emptyAddrs(), _emptyRanks(), address(usdt), deadline, sig
        );
    }

    function test_UnsupportedTokenReverts() public {
        address buyer = makeAddr("badToken");
        _fundAndApprove(buyer);
        address fake = makeAddr("fakeToken");
        uint256 deadline = block.timestamp + 600;
        bytes memory sig = _signAuth(
            buyer, uint8(IHNTRMembership.Tier.BRONZE), _emptyAddrs(), _emptyRanks(), fake, deadline, PURCHASE_OP
        );
        vm.prank(buyer);
        vm.expectRevert("Unsupported token");
        membership.purchaseMembership(
            buyer, IHNTRMembership.Tier.BRONZE, _emptyAddrs(), _emptyRanks(), fake, deadline, sig
        );
    }

    function test_PurchaseWithUSDC() public {
        address buyer = makeAddr("usdcBuyer");
        _fundAndApprove(buyer);
        (address[] memory up, uint8[] memory ranks) = _oneUpline(rootUser, HUNTER);

        uint256 treasuryBefore = usdc.balanceOf(treasuryWallet);
        _purchaseToken(buyer, IHNTRMembership.Tier.BRONZE, up, ranks, address(usdc));

        assertEq(uint8(membership.getUser(buyer).tier), uint8(IHNTRMembership.Tier.BRONZE));
        assertGt(usdc.balanceOf(treasuryWallet), treasuryBefore);
        _assertSolvent();
    }

    function test_CannotDowngrade() public {
        (address[] memory up, uint8[] memory ranks) = _oneUpline(rootUser, HUNTER);
        // user1 is Diamond — cannot go to Gold
        uint256 deadline = block.timestamp + 600;
        bytes memory sig =
            _signAuth(user1, uint8(IHNTRMembership.Tier.GOLD), up, ranks, address(usdt), deadline, UPGRADE_OP);
        vm.prank(user1);
        vm.expectRevert("Can only upgrade to higher tier");
        membership.upgradeMembership(user1, IHNTRMembership.Tier.GOLD, up, ranks, address(usdt), deadline, sig);
    }

    function test_CannotUpgradeNonMember() public {
        address stranger = makeAddr("stranger");
        _fundAndApprove(stranger);
        (address[] memory up, uint8[] memory ranks) = _oneUpline(rootUser, HUNTER);
        uint256 deadline = block.timestamp + 600;
        bytes memory sig =
            _signAuth(stranger, uint8(IHNTRMembership.Tier.BRONZE), up, ranks, address(usdt), deadline, UPGRADE_OP);
        vm.prank(stranger);
        vm.expectRevert("Not a member");
        membership.upgradeMembership(
            stranger, IHNTRMembership.Tier.BRONZE, up, ranks, address(usdt), deadline, sig
        );
    }

    function test_UpgradeUsesPriceDiff() public {
        (address[] memory up, uint8[] memory ranks) = _oneUpline(rootUser, HUNTER);
        uint256 balBefore = usdt.balanceOf(user2);
        _upgrade(user2, IHNTRMembership.Tier.SILVER, up, ranks);
        // Silver - Bronze = 200
        assertEq(balBefore - usdt.balanceOf(user2), 200 * 1e6);
        assertEq(uint8(membership.getUser(user2).tier), uint8(IHNTRMembership.Tier.SILVER));
        _assertSolvent();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Commission economics
    // ═══════════════════════════════════════════════════════════════════════

    function test_FixedSplitsAndBreakage() public {
        uint256 t0 = usdt.balanceOf(treasuryWallet);
        uint256 l0 = usdt.balanceOf(leadershipWallet);
        uint256 a0 = usdt.balanceOf(achievementWallet);
        uint256 p0 = usdt.balanceOf(poolWallet);
        uint256 u1Liq0 = membership.withdrawableCommissions(user1, address(usdt));
        uint256 u1Lock0 = membership.lockedCommissions(user1, address(usdt));
        uint256 tw0 = membership.totalWithdrawable(address(usdt));

        address[] memory uplines = new address[](3);
        uplines[0] = user2;
        uplines[1] = user1;
        uplines[2] = rootUser;
        uint8[] memory ranks = new uint8[](3);
        ranks[0] = HUNTER;
        ranks[1] = HUNTER;
        ranks[2] = HUNTER;

        _purchase(user3, IHNTRMembership.Tier.DIAMOND, uplines, ranks);

        uint256 price = 2500 * 1e6;
        // L1 15% + L2 15% + L3 8% = 38%; breakage 27%; treasury 25+27=52
        assertEq(usdt.balanceOf(leadershipWallet) - l0, (price * 5) / 100);
        assertEq(usdt.balanceOf(achievementWallet) - a0, (price * 5) / 100);
        assertEq(usdt.balanceOf(treasuryWallet) - t0, (price * 52) / 100);

        // Locked to pool: 20% of each level cut = 20% of 38% = 7.6% of price
        uint256 distributed = (price * 38) / 100;
        assertEq(usdt.balanceOf(poolWallet) - p0, (distributed * 20) / 100);

        // user1 L2 liquid = 80% of 15% of 2500 = 300
        assertEq(membership.withdrawableCommissions(user1, address(usdt)) - u1Liq0, 300 * 1e6);
        assertEq(membership.lockedCommissions(user1, address(usdt)) - u1Lock0, 75 * 1e6);

        // totalWithdrawable increased by all liquid commissions (80% of 38%)
        assertEq(membership.totalWithdrawable(address(usdt)) - tw0, (distributed * 80) / 100);
        _assertSolvent();
    }

    function test_Full12LevelDistribution() public {
        // 12 Diamond+Hunter uplines in a chain; buyer pays Diamond → all 65% paid, 0 breakage beyond 25% base
        address[] memory chain = new address[](12);
        for (uint256 i = 0; i < 12; i++) {
            chain[i] = makeAddr(string(abi.encodePacked("lvl", vm.toString(i))));
            _fundAndApprove(chain[i]);
        }

        // Purchase from top of chain downward so each has the lower ones as uplines... 
        // Actually we need each member to exist first. Seed each with empty then rebuild isn't needed —
        // purchase each with only higher (already purchased) as upline.
        _purchase(chain[0], IHNTRMembership.Tier.DIAMOND, _emptyAddrs(), _emptyRanks());
        for (uint256 i = 1; i < 12; i++) {
            address[] memory up = new address[](i);
            uint8[] memory ranks = new uint8[](i);
            for (uint256 j = 0; j < i; j++) {
                up[j] = chain[i - 1 - j]; // nearest first
                ranks[j] = HUNTER;
            }
            _purchase(chain[i], IHNTRMembership.Tier.DIAMOND, up, ranks);
        }

        address buyer = makeAddr("fullBuyer");
        _fundAndApprove(buyer);

        address[] memory uplines = new address[](12);
        uint8[] memory buyerRanks = new uint8[](12);
        for (uint256 i = 0; i < 12; i++) {
            uplines[i] = chain[11 - i]; // nearest = last in chain
            buyerRanks[i] = HUNTER;
        }

        uint256 t0 = usdt.balanceOf(treasuryWallet);
        uint256 price = 2500 * 1e6;
        _purchase(buyer, IHNTRMembership.Tier.DIAMOND, uplines, buyerRanks);

        // All 65% distributed → treasury only gets base 25% (no breakage)
        assertEq(usdt.balanceOf(treasuryWallet) - t0, (price * 25) / 100);
        _assertSolvent();
    }

    function test_DynamicCompressionSkipsUnqualified() public {
        // Bronze member with rank NONE cannot earn L4 (needs Bronze+Scout).
        // Place them first; L4 should compress to the next qualified Diamond/Hunter.
        address bronze = makeAddr("bronzeGate");
        address deep = makeAddr("deepLeader");
        address buyer = makeAddr("compressBuyer");
        _fundAndApprove(bronze);
        _fundAndApprove(deep);
        _fundAndApprove(buyer);

        _purchase(deep, IHNTRMembership.Tier.DIAMOND, _emptyAddrs(), _emptyRanks());
        {
            (address[] memory upB, uint8[] memory ranksB) = _oneUpline(deep, HUNTER);
            _purchase(bronze, IHNTRMembership.Tier.BRONZE, upB, ranksB);
        }

        // Build 4 uplines: 3 Diamond/Hunter then bronze with NONE rank for L4 slot attempt.
        // Compression: L1-L3 go to first three Diamond; L4 skips bronze (rank NONE < SCOUT), goes to deep.
        address a = makeAddr("a");
        address b = makeAddr("b");
        address c = makeAddr("c");
        _fundAndApprove(a);
        _fundAndApprove(b);
        _fundAndApprove(c);
        _purchase(a, IHNTRMembership.Tier.DIAMOND, _emptyAddrs(), _emptyRanks());
        {
            (address[] memory upA, uint8[] memory ranksA) = _oneUpline(a, HUNTER);
            _purchase(b, IHNTRMembership.Tier.DIAMOND, upA, ranksA);
        }
        {
            address[] memory upC = new address[](2);
            upC[0] = b;
            upC[1] = a;
            uint8[] memory ranksC = new uint8[](2);
            ranksC[0] = HUNTER;
            ranksC[1] = HUNTER;
            _purchase(c, IHNTRMembership.Tier.DIAMOND, upC, ranksC);
        }

        address[] memory uplines = new address[](5);
        uplines[0] = c;
        uplines[1] = b;
        uplines[2] = a;
        uplines[3] = bronze; // unqualified for L4
        uplines[4] = deep; // should get L4
        uint8[] memory ranks = new uint8[](5);
        ranks[0] = HUNTER;
        ranks[1] = HUNTER;
        ranks[2] = HUNTER;
        ranks[3] = RANK_NONE;
        ranks[4] = HUNTER;

        uint256 deepLiq0 = membership.withdrawableCommissions(deep, address(usdt));
        uint256 bronzeLiq0 = membership.withdrawableCommissions(bronze, address(usdt));

        _purchase(buyer, IHNTRMembership.Tier.DIAMOND, uplines, ranks);

        // L4 = 5% of 2500 = 125; liquid 80% = 100 → deep
        assertEq(membership.withdrawableCommissions(deep, address(usdt)) - deepLiq0, 100 * 1e6);
        // bronze should not have gained from this sale's L4
        assertEq(membership.withdrawableCommissions(bronze, address(usdt)), bronzeLiq0);
        _assertSolvent();
    }

    function test_EightyTwentySplitOnCommission() public {
        address buyer = makeAddr("8020");
        _fundAndApprove(buyer);
        (address[] memory up, uint8[] memory ranks) = _oneUpline(rootUser, HUNTER);

        uint256 liq0 = membership.withdrawableCommissions(rootUser, address(usdt));
        uint256 lock0 = membership.lockedCommissions(rootUser, address(usdt));
        uint256 pool0 = usdt.balanceOf(poolWallet);

        _purchase(buyer, IHNTRMembership.Tier.BRONZE, up, ranks);

        uint256 cut = (50 * 1e6 * 15) / 100; // L1
        assertEq(membership.withdrawableCommissions(rootUser, address(usdt)) - liq0, (cut * 80) / 100);
        assertEq(membership.lockedCommissions(rootUser, address(usdt)) - lock0, cut - (cut * 80) / 100);
        assertEq(usdt.balanceOf(poolWallet) - pool0, cut - (cut * 80) / 100);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Withdrawals / company sweep
    // ═══════════════════════════════════════════════════════════════════════

    function test_WithdrawCommissions() public {
        uint256 amount = membership.withdrawableCommissions(user1, address(usdt));
        assertGt(amount, 0);
        uint256 tw0 = membership.totalWithdrawable(address(usdt));
        uint256 bal0 = usdt.balanceOf(user1);

        vm.prank(user1);
        membership.withdrawCommissions(user1, address(usdt));

        assertEq(membership.withdrawableCommissions(user1, address(usdt)), 0);
        assertEq(membership.totalWithdrawable(address(usdt)), tw0 - amount);
        assertEq(usdt.balanceOf(user1), bal0 + amount);
        assertGt(membership.lastClaimedAt(user1, address(usdt)), 0);
        _assertSolvent();
    }

    function test_WithdrawOnlySelf() public {
        vm.prank(user2);
        vm.expectRevert("Not authorized");
        membership.withdrawCommissions(user1, address(usdt));
    }

    function test_CompanyWalletSweepSendsToUser() public {
        uint256 amount = membership.withdrawableCommissions(user1, address(usdt));
        assertGt(amount, 0);
        // never claimed → overdue immediately (lastClaimedAt == 0)
        uint256 bal0 = usdt.balanceOf(user1);

        vm.prank(companySigner);
        membership.withdrawCompanyWallet(user1, address(usdt));

        assertEq(usdt.balanceOf(user1), bal0 + amount);
        assertEq(membership.withdrawableCommissions(user1, address(usdt)), 0);
        // company signer did not receive funds
        assertEq(usdt.balanceOf(companySigner), 0);
    }

    function test_CompanyWalletSweepBlockedWithinGrace() public {
        vm.prank(user1);
        membership.withdrawCommissions(user1, address(usdt));

        // Earn again
        address buyer = makeAddr("earnAgain");
        _fundAndApprove(buyer);
        (address[] memory up, uint8[] memory ranks) = _oneUpline(user1, HUNTER);
        _purchase(buyer, IHNTRMembership.Tier.BRONZE, up, ranks);
        assertGt(membership.withdrawableCommissions(user1, address(usdt)), 0);

        vm.prank(companySigner);
        vm.expectRevert("Claim not overdue");
        membership.withdrawCompanyWallet(user1, address(usdt));

        vm.warp(block.timestamp + 30 days + 1);
        uint256 amt = membership.withdrawableCommissions(user1, address(usdt));
        uint256 bal0 = usdt.balanceOf(user1);
        vm.prank(companySigner);
        membership.withdrawCompanyWallet(user1, address(usdt));
        assertEq(usdt.balanceOf(user1), bal0 + amt);
    }

    function test_OnlyCompanyWalletCanSweep() public {
        vm.prank(user1);
        vm.expectRevert("Not company wallet");
        membership.withdrawCompanyWallet(user1, address(usdt));
    }

    function test_GetOverdueWallets() public {
        vm.prank(companySigner);
        address[] memory overdue = membership.getOverdueWallets(address(usdt));
        assertGt(overdue.length, 0);

        // Non-company cannot call
        vm.prank(user1);
        vm.expectRevert("Not company wallet");
        membership.getOverdueWallets(address(usdt));
    }

    // ═══════════════════════════════════════════════════════════════════════
    // SEC-01 Signature hardening
    // ═══════════════════════════════════════════════════════════════════════

    function test_NonceIncrementsAndBlocksReplay() public {
        address buyer = makeAddr("nonceBuyer");
        _fundAndApprove(buyer);
        (address[] memory up, uint8[] memory ranks) = _oneUpline(rootUser, HUNTER);

        assertEq(membership.nonces(buyer), 0);
        _purchase(buyer, IHNTRMembership.Tier.BRONZE, up, ranks);
        assertEq(membership.nonces(buyer), 1);

        // Stale nonce=0 upgrade sig
        uint256 deadline = block.timestamp + 600;
        bytes32 digest = _authHash(
            address(membership),
            buyer,
            uint8(IHNTRMembership.Tier.SILVER),
            up,
            ranks,
            address(usdt),
            deadline,
            0,
            membership.signatureEpoch(),
            UPGRADE_OP
        ).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(companyPk, digest);

        vm.prank(buyer);
        vm.expectRevert("Invalid signature");
        membership.upgradeMembership(
            buyer, IHNTRMembership.Tier.SILVER, up, ranks, address(usdt), deadline, abi.encodePacked(r, s, v)
        );
    }

    function test_InvalidateSignaturesBumpsEpoch() public {
        address buyer = makeAddr("epochBuyer");
        _fundAndApprove(buyer);
        (address[] memory up, uint8[] memory ranks) = _oneUpline(rootUser, HUNTER);

        uint256 deadline = block.timestamp + 600;
        bytes memory sig =
            _signAuth(buyer, uint8(IHNTRMembership.Tier.BRONZE), up, ranks, address(usdt), deadline, PURCHASE_OP);

        assertEq(membership.signatureEpoch(), 0);
        membership.invalidateSignatures();
        assertEq(membership.signatureEpoch(), 1);

        vm.prank(buyer);
        vm.expectRevert("Invalid signature");
        membership.purchaseMembership(buyer, IHNTRMembership.Tier.BRONZE, up, ranks, address(usdt), deadline, sig);

        _purchase(buyer, IHNTRMembership.Tier.BRONZE, up, ranks);
    }

    function test_ExpiredSignatureReverts() public {
        address buyer = makeAddr("expired");
        _fundAndApprove(buyer);
        (address[] memory up, uint8[] memory ranks) = _oneUpline(rootUser, HUNTER);
        uint256 deadline = block.timestamp + 10;
        bytes memory sig =
            _signAuth(buyer, uint8(IHNTRMembership.Tier.BRONZE), up, ranks, address(usdt), deadline, PURCHASE_OP);
        vm.warp(deadline + 1);
        vm.prank(buyer);
        vm.expectRevert("Signature expired");
        membership.purchaseMembership(buyer, IHNTRMembership.Tier.BRONZE, up, ranks, address(usdt), deadline, sig);
    }

    function test_WrongSignerReverts() public {
        address buyer = makeAddr("wrongSig");
        _fundAndApprove(buyer);
        (address[] memory up, uint8[] memory ranks) = _oneUpline(rootUser, HUNTER);
        uint256 deadline = block.timestamp + 600;
        bytes32 digest = _authHash(
            address(membership),
            buyer,
            uint8(IHNTRMembership.Tier.BRONZE),
            up,
            ranks,
            address(usdt),
            deadline,
            0,
            0,
            PURCHASE_OP
        ).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xB0B, digest); // not company key

        vm.prank(buyer);
        vm.expectRevert("Invalid signature");
        membership.purchaseMembership(
            buyer, IHNTRMembership.Tier.BRONZE, up, ranks, address(usdt), deadline, abi.encodePacked(r, s, v)
        );
    }

    function test_CrossOperationReplayBlocked() public {
        // Purchase sig cannot be used for upgrade
        address buyer = makeAddr("crossOp");
        _fundAndApprove(buyer);
        (address[] memory up, uint8[] memory ranks) = _oneUpline(rootUser, HUNTER);
        _purchase(buyer, IHNTRMembership.Tier.BRONZE, up, ranks);

        uint256 deadline = block.timestamp + 600;
        // Sign PURCHASE for Silver (wrong op tag for upgrade)
        bytes memory purchaseSig =
            _signAuth(buyer, uint8(IHNTRMembership.Tier.SILVER), up, ranks, address(usdt), deadline, PURCHASE_OP);

        vm.prank(buyer);
        vm.expectRevert("Invalid signature");
        membership.upgradeMembership(
            buyer, IHNTRMembership.Tier.SILVER, up, ranks, address(usdt), deadline, purchaseSig
        );
    }

    function test_LengthMismatchReverts() public {
        address buyer = makeAddr("lenMis");
        _fundAndApprove(buyer);
        address[] memory up = new address[](1);
        up[0] = rootUser;
        uint8[] memory ranks = new uint8[](2);
        ranks[0] = HUNTER;
        ranks[1] = HUNTER;
        uint256 deadline = block.timestamp + 600;
        // Craft hash with mismatched arrays so we hit length check before sig
        // Actually length check happens before sig verify — any bytes ok
        vm.prank(buyer);
        vm.expectRevert("Length mismatch");
        membership.purchaseMembership(buyer, IHNTRMembership.Tier.BRONZE, up, ranks, address(usdt), deadline, hex"00");
    }

    function test_InvalidRankReverts() public {
        address buyer = makeAddr("badRank");
        _fundAndApprove(buyer);
        address[] memory up = new address[](1);
        up[0] = rootUser;
        uint8[] memory ranks = new uint8[](1);
        ranks[0] = 99;
        uint256 deadline = block.timestamp + 600;
        bytes memory sig =
            _signAuth(buyer, uint8(IHNTRMembership.Tier.BRONZE), up, ranks, address(usdt), deadline, PURCHASE_OP);
        vm.prank(buyer);
        vm.expectRevert("Invalid rank");
        membership.purchaseMembership(buyer, IHNTRMembership.Tier.BRONZE, up, ranks, address(usdt), deadline, sig);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // SEC-02 / SEC-03 Ownable2Step, Pause, Rescue
    // ═══════════════════════════════════════════════════════════════════════

    function test_Ownable2Step() public {
        address next = makeAddr("multisig");
        membership.transferOwnership(next);
        assertEq(membership.pendingOwner(), next);
        assertEq(membership.owner(), address(this));

        vm.prank(next);
        membership.acceptOwnership();
        assertEq(membership.owner(), next);

        vm.expectRevert();
        membership.pause(); // old owner lost access
    }

    function test_OnlyOwnerAdmin() public {
        vm.prank(user1);
        vm.expectRevert();
        membership.pause();

        vm.prank(user1);
        vm.expectRevert();
        membership.invalidateSignatures();

        vm.prank(user1);
        vm.expectRevert();
        membership.setCompanyWallet(user1);
    }

    function test_PauseBlocksEntryUnpauseRestores() public {
        membership.pause();
        assertTrue(membership.paused());

        address buyer = makeAddr("pausedBuyer");
        _fundAndApprove(buyer);
        (address[] memory up, uint8[] memory ranks) = _oneUpline(rootUser, HUNTER);
        uint256 deadline = block.timestamp + 600;
        bytes memory sig =
            _signAuth(buyer, uint8(IHNTRMembership.Tier.BRONZE), up, ranks, address(usdt), deadline, PURCHASE_OP);

        vm.prank(buyer);
        vm.expectRevert();
        membership.purchaseMembership(buyer, IHNTRMembership.Tier.BRONZE, up, ranks, address(usdt), deadline, sig);

        // withdraw still works
        uint256 amt = membership.withdrawableCommissions(user1, address(usdt));
        vm.prank(user1);
        membership.withdrawCommissions(user1, address(usdt));
        assertEq(membership.withdrawableCommissions(user1, address(usdt)), 0);
        assertGt(amt, 0);

        membership.unpause();
        _purchase(buyer, IHNTRMembership.Tier.BRONZE, up, ranks);
        assertEq(uint8(membership.getUser(buyer).tier), uint8(IHNTRMembership.Tier.BRONZE));
    }

    function test_PauseBlocksUpgrade() public {
        membership.pause();
        (address[] memory up, uint8[] memory ranks) = _oneUpline(rootUser, HUNTER);
        uint256 deadline = block.timestamp + 600;
        bytes memory sig =
            _signAuth(user2, uint8(IHNTRMembership.Tier.SILVER), up, ranks, address(usdt), deadline, UPGRADE_OP);
        vm.prank(user2);
        vm.expectRevert();
        membership.upgradeMembership(user2, IHNTRMembership.Tier.SILVER, up, ranks, address(usdt), deadline, sig);
    }

    function test_RescueRespectsLiabilities() public {
        uint256 liability = membership.totalWithdrawable(address(usdt));
        uint256 bal = usdt.balanceOf(address(membership));
        assertGe(bal, liability);

        vm.expectRevert("Below liabilities");
        membership.rescueToken(address(usdt), address(this), bal);

        if (bal > liability) {
            membership.rescueToken(address(usdt), address(this), bal - liability);
            assertEq(usdt.balanceOf(address(membership)), liability);
        }
        _assertSolvent();
    }

    function test_RescueWrongTokenUnrestricted() public {
        MockERC20 other = new MockERC20();
        other.mint(address(membership), 1000 * 1e6);
        membership.rescueToken(address(other), address(this), 1000 * 1e6);
        assertEq(other.balanceOf(address(this)), 1000 * 1e6);
    }

    function test_RescueZeroRecipientReverts() public {
        vm.expectRevert("Zero recipient");
        membership.rescueToken(address(usdt), address(0), 1);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // SEC-04 Fee-on-transfer / measured receipt
    // ═══════════════════════════════════════════════════════════════════════

    function test_FeeOnTransferDistributesReceived() public {
        MockFeeOnTransferERC20 feeUsdt = new MockFeeOnTransferERC20(10);
        MockFeeOnTransferERC20 feeUsdc = new MockFeeOnTransferERC20(10);
        HNTRMembership m = new HNTRMembership(address(feeUsdt), address(feeUsdc));
        m.setWallets(treasuryWallet, leadershipWallet, achievementWallet, poolWallet);
        m.setCompanyWallet(companySigner);

        address upline = makeAddr("feeUpline");
        address buyer = makeAddr("feeBuyer");
        feeUsdt.mint(upline, 50_000 * 1e6);
        feeUsdt.mint(buyer, 50_000 * 1e6);
        vm.prank(upline);
        feeUsdt.approve(address(m), type(uint256).max);
        vm.prank(buyer);
        feeUsdt.approve(address(m), type(uint256).max);

        {
            uint256 deadline = block.timestamp + 600;
            bytes memory sig = _signFor(
                m, upline, uint8(IHNTRMembership.Tier.DIAMOND), _emptyAddrs(), _emptyRanks(), address(feeUsdt), deadline, PURCHASE_OP
            );
            vm.prank(upline);
            m.purchaseMembership(
                upline, IHNTRMembership.Tier.DIAMOND, _emptyAddrs(), _emptyRanks(), address(feeUsdt), deadline, sig
            );
        }

        (address[] memory up, uint8[] memory ranks) = _oneUpline(upline, HUNTER);
        uint256 price = 50 * 1e6;
        uint256 received = price - (price * 10) / 10_000;

        uint256 deadline2 = block.timestamp + 600;
        bytes memory sig2 = _signFor(
            m, buyer, uint8(IHNTRMembership.Tier.BRONZE), up, ranks, address(feeUsdt), deadline2, PURCHASE_OP
        );
        vm.prank(buyer);
        m.purchaseMembership(buyer, IHNTRMembership.Tier.BRONZE, up, ranks, address(feeUsdt), deadline2, sig2);

        uint256 levelCut = (received * 15) / 100;
        assertEq(m.withdrawableCommissions(upline, address(feeUsdt)), (levelCut * 80) / 100);
        assertGe(feeUsdt.balanceOf(address(m)), m.totalWithdrawable(address(feeUsdt)));
    }

    // ═══════════════════════════════════════════════════════════════════════
    // SEC-05 Upline hygiene + Appendix A
    // ═══════════════════════════════════════════════════════════════════════

    function test_RejectSelfUpline() public {
        address buyer = makeAddr("selfUp");
        _fundAndApprove(buyer);
        (address[] memory up, uint8[] memory ranks) = _oneUpline(buyer, HUNTER);
        uint256 deadline = block.timestamp + 600;
        bytes memory sig =
            _signAuth(buyer, uint8(IHNTRMembership.Tier.BRONZE), up, ranks, address(usdt), deadline, PURCHASE_OP);
        vm.prank(buyer);
        vm.expectRevert("Self upline");
        membership.purchaseMembership(buyer, IHNTRMembership.Tier.BRONZE, up, ranks, address(usdt), deadline, sig);
    }

    function test_RejectZeroUpline() public {
        address buyer = makeAddr("zeroUp");
        _fundAndApprove(buyer);
        address[] memory up = new address[](1);
        up[0] = address(0);
        uint8[] memory ranks = new uint8[](1);
        ranks[0] = HUNTER;
        uint256 deadline = block.timestamp + 600;
        bytes memory sig =
            _signAuth(buyer, uint8(IHNTRMembership.Tier.BRONZE), up, ranks, address(usdt), deadline, PURCHASE_OP);
        vm.prank(buyer);
        vm.expectRevert("Zero upline");
        membership.purchaseMembership(buyer, IHNTRMembership.Tier.BRONZE, up, ranks, address(usdt), deadline, sig);
    }

    function test_RejectDuplicateUpline() public {
        address buyer = makeAddr("dupUp");
        _fundAndApprove(buyer);
        address[] memory up = new address[](2);
        up[0] = rootUser;
        up[1] = rootUser;
        uint8[] memory ranks = new uint8[](2);
        ranks[0] = HUNTER;
        ranks[1] = HUNTER;
        uint256 deadline = block.timestamp + 600;
        bytes memory sig =
            _signAuth(buyer, uint8(IHNTRMembership.Tier.BRONZE), up, ranks, address(usdt), deadline, PURCHASE_OP);
        vm.prank(buyer);
        vm.expectRevert("Duplicate upline");
        membership.purchaseMembership(buyer, IHNTRMembership.Tier.BRONZE, up, ranks, address(usdt), deadline, sig);
    }

    function test_TooManyUplinesReverts() public {
        address buyer = makeAddr("tooMany");
        _fundAndApprove(buyer);
        address[] memory up = new address[](65);
        uint8[] memory ranks = new uint8[](65);
        for (uint256 i = 0; i < 65; i++) {
            up[i] = address(uint160(1000 + i));
            ranks[i] = HUNTER;
        }
        uint256 deadline = block.timestamp + 600;
        bytes memory sig =
            _signAuth(buyer, uint8(IHNTRMembership.Tier.BRONZE), up, ranks, address(usdt), deadline, PURCHASE_OP);
        vm.prank(buyer);
        vm.expectRevert("Too many uplines");
        membership.purchaseMembership(buyer, IHNTRMembership.Tier.BRONZE, up, ranks, address(usdt), deadline, sig);
    }

    function test_ZeroWalletSettersRejected() public {
        vm.expectRevert("Zero wallet");
        membership.setCompanyWallet(address(0));

        vm.expectRevert("Zero wallet");
        membership.setWallets(address(0), leadershipWallet, achievementWallet, poolWallet);

        vm.expectRevert("Zero wallet");
        membership.setWallets(treasuryWallet, address(0), achievementWallet, poolWallet);
    }

    function test_SetWalletsUpdates() public {
        address t = makeAddr("t2");
        address l = makeAddr("l2");
        address a = makeAddr("a2");
        address p = makeAddr("p2");
        membership.setWallets(t, l, a, p);
        assertEq(membership.treasuryWallet(), t);
        assertEq(membership.leadershipWallet(), l);
        assertEq(membership.achievementWallet(), a);
        assertEq(membership.poolWallet(), p);
    }

    function test_SolvencyInvariantAfterWithdraw() public {
        _assertSolvent();
        vm.prank(user1);
        membership.withdrawCommissions(user1, address(usdt));
        _assertSolvent();

        address buyer = makeAddr("solvBuyer");
        _fundAndApprove(buyer);
        (address[] memory up, uint8[] memory ranks) = _oneUpline(rootUser, HUNTER);
        _purchase(buyer, IHNTRMembership.Tier.GOLD, up, ranks);
        _assertSolvent();
    }
}
