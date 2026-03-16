// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {
    RecycleConfig,
    SlotRecyclingLib,
    BadRecycleConfig,
    TombstoneIsZero,
    VacancyFlagNotSet,
    ClearMaskIncomplete,
    SentinelOccupied
} from "src/SlotRecyclingLib.sol";

/// @notice Harness that exposes library functions via external calls for testing.
contract RecyclerHarness {
    SlotRecyclingLib.Pool private _pool;

    function create(uint256 vacancyBitOffset_, uint256 vacancyBitWidth_) external pure returns (RecycleConfig) {
        return SlotRecyclingLib.create(vacancyBitOffset_, vacancyBitWidth_);
    }

    function vacancyMask(RecycleConfig cfg) external pure returns (uint256) {
        return cfg.vacancyMask();
    }

    function allocate(RecycleConfig cfg, uint256 searchPointer, uint256 packedValue) external returns (uint256 index) {
        return SlotRecyclingLib.allocate(_pool, cfg, searchPointer, packedValue);
    }

    function free(RecycleConfig cfg, uint256 index, uint256 clearMask) external returns (uint256 freedValue) {
        return SlotRecyclingLib.free(_pool, cfg, index, clearMask);
    }

    function freeWithSentinel(RecycleConfig cfg, uint256 index, uint256 sentinel)
        external
        returns (uint256 freedValue)
    {
        return SlotRecyclingLib.freeWithSentinel(_pool, cfg, index, sentinel);
    }

    function load(uint256 index) external view returns (uint256) {
        return SlotRecyclingLib.load(_pool, index);
    }

    function store(uint256 index, uint256 packedValue) external {
        SlotRecyclingLib.store(_pool, index, packedValue);
    }

    function isVacant(RecycleConfig cfg, uint256 index) external view returns (bool) {
        return SlotRecyclingLib.isVacant(_pool, cfg, index);
    }

    function findVacant(RecycleConfig cfg, uint256 searchPointer) external view returns (uint256 index) {
        return SlotRecyclingLib.findVacant(_pool, cfg, searchPointer);
    }
}

