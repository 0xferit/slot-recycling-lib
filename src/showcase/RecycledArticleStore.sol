// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {RecycleConfig, SlotRecyclingLib} from "../SlotRecyclingLib.sol";
import {
    WITHDRAWAL_OFFSET,
    BOUNTY_OFFSET,
    CATEGORY_OFFSET,
    articleRecycleConfig,
    articleClearMask
} from "./ArticleLayout.sol";

/// @title RecycledArticleStore
/// @notice Gas fixture that scans from zero and reuses vacant slot indices as article identifiers.
/// @dev Deletion is unrestricted. Deleting an existing tombstone emits another deletion event.
///      Deleting a never-written slot reverts. Reads expose the tombstone until the slot is reused.
///      Vacancy scans visit consecutive occupied slots with no fixed gas bound.
contract RecycledArticleStore {
    SlotRecyclingLib.Pool private _pool;

    RecycleConfig private immutable CFG = articleRecycleConfig();
    uint256 private immutable CLEAR_MASK = articleClearMask();

    event ArticleCreated(uint256 indexed id, address owner);
    event ArticleDeleted(uint256 indexed id);

    function createArticle(uint56 _bountyAmount, uint8 _category) external returns (uint256 id) {
        require(_bountyAmount > 0, "bounty required");
        uint256 packed = uint256(uint160(msg.sender)) | (uint256(_bountyAmount) << BOUNTY_OFFSET)
            | (uint256(_category) << CATEGORY_OFFSET);

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
        withdrawalPermittedAt = uint32(raw >> WITHDRAWAL_OFFSET);
        bountyAmount = uint56(raw >> BOUNTY_OFFSET);
        category = uint8(raw >> CATEGORY_OFFSET);
    }

    function findVacantSlot(uint256 _searchPointer) external view returns (uint256) {
        return SlotRecyclingLib.findVacant(_pool, CFG, _searchPointer);
    }
}
