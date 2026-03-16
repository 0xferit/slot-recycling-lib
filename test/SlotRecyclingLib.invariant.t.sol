// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {RecycleConfig, SlotRecyclingLib, VacancyFlagNotSet, TombstoneIsZero} from "src/SlotRecyclingLib.sol";

/// @notice Handler that exposes allocate/free as external calls for Foundry's invariant tester.
///         Tracks which slots are occupied so the invariant test can verify properties.
contract PoolHandler {
    SlotRecyclingLib.Pool private _pool;
    RecycleConfig public immutable CFG = SlotRecyclingLib.create(192, 56);
    uint256 public constant VACANCY_MASK = ((uint256(1) << 56) - 1) << 192;
    uint256 public constant CLEAR_MASK = (((uint256(1) << 56) - 1) << 192) | (((uint256(1) << 32) - 1) << 160);

    // Ghost state: tracks which indices are occupied.
    mapping(uint256 => bool) public occupied;
    uint256[] public occupiedList;
    uint256 public occupiedCount;

    /// @notice Allocate a slot with a random-ish packed value.
    function doAllocate(uint56 bountyAmount, uint8 category) external {
        if (bountyAmount == 0) bountyAmount = 1;
        uint256 packed = uint256(uint160(msg.sender)) | (uint256(bountyAmount) << 192) | (uint256(category) << 248);

        uint256 idx = SlotRecyclingLib.allocate(_pool, CFG, 0, packed);
        occupied[idx] = true;
        occupiedList.push(idx);
        occupiedCount++;
    }

    /// @notice Free the N-th occupied slot (modular index into occupiedList).
    function doFree(uint256 seed) external {
        if (occupiedCount == 0) return;
        uint256 listIdx = seed % occupiedCount;
        uint256 poolIdx = occupiedList[listIdx];
        if (!occupied[poolIdx]) return;

        SlotRecyclingLib.free(_pool, CFG, poolIdx, CLEAR_MASK);
        occupied[poolIdx] = false;

        // Swap-and-pop from occupiedList.
        occupiedList[listIdx] = occupiedList[occupiedCount - 1];
        occupiedList.pop();
        occupiedCount--;
    }

    /// @notice Read raw slot data for invariant checks.
    function rawLoad(uint256 index) external view returns (uint256) {
        return SlotRecyclingLib.load(_pool, index);
    }

    function getOccupiedList() external view returns (uint256[] memory) {
        return occupiedList;
    }
}

contract SlotRecyclingInvariantTest is Test {
    PoolHandler handler;

    function setUp() public {
        handler = new PoolHandler();
        targetContract(address(handler));

        // Only call doAllocate and doFree.
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = PoolHandler.doAllocate.selector;
        selectors[1] = PoolHandler.doFree.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice Every occupied slot must have vacancy flag bits non-zero.
    function invariant_occupiedSlotsHaveVacancyBitsSet() public view {
        uint256 mask = handler.VACANCY_MASK();
        uint256[] memory list = handler.getOccupiedList();
        for (uint256 i = 0; i < list.length; i++) {
            uint256 raw = handler.rawLoad(list[i]);
            assertTrue(raw & mask != 0, "occupied slot has vacancy bits cleared");
        }
    }

    /// @notice Every freed slot must be non-zero (tombstone preserved).
    /// @dev    Checks a window of indices: if a slot is not in the occupied set and has been
    ///         written to (raw != 0), the tombstone must have vacancy bits == 0.
    function invariant_freedSlotsAreNonZeroWithVacancyClear() public view {
        uint256 mask = handler.VACANCY_MASK();
        // Check indices 0..occupiedCount+5 (covers allocated and freed range).
        uint256 checkRange = handler.occupiedCount() + 6;
        if (checkRange > 50) checkRange = 50;
        for (uint256 i = 0; i < checkRange; i++) {
            uint256 raw = handler.rawLoad(i);
            if (raw == 0) continue; // Never written; skip.
            if (handler.occupied(i)) {
                // Occupied: vacancy bits must be set.
                assertTrue(raw & mask != 0, "occupied slot missing vacancy bits");
            } else {
                // Freed (tombstoned): vacancy bits must be clear, slot must be non-zero.
                assertEq(raw & mask, 0, "freed slot has vacancy bits still set");
            }
        }
    }
}
