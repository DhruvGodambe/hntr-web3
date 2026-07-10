# Phase 1 Implementation Plan (Revised for Off-Chain Network)

Based on the feedback, we are pivoting to a vastly simplified on-chain architecture. Since the network tree, user emails/usernames, and complex 40/40/20 leg volume calculations will be handled by the **off-chain backend**, the smart contracts will act primarily as a secure payment gateway and commission escrow.

The Uniswap V4 and NFT Prize Pool mechanisms (Phase 2) are completely removed from this phase.

## Smart Contract Architecture

We will consolidate the logic into a main `HNTRMembership` (or `HNTRProtocol`) contract.

### 1. Wallets & State
The contract will store 3 primary system addresses:
- `treasuryWallet` (Receives 25%)
- `leadershipWallet` (Receives 5%)
- `achievementWallet` (Receives 5%)

The contract will store user state:
- `mapping(address => uint256) public userTiers;` (e.g., 1 = Scout, 5 = Apex)
- `mapping(address => uint256) public withdrawableCommissions;` (USDT balances)

### 2. Purchasing & Upgrading Tiers
When a user buys a tier (e.g., Scout for $50), they will call a function:
`function purchaseMembership(uint256 tier, address[] calldata uplines) external`

**The Flow:**
1. The contract pulls the required USDT/USDC from the user.
2. It instantly transfers 25% to `treasuryWallet`.
3. It instantly transfers 5% to `leadershipWallet`.
4. It instantly transfers 5% to `achievementWallet`.
5. It processes the remaining 65% through the `uplines` array provided by the backend.

### 3. Commission Distribution (65%)
The backend passes an array of up to 12 addresses representing the buyer's direct upline. The contract loops through this array:
- Level 1: 20%
- Level 2: 10%
- Level 3: 8%
- ...up to Level 12 (2%).

**Tier Depth Enforcement:**
For each level `i`, the contract checks the `userTiers[uplines[i]]`. 
- If `uplines[i]` is a **Scout** and `i > 3`, they *do not* qualify for the commission.
- If they do not qualify, the commission for that level is considered "breakage" and routed to the `treasuryWallet`.
- If they do qualify, the commission is added to their `withdrawableCommissions` balance inside the contract.

Users can call `withdrawCommissions()` at any time to claim their accumulated USDT.

---

## Wiring the Leadership & Achievement Pools

You asked how the Leadership Pool distributes shares and how users claim them. Here are the two ways we can wire this:

### Option A: Manual / Off-Chain Airdrop (Recommended, Matches PDF)
In the PDF, it says *"Leadership Bonus: Monthly (Manually)"*. 
- **How it works**: The 5% fee is simply transferred to a company-controlled Multi-Sig wallet (`leadershipWallet`). At the end of every month, your backend calculates exactly how much USDC each Hunter/Apex user deserves based on their rank shares. The admin then runs a script to airdrop the USDC directly to the users.
- **Pros**: Very simple smart contract. No gas costs for users. Total control over distribution.

### Option B: On-Chain Dividend Contract (Claimable)
- **How it works**: We create a separate `LeadershipPool.sol` contract. The 5% fee flows here. Because ranks are calculated off-chain, the Admin/Backend must call `updateUserShares(address user, uint256 newShares)` on the contract whenever someone ranks up. The contract uses complex staking math (a "reward per share" accumulator) to track who is owed what as the 5% continuously trickles in.
- **Pros**: Users click a "Claim Leadership Bonus" button on the dApp, making it feel more Web3 native.
- **Cons**: High gas costs. The backend still has to constantly push rank updates to the blockchain. 

## Proposed Changes

- **[DELETE]** `HNTRPool.sol`, `HNTRPoolManager.sol`, `HNTRCommissions.sol` (We no longer need separate auto-deposit, Uniswap V4, or pool logic).
- **[MODIFY]** `HNTRMembership.sol` to become the standalone protocol contract handling everything described above.
- **[MODIFY]** `test/HNTR.t.sol` to reflect the new off-chain upline array injection and commission logic.

---

## Open Questions

> [!WARNING]
> **Breakage / Unpaid Commissions**
> If an upline user does not have a high enough tier to receive a commission (e.g. a Scout missing out on a Level 4 commission), I plan to route that unpaid commission directly to the `treasuryWallet`. Is this the correct behavior for "breakage", or should it roll up to the next qualified person in the tree?

> [!IMPORTANT]
> **80/20 Rule Application**
> The PDF mentions "All Unilever commissions are divided rule 80/20, 80% instantly withdrawal and 20% is directed into first available pool." Since we are skipping the NFT pools for now, what should happen to the 20%? Should we just give them 100% of the commission as withdrawable USDT for Phase 1, or should the contract hold the 20% in a locked balance for when Phase 2 launches?
