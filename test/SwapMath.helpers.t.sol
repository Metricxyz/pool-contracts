// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {SwapMath} from "../contracts/libraries/SwapMath.sol";

/**
 * @title SwapMathHelpersTest
 * @notice Tests for SwapMath helper functions
 */
contract SwapMathHelpersTest is Test {
  /**
   * @notice Test calculateRequiredToken1 is inverse of standard amount calculation
   * @dev Now uses simplified 2-param function since internal decimals are equal
   */
  function testFuzz_calculateRequiredToken1_inverse(uint128 outToken0, uint128 avgPriceX64) public pure {
    vm.assume(outToken0 > 1000);
    vm.assume(avgPriceX64 > 1e10);
    vm.assume(uint256(outToken0) * avgPriceX64 < type(uint256).max / 1e18);

    // Simplified function: internally both tokens have same decimals, so multipliers cancel
    uint256 inToken1 = SwapMath.calculateRequiredToken(outToken0, avgPriceX64);

    // Check if (inToken1 * price) gives approx outToken0
    // inToken1 = ceil(outToken0 * price / 2^64)
    // outToken0Calc = inToken1 * 2^64 / price
    uint256 outToken0Calc = (inToken1 * (1 << 64)) / avgPriceX64;

    // Check that the calculated output is greater or equal (since we rounded up input)
    assertGe(outToken0Calc, outToken0, "Calculated output should be >= original");

    // Check that the difference is less than what 1 unit of input would produce
    // 1 unit of input * 2^64 / price
    uint256 oneUnitOutput = (1 * (1 << 64)) / avgPriceX64;

    // Allow difference up to one unit output + rounding error (small buffer)
    assertLe(outToken0Calc - outToken0, oneUnitOutput + 100, "Difference should be within 1 unit of input precision");
  }

  // Note: calculateLocalFeeE6 test removed - we now use constant fee per bin
}
