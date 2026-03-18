// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {RecycledArticleStore} from "src/showcase/RecycledArticleStore.sol";
import {RecycledArticleStoreWithHint} from "src/showcase/RecycledArticleStoreWithHint.sol";

/// @title  ShowcaseHintTest
/// @notice Behavioral tests and gas benchmark for the hint-managed showcase.
contract ShowcaseHintTest is Test {
    RecycledArticleStoreWithHint hint;

    function setUp() public {
        hint = new RecycledArticleStoreWithHint();
    }

    // ───────────────────── Correctness: create / read / delete ─────────────────────

    /// @notice Basic create and read round-trip.
    function test_createAndRead() public {
        uint256 id = hint.createArticle(100, 1);
        (address owner, uint32 wpa, uint56 bounty, uint8 cat) = hint.readArticle(id);

        assertEq(owner, address(this));
        assertEq(wpa, 0);
        assertEq(bounty, 100);
        assertEq(cat, 1);
    }

    /// @notice Sequential creates produce monotonically increasing IDs.
    function test_sequentialCreatesMonotonicIds() public {
        uint256 a = hint.createArticle(10, 1);
        uint256 b = hint.createArticle(20, 2);
        uint256 c = hint.createArticle(30, 3);

        assertEq(a, 0);
        assertEq(b, 1);
        assertEq(c, 2);
    }

    /// @notice After deletion, the vacancy flag (bountyAmount) reads as zero.
    function test_deleteClearsVacancyFlag() public {
        uint256 id = hint.createArticle(100, 1);
        hint.deleteArticle(id);

        (, , uint56 bounty, ) = hint.readArticle(id);
        assertEq(bounty, 0, "bountyAmount should be zero after delete");
    }

    // ───────────────────── Reuse of freed slots ─────────────────────

    /// @notice A freed slot is reused by the next allocation.
    function test_freedSlotIsReused() public {
        uint256 first = hint.createArticle(100, 1);
        hint.deleteArticle(first);

        uint256 second = hint.createArticle(200, 2);
        assertEq(second, first, "should reuse the freed slot");

        (, , uint56 bounty, uint8 cat) = hint.readArticle(second);
        assertEq(bounty, 200);
        assertEq(cat, 2);
    }

    /// @notice Multiple freed slots are reused in order (lowest first).
    function test_multipleFreedSlotsReusedInOrder() public {
        hint.createArticle(10, 1); // 0
        hint.createArticle(20, 2); // 1
        hint.createArticle(30, 3); // 2

        hint.deleteArticle(0);
        hint.deleteArticle(2);

        // Next allocate should reuse slot 0 (lowest freed)
        uint256 a = hint.createArticle(40, 4);
        assertEq(a, 0, "should reuse slot 0 first");

        // Next allocate should reuse slot 2
        uint256 b = hint.createArticle(50, 5);
        assertEq(b, 2, "should reuse slot 2 next");
    }

    // ───────────────────── Interior gaps ─────────────────────

    /// @notice Interior gap: free a middle slot, verify it is found and reused.
    function test_interiorGapReused() public {
        hint.createArticle(10, 1); // 0
        hint.createArticle(20, 2); // 1
        hint.createArticle(30, 3); // 2
        hint.createArticle(40, 4); // 3
        hint.createArticle(50, 5); // 4

        hint.deleteArticle(2); // create interior gap at index 2

        uint256 id = hint.createArticle(60, 6);
        assertEq(id, 2, "should fill the interior gap");
    }

    /// @notice Multiple interior gaps: slots 1 and 3 freed; allocation fills them in order.
    function test_multipleInteriorGaps() public {
        for (uint56 i = 1; i <= 5; i++) {
            hint.createArticle(i * 10, uint8(i));
        }

        hint.deleteArticle(1);
        hint.deleteArticle(3);

        uint256 a = hint.createArticle(60, 6);
        assertEq(a, 1, "should fill gap at 1 first");

        uint256 b = hint.createArticle(70, 7);
        assertEq(b, 3, "should fill gap at 3 next");
    }

    // ───────────────────── Out-of-order deletes ─────────────────────

    /// @notice Deleting slots in reverse order still produces correct reuse.
    function test_outOfOrderDeletes_reverseOrder() public {
        hint.createArticle(10, 1); // 0
        hint.createArticle(20, 2); // 1
        hint.createArticle(30, 3); // 2

        // Delete in reverse: 2, 1, 0
        hint.deleteArticle(2);
        hint.deleteArticle(1);
        hint.deleteArticle(0);

        // Allocations should reuse from lowest
        assertEq(hint.createArticle(40, 4), 0);
        assertEq(hint.createArticle(50, 5), 1);
        assertEq(hint.createArticle(60, 6), 2);
    }

    /// @notice Delete the highest slot first, then a lower one; reuse picks the lower first.
    function test_outOfOrderDeletes_highThenLow() public {
        hint.createArticle(10, 1); // 0
        hint.createArticle(20, 2); // 1
        hint.createArticle(30, 3); // 2

        hint.deleteArticle(2); // hint moves to 2 (was 3)
        hint.deleteArticle(0); // hint moves to 0 (lower)

        uint256 a = hint.createArticle(40, 4);
        assertEq(a, 0, "should reuse slot 0 (lowest freed)");

        uint256 b = hint.createArticle(50, 5);
        assertEq(b, 2, "should reuse slot 2 next");
    }

    // ───────────────────── _nextHint correctness ─────────────────────

    /// @notice Hint starts at 0.
    function test_hintStartsAtZero() public view {
        assertEq(hint.nextHint(), 0);
    }

    /// @notice Hint advances after each allocation.
    function test_hintAdvancesAfterAllocate() public {
        hint.createArticle(10, 1); // allocates slot 0
        assertEq(hint.nextHint(), 1);

        hint.createArticle(20, 2); // allocates slot 1
        assertEq(hint.nextHint(), 2);
    }

    /// @notice Hint moves backward when a freed slot is below the current hint.
    function test_hintMovesBackwardOnLowerFree() public {
        hint.createArticle(10, 1); // 0
        hint.createArticle(20, 2); // 1
        hint.createArticle(30, 3); // 2
        // hint is now 3

        hint.deleteArticle(1); // freed slot 1 < hint 3 → hint becomes 1
        assertEq(hint.nextHint(), 1);
    }

    /// @notice Hint does not move when a freed slot is at or above the current hint.
    function test_hintUnchangedOnHigherFree() public {
        hint.createArticle(10, 1); // 0
        hint.createArticle(20, 2); // 1
        // hint is now 2

        hint.deleteArticle(1); // freed slot 1 < hint 2 → hint becomes 1
        assertEq(hint.nextHint(), 1);

        hint.deleteArticle(0); // freed slot 0 < hint 1 → hint becomes 0
        assertEq(hint.nextHint(), 0);
    }

    /// @notice After reuse of freed slot, hint advances past it.
    function test_hintAdvancesPastReusedSlot() public {
        hint.createArticle(10, 1); // 0
        hint.createArticle(20, 2); // 1
        hint.createArticle(30, 3); // 2

        hint.deleteArticle(0); // hint → 0
        assertEq(hint.nextHint(), 0);

        hint.createArticle(40, 4); // reuses slot 0, hint → 1
        assertEq(hint.nextHint(), 1);
    }

    /// @notice Full round-trip: allocate all, free all, re-allocate all. Hint tracks correctly.
    function test_hintFullRoundTrip() public {
        // Allocate 5 slots
        for (uint56 i = 1; i <= 5; i++) {
            hint.createArticle(i * 10, uint8(i));
        }
        assertEq(hint.nextHint(), 5);

        // Free all (in order)
        for (uint256 i = 0; i < 5; i++) {
            hint.deleteArticle(i);
        }
        assertEq(hint.nextHint(), 0, "hint should be 0 after freeing slot 0");

        // Re-allocate all (should reuse 0-4)
        for (uint56 i = 1; i <= 5; i++) {
            uint256 id = hint.createArticle(i * 100, uint8(i));
            assertEq(id, uint256(i - 1), "should reuse slots in order");
        }
        assertEq(hint.nextHint(), 5);
    }

    // ───────────────────── Gas benchmark: hint vs no-hint ─────────────────────

    /// @notice Compares hint-managed vs hint-less showcase in a churn scenario with scan overhead.
    /// @dev    Scenario: create 20 articles, delete the first 10, then create 10 more.
    ///         Without hint: each allocation scans from 0; after the first reuse fills slot 0 the
    ///         next call must skip it to find slot 1, then skip 0-1 to find slot 2, etc.
    ///         With hint: _nextHint advances after each reuse, so every call finds its slot immediately.
    function test_gasComparison_hintVsNoHint_churnScenario() public {
        RecycledArticleStore noHint = new RecycledArticleStore();
        RecycledArticleStoreWithHint withHint = new RecycledArticleStoreWithHint();

        // Phase 1: Populate 20 articles in both stores
        for (uint56 i = 1; i <= 20; i++) {
            noHint.createArticle(i * 100, uint8(i % 10));
            withHint.createArticle(i * 100, uint8(i % 10));
        }

        // Phase 2: Delete the first 10 articles (indices 0-9) in both stores
        for (uint256 i = 0; i < 10; i++) {
            noHint.deleteArticle(i);
            withHint.deleteArticle(i);
        }

        // Phase 3: Create 10 new articles — this is where hint matters.
        // No-hint scans from 0 each time, but quickly finds slot 0 (freed).
        // After reusing 0, next call scans from 0 again, skips the just-filled 0, finds 1, etc.
        // With hint: first call finds 0 immediately, sets hint to 1, next finds 1 immediately, etc.
        uint256 noHintGas;
        uint256 withHintGas;
        uint256 gasBefore;

        for (uint56 i = 21; i <= 30; i++) {
            gasBefore = gasleft();
            noHint.createArticle(i * 100, uint8(i % 10));
            noHintGas += gasBefore - gasleft();

            gasBefore = gasleft();
            withHint.createArticle(i * 100, uint8(i % 10));
            withHintGas += gasBefore - gasleft();
        }

        console.log("--- churn scenario: 20 create, 10 delete, 10 re-create ---");
        console.log("  no-hint re-create gas:   ", noHintGas);
        console.log("  with-hint re-create gas: ", withHintGas);

        if (noHintGas > withHintGas) {
            console.log("  hint savings gas:        ", noHintGas - withHintGas);
            uint256 savingsBps = ((noHintGas - withHintGas) * 10000) / noHintGas;
            console.log("  hint savings bps:        ", savingsBps);
        } else {
            console.log("  hint overhead gas:       ", withHintGas - noHintGas);
        }

        assertTrue(withHintGas <= noHintGas, "hint-managed should not be more expensive");
    }

    /// @notice Compares hint vs no-hint when deletions create scattered gaps far from index 0.
    /// @dev    Scenario: create 50 articles, delete every other one starting from index 30.
    ///         No-hint must scan past 30 occupied slots (indices 0-29) to reach the first vacancy
    ///         at index 30. Hint-managed jumps directly to the first freed slot.
    function test_gasComparison_hintVsNoHint_scatteredHighGaps() public {
        RecycledArticleStore noHint = new RecycledArticleStore();
        RecycledArticleStoreWithHint withHint = new RecycledArticleStoreWithHint();

        // Phase 1: Populate 50 articles
        for (uint56 i = 1; i <= 50; i++) {
            noHint.createArticle(i * 100, uint8(i % 10));
            withHint.createArticle(i * 100, uint8(i % 10));
        }

        // Phase 2: Delete every other slot starting from index 30
        for (uint256 i = 30; i < 50; i += 2) {
            noHint.deleteArticle(i);
            withHint.deleteArticle(i);
        }

        // Phase 3: Create 10 new articles
        uint256 noHintGas;
        uint256 withHintGas;
        uint256 gasBefore;

        for (uint56 i = 51; i <= 60; i++) {
            gasBefore = gasleft();
            noHint.createArticle(i * 100, uint8(i % 10));
            noHintGas += gasBefore - gasleft();

            gasBefore = gasleft();
            withHint.createArticle(i * 100, uint8(i % 10));
            withHintGas += gasBefore - gasleft();
        }

        console.log("--- scattered high gaps: 50 create, 10 scattered delete, 10 re-create ---");
        console.log("  no-hint re-create gas:   ", noHintGas);
        console.log("  with-hint re-create gas: ", withHintGas);

        if (noHintGas > withHintGas) {
            console.log("  hint savings gas:        ", noHintGas - withHintGas);
            uint256 savingsBps = ((noHintGas - withHintGas) * 10000) / noHintGas;
            console.log("  hint savings bps:        ", savingsBps);
        } else {
            console.log("  hint overhead gas:       ", withHintGas - noHintGas);
        }

        assertTrue(withHintGas < noHintGas, "hint should save gas when gaps are far from 0");
    }
}
