// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";

abstract contract ProofAssumptions is Test {
    // Canonical 192/56 vacancy mask (bits 192-247).
    uint256 internal constant _VACANCY_MASK = ((uint256(1) << 56) - 1) << 192;

    function _assumePackedValueWithVacancy(uint256 value) internal {
        vm.assume((value & _VACANCY_MASK) != 0);
    }

    function _assumePackedValueWithoutVacancy(uint256 value) internal {
        vm.assume((value & _VACANCY_MASK) == 0);
    }

    function _assumeValidSentinel(uint256 sentinel) internal {
        vm.assume(sentinel != 0);
        vm.assume((sentinel & _VACANCY_MASK) == 0);
    }

    function _assumeSentinelOccupied(uint256 sentinel) internal {
        vm.assume((sentinel & _VACANCY_MASK) != 0);
    }
}
