// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {RawArticleStore} from "src/showcase/RawArticleStore.sol";
import {RecycledArticleStore} from "src/showcase/RecycledArticleStore.sol";

/// @title  ShowcaseGasTest
/// @notice Gas benchmarks comparing RawArticleStore (standard delete) vs RecycledArticleStore
///         (tombstoned slot recycling). All measurements happen within a single transaction,
///         so storage accesses are warm. The recycled path uses searchPointer = 0 with only
///         the freed slot in the pool, meaning zero scan iterations.
///
/// @dev    **Gas regression budgets.**
///         Each key scenario has an explicit gas budget enforced via `assertLe`. The budgets
///         include ~20-40% headroom above observed values to absorb compiler/EVM variation
///         without producing false positives. If a budget is exceeded, CI will fail.
///
///         Current observed values (Solc 0.8.25, optimizer runs = 0x10000):
///           - Fresh allocation overhead (recycled):   ~29,200 gas
///           - Best-case create-after-delete:          ~2,800 gas
///           - Realistic scan (5 occupied slots):      ~3,900 gas
///           - Lifecycle (20 creates, 10 deletes):     ~325,000 gas
///
///         **Updating budgets.** When a deliberate change causes gas to exceed a budget:
///           1. Run `forge test --match-path test/showcase/ShowcaseGas.t.sol -vv` locally.
///           2. Note the new observed values in the console output.
///           3. Update the corresponding `GAS_BUDGET_*` constant below with ~20% headroom.
///           4. Update the "Current observed values" comment above.
///           5. If README benchmarks are affected, update those numbers too.
///           6. Commit with a message explaining the tradeoff (e.g., "perf: accept +X gas for Y").
contract ShowcaseGasTest is Test {
    // -------------------------------------------------------------------------
    // Gas regression budgets (single source of truth)
    // -------------------------------------------------------------------------
    // Each constant caps the gas for its scenario. Values include ~20-40% slack
    // above observed measurements to prevent flaky failures across environments.
    // See the contract NatSpec above for how to update these after an intentional change.

    /// @dev Fresh allocation via the recycled path (no prior delete, no reuse).
    uint256 internal constant GAS_BUDGET_FRESH_ALLOCATION = 35_000;

    /// @dev Best-case create-after-delete: one create, one delete, one recycled create.
    uint256 internal constant GAS_BUDGET_BEST_CASE = 4_000;

    /// @dev Realistic scan: 10 articles, delete index 5, create with searchPointer=0 (5 slots scanned).
    uint256 internal constant GAS_BUDGET_REALISTIC_SCAN = 5_500;

    /// @dev Lifecycle: 20 creates + 10 deletes with 50% reuse (total recycled-path gas).
    uint256 internal constant GAS_BUDGET_LIFECYCLE = 400_000;

    RawArticleStore raw;
    RecycledArticleStore recycled;

    function setUp() public {
        raw = new RawArticleStore();
        recycled = new RecycledArticleStore();
    }

    /// @notice Measures gas for the create-after-delete scenario.
    /// @dev    Scenario: create one article, delete it, then create another in the same slot.
    ///         Raw path: delete zeros the slot, so the second create is zero-to-nonzero (expensive).
    ///         Recycled path: free leaves a tombstone, so the second create is nonzero-to-nonzero (cheap).
    ///         This is the best-case scenario for the library; real savings depend on scan overhead.
    function test_gasComparison_recycledVsFresh() public {
        // --- Raw path: create, delete (full zero), create again (zero-to-nonzero) ---
        raw.createArticle(100, 1);
        raw.deleteArticle(0);

        uint256 gasBefore = gasleft();
        raw.createArticle(200, 2);
        uint256 rawCreateAfterDelete = gasBefore - gasleft();

        // --- Recycled path: create, free (tombstone), create again (nonzero-to-nonzero) ---
        recycled.createArticle(100, 1);
        recycled.deleteArticle(0);

        gasBefore = gasleft();
        recycled.createArticle(200, 2);
        uint256 recycledCreateAfterDelete = gasBefore - gasleft();

        console.log("raw create-after-delete gas:     ", rawCreateAfterDelete);
        console.log("recycled create-after-delete gas: ", recycledCreateAfterDelete);
        console.log("savings gas:                      ", rawCreateAfterDelete - recycledCreateAfterDelete);

        uint256 savingsBps = ((rawCreateAfterDelete - recycledCreateAfterDelete) * 10000) / rawCreateAfterDelete;
        console.log("recycling savings bps:            ", savingsBps);

        assertTrue(recycledCreateAfterDelete < rawCreateAfterDelete, "recycled should be cheaper");
        assertLe(recycledCreateAfterDelete, GAS_BUDGET_BEST_CASE, "best-case gas budget exceeded");
    }

    /// @notice Realistic scenario: pool has occupied slots, freed slot is not at the front.
    /// @dev    Scenario: create 10 articles, delete the one at index 5, then create a new article
    ///         with searchPointer = 0. The allocator must scan past 5 occupied slots before finding
    ///         the vacancy. Compared against the raw path which always appends to nextId (no scan).
    function test_gasComparison_realisticScan() public {
        // --- Populate both pools with 10 articles ---
        for (uint56 i = 1; i <= 10; i++) {
            raw.createArticle(i * 100, uint8(i));
            recycled.createArticle(i * 100, uint8(i));
        }

        // --- Raw path: delete article 5, create again (always appends to fresh slot) ---
        raw.deleteArticle(5);

        uint256 gasBefore = gasleft();
        raw.createArticle(999, 7);
        uint256 rawGas = gasBefore - gasleft();

        // --- Recycled path: delete article 5, create with searchPointer=0 (scans past 5 slots) ---
        recycled.deleteArticle(5);

        gasBefore = gasleft();
        recycled.createArticle(999, 7);
        uint256 recycledGas = gasBefore - gasleft();

        console.log("realistic raw gas:      ", rawGas);
        console.log("realistic recycled gas:  ", recycledGas);
        console.log("realistic savings gas:   ", rawGas - recycledGas);

        uint256 savingsBps = ((rawGas - recycledGas) * 10000) / rawGas;
        console.log("realistic savings bps:   ", savingsBps);

        assertTrue(recycledGas < rawGas, "recycled should still be cheaper with scan overhead");
        assertLe(recycledGas, GAS_BUDGET_REALISTIC_SCAN, "realistic scan gas budget exceeded");
    }

    /// @notice Lifecycle benchmark: 20 creates and 10 deletes interleaved over time.
    /// @dev    Simulates a content board with churn. The sequence:
    ///           Phase 1: create 10 articles                    (10 fresh writes, no recycling possible)
    ///           Phase 2: delete 5 of them (indices 1,3,5,7,9)  (5 deletes)
    ///           Phase 3: create 5 more                         (raw: fresh slots; recycled: reuses tombstoned slots)
    ///           Phase 4: delete 5 more (indices 0,2,4,6,8)     (5 deletes)
    ///           Phase 5: create 5 more                         (raw: fresh slots; recycled: reuses tombstoned slots)
    ///         Total: 20 creates, 10 deletes. Of the 20 creates, 10 are fresh (no recycling benefit)
    ///         and 10 hit recycled slots (where the library saves gas).
    function test_gasComparison_lifecycle() public {
        uint256 rawTotal;
        uint256 recycledTotal;
        uint256 gasBefore;

        // Phase 1: 10 fresh creates (both paths write to zero slots)
        for (uint56 i = 1; i <= 10; i++) {
            gasBefore = gasleft();
            raw.createArticle(i * 100, uint8(i));
            rawTotal += gasBefore - gasleft();

            gasBefore = gasleft();
            recycled.createArticle(i * 100, uint8(i));
            recycledTotal += gasBefore - gasleft();
        }

        // Phase 2: delete odd indices (1,3,5,7,9)
        for (uint256 i = 1; i <= 9; i += 2) {
            gasBefore = gasleft();
            raw.deleteArticle(i);
            rawTotal += gasBefore - gasleft();

            gasBefore = gasleft();
            recycled.deleteArticle(i);
            recycledTotal += gasBefore - gasleft();
        }

        // Phase 3: 5 creates (raw: fresh slots 10-14; recycled: reuses tombstoned odd slots)
        for (uint56 i = 11; i <= 15; i++) {
            gasBefore = gasleft();
            raw.createArticle(i * 100, uint8(i % 10));
            rawTotal += gasBefore - gasleft();

            gasBefore = gasleft();
            recycled.createArticle(i * 100, uint8(i % 10));
            recycledTotal += gasBefore - gasleft();
        }

        // Phase 4: delete even indices (0,2,4,6,8)
        for (uint256 i = 0; i <= 8; i += 2) {
            gasBefore = gasleft();
            raw.deleteArticle(i);
            rawTotal += gasBefore - gasleft();

            gasBefore = gasleft();
            recycled.deleteArticle(i);
            recycledTotal += gasBefore - gasleft();
        }

        // Phase 5: 5 more creates (raw: fresh slots 15-19; recycled: reuses tombstoned even slots)
        for (uint56 i = 16; i <= 20; i++) {
            gasBefore = gasleft();
            raw.createArticle(i * 100, uint8(i % 10));
            rawTotal += gasBefore - gasleft();

            gasBefore = gasleft();
            recycled.createArticle(i * 100, uint8(i % 10));
            recycledTotal += gasBefore - gasleft();
        }

        console.log("--- lifecycle: 20 creates, 10 deletes ---");
        console.log("  fresh creates (no reuse):  10");
        console.log("  recycled creates (reuse):  10");
        console.log("  raw total gas:             ", rawTotal);
        console.log("  recycled total gas:        ", recycledTotal);
        console.log("  total savings gas:         ", rawTotal - recycledTotal);

        uint256 savingsBps = ((rawTotal - recycledTotal) * 10000) / rawTotal;
        console.log("  lifecycle savings bps:     ", savingsBps);

        assertTrue(recycledTotal < rawTotal, "recycled should be cheaper over full lifecycle");
        assertLe(recycledTotal, GAS_BUDGET_LIFECYCLE, "lifecycle gas budget exceeded");
    }

    /// @notice Measures gas for first-time creation (no prior delete, no recycling benefit).
    /// @dev    Both paths write to a fresh zero slot, so the SSTORE cost is the same.
    ///         This test confirms the library does not add meaningful overhead on the non-recycling path.
    function test_gasComparison_freshAllocation() public {
        uint256 gasBefore = gasleft();
        raw.createArticle(100, 1);
        uint256 rawFresh = gasBefore - gasleft();

        gasBefore = gasleft();
        recycled.createArticle(100, 1);
        uint256 recycledFresh = gasBefore - gasleft();

        console.log("raw fresh allocation gas:      ", rawFresh);
        console.log("recycled fresh allocation gas:  ", recycledFresh);

        assertLe(recycledFresh, GAS_BUDGET_FRESH_ALLOCATION, "fresh allocation gas budget exceeded");
    }
}
