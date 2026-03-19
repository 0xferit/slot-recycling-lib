# Kontrol Formal Verification

This project includes a narrow Kontrol proof layer for the core library as a supplement to the
Foundry fuzz and invariant test suite.

Kontrol is used for machine-checked proofs over all symbolic inputs/states for selected properties.

## Scope

Proof specs live in:

- `test/kontrol/ProofSlotRecyclingSolidity.sol`

They cover:

- `allocate` rejects writes whose vacancy bits are all zero.
- `free` reverts when the tombstone would be zero, and writes a non-zero tombstone with vacancy
  bits cleared on success.
- `freeWithSentinel` reverts on zero or occupied (vacancy-bit-set) sentinel, and writes the
  non-zero sentinel with vacancy bits cleared on success.
- `allocate` reuses a just-freed slot when the search pointer makes that slot eligible.
- `findVacant` agrees with the harnessed occupancy scenario for the small states modelled.

All proofs use the canonical `192/56` vacancy range (showcase-style config).

## Prerequisites

Native Kontrol and Foundry installations available on `PATH`.

Example Apple Silicon install for Kontrol:

```bash
APPLE_SILICON=true UV_PYTHON=3.10 kup install kontrol --version v1.0.231
```

The helper script uses the native `kontrol` binary. Docker is only used in CI, where the image is
pinned in `.github/workflows/ci.yml`.

## Commands

```bash
# Show available proofs/specs
./script/kontrol.sh list

# Prove core (revert-condition) Solidity specs
./script/kontrol.sh prove-core

# Prove all Solidity specs
./script/kontrol.sh prove-core-full

# Remove local proof artifacts
./script/kontrol.sh clean
```

## Artifacts

Kontrol artifacts are written under `.kontrol/` (gitignored).

## Counterexample workflow

If a proof fails:

1. Re-run the specific proof with `kontrol prove --match-test "<Contract.proof_name>"`.
2. Inspect generated proof artifacts under `.kontrol/`.
3. Use `kontrol show`, `kontrol list`, and `kontrol view-kcfg` for proof state/debugging.
