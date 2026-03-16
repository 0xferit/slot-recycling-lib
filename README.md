# slot-recycling-lib

EVM charges ~20,000 gas for a zero-to-nonzero SSTORE but only ~2,900 gas (warm) for nonzero-to-nonzero. In mapping-backed collections with churn, this library recycles freed slots by leaving a non-zero "tombstone" on deletion instead of fully zeroing. The next allocation overwrites the tombstoned slot at the cheaper rate.

**Quick start:**

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

## Gas economics

Post-London (EIP-2929 + EIP-3529):

| SSTORE transition | Warm | Cold |
|---|---|---|
| zero to nonzero | 20,000 | 22,100 |
| nonzero to nonzero | 2,900 | 5,000 |

Showcase benchmark (create-after-delete):
- Raw (full-zero delete): 23,613 gas
- Recycled (tombstone): 2,966 gas
- **Savings: 87.4%**

Benchmark assumes immediate reuse with `searchPointer` at the freed slot (zero scan iterations).
Each occupied slot scanned adds a storage read (~100 gas warm, ~2,100 gas cold) and reduces
realized savings.

Run the benchmark:

```bash
forge test --match-path test/showcase/ShowcaseGas.t.sol -vv
```

## Showcase

Showcase contracts under `src/showcase/` compare:

- `RawArticleStore`: standard mapping with `delete` on removal.
- `RecycledArticleStore`: same API using `SlotRecyclingLib` for tombstoned recycling.

## License

MIT (see SPDX headers in source files).

## Author

[0xferit](https://github.com/0xferit)