contract SlotRecyclingLibTest is Test {
    RecyclerHarness harness;

    // TruthPost-like config: vacancy flag is bountyAmount at bits 192-247 (offset=192, width=56)
    RecycleConfig cfg;

    // An address packed into bits 0-159 (simulates "owner" field)
    uint256 constant OWNER_BITS = uint256(uint160(0xdead));
    // A bountyAmount packed into bits 192-247
    uint256 constant BOUNTY_BITS = uint256(42) << 192;
    // A category packed into bits 248-255
    uint256 constant CATEGORY_BITS = uint256(1) << 248;

    // Full live value: owner + bounty + category (vacancy flag set via bounty)
    uint256 constant LIVE_VALUE = OWNER_BITS | BOUNTY_BITS | CATEGORY_BITS;
    // Clear mask: zeros bountyAmount (bits 192-247) and withdrawalPermittedAt (bits 160-191)
    uint256 constant CLEAR_MASK = (((uint256(1) << 56) - 1) << 192) | (((uint256(1) << 32) - 1) << 160);

    function setUp() public {
        harness = new RecyclerHarness();
        cfg = harness.create(192, 56);
    }

    // ── Factory ──

    function test_create_validConfig() public view {
        uint256 expectedMask = ((uint256(1) << 56) - 1) << 192;
        assertEq(harness.vacancyMask(cfg), expectedMask);
    }

    function test_create_invalidWidth_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(BadRecycleConfig.selector, 0, 4));
        harness.create(0, 4); // width < 8
    }

    function test_create_invalidAlignment_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(BadRecycleConfig.selector, 3, 8));
        harness.create(3, 8); // offset not multiple of 8
    }

    function test_create_overflow_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(BadRecycleConfig.selector, 200, 64));
        harness.create(200, 64); // 200 + 64 = 264 > 256
    }

    // ── Vacancy mask ──

    function test_vacancyMask_correctComputation() public view {
        uint256 mask = harness.vacancyMask(cfg);
        uint256 expected = ((uint256(1) << 56) - 1) << 192;
        assertEq(mask, expected);
    }

    // ── Allocate ──

    function test_allocate_freshSlot() public {
        uint256 idx = harness.allocate(cfg, 0, LIVE_VALUE);
        assertEq(idx, 0);
        assertEq(harness.load(0), LIVE_VALUE);
    }

    function test_allocate_skipsOccupied() public {
        harness.allocate(cfg, 0, LIVE_VALUE);
        uint256 idx2 = harness.allocate(cfg, 0, LIVE_VALUE | (uint256(99) << 192));
        assertEq(idx2, 1);
    }

    function test_allocate_reusesFreedSlot() public {
        uint256 idx = harness.allocate(cfg, 0, LIVE_VALUE);
        harness.free(cfg, idx, CLEAR_MASK);
        uint256 idx2 = harness.allocate(cfg, 0, LIVE_VALUE);
        assertEq(idx, idx2);
    }

    function test_allocate_findsInteriorGap() public {
        harness.allocate(cfg, 0, LIVE_VALUE);
        harness.allocate(cfg, 1, LIVE_VALUE | (uint256(99) << 192));
        harness.allocate(cfg, 2, LIVE_VALUE | (uint256(77) << 192));

        harness.free(cfg, 1, CLEAR_MASK);

        assertFalse(harness.isVacant(cfg, 0));
        assertTrue(harness.isVacant(cfg, 1));
        assertFalse(harness.isVacant(cfg, 2));

        uint256 idx = harness.allocate(cfg, 0, LIVE_VALUE | (uint256(55) << 192));
        assertEq(idx, 1);
    }

    function test_allocate_vacancyFlagZero_reverts() public {
        // Value with bounty bits all zero
        uint256 noVacancy = OWNER_BITS | CATEGORY_BITS;
        vm.expectRevert(abi.encodeWithSelector(VacancyFlagNotSet.selector, noVacancy));
        harness.allocate(cfg, 0, noVacancy);
    }

    // ── Free ──

    function test_free_residualTombstone() public {
        harness.allocate(cfg, 0, LIVE_VALUE);
        harness.free(cfg, 0, CLEAR_MASK);

        uint256 raw = harness.load(0);
        assertTrue(raw != 0, "slot should be non-zero (tombstone)");

        uint256 mask = harness.vacancyMask(cfg);
        assertEq(raw & mask, 0, "vacancy flag should be cleared");
    }

    function test_free_returnsOriginalValue() public {
        harness.allocate(cfg, 0, LIVE_VALUE);
        uint256 freed = harness.free(cfg, 0, CLEAR_MASK);
        assertEq(freed, LIVE_VALUE);
    }

    function test_free_tombstoneZero_reverts() public {
        // Store a value where clearing ALL bits would leave zero
        uint256 val = BOUNTY_BITS; // only vacancy bits set, nothing else
        harness.store(0, val);
        // clearMask covers all set bits
        vm.expectRevert(TombstoneIsZero.selector);
        harness.free(cfg, 0, type(uint256).max);
    }

    function test_free_clearMaskMissesVacancy_reverts() public {
        harness.allocate(cfg, 0, LIVE_VALUE);
        // clearMask that does NOT cover the vacancy flag bits
        uint256 badClearMask = (uint256(1) << 160) - 1; // only clears bits 0-159
        vm.expectRevert(abi.encodeWithSelector(ClearMaskIncomplete.selector, badClearMask));
        harness.free(cfg, 0, badClearMask);
    }

    // ── Free with sentinel ──

    function test_freeWithSentinel() public {
        harness.allocate(cfg, 0, LIVE_VALUE);
        uint256 sentinel = 1; // bit 0 set, vacancy bits clear
        uint256 freed = harness.freeWithSentinel(cfg, 0, sentinel);
        assertEq(freed, LIVE_VALUE);
        assertEq(harness.load(0), sentinel);
        assertTrue(harness.isVacant(cfg, 0));
    }

    function test_allocate_reusesSlotAfterSentinelFree() public {
        uint256 idx = harness.allocate(cfg, 0, LIVE_VALUE);
        harness.freeWithSentinel(cfg, idx, 1);
        assertTrue(harness.isVacant(cfg, idx));
        uint256 idx2 = harness.allocate(cfg, 0, LIVE_VALUE);
        assertEq(idx, idx2);
    }

    function test_freeWithSentinel_zeroSentinel_reverts() public {
        harness.store(0, LIVE_VALUE);
        vm.expectRevert(TombstoneIsZero.selector);
        harness.freeWithSentinel(cfg, 0, 0);
    }

    function test_freeWithSentinel_sentinelHasVacancyBits_reverts() public {
        harness.store(0, LIVE_VALUE);
        vm.expectRevert(abi.encodeWithSelector(SentinelOccupied.selector, LIVE_VALUE));
        harness.freeWithSentinel(cfg, 0, LIVE_VALUE); // vacancy bits set in sentinel
    }

    // ── isVacant ──

    function test_isVacant_freshSlot() public view {
        assertTrue(harness.isVacant(cfg, 999));
    }

    function test_isVacant_occupied() public {
        harness.allocate(cfg, 0, LIVE_VALUE);
        assertFalse(harness.isVacant(cfg, 0));
    }

    function test_isVacant_afterFree() public {
        harness.allocate(cfg, 0, LIVE_VALUE);
        harness.free(cfg, 0, CLEAR_MASK);
        assertTrue(harness.isVacant(cfg, 0));
    }

    // ── findVacant ──

    function test_findVacant_scansCorrectly() public {
        harness.allocate(cfg, 0, LIVE_VALUE);
        harness.allocate(cfg, 1, LIVE_VALUE);
        // Slots 0,1 occupied. Next vacant should be 2.
        assertEq(harness.findVacant(cfg, 0), 2);
    }

    function test_findVacant_findsFreedSlot() public {
        harness.allocate(cfg, 0, LIVE_VALUE);
        harness.allocate(cfg, 1, LIVE_VALUE);
        harness.free(cfg, 0, CLEAR_MASK);
        // Slot 0 freed, should be found first.
        assertEq(harness.findVacant(cfg, 0), 0);
    }

    function test_findVacant_findsInteriorGap() public {
        harness.allocate(cfg, 0, LIVE_VALUE);
        harness.allocate(cfg, 1, LIVE_VALUE | (uint256(99) << 192));
        harness.allocate(cfg, 2, LIVE_VALUE | (uint256(77) << 192));
        harness.free(cfg, 1, CLEAR_MASK);
        assertEq(harness.findVacant(cfg, 0), 1);
    }

    // ── Bitmask helper ──

    function test_bitmask_correctComputation() public pure {
        uint256 mask = SlotRecyclingLib.bitmask(192, 56);
        uint256 expected = ((uint256(1) << 56) - 1) << 192;
        assertEq(mask, expected);
    }

    function test_bitmask_composable() public pure {
        uint256 combined = SlotRecyclingLib.bitmask(160, 32) | SlotRecyclingLib.bitmask(192, 56);
        // Should cover bits 160-247
        uint256 expected = ((uint256(1) << 88) - 1) << 160;
        assertEq(combined, expected);
    }

    // ── Create edge cases ──

    function test_create_hugeOffset_reverts() public {
        // Would overflow offset + width in unchecked arithmetic; must revert with BadRecycleConfig
        vm.expectRevert(abi.encodeWithSelector(BadRecycleConfig.selector, type(uint256).max - 7, 8));
        harness.create(type(uint256).max - 7, 8);
    }

    // ── Fuzz tests ──

    function testFuzz_allocateFreeRoundTrip(uint8 offsetDiv8, uint8 widthDiv8, uint256 rawValue) public {
        uint256 offset = bound(uint256(offsetDiv8), 0, 31) * 8;
        uint256 width = bound(uint256(widthDiv8), 1, 31) * 8;
        if (offset + width > 256) return;

        RecycleConfig fuzzCfg = harness.create(offset, width);
        uint256 mask = fuzzCfg.vacancyMask();

        // Ensure value has vacancy bits set
        if (rawValue & mask == 0) {
            rawValue = rawValue | (uint256(1) << offset);
        }

        uint256 idx = harness.allocate(fuzzCfg, 0, rawValue);
        assertEq(harness.load(idx), rawValue);
        assertFalse(harness.isVacant(fuzzCfg, idx));

        // Free with a clearMask that covers vacancy bits and potentially more
        uint256 clearMask = mask; // at minimum clear the vacancy bits
        uint256 tombstone = rawValue & ~clearMask;

        if (tombstone == 0) {
            // Would revert; use sentinel instead. Place sentinel bit outside the vacancy region.
            uint256 sentinelBitPos = offset > 0 ? 0 : offset + width;
            if (sentinelBitPos >= 256) sentinelBitPos = 0;
            harness.freeWithSentinel(fuzzCfg, idx, uint256(1) << sentinelBitPos);
        } else {
            harness.free(fuzzCfg, idx, clearMask);
        }

        assertTrue(harness.isVacant(fuzzCfg, idx));

        // Re-allocate should reuse the same slot
        uint256 idx2 = harness.allocate(fuzzCfg, 0, rawValue);
        assertEq(idx, idx2);
    }

    function testFuzz_vacancyMaskComputation(uint8 offsetDiv8, uint8 widthDiv8) public view {
        uint256 offset = bound(uint256(offsetDiv8), 0, 31) * 8;
        uint256 width = bound(uint256(widthDiv8), 1, 31) * 8;
        if (offset + width > 256) return;

        RecycleConfig fuzzCfg = harness.create(offset, width);
        uint256 mask = fuzzCfg.vacancyMask();

        // Verify mask has exactly `width` bits set starting at `offset`
        uint256 expected = ((uint256(1) << width) - 1) << offset;
        assertEq(mask, expected);
    }

    function testFuzz_tombstoneAlwaysNonZero(uint256 slotValue, uint256 clearMask) public {
        RecycleConfig fuzzCfg = harness.create(192, 56);
        uint256 mask = fuzzCfg.vacancyMask();

        // Ensure slotValue has vacancy bits set (occupied)
        if (slotValue & mask == 0) {
            slotValue = slotValue | (uint256(1) << 192);
        }

        harness.store(0, slotValue);

        uint256 tombstone = slotValue & ~clearMask;
        bool vacancyCleared = (tombstone & mask == 0);

        if (tombstone == 0) {
            vm.expectRevert(TombstoneIsZero.selector);
            harness.free(fuzzCfg, 0, clearMask);
        } else if (!vacancyCleared) {
            vm.expectRevert(abi.encodeWithSelector(ClearMaskIncomplete.selector, clearMask));
            harness.free(fuzzCfg, 0, clearMask);
        } else {
            uint256 freed = harness.free(fuzzCfg, 0, clearMask);
            assertEq(freed, slotValue);
            assertTrue(harness.load(0) != 0, "tombstone must be non-zero");
        }
    }
}
