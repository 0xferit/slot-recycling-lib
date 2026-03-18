# Security Review Pack

- The library is **unaudited**.
- This document is audit-readiness material, not an audit claim.
- Primary review target: [`../src/SlotRecyclingLib.sol`](../src/SlotRecyclingLib.sol)

## Model

1. `RecycleConfig` encodes a vacancy mask.
2. A slot is occupied when `slotData & vacancyMask != 0`.
3. `allocate` finds the first vacant slot at or after a caller hint and writes a
   value whose vacancy bits are non-zero.
4. `free` and `freeWithSentinel` clear the vacancy bits but leave a non-zero
   tombstone.

The library does not define application-level IDs, existence rules, or access
control.

## Public semantics

- slot indices are reusable internal storage positions
- freed slots read back as tombstones, not zero
- zero means "never written", not "deleted"
- vacancy is defined by the configured mask, not by full-word zero
- hints affect gas, not correctness

## Core invariants

1. `create` rejects invalid offset/width pairs.
2. `allocate` only accepts values with non-zero vacancy bits.
3. `free` and `freeWithSentinel` leave the slot vacant but non-zero.
4. `isVacant`, `findVacant`, and `allocate` use the same vacancy predicate.
5. `findVacant` and `allocate` return the first vacant slot at or after the hint.
6. `store` is intentionally unsafe and can violate all other invariants.

## Footguns and assumptions

- using slot indices as external unique IDs
- assuming `load(index) == 0` means deleted
- assuming double-free will be rejected
- writing zero with `delete` or direct `sstore`
- choosing a vacancy field that can be zero when occupied
- building a `clearMask` that would zero the whole slot
- using `store` in normal flows instead of controlled migrations
- treating showcase gas numbers as universal

## Out of scope

- application-specific access control
- downstream uniqueness or identity models
- business logic built on top of recycled indices
- indexer correctness beyond documented semantics
- protocol economics unrelated to slot reuse

## Highest-risk failure modes

1. an occupied slot is misclassified as vacant and overwritten
2. a freed slot is misclassified as occupied and never reused
3. `free` or `freeWithSentinel` zeroes a slot
4. documentation or examples hide semantics that integrators rely on

## Evidence map

- core library: [`../src/SlotRecyclingLib.sol`](../src/SlotRecyclingLib.sol)
- public API fixture: [`../test/compat/PublicApiCompat.t.sol`](../test/compat/PublicApiCompat.t.sol)
- unit and fuzz tests: [`../test/SlotRecyclingLib.t.sol`](../test/SlotRecyclingLib.t.sol)
- invariants: [`../test/SlotRecyclingLib.invariant.t.sol`](../test/SlotRecyclingLib.invariant.t.sol)
- gas claims: [`../test/showcase/ShowcaseGas.t.sol`](../test/showcase/ShowcaseGas.t.sol)
- hint showcase: [`../src/showcase/RecycledArticleStoreWithHint.sol`](../src/showcase/RecycledArticleStoreWithHint.sol)
- hint tests: [`../test/showcase/ShowcaseHintTest.t.sol`](../test/showcase/ShowcaseHintTest.t.sol)

## Maintainer next actions

1. commission or obtain an independent review
2. publish the review artifact or reviewer statement if one exists
3. update [`../README.md`](../README.md) with the exact reviewed version/tag
4. link remediation commits if findings are fixed
