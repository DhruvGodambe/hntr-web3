// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IHNTRMembership {
    enum Tier {
        NONE,
        BRONZE,
        SILVER,
        GOLD,
        PLATINUM,
        DIAMOND
    }

    // Used only in signed commission auth payloads (ranks live off-chain).
    enum Rank {
        NONE,
        SCOUT,
        TRACKER,
        RANGER,
        HUNTER
    }

    struct User {
        Tier tier;
        uint256 joinedAt;
    }

    function getUser(address user) external view returns (User memory);

    // --- Core purchase/upgrade surface ---------------------------------------------
    // Backend signs (uplines, ranks, deadline, nonce, signatureEpoch). User pays gas and submits the tx.
    function purchaseMembership(
        address user,
        Tier tier,
        address[] calldata uplines,
        uint8[] calldata ranks,
        address token,
        uint256 deadline,
        bytes calldata signature
    ) external;

    function upgradeMembership(
        address user,
        Tier newTier,
        address[] calldata uplines,
        uint8[] calldata ranks,
        address token,
        uint256 deadline,
        bytes calldata signature
    ) external;

    // --- Permit-based variants (single wallet transaction, no separate approve) -----
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
    ) external;

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
    ) external;

    // --- Withdrawals -----------------------------------------------------------------
    function withdrawCommissions(address user, address token) external;
    function withdrawCompanyWallet(address user, address token) external;
    function withdrawProtocolBalance(address token) external;

    // --- Company-wallet views ---------------------------------------------------------
    function getOverdueWallets(address token) external view returns (address[] memory);

    // --- Administrative surface (all onlyOwner) ---------------------------------------
    function pause() external;
    function unpause() external;
    function invalidateSignatures() external;
    function authorizeSigner(address signer) external;
    function revokeSigner(address signer) external;
    function setWallets(address _treasury, address _leadership, address _achievement, address _poolWallet) external;
    function setCompanyWallet(address _companyWallet) external;
    function rescueToken(address token, address to, uint256 amount) external;
}
