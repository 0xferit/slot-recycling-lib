# slot-recycling-lib

[![lifecycle (50% reuse): gas saved](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/0xferit/slot-recycling-lib/gh-badges/.badges/recycling-savings.json)](test/showcase/ShowcaseGas.t.sol)
[![per recycled write: gas saved](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/0xferit/slot-recycling-lib/gh-badges/.badges/bestcase-savings.json)](test/showcase/ShowcaseGas.t.sol)

EVM charges ~20,000 gas for a zero-to-nonzero SSTORE but only ~2,900 gas (warm) for nonzero-to-nonzero. In mapping-backed collections with churn, this library recycles freed slots by leaving a non-zero "tombstone" on deletion instead of fully zeroing. The next allocation overwrites the tombstoned slot at the cheaper rate.

## How it works

When a Solidity contract uses `delete` on a mapping entry, the slot is set to zero. The next time that slot is written, the EVM treats it as a zero-to-nonzero transition and charges the full 20,000 gas SSTORE cost.

This library avoids that by never fully zeroing a slot. On deletion, it clears only the bits you specify (via a "clear mask") and leaves the rest as a non-zero tombstone. The slot stays dirty, so the next write is a cheap nonzero-to-nonzero transition (~2,900 gas warm).

To tell vacant slots apart from occupied ones, the library uses a **vacancy flag**: a configurable bit range within the 256-bit word. When those bits are zero, the slot is vacant and available for reuse. Any packed struct that has a field guaranteed to be non-zero when occupied (e.g., an amount, a timestamp, an address) can serve as the vacancy flag.

The lifecycle:

1. **Allocate**: scan from a hint index, find the first slot where the vacancy flag bits are zero, write the new packed value.
2. **Free**: clear the vacancy flag bits (and optionally others) via a bitmask, leaving a non-zero tombstone.
3. **Re-allocate**: the freed slot is found by the next scan and overwritten at the cheap SSTORE rate.

## Gas economics

Post-London (EIP-2929 + EIP-3529):

| SSTORE transition | Warm | Cold |
|---|---|---|
| zero to nonzero | 20,000 | 22,100 |
| nonzero to nonzero | 2,900 | 5,000 |

### Benchmarks

All benchmarks come from `ShowcaseGas.t.sol` and run within a single transaction (warm storage).

**Lifecycle: 20 creates, 10 deletes (50% reuse rate)**

Simulates a content board with churn. 10 articles are created, 5 deleted, 5 created (reusing freed
slots), 5 more deleted, 5 more created (reusing again). Of the 20 total creates, 10 are fresh writes
and 10 land on recycled slots.

| | Total gas | Savings |
|---|---|---|
| Raw (standard delete) | 510,710 | |
| Recycled (tombstone) | 324,863 | **36.4%** |

**Per-write: create-after-delete (best case, zero scan)**

Isolates the single-write savings. Create one article, delete it, create another. The recycled path
finds the freed slot immediately with no scan.

| | Gas | Savings |
|---|---|---|
| Raw (full-zero delete) | 23,613 | |
| Recycled (tombstone) | 2,800 | **88.1%** |

The per-write savings are up to 88%, but lifetime savings depend on your reuse rate: how often a
create lands on a recycled slot vs. a fresh one. The per-write benchmark assumes zero scan iterations;
this is realistic in practice because `findVacant` (a view function) can locate the next vacancy
off-chain, and the on-chain `allocate` call starts at that exact index.

Run the benchmark:

```bash
forge test --match-path test/showcase/ShowcaseGas.t.sol -vv
```

## Quick start

```solidity
import {RecycleConfig, SlotRecyclingLib} from "slot-recycling-lib/src/SlotRecyclingLib.sol";

// Vacancy field spans bits 192-247 (56 bits) of the packed word.
RecycleConfig private immutable CFG = SlotRecyclingLib.create(192, 56);
SlotRecyclingLib.Pool private _pool;

// Allocate: scans from hint, writes to first vacant slot.
uint256 idx = SlotRecyclingLib.allocate(_pool, CFG, 0, packedValue);

// Free: clears vacancy flag bits, leaves tombstone (slot stays non-zero).
SlotRecyclingLib.free(_pool, CFG, idx, CLEAR_MASK);

// Next allocate reuses the freed slot at ~2,900 gas instead of ~20,000.
```

## Before you integrate

> **This library changes the observable semantics of a mapping-backed collection.**
> Read this section before adopting it; the storage optimization is not free of tradeoffs.

### Semantic differences from a normal mapping

