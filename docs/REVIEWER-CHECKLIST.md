# Reviewer Checklist

## Start here

1. [`../src/SlotRecyclingLib.sol`](../src/SlotRecyclingLib.sol)
2. [`../README.md`](../README.md)
3. [`SECURITY-REVIEW-PACK.md`](SECURITY-REVIEW-PACK.md)

## Primary targets

- core implementation:
  [`../src/SlotRecyclingLib.sol`](../src/SlotRecyclingLib.sol)
- baseline showcase:
  [`../src/showcase/RecycledArticleStore.sol`](../src/showcase/RecycledArticleStore.sol)
- hint showcase:
  [`../src/showcase/RecycledArticleStoreWithHint.sol`](../src/showcase/RecycledArticleStoreWithHint.sol)
- public API freeze:
  [`../STABILITY.md`](../STABILITY.md),
  [`../test/compat/PublicApiCompat.t.sol`](../test/compat/PublicApiCompat.t.sol)

## Questions

- Does `create` reject every invalid configuration it claims to?
- Can `allocate` ever write a value the library would later treat as vacant?
- Do `isVacant`, `findVacant`, and `allocate` agree on vacancy?
- Can `free` leave a slot zero or leave vacancy bits set?
- Is `freeWithSentinel` constrained enough to preserve the vacancy invariant?
- Are `store`, ID reuse, and tombstone reads documented clearly enough?
- Are hint examples presented as gas optimizations only?

## Tests to inspect

- [`../test/SlotRecyclingLib.t.sol`](../test/SlotRecyclingLib.t.sol)
- [`../test/SlotRecyclingLib.invariant.t.sol`](../test/SlotRecyclingLib.invariant.t.sol)
- [`../test/showcase/ShowcaseGas.t.sol`](../test/showcase/ShowcaseGas.t.sol)
- [`../test/showcase/ShowcaseHintTest.t.sol`](../test/showcase/ShowcaseHintTest.t.sol)

## Reproduction

```bash
forge build
forge test --match-path test/compat/PublicApiCompat.t.sol
forge test --match-path test/SlotRecyclingLib.t.sol
forge test --match-path test/SlotRecyclingLib.invariant.t.sol
forge test --match-path test/showcase/ShowcaseGas.t.sol -vv
forge test --match-path test/showcase/ShowcaseHintTest.t.sol -vv
```

## Gas-claim sources

- [`../test/showcase/ShowcaseGas.t.sol`](../test/showcase/ShowcaseGas.t.sol)
- benchmark numbers in [`../README.md`](../README.md)

Completing this checklist does not mean the library has been audited.
