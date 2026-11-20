# Architecture

## Storage and identity

The consumer owns the pool in its contract storage. The pool contains only the mapping from slot indices to packed words. The consumer supplies its vacancy mask on every checked operation and must preserve the field layout while any of those words remain in use. The library runs internally in the consumer and has no independent deployment, owner or access control. [Core library](src/SlotRecyclingLib.sol)

The vacancy field describes occupancy. Logical deletion keeps a nonzero word so allocation can reuse paid-for storage. The library owns the vacancy checks and scan order. Consumers own the search hint, record identity, and permission to read or mutate records. Consumers that need stable identifiers must manage their binding to the currently occupied slot. [Integration guide](README.md)

## Measurements and verification

The three article stores share a record layout. They compare full deletion and sequential allocation with slot recycling, either scanning from zero or maintaining a hint. They expose unrestricted calls so the benchmarks measure those storage and bookkeeping choices. Foundry tests measure gross call costs within a transaction. The receipt benchmark deploys fresh fixtures and measures the gas settled when each operation has its own transaction. [Showcases](src/showcase/) · [Gas measurements](docs/gas.md)

The compatibility fixture exercises the supported consumer interface. Stateful Foundry tests compare the pool to a model across sequences of writes. Kontrol proves selected properties with a fixed vacancy field. The proof guide identifies the subset run in continuous integration and the scope of the search proofs. [Compatibility fixture](test/compat/PublicApiCompat.t.sol) · [Behavioral tests](test/SlotRecyclingLib.behavioral.t.sol) · [Proof guide](docs/kontrol.md)

## Release boundary

Successful continuous integration (CI) for a push to `main` makes that exact source revision eligible for release. The read-only verification job generates a deterministic version and changelog commit, tests the candidate, and checks a Soldeer package built from that commit. The publishing job regenerates the same commit, advances `main` and creates the version tag atomically, and compares the registry package contents with the tagged files before creating the GitHub release. An explicit version retry resumes a tagged release after partial publication. [Release workflow](.github/workflows/release.yml) · [Version policy](STABILITY.md)
