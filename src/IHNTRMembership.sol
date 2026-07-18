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

    // Backend signs (uplines, ranks, deadline). User pays gas and submits the tx.
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

    function withdrawCommissions(address user, address token) external;
    function withdrawCompanyWallet(address user, address token) external;
}
