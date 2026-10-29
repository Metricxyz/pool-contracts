// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {SwapMath, ONE_X64} from "../contracts/libraries/SwapMath.sol";

/**
 * @title SwapMathHelpersTest
 * @notice Pinned endpoint-mean costs for the two token conversion helpers.
 * @dev Every expectation is the exact rounded-up mean of the two rounded-up endpoint
 *      costs, computed by hand. A change in either helper's rounding breaks these.
 */
contract SwapMathHelpersTest is Test {
  uint256 constant HIGH_PRICE_X64 = 10 ** 19 * ONE_X64;
  uint256 constant HIGH_PRICE_UPPER_X64 = HIGH_PRICE_X64 * 101 / 100;

  function test_calculateRequiredToken0_matchesPinnedEndpointCosts() public pure {
    assertEq(SwapMath.calculateRequiredToken0(1e18, ONE_X64, ONE_X64), 1e18);
    assertEq(SwapMath.calculateRequiredToken0(1e18, 2 * ONE_X64, 2 * ONE_X64), 0.5e18);

    // Endpoint costs 1e18 and 0.5e18.
    assertEq(SwapMath.calculateRequiredToken0(1e18, ONE_X64, 2 * ONE_X64), 0.75e18);

    // A sub-unit cost still charges one whole unit.
    assertEq(SwapMath.calculateRequiredToken0(1, 3 * ONE_X64, 3 * ONE_X64), 1);

    // Endpoint costs 100,000 and 99,010. Rounding the inverse prices first charged 108,421.
    assertEq(SwapMath.calculateRequiredToken0(1e24, HIGH_PRICE_X64, HIGH_PRICE_UPPER_X64), 99_505);

    assertEq(SwapMath.calculateRequiredToken0(type(uint104).max, 1, 1), uint256(type(uint104).max) * ONE_X64);
  }

  function test_calculateRequiredToken1_matchesPinnedEndpointCosts() public pure {
    assertEq(SwapMath.calculateRequiredToken1(1e18, ONE_X64, ONE_X64), 1e18);
    assertEq(SwapMath.calculateRequiredToken1(1e18, 2 * ONE_X64, 2 * ONE_X64), 2e18);

    // Endpoint costs 1e18 and 2e18.
    assertEq(SwapMath.calculateRequiredToken1(1e18, ONE_X64, 2 * ONE_X64), 1.5e18);

    // A sub-unit cost still charges one whole unit.
    assertEq(SwapMath.calculateRequiredToken1(3, 1, 1), 1);

    // Endpoint costs 108,421 and 162,631. Averaging the prices first charged 162,631.
    assertEq(SwapMath.calculateRequiredToken1(1e24, 2, 3), 135_526);

    assertEq(
      SwapMath.calculateRequiredToken1(type(uint104).max, ONE_X64, ONE_X64), 20_282_409_603_651_670_423_947_251_286_015
    );
  }
}
