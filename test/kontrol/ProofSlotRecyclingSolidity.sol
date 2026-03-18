// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {
    RecycleConfig,
    SlotRecyclingLib,
    TombstoneIsZero,
    VacancyFlagNotSet,
    ClearMaskIncomplete,
    SentinelOccupied
} from "src/SlotRecyclingLib.sol";
import {ProofAssumptions} from "test/kontrol/ProofAssumptions.sol";

/**
 * @title ProofSlotRecyclingSolidity
 * @notice Kontrol formal-verification proofs for the core SlotRecyclingLib properties.
 *
 *         Canonical config: vacancy flag at bits 192-247 (offset=192, width=56).
 *         Pool state is always fresh (empty) at the start of each proof (run-constructor=true).
 *
 *         Proof naming convention: prove_<function>_<scenario>.
 *         Essential (CI) subset: all prove_*_reverts proofs.
 *         Full set: all prove_* proofs.
 */
contract ProofSlotRecyclingSolidity is ProofAssumptions {
    SlotRecyclingLib.Pool internal _pool;

    // Canonical 192/56 config set in constructor (immutable).
    RecycleConfig internal immutable _cfg;

    // Vacancy mask: bits 192-247 (56 bits). Same as _VACANCY_MASK in ProofAssumptions.
    uint256 internal constant VACANCY_MASK = ((uint256(1) << 56) - 1) << 192;

    // Concrete live value: owner=0xdead (bits 0-159), bounty=42 (bits 192-247), category=1 (bit 248).
    uint256 internal constant OWNER_BITS = uint256(uint160(0xdead));
    uint256 internal constant BOUNTY_BITS = uint256(42) << 192;
    uint256 internal constant CATEGORY_BITS = uint256(1) << 248;
    uint256 internal constant LIVE_VALUE = OWNER_BITS | BOUNTY_BITS | CATEGORY_BITS;

    // clearMask covers bounty (bits 192-247) and withdrawalPermittedAt (bits 160-191).
    uint256 internal constant CLEAR_MASK =
        (((uint256(1) << 56) - 1) << 192) | (((uint256(1) << 32) - 1) << 160);

    constructor() {
        _cfg = SlotRecyclingLib.create(192, 56);
    }

    // ── External wrappers (for revert capture via low-level call) ──

    function _doAllocate(uint256 searchPointer, uint256 packedValue) external {
        SlotRecyclingLib.allocate(_pool, _cfg, searchPointer, packedValue);
    }

    function _doFree(uint256 index, uint256 clearMask) external {
        SlotRecyclingLib.free(_pool, _cfg, index, clearMask);
    }

    function _doFreeWithSentinel(uint256 index, uint256 sentinel) external {
        SlotRecyclingLib.freeWithSentinel(_pool, _cfg, index, sentinel);
    }

    // ── Helper ──

    function _assertCustomErrorSelector(bytes memory returndata, bytes4 expectedSelector) internal pure {
        assertGe(returndata.length, 4);
        bytes4 actualSelector;
        assembly ("memory-safe") {
            actualSelector := mload(add(returndata, 0x20))
        }
        assertEq(actualSelector, expectedSelector);
    }

    // ────────────────────────────────────────────────────────────────
    // allocate proofs
    // ────────────────────────────────────────────────────────────────

    /// @notice allocate reverts with VacancyFlagNotSet when all vacancy bits in packedValue are zero.
    function prove_allocate_vacancyFlagZero_reverts(uint256 packedValue, uint256 searchPointer) public {
        _assumePackedValueWithoutVacancy(packedValue);
        (bool success, bytes memory returndata) =
            address(this).call(abi.encodeCall(this._doAllocate, (searchPointer, packedValue)));
        assertFalse(success);
        _assertCustomErrorSelector(returndata, VacancyFlagNotSet.selector);
    }

    /// @notice allocate reuses a just-freed slot when searchPointer starts at that slot (concrete).
    function prove_allocate_reuses_freed_slot() public {
        uint256 idx = SlotRecyclingLib.allocate(_pool, _cfg, 0, LIVE_VALUE);
        assertEq(idx, 0);
        SlotRecyclingLib.free(_pool, _cfg, 0, CLEAR_MASK);
        uint256 idx2 = SlotRecyclingLib.allocate(_pool, _cfg, 0, LIVE_VALUE);
        assertEq(idx2, 0);
    }

    // ────────────────────────────────────────────────────────────────
    // free proofs
    // ────────────────────────────────────────────────────────────────

    /// @notice free reverts with TombstoneIsZero when clearing all bits would zero the slot.
    function prove_free_tombstoneZero_reverts(uint256 slotValue) public {
        _assumePackedValueWithVacancy(slotValue);
        SlotRecyclingLib.store(_pool, 0, slotValue);
        (bool success, bytes memory returndata) =
            address(this).call(abi.encodeCall(this._doFree, (0, type(uint256).max)));
        assertFalse(success);
        _assertCustomErrorSelector(returndata, TombstoneIsZero.selector);
    }

    /// @notice free writes a non-zero tombstone with vacancy bits cleared on success (concrete).
    function prove_free_writesNonZeroTombstoneWithVacancyCleared() public {
        SlotRecyclingLib.allocate(_pool, _cfg, 0, LIVE_VALUE);
        SlotRecyclingLib.free(_pool, _cfg, 0, CLEAR_MASK);
        uint256 raw = SlotRecyclingLib.load(_pool, 0);
        assertTrue(raw != 0);
        assertEq(raw & VACANCY_MASK, 0);
    }

    // ────────────────────────────────────────────────────────────────
    // freeWithSentinel proofs
    // ────────────────────────────────────────────────────────────────

    /// @notice freeWithSentinel reverts with TombstoneIsZero when sentinel is zero.
    function prove_freeWithSentinel_zeroSentinel_reverts(uint256 index) public {
        (bool success, bytes memory returndata) =
            address(this).call(abi.encodeCall(this._doFreeWithSentinel, (index, 0)));
        assertFalse(success);
        _assertCustomErrorSelector(returndata, TombstoneIsZero.selector);
    }

    /// @notice freeWithSentinel reverts with SentinelOccupied when sentinel has vacancy bits set.
    function prove_freeWithSentinel_occupiedSentinel_reverts(uint256 index, uint256 sentinel) public {
        _assumeSentinelOccupied(sentinel);
        (bool success, bytes memory returndata) =
            address(this).call(abi.encodeCall(this._doFreeWithSentinel, (index, sentinel)));
        assertFalse(success);
        _assertCustomErrorSelector(returndata, SentinelOccupied.selector);
    }

    /// @notice freeWithSentinel writes non-zero sentinel with vacancy bits cleared on success.
    function prove_freeWithSentinel_writesNonZeroSentinelWithVacancyCleared(uint256 sentinel) public {
        _assumeValidSentinel(sentinel);
        SlotRecyclingLib.store(_pool, 0, LIVE_VALUE);
        SlotRecyclingLib.freeWithSentinel(_pool, _cfg, 0, sentinel);
        uint256 raw = SlotRecyclingLib.load(_pool, 0);
        assertEq(raw, sentinel);
        assertTrue(raw != 0);
        assertEq(raw & VACANCY_MASK, 0);
    }

    // ────────────────────────────────────────────────────────────────
    // findVacant proofs
    // ────────────────────────────────────────────────────────────────

    /// @notice findVacant returns slot 0 when the pool is fresh (concrete).
    function prove_findVacant_freshPool_returnsZero() public view {
        uint256 idx = SlotRecyclingLib.findVacant(_pool, _cfg, 0);
        assertEq(idx, 0);
    }

    /// @notice findVacant returns the freed slot when searching from that slot (concrete).
    function prove_findVacant_finds_freed_slot() public {
        SlotRecyclingLib.allocate(_pool, _cfg, 0, LIVE_VALUE);
        SlotRecyclingLib.free(_pool, _cfg, 0, CLEAR_MASK);
        uint256 idx = SlotRecyclingLib.findVacant(_pool, _cfg, 0);
        assertEq(idx, 0);
    }
}
