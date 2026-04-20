# TAO Punks V2

**The community takes over.**

The original TAO Punks team deployed a contract with an unfrozen `setBaseURI()` — a kill switch that lets the owner rug every single holder's metadata and images at any moment. When the community discovered this, the team took the site down instead of fixing it.

So we fixed it ourselves.

---

## What V2 Changes

| V1 Problem | V2 Fix |
|---|---|
| `setBaseURI()` can rug all metadata | **No setter exists.** URI is set once in the constructor. There is no code path to change it — ever. |
| `freezeMetadata()` requires trust | **Removed.** Nothing to freeze when there's no setter. |
| `setDefaultRoyalty()` can extract fees | **No ERC2981.** 0% royalties, hardcoded at the interface level. |
| `mint()` public payable | **Removed.** No public minting. Airdrop only. |
| `ownerMint()` unlimited | **Removed.** `airdropBatch()` is owner-only and permanently locked after finalization. |
| `setPayoutRecipient()` redirects funds | **Removed.** No mint revenue to redirect. |
| No burn function | **`burn(tokenId)`** — holders control their own tokens. |
| Single-step ownership transfer | **Ownable2Step** — requires the new owner to explicitly accept. |

## What Stays the Same

- **3,333 tokens** — same max supply
- **"TAO Punks" / "TAOPUNK"** — same name and symbol
- **Token IDs 1–3333** — every V2 token ID matches its V1 original
- **Same IPFS metadata** — same CID, same images, same traits
- **ERC721A** — same gas-efficient standard

Your punk looks the same. Your token ID is the same. The only difference is that nobody can pull the rug.

---

## Architecture

```
TaoPunksV2
  ├── ERC721A              — Gas-optimized ERC721 (Chiru Labs v4.3.0)
  ├── ERC721ABurnable      — Holder-controlled burn
  ├── Ownable2Step         — Two-step ownership transfer (OpenZeppelin v5.1)
  ├── Pausable             — Emergency circuit breaker
  └── ReentrancyGuard      — Reentrancy protection
```

**122 lines of Solidity.** No bloat, no hidden functions, no admin backdoors.

### Key Functions

| Function | Access | Purpose |
|---|---|---|
| `airdropBatch(address[])` | Owner only | Mint tokens to snapshot recipients in order |
| `finalizeAirdrop()` | Owner only | Permanently lock minting — irreversible |
| `burn(tokenId)` | Token holder | Burn your own token |
| `pause()` / `unpause()` | Owner only | Emergency halt on all transfers |
| `renounceOwnership()` | **Disabled** | Always reverts — prevents lockout |

---

## Airdrop Strategy

1. **Snapshot** all 3,333 V1 token owners from on-chain data
2. **Build** ordered recipient array: `recipients[0]` = owner of V1 token #1, etc.
3. **Replace** confirmed team wallets with `0x000000000000000000000000000000000000dEaD`
4. **Execute** `airdropBatch()` in chunks of 100 (34 transactions)
5. **Finalize** — permanently lock minting

### Team Token Burns

8 tokens from 3 confirmed team wallets are sent to the dead address:

| Token IDs | V1 Wallet | Evidence |
|---|---|---|
| #91, #2034, #2036 | `0x58c9...20d6` | Contract deployer |
| #92, #443, #2859 | `0xC68A...77a9` | Direct deployer transfers |
| #442, #2858 | `0xDC97...0d41` | Direct deployer transfers |

These wallets were identified through on-chain forensic analysis of deployer transfer histories. Only wallets with confirmed deployer links are burned. The community voted on this list.

---

## Metadata

V2 points to the **exact same IPFS metadata** as V1:

```
tokenURI(1)
  → ipfs://bafybeielhkzlrzz6dhz4ixgtywf43s3z7mdpk4fysaqapehz3bijck6cqa/1
    → { "image": "ipfs://bafybeicvdilmqgjf23lrb4heggim3humcug7tcelcfayvnijvsbhphjboa/1.png" }
```

| Asset | CID | Files |
|---|---|---|
| Metadata JSON | `bafybeielhkzlrzz6dhz4ixgtywf43s3z7mdpk4fysaqapehz3bijck6cqa` | 3,333 |
| Image PNGs | `bafybeicvdilmqgjf23lrb4heggim3humcug7tcelcfayvnijvsbhphjboa` | 3,333 |

IPFS is content-addressed. Same CID = same data. The images and traits are identical.

---

## Audit

**50 out of 50 tests passing.** Full test suite in `test/TaoPunksV2.t.sol` (781 lines).

| Category | Tests | Status |
|---|---|---|
| Constructor & Metadata | 5 | All pass |
| Airdrop (core + edge cases) | 10 | All pass |
| Finalization | 4 | All pass |
| Burn | 5 | All pass |
| Pause | 6 | All pass |
| Ownership (Ownable2Step) | 4 | All pass |
| Interface (no ERC2981) | 2 | All pass |
| View helpers | 2 | All pass |
| Fuzz tests (256 runs each) | 2 | All pass |
| Security | 5 | All pass |
| Full 3,333-token simulation | 1 | All pass |
| Gas benchmarks | 3 | All pass |
| End-to-end CTO scenario | 1 | All pass |

