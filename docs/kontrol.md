# Kontrol Formal Verification

This project includes a narrow Kontrol proof layer for the core library as a supplement to the
Foundry fuzz and invariant test suite.

## Scope

Each proof starts with a fresh pool and uses the canonical vacancy range at bit offset 192 with
width 56. [Proof specifications](../test/kontrol/ProofSlotRecyclingSolidity.sol)

- `allocate` rejects a symbolic packed value whose vacancy bits are all zero, for any start index.
- `free` rejects a full-word clear mask applied to a symbolic occupied value.
- `freeWithSentinel` rejects a zero sentinel or the concrete sentinel with bit 192 set, for any index.
- `freeWithSentinel` writes any valid symbolic sentinel at index zero in the occupied fixture.
- Concrete allocation and free sequences check the tombstone and reuse at index zero.
- The two concrete `findVacant` scenarios start at index zero in a fresh pool and after freeing that
  slot. Each starts at an immediate vacancy.

Continuous integration runs the four rejection specifications when the inputs differ from a successful
push build on main. Documentation, benchmark reporting and the review workflow can reuse a verified
ancestor. Solidity edits remain proof inputs because Kontrol reads NatSpec constraints. Changes to compiler inputs, dependencies, proof settings or the hosted proof workflow run the prover.
When adding a new proof input, include it in the selector. A missing baseline also runs the prover. The Foundry build and test suite run on every pull request and push to main.
[Input selection](../scripts/kontrol-inputs-match.sh) · [CI workflow](../.github/workflows/ci.yml)

The full local run also includes the five success scenarios.

## Prerequisites

Native Kontrol and Foundry installations available on `PATH`.

Example Apple Silicon install for Kontrol:

```bash
APPLE_SILICON=true UV_PYTHON=3.10 kup install kontrol --version v1.0.231
```

The helper script uses the native `kontrol` binary. Continuous integration uses the Docker image
pinned in `.github/workflows/ci.yml`.

## Commands

```bash
# List saved proof results
./script/kontrol.sh list

# Prove core (revert-condition) Solidity specs
./script/kontrol.sh prove-core

# Prove core specs with higher local parallelism (local-hi profile)
./script/kontrol.sh prove-core-hi

# Prove all Solidity specs
./script/kontrol.sh prove-core-full

# Remove saved proofs and toolchain metadata
./script/kontrol.sh clean
```

## Artifacts

Kontrol saves proof graphs and compiled definitions inside Foundry's configured build output.
The wrapper records its toolchain metadata separately. Its `clean` command removes the saved
graphs and metadata and retains the compiled definitions and other build output.
[Foundry configuration](../foundry.toml), [Kontrol wrapper](../script/kontrol.sh)

The wrapper reports a failed proof command immediately. Kontrol owns the solver processes it starts.

## Counterexample workflow

If a proof fails:

1. Re-run the specific proof with `kontrol prove --match-test "<Contract.proof_name>"`.
2. Use `kontrol list` to identify the saved proof.
3. Inspect the proof state with `kontrol show` or `kontrol view-kcfg`.
