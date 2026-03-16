// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/// @title  RawArticleStore
/// @notice Baseline contract: standard mapping with full-zero deletion.
///         Used as the control case for gas benchmarks against RecycledArticleStore.
contract RawArticleStore {
    struct Article {
        address owner;
        uint32 withdrawalPermittedAt;
        uint56 bountyAmount;
        uint8 category;
    }

    mapping(uint256 => Article) public articles;
    uint256 public nextId;

    function createArticle(uint56 _bountyAmount, uint8 _category) external returns (uint256 id) {
        id = nextId++;
        articles[id] =
            Article({owner: msg.sender, withdrawalPermittedAt: 0, bountyAmount: _bountyAmount, category: _category});
    }

    function deleteArticle(uint256 _id) external {
        delete articles[_id];
    }

    function readArticle(uint256 _id) external view returns (Article memory) {
        return articles[_id];
    }
}
