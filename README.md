# slot-recycling-lib

[![create-after-delete: gas saved](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/0xferit/slot-recycling-lib/gh-badges/.badges/recycling-savings.json)](test/showcase/ShowcaseGas.t.sol)

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

### Benchmark scenario

The badge and numbers below come from a specific test (`ShowcaseGas.t.sol`):

1. Create an article (writes a packed word to a mapping slot).
2. Delete it: `RawArticleStore` uses `delete` (zeros the slot); `RecycledArticleStore` uses `free` (leaves a tombstone).
3. Create another article that lands in the same slot.

Step 3 is where the difference shows. The raw path pays zero-to-nonzero (expensive); the recycled
path pays nonzero-to-nonzero (cheap). Both measurements happen in the same transaction with warm
storage access, and the recycled path's `searchPointer` is already at the freed slot (zero scan
iterations).

- Raw (full-zero delete): 23,613 gas
- Recycled (tombstone): 2,966 gas
- **Savings: 87.4%**

Real-world savings depend on two things: whether the slot access is warm or cold, and how many
occupied slots `allocate` must scan before finding a vacancy. Each occupied slot scanned adds
~100 gas (warm) or ~2,100 gas (cold). With a tight off-chain hint via `findVacant`, scan overhead
is near zero.

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
