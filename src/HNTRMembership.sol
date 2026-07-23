// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHNTRMembership} from "./IHNTRMembership.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Permit} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Ownable2Step} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

contract HNTRMembership is IHNTRMembership, Ownable2Step, Pausable, ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;

    bytes32 public constant PURCHASE_OP = keccak256("PURCHASE");
    bytes32 public constant UPGRADE_OP = keccak256("UPGRADE");
    uint256 public constant MAX_UPLINES = 64;

    /// @dev Caller-supplied deadlines are capped relative to block.timestamp so a
    /// leaked/coerced signature can never be crafted to stay valid for months.
    uint256 public constant MAX_SIGNATURE_VALIDITY = 1 hours;

    address public immutable usdt;
    address public immutable usdc;

    /// @dev Decimal scale shared by usdt/usdc, detected at deploy time and used to size
    /// tierPrices. Previously hardcoded to 1e6 (real-world USDT/USDC), which silently
    /// mis-scaled every transfer when deployed against non-6-decimal tokens — purchases
    /// went through but every amount shown on Etherscan rendered as a near-zero fraction
    /// of a cent. tierPrices are now derived from the tokens' actual decimals(), so the
    /// contract is correct for whatever decimal scale the two tokens actually share.
    uint8 public immutable tokenDecimals;

    address public treasuryWallet;
    address public leadershipWallet;
    address public achievementWallet;
    address public poolWallet;
    address public companyWallet;

    mapping(address => User) public users;

    address[] public allUsers;

    mapping(Tier => uint256) public tierPrices;

    mapping(address => mapping(address => uint256)) public withdrawableCommissions;
    mapping(address => mapping(address => uint256)) public lockedCommissions;

    mapping(address => uint256) public totalWithdrawable;

    // Seeded to the timestamp of a wallet's first commission credit so a never-claimed
    // wallet still gets a full 30-day grace period rather than being immediately sweepable.
    mapping(address => mapping(address => uint256)) public lastClaimedAt;

    mapping(address => uint256) public nonces;

    uint256 public signatureEpoch;

    /// @dev Commission-auth payloads can be signed by any individually-revocable
    /// authorized signer, not just a single companyWallet address.
    mapping(address => bool) public isAuthorizedSigner;

    /// @dev Protocol wallets' shares are credited here (pull-payment) instead of being
    /// pushed inline during purchase/upgrade. A frozen protocol wallet can no longer
    /// halt every sale.
    mapping(address => mapping(address => uint256)) public protocolBalances;
    mapping(address => uint256) public totalProtocolBalance;

    uint256[12] public levelPercentages = [15, 15, 8, 5, 4, 4, 4, 2, 2, 2, 2, 2];

    Tier[12] public tierRequiredForLevel = [
        Tier.NONE, Tier.NONE, Tier.NONE,
        Tier.BRONZE, Tier.SILVER, Tier.SILVER,
        Tier.GOLD, Tier.GOLD, Tier.GOLD, Tier.GOLD,
        Tier.PLATINUM, Tier.PLATINUM
    ];

    Rank[12] public rankRequiredForLevel = [
        Rank.NONE, Rank.NONE, Rank.NONE,
        Rank.SCOUT, Rank.TRACKER, Rank.TRACKER,
        Rank.RANGER, Rank.RANGER, Rank.RANGER, Rank.RANGER,
        Rank.HUNTER, Rank.HUNTER
    ];

    uint256 public constant CLAIM_GRACE_PERIOD = 30 days;

    /// @dev EIP-712 typed struct. Dynamic arrays (uplines/ranks) are pre-hashed into the
    /// struct as bytes32 fields so scalar fields remain visible to a hardware-wallet signer.
    bytes32 public constant COMMISSION_AUTH_TYPEHASH = keccak256(
        "CommissionAuth(address user,uint8 tier,bytes32 uplinesHash,bytes32 ranksHash,address token,uint256 deadline,uint256 nonce,uint256 signatureEpoch,bytes32 operation)"
    );

    event MembershipPurchased(address indexed user, Tier tier, uint256 amount, address token);
    event MembershipUpgraded(address indexed user, Tier oldTier, Tier newTier, uint256 amountPaid, address token);
    event CommissionEarned(address indexed user, uint256 liquidAmount, uint256 lockedAmount, uint8 level, address token);
    event CommissionWithdrawn(address indexed user, uint256 amount, address token);
    event CompanyWalletWithdrawn(address indexed user, address indexed token, uint256 amount, address indexed companyWallet);
    event WalletsUpdated(address treasury, address leadership, address achievement, address poolWallet);
    event CompanyWalletUpdated(address companyWallet);
    event SignaturesInvalidated(uint256 newEpoch);
    event TokensRescued(address indexed token, address indexed to, uint256 amount);
    event SignerAuthorized(address indexed signer);
    event SignerRevoked(address indexed signer);
    event ProtocolFundsCredited(address indexed wallet, address indexed token, uint256 amount);
    event ProtocolFundsWithdrawn(address indexed wallet, address indexed token, uint256 amount);

    modifier onlyCompanyWallet() {
        require(msg.sender == companyWallet, "Not company wallet");
        _;
    }

    constructor(address _usdt, address _usdc) Ownable(msg.sender) EIP712("HNTRMembership", "1") {
        require(_usdt != address(0) && _usdc != address(0), "Invalid token");

        uint8 decimals_ = IERC20Metadata(_usdt).decimals();
        require(decimals_ == IERC20Metadata(_usdc).decimals(), "USDT/USDC decimals mismatch");

        usdt = _usdt;
        usdc = _usdc;
        tokenDecimals = decimals_;

        uint256 unit = 10 ** decimals_;
        tierPrices[Tier.BRONZE] = 50 * unit;
        tierPrices[Tier.SILVER] = 250 * unit;
        tierPrices[Tier.GOLD] = 750 * unit;
        tierPrices[Tier.PLATINUM] = 1500 * unit;
        tierPrices[Tier.DIAMOND] = 2500 * unit;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function invalidateSignatures() external onlyOwner {
        signatureEpoch++;
        emit SignaturesInvalidated(signatureEpoch);
    }

    function authorizeSigner(address signer) external onlyOwner {
        require(signer != address(0), "Zero signer");
        isAuthorizedSigner[signer] = true;
        emit SignerAuthorized(signer);
    }

    function revokeSigner(address signer) external onlyOwner {
        isAuthorizedSigner[signer] = false;
        emit SignerRevoked(signer);
    }

    function setWallets(address _treasury, address _leadership, address _achievement, address _poolWallet)
        external
        onlyOwner
    {
        require(
            _treasury != address(0) && _leadership != address(0) && _achievement != address(0)
                && _poolWallet != address(0),
            "Zero wallet"
        );
        treasuryWallet = _treasury;
        leadershipWallet = _leadership;
        achievementWallet = _achievement;
        poolWallet = _poolWallet;
        emit WalletsUpdated(_treasury, _leadership, _achievement, _poolWallet);
    }

    function setCompanyWallet(address _companyWallet) external onlyOwner {
        require(_companyWallet != address(0), "Zero wallet");
        companyWallet = _companyWallet;
        isAuthorizedSigner[_companyWallet] = true;
        emit CompanyWalletUpdated(_companyWallet);
    }

    /// @notice Disabled — every incident-response control is onlyOwner; an irreversible
    /// renounce would permanently disable all of them with no recovery path.
    function renounceOwnership() public view override onlyOwner {
        revert("Renounce disabled");
    }

    /// @notice Rescue tokens mistakenly sent to this contract.
    /// For USDT/USDC, cannot reduce the balance below outstanding liabilities.
    function rescueToken(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Zero recipient");
        require(amount > 0, "Zero amount");

        if (token == usdt || token == usdc) {
            uint256 bal = IERC20(token).balanceOf(address(this));
            uint256 liabilities = totalWithdrawable[token] + totalProtocolBalance[token];
            require(bal >= amount, "Insufficient balance");
            require(bal - amount >= liabilities, "Below liabilities");
        }

        IERC20(token).safeTransfer(to, amount);
        emit TokensRescued(token, to, amount);
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
    ) external override whenNotPaused nonReentrant {
        _executePurchase(user, tier, uplines, ranks, token, deadline, signature);
    }

    /// @notice Authorizes the token pull via an off-chain EIP-2612 permit signature
    /// instead of a separate on-chain approve() transaction — collapsing two wallet
    /// confirmations into a single transaction for tokens that implement permit.
    function purchaseMembershipWithPermit(
        address user,
        Tier tier,
        address[] calldata uplines,
        uint8[] calldata ranks,
        address token,
        uint256 deadline,
        bytes calldata signature,
        uint256 permitValue,
        uint256 permitDeadline,
        uint8 permitV,
        bytes32 permitR,
        bytes32 permitS
    ) external whenNotPaused nonReentrant {
        _permitToken(token, user, permitValue, permitDeadline, permitV, permitR, permitS);
        _executePurchase(user, tier, uplines, ranks, token, deadline, signature);
    }

    function upgradeMembership(
        address user,
        Tier newTier,
        address[] calldata uplines,
        uint8[] calldata ranks,
        address token,
        uint256 deadline,
        bytes calldata signature
    ) external override whenNotPaused nonReentrant {
        _executeUpgrade(user, newTier, uplines, ranks, token, deadline, signature);
    }

    /// @notice Permit-based counterpart to upgradeMembership.
    function upgradeMembershipWithPermit(
        address user,
        Tier newTier,
        address[] calldata uplines,
        uint8[] calldata ranks,
        address token,
        uint256 deadline,
        bytes calldata signature,
        uint256 permitValue,
        uint256 permitDeadline,
        uint8 permitV,
        bytes32 permitR,
        bytes32 permitS
    ) external whenNotPaused nonReentrant {
        _permitToken(token, user, permitValue, permitDeadline, permitV, permitR, permitS);
        _executeUpgrade(user, newTier, uplines, ranks, token, deadline, signature);
    }

    /// @dev Best-effort permit call. Wrapped in try/catch so a stale or unnecessary permit
    /// signature cannot itself revert the transaction — if the resulting allowance is
    /// genuinely insufficient, the safeTransferFrom pull further down reverts on its own.
    function _permitToken(
        address token,
        address owner_,
        uint256 value,
        uint256 permitDeadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal {
        try IERC20Permit(token).permit(owner_, address(this), value, permitDeadline, v, r, s) {}
        catch {}
    }

    function _executePurchase(
        address user,
        Tier tier,
        address[] calldata uplines,
        uint8[] calldata ranks,
        address token,
        uint256 deadline,
        bytes calldata signature
    ) internal {
        require(msg.sender == user, "Not authorized");
        require(tier != Tier.NONE, "Invalid tier");
        require(users[user].tier == Tier.NONE, "Already a member");
        require(token == usdt || token == usdc, "Unsupported token");

        _verifyCommissionAuth(user, uint8(tier), uplines, ranks, token, deadline, PURCHASE_OP, signature);
        nonces[user]++;

        uint256 price = tierPrices[tier];
        require(price > 0, "Tier price not set");

        users[user] = User({tier: tier, joinedAt: block.timestamp});
        allUsers.push(user);

        uint256 received = _processPaymentAndDistribution(user, price, uplines, ranks, token);

        emit MembershipPurchased(user, tier, received, token);
    }

    function _executeUpgrade(
        address user,
        Tier newTier,
        address[] calldata uplines,
        uint8[] calldata ranks,
        address token,
        uint256 deadline,
        bytes calldata signature
    ) internal {
        require(msg.sender == user, "Not authorized");
        User storage u = users[user];
        require(u.tier != Tier.NONE, "Not a member");
        require(uint8(newTier) > uint8(u.tier), "Can only upgrade to higher tier");
        require(token == usdt || token == usdc, "Unsupported token");

        _verifyCommissionAuth(user, uint8(newTier), uplines, ranks, token, deadline, UPGRADE_OP, signature);
        nonces[user]++;

        uint256 priceDiff = tierPrices[newTier] - tierPrices[u.tier];
        Tier oldTier = u.tier;
        u.tier = newTier;

        uint256 received = _processPaymentAndDistribution(user, priceDiff, uplines, ranks, token);

        emit MembershipUpgraded(user, oldTier, newTier, received, token);
    }

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
        require(deadline <= block.timestamp + MAX_SIGNATURE_VALIDITY, "Deadline too far");
        require(uplines.length == ranks.length, "Length mismatch");
        require(uplines.length <= MAX_UPLINES, "Too many uplines");

        _validateUplines(user, uplines);

        for (uint256 i = 0; i < ranks.length; i++) {
            require(ranks[i] <= uint8(Rank.HUNTER), "Invalid rank");
        }

        bytes32 digest = _commissionAuthHash(user, tier, uplines, ranks, token, deadline, operation);
        address signer = ECDSA.recover(digest, signature);
        require(isAuthorizedSigner[signer], "Invalid signature");
    }

    /// @dev EIP-712 typed-data hash. Arrays are pre-hashed to keep the struct's scalar
    /// fields visible to a typed-data-aware signer while staying EIP-712-compliant.
    function _commissionAuthHash(
        address user,
        uint8 tier,
        address[] calldata uplines,
        uint8[] calldata ranks,
        address token,
        uint256 deadline,
        bytes32 operation
    ) internal view returns (bytes32) {
        bytes32 uplinesHash = keccak256(abi.encode(uplines));
        bytes32 ranksHash = keccak256(abi.encode(ranks));
        bytes32 structHash = keccak256(
            abi.encode(
                COMMISSION_AUTH_TYPEHASH,
                user,
                tier,
                uplinesHash,
                ranksHash,
                token,
                deadline,
                nonces[user],
                signatureEpoch,
                operation
            )
        );
        return _hashTypedDataV4(structHash);
    }

    function _validateUplines(address payer, address[] calldata uplines) internal pure {
        for (uint256 i = 0; i < uplines.length; i++) {
            address upline = uplines[i];
            require(upline != address(0), "Zero upline");
            require(upline != payer, "Self upline");
            for (uint256 j = 0; j < i; j++) {
                require(uplines[j] != upline, "Duplicate upline");
            }
        }
    }

    /// @dev Try to push tokens directly to the protocol wallet. If the transfer fails
    /// (e.g. wallet is frozen/blacklisted by the token issuer), fall back to crediting
    /// the pull-payment balance so a single frozen wallet cannot halt all purchases.
    function _creditProtocol(address wallet, address token, uint256 amount) internal {
        if (amount == 0) return;
        (bool success, bytes memory ret) = token.call(abi.encodeCall(IERC20.transfer, (wallet, amount)));
        if (success && (ret.length == 0 || abi.decode(ret, (bool)))) {
            emit ProtocolFundsCredited(wallet, token, amount);
        } else {
            protocolBalances[wallet][token] += amount;
            totalProtocolBalance[token] += amount;
            emit ProtocolFundsCredited(wallet, token, amount);
        }
    }

    /// @dev Credits a member's commission balance and seeds lastClaimedAt on first-ever
    /// credit so the 30-day grace period starts from when they first earn, not from zero.
    function _creditCommission(address upline, address token, uint256 liquid) internal {
        withdrawableCommissions[upline][token] += liquid;
        totalWithdrawable[token] += liquid;
        if (lastClaimedAt[upline][token] == 0) {
            lastClaimedAt[upline][token] = block.timestamp;
        }
    }

    function _processPaymentAndDistribution(
        address payer,
        uint256 amount,
        address[] calldata uplines,
        uint8[] calldata ranks,
        address token
    ) internal returns (uint256 received) {
        uint256 beforeBal = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(payer, address(this), amount);
        received = IERC20(token).balanceOf(address(this)) - beforeBal;
        require(received > 0, "No tokens received");

        _creditProtocol(treasuryWallet, token, (received * 25) / 100);
        _creditProtocol(leadershipWallet, token, (received * 5) / 100);
        _creditProtocol(achievementWallet, token, (received * 5) / 100);

        uint256 distributedAmount = 0;
        uint8 currentLevel = 1;

        for (uint256 i = 0; i < uplines.length && currentLevel <= 12; i++) {
            address upline = uplines[i];
            Tier uplineTier = users[upline].tier;
            Rank uplineRank = Rank(ranks[i]);

            if (
                uplineTier != Tier.NONE && uplineTier >= tierRequiredForLevel[currentLevel - 1]
                    && uplineRank >= rankRequiredForLevel[currentLevel - 1]
            ) {
                uint256 levelCut = (received * levelPercentages[currentLevel - 1]) / 100;
                distributedAmount += levelCut;

                uint256 liquid = (levelCut * 80) / 100;
                uint256 locked = levelCut - liquid;

                _creditCommission(upline, token, liquid);
                lockedCommissions[upline][token] += locked;

                _creditProtocol(poolWallet, token, locked);

                emit CommissionEarned(upline, liquid, locked, currentLevel, token);

                currentLevel++;
            }
        }

        uint256 maxCommission = (received * 65) / 100;
        if (distributedAmount < maxCommission) {
            _creditProtocol(treasuryWallet, token, maxCommission - distributedAmount);
        }
    }

    /// @notice Lets a protocol wallet pull its accrued share on demand.
    function withdrawProtocolBalance(address token) external nonReentrant {
        require(token == usdt || token == usdc, "Unsupported token");

        uint256 amount = protocolBalances[msg.sender][token];
        require(amount > 0, "No balance to withdraw");

        protocolBalances[msg.sender][token] = 0;
        totalProtocolBalance[token] -= amount;
        IERC20(token).safeTransfer(msg.sender, amount);

        emit ProtocolFundsWithdrawn(msg.sender, token, amount);
    }

    function withdrawCommissions(address user, address token) external override nonReentrant {
        require(msg.sender == user, "Not authorized");
        require(token == usdt || token == usdc, "Unsupported token");

        uint256 amount = withdrawableCommissions[user][token];
        require(amount > 0, "No commissions to withdraw");

        _withdraw(user, token, amount, false);
    }

    function withdrawCompanyWallet(address user, address token) external onlyCompanyWallet nonReentrant {
        require(token == usdt || token == usdc, "Unsupported token");
        require(
            lastClaimedAt[user][token] == 0 || block.timestamp > lastClaimedAt[user][token] + CLAIM_GRACE_PERIOD,
            "Claim not overdue"
        );

        uint256 amount = withdrawableCommissions[user][token];
        require(amount > 0, "No commissions to withdraw");

        _withdraw(user, token, amount, true);
        emit CompanyWalletWithdrawn(user, token, amount, msg.sender);
    }

    /// @dev viaCompanyWallet suppresses the generic CommissionWithdrawn event when the
    /// caller already emits the more specific CompanyWalletWithdrawn.
    function _withdraw(address user, address token, uint256 amount, bool viaCompanyWallet) internal {
        withdrawableCommissions[user][token] = 0;
        totalWithdrawable[token] -= amount;
        IERC20(token).safeTransfer(user, amount);
        lastClaimedAt[user][token] = block.timestamp;
        if (!viaCompanyWallet) {
            emit CommissionWithdrawn(user, amount, token);
        }
    }

    function getOverdueWallets(address token) external view onlyCompanyWallet returns (address[] memory overdue) {
        require(token == usdt || token == usdc, "Unsupported token");

        uint256 len = allUsers.length;
        overdue = new address[](len);
        uint256 count = 0;

        for (uint256 i = 0; i < len; i++) {
            address user = allUsers[i];
            if (
                withdrawableCommissions[user][token] > 0
                    && (lastClaimedAt[user][token] == 0
                        || block.timestamp > lastClaimedAt[user][token] + CLAIM_GRACE_PERIOD)
            ) {
                overdue[count++] = user;
            }
        }

        assembly ("memory-safe") {
            mstore(overdue, count)
        }
    }
}
