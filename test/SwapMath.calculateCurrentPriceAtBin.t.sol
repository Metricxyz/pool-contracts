// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {SwapMath} from "../contracts/libraries/SwapMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title SwapMathCalculateCurrentPriceAtBinTest
 * @notice Focused tests for SwapMath.calculateCurrentPriceAtBin function
 */
contract SwapMathCalculateCurrentPriceAtBinTest is Test {
  /**
   * @notice Test that position 0 returns lowerPrice for both roundings
   */
  function testFuzz_PositionZero_ReturnLowerPrice(uint128 lowerPrice, uint128 upperPrice) public pure {
    vm.assume(lowerPrice > 0);
    vm.assume(upperPrice > lowerPrice);
    vm.assume(upperPrice <= type(uint104).max);

    uint256 resultDown = SwapMath.calculatePriceAtBinPosition(lowerPrice, upperPrice, 0, Math.Rounding.Floor);
    uint256 resultUp = SwapMath.calculatePriceAtBinPosition(lowerPrice, upperPrice, 0, Math.Rounding.Ceil);

    assertEq(resultDown, lowerPrice, "Position 0 should return lowerPrice (floor)");
    assertEq(resultUp, lowerPrice, "Position 0 should return lowerPrice (ceil)");
  }

  /**
   * @notice Test that position max returns upperPrice for both roundings
   */
  function testFuzz_PositionMax_ReturnUpperPrice(uint128 lowerPrice, uint128 upperPrice) public pure {
    vm.assume(lowerPrice > 0);
    vm.assume(upperPrice > lowerPrice);
    vm.assume(upperPrice <= type(uint104).max);

    uint256 resultDown =
      SwapMath.calculatePriceAtBinPosition(lowerPrice, upperPrice, type(uint104).max, Math.Rounding.Floor);
    uint256 resultUp =
      SwapMath.calculatePriceAtBinPosition(lowerPrice, upperPrice, type(uint104).max, Math.Rounding.Ceil);

    assertEq(resultDown, upperPrice, "Position max should return upperPrice (floor)");
    assertEq(resultUp, upperPrice, "Position max should return upperPrice (ceil)");
  }

  /**
   * @notice Test that position max/n gives approximately (lowerPrice + upperPrice)/n
   */
  function testFuzz_PositionDividedByN_InterpolatesCorrectly(uint128 lowerPrice, uint128 upperPrice, uint104 n)
    public
    pure
  {
    vm.assume(lowerPrice > 0);
    vm.assume(upperPrice > lowerPrice);
    vm.assume(upperPrice <= type(uint104).max);
    vm.assume(n >= 1 && n <= type(uint104).max / 2);

    uint104 position = type(uint104).max / n;

    uint256 resultDown = SwapMath.calculatePriceAtBinPosition(lowerPrice, upperPrice, position, Math.Rounding.Floor);
    uint256 resultUp = SwapMath.calculatePriceAtBinPosition(lowerPrice, upperPrice, position, Math.Rounding.Ceil);

    // Expected value: lowerPrice + (upperPrice - lowerPrice) / n
    uint256 expected = lowerPrice + (upperPrice - lowerPrice) / n;

    // Results should be close to expected (within rounding)
    // expected = 1 <= resultDown <= resultUp <= expected + 1
    assertGe(resultDown + 1, expected, "Floor result should be >= expected - 1");
    assertLe(resultUp, expected + 1, "Ceil result should be <= expected + 1");
    assertLe(resultDown, resultUp, "Floor should be <= Ceil");
  }

  /**
   * @notice Test that floor rounding is equal or smaller by 1 than ceil rounding
   */
  function testFuzz_RoundingDifference_MaxOneUnit(uint128 lowerPrice, uint128 upperPrice, uint104 position)
    public
    pure
  {
    vm.assume(lowerPrice > 0);
    vm.assume(upperPrice > lowerPrice);
    vm.assume(upperPrice <= type(uint104).max);

    uint256 resultDown = SwapMath.calculatePriceAtBinPosition(lowerPrice, upperPrice, position, Math.Rounding.Floor);
    uint256 resultUp = SwapMath.calculatePriceAtBinPosition(lowerPrice, upperPrice, position, Math.Rounding.Ceil);

    // Ceil should be equal or greater by at most 1
    assertGe(resultUp, resultDown, "Ceil should be >= floor");
    assertLe(resultUp - resultDown, 1, "Ceil - floor should be at most 1");
  }
}
