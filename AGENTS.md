# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

`slot-recycling-lib` is a Solidity library for recycling freed mapping slots to avoid zero-to-nonzero SSTORE costs. The core mechanism: on logical deletion, leave a non-zero "tombstone" in the slot so the next allocation writes nonzero-to-nonzero (~2,900 gas warm) instead of zero-to-nonzero (~20,000 gas). A `RecycleConfig` value type wraps a precomputed `uint256` vacancy mask. The recommended pattern is `immutable` + `create(vacancyBitOffset, vacancyBitWidth)`.

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

- UDT `RecycleConfig` wraps `uint256`: the precomputed vacancy mask.
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
- `showcase/ShowcaseGas.t.sol`: gas benchmarks comparing raw vs recycled create-after-delete. Enforces explicit gas budgets via `GAS_BUDGET_*` constants (see "Gas regression budgets" section below).

### Configuration

- `foundry.toml`: optimizer runs = 0x10000, fuzz runs = 0x10000, deps via Soldeer. Pins `solc_version` for reproducible builds.
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

## Gas regression budgets

`test/showcase/ShowcaseGas.t.sol` defines `GAS_BUDGET_*` constants that cap the gas for each key
scenario. CI enforces these via `assertLe`. The budgets include ~20-40% headroom above observed
values to absorb compiler and EVM variation without false positives.

| Constant | Scenario | Budget |
|---|---|---|
| `GAS_BUDGET_FRESH_ALLOCATION` | First allocation (no reuse) | 35,000 |
| `GAS_BUDGET_BEST_CASE` | Create-after-delete (zero scan) | 4,000 |
| `GAS_BUDGET_REALISTIC_SCAN` | Create-after-delete (5 occupied slots scanned) | 5,500 |
| `GAS_BUDGET_LIFECYCLE` | 20 creates + 10 deletes (50% reuse) | 400,000 |

**Updating budgets** (when a deliberate change causes a budget to be exceeded):

1. Run `forge test --match-path test/showcase/ShowcaseGas.t.sol -vv` locally.
2. Note the new observed values in the console output.
3. Update the corresponding `GAS_BUDGET_*` constant with ~20% headroom above the new value.
4. Update the "Current observed values" comment in the `ShowcaseGasTest` contract NatSpec.
5. If README benchmarks are affected, update those numbers too.
6. Commit with a message explaining the tradeoff (e.g., `perf: accept +X gas for Y`).

The same test file feeds both CI (`forge test`) and the badge-generation workflow
(`gas-badges.yml`), so they cannot silently diverge.

## Pinned toolchain

The repo pins both the Solidity compiler and the Foundry release so that gas benchmarks,
regression budgets, and badge values are reproducible across local and CI environments.

- **Solc version**: set via `solc_version` in `foundry.toml`. This is the source of truth for
  the compiler used by both local and CI builds.
- **Foundry release**: set via the `version` input of `foundry-rs/foundry-toolchain@v1` in every
  GitHub Actions workflow that runs `forge` (`ci.yml`, `gas-badges.yml`, `release.yml`). All
  three workflows must use the same version.

**Upgrading the toolchain.** When intentionally bumping Solc or Foundry, do it in one dedicated PR:

1. Update `solc_version` in `foundry.toml` and/or the Foundry `version` in all workflows.
2. Run `forge test --match-path test/showcase/ShowcaseGas.t.sol -vv` locally.
3. Refresh `GAS_BUDGET_*` constants and the "Current observed values" comment in `ShowcaseGas.t.sol` if needed.
4. Update README benchmark numbers if they changed.
5. Ship all changes together in the same PR.
