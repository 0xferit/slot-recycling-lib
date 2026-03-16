# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

`slot-recycling-lib` is a Solidity library for recycling freed mapping slots to avoid zero-to-nonzero SSTORE costs. The core mechanism: on logical deletion, leave a non-zero "tombstone" in the slot so the next allocation writes nonzero-to-nonzero (~2,900 gas warm) instead of zero-to-nonzero (~20,000 gas). A `RecycleConfig` value type packs `(vacancyBitOffset, vacancyBitWidth)` into a single `uint16`. The recommended pattern is `immutable` + `create(vacancyBitOffset, vacancyBitWidth)`.

## Commands

```bash
forge build                                                          # compile
forge test                                                           # all tests (includes 65536 fuzz runs)
forge test --match-path test/SlotRecyclingLib.t.sol                  # library tests only
forge test --match-test test_allocate_reusesFreedSlot                # single test
forge test --match-test testFuzz_                                    # fuzz tests only
forge test --match-path test/showcase/ShowcaseGas.t.sol -vv          # gas benchmarks
forge fmt                                                            # format Solidity files
```

## Architecture

### Core library: `src/SlotRecyclingLib.sol`

- UDT `RecycleConfig` wraps `uint16`: bits 0-7 = vacancyBitOffset, bits 8-15 = vacancyBitWidth.
- `Pool` struct wraps `mapping(uint256 => uint256)`. Consumer declares in their storage.
- All library functions are `internal`. Storage-touching functions are state-changing; config accessors are `pure`.
- Errors (`BadRecycleConfig`, `TombstoneIsZero`, `VacancyFlagNotSet`) are file-level, not inside the library block.
- `using SlotRecyclingLib for RecycleConfig global` at file bottom propagates method-call syntax.
- `VERSION` constant is bumped automatically by semantic-release; do not edit it manually.

### Showcase: `src/showcase/`

- `RawArticleStore.sol`: baseline contract with standard mapping + full-zero deletion.
- `RecycledArticleStore.sol`: same API using SlotRecyclingLib for tombstoned slot recycling.

### Tests: `test/`

- `SlotRecyclingLib.t.sol`: `RecyclerHarness` exposes library via external calls. Smoke tests and fuzz tests.
- `showcase/ShowcaseGas.t.sol`: gas benchmarks comparing raw vs recycled create-after-delete.

### Configuration

- `foundry.toml`: optimizer runs = 0x10000, fuzz runs = 0x10000, deps via Soldeer.
- `remappings.txt`: maps `forge-std/` from `dependencies/`.

## Conventions

- Solidity `^0.8.25`, 4-space indentation, NatSpec on public-facing behavior.
- Errors are file-level with bare names.
- Create configs with `SlotRecyclingLib.create(...)`; never use `RecycleConfig.wrap(...)` directly.
- Showcase pairs follow `Raw...` / `Recycled...` naming.
- Test names: `test_` prefix for concrete, `testFuzz_` for fuzz. Descriptive: `test_free_tombstoneZero_reverts`.
- Fuzz tests: `uint8` params for config dimensions, `bound()` not `vm.assume`.
- Conventional Commits: `feat:`, `fix:`, `ci:`, `docs:`, `chore:`, `refactor:`, `perf:`.

## Testing doctrine

A test is worth keeping if it protects against a plausible future regression that a reviewer could miss. Write a test when at least one is true:

1. It explores more of the input space than review will (fuzz/property tests, parameterized ranges).
2. It pins a singular boundary where arithmetic or bit logic tends to fail (0, 1, max, first invalid value).
3. It captures a non-local contract (constructor invariants, checked vs unchecked semantics, round-trip relationships).
4. It documents a user-visible revert condition with non-trivial control flow.
5. It prevents a known regression or a previously identified review finding.
6. It serves as executable documentation for a tricky public semantic (one golden test per semantic, not per function).

Do not write a test that re-implements the function under test, proves the language works as documented, or duplicates coverage from a stronger fuzz/property test.

## Release pipeline

Fully automated on push to main (`.github/workflows/release.yml`):
1. `scripts/analyze-bump.sh` checks if any `src/**/*.sol` files changed since the last Soldeer publish. If no Solidity source changed, no release is created.
2. If source changed, Claude (Opus, max effort) analyzes the diff and determines the semver bump. Falls back to "patch" if Claude is unavailable.
3. `@semantic-release/exec` bumps the `VERSION` constant in `SlotRecyclingLib.sol`.
4. GitHub release created, CHANGELOG.md + source committed with `[skip ci]`.
5. `forge soldeer push` publishes to the Soldeer registry, then tags `soldeer-published`.
