// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHNTRMembership} from "./IHNTRMembership.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "openzeppelin-contracts/contracts/utils/cryptography/MessageHashUtils.sol";

contract HNTRMembership is IHNTRMembership {
    using SafeERC20 for IERC20;

    bytes32 public constant PURCHASE_OP = keccak256("PURCHASE");
    bytes32 public constant UPGRADE_OP = keccak256("UPGRADE");

    address public immutable usdt;
    address public immutable usdc;

    address public treasuryWallet;
    address public leadershipWallet;
    address public achievementWallet;
    address public poolWallet;
    address public companyWallet;
    address public owner;

    mapping(address => User) public users;

    // Iterable list of all members so the company wallet can scan for overdue claims.
    address[] public allUsers;

    // Tier pricing in stablecoin units (assumes 6 decimals, e.g. USDT/USDC).
    mapping(Tier => uint256) public tierPrices;

    // Commission Balances: User => Token => Amount
    mapping(address => mapping(address => uint256)) public withdrawableCommissions;
    mapping(address => mapping(address => uint256)) public lockedCommissions;

    // Last time a user claimed commissions for a specific token.
    mapping(address => mapping(address => uint256)) public lastClaimedAt;

    // Unilevel commission percentages by level (1-based index).
    uint256[12] public levelPercentages = [15, 15, 8, 5, 4, 4, 4, 2, 2, 2, 2, 2];

    // Minimum membership tier required to earn from each level.
    // L1-3: any member | L4: Bronze | L5-6: Silver | L7-10: Gold | L11-12: Platinum
    Tier[12] public tierRequiredForLevel = [
        Tier.NONE, Tier.NONE, Tier.NONE,
        Tier.BRONZE, Tier.SILVER, Tier.SILVER,
        Tier.GOLD, Tier.GOLD, Tier.GOLD, Tier.GOLD,
        Tier.PLATINUM, Tier.PLATINUM
    ];

    // Minimum rank required to earn from each level (rank comes from backend signature).
    // L1-3: Default | L4: Scout | L5-6: Tracker | L7-10: Ranger | L11-12: Hunter
    Rank[12] public rankRequiredForLevel = [
        Rank.NONE, Rank.NONE, Rank.NONE,
        Rank.SCOUT, Rank.TRACKER, Rank.TRACKER,
        Rank.RANGER, Rank.RANGER, Rank.RANGER, Rank.RANGER,
        Rank.HUNTER, Rank.HUNTER
    ];

    uint256 public constant CLAIM_GRACE_PERIOD = 30 days;

    event MembershipPurchased(address indexed user, Tier tier, uint256 amount, address token);
    event MembershipUpgraded(address indexed user, Tier oldTier, Tier newTier, uint256 amountPaid, address token);
    event CommissionEarned(address indexed user, uint256 liquidAmount, uint256 lockedAmount, uint8 level, address token);
    event CommissionWithdrawn(address indexed user, uint256 amount, address token);
    event CompanyWalletWithdrawn(address indexed user, address indexed token, uint256 amount, address indexed companyWallet);
    event WalletsUpdated(address treasury, address leadership, address achievement, address poolWallet);
    event CompanyWalletUpdated(address companyWallet);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier onlyCompanyWallet() {
        require(msg.sender == companyWallet, "Not company wallet");
        _;
    }

    constructor(
        address _usdt,
        address _usdc
    ) {
        usdt = _usdt;
        usdc = _usdc;
        owner = msg.sender;

        // Initialize tier prices (in 6-decimal stablecoin units).
        tierPrices[Tier.BRONZE] = 50 * 1e6;
        tierPrices[Tier.SILVER] = 250 * 1e6;
        tierPrices[Tier.GOLD] = 750 * 1e6;
        tierPrices[Tier.PLATINUM] = 1500 * 1e6;
        tierPrices[Tier.DIAMOND] = 2500 * 1e6;
    }

    function setWallets(address _treasury, address _leadership, address _achievement, address _poolWallet) external onlyOwner {
        treasuryWallet = _treasury;
        leadershipWallet = _leadership;
        achievementWallet = _achievement;
        poolWallet = _poolWallet;
        emit WalletsUpdated(_treasury, _leadership, _achievement, _poolWallet);
    }

    function setCompanyWallet(address _companyWallet) external onlyOwner {
        companyWallet = _companyWallet;
        emit CompanyWalletUpdated(_companyWallet);
    }

    function getUser(address user) external view override returns (User memory) {
        return users[user];
    }

    function purchaseMembership(
        address user,
        Tier tier,
        address[] calldata uplines,
        uint8[] calldata ranks,
        address token,
        uint256 deadline,
        bytes calldata signature
    ) external override {
        require(msg.sender == user, "Not authorized");
        require(tier != Tier.NONE, "Invalid tier");
        require(users[user].tier == Tier.NONE, "Already a member");
        require(token == usdt || token == usdc, "Unsupported token");

        _verifyCommissionAuth(user, uint8(tier), uplines, ranks, token, deadline, PURCHASE_OP, signature);

        uint256 price = tierPrices[tier];
        require(price > 0, "Tier price not set");

        users[user] = User({
            tier: tier,
            joinedAt: block.timestamp
        });

        allUsers.push(user);

        _processPaymentAndDistribution(user, price, uplines, ranks, token);

        emit MembershipPurchased(user, tier, price, token);
    }

    function upgradeMembership(
        address user,
        Tier newTier,
        address[] calldata uplines,
        uint8[] calldata ranks,
        address token,
        uint256 deadline,
        bytes calldata signature
    ) external override {
        require(msg.sender == user, "Not authorized");
        User storage u = users[user];
        require(u.tier != Tier.NONE, "Not a member");
        require(uint8(newTier) > uint8(u.tier), "Can only upgrade to higher tier");
        require(token == usdt || token == usdc, "Unsupported token");

        _verifyCommissionAuth(user, uint8(newTier), uplines, ranks, token, deadline, UPGRADE_OP, signature);

        uint256 priceDiff = tierPrices[newTier] - tierPrices[u.tier];
        Tier oldTier = u.tier;
        u.tier = newTier;

        _processPaymentAndDistribution(user, priceDiff, uplines, ranks, token);

        emit MembershipUpgraded(user, oldTier, newTier, priceDiff, token);
    }

    /// @dev Verifies a company-wallet signature over the commission auth payload.
    function _verifyCommissionAuth(
        address user,
        uint8 tier,
        address[] calldata uplines,
        uint8[] calldata ranks,
        address token,
        uint256 deadline,
        bytes32 operation,
        bytes calldata signature
    ) internal view {
        require(companyWallet != address(0), "Company wallet not set");
        require(block.timestamp <= deadline, "Signature expired");
        require(uplines.length == ranks.length, "Length mismatch");

        for (uint256 i = 0; i < ranks.length; i++) {
            require(ranks[i] <= uint8(Rank.HUNTER), "Invalid rank");
        }

        bytes32 structHash = keccak256(
            abi.encode(
                user,
                tier,
                uplines,
                ranks,
                token,
                deadline,
                block.chainid,
                address(this),
                operation
            )
        );

        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(structHash);
        address signer = ECDSA.recover(digest, signature);
        require(signer == companyWallet, "Invalid signature");
    }

    function _processPaymentAndDistribution(
        address payer,
        uint256 amount,
        address[] calldata uplines,
        uint8[] calldata ranks,
        address token
    ) internal {
        // Pull funds from payer
        IERC20(token).safeTransferFrom(payer, address(this), amount);

        {
            // 1. Treasury (25%): 5% base + 20% reallocated from pool wallet
            IERC20(token).safeTransfer(treasuryWallet, (amount * 25) / 100);

            // 2. Leadership Pool (5%)
            IERC20(token).safeTransfer(leadershipWallet, (amount * 5) / 100);

            // 3. Achievement Bonus (5%)
            IERC20(token).safeTransfer(achievementWallet, (amount * 5) / 100);
        }

        // 4. Commission Distribution (65% total via Dynamic Compression)
        uint256 distributedAmount = 0;
        uint8 currentLevel = 1;

        for (uint256 i = 0; i < uplines.length && currentLevel <= 12; i++) {
            address upline = uplines[i];
            Tier uplineTier = users[upline].tier;
            Rank uplineRank = Rank(ranks[i]);

            // Skip non-members and anyone who doesn't meet the level's tier + rank gate.
            if (
                uplineTier != Tier.NONE &&
                uplineTier >= tierRequiredForLevel[currentLevel - 1] &&
                uplineRank >= rankRequiredForLevel[currentLevel - 1]
            ) {
                // Qualified! Calculate their cut
                uint256 levelCut = (amount * levelPercentages[currentLevel - 1]) / 100;
                distributedAmount += levelCut;

                uint256 liquid = (levelCut * 80) / 100;
                uint256 locked = levelCut - liquid;

                withdrawableCommissions[upline][token] += liquid;
                lockedCommissions[upline][token] += locked;

                // Locked value is transferred to the pool wallet
                IERC20(token).safeTransfer(poolWallet, locked);

                emit CommissionEarned(upline, liquid, locked, currentLevel, token);

                currentLevel++;
            }
        }

        // 5. Breakage (Unpaid commissions go to Treasury)
        uint256 maxCommission = (amount * 65) / 100;
        if (distributedAmount < maxCommission) {
            IERC20(token).safeTransfer(treasuryWallet, maxCommission - distributedAmount);
        }
    }

    function withdrawCommissions(address user, address token) external override {
        require(msg.sender == user, "Not authorized");
        require(token == usdt || token == usdc, "Unsupported token");

        uint256 amount = withdrawableCommissions[user][token];
        require(amount > 0, "No commissions to withdraw");

        _withdraw(user, token, amount);
    }

    /// @notice Allows the company wallet to withdraw claimable commissions on behalf of a user
    /// whose last claim is at least 30 days old. Funds are sent to the user.
    function withdrawCompanyWallet(address user, address token) external onlyCompanyWallet {
        require(token == usdt || token == usdc, "Unsupported token");
        require(
            lastClaimedAt[user][token] == 0 || block.timestamp > lastClaimedAt[user][token] + CLAIM_GRACE_PERIOD,
            "Claim not overdue"
        );

        uint256 amount = withdrawableCommissions[user][token];
        require(amount > 0, "No commissions to withdraw");

        _withdraw(user, token, amount);
        emit CompanyWalletWithdrawn(user, token, amount, msg.sender);
    }

    function _withdraw(address user, address token, uint256 amount) internal {
        withdrawableCommissions[user][token] = 0;
        IERC20(token).safeTransfer(user, amount);
        lastClaimedAt[user][token] = block.timestamp;
        emit CommissionWithdrawn(user, amount, token);
    }

    /// @notice Returns all wallets with overdue claims for a given token.
    /// A wallet is overdue if it has withdrawable commissions and has not claimed
    /// the token for more than 30 days (or never claimed).
    function getOverdueWallets(address token) external view onlyCompanyWallet returns (address[] memory) {
        require(token == usdt || token == usdc, "Unsupported token");

        uint256 count = 0;
        for (uint256 i = 0; i < allUsers.length; i++) {
            address user = allUsers[i];
            if (
                withdrawableCommissions[user][token] > 0 &&
                (lastClaimedAt[user][token] == 0 || block.timestamp > lastClaimedAt[user][token] + CLAIM_GRACE_PERIOD)
            ) {
                count++;
            }
        }

        address[] memory overdue = new address[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < allUsers.length; i++) {
            address user = allUsers[i];
            if (
                withdrawableCommissions[user][token] > 0 &&
                (lastClaimedAt[user][token] == 0 || block.timestamp > lastClaimedAt[user][token] + CLAIM_GRACE_PERIOD)
            ) {
                overdue[index++] = user;
            }
        }

        return overdue;
    }
}