### Security Checks

- No public mint function exists
- Owner cannot transfer or burn holder tokens
- Max supply (3,333) enforced as compile-time constant
- Reentrancy guard on airdropBatch
- `renounceOwnership()` permanently disabled
- No `setBaseURI` — verified at bytecode level
- `supportsInterface(ERC2981)` returns `false`

### Gas Benchmarks

| Operation | Gas |
|---|---|
| 100-token airdrop batch | ~4,700,000 |
| Single burn | ~28,000 |
| Single transfer | ~31,000 |

---

## Build & Test

```bash
# Install Foundry: https://book.getfoundry.sh/getting-started/installation
forge install
forge build
forge test -vv
```

## Deploy

```bash
# Set PRIVATE_KEY in ../.env
bash script/deploy-taopunks-v2.sh
```

## Execute Airdrop

```bash
node script/execute-airdrop.js <V2_CONTRACT_ADDRESS>
```

---

## Network

| | |
|---|---|
| **Chain** | Bittensor EVM |
| **Chain ID** | 964 |
| **V1 Contract** | `0xd7553eF9AFf4827451643dd13181D98A4832d718` |

---

## TAO Punks Agent Registry

**ERC-8004 + ERC-8041 | Pay-Per-Call AI Agents | 100% Holder Revenue**

The Agent Registry turns each TAO Punk into a queryable AI agent endpoint. Punk holders earn TAO every time someone queries their agent. No protocol fee — 100% of revenue goes to holders.

### How It Works

```
1. Holder activates their punk as an agent (one-time, irreversible)
2. Anyone queries the agent by paying TAO (0.0001 - 1 TAO per query)
3. Relay fulfills the query off-chain, credits 100% to the holder
4. Holder calls claim() to withdraw accumulated earnings
```

### Contract Architecture

```
TaoPunkAgentRegistry.sol (454 lines)
  ├── IERC8041Collection  — Fixed-supply agent NFT standard
  ├── AccessControl       — Role-based permissions (Admin, Governor, Fulfiller)
  └── ReentrancyGuard     — Mutex on query() and claim()
```

### Key Design Decisions

| Decision | Rationale |
|---|---|
| **100% to holders** | No protocol fee, no referrer split. Every wei of query revenue goes to the punk owner. |
| **Pull-based claim()** | Fees accumulate in `pendingWithdrawals`. Holders withdraw on their own schedule. Eliminates DOS vectors. |
| **Immutable economics** | Fee bounds (0.0001-1 TAO) and revenue model are Solidity `constant` — no admin can change them. |
| **fulfill() has zero external calls** | Pure storage write. Cannot be griefed by malicious holder contracts. |
| **Agent bound to punk** | Control follows `ownerOf()`. Sell your punk = sell your agent. No separate token. |

### Revenue Model (IMMUTABLE)

```solidity
MIN_QUERY_FEE = 0.0001 ether   // Minimum per query
MAX_QUERY_FEE = 1 ether         // Maximum per query

// fulfill() credits 100% to holder
// claim() withdraws accumulated balance
// 0% protocol fee. 0% referrer. 100% holder.
```

### Security Audit

**96 tests, 5 fuzz campaigns, 100% pass rate.**

| Category | Tests |
|---|---|
| Activation + Management | 17 |
| Query / Fulfill / Claim | 15 |
| Refund / Expiry | 3 |
| Governance | 7 |
| ERC-8041 Compliance | 4 |
| Hardened Security | 22 |
| Claim Edge Cases | 10 |
| Fuzz (1,281 runs) | 5 |
| Gas Benchmarks | 4 |
| End-to-End | 1 |
| **TOTAL** | **96** |

**Findings:** 2 HIGH (both RESOLVED), 1 LOW (acknowledged), 5 INFO (documented).

Full audit report: [`TaoPunks_AgentRegistry_Security_Audit.pdf`](./audit/TaoPunks_AgentRegistry_Security_Audit.pdf)

### Build & Test

```bash
cd contracts
forge install
forge build
forge test --match-contract TaoPunkAgentRegistryTest -vv
```

### Contracts

| Contract | Lines | Purpose |
|---|---|---|
| `src/TaoPunkAgentRegistry.sol` | 454 | ERC-8004 agent registry with pay-per-call |
| `src/TaoPunksV2.sol` | 122 | Immutable ERC721A (CTO collection) |
| `test/TaoPunkAgentRegistry.t.sol` | ~1500 | 96-test security suite |
| `test/TaoPunksV2.t.sol` | 781 | 50-test V2 suite |

---

*Built by the community, for the community. No team allocation. No royalties. No kill switches. Just punks.*
