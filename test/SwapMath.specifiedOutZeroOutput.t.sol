// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {SwapMath, MAX_POS_BIN} from "../contracts/libraries/SwapMath.sol";
import {BinState} from "../contracts/types/PoolStorage.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Regression tests: exact-output bin steps must not move the cursor when rounded output is zero.
contract SwapMathSpecifiedOutZeroOutputTest is Test {
  uint256 constant LOWER_PRICE_X64 = 1 << 64;
  uint256 constant UPPER_PRICE_X64 = 2 << 64;

  function test_buyToken0InBinSpecifiedOut_zeroRoundedOutput_keepsCursorAndState() public pure {
    uint256 currBinPos = MAX_POS_BIN / 2;
    uint256 cappedPos = currBinPos + 1;

    BinState memory binState =
      BinState({token0BalanceScaled: 1, token1BalanceScaled: 1_000_000, lengthE6: 1, addFeeBuyE6: 0, addFeeSellE6: 0});

    SwapMath.SwapState memory state = SwapMath.SwapState({
      amountSpecifiedRemainingScaled: 1,
      amountCalculatedScaled: 0,
      protocolFeeAmountScaled: 0,
      feeExclusiveInputScaled: 0
    });

    uint256 priceLimitX64 =
      SwapMath.calculatePriceAtBinPosition(LOWER_PRICE_X64, UPPER_PRICE_X64, cappedPos, Math.Rounding.Floor);

    assertEq(
      SwapMath.calculateOutputToken0FromBinPosition(binState.token0BalanceScaled, currBinPos, cappedPos),
      0,
      "precondition: one-step move rounds token0 output to zero"
    );

    (uint256 finalBinPos, int256 delta0, int256 delta1, uint256 binLpFee) = SwapMath.buyToken0InBinSpecifiedOut(
      binState, currBinPos, state, 0, LOWER_PRICE_X64, UPPER_PRICE_X64, priceLimitX64, 0
    );

    assertEq(finalBinPos, currBinPos, "cursor must not move when output rounds to zero");
    assertEq(delta0, 0);
    assertEq(delta1, 0);
    assertEq(binLpFee, 0);
    assertEq(binState.token0BalanceScaled, 1);
    assertEq(binState.token1BalanceScaled, 1_000_000);
    assertEq(state.amountSpecifiedRemainingScaled, 1);
    assertEq(state.amountCalculatedScaled, 0);
  }

  function test_buyToken1InBinSpecifiedOut_zeroRoundedOutput_keepsCursorAndState() public pure {
    uint256 currBinPos = MAX_POS_BIN / 2;
    uint256 cappedPos = currBinPos - 1;

    BinState memory binState =
      BinState({token0BalanceScaled: 1_000_000, token1BalanceScaled: 2, lengthE6: 1, addFeeBuyE6: 0, addFeeSellE6: 0});

    SwapMath.SwapState memory state = SwapMath.SwapState({
      amountSpecifiedRemainingScaled: 1,
      amountCalculatedScaled: 0,
      protocolFeeAmountScaled: 0,
      feeExclusiveInputScaled: 0
    });

    uint256 priceLimitX64 =
      SwapMath.calculatePriceAtBinPosition(LOWER_PRICE_X64, UPPER_PRICE_X64, cappedPos, Math.Rounding.Floor);

    assertEq(
      SwapMath.calculateOutputToken1FromBinPosition(binState.token1BalanceScaled, currBinPos, cappedPos),
      0,
      "precondition: one-step move rounds token1 output to zero"
    );

    (uint256 finalBinPos, int256 delta0, int256 delta1, uint256 binLpFee) = SwapMath.buyToken1InBinSpecifiedOut(
      binState, currBinPos, state, 0, LOWER_PRICE_X64, UPPER_PRICE_X64, priceLimitX64, 0
    );

    assertEq(finalBinPos, currBinPos, "cursor must not move when output rounds to zero");
    assertEq(delta0, 0);
    assertEq(delta1, 0);
    assertEq(binLpFee, 0);
    assertEq(binState.token1BalanceScaled, 2);
    assertEq(binState.token0BalanceScaled, 1_000_000);
    assertEq(state.amountSpecifiedRemainingScaled, 1);
    assertEq(state.amountCalculatedScaled, 0);
  }
}
