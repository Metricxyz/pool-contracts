// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {SwapMath} from "../contracts/libraries/SwapMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title SwapMathCalculateBinPositionAtPriceTest
 * @notice Focused tests for SwapMath.calculateBinPositionAtPrice function
 */
contract SwapMathCalculateBinPositionAtPriceTest is Test {
  /**
   * @notice Test that price = lowerPrice returns position 0 for both roundings
   */
  function testFuzz_PriceAtLower_ReturnsZero(uint128 lowerPriceX64, uint128 upperPriceX64) public pure {
    vm.assume(lowerPriceX64 > 0);
    vm.assume(upperPriceX64 > lowerPriceX64);

    uint256 resultDown =
      SwapMath.calculateBinPositionAtPrice(lowerPriceX64, upperPriceX64, lowerPriceX64, Math.Rounding.Floor);
    uint256 resultUp =
      SwapMath.calculateBinPositionAtPrice(lowerPriceX64, upperPriceX64, lowerPriceX64, Math.Rounding.Ceil);

    assertEq(resultDown, 0, "Price at lower bound should return 0 (floor)");
    assertEq(resultUp, 0, "Price at lower bound should return 0 (ceil)");
  }

  /**
   * @notice Test that price = upperPrice returns position max for both roundings
   */
  function testFuzz_PriceAtUpper_ReturnsMax(uint128 lowerPriceX64, uint128 upperPriceX64) public pure {
    vm.assume(lowerPriceX64 > 0);
    vm.assume(upperPriceX64 > lowerPriceX64);

    uint256 resultDown =
      SwapMath.calculateBinPositionAtPrice(lowerPriceX64, upperPriceX64, upperPriceX64, Math.Rounding.Floor);
    uint256 resultUp =
      SwapMath.calculateBinPositionAtPrice(lowerPriceX64, upperPriceX64, upperPriceX64, Math.Rounding.Ceil);

    assertEq(resultDown, type(uint104).max, "Price at upper bound should return max (floor)");
    assertEq(resultUp, type(uint104).max, "Price at upper bound should return max (ceil)");
  }

  /**
   * @notice Test that for a price calculated from a position, the inverse returns close to original
   * @dev If price = lowerPrice * (max - x) + upperPrice * x, then position should return x ± 1
   */
  function testFuzz_InverseRelationship_ReturnsCloseToOriginal(uint128 lowerPriceX64, uint128 upperPriceX64, uint104 x)
    public
    pure
  {
    vm.assume(lowerPriceX64 > 1 << 32);
    vm.assume(lowerPriceX64 < 1 << 97);
    vm.assume(upperPriceX64 > lowerPriceX64 + type(uint104).max);

    uint256 priceAtX = Math.ceilDiv(
      (uint256(lowerPriceX64) * (uint256(type(uint104).max) - uint256(x))) + (uint256(upperPriceX64) * uint256(x)),
      uint256(type(uint104).max)
    );

    // Calculate position from that price
    uint256 resultDown =
      SwapMath.calculateBinPositionAtPrice(lowerPriceX64, upperPriceX64, priceAtX, Math.Rounding.Floor);
    uint256 resultUp = SwapMath.calculateBinPositionAtPrice(lowerPriceX64, upperPriceX64, priceAtX, Math.Rounding.Ceil);

    // Floor rounding should return x or x-1 (can be slightly off due to rounding)
    assertGe(resultDown, x > 0 ? x - 1 : 0, "Floor should return x or x-1");
    assertLe(resultDown, x, "Floor should return x or x-1");

    // Ceil rounding should return x or x+1
    assertGe(resultUp, x, "Ceil should return x or x+1");
    assertLe(resultUp, x < type(uint104).max ? x + 1 : type(uint104).max, "Ceil should return x or x+1");
  }
}
