// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {RecycleConfig, SlotRecyclingLib} from "../SlotRecyclingLib.sol";

/// @title  RecycledArticleStore
/// @notice Optimized contract: uses SlotRecyclingLib to recycle freed mapping slots.
///         Saves ~17,100 gas per recycled allocation vs RawArticleStore.
/// @dev    Differs from the raw baseline: IDs are recycled slot indices (not monotonic),
///         and reading a deleted slot returns stale tombstone data (not zeros).
///         Production contracts should track a `_nextHint` state variable to avoid scanning
///         from 0 on every allocation. This showcase omits hints to isolate the recycling benefit.
contract RecycledArticleStore {
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

    event ArticleCreated(uint256 indexed id, address owner);
    event ArticleDeleted(uint256 indexed id);

    function createArticle(uint56 _bountyAmount, uint8 _category) external returns (uint256 id) {
        require(_bountyAmount > 0, "bounty required");
        uint256 packed = uint256(uint160(msg.sender)) | (uint256(_bountyAmount) << 192) | (uint256(_category) << 248);

        id = SlotRecyclingLib.allocate(_pool, CFG, 0, packed);
        emit ArticleCreated(id, msg.sender);
    }

    function deleteArticle(uint256 _id) external {
        SlotRecyclingLib.free(_pool, CFG, _id, CLEAR_MASK);
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

    function findVacantSlot(uint256 _searchPointer) external view returns (uint256) {
        return SlotRecyclingLib.findVacant(_pool, CFG, _searchPointer);
    }
}