| Normal mapping | SlotRecyclingLib pool |
|---|---|
| Each new entry gets a fresh, never-before-used key | Slot indices are **reused**. A new allocation may return an index that previously belonged to a different logical item. |
| `delete` zeroes the slot; reading it returns `0` / default | `free` / `freeWithSentinel` leave a **non-zero tombstone**. Reading a freed slot returns stale data, not zero. |
| A zero read reliably means "does not exist" | A zero read only means the slot was **never written**. Freed slots read as the tombstone, not zero. |
| IDs are inherently monotonic (e.g., `nextId++`) | Recycled indices are **not monotonic**. Do not use slot indices as externally visible unique IDs without an indirection layer. |

**If your contract or off-chain indexer relies on any of the left-column behaviors, you must add your own bookkeeping.** Common mitigations:
- Maintain a separate monotonic counter and map external IDs → slot indices.
- Track existence with a `mapping(uint256 => bool)` or a bitmap alongside the pool.
- Treat any read where `isVacant(pool, cfg, index)` returns `true` as "does not exist."

### Operational footguns

1. **Double-free is silently permitted.** `free` and `freeWithSentinel` do not check whether the slot is already vacant. Calling free twice on the same index succeeds as long as the resulting tombstone is non-zero. Guard against this in your own code if double-free would break your invariants.

2. **`store` bypasses all invariants.** It performs a raw `SSTORE` with no vacancy check and no vacancy-flag validation. Writing zero or a value with vacant vacancy bits corrupts the pool — the slot will appear vacant while holding data, or vice versa. Use `store` only for migrations or administrative overrides, never in normal allocation paths.

3. **Vacancy bits must be non-zero for every occupied value.** `allocate` enforces this, but if you construct packed values incorrectly the check will revert your transaction. Pick a field that is *guaranteed* non-zero whenever the slot is logically occupied (e.g., a non-zero amount, a non-zero timestamp, a non-zero address).

4. **`delete` or any full-zero write defeats the optimization.** If any code path writes zero to a pool slot (Solidity `delete`, inline assembly `sstore(slot, 0)`), the next write to that slot will pay the full 20,000 gas zero-to-nonzero cost. Always use `free` or `freeWithSentinel` to clear slots.

5. **Gas savings depend on reuse rate and hint quality.** If your workload rarely deletes, or the `searchPointer` hint is far from the next vacancy, the scan overhead can offset or exceed the savings. Benchmark with your actual access pattern (see [ShowcaseGas.t.sol](test/showcase/ShowcaseGas.t.sol)).

### Choosing between `free` and `freeWithSentinel`

| Use `free` when | Use `freeWithSentinel` when |
|---|---|
| At least one field naturally stays non-zero after clearing the vacancy field and other mutable data (e.g., an `address owner` field). | No remaining field is guaranteed non-zero, or you want a deterministic tombstone value across all slots. |
| You want to preserve some original data as part of the tombstone (e.g., keep the owner address for historical queries). | You want a fixed, recognizable sentinel (e.g., `0x01`) that is trivial to filter out in off-chain indexing. |

### Constructing a safe `clearMask`

The `clearMask` passed to `free` tells the library which bits to zero. The bits that remain form the tombstone.

1. **Always include the vacancy flag bits.** If the clear mask does not cover every vacancy-flag bit, `free` reverts with `ClearMaskIncomplete`.
2. **Include all mutable data fields** you want to erase — but leave at least one non-zero field untouched so the tombstone is non-zero.
3. **Build the mask with `SlotRecyclingLib.bitmask`** and compose ranges with bitwise OR:
   ```solidity
   // Clear bountyAmount (bits 192-247) and withdrawalPermittedAt (bits 160-191).
   // Leaves owner (bits 0-159) and category (bits 248-255) as tombstone.
   uint256 CLEAR_MASK = SlotRecyclingLib.bitmask(192, 56) | SlotRecyclingLib.bitmask(160, 32);
   ```
4. **Choose a vacancy field that your contract guarantees is non-zero when occupied.** Good candidates: a non-zero token amount, a timestamp field that your contract never leaves at zero for occupied entries, or a non-zero-address owner. Avoid boolean fields (only 1 bit wide and not byte-aligned) or fields that can legitimately be zero.

See [`RecycledArticleStore.sol`](src/showcase/RecycledArticleStore.sol) for a complete working example, and [`RawArticleStore.sol`](src/showcase/RawArticleStore.sol) for the standard-mapping baseline it replaces.

### When NOT to use this library

Use this checklist to decide whether slot recycling fits your use case:

