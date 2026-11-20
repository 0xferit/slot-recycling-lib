# slot-recycling-lib

[![Cancun batch lifecycle gross gas savings](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/0xferit/slot-recycling-lib/gh-badges/.badges/recycling-savings.json)](docs/gas.md)
[![Cancun batch create-after-delete gross gas savings](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/0xferit/slot-recycling-lib/gh-badges/.badges/bestcase-savings.json)](docs/gas.md)

`SlotRecyclingLib` lets a Solidity contract reuse storage slots in a mapping-backed collection. A live entry has at least one bit set in its configured **vacancy field**. Freeing it clears that field and leaves a nonzero **tombstone**. A later allocation can overwrite the existing word and avoid paying to create a storage slot.

## Installation and usage

These commands install version 1.1.0 in a Foundry project using Soldeer.

```sh
forge soldeer install 'slot-recycling-lib~1.1.0' --config-location foundry
```

For the import below, add this alias to your project's `remappings.txt`. Soldeer's default generated alias includes the package version.

```text
slot-recycling-lib/=dependencies/slot-recycling-lib-1.1.0/
```

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {RecycleConfig, SlotRecyclingLib} from "slot-recycling-lib/src/SlotRecyclingLib.sol";

abstract contract Records {
    SlotRecyclingLib.Pool private pool;
    RecycleConfig private immutable CFG = SlotRecyclingLib.create(192, 56);

    function _insert(uint256 hint, uint256 packed) internal returns (uint256 slot) {
        return SlotRecyclingLib.allocate(pool, CFG, hint, packed);
    }

    function _remove(uint256 slot) internal returns (uint256 oldWord) {
        return SlotRecyclingLib.freeWithSentinel(pool, CFG, slot, 1);
    }
}
```

Here the vacancy field occupies bits 192 through 247. Each inserted word must set at least one of them. The sentinel sets only bit zero. Keep a single configuration for each pool across calls and upgrades. Changing the field requires migrating existing records.

## Integration guarantees

- **Layout.** `create(offset, width)` accepts byte-aligned fields 8 to 248 bits wide that fit in one word. A dedicated Solidity `bool` occupies one byte and works if every live record sets it to true. A manually packed single-bit flag needs its own byte. `cfg.vacancyMask()` returns the field mask. The generic `bitmask(offset, width)` also accepts empty and full-word ranges.
- **Allocation and search.** `allocate` writes to the first vacant slot starting at the hint. `findVacant` uses the same cyclic order, including wraparound from the maximum index to zero. Search costs grow with the consecutive occupied slots visited. An off-chain hint can go stale. Applications needing bounded allocation work can maintain a free-index list and a separate append cursor.
- **Deletion.** `free` returns the previous word and clears the requested bits. An all-zero result raises `TombstoneIsZero`. Otherwise, any remaining vacancy-field bit raises `ClearMaskIncomplete`. Including the full field guarantees those bits are cleared for every live word. `freeWithSentinel` accepts a nonzero sentinel with the entire vacancy field clear. Both operations permit writes to an already vacant slot if their result is valid.
- **Identity and authorization.** `isVacant` describes current occupancy. `load` returns the raw word, including retained data until reuse. A slot index can belong to many records over time. For externally visible records, issue stable identifiers, invalidate the identifier-to-slot binding on deletion, and verify that the binding is live and the caller authorized before operating on it.
- **Raw writes.** `store` writes any word and bypasses occupancy validation. Reserve it for controlled migrations. A zero read provides no record of earlier writes.

## Gas measurements

The badges measure gross call gas in a single Cancun transaction. Separate user transactions pay intrinsic gas, reset storage access warmth, and settle refunds individually. Comparisons also include each showcase's counter, hint, scans and events. Run the [gas benchmarks](docs/gas.md) for receipt-level measurements under Cancun and the tested Glamsterdam draft.

The [showcases](src/showcase/) are unrestricted gas fixtures. All three allow deletion by any caller. The recycled fixtures expose reusable slot indices. Moving a hint back to a freed slot helps nearby allocations, but a subsequent allocation can still scan an arbitrarily long occupied span.

## Compatibility and security

The library follows [semantic versioning](STABILITY.md). Its functions are internal and execute in the consumer's storage context. The [compatibility fixture](https://github.com/0xferit/slot-recycling-lib/blob/main/test/compat/PublicApiCompat.t.sol) exercises the supported import and call patterns. See the [library source](src/SlotRecyclingLib.sol) for signatures and errors.

An independent security audit has yet to be published. See the [security policy](SECURITY.md) for review scope and private reporting. Released under the [MIT License](LICENSE) by [0xferit](https://github.com/0xferit).
