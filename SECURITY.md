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

## Review materials

- [`docs/SECURITY-REVIEW-PACK.md`](docs/SECURITY-REVIEW-PACK.md)
- [`docs/REVIEWER-CHECKLIST.md`](docs/REVIEWER-CHECKLIST.md)
