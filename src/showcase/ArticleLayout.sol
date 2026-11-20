// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {RecycleConfig, SlotRecyclingLib} from "../SlotRecyclingLib.sol";

uint256 constant WITHDRAWAL_OFFSET = 160;
uint256 constant BOUNTY_OFFSET = 192;
uint256 constant CATEGORY_OFFSET = 248;
uint256 constant WITHDRAWAL_WIDTH = BOUNTY_OFFSET - WITHDRAWAL_OFFSET;
uint256 constant BOUNTY_WIDTH = CATEGORY_OFFSET - BOUNTY_OFFSET;

function articleRecycleConfig() pure returns (RecycleConfig) {
    return SlotRecyclingLib.create(BOUNTY_OFFSET, BOUNTY_WIDTH);
}

function articleClearMask() pure returns (uint256) {
    return SlotRecyclingLib.bitmask(BOUNTY_OFFSET, BOUNTY_WIDTH)
        | SlotRecyclingLib.bitmask(WITHDRAWAL_OFFSET, WITHDRAWAL_WIDTH);
}