- [ ] **Your mapping has meaningful churn** (entries are created and deleted regularly). If entries are append-only, there are no slots to recycle.
- [ ] **You can identify a non-zero vacancy field** in your packed struct. If every field can legitimately be zero when occupied, tombstoning does not work cleanly.
- [ ] **Your contract does not depend on zero-on-missing semantics.** If you rely on reading a deleted key as zero (e.g., for access-control checks like `require(balances[id] == 0)`), tombstone data will break that assumption.
- [ ] **Slot indices are not used as external unique IDs** — or you have an indirection layer that maps stable external IDs to recycled internal indices.
- [ ] **Off-chain indexers can handle non-zero reads on freed slots** or you have existence tracking that indexers can query.

If any box stays unchecked, consider whether the integration cost outweighs the gas savings.

## Installation

```bash
forge soldeer install slot-recycling-lib
```

## Solidity API

Library: `SlotRecyclingLib` (`src/SlotRecyclingLib.sol`). Import both the `RecycleConfig` type and the library.

Because the source file declares `using SlotRecyclingLib for RecycleConfig global`, importers get method-call syntax on config values automatically.

### Type layout

The `RecycleConfig` value type wraps a precomputed `uint256` vacancy mask. The mask is computed by
`create(offset, width)` and has `width` consecutive bits set starting at bit `offset`.
A slot is vacant when `slotData & vacancyMask == 0`.

**Byte-alignment:** both offset and width must be multiples of 8. This is a deliberate design choice
to align with Solidity's native packed types (uint8 through uint248), where field boundaries always
fall on byte boundaries. Sub-byte vacancy flags (e.g., a single bool bit) are not supported.

### API

| Function | Description |
|---|---|
| `SlotRecyclingLib.create(offset, width)` | Creates a `RecycleConfig`. Reverts with `BadRecycleConfig` on invalid parameters. |
| `cfg.vacancyMask()` | Returns the precomputed vacancy mask. |
| `SlotRecyclingLib.bitmask(offset, width)` | Returns a mask with `width` bits set at `offset`. Compose with OR for clearMask arguments. |
| `allocate(pool, cfg, searchPointer, packedValue)` | Scan from hint, write to first vacant slot. Reverts if vacancy bits in value are zero. |
| `free(pool, cfg, index, clearMask)` | Clear bits via mask, leave tombstone. Reverts if tombstone would be zero. |
| `freeWithSentinel(pool, cfg, index, sentinel)` | Write fixed sentinel as tombstone. For cases where no field naturally stays non-zero. |
| `load(pool, index)` | Raw read of packed value. |
| `store(pool, index, packedValue)` | Raw write (no vacancy scan). |
| `isVacant(pool, cfg, index)` | True if vacancy flag bits are all zero. |
| `findVacant(pool, cfg, searchPointer)` | Scan for next vacant slot (view, for off-chain hints). |

### Errors

```solidity
error BadRecycleConfig(uint256 vacancyBitOffset, uint256 vacancyBitWidth);
error TombstoneIsZero();
error VacancyFlagNotSet(uint256 packedValue);
error ClearMaskIncomplete(uint256 clearMask);
error SentinelOccupied(uint256 sentinel);
```

## Showcase

Showcase contracts under `src/showcase/` compare:

- `RawArticleStore`: standard mapping with `delete` on removal.
- `RecycledArticleStore`: same API using `SlotRecyclingLib` for tombstoned recycling.
  Scans from 0 on every allocation to isolate the recycling benefit.
- [`RecycledArticleStoreWithHint`](src/showcase/RecycledArticleStoreWithHint.sol): production-oriented
  example with a `_nextHint` strategy that keeps scans tight. Shows the recommended pattern for
  real integrations.

### Hint strategy

`RecycledArticleStoreWithHint` maintains a `_nextHint` state variable—the lowest index likely to be
vacant:

- **On allocate:** pass `_nextHint` as the search pointer; after allocation, set
  `_nextHint = allocatedIndex + 1`.
- **On free:** if the freed index is below `_nextHint`, move the hint down to the freed index.

This simple policy gives O(1) scan cost when slots are freed and re-allocated in FIFO order, and
degrades gracefully to a short linear scan when gaps are scattered. See the contract's NatSpec for
tradeoff discussion. Run the benchmark:

```bash
forge test --match-path test/showcase/ShowcaseHintTest.t.sol -vv
```

## Stability & Semver

The public API is frozen as of `1.0.0`. Breaking changes require a **major**
version bump. See [`STABILITY.md`](STABILITY.md) for the full policy, including
what counts as public API and how `major`/`minor`/`patch` are defined.

A compile-time compatibility fixture (`test/compat/PublicApiCompat.t.sol`)
exercises every supported import and call pattern. CI fails if the fixture
stops compiling or its tests break.

## License

MIT (see SPDX headers in source files).

## Author

[0xferit](https://github.com/0xferit)
