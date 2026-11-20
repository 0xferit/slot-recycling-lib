# Gas benchmarks

The Foundry tests measure gross execution gas for calls batched in one Cancun
transaction. The receipt script measures net gas paid when each call has its
own transaction.

## Batched Cancun calls

```sh
forge test --match-path test/showcase/ShowcaseGas.t.sol -vv
forge test --match-path test/showcase/ShowcaseHintTest.t.sol -vv
```

[ShowcaseGas.t.sol](../test/showcase/ShowcaseGas.t.sol) uses `gasleft()` around
each call. A reused slot in these tests was already accessed and changed in the
same transaction, so its storage write is warm and dirty. A raw create always
writes a fresh article slot. The totals exclude transaction overhead and refunds
credited at settlement. The gas budgets and badges track this workload.

[ShowcaseHintTest.t.sol](../test/showcase/ShowcaseHintTest.t.sol) measures the
recreate phase for contiguous and scattered vacancies.

## Separate transactions

From a repository checkout, build with the [pinned compiler settings](../foundry.toml)
and run the script with Python 3 and Anvil v1.5.1.

```sh
forge build
python3 scripts/benchmark-receipts.py
```

The script starts a local Anvil instance on a temporary loopback port, deploys a
fresh showcase for each scenario, and sends one operation per transaction and
block. It sums the receipt gas after refunds and includes base and calldata
gas. Deployment gas is excluded. The workloads are three operations (create,
delete, create) and 30 operations (20 creates, 10 deletes, and ten article slot
reuses in the recycled fixtures). Each showcase keeps its own bookkeeping,
including identifiers, hint writes, and events.

To measure the draft Glamsterdam gas schedule, use an Anvil binary with
Amsterdam support. Anvil v1.9.0 was used for the draft measurements with the
same Solidity 0.8.25 Cancun bytecode in both modes. Set `AMSTERDAM_ANVIL` to
the path to the chosen Anvil executable.
[Foundry v1.9.0 release](https://github.com/foundry-rs/foundry/releases/tag/v1.9.0).

```sh
python3 scripts/benchmark-receipts.py --hardfork amsterdam --anvil "$AMSTERDAM_ANVIL"
```

Before measuring, the script writes, clears or tombstones, and rewrites the
same slot in separate transactions. It checks storage-write traces and net
receipts against the expected prices, including the refund cap on deletion.
Amsterdam must charge 110,020 gas for a cold fresh storage write and 12,100
for a cold update. A client that prices those operations differently stops at
the control. These figures apply to the draft rules exercised by the workload.
The protocol rules and prices can change before activation.
[EIP-8037](https://eips.ethereum.org/EIPS/eip-8037#parameter-changes),
[EIP-8038](https://eips.ethereum.org/EIPS/eip-8038#sstore-pricing),
[EIP-2780](https://eips.ethereum.org/EIPS/eip-2780#intrinsic-gas-costs),
[EIP-7976](https://eips.ethereum.org/EIPS/eip-7976#specification).

| Fixture | Cancun 3 transactions | Cancun 30 transactions | Amsterdam 3 transactions | Amsterdam 30 transactions |
|---|---:|---:|---:|---:|
| Raw | 137,339 | 1,219,802 | 396,981 | 3,088,815 |
| Recycled | 101,881 | 1,218,112 | 186,301 | 2,062,312 |
| Recycled with hint | 146,559 | 1,195,718 | 410,760 | 2,356,499 |

The 30-transaction Cancun savings are about 0.14% without the hint and 1.97%
with it. Under the draft Amsterdam schedule they are 33.23% and 23.71%.
In the three-transaction workload the hinted fixture spends more gas than
the raw fixture on both schedules. Deleting article zero resets the hint
slot to zero, so the next create pays to initialize the hint again.
