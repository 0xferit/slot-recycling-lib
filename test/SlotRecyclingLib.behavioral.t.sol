// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {RecycleConfig, SlotRecyclingLib} from "src/SlotRecyclingLib.sol";

/// @notice Handler with a reference model for first-vacant semantics.
///         Validates that allocate/findVacant return the first vacant slot matching a simple
///         linear-scan reference. Supports randomized search pointers, clearMask-based free,
///         and sentinel-based free. Parameterized by config shape (offset, width).
contract BehavioralPoolHandler is Test {
    SlotRecyclingLib.Pool private _pool;

    RecycleConfig public immutable CFG;
    uint256 public immutable VACANCY_MASK;
    uint256 public immutable CLEAR_MASK;
    uint256 public immutable SENTINEL;
    uint256 private immutable _vacancyBitOffset;

    // ── Reference model ──

    /// @dev Which indices are currently occupied according to the model.
    mapping(uint256 => bool) public occupied;

    /// @dev Compact list of occupied indices (maintained via swap-and-pop).
    uint256[] public occupiedList;
    uint256 public occupiedCount;

    /// @dev Highest index ever written + 1. Bounds the invariant inspection window.
    uint256 public highWaterMark;

    // ── Sticky violation flags ──
    //    Set once if a behavioral property is violated; never cleared.
    //    Checked by invariant functions in the test contract.

    bool public allocateViolation;
    bool public findVacantViolation;

    // ── Counters (make view-like actions non-view for Foundry targeting) ──

    uint256 public findVacantCalls;

    constructor(uint256 vacancyBitOffset, uint256 vacancyBitWidth) {
        CFG = SlotRecyclingLib.create(vacancyBitOffset, vacancyBitWidth);
        VACANCY_MASK = CFG.vacancyMask();
        CLEAR_MASK = VACANCY_MASK;
        _vacancyBitOffset = vacancyBitOffset;

        // Sentinel: a single bit outside the vacancy region (always valid).
        if (vacancyBitOffset > 0) {
            SENTINEL = 1; // bit 0
        } else {
            SENTINEL = uint256(1) << (vacancyBitOffset + vacancyBitWidth);
        }
    }

    // ── Internal helpers ──

    /// @notice Build a packed value that is guaranteed to have vacancy bits set and at least
    ///         one bit outside the vacancy region (so the tombstone survives clearMask-free).
    function _buildPackedValue(uint256 seed) internal view returns (uint256) {
        // Always set one vacancy bit + the sentinel bit (outside vacancy region).
        uint256 packed = (uint256(1) << _vacancyBitOffset) | SENTINEL;
        // Mix in additional vacancy-region variety from the seed.
        packed |= (seed & VACANCY_MASK);
        return packed;
    }

    /// @notice Reference model: first vacant index at or after `from`.
    ///         Simple linear scan — obviously correct by construction.
    function _referenceFirstVacant(uint256 from) internal view returns (uint256) {
        uint256 ptr = from;
        while (occupied[ptr]) {
            unchecked {
                ptr++;
            }
        }
        return ptr;
    }

    // ── Handler actions (targeted by Foundry's invariant fuzzer) ──

    /// @notice Allocate a slot with a randomized search pointer.
    ///         Compares the library result against the reference model and sets
    ///         `allocateViolation` if they disagree.
    function doAllocate(uint256 searchPointerSeed, uint256 valueSeed) external {
        uint256 searchPointer = bound(searchPointerSeed, 0, highWaterMark + 3);
        uint256 packed = _buildPackedValue(valueSeed);

        // Reference prediction.
        uint256 expected = _referenceFirstVacant(searchPointer);

        // Library call.
        uint256 actual = SlotRecyclingLib.allocate(_pool, CFG, searchPointer, packed);

        // Behavioral check.
        if (actual != expected) allocateViolation = true;

        // Update reference model (use actual to keep model in sync with pool).
        occupied[actual] = true;
        occupiedList.push(actual);
        occupiedCount++;
        if (actual + 1 > highWaterMark) highWaterMark = actual + 1;
    }

    /// @notice Free a randomly selected occupied slot using clearMask.
    function doFree(uint256 seed) external {
        if (occupiedCount == 0) return;
        uint256 listIdx = seed % occupiedCount;
        uint256 poolIdx = occupiedList[listIdx];
        if (!occupied[poolIdx]) return;

        SlotRecyclingLib.free(_pool, CFG, poolIdx, CLEAR_MASK);
        occupied[poolIdx] = false;

        // Swap-and-pop.
        occupiedList[listIdx] = occupiedList[occupiedCount - 1];
        occupiedList.pop();
        occupiedCount--;
    }

    /// @notice Free a randomly selected occupied slot using a sentinel value.
    function doFreeWithSentinel(uint256 seed) external {
        if (occupiedCount == 0) return;
        uint256 listIdx = seed % occupiedCount;
        uint256 poolIdx = occupiedList[listIdx];
        if (!occupied[poolIdx]) return;

        SlotRecyclingLib.freeWithSentinel(_pool, CFG, poolIdx, SENTINEL);
        occupied[poolIdx] = false;

        // Swap-and-pop.
        occupiedList[listIdx] = occupiedList[occupiedCount - 1];
        occupiedList.pop();
        occupiedCount--;
    }

    /// @notice Call findVacant with a randomized search pointer and compare
    ///         against the reference model. Sets `findVacantViolation` on mismatch.
    function doFindVacant(uint256 searchPointerSeed) external {
        findVacantCalls++; // side-effect keeps this non-view

        uint256 searchPointer = bound(searchPointerSeed, 0, highWaterMark + 3);
        uint256 expected = _referenceFirstVacant(searchPointer);
        uint256 actual = SlotRecyclingLib.findVacant(_pool, CFG, searchPointer);

        if (actual != expected) findVacantViolation = true;
    }

    // ── View helpers for invariant checks ──

    function rawLoad(uint256 index) external view returns (uint256) {
        return SlotRecyclingLib.load(_pool, index);
    }

    function getOccupiedList() external view returns (uint256[] memory) {
        return occupiedList;
    }
}

