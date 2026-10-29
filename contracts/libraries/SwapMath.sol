// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IMetricOmmPoolActions} from "../interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {BinState} from "../types/PoolStorage.sol";

uint256 constant ONE_X64 = 0x10000000000000000;
uint256 constant ONE_X128 = 0x100000000000000000000000000000000;
/// @dev Maximum discrete bin position (`type(uint104).max`); use as uint256 for arithmetic.
uint256 constant MAX_POS_BIN = type(uint104).max;

/**
 * @title SwapMath
 * @notice Library for pure swap calculation functions
 * @dev All functions are pure and do not access storage, making them easily testable.
 *      Incoming-leg bin balance writes revert with `OverflowedOnFittingBinBalances` when they would exceed
 *      `type(uint104).max` (instead of a generic SafeCast panic).
 *      Callers must advance `SwapState` fields conservatively: keep per-iteration deltas within the bounds
 *      documented on each field so widened sums stay representable where the pool persists them.
 */
library SwapMath {
  using SafeCast for uint256;
  using SafeCast for int256;

  /// @dev Cast an incoming-side bin balance to `uint104`, or revert with a defined pool error.
  function _toUint104IncomingBinBalance(uint256 value) private pure returns (uint104) {
    if (value > type(uint104).max) {
      revert IMetricOmmPoolActions.OverflowedOnFittingBinBalances(value);
    }
    // forge-lint: disable-next-line(unsafe-typecast) -- guarded by the check above.
    return uint104(value);
  }

  // ============ Type Definitions ============

  /// @notice State tracked during a swap operation
  /// @param amountSpecifiedRemainingScaled Remaining amount to swap (scaled to internal decimals). Assumes <= type(uint128).max.
  /// @param amountCalculatedScaled Accumulated output/input amount (scaled to internal decimals). Assumes <= type(uint128).max.
  /// @dev Orchestrators should treat all four as running totals whose growth per bin step is bounded by the
  ///      bin liquidity and swap amount; the pool assumes intermediate values fit the same width as scaled balances.
  struct SwapState {
    uint256 amountSpecifiedRemainingScaled;
    uint256 amountCalculatedScaled;
  }

  // ============ Price and Position Helpers ============

  /// @notice Invert a price in Q64.64 format.
  function invertPriceX64(uint256 priceX64) internal pure returns (uint256) {
    return Math.ceilDiv(ONE_X128, priceX64);
  }

  /// @notice Arithmetic mean of two values, rounded up.
  function calculateArithmeticMean(uint256 a, uint256 b) internal pure returns (uint256) {
    unchecked {
      return (a + b + 1) / 2;
    }
  }

  /// @notice Base fee in Q64.64 when buying token0 (1-for-0 swap): ask vs reference spread.
  function buyBaseFeeX64FromAskAndReference(uint256 askPriceX64, uint256 referencePriceX64)
    internal
    pure
    returns (uint256 baseFeeX64)
  {
    baseFeeX64 = Math.mulDiv(askPriceX64, ONE_X64, referencePriceX64, Math.Rounding.Ceil) - ONE_X64;
  }

  /// @notice Base fee in Q64.64 when selling token0 (0-for-1 swap): reference vs bid spread.
  /// @dev `reference/bid - 1` (not `1 - bid/reference`): downstream bin math multiplies the token0 *input* amount by
  ///      `1 + baseFeeX64`, and that input is proportional to `1/price`, so this ratio is what makes the realized
  ///      execution price land exactly on `bid` (mirrors how `ask/reference - 1` lands exactly on `ask` for buys,
  ///      where the token1 input is proportional to `price` instead).
  function sellBaseFeeX64FromBidAndReference(uint256 bidPriceX64, uint256 referencePriceX64)
    internal
    pure
    returns (uint256 baseFeeX64)
  {
    baseFeeX64 = Math.mulDiv(referencePriceX64, ONE_X64, bidPriceX64, Math.Rounding.Ceil) - ONE_X64;
  }

  /**
   * @notice Both base fee legs in Q64.64 from bid/ask + reference.
   * @dev Fee-only helper for `getSellAndBuyPrices`; the reference price itself is used as the mid/anchor price.
   */
  function buySellBaseFeesX64FromBidAskAndReference(uint256 bidPriceX64, uint256 askPriceX64, uint256 referencePriceX64)
    internal
    pure
    returns (uint256 baseBuyFeeX64, uint256 baseSellFeeX64)
  {
    baseBuyFeeX64 = buyBaseFeeX64FromAskAndReference(askPriceX64, referencePriceX64);
    baseSellFeeX64 = sellBaseFeeX64FromBidAndReference(bidPriceX64, referencePriceX64);
  }

  /**
   * @notice Calculate price at a specific position within a bin
   * @param lowerPriceX64 Price at the lower bound of the bin.
   * @param upperPriceX64 Price at the upper bound of the bin.
   * @param position Current position along the bin segment (uint256; must be ≤ `MAX_POS_BIN` or the subtraction reverts).
   * @param rounding Rounding mode for interpolation.
   * @return priceX64 Interpolated price at the given position.
   */
  function calculatePriceAtBinPosition(
    uint256 lowerPriceX64,
    uint256 upperPriceX64,
    uint256 position,
    Math.Rounding rounding
  ) internal pure returns (uint256 priceX64) {
    uint256 maxSubCurrPos = MAX_POS_BIN - position;
    unchecked {
      if (rounding == Math.Rounding.Floor) {
        priceX64 = (lowerPriceX64 * maxSubCurrPos + upperPriceX64 * position) / MAX_POS_BIN;
      } else {
        priceX64 = Math.ceilDiv(lowerPriceX64 * maxSubCurrPos + upperPriceX64 * position, MAX_POS_BIN);
      }
    }
  }

  /**
   * @notice Calculate finalBinPos position limited by price
   * @param lowerPriceX64 Price at lower bound (typically EFFECTIVE / fee-inclusive).
   * @param upperPriceX64 Price at upper bound (typically EFFECTIVE / fee-inclusive).
   * @param priceX64 Maximum acceptable price along the same encoding as the bounds.
   * @param rounding Rounding mode used for inverse interpolation.
   * @return result Bin position where price limit is reached. Result <= MAX_POS_BIN.
   */
  function calculateBinPositionAtPrice(
    uint256 lowerPriceX64,
    uint256 upperPriceX64,
    uint256 priceX64,
    Math.Rounding rounding
  ) internal pure returns (uint256) {
    unchecked {
      // Result ≤ MAX_POS_BIN since priceX64 ∈ [lower, upper].
      if (rounding == Math.Rounding.Floor) {
        return ((priceX64 - lowerPriceX64) * MAX_POS_BIN) / (upperPriceX64 - lowerPriceX64);
      } else {
        return Math.ceilDiv((priceX64 - lowerPriceX64) * MAX_POS_BIN, upperPriceX64 - lowerPriceX64);
      }
    }
  }

  /**
   * @notice Calculate finalBinPos position to achieve desired token0 output
   * @param currBinPos Current position in bin (uint104).
   * @param tradedAmount0 Desired token0 output amount. Assumes <= availableToken0.
   * @param availableToken0 Available token0 in bin. Assumes <= MAX_POS_BIN and > 0.
   * @return finalBinPos Position after consuming tradedAmount0. Result <= MAX_POS_BIN.
   */
  function calculateBinPositionAfterSellingAmount0(uint256 currBinPos, uint256 tradedAmount0, uint256 availableToken0)
    internal
    pure
    returns (uint256 finalBinPos)
  {
    unchecked {
      // Product ≤ 2^104 × 2^104 = 2^208 < 2^256. Quotient ≤ max − currBinPos,
      // so currBinPos + quotient ≤ MAX_POS_BIN.
      return currBinPos + (((MAX_POS_BIN - currBinPos) * tradedAmount0) / availableToken0);
    }
  }

  /**
   * @notice Calculate finalBinPos position to achieve desired token1 output
   * @param currBinPos Current position in bin (uint104).
   * @param tradedAmount1 Desired token1 output amount. Assumes <= availableToken1.
   * @param availableToken1 Available token1 in bin. Assumes <= MAX_POS_BIN and > 0.
   * @return finalBinPos Position after consuming tradedAmount1.
   */
  function calculateBinPositionAfterSellingAmount1(uint256 currBinPos, uint256 tradedAmount1, uint256 availableToken1)
    internal
    pure
    returns (uint256 finalBinPos)
  {
    unchecked {
      // Product ≤ 2^104 × 2^104 = 2^208 < 2^256. Quotient ≤ currBinPos ≤ MAX_POS_BIN.
      return Math.ceilDiv(currBinPos * (availableToken1 - tradedAmount1), availableToken1);
    }
  }

  /**
   * @notice Calculate output token1 amount from position movement
   * @param availableToken1 Available token1 in bin. Assumes <= MAX_POS_BIN.
   * @param currBinPos Start position (uint104). Assumes > 0.
   * @param finalBinPos End position (uint104). Assumes <= currBinPos.
   * @return outToken1 Amount of token1 to output (rounds down). Result <= MAX_POS_BIN.
   */
  function calculateOutputToken1FromBinPosition(uint256 availableToken1, uint256 currBinPos, uint256 finalBinPos)
    internal
    pure
    returns (uint256 outToken1)
  {
    unchecked {
      // Product ≤ 2^104 × 2^104 = 2^208. Quotient ≤ availableToken1 ≤ MAX_POS_BIN.
      outToken1 = (availableToken1 * uint256(currBinPos - finalBinPos)) / currBinPos;
    }
  }

  /**
   * @notice Calculate output token0 amount from position movement
   * @param availableToken0 Available token0 in bin. Assumes <= MAX_POS_BIN.
   * @param currBinPos Start position (uint104). Assumes < MAX_POS_BIN.
   * @param finalBinPos End position (uint104). Assumes >= currBinPos.
   * @return outToken0 Amount of token0 to output (rounds down). Result <= MAX_POS_BIN.
   */
  function calculateOutputToken0FromBinPosition(uint256 availableToken0, uint256 currBinPos, uint256 finalBinPos)
    internal
    pure
    returns (uint256 outToken0)
  {
    unchecked {
      // Product ≤ 2^104 × 2^104 = 2^208. Quotient ≤ availableToken0 ≤ MAX_POS_BIN.
      outToken0 = (availableToken0 * (finalBinPos - currBinPos)) / (MAX_POS_BIN - currBinPos);
    }
  }

  // ============ Token Conversion Helpers ============

  /**
   * @notice Calculates the required token1 input for a given amount of token0 output
   * @param token0Out Amount of token0 output. Assumes <= type(uint128).max.
   * @param startingPriceX64 Starting price of token1 in token0 (Q64.64).
   * @param finalPriceX64 Final price of token1 in token0 (Q64.64).
   * @return requiredToken1In Token1 input in internal decimals. Not bounded here; an oversized result reverts downstream in `_toUint104IncomingBinBalance`.
   */
  function calculateRequiredToken1(uint256 token0Out, uint256 startingPriceX64, uint256 finalPriceX64)
    internal
    pure
    returns (uint256 requiredToken1In)
  {
    uint256 startingCost = Math.mulDiv(token0Out, startingPriceX64, ONE_X64, Math.Rounding.Ceil);
    uint256 finalCost = Math.mulDiv(token0Out, finalPriceX64, ONE_X64, Math.Rounding.Ceil);
    requiredToken1In = calculateArithmeticMean(startingCost, finalCost);
  }

  /**
   * @notice Calculates the required token0 input for a given amount of token1 output
   * @param token1Out Amount of token1 output. Assumes <= type(uint128).max.
   * @param startingPriceX64 Starting price of token0 in token1 (Q64.64). Must be > 0.
   * @param finalPriceX64 Final price of token0 in token1 (Q64.64). Must be > 0.
   * @return requiredToken0In Token0 input in internal decimals. Not bounded here; an oversized result reverts downstream in `_toUint104IncomingBinBalance`.
   */
  function calculateRequiredToken0(uint256 token1Out, uint256 startingPriceX64, uint256 finalPriceX64)
    internal
    pure
    returns (uint256 requiredToken0In)
  {
    uint256 startingCost = Math.mulDiv(token1Out, ONE_X64, startingPriceX64, Math.Rounding.Ceil);
    uint256 finalCost = Math.mulDiv(token1Out, ONE_X64, finalPriceX64, Math.Rounding.Ceil);
    return calculateArithmeticMean(startingCost, finalCost);
  }

  // ============ Analytical Target Position Helpers ============

  /**
   * @notice Compute target bin position using analytical closed-form solution for selling specified amount of token1
   * @dev Solves the quadratic equation: A×d + B×d² = target
   *      d = 2 * target / (A + sqrt(A² + 4B×target)) = 2Q / (1 + sqrt(1 + 4rQ))
   *      where:
   *        r = B/A and Q = target / A
   *        A = T0 × Pc / [(M-c) × 2^64] × (2^64 + fee) / 2^64
   *        B = ΔP / (2M × Pc) × A
   * @param currBinPos Current position in bin. Assumes <= MAX_POS_BIN.
   * @param maxFinalBinPos Maximum achievable final position. Assumes currBinPos < maxFinalBinPos <= MAX_POS_BIN.
   * @param inputAmount Amount of token1 input to spend. Assumes <= type(uint128).max.
   * @param token0Balance Available token0 in bin. Assumes <= MAX_POS_BIN.
   * @param lowerPriceX64 Lower price bound of bin. Assumes <= 2*type(uint128).max.
   * @param upperPriceX64 Upper price bound of bin. Assumes lowerPriceX64 < upperPriceX64 <= 2*type(uint128).max.
   * @dev `lowerPriceX64`/`upperPriceX64` are EFFECTIVE (fee-inclusive) prices, so no fee term appears here.
   * @return targetPos Computed target position. Result satisfies currBinPos < targetPos <= maxFinalBinPos.
   */
  function computeAnalyticalTargetPosForBuyToken0(
    uint256 currBinPos,
    uint256 maxFinalBinPos,
    uint256 inputAmount,
    uint256 token0Balance,
    uint256 lowerPriceX64,
    uint256 upperPriceX64
  ) internal pure returns (uint256 targetPos) {
    uint256 maxSubCurrPos = MAX_POS_BIN - currBinPos;
    uint256 deltaPriceX64 = upperPriceX64 - lowerPriceX64;
    uint256 priceAtCurrPosX64 = lowerPriceX64 + (deltaPriceX64 * currBinPos) / MAX_POS_BIN;

    uint256 deltaPos = 0;
    if (token0Balance > 0 && priceAtCurrPosX64 > 0 && maxSubCurrPos > 0) {
      uint256 aX128 = Math.mulDiv(token0Balance, priceAtCurrPosX64 << 64, maxSubCurrPos);

      if (aX128 > 0) {
        uint256 qX128 = Math.mulDiv(inputAmount << 128, 1 << 128, aX128);

        // Apply quadratic correction
        // Exact solution: d = 2Q / (1 + sqrt(1 + 4rQ))
        // where r = B/A = ΔP / (2M × Pc)
        {
          // rQx128 = ΔP × qX128 / (2M × Pc) = rQ × 2^128
          uint256 rQx128 = Math.mulDiv(deltaPriceX64, qX128, 2 * MAX_POS_BIN * priceAtCurrPosX64);

          // Exact quadratic solution: d = 2Q / (1 + sqrt(1 + 4rQ))
          uint256 sqrtArgX128 = (1 << 128) + 4 * rQx128;
          uint256 sqrtValX64 = Math.sqrt(sqrtArgX128);
          deltaPos = (2 * qX128) / ((1 << 128) + (sqrtValX64 << 64));
        }
      }
    }

    // Minimum forward progress when the closed form rounds to zero but input is non-zero.
    if (deltaPos == 0 && inputAmount > 0) deltaPos = 1;

    if (deltaPos > maxSubCurrPos) deltaPos = maxSubCurrPos;
    targetPos = (currBinPos + deltaPos > maxFinalBinPos) ? maxFinalBinPos : currBinPos + deltaPos;
    // Ensure we move at least one step toward `maxFinalBinPos` when the grid still allows it.
    if (targetPos <= currBinPos) targetPos = currBinPos + (currBinPos < maxFinalBinPos ? 1 : 0);
  }

  /**
   * @notice Compute target bin position using analytical closed-form solution for selling specified amount of token0
   * @dev Use the same analytical closed-form solution as for buying token0, but invert the price and mirror bin positions.
   * @param currBinPos Current position in bin. Assumes <= MAX_POS_BIN.
   * @param minFinalBinPos Minimum achievable final position. Assumes minFinalBinPos < currBinPos.
   * @param inputAmount Amount of token0 input to spend. Assumes <= type(uint128).max.
   * @param token1Balance Available token1 in bin. Assumes <= MAX_POS_BIN.
   * @param lowerPriceX64 Lower price bound of bin. Assumes <= 2*type(uint128).max.
   * @param upperPriceX64 Upper price bound of bin. Assumes lowerPriceX64 < upperPriceX64 <= 2*type(uint128).max.
   * @dev `lowerPriceX64`/`upperPriceX64` are EFFECTIVE (fee-inclusive) prices, so no fee term appears here.
   * @return targetPos Computed target position. Result satisfies minFinalBinPos <= targetPos < currBinPos.
   */
  function computeAnalyticalTargetPosForSellToken0(
    uint256 currBinPos,
    uint256 minFinalBinPos,
    uint256 inputAmount,
    uint256 token1Balance,
    uint256 lowerPriceX64,
    uint256 upperPriceX64
  ) internal pure returns (uint256 targetPos) {
    uint256 mirroredTargetPos = computeAnalyticalTargetPosForBuyToken0(
      MAX_POS_BIN - currBinPos,
      MAX_POS_BIN - minFinalBinPos,
      inputAmount,
      token1Balance,
      invertPriceX64(upperPriceX64),
      invertPriceX64(lowerPriceX64)
    );
    return MAX_POS_BIN - mirroredTargetPos;
  }

  // ============ Swap In Bin Functions - Exact Output ============

  /**
   * @notice Calculate swap amounts for a single bin iteration (token1 → token0, exact output)
   * @dev `lowerPriceX64`/`upperPriceX64` are EFFECTIVE prices, so `priceLimitX64` is compared against them
   *      directly and therefore bounds the price the trader actually realizes.
   * @param binState Current bin state
   * @param currBinPos Current position in bin (uint104).
   * @param state Current swap state
   * @param lowerEffPriceX64 Effective lower bound price of bin (Q64.64). Assumes <= type(uint128).max.
   * @param upperEffPriceX64 Effective upper bound price of bin. Assumes lowerPriceX64 < upperPriceX64 <= type(uint128).max.
   * @param priceLimitX64 Price limit for the swap. Assumes <= type(uint128).max.
   * @return finalBinPos End position in bin.
   * @return binDelta0Scaled Change in the BIN's scaled token0 balance (negative = token0 left the bin).
   * @return binDelta1Scaled Change in the BIN's scaled token1 balance (positive = token1 entered the bin, net of the platform take).
   * @return platformFeeScaled Combined platform take withheld from the input (never enters the bin).
   * @return lpFeeScaled LP leg of the carved fee for this step; stays in the bin.
   */
  function buyToken0InBinSpecifiedOut(
    BinState memory binState,
    uint256 currBinPos,
    SwapState memory state,
    uint256 totalFeeOfGrossX64,
    uint256 platformShareOfFeeX64,
    uint256 lowerEffPriceX64,
    uint256 upperEffPriceX64,
    uint256 priceLimitX64
  )
    internal
    pure
    returns (
      uint256 finalBinPos,
      int256 binDelta0Scaled,
      int256 binDelta1Scaled,
      uint256 platformFeeScaled,
      uint256 lpFeeScaled
    )
  {
    unchecked {
      uint256 amountOutScaled = 0;

      if (state.amountSpecifiedRemainingScaled < binState.token0BalanceScaled) {
        finalBinPos = calculateBinPositionAfterSellingAmount0(
          currBinPos, state.amountSpecifiedRemainingScaled, binState.token0BalanceScaled
        );
        amountOutScaled = state.amountSpecifiedRemainingScaled;
      } else {
        finalBinPos = MAX_POS_BIN;
        amountOutScaled = binState.token0BalanceScaled;
      }

      if (priceLimitX64 < upperEffPriceX64) {
        if (priceLimitX64 <= lowerEffPriceX64) return (currBinPos, 0, 0, 0, 0);

        uint256 finalBinPosAtPriceLimit =
          calculateBinPositionAtPrice(lowerEffPriceX64, upperEffPriceX64, priceLimitX64, Math.Rounding.Floor);
        if (finalBinPosAtPriceLimit <= currBinPos) return (currBinPos, 0, 0, 0, 0);

        if (finalBinPosAtPriceLimit < finalBinPos) {
          finalBinPos = finalBinPosAtPriceLimit;
          uint256 amountOutHelper =
            calculateOutputToken0FromBinPosition(binState.token0BalanceScaled, currBinPos, finalBinPos);
          amountOutScaled = amountOutHelper < amountOutScaled ? amountOutHelper : amountOutScaled;
        }
      }

      if (amountOutScaled == 0) {
        finalBinPos = currBinPos;
        return (finalBinPos, 0, 0, 0, 0);
      }

      uint256 startingPriceX64 =
        calculatePriceAtBinPosition(lowerEffPriceX64, upperEffPriceX64, currBinPos, Math.Rounding.Ceil);
      uint256 finalPriceX64 =
        calculatePriceAtBinPosition(lowerEffPriceX64, upperEffPriceX64, finalBinPos, Math.Rounding.Ceil);

      uint256 amountInScaled = calculateRequiredToken1(amountOutScaled, startingPriceX64, finalPriceX64);

      uint256 totalFeeScaled = (amountInScaled * totalFeeOfGrossX64) / ONE_X64;
      platformFeeScaled = totalFeeScaled * platformShareOfFeeX64 / ONE_X64;
      lpFeeScaled = totalFeeScaled - platformFeeScaled;
      uint256 binCreditScaled = amountInScaled - platformFeeScaled;

      binState.token0BalanceScaled -= amountOutScaled.toUint104();
      binState.token1BalanceScaled =
        _toUint104IncomingBinBalance(uint256(binState.token1BalanceScaled) + binCreditScaled);

      state.amountSpecifiedRemainingScaled -= amountOutScaled;
      state.amountCalculatedScaled += amountInScaled;

      binDelta0Scaled = -amountOutScaled.toInt256();
      binDelta1Scaled = binCreditScaled.toInt256();
    }
  }

  /**
   * @notice Calculate swap amounts for a single bin iteration (token0 → token1, exact output)
   * @dev `lowerPriceX64`/`upperPriceX64` are EFFECTIVE prices; see `buyToken0InBinSpecifiedOut`.
   * @param binState Current bin state
   * @param currBinPos Current position in bin (uint104).
   * @param state Current swap state
   * @param lowerEffPriceX64 Effective lower bound price of bin (Q64.64). Assumes <= type(uint128).max.
   * @param upperEffPriceX64 Effective upper bound price of bin. Assumes lowerEffPriceX64 < upperEffPriceX64 <= type(uint128).max.
   * @param priceLimitX64 Price limit for the swap. Assumes <= type(uint128).max.
   * @return finalBinPos End position in bin. Result <= MAX_POS_BIN.
   * @return binDelta0Scaled Change in the BIN's scaled token0 balance (positive = token0 entered the bin, net of the platform take).
   * @return binDelta1Scaled Change in the BIN's scaled token1 balance (negative = token1 left the bin).
   * @return platformFeeScaled Combined platform take withheld from the input (never enters the bin).
   * @return lpFeeScaled LP leg of the carved fee for this step; stays in the bin.
   */
  function buyToken1InBinSpecifiedOut(
    BinState memory binState,
    uint256 currBinPos,
    SwapState memory state,
    uint256 totalFeeOfGrossX64,
    uint256 platformShareOfFeeX64,
    uint256 lowerEffPriceX64,
    uint256 upperEffPriceX64,
    uint256 priceLimitX64
  )
    internal
    pure
    returns (
      uint256 finalBinPos,
      int256 binDelta0Scaled,
      int256 binDelta1Scaled,
      uint256 platformFeeScaled,
      uint256 lpFeeScaled
    )
  {
    unchecked {
      uint256 amountOutScaled = 0;

      if (state.amountSpecifiedRemainingScaled < binState.token1BalanceScaled) {
        finalBinPos = calculateBinPositionAfterSellingAmount1(
          currBinPos, state.amountSpecifiedRemainingScaled, binState.token1BalanceScaled
        );
        amountOutScaled = state.amountSpecifiedRemainingScaled;
      } else {
        finalBinPos = 0;
        amountOutScaled = binState.token1BalanceScaled;
      }

      if (lowerEffPriceX64 < priceLimitX64) {
        if (priceLimitX64 >= upperEffPriceX64) return (currBinPos, 0, 0, 0, 0);

        uint256 finalBinPosAtPriceLimit =
          calculateBinPositionAtPrice(lowerEffPriceX64, upperEffPriceX64, priceLimitX64, Math.Rounding.Ceil);
        if (finalBinPosAtPriceLimit >= currBinPos) return (currBinPos, 0, 0, 0, 0);

        if (finalBinPos < finalBinPosAtPriceLimit) {
          finalBinPos = finalBinPosAtPriceLimit;
          uint256 amountOutHelper =
            calculateOutputToken1FromBinPosition(binState.token1BalanceScaled, currBinPos, finalBinPos);
          amountOutScaled = amountOutHelper < amountOutScaled ? amountOutHelper : amountOutScaled;
        }
      }

      if (amountOutScaled == 0) {
        finalBinPos = currBinPos;
        return (finalBinPos, 0, 0, 0, 0);
      }

      uint256 startingPriceX64 =
        calculatePriceAtBinPosition(lowerEffPriceX64, upperEffPriceX64, currBinPos, Math.Rounding.Floor);
      uint256 finalPriceX64 =
        calculatePriceAtBinPosition(lowerEffPriceX64, upperEffPriceX64, finalBinPos, Math.Rounding.Floor);
      uint256 amountInScaled = calculateRequiredToken0(amountOutScaled, startingPriceX64, finalPriceX64);

      uint256 totalFeeScaled = (amountInScaled * totalFeeOfGrossX64) / ONE_X64;
      platformFeeScaled = totalFeeScaled * platformShareOfFeeX64 / ONE_X64;
      lpFeeScaled = totalFeeScaled - platformFeeScaled;
      uint256 binCreditScaled = amountInScaled - platformFeeScaled;

      binState.token1BalanceScaled -= amountOutScaled.toUint104();
      binState.token0BalanceScaled =
        _toUint104IncomingBinBalance(uint256(binState.token0BalanceScaled) + binCreditScaled);

      state.amountSpecifiedRemainingScaled -= amountOutScaled;
      state.amountCalculatedScaled += amountInScaled;

      binDelta0Scaled = binCreditScaled.toInt256();
      binDelta1Scaled = -amountOutScaled.toInt256();
    }
  }

  // ============ Swap In Bin Functions - Exact Input ============

  /**
   * @notice Calculate swap amounts for a single bin iteration - exact input token1, output token0 (going up in price)
   * @dev Uses analytical quadratic solution with Math.sqrt and iterative refinement.
   * @param binState Current bin state
   * @param currBinPos Current position in bin (uint104).
   * @param state Current swap state
   * @param lowerEffPriceX64 Effective lower bound price of bin. Assumes <= type(uint128).max.
   * @param upperEffPriceX64 Effective upper bound price of bin. Assumes lowerEffPriceX64 < upperEffPriceX64 <= type(uint128).max.
   * @param priceLimitX64 Price limit for the swap. Assumes <= type(uint128).max.
   * @return finalBinPos End position in bin. Result <= MAX_POS_BIN.
   * @return out0Scaled Output token0 amount for this bin. Result <= MAX_POS_BIN.
   * @return binDelta0Scaled Change in the BIN's scaled token0 balance (negative = token0 left the bin).
   * @return binDelta1Scaled Change in the BIN's scaled token1 balance (positive = token1 entered the bin, net of the platform take).
   * @return platformFeeScaled Combined platform take withheld from the input (never enters the bin).
   * @return lpFeeScaled LP leg of the carved fee for this step; stays in the bin.
   */
  function buyToken0InBinSpecifiedIn(
    BinState memory binState,
    uint256 currBinPos,
    SwapState memory state,
    uint256 totalFeeOfGrossX64,
    uint256 platformShareOfFeeX64,
    uint256 lowerEffPriceX64,
    uint256 upperEffPriceX64,
    uint256 priceLimitX64
  )
    internal
    pure
    returns (
      uint256 finalBinPos,
      uint256 out0Scaled,
      int256 binDelta0Scaled,
      int256 binDelta1Scaled,
      uint256 platformFeeScaled,
      uint256 lpFeeScaled
    )
  {
    unchecked {
      uint256 startingPriceX64 =
        calculatePriceAtBinPosition(lowerEffPriceX64, upperEffPriceX64, currBinPos, Math.Rounding.Ceil);

      if ((state.amountSpecifiedRemainingScaled << 64) < startingPriceX64) {
        return (currBinPos, 0, 0, 0, 0, 0);
      }

      uint256 maxFinalBinPos;
      if (upperEffPriceX64 <= priceLimitX64) {
        maxFinalBinPos = MAX_POS_BIN;
      } else {
        if (priceLimitX64 <= lowerEffPriceX64) {
          return (currBinPos, 0, 0, 0, 0, 0);
        }
        maxFinalBinPos =
          calculateBinPositionAtPrice(lowerEffPriceX64, upperEffPriceX64, priceLimitX64, Math.Rounding.Floor);
        if (maxFinalBinPos <= currBinPos) {
          return (currBinPos, 0, 0, 0, 0, 0);
        }
      }

      // Check if we can consume up to maxFinalBinPos directly
      out0Scaled = calculateOutputToken0FromBinPosition(binState.token0BalanceScaled, currBinPos, maxFinalBinPos);

      uint256 finalPriceX64 =
        calculatePriceAtBinPosition(lowerEffPriceX64, upperEffPriceX64, maxFinalBinPos, Math.Rounding.Ceil);
      uint256 totalIn1Scaled = calculateRequiredToken1(out0Scaled, startingPriceX64, finalPriceX64);

      uint256 targetPos;
      if (totalIn1Scaled <= state.amountSpecifiedRemainingScaled) {
        targetPos = maxFinalBinPos;
      } else {
        targetPos = computeAnalyticalTargetPosForBuyToken0(
          currBinPos,
          maxFinalBinPos,
          state.amountSpecifiedRemainingScaled,
          binState.token0BalanceScaled,
          lowerEffPriceX64,
          upperEffPriceX64
        );

        out0Scaled = calculateOutputToken0FromBinPosition(binState.token0BalanceScaled, currBinPos, targetPos);
        finalPriceX64 = calculatePriceAtBinPosition(lowerEffPriceX64, upperEffPriceX64, targetPos, Math.Rounding.Ceil);
        totalIn1Scaled = calculateRequiredToken1(out0Scaled, startingPriceX64, finalPriceX64);

        if (totalIn1Scaled < state.amountSpecifiedRemainingScaled && targetPos < maxFinalBinPos) {
          if (totalIn1Scaled == 0) totalIn1Scaled = 1;
          uint256 delta = targetPos - currBinPos;
          uint256 scaledDelta = delta * state.amountSpecifiedRemainingScaled / totalIn1Scaled;
          if (scaledDelta == 0) {
            totalIn1Scaled = state.amountSpecifiedRemainingScaled;
            targetPos = currBinPos;
            out0Scaled = 0;
          } else {
            uint256 scaledTarget = currBinPos + scaledDelta;
            if (scaledTarget > maxFinalBinPos) {
              targetPos = maxFinalBinPos;
            } else {
              targetPos = scaledTarget;
            }

            out0Scaled = calculateOutputToken0FromBinPosition(binState.token0BalanceScaled, currBinPos, targetPos);
            finalPriceX64 =
              calculatePriceAtBinPosition(lowerEffPriceX64, upperEffPriceX64, targetPos, Math.Rounding.Ceil);
            totalIn1Scaled = calculateRequiredToken1(out0Scaled, startingPriceX64, finalPriceX64);
          }
        }

        if (totalIn1Scaled < state.amountSpecifiedRemainingScaled && targetPos < maxFinalBinPos) {
          totalIn1Scaled = state.amountSpecifiedRemainingScaled;
        }

        if (totalIn1Scaled > state.amountSpecifiedRemainingScaled) {
          out0Scaled = (out0Scaled * state.amountSpecifiedRemainingScaled) / totalIn1Scaled;
          targetPos = calculateBinPositionAfterSellingAmount0(currBinPos, out0Scaled, binState.token0BalanceScaled);
          totalIn1Scaled = state.amountSpecifiedRemainingScaled;
        }
      }

      if (out0Scaled == 0) {
        targetPos = currBinPos;
      }

      uint256 totalFeeScaled = (totalIn1Scaled * totalFeeOfGrossX64) / ONE_X64;
      platformFeeScaled = totalFeeScaled * platformShareOfFeeX64 / ONE_X64;
      lpFeeScaled = totalFeeScaled - platformFeeScaled;
      uint256 binCreditScaled = totalIn1Scaled - platformFeeScaled;

      binState.token0BalanceScaled -= out0Scaled.toUint104();
      binState.token1BalanceScaled =
        _toUint104IncomingBinBalance(uint256(binState.token1BalanceScaled) + binCreditScaled);

      state.amountSpecifiedRemainingScaled -= totalIn1Scaled;
      state.amountCalculatedScaled += out0Scaled;

      binDelta0Scaled = -out0Scaled.toInt256();
      binDelta1Scaled = binCreditScaled.toInt256();
      return (targetPos, out0Scaled, binDelta0Scaled, binDelta1Scaled, platformFeeScaled, lpFeeScaled);
    }
  }

  /**
   * @notice Calculate swap amounts for a single bin iteration - exact input token0, output token1 (going down in price)
   * @dev Uses analytical quadratic solution with Math.sqrt and iterative refinement.
   * @param binState Current bin state
   * @param currBinPos Current position in bin (uint104).
   * @param state Current swap state
   * @param lowerEffPriceX64 Effective lower bound price of bin. Assumes <= type(uint128).max.
   * @param upperEffPriceX64 Effective upper bound price of bin. Assumes lowerPriceX64 < upperPriceX64 <= type(uint128).max.
   * @param priceLimitX64 Price limit for the swap. Assumes <= type(uint128).max.
   * @return finalBinPos End position in bin. Result <= MAX_POS_BIN.
   * @return out1Scaled Output token1 amount for this bin. Result <= MAX_POS_BIN.
   * @return binDelta0Scaled Change in the BIN's scaled token0 balance (positive = token0 entered the bin, net of the platform take).
   * @return binDelta1Scaled Change in the BIN's scaled token1 balance (negative = token1 left the bin).
   * @return platformFeeScaled Combined platform take withheld from the input (never enters the bin).
   * @return lpFeeScaled LP leg of the carved fee for this step; stays in the bin.
   */
  function buyToken1InBinSpecifiedIn(
    BinState memory binState,
    uint256 currBinPos,
    SwapState memory state,
    uint256 totalFeeOfGrossX64,
    uint256 platformShareOfFeeX64,
    uint256 lowerEffPriceX64,
    uint256 upperEffPriceX64,
    uint256 priceLimitX64
  )
    internal
    pure
    returns (
      uint256 finalBinPos,
      uint256 out1Scaled,
      int256 binDelta0Scaled,
      int256 binDelta1Scaled,
      uint256 platformFeeScaled,
      uint256 lpFeeScaled
    )
  {
    unchecked {
      uint256 startingPriceX64 =
        calculatePriceAtBinPosition(lowerEffPriceX64, upperEffPriceX64, currBinPos, Math.Rounding.Floor);

      if (state.amountSpecifiedRemainingScaled < Math.ceilDiv(ONE_X64, startingPriceX64)) {
        return (currBinPos, 0, 0, 0, 0, 0);
      }

      uint256 minFinalBinPos;

      if (priceLimitX64 <= lowerEffPriceX64) {
        minFinalBinPos = 0;
      } else {
        minFinalBinPos =
          calculateBinPositionAtPrice(lowerEffPriceX64, upperEffPriceX64, priceLimitX64, Math.Rounding.Ceil);
        if (currBinPos <= minFinalBinPos) {
          return (currBinPos, 0, 0, 0, 0, 0);
        }
      }

      // Check if we can consume up to minFinalBinPos directly
      out1Scaled = calculateOutputToken1FromBinPosition(binState.token1BalanceScaled, currBinPos, minFinalBinPos);

      uint256 finalPriceX64 =
        calculatePriceAtBinPosition(lowerEffPriceX64, upperEffPriceX64, minFinalBinPos, Math.Rounding.Floor);
      uint256 totalIn0Scaled = calculateRequiredToken0(out1Scaled, startingPriceX64, finalPriceX64);

      uint256 targetPos;
      if (totalIn0Scaled <= state.amountSpecifiedRemainingScaled) {
        targetPos = minFinalBinPos;
      } else {
        targetPos = computeAnalyticalTargetPosForSellToken0(
          currBinPos,
          minFinalBinPos,
          state.amountSpecifiedRemainingScaled,
          binState.token1BalanceScaled,
          lowerEffPriceX64,
          upperEffPriceX64
        );
        out1Scaled = calculateOutputToken1FromBinPosition(binState.token1BalanceScaled, currBinPos, targetPos);

        finalPriceX64 = calculatePriceAtBinPosition(lowerEffPriceX64, upperEffPriceX64, targetPos, Math.Rounding.Floor);
        totalIn0Scaled = calculateRequiredToken0(out1Scaled, startingPriceX64, finalPriceX64);

        if (totalIn0Scaled < state.amountSpecifiedRemainingScaled && targetPos > minFinalBinPos) {
          if (totalIn0Scaled == 0) totalIn0Scaled = 1;
          uint256 delta = currBinPos - targetPos;
          uint256 scaledDelta = delta * state.amountSpecifiedRemainingScaled / totalIn0Scaled;
          if (scaledDelta == 0) {
            totalIn0Scaled = state.amountSpecifiedRemainingScaled;
            targetPos = currBinPos;
            out1Scaled = 0;
          } else {
            targetPos = currBinPos > scaledDelta ? currBinPos - scaledDelta : 0;
            if (targetPos < minFinalBinPos) {
              targetPos = minFinalBinPos;
            }

            out1Scaled = calculateOutputToken1FromBinPosition(binState.token1BalanceScaled, currBinPos, targetPos);

            finalPriceX64 =
              calculatePriceAtBinPosition(lowerEffPriceX64, upperEffPriceX64, targetPos, Math.Rounding.Floor);
            totalIn0Scaled = calculateRequiredToken0(out1Scaled, startingPriceX64, finalPriceX64);
          }
        }
        if (totalIn0Scaled < state.amountSpecifiedRemainingScaled && targetPos > minFinalBinPos) {
          totalIn0Scaled = state.amountSpecifiedRemainingScaled;
        }

        if (totalIn0Scaled > state.amountSpecifiedRemainingScaled) {
          out1Scaled = (out1Scaled * state.amountSpecifiedRemainingScaled) / totalIn0Scaled;
          targetPos = calculateBinPositionAfterSellingAmount1(currBinPos, out1Scaled, binState.token1BalanceScaled);
          totalIn0Scaled = state.amountSpecifiedRemainingScaled;
        }
      }

      if (out1Scaled == 0) {
        targetPos = currBinPos;
      }

      uint256 totalFeeScaled = (totalIn0Scaled * totalFeeOfGrossX64) / ONE_X64;
      platformFeeScaled = totalFeeScaled * platformShareOfFeeX64 / ONE_X64;
      lpFeeScaled = totalFeeScaled - platformFeeScaled;
      uint256 binCreditScaled = totalIn0Scaled - platformFeeScaled;

      binState.token1BalanceScaled -= out1Scaled.toUint104();
      binState.token0BalanceScaled =
        _toUint104IncomingBinBalance(uint256(binState.token0BalanceScaled) + binCreditScaled);

      state.amountSpecifiedRemainingScaled -= totalIn0Scaled;
      state.amountCalculatedScaled += out1Scaled;

      binDelta0Scaled = binCreditScaled.toInt256();
      binDelta1Scaled = -out1Scaled.toInt256();
      return (targetPos, out1Scaled, binDelta0Scaled, binDelta1Scaled, platformFeeScaled, lpFeeScaled);
    }
  }
}
