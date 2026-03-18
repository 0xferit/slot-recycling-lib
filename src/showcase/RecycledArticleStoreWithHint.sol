// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {RecycleConfig, SlotRecyclingLib} from "../SlotRecyclingLib.sol";

/// @title  RecycledArticleStoreWithHint
/// @notice Production-oriented showcase: uses SlotRecyclingLib with a `_nextHint` strategy
///         to keep vacancy scans tight.
///
/// @dev    **Hint strategy (simple backward-on-free):**
///
///         `_nextHint` tracks the lowest index likely to be vacant.
///
///         • On **allocate**: the library scans from `_nextHint` and returns the index it wrote to.
///           We set `_nextHint = allocatedIndex + 1` so the next allocation starts right after the
///           slot just filled—no wasted re-scanning of known-occupied slots.
///
///         • On **free**: if the freed index is below `_nextHint`, we move `_nextHint` down to
///           the freed index so the next allocation finds it immediately (zero scan iterations).
///           If the freed index is at or above `_nextHint`, we leave the hint unchanged because
///           lowering it would not help the allocator reach that newly freed higher slot sooner.
///
///         **Tradeoffs:**
///         - This strategy is greedy: it always reuses the lowest available slot. Allocations
///           cluster toward the bottom of the index space, which keeps scans short.
///         - If many slots are freed above `_nextHint`, only the lowest one pulls the hint down.
///           The others are still reachable—they just require scanning past the lower vacancy first.
///         - The hint is never wrong in a safety sense: `allocate` will always find a vacant slot
///           even if the hint points to an occupied one. A stale hint only costs extra scan gas.
///
///         This contract is otherwise identical to `RecycledArticleStore` and uses the same
///         bit-packing layout.
contract RecycledArticleStoreWithHint {
    /// @dev Article layout in a single 256-bit word:
    ///      bits   0-159 : owner (address, 160 bits)
    ///      bits 160-191 : withdrawalPermittedAt (uint32)
    ///      bits 192-247 : bountyAmount (uint56) <-- vacancy flag
    ///      bits 248-255 : category (uint8)
    SlotRecyclingLib.Pool private _pool;

    /// @dev Vacancy flag: bountyAmount at bits 192-247.
    RecycleConfig private immutable CFG = SlotRecyclingLib.create(192, 56);

    /// @dev Clear mask: zeros bountyAmount (bits 192-247) and withdrawalPermittedAt (bits 160-191).
    ///      Leaves owner and category as tombstone.
    uint256 private immutable CLEAR_MASK = SlotRecyclingLib.bitmask(192, 56) | SlotRecyclingLib.bitmask(160, 32);

    /// @dev Lowest index likely to be vacant. Updated on allocate and free.
    uint256 private _nextHint;

    event ArticleCreated(uint256 indexed id, address owner);
    event ArticleDeleted(uint256 indexed id);

    function createArticle(uint56 _bountyAmount, uint8 _category) external returns (uint256 id) {
        require(_bountyAmount > 0, "bounty required");
        uint256 packed = uint256(uint160(msg.sender)) | (uint256(_bountyAmount) << 192) | (uint256(_category) << 248);

        id = SlotRecyclingLib.allocate(_pool, CFG, _nextHint, packed);
        _nextHint = id + 1;
        emit ArticleCreated(id, msg.sender);
    }

    function deleteArticle(uint256 _id) external {
        SlotRecyclingLib.free(_pool, CFG, _id, CLEAR_MASK);
        if (_id < _nextHint) {
            _nextHint = _id;
        }
        emit ArticleDeleted(_id);
    }

    function readArticle(uint256 _id)
        external
        view
        returns (address owner, uint32 withdrawalPermittedAt, uint56 bountyAmount, uint8 category)
    {
        uint256 raw = SlotRecyclingLib.load(_pool, _id);
        owner = address(uint160(raw));
        withdrawalPermittedAt = uint32(raw >> 160);
        bountyAmount = uint56(raw >> 192);
        category = uint8(raw >> 248);
    }

    /// @notice Returns the current hint value (for off-chain monitoring or testing).
    function nextHint() external view returns (uint256) {
        return _nextHint;
    }

    function findVacantSlot(uint256 _searchPointer) external view returns (uint256) {
        return SlotRecyclingLib.findVacant(_pool, CFG, _searchPointer);
    }
}
