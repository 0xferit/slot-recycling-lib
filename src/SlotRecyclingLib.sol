// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/**
 * @title SlotRecyclingLib
 * @author [0xferit](https://github.com/0xferit)
 * @custom:security-contact ferit@cryptolab.net
 * @notice Library for recycling freed mapping slots to avoid zero-to-nonzero SSTORE costs.
 *
 *         EVM charges ~20,000 gas for a zero-to-nonzero SSTORE but only ~2,900 gas (warm) for
 *         nonzero-to-nonzero. In mapping-backed collections with churn, freed slots can be reused
 *         for new items by leaving a non-zero "tombstone" on deletion instead of fully zeroing.
 *
 *         The `RecycleConfig` value type wraps a precomputed `uint256` vacancy mask. The mask has
 *         consecutive bits set at the position and width specified during `create()`.
 *         A slot is vacant when `slotData & RecycleConfig.unwrap(cfg) == 0`.
 *
 *         Usage:
 *         ```solidity
 *         import {RecycleConfig, SlotRecyclingLib} from "slot-recycling-lib/src/SlotRecyclingLib.sol";
 *
 *         RecycleConfig private immutable CFG = SlotRecyclingLib.create(192, 56);
 *         SlotRecyclingLib.Pool private _pool;
 *
 *         uint256 idx = SlotRecyclingLib.allocate(_pool, CFG, 0, packedValue);
 *         SlotRecyclingLib.free(_pool, CFG, idx, CLEAR_MASK);
 *         ```
 *
 *         **Important:** Always construct `RecycleConfig` values via `create()`. Using
 *         `RecycleConfig.wrap()` directly bypasses validation and produces undefined behavior.
 */
type RecycleConfig is uint256;

/// @notice Thrown by `create` when the (vacancyBitOffset, vacancyBitWidth) pair is invalid.
error BadRecycleConfig(uint256 vacancyBitOffset, uint256 vacancyBitWidth);

/// @notice Thrown by `free` when clearing bits would leave the slot fully zeroed.
error TombstoneIsZero();

/// @notice Thrown by `allocate` when the packed value has vacancy flag bits all-zero.
error VacancyFlagNotSet(uint256 packedValue);

/// @notice Thrown by `free` when clearMask does not cover the vacancy flag bits.
error ClearMaskIncomplete(uint256 clearMask);

/// @notice Thrown by `freeWithSentinel` when the sentinel has vacancy flag bits set.
error SentinelOccupied(uint256 sentinel);

library SlotRecyclingLib {
    string internal constant VERSION = "1.0.2";

    struct Pool {
        mapping(uint256 => uint256) _data;
    }

    // -------------------------------------------------------------------------
    // Factory
    // -------------------------------------------------------------------------

    /// @notice Creates a `RecycleConfig` from vacancyBitOffset and vacancyBitWidth.
    /// @dev    Both parameters must be multiples of 8. vacancyBitWidth must be >= 8.
    ///         vacancyBitOffset + vacancyBitWidth must be <= 256.
    ///         The returned config wraps the precomputed vacancy mask.
    ///         **Byte-alignment:** the multiples-of-8 constraint is a deliberate design choice, not
    ///         a technical requirement. It simplifies integration with Solidity's native packed types
    ///         (uint8, uint16, ..., uint248) where field boundaries always fall on byte boundaries.
    ///         Sub-byte vacancy flags (e.g., a single bool bit) are not supported.
    function create(uint256 _vacancyBitOffset, uint256 _vacancyBitWidth) internal pure returns (RecycleConfig) {
        if (
            _vacancyBitWidth < 8 || _vacancyBitWidth > 248 || _vacancyBitOffset > 248 || _vacancyBitOffset % 8 != 0
                || _vacancyBitWidth % 8 != 0 || _vacancyBitOffset + _vacancyBitWidth > 256
        ) {
            revert BadRecycleConfig(_vacancyBitOffset, _vacancyBitWidth);
        }
        return RecycleConfig.wrap(bitmask(_vacancyBitOffset, _vacancyBitWidth));
    }

    // -------------------------------------------------------------------------
    // Config accessor
    // -------------------------------------------------------------------------

    /// @notice Returns the vacancy mask: bits that must be non-zero for an occupied slot.
    function vacancyMask(RecycleConfig cfg) internal pure returns (uint256) {
        return RecycleConfig.unwrap(cfg);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    /// @notice Returns a bitmask with `width` bits set starting at `offset`.
    /// @dev    Convenience for building clearMask arguments. Compose multiple ranges with OR:
    ///         `bitmask(160, 32) | bitmask(192, 56)` clears bits 160-247.
    function bitmask(uint256 offset, uint256 width) internal pure returns (uint256) {
        return ((uint256(1) << width) - 1) << offset;
    }

    // -------------------------------------------------------------------------
    // Core functions
    // -------------------------------------------------------------------------

    /// @notice Scan forward from `searchPointer` until a vacant slot is found, then write `packedValue`.
    /// @dev    Reverts with `VacancyFlagNotSet` if the vacancy flag bits in `packedValue` are all zero,
    ///         since the slot would appear vacant immediately after writing.
    ///         **Gas warning:** the scan is O(n) in the number of contiguous occupied slots from
    ///         `searchPointer`. Each slot scanned adds one storage read plus loop overhead (~100 gas
    ///         warm, ~2,100 gas cold). Use `findVacant` off-chain to compute a tight hint.
    /// @return index The slot index where `packedValue` was stored.
    function allocate(Pool storage pool, RecycleConfig cfg, uint256 searchPointer, uint256 packedValue)
        internal
        returns (uint256 index)
    {
        uint256 mask = vacancyMask(cfg);
        if (packedValue & mask == 0) revert VacancyFlagNotSet(packedValue);

        uint256 ptr = searchPointer;
        while (pool._data[ptr] & mask != 0) {
            unchecked {
                ptr++;
            }
        }
        pool._data[ptr] = packedValue;
        return ptr;
    }

    /// @notice Mark a slot as vacant by clearing bits specified in `clearMask`.
    /// @dev    The remaining bits form the "tombstone" that keeps the slot non-zero.
    ///         Reverts with `TombstoneIsZero` if the result would be zero.
    /// @return freedValue The original value that was in the slot before freeing.
    function free(Pool storage pool, RecycleConfig cfg, uint256 index, uint256 clearMask)
        internal
        returns (uint256 freedValue)
    {
        freedValue = pool._data[index];
        uint256 tombstone = freedValue & ~clearMask;
        if (tombstone == 0) revert TombstoneIsZero();
        // Verify vacancy flag is actually cleared.
        uint256 mask = vacancyMask(cfg);
        if (tombstone & mask != 0) {
            revert ClearMaskIncomplete(clearMask);
        }
        pool._data[index] = tombstone;
    }

    /// @notice Mark a slot as vacant by writing a fixed sentinel value.
    /// @dev    Use when no field naturally stays non-zero after clearing.
    ///         The sentinel must be non-zero and must have vacancy flag bits == 0.
    /// @return freedValue The original value that was in the slot before freeing.
    function freeWithSentinel(Pool storage pool, RecycleConfig cfg, uint256 index, uint256 sentinel)
        internal
        returns (uint256 freedValue)
    {
        if (sentinel == 0) revert TombstoneIsZero();
        uint256 mask = vacancyMask(cfg);
        if (sentinel & mask != 0) revert SentinelOccupied(sentinel);
        freedValue = pool._data[index];
        pool._data[index] = sentinel;
    }

    /// @notice Read the raw packed value at `index`.
    function load(Pool storage pool, uint256 index) internal view returns (uint256) {
        return pool._data[index];
    }

    /// @notice Write a raw packed value at `index` without scanning for vacancy.
    /// @dev    **Invariant bypass:** this function does not check vacancy or the vacancy flag.
    ///         Writing zero or a value with vacancy bits unset will corrupt pool state.
    ///         Use `allocate` for safe writes; use this only for advanced migration scenarios.
    function store(Pool storage pool, uint256 index, uint256 packedValue) internal {
        pool._data[index] = packedValue;
    }

    /// @notice Returns true if the slot at `index` is vacant (vacancy flag bits are all zero).
    function isVacant(Pool storage pool, RecycleConfig cfg, uint256 index) internal view returns (bool) {
        return pool._data[index] & vacancyMask(cfg) == 0;
    }

    /// @notice Find the next vacant slot starting from `searchPointer`.
    /// @dev    Intended for off-chain use (view). On-chain callers should use `allocate` which
    ///         combines scanning and writing in a single call.
    ///         **Gas warning:** the scan is O(n) in the number of contiguous occupied slots.
    ///         Each slot scanned adds one storage read plus loop overhead (~100 gas warm,
    ///         ~2,100 gas cold).
    function findVacant(Pool storage pool, RecycleConfig cfg, uint256 searchPointer)
        internal
        view
        returns (uint256 index)
    {
        uint256 mask = vacancyMask(cfg);
        uint256 ptr = searchPointer;
        while (pool._data[ptr] & mask != 0) {
            unchecked {
                ptr++;
            }
        }
        return ptr;
    }
}

using SlotRecyclingLib for RecycleConfig global;
