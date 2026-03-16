// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {RawArticleStore} from "src/showcase/RawArticleStore.sol";
import {RecycledArticleStore} from "src/showcase/RecycledArticleStore.sol";

contract ShowcaseGasTest is Test {
    RawArticleStore raw;
    RecycledArticleStore recycled;

    function setUp() public {
        raw = new RawArticleStore();
        recycled = new RecycledArticleStore();
    }

    /// @notice Measures gas for create-after-delete (the recycling case).
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
    }

    /// @notice Measures gas for first-time creation (no recycling benefit).
    function test_gasComparison_freshAllocation() public {
        uint256 gasBefore = gasleft();
        raw.createArticle(100, 1);
        uint256 rawFresh = gasBefore - gasleft();

        gasBefore = gasleft();
        recycled.createArticle(100, 1);
        uint256 recycledFresh = gasBefore - gasleft();

        console.log("raw fresh allocation gas:      ", rawFresh);
        console.log("recycled fresh allocation gas:  ", recycledFresh);

        // Fresh allocation should be comparable (no recycling benefit yet)
    }
}
