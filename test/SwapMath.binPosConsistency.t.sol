// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;
// forge-lint: disable-start(unsafe-typecast)

import {Test} from "forge-std/Test.sol";
import {SwapMath} from "../contracts/libraries/SwapMath.sol";
import {FeeMath} from "../contracts/libraries/FeeMath.sol";
import {BinState} from "../contracts/types/PoolStorage.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

uint256 constant Q64 = 2 ** 64;

/// @dev Exact-in Path D must not drive bin position to an extreme while leaving
///      the opposite token balance non-zero (pos/balance consistency).
contract SwapMathBinPosConsistencyTest is Test {
  function test_buyToken1ExactIn_dustSwapsDoNotLeaveToken1AtPos0() public pure {
    uint256 lowerPriceX64 = Q64;
    uint256 upperPriceX64 = Q64 + Q64 / 100;
    uint256 feeX64 = Math.mulDiv(1000, Q64, 1e6);

    BinState memory binState =
      BinState({token0BalanceScaled: 500, token1BalanceScaled: 500, lengthE6: 1e4, addFeeBuyE6: 0, addFeeSellE6: 0});
    uint256 currBinPos = type(uint104).max / 2;
    uint256 startBinPos = currBinPos;
    uint256 token1Start = binState.token1BalanceScaled;

    for (uint256 i = 0; i < 50_000; i++) {
      if (currBinPos == 0) break;

      SwapMath.SwapState memory state =
        SwapMath.SwapState({amountSpecifiedRemainingScaled: 1, amountCalculatedScaled: 0});

      uint256 finalPos;
      (finalPos,,,,,) = SwapMath.buyToken1InBinSpecifiedIn(
        binState,
        currBinPos,
        state,
        0,
        0,
        FeeMath.effectivePriceX64(lowerPriceX64, feeX64, true),
        FeeMath.effectivePriceX64(upperPriceX64, feeX64, true),
        0
      );
      if (finalPos == currBinPos) break;
      currBinPos = finalPos;
    }

    // With fee-inclusive prices a 1-wei input trades at the marginal price instead of being rejected
    // by a 1-wei fee rounded up on top, so the balance legitimately drains. The property that matters
    // is pos/balance CONSISTENCY: the position may only reach the extreme once the balance is gone,
    // and in between it must track the balance proportionally.
    if (currBinPos == 0) {
      assertEq(binState.token1BalanceScaled, 0, "token1 must be 0 at pos 0");
    } else {
      assertGt(binState.token1BalanceScaled, 0, "position above 0 must retain token1");
      assertApproxEqRel(
        currBinPos,
        (startBinPos * binState.token1BalanceScaled) / token1Start,
        0.01e18,
        "position must track the remaining token1 balance"
      );
    }
  }

  function test_buyToken1ExactIn_pathDOutputDoesNotExceedPositionFormula() public pure {
    uint256 lowerPriceX64 = Q64;
    uint256 upperPriceX64 = Q64 + Q64 / 100;
    uint256 feeX64 = Math.mulDiv(3000, Q64, 1e6);

    uint256 token1Start = 10_000e18;
    BinState memory binState = BinState({
      token0BalanceScaled: 0, token1BalanceScaled: uint104(token1Start), lengthE6: 1, addFeeBuyE6: 0, addFeeSellE6: 0
    });
    uint256 currBinPos = type(uint104).max;

    SwapMath.SwapState memory state =
      SwapMath.SwapState({amountSpecifiedRemainingScaled: 1e18, amountCalculatedScaled: 0});

    uint256 finalPos;
    uint256 out1;
    (finalPos, out1,,,,) = SwapMath.buyToken1InBinSpecifiedIn(
      binState,
      currBinPos,
      state,
      0,
      0,
      FeeMath.effectivePriceX64(lowerPriceX64, feeX64, true),
      FeeMath.effectivePriceX64(upperPriceX64, feeX64, true),
      0
    );

    uint256 maxOutForPos = SwapMath.calculateOutputToken1FromBinPosition(token1Start, currBinPos, finalPos);
    // Position is Ceil-derived from output, so formula(pos) may be <= committed out.
    // Critical invariant: never pay out less than position advance implies in a way that
    // leaves leftover token1 at pos 0; equivalently, do not advance past what out supports.
    // With Ceil derivation, maxOutForPos <= out1 (position under-advances vs tokens sold).
    assertLe(maxOutForPos, out1, "position must not imply more token1 than sold");
    assertEq(binState.token1BalanceScaled, uint104(token1Start - out1));
  }
}
