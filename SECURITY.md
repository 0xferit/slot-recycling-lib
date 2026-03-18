# Security Policy

## Current status

`slot-recycling-lib` is currently **unaudited**. The docs in this repo are
review-prep material, not an audit claim.

## Reporting a vulnerability

For security-sensitive reports, email **ferit@cryptolab.net**.

Do not open a public GitHub issue for a new vulnerability before triage.

Useful report contents:

- affected version, tag, or commit SHA
- whether the issue is in the core library or an example integration
- reproduction steps or a minimal proof of concept
- impact and required assumptions

Non-sensitive bugs and doc fixes can go through normal GitHub issues.

## Scope

Primary in-scope code:

- [`src/SlotRecyclingLib.sol`](src/SlotRecyclingLib.sol)

Reference material that matters when it affects documented semantics:

- [`src/showcase/RecycledArticleStore.sol`](src/showcase/RecycledArticleStore.sol)
- [`src/showcase/RecycledArticleStoreWithHint.sol`](src/showcase/RecycledArticleStoreWithHint.sol)
- [`README.md`](README.md)
- [`STABILITY.md`](STABILITY.md)

Out of scope unless tied to a concrete library bug:

- downstream application logic
- consumer-specific packing or access control
- off-chain indexer behavior outside documented semantics
- gas conclusions under unrelated environments

## Support expectations

- Triage is best effort. No guaranteed SLA.
- The maintainer will try to acknowledge security mail within 7 calendar days.
- There is currently **no bug bounty program**.
- Backports are not guaranteed. Default targets are the latest release and `main`.

## For reviewers

- Primary review target: [`src/SlotRecyclingLib.sol`](src/SlotRecyclingLib.sol)
- Key semantics: recycled indices, tombstone reads, vacancy-mask-based emptiness
- Main invariants:
  - `create` rejects invalid configs
  - `allocate` only writes values with non-zero vacancy bits
  - `free` and `freeWithSentinel` leave slots vacant but non-zero
  - `isVacant`, `findVacant`, and `allocate` use the same vacancy predicate
  - `store` is intentionally unsafe and bypasses invariants
- Useful evidence:
  - [`test/compat/PublicApiCompat.t.sol`](test/compat/PublicApiCompat.t.sol)
  - [`test/SlotRecyclingLib.t.sol`](test/SlotRecyclingLib.t.sol)
  - [`test/SlotRecyclingLib.invariant.t.sol`](test/SlotRecyclingLib.invariant.t.sol)
  - [`test/showcase/ShowcaseGas.t.sol`](test/showcase/ShowcaseGas.t.sol)
  - [`test/showcase/ShowcaseHintTest.t.sol`](test/showcase/ShowcaseHintTest.t.sol)
- Remaining maintainer action: obtain an independent review and publish the exact reviewed version/tag if one happens
