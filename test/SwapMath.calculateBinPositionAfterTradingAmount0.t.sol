// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {SwapMath} from "../contracts/libraries/SwapMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title SwapMathCalculateBinPositionAfterTradingAmount0Test
 * @notice Focused tests for SwapMath.calculateBinPositionAfterSellingAmount0 function
 */
contract SwapMathCalculateBinPositionAfterTradingAmount0Test is Test {
  /**
   * @notice Test that tradedAmount = 0 returns xEnd = x
   */
  function testFuzz_ZeroTradedAmount_ReturnsOriginalPosition(uint104 x, uint128 availableToken0) public pure {
    vm.assume(availableToken0 > 0);

    uint256 xEnd = SwapMath.calculateBinPositionAfterSellingAmount0(x, 0, availableToken0, Math.Rounding.Floor);

    assertEq(xEnd, x, "Zero traded amount should return original position");
  }

  /**
   * @notice Test that tradedAmount = availableToken0 returns xEnd = type(uint104).max
   */
  function testFuzz_FullTradedAmount_ReturnsMax(uint104 x, uint128 availableToken0) public pure {
    vm.assume(availableToken0 > 0);

    uint256 xEnd =
      SwapMath.calculateBinPositionAfterSellingAmount0(x, availableToken0, availableToken0, Math.Rounding.Floor);

    assertEq(xEnd, type(uint104).max, "Full traded amount should return max position");
  }

  /**
   * @notice Test that xEnd is always between x and type(uint104).max
   */
  function testFuzz_ResultInValidRange(uint104 x, uint128 tradedAmount0, uint128 availableToken0) public pure {
    vm.assume(availableToken0 > 0);
    vm.assume(tradedAmount0 <= availableToken0);

    uint256 xEnd =
      SwapMath.calculateBinPositionAfterSellingAmount0(x, tradedAmount0, availableToken0, Math.Rounding.Floor);

    assertGe(xEnd, x, "xEnd should be >= x");
  }

  /**
   * @notice Test linearity: (xEnd - x) should scale linearly with tradedAmount
   * @dev Tests that for tradedAmount = n/100 * availableToken0, the movement is proportional
   *      n=0 -> res-x = 0, n=100 -> res = uint104.max
   */
  function testFuzz_Linearity_MovementScalesWithTradedAmount(uint104 x, uint128 availableToken0, uint8 n) public pure {
    // Constraints
    vm.assume(availableToken0 > type(uint104).max); // Large enough to avoid rounding issues
    vm.assume(x < type(uint104).max - type(uint16).max); // x < max - max:u16
    vm.assume(n <= 100);

    // Calculate tradedAmount = n/100 * availableToken0
    uint128 tradedAmount0 = uint128((uint256(availableToken0) * uint256(n)) / 100);

    uint256 xEnd =
      SwapMath.calculateBinPositionAfterSellingAmount0(x, tradedAmount0, availableToken0, Math.Rounding.Floor);

    uint256 movement = uint256(xEnd) - uint256(x);

    // Expected movement: n/100 of the distance from x to max
    uint256 totalDistance = uint256(type(uint104).max) - uint256(x);
    uint256 expectedMovement = (totalDistance * uint256(n)) / 100;

    // Special cases
    if (n == 0) {
      assertEq(movement, 0, "n=0 should result in zero movement");
    } else if (n == 100) {
      assertEq(xEnd, type(uint104).max, "n=100 should result in max position");
    } else {
      assertGe(movement, expectedMovement > 0 ? expectedMovement - 1 : 0, "Movement should be at or above expected - 1");
      assertLe(movement, expectedMovement + 1, "Movement should be within 1 of expected due to ceiling");
    }
  }
}
