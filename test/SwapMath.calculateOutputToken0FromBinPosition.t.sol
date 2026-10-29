// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {SwapMath} from "../contracts/libraries/SwapMath.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/**
 * @title SwapMathCalculateOutputToken0FromBinPositionTest
 * @notice Focused tests for SwapMath.calculateOutputToken0FromBinPosition function
 */
contract SwapMathCalculateOutputToken0FromBinPositionTest is Test {
  /**
   * @notice Test that xEnd = x returns 0
   */
  function testFuzz_SamePosition_ReturnsZero(uint104 availableToken0, uint104 x) public pure {
    vm.assume(availableToken0 > 0);
    vm.assume(x < type(uint104).max);

    uint256 outToken0 = SwapMath.calculateOutputToken0FromBinPosition(availableToken0, x, x);

    assertEq(outToken0, 0, "Same position should return 0");
  }

  /**
   * @notice Test that xEnd = type(uint104).max returns availableToken0
   */
  function testFuzz_MaxPosition_ReturnsAvailable(uint104 availableToken0, uint104 x) public pure {
    vm.assume(availableToken0 > 0);
    vm.assume(x < type(uint104).max);

    uint256 outToken0 = SwapMath.calculateOutputToken0FromBinPosition(availableToken0, x, type(uint104).max);

    assertEq(outToken0, availableToken0, "Max position should return all available tokens");
  }

  /**
   * @notice Test linearity: output should scale linearly with position movement
   * @dev If xEnd is at n/type(uint16).max distance from x to max, output should be n/type(uint16).max * availableToken0
   */
  function testFuzz_Linearity_OutputScalesWithPosition(uint104 availableToken0, uint104 x, uint32 n) public pure {
    // Constraints
    vm.assume(availableToken0 > type(uint16).max); // Large enough to avoid rounding issues
    vm.assume(x < type(uint104).max - type(uint16).max); // Leave room for movement
    vm.assume(n <= type(uint16).max);

    // Calculate xEnd at n/type(uint16).max distance from x to max
    uint256 totalDistance = uint256(type(uint104).max) - uint256(x);
    uint256 movement = (totalDistance * uint256(n)) / type(uint16).max;
    uint104 xEnd = SafeCast.toUint104(uint256(x) + movement);

    uint256 outToken0 = SwapMath.calculateOutputToken0FromBinPosition(availableToken0, x, xEnd);

    if (n == 0) {
      assertEq(outToken0, 0, "n=0 should result in zero output");
    } else if (n == type(uint16).max) {
      assertEq(outToken0, availableToken0, "n=type(uint16).max should result in full available amount");
    } else {
      uint256 receivedPart = (type(uint16).max * uint256(outToken0)) / uint256(availableToken0);

      assertGe(receivedPart, n - 1, "Output should be close to expected (floor)");
      assertLe(receivedPart, n, "Output should not exceed expected");
    }
  }

  /**
   * @notice Test that output is always in valid range
   */
  function testFuzz_ResultInValidRange(uint104 availableToken0, uint104 x, uint104 xEnd) public pure {
    vm.assume(availableToken0 > 0);
    vm.assume(x < type(uint104).max);
    vm.assume(xEnd > x);

    uint256 outToken0 = SwapMath.calculateOutputToken0FromBinPosition(availableToken0, x, xEnd);

    assertLe(outToken0, availableToken0, "Output should not exceed available");
  }
}
