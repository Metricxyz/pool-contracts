// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {SwapMath, MAX_POS_BIN, ONE_X64} from "../contracts/libraries/SwapMath.sol";
import {BinState} from "../contracts/types/PoolStorage.sol";

contract SwapMathReciprocalPrecisionTest is Test {
  uint256 constant LOWER = 10 ** 19 * ONE_X64;
  uint256 constant UPPER = LOWER * 101 / 100;

  function test_highPriceExactOut_usesPreciseEndpointCosts() public pure {
    BinState memory bin = BinState(0, 1e24, 10000, 0, 0);
    SwapMath.SwapState memory state = SwapMath.SwapState(1e24, 0);
    (uint256 pos, int256 delta0, int256 delta1,,) =
      SwapMath.buyToken1InBinSpecifiedOut(bin, MAX_POS_BIN, state, 0, 0, LOWER, UPPER, 0);

    // ceil(1e24 * (1/1e19 + 1/1.01e19) / 2) = 99,505.
    // Rounding reciprocal prices before multiplying charged 108,421 instead.
    assertEq(state.amountCalculatedScaled, 99505);
    assertEq(state.amountSpecifiedRemainingScaled, 0);
    assertEq(pos, 0);
    assertEq(delta0, 99505);
    assertEq(delta1, -int256(1e24));
    assertEq(bin.token0BalanceScaled, 99505);
    assertEq(bin.token1BalanceScaled, 0);
  }

  function test_highPriceExactIn_exhaustsBinAtPreciseCost() public pure {
    BinState memory bin = BinState(0, 1e24, 10000, 0, 0);
    SwapMath.SwapState memory state = SwapMath.SwapState(99506, 0);
    (uint256 pos, uint256 output,,,,) =
      SwapMath.buyToken1InBinSpecifiedIn(bin, MAX_POS_BIN, state, 0, 0, LOWER, UPPER, 0);
    assertEq(output, 1e24);
    assertEq(pos, 0);
    assertEq(state.amountSpecifiedRemainingScaled, 1);
    assertEq(bin.token0BalanceScaled, 99505);
    assertEq(bin.token1BalanceScaled, 0);
  }

  function testFuzz_endpointCost_isConservativeWithinOneUnit(uint104 output, uint128 start, uint128 end) public pure {
    if (start == 0) start = 1;
    if (end == 0) end = 1;
    uint256 numerator = uint256(output) * ONE_X64;
    uint256 wholeSum = numerator / start + numerator / end;
    uint256 startRemainder = numerator % start;
    uint256 endRemainder = numerator % end;

    // Independent rational reference: add the integer parts, then compare the
    // sum of the fractional parts to zero or one, without rounding endpoints.
    uint256 exact = wholeSum / 2;
    if (wholeSum % 2 == 0) {
      if (startRemainder != 0 || endRemainder != 0) exact++;
    } else {
      exact++;
      // Products fit: both denominator and remainder are at most uint128.max.
      if (startRemainder * end > (uint256(end) - endRemainder) * start) exact++;
    }
    uint256 actual = SwapMath.calculateRequiredToken0(output, start, end);
    assertGe(actual, exact);
    assertLe(actual, exact + 1);
  }

  function test_endpointCost_maxOutputAtMinimumPrice() public pure {
    assertEq(SwapMath.calculateRequiredToken0(type(uint104).max, 1, 1), uint256(type(uint104).max) * ONE_X64);
  }

  function test_lowPriceExactOut_usesPreciseEndpointCosts() public pure {
    BinState memory bin = BinState(1e24, 0, 10000, 0, 0);
    SwapMath.SwapState memory state = SwapMath.SwapState(1e24, 0);
    (uint256 pos, int256 delta0, int256 delta1,,) =
      SwapMath.buyToken0InBinSpecifiedOut(bin, 0, state, 0, 0, 2, 3, type(uint128).max);

    // ceil-then-average of the endpoint costs 108,421 and 162,631 gives 135,526.
    // Averaging the Q64.64 prices first collapsed (2,3) to 3 and charged 162,631.
    assertEq(state.amountCalculatedScaled, 135526);
    assertEq(state.amountSpecifiedRemainingScaled, 0);
    assertEq(pos, MAX_POS_BIN);
    assertEq(delta0, -int256(1e24));
    assertEq(delta1, 135526);
    assertEq(bin.token0BalanceScaled, 0);
    assertEq(bin.token1BalanceScaled, 135526);
  }

  function testFuzz_token1EndpointCost_isConservativeWithinOneUnit(uint104 output, uint128 start, uint128 end)
    public
    pure
  {
    uint256 wholeSum = (uint256(output) * start) / ONE_X64 + (uint256(output) * end) / ONE_X64;
    uint256 startRemainder = (uint256(output) * start) % ONE_X64;
    uint256 endRemainder = (uint256(output) * end) % ONE_X64;

    // Independent rational reference: sum the integer parts, then resolve the
    // fractional halves without rounding either endpoint price first.
    uint256 exact = wholeSum / 2;
    if (wholeSum % 2 == 0) {
      if (startRemainder != 0 || endRemainder != 0) exact++;
    } else {
      exact++;
      if (startRemainder + endRemainder > ONE_X64) exact++;
    }
    uint256 actual = SwapMath.calculateRequiredToken1(output, start, end);
    assertGe(actual, exact);
    assertLe(actual, exact + 1);
  }
}
