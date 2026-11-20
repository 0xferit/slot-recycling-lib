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

/// @title RecycledArticleStoreWithHint
/// @notice Gas fixture that keeps a persistent hint for scanning vacant article slots.
/// @dev Every index below the hint is occupied. On create the hint advances past the chosen slot.
///      A deletion below the hint moves it back to that vacancy. The next scan can still cross an
///      arbitrarily long occupied span between vacancies.
///      Deletion is unrestricted. Deleting an existing tombstone emits another deletion event.
///      Deleting a never-written slot reverts. Reads expose tombstone data until reuse.
///      Article identifiers are recycled slot indices.
contract RecycledArticleStoreWithHint {
    SlotRecyclingLib.Pool private _pool;

    RecycleConfig private immutable CFG = articleRecycleConfig();
    uint256 private immutable CLEAR_MASK = articleClearMask();

    uint256 private _nextHint;

    event ArticleCreated(uint256 indexed id, address owner);
    event ArticleDeleted(uint256 indexed id);

    function createArticle(uint56 _bountyAmount, uint8 _category) external returns (uint256 id) {
        require(_bountyAmount > 0, "bounty required");
        uint256 packed = uint256(uint160(msg.sender)) | (uint256(_bountyAmount) << BOUNTY_OFFSET)
            | (uint256(_category) << CATEGORY_OFFSET);

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
        withdrawalPermittedAt = uint32(raw >> WITHDRAWAL_OFFSET);
        bountyAmount = uint56(raw >> BOUNTY_OFFSET);
        category = uint8(raw >> CATEGORY_OFFSET);
    }

    /// @notice Returns the current hint value (for off-chain monitoring or testing).
    function nextHint() external view returns (uint256) {
        return _nextHint;
    }

    function findVacantSlot(uint256 _searchPointer) external view returns (uint256) {
        return SlotRecyclingLib.findVacant(_pool, CFG, _searchPointer);
    }
}
