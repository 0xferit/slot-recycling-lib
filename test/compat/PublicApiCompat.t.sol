// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

// ──────────────────────────────────────────────────────────────────────────────
// Public API compatibility fixture.
//
// This file imports every public symbol and exercises every call pattern that
// external consumers are expected to use. If a change to SlotRecyclingLib
// breaks this file, `forge build` fails and CI catches the regression before
// merge. See STABILITY.md for the full semver policy.
// ──────────────────────────────────────────────────────────────────────────────

import {Test} from "forge-std/Test.sol";

// 1. Canonical import path and named symbols ──────────────────────────────────
import {
    RecycleConfig,
    SlotRecyclingLib,
    BadRecycleConfig,
    TombstoneIsZero,
    VacancyFlagNotSet,
    ClearMaskIncomplete,
    SentinelOccupied
} from "src/SlotRecyclingLib.sol";

/// @notice Minimal consumer contract that mirrors the README quick-start pattern.
///         Its purpose is compile-time verification; the test below calls every
///         public entry point to ensure signatures and return types have not drifted.
contract MinimalConsumer {
    // Pool struct ─────────────────────────────────────────────────────────────
    SlotRecyclingLib.Pool private _pool;

    // Config via create() ─────────────────────────────────────────────────────
    RecycleConfig private immutable CFG = SlotRecyclingLib.create(192, 56);

    // Bitmask helper ──────────────────────────────────────────────────────────
    uint256 private immutable CLEAR_MASK = SlotRecyclingLib.bitmask(192, 56) | SlotRecyclingLib.bitmask(160, 32);

    // -- allocate ---------------------------------------------------------
    function doAllocate(uint256 searchPointer, uint256 packedValue) external returns (uint256 index) {
        return SlotRecyclingLib.allocate(_pool, CFG, searchPointer, packedValue);
    }

    // -- free -------------------------------------------------------------
    function doFree(uint256 index) external returns (uint256 freedValue) {
        return SlotRecyclingLib.free(_pool, CFG, index, CLEAR_MASK);
    }

    // -- freeWithSentinel -------------------------------------------------
    function doFreeWithSentinel(uint256 index, uint256 sentinel) external returns (uint256 freedValue) {
        return SlotRecyclingLib.freeWithSentinel(_pool, CFG, index, sentinel);
    }

    // -- load / store -----------------------------------------------------
    function doLoad(uint256 index) external view returns (uint256) {
        return SlotRecyclingLib.load(_pool, index);
    }

    function doStore(uint256 index, uint256 packedValue) external {
        SlotRecyclingLib.store(_pool, index, packedValue);
    }

    // -- isVacant ---------------------------------------------------------
    function doIsVacant(uint256 index) external view returns (bool) {
        return SlotRecyclingLib.isVacant(_pool, CFG, index);
    }

    // -- findVacant -------------------------------------------------------
    function doFindVacant(uint256 searchPointer) external view returns (uint256) {
        return SlotRecyclingLib.findVacant(_pool, CFG, searchPointer);
    }

    // -- vacancyMask (method-call syntax via global using) -----------------
    function doVacancyMask() external view returns (uint256) {
        return CFG.vacancyMask();
    }
}

/// @notice Tests that exercise every public entry point through MinimalConsumer.
///         A compilation failure here means the public API has changed.
contract PublicApiCompatTest is Test {
    MinimalConsumer private consumer;

    // Packed value with vacancy bits (192-247) set to a non-zero bounty.
    // Layout: owner=address(1) | bountyAmount=100 at bits 192 | category=1 at bits 248.
    uint256 private constant PACKED = uint256(uint160(address(1))) | (uint256(100) << 192) | (uint256(1) << 248);

    function setUp() public {
        consumer = new MinimalConsumer();
    }

    // -- RecycleConfig type and create() ----------------------------------
    function test_compat_createConfig() public pure {
        RecycleConfig cfg = SlotRecyclingLib.create(192, 56);
        assertGt(RecycleConfig.unwrap(cfg), 0);
    }

    // -- vacancyMask (global using syntax) --------------------------------
    function test_compat_vacancyMask() public view {
        uint256 mask = consumer.doVacancyMask();
        assertGt(mask, 0);
    }

    // -- bitmask helper ---------------------------------------------------
    function test_compat_bitmask() public pure {
        uint256 m = SlotRecyclingLib.bitmask(192, 56);
        assertGt(m, 0);
    }

    // -- allocate → load round-trip ---------------------------------------
    function test_compat_allocateAndLoad() public {
        uint256 idx = consumer.doAllocate(0, PACKED);
        uint256 loaded = consumer.doLoad(idx);
        assertEq(loaded, PACKED);
    }

    // -- free → isVacant --------------------------------------------------
    function test_compat_freeAndIsVacant() public {
        uint256 idx = consumer.doAllocate(0, PACKED);
        consumer.doFree(idx);
        assertTrue(consumer.doIsVacant(idx));
    }

    // -- freeWithSentinel → isVacant --------------------------------------
    function test_compat_freeWithSentinelAndIsVacant() public {
        uint256 idx = consumer.doAllocate(0, PACKED);
        // Sentinel: non-zero value with vacancy bits (192-247) all zero.
        uint256 sentinel = 1;
        consumer.doFreeWithSentinel(idx, sentinel);
        assertTrue(consumer.doIsVacant(idx));
    }

    // -- store (raw write) ------------------------------------------------
    function test_compat_store() public {
        consumer.doStore(42, PACKED);
        uint256 loaded = consumer.doLoad(42);
        assertEq(loaded, PACKED);
    }

    // -- findVacant -------------------------------------------------------
    function test_compat_findVacant() public view {
        uint256 idx = consumer.doFindVacant(0);
        assertEq(idx, 0);
    }

    // -- error selectors (compile-time check that errors exist) -----------
    function test_compat_errorSelectors() public pure {
        // Verify each error's selector is computable (confirms name + params).
        assertTrue(BadRecycleConfig.selector != bytes4(0));
        assertTrue(TombstoneIsZero.selector != bytes4(0));
        assertTrue(VacancyFlagNotSet.selector != bytes4(0));
        assertTrue(ClearMaskIncomplete.selector != bytes4(0));
        assertTrue(SentinelOccupied.selector != bytes4(0));
    }
}
