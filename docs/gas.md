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

## What the controls verify

The storage control sends the same rewrite to the same mapping index in two fresh
harnesses. Both first store the same nonzero word. One clears it to zero in a
separate transaction, the other leaves a nonzero tombstone. The identical
rewrite saves **17,100 receipt gas under Cancun** and **97,920 under the tested
Glamsterdam draft**. These figures isolate the final write. The showcase
comparison includes deletion and each store's bookkeeping. [Workload savings](../README.md#gas-measurements)

The draft adds a transaction-wide state-gas reservoir. With a 4 million gas
limit the reservoir starts empty, and a fresh cold storage write consumes
110,020 gas from its execution frame. With a 20 million gas limit the same
instruction consumes 12,100 frame gas and draws 97,920 from the reservoir.
This is why a Solidity `gasleft()` difference can miss part of the sender's
cost. The script compares every operation receipt at both gas limits before
reporting the draft savings. [Ethereum Improvement Proposal 8037](https://eips.ethereum.org/EIPS/eip-8037#transaction-level-gas-accounting-reservoir-model) · [Storage write pricing](https://eips.ethereum.org/EIPS/eip-8038#sstore-pricing)

The control also checks the refund for clearing a committed nonzero word. In
the draft, appending zero bytes to a fresh write makes the calldata floor
determine its receipt. The sender pays the greater of the total post-refund
gas and the transaction's calldata floor. Block capacity uses separate
execution and state counters. [Transaction settlement](https://eips.ethereum.org/EIPS/eip-8037#transaction-gas-used) · [Calldata floor](https://eips.ethereum.org/EIPS/eip-7976#specification) · [Transaction base cost](https://eips.ethereum.org/EIPS/eip-2780#interactions-with-other-eips)
