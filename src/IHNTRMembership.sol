// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IHNTRMembership {
    enum Tier {
        NONE,
        SCOUT,
        TRACKER,
        RANGER,
        HUNTER,
        APEX
    }

    struct User {
        Tier tier;
        uint256 joinedAt;
    }

    function getUser(address user) external view returns (User memory);
    
    // The backend provides the `uplines` array for distribution.
    function purchaseMembership(Tier tier, address[] calldata uplines, address token) external;
    function upgradeMembership(Tier newTier, address[] calldata uplines, address token) external;
    
    function withdrawCommissions(address token) external;
}