/// @title Behavioral invariant tests for SlotRecyclingLib
/// @notice Validates first-vacant semantics, findVacant correctness, slot uniqueness,
///         tombstone safety, and vacancy-bit consistency across multiple config shapes
///         and randomized search pointers.
contract SlotRecyclingBehavioralTest is Test {
    BehavioralPoolHandler private _handlerDefault; // config(192, 56) – mid-high vacancy
    BehavioralPoolHandler private _handlerLow; // config(0, 8)    – low-bit vacancy
    BehavioralPoolHandler private _handlerHigh; // config(248, 8)  – high-bit vacancy

    function setUp() public {
        _handlerDefault = new BehavioralPoolHandler(192, 56);
        _handlerLow = new BehavioralPoolHandler(0, 8);
        _handlerHigh = new BehavioralPoolHandler(248, 8);

        BehavioralPoolHandler[3] memory hs = [_handlerDefault, _handlerLow, _handlerHigh];

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = BehavioralPoolHandler.doAllocate.selector;
        selectors[1] = BehavioralPoolHandler.doFree.selector;
        selectors[2] = BehavioralPoolHandler.doFreeWithSentinel.selector;
        selectors[3] = BehavioralPoolHandler.doFindVacant.selector;

        for (uint256 i = 0; i < hs.length; i++) {
            targetContract(address(hs[i]));
            targetSelector(FuzzSelector({addr: address(hs[i]), selectors: selectors}));
        }
    }

    // ── Behavioral invariants (sticky-flag based) ──

    /// @notice allocate must always return the first vacant slot at or after the search pointer.
    function invariant_allocateReturnsFirstVacant() public view {
        assertFalse(_handlerDefault.allocateViolation(), "default: allocate returned wrong index");
        assertFalse(_handlerLow.allocateViolation(), "low: allocate returned wrong index");
        assertFalse(_handlerHigh.allocateViolation(), "high: allocate returned wrong index");
    }

    /// @notice findVacant must agree with the reference model for any search pointer.
    function invariant_findVacantMatchesModel() public view {
        assertFalse(_handlerDefault.findVacantViolation(), "default: findVacant mismatch");
        assertFalse(_handlerLow.findVacantViolation(), "low: findVacant mismatch");
        assertFalse(_handlerHigh.findVacantViolation(), "high: findVacant mismatch");
    }

    // ── Structural invariants ──

    /// @notice Every occupied slot must have vacancy flag bits non-zero.
    function invariant_occupiedSlotsHaveVacancyBits() public view {
        _checkOccupiedBits(_handlerDefault);
        _checkOccupiedBits(_handlerLow);
        _checkOccupiedBits(_handlerHigh);
    }

    /// @notice Freed slots (within the high-water mark) must be non-zero and have vacancy bits clear.
    function invariant_freedSlotsNonZeroVacancyClear() public view {
        _checkFreedSlots(_handlerDefault);
        _checkFreedSlots(_handlerLow);
        _checkFreedSlots(_handlerHigh);
    }

    /// @notice The occupied list must contain no duplicate indices.
    function invariant_occupiedSlotsUnique() public view {
        _checkUnique(_handlerDefault);
        _checkUnique(_handlerLow);
        _checkUnique(_handlerHigh);
    }

    // ── Internal check helpers ──

    function _checkOccupiedBits(BehavioralPoolHandler handler) internal view {
        uint256 mask = handler.VACANCY_MASK();
        uint256[] memory list = handler.getOccupiedList();
        for (uint256 i = 0; i < list.length; i++) {
            uint256 raw = handler.rawLoad(list[i]);
            assertTrue(raw & mask != 0, "occupied slot has vacancy bits cleared");
        }
    }

    function _checkFreedSlots(BehavioralPoolHandler handler) internal view {
        uint256 mask = handler.VACANCY_MASK();
        uint256 hwm = handler.highWaterMark();
        for (uint256 i = 0; i < hwm; i++) {
            uint256 raw = handler.rawLoad(i);
            if (raw == 0) continue; // Never written; skip.
            if (handler.occupied(i)) {
                assertTrue(raw & mask != 0, "occupied slot missing vacancy bits");
            } else {
                assertTrue(raw != 0, "freed slot is zero (tombstone lost)");
                assertEq(raw & mask, 0, "freed slot has vacancy bits still set");
            }
        }
    }

    function _checkUnique(BehavioralPoolHandler handler) internal view {
        uint256[] memory list = handler.getOccupiedList();
        for (uint256 i = 0; i < list.length; i++) {
            for (uint256 j = i + 1; j < list.length; j++) {
                assertTrue(list[i] != list[j], "duplicate occupied index");
            }
        }
    }
}
