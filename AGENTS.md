# Contributor guidance

See [ARCHITECTURE.md](ARCHITECTURE.md) for the storage model, verification boundaries and release pipeline.

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

## Releases

The release workflow generates `VERSION` and the changelog. Review the Conventional Commit classification of source changes against [STABILITY.md](STABILITY.md), including the title used for squash merges. To resume a release this workflow tagged but only partially published, dispatch the Release workflow on main with the existing tagged version.

## Gas regression budgets

The batched Cancun tests own their gas ceilings. When a deliberate change exceeds a ceiling, record the measured cost and explain the tradeoff before proposing a new budget. Update the affected figures in [docs/gas.md](docs/gas.md) after measuring the matching workload.

## Pinned toolchain

`foundry.toml` pins the Solidity compiler, Ethereum Virtual Machine target and optimizer settings. The GitHub workflows install Forge from the release archive pinned by version and checksum in [scripts/install-ci-forge.sh](scripts/install-ci-forge.sh). When upgrading the toolchain, update the pin and rerun the showcase gas benchmarks before updating affected figures or budgets.
