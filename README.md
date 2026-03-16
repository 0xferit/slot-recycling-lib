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

## License

MIT (see SPDX headers in source files).

## Author

[0xferit](https://github.com/0xferit)
