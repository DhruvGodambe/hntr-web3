// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHNTRMembership} from "./IHNTRMembership.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

contract HNTRMembership is IHNTRMembership {
    using SafeERC20 for IERC20;

    address public immutable usdt;
    address public immutable usdc;
    
    address public treasuryWallet;
    address public leadershipWallet;
    address public achievementWallet;
    address public owner;

    mapping(address => User) public users;
    
    // Tier pricing in stablecoin units
    mapping(Tier => uint256) public tierPrices;
    // Max levels deep a tier can earn from
    mapping(Tier => uint8) public tierMaxLevels;

    // Commission Balances: User => Token => Amount
    mapping(address => mapping(address => uint256)) public withdrawableCommissions;
    mapping(address => mapping(address => uint256)) public lockedCommissions;

    uint256[12] public levelPercentages = [20, 10, 8, 5, 4, 4, 4, 2, 2, 2, 2, 2];

    event MembershipPurchased(address indexed user, Tier tier, uint256 amount, address token);
    event MembershipUpgraded(address indexed user, Tier oldTier, Tier newTier, uint256 amountPaid, address token);
    event CommissionEarned(address indexed user, uint256 liquidAmount, uint256 lockedAmount, uint8 level, address token);
    event CommissionWithdrawn(address indexed user, uint256 amount, address token);
    event WalletsUpdated(address treasury, address leadership, address achievement);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor(
        address _usdt,
        address _usdc
    ) {
        usdt = _usdt;
        usdc = _usdc;
        owner = msg.sender;

        // Initialize tier prices
        tierPrices[Tier.SCOUT] = 50 * 1e6;
        tierPrices[Tier.TRACKER] = 250 * 1e6;
        tierPrices[Tier.RANGER] = 750 * 1e6;
        tierPrices[Tier.HUNTER] = 1500 * 1e6;
        tierPrices[Tier.APEX] = 2500 * 1e6;

        // Initialize tier depths
        tierMaxLevels[Tier.SCOUT] = 3;
        tierMaxLevels[Tier.TRACKER] = 6;
        tierMaxLevels[Tier.RANGER] = 9;
        tierMaxLevels[Tier.HUNTER] = 12;
        tierMaxLevels[Tier.APEX] = 12;
    }

    function setWallets(address _treasury, address _leadership, address _achievement) external onlyOwner {
        treasuryWallet = _treasury;
        leadershipWallet = _leadership;
        achievementWallet = _achievement;
        emit WalletsUpdated(_treasury, _leadership, _achievement);
    }

    function getUser(address user) external view override returns (User memory) {
        return users[user];
    }

    function purchaseMembership(Tier tier, address[] calldata uplines, address token) external override {
        require(tier != Tier.NONE, "Invalid tier");
        require(users[msg.sender].tier == Tier.NONE, "Already a member");
        require(token == usdt || token == usdc, "Unsupported token");

        uint256 price = tierPrices[tier];
        require(price > 0, "Tier price not set");

        users[msg.sender] = User({
            tier: tier,
            joinedAt: block.timestamp
        });

        _processPaymentAndDistribution(price, uplines, token);

        emit MembershipPurchased(msg.sender, tier, price, token);
    }

    function upgradeMembership(Tier newTier, address[] calldata uplines, address token) external override {
        User storage user = users[msg.sender];
        require(user.tier != Tier.NONE, "Not a member");
        require(uint8(newTier) > uint8(user.tier), "Can only upgrade to higher tier");
        require(token == usdt || token == usdc, "Unsupported token");

        uint256 priceDiff = tierPrices[newTier] - tierPrices[user.tier];
        Tier oldTier = user.tier;
        user.tier = newTier;

        _processPaymentAndDistribution(priceDiff, uplines, token);

        emit MembershipUpgraded(msg.sender, oldTier, newTier, priceDiff, token);
    }

    function _processPaymentAndDistribution(uint256 amount, address[] calldata uplines, address token) internal {
        // Pull funds from user
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        {
            // 1. Treasury (25%)
            IERC20(token).safeTransfer(treasuryWallet, (amount * 25) / 100);

            // 2. Leadership Pool (5%)
            IERC20(token).safeTransfer(leadershipWallet, (amount * 5) / 100);

            // 3. Achievement Bonus (5%)
            IERC20(token).safeTransfer(achievementWallet, (amount * 5) / 100);
        }

        // 4. Commission Distribution (65% total via Dynamic Compression)
        uint256 distributedAmount = 0;
        uint8 currentLevelToPay = 1;

        for (uint256 i = 0; i < uplines.length; i++) {
            if (currentLevelToPay > 12) break;

            address upline = uplines[i];
            Tier uplineTier = users[upline].tier;

            // Check if upline is qualified for the current level depth
            if (uplineTier != Tier.NONE && tierMaxLevels[uplineTier] >= currentLevelToPay) {
                // Qualified! Calculate their cut
                uint256 levelCut = (amount * levelPercentages[currentLevelToPay - 1]) / 100;
                distributedAmount += levelCut;

                uint256 liquid = (levelCut * 80) / 100;
                uint256 locked = levelCut - liquid;

                withdrawableCommissions[upline][token] += liquid;
                lockedCommissions[upline][token] += locked;

                emit CommissionEarned(upline, liquid, locked, currentLevelToPay, token);

                currentLevelToPay++;
            }
        }

        // 5. Breakage (Unpaid commissions go to Treasury)
        uint256 maxCommission = (amount * 65) / 100;
        if (distributedAmount < maxCommission) {
            IERC20(token).safeTransfer(treasuryWallet, maxCommission - distributedAmount);
        }
    }

    function withdrawCommissions(address token) external override {
        require(token == usdt || token == usdc, "Unsupported token");

        uint256 amount = withdrawableCommissions[msg.sender][token];
        require(amount > 0, "No commissions to withdraw");

        withdrawableCommissions[msg.sender][token] = 0;
        IERC20(token).safeTransfer(msg.sender, amount);

        emit CommissionWithdrawn(msg.sender, amount, token);
    }
}
