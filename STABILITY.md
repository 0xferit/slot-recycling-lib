# Stability & Semver Policy

This library follows [Semantic Versioning 2.0.0](https://semver.org/) with the
definitions below. Breaking changes to the documented public API require a
**major** version bump; backward-compatible additions are **minor** releases,
and fixes or internal-only changes are **patch** releases.

## What counts as public API

| Surface | Examples |
|---|---|
| **User-defined value type** | `RecycleConfig` and its underlying `uint256` type |
| **Struct definitions** | `SlotRecyclingLib.Pool` |
| **File-level errors** | `BadRecycleConfig`, `TombstoneIsZero`, `VacancyFlagNotSet`, `ClearMaskIncomplete`, `SentinelOccupied` — names, parameter types, and parameter order |
| **Library function signatures** | Every `internal` function in `SlotRecyclingLib` — name, parameter types/order, return types |
| **Global using directive** | `using SlotRecyclingLib for RecycleConfig global` |
| **Import path** | `import {RecycleConfig, SlotRecyclingLib} from "slot-recycling-lib/src/SlotRecyclingLib.sol"` |
| **Documented semantics** | Vacancy-flag convention, tombstone invariant, byte-alignment requirement, and the `create()` validation rules described in NatSpec and README |

## What is NOT public API

- Internal constants such as `VERSION` (informational, may change on any release).
- Showcase contracts under `src/showcase/` (reference implementations, not importable API).
- Test files and scripts.
- Gas costs (these may vary with compiler version and optimizer settings).

## Version bump rules

| Bump | When |
|---|---|
| **major** | Any change to the public API surface listed above: renaming or removing a function, changing a signature or return type, renaming or removing an error, changing the `RecycleConfig` underlying type, altering the `Pool` struct layout, or breaking the documented import path. |
| **minor** | Adding new public API surface that does not break existing consumers: new library functions, new error types, new helper types. |
| **patch** | Bug fixes, performance improvements, documentation updates, internal refactoring, or tooling changes that do not alter the public API. |

## Compatibility fixture

The file `test/compat/PublicApiCompat.t.sol` is a compile-time guard for the
public API. It imports every public symbol and exercises every supported call
pattern that external consumers are expected to copy. If a change breaks the
compatibility fixture, CI fails before merge.

Any PR that modifies or removes code in the compatibility fixture should be
treated as a signal that the public API is changing and reviewed accordingly.
