// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {BinState} from "../types/PoolStorage.sol";

uint256 constant ONE_X64 = 0x10000000000000000;
/// @dev Maximum discrete bin position (`type(uint104).max`); use as uint256 for arithmetic.
uint256 constant MAX_POS_BIN = type(uint104).max;

/**
 * @title SwapMath
 * @notice Library for pure swap calculation functions
 * @dev All functions are pure and do not access storage, making them easily testable.
 *      Callers must advance `SwapState` fields conservatively: keep per-iteration deltas within the bounds
 *      documented on each field so widened sums stay representable where the pool persists them.
 */
library SwapMath {
  using SafeCast for uint256;
  using SafeCast for int256;

  // ============ Type Definitions ============

  /// @notice State tracked during a swap operation
  /// @param amountSpecifiedRemainingScaled Remaining amount to swap (scaled to internal decimals). Assumes <= type(uint128).max.
  /// @param amountCalculatedScaled Accumulated output/input amount (scaled to internal decimals). Assumes <= type(uint128).max.
  /// @param protocolFeeAmountScaled Accumulated protocol fees (in internal decimals). Assumes <= MAX_POS_BIN before storage write.
  /// @dev Orchestrators should treat all three as running totals whose growth per bin step is bounded by the
  ///      bin liquidity and swap amount; the pool assumes intermediate values fit the same width as scaled balances.
  struct SwapState {
    uint256 amountSpecifiedRemainingScaled;
    uint256 amountCalculatedScaled;
    uint256 protocolFeeAmountScaled;
  }

  /// @notice Parameters passed to internal swap functions
  /// @param midPriceX64 Assumes <= type(uint128).max.
  /// @param baseFeeX64 Base fee in Q64.64 fixed-point. Assumes <= ONE_X64.
  /// @param priceLimitX64 Assumes <= type(uint128).max.
  struct InternalSwapParams {
    uint256 midPriceX64;
    uint256 baseFeeX64;
    uint256 priceLimitX64;
  }

  // ============ Price and Position Helpers ============

  /**
   * @notice Calculate price at a specific position within a bin
   * @param lowerPriceX64 Price at the lower bound of the bin. Assumes <= type(uint128).max.
   * @param upperPriceX64 Price at the upper bound of the bin. Assumes <= type(uint128).max.
   * @param position Current position along the bin segment (uint256; must be ≤ `MAX_POS_BIN` or the subtraction reverts).
   * @param rounding Rounding mode for interpolation.
   * @return priceX64 Interpolated price at the given position. Result <= type(uint128).max.
   */
  function calculatePriceAtBinPosition(
    uint256 lowerPriceX64,
    uint256 upperPriceX64,
    uint256 position,
    Math.Rounding rounding
  ) internal pure returns (uint256 priceX64) {
    uint256 maxSubCurrPos = MAX_POS_BIN - position;
    unchecked {
      // Overflow-safe: each product ≤ 2^128 × 2^104 = 2^232; sum ≤ 2^233 < 2^256.
      // Result is weighted average of lower/upper, so fits in uint128.
      if (rounding == Math.Rounding.Floor) {
        priceX64 = (lowerPriceX64 * maxSubCurrPos + upperPriceX64 * position) / MAX_POS_BIN;
      } else {
        priceX64 = Math.ceilDiv(lowerPriceX64 * maxSubCurrPos + upperPriceX64 * position, MAX_POS_BIN);
      }
    }
  }

  /**
   * @notice Calculate finalBinPos position limited by price
   * @param lowerPriceX64 Price at lower bound. Assumes <= type(uint128).max.
   * @param upperPriceX64 Price at upper bound. Assumes <= type(uint128).max.
   * @param priceX64 Maximum acceptable price. Assumes <= type(uint128).max.
   * @param rounding Rounding mode used for inverse interpolation.
   * @return result Bin position where price limit is reached. Result <= MAX_POS_BIN.
   * @dev Requires `lowerPriceX64 < upperPriceX64` and `priceX64` in `[lowerPriceX64, upperPriceX64]` so the
   *      inverse linear map is well-defined and the result stays on the bin segment.
   */
  function calculateBinPositionAtPrice(
    uint256 lowerPriceX64,
    uint256 upperPriceX64,
    uint256 priceX64,
    Math.Rounding rounding
  ) internal pure returns (uint256) {
    unchecked {
      // Numerator ≤ 2^128 × 2^104 = 2^232; denominator > 0 by assumption.
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
   * @param rounding Rounding mode for position update.
   * @return finalBinPos Position after consuming tradedAmount0. Result <= MAX_POS_BIN.
   */
  function calculateBinPositionAfterSellingAmount0(
    uint256 currBinPos,
    uint256 tradedAmount0,
    uint256 availableToken0,
    Math.Rounding rounding
  ) internal pure returns (uint256 finalBinPos) {
    unchecked {
      // Product ≤ 2^104 × 2^104 = 2^208 < 2^256. Quotient ≤ max − currBinPos,
      // so currBinPos + quotient ≤ MAX_POS_BIN.
      if (rounding == Math.Rounding.Floor) {
        return currBinPos + (((MAX_POS_BIN - currBinPos) * tradedAmount0) / availableToken0);
      } else {
        return currBinPos + Math.ceilDiv((MAX_POS_BIN - currBinPos) * tradedAmount0, availableToken0);
      }
    }
  }

  /**
   * @notice Calculate finalBinPos position to achieve desired token1 output
   * @param currBinPos Current position in bin (uint104).
   * @param tradedAmount1 Desired token1 output amount. Assumes <= availableToken1.
   * @param availableToken1 Available token1 in bin. Assumes <= MAX_POS_BIN and > 0.
   * @param rounding Rounding mode for position update.
   * @return finalBinPos Position after consuming tradedAmount1.
   */
  function calculateBinPositionAfterSellingAmount1(
    uint256 currBinPos,
    uint256 tradedAmount1,
    uint256 availableToken1,
    Math.Rounding rounding
  ) internal pure returns (uint256 finalBinPos) {
    unchecked {
      // Product ≤ 2^104 × 2^104 = 2^208 < 2^256. Quotient ≤ currBinPos ≤ MAX_POS_BIN.
      if (rounding == Math.Rounding.Floor) {
        return (currBinPos * (availableToken1 - tradedAmount1)) / availableToken1;
      } else {
        return Math.ceilDiv(currBinPos * (availableToken1 - tradedAmount1), availableToken1);
      }
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
   * @notice Calculate required token1 input for given token0 amount (both in the same internal decimals)
   * @param token0Amount Assumes <= MAX_POS_BIN.
   * @param avgPriceX64 Assumes <= type(uint128).max (Q64.64 format) and > 0.
   * @return requiredToken1 Token1 input in internal decimals. Result <= type(uint128).max.
   */
  function calculateRequiredToken1(uint256 token0Amount, uint256 avgPriceX64)
    internal
    pure
    returns (uint256 requiredToken1)
  {
    // Product ≤ 2^104 × 2^128 = 2^232 < 2^256.
    requiredToken1 = Math.ceilDiv(token0Amount * avgPriceX64, ONE_X64);
  }

  /**
   * @notice Calculate required token0 input for given token1 amount (both in the same internal decimals)
   * @param token1Amount Assumes <= MAX_POS_BIN.
   * @param avgPriceX64 Assumes <= type(uint128).max (Q64.64 format) and > 0.
   * @return requiredToken0 Token0 input in internal decimals. Result <= type(uint128).max.
   */
  function calculateRequiredToken0(uint256 token1Amount, uint256 avgPriceX64)
    internal
    pure
    returns (uint256 requiredToken0)
  {
    // Shift ≤ 2^104 << 64 = 2^168 < 2^256.
    requiredToken0 = Math.ceilDiv(token1Amount << 64, avgPriceX64);
  }

  // ============ Analytical Target Position Helpers ============

  /**
   * @notice Compute target bin position using analytical closed-form solution for buying token0
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
   * @param lowerPriceX64 Lower price bound of bin. Assumes <= type(uint128).max.
   * @param upperPriceX64 Upper price bound of bin. Assumes lowerPriceX64 < upperPriceX64 <= type(uint128).max.
   * @param feeX64 Constant fee in Q64.64 fixed-point.
   * @return targetPos Computed target position. Result satisfies currBinPos < targetPos <= maxFinalBinPos.
   */
  function computeAnalyticalTargetPosForBuyToken0(
    uint256 currBinPos,
    uint256 maxFinalBinPos,
    uint256 inputAmount,
    uint256 token0Balance,
    uint256 lowerPriceX64,
    uint256 upperPriceX64,
    uint256 feeX64
  ) internal pure returns (uint256 targetPos) {
    uint256 maxSubCurrPos = MAX_POS_BIN - currBinPos;
    uint256 deltaPriceX64 = upperPriceX64 - lowerPriceX64;
    uint256 priceAtCurrPosX64 = lowerPriceX64 + (deltaPriceX64 * currBinPos) / MAX_POS_BIN;

    uint256 deltaPos = 0;
    if (token0Balance > 0 && priceAtCurrPosX64 > 0 && maxSubCurrPos > 0) {
      uint256 aX128 = Math.mulDiv(token0Balance * (ONE_X64 + feeX64), priceAtCurrPosX64 << 64, maxSubCurrPos * ONE_X64);

      if (aX128 > 0) {
        uint256 qX128 = Math.mulDiv(inputAmount << 128, 1 << 128, aX128);

        // Apply quadratic correction
        // Exact solution: d = 2Q / (1 + sqrt(1 + 4rQ))
        // where r = B/A = ΔP / (2M × Pc)
        if (deltaPriceX64 > 0) {
          // rQx128 = ΔP × qX128 / (2M × Pc) = rQ × 2^128
          uint256 rQx128 = Math.mulDiv(deltaPriceX64, qX128, 2 * MAX_POS_BIN * priceAtCurrPosX64);

          // Exact quadratic solution: d = 2Q / (1 + sqrt(1 + 4rQ))
          uint256 sqrtArgX128 = (1 << 128) + 4 * rQx128;
          uint256 sqrtValX64 = Math.sqrt(sqrtArgX128);
          deltaPos = (2 * qX128) / ((1 << 128) + (sqrtValX64 << 64));
        } else {
          // Linear case (can happen for very small swaps):
          deltaPos = qX128 >> 128;
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
   * @notice Compute target bin position using analytical closed-form solution for selling token0
   * @dev Uses the compact midpoint-model form:
   *      d = (in0 * c * Pc) / (T1 * (1 + fee/2^64) * 2^64 + in0 * c * ΔP / (2M)).
   *      Implementation uses rounded-up denominator terms to keep d conservative (rounded down).
   * @param currBinPos Current position in bin. Assumes <= MAX_POS_BIN.
   * @param minFinalBinPos Minimum achievable final position. Assumes minFinalBinPos < currBinPos.
   * @param inputAmount Amount of token0 input to spend. Assumes <= type(uint128).max.
   * @param token1Balance Available token1 in bin. Assumes <= MAX_POS_BIN.
   * @param lowerPriceX64 Lower price bound of bin. Assumes <= type(uint128).max.
   * @param upperPriceX64 Upper price bound of bin. Assumes lowerPriceX64 < upperPriceX64 <= type(uint128).max.
   * @param feeX64 Constant fee in Q64.64 fixed-point.
   * @return targetPos Computed target position. Result satisfies minFinalBinPos <= targetPos < currBinPos.
   */
  function computeAnalyticalTargetPosForSellToken0(
    uint256 currBinPos,
    uint256 minFinalBinPos,
    uint256 inputAmount,
    uint256 token1Balance,
    uint256 lowerPriceX64,
    uint256 upperPriceX64,
    uint256 feeX64
  ) internal pure returns (uint256 targetPos) {
    uint256 deltaPriceX64 = upperPriceX64 - lowerPriceX64;
    uint256 priceAtCurrPosX64 = lowerPriceX64 + (deltaPriceX64 * currBinPos) / MAX_POS_BIN;

    if (currBinPos == 0 || priceAtCurrPosX64 == 0 || token1Balance == 0) return 0;

    uint256 denominator = Math.ceilDiv(token1Balance * (ONE_X64 + feeX64), ONE_X64);

    if (deltaPriceX64 > 0) {
      denominator += Math.mulDiv(inputAmount, currBinPos * deltaPriceX64, 2 * MAX_POS_BIN, Math.Rounding.Ceil);
    }
    if (denominator == 0) return 0;

    uint256 deltaPos = Math.mulDiv(inputAmount, currBinPos * priceAtCurrPosX64, denominator);

    // Minimum backward progress when rounding would otherwise stall with non-zero input.
    if (deltaPos == 0 && inputAmount > 0) deltaPos = 1;

    if (deltaPos > currBinPos) {
      targetPos = minFinalBinPos;
    } else {
      targetPos = (currBinPos - deltaPos < minFinalBinPos) ? minFinalBinPos : currBinPos - deltaPos;
    }

    if (targetPos < minFinalBinPos) targetPos = minFinalBinPos;
    // At least one step toward `minFinalBinPos` when still inside a positive bin span.
    if (targetPos >= currBinPos && currBinPos > 0) targetPos = currBinPos - 1;
  }

  /// @notice `ceil(net * onePlusBinFeeX64 / ONE_X64)` — gross input when the bin LP fee is charged on top.
  function grossInputWithBinFeeCeil(uint256 netInScaled, uint256 onePlusBinFeeX64) internal pure returns (uint256) {
    unchecked {
      return Math.ceilDiv(netInScaled * onePlusBinFeeX64, ONE_X64);
    }
  }

  /// @notice LP fee leg (scaled) implied by gross input and fee `binFeeX64 / ONE_X64` with `onePlus = ONE_X64 + binFeeX64`.
  function lpFeeScaledFromGrossInput(uint256 grossInScaled, uint256 binFeeX64, uint256 onePlusBinFeeX64)
    internal
    pure
    returns (uint256)
  {
    unchecked {
      return (grossInScaled * binFeeX64) / onePlusBinFeeX64;
    }
  }

  // ============ Swap In Bin Functions ============

  /**
   * @notice Calculate swap amounts for a single bin iteration (token1 → token0, exact output)
   * @dev Mirrored exact-output path for token1-out (`buyToken1InBinSpecifiedOut`) uses different midpoint/price
   *      rounding on purpose; see that function's @dev for the asymmetric pairing.
   * @param binState Current bin state
   * @param currBinPos Current position in bin (uint104).
   * @param state Current swap state
   * @param currBinBuyFeeX64 Current bin buy fee in Q64.64 fixed-point.
   * @param lowerPriceX64 Lower bound price of bin (Q64.64). Assumes <= type(uint128).max.
   * @param upperPriceX64 Upper bound price of bin. Assumes lowerPriceX64 < upperPriceX64 <= type(uint128).max.
   * @param priceLimitX64 Price limit for the swap. Assumes <= type(uint128).max.
   * @param spreadFeeE6 Spread (oracle + bin) fee share in E6 units taken from LP fee. Assumes <= type(uint24).max.
   * @return finalBinPos End position in bin.
   * @return delta0Scaled Net change in bin's scaled token0 balance (negative = token0 left bin).
   * @return delta1Scaled Net change in bin's scaled token1 balance (positive = token1 entered bin net of protocol fee).
   * @return binLpFeeAmount LP fee charged in this bin on the token1 input (excludes protocol portion).
   */
  function buyToken0InBinSpecifiedOut(
    BinState memory binState,
    uint256 currBinPos,
    SwapState memory state,
    uint256 currBinBuyFeeX64,
    uint256 lowerPriceX64,
    uint256 upperPriceX64,
    uint256 priceLimitX64,
    uint256 spreadFeeE6
  ) internal pure returns (uint256 finalBinPos, int256 delta0Scaled, int256 delta1Scaled, uint256 binLpFeeAmount) {
    unchecked {
      uint256 amountOutScaled = 0;

      if (state.amountSpecifiedRemainingScaled < binState.token0BalanceScaled) {
        finalBinPos = calculateBinPositionAfterSellingAmount0(
          currBinPos, state.amountSpecifiedRemainingScaled, binState.token0BalanceScaled, Math.Rounding.Floor
        );
        amountOutScaled =
          state.amountSpecifiedRemainingScaled > MAX_POS_BIN ? MAX_POS_BIN : state.amountSpecifiedRemainingScaled;
      } else {
        finalBinPos = MAX_POS_BIN;
        amountOutScaled = binState.token0BalanceScaled;
      }

      if (priceLimitX64 < upperPriceX64) {
        uint256 finalBinPosAtPriceLimit =
          calculateBinPositionAtPrice(lowerPriceX64, upperPriceX64, priceLimitX64, Math.Rounding.Floor);

        if (finalBinPosAtPriceLimit < finalBinPos) {
          finalBinPos = finalBinPosAtPriceLimit;
          uint256 amountOutHelper =
            calculateOutputToken0FromBinPosition(binState.token0BalanceScaled, currBinPos, finalBinPos);
          amountOutScaled = amountOutHelper < amountOutScaled ? amountOutHelper : amountOutScaled;
        }
      }

      // Both uint104: sum ≤ 2 × 2^104, avg ≤ MAX_POS_BIN
      uint256 avgPos = Math.ceilDiv(currBinPos + finalBinPos, 2);
      uint256 avgPriceX64 = calculatePriceAtBinPosition(lowerPriceX64, upperPriceX64, avgPos, Math.Rounding.Ceil);

      uint256 amountInScaled = calculateRequiredToken1(amountOutScaled, avgPriceX64);

      uint256 feeAmountScaled = Math.ceilDiv(amountInScaled * currBinBuyFeeX64, ONE_X64);
      amountInScaled += feeAmountScaled;
      uint256 protocolFeeAmountScaled = (feeAmountScaled * spreadFeeE6) / 1e6;

      binState.token0BalanceScaled -= amountOutScaled.toUint104();
      binState.token1BalanceScaled =
        (uint256(binState.token1BalanceScaled) + amountInScaled - protocolFeeAmountScaled).toUint104();

      state.amountSpecifiedRemainingScaled -= amountOutScaled;
      state.amountCalculatedScaled += amountInScaled;
      state.protocolFeeAmountScaled += protocolFeeAmountScaled;

      // casting to int256 is safe because amountOutScaled is bounded by uint104 bin liquidity.
      // forge-lint: disable-next-line(unsafe-typecast)
      delta0Scaled = -int256(amountOutScaled);
      // casting to int256 is safe because amountInScaled - protocolFeeAmountScaled is non-negative and bounded by uint104-scaled bin math.
      // forge-lint: disable-next-line(unsafe-typecast)
      delta1Scaled = int256(amountInScaled - protocolFeeAmountScaled);
      binLpFeeAmount = feeAmountScaled - protocolFeeAmountScaled;
    }
  }

  /**
   * @notice Calculate swap amounts for a single bin iteration (token0 → token1, exact output)
   * @dev Intentionally asymmetric vs `buyToken0InBinSpecifiedOut`: here the midpoint position uses integer halving
   *      and average price uses `Floor` rounding, while the token0-out path uses `ceilDiv` on the midpoint and
   *      `Ceil` on the interpolated price. Do not “symmetrize” without revisiting both paths together.
   * @param binState Current bin state
   * @param currBinPos Current position in bin (uint104).
   * @param state Current swap state
   * @param currBinSellFeeX64 Current bin sell fee in Q64.64 fixed-point.
   * @param lowerPriceX64 Lower bound price of bin (Q64.64). Assumes <= type(uint128).max.
   * @param upperPriceX64 Upper bound price of bin. Assumes lowerPriceX64 < upperPriceX64 <= type(uint128).max.
   * @param priceLimitX64 Price limit for the swap. Assumes <= type(uint128).max.
   * @param spreadFeeE6 Spread fee share in E6 units taken from LP fee. Assumes <= type(uint24).max.
   * @return finalBinPos End position in bin. Result <= MAX_POS_BIN.
   * @return delta0Scaled Net change in bin's scaled token0 balance (positive = token0 entered bin net of protocol fee).
   * @return delta1Scaled Net change in bin's scaled token1 balance (negative = token1 left bin).
   * @return binLpFeeAmount LP fee charged in this bin on the token0 input (excludes protocol portion).
   */
  function buyToken1InBinSpecifiedOut(
    BinState memory binState,
    uint256 currBinPos,
    SwapState memory state,
    uint256 currBinSellFeeX64,
    uint256 lowerPriceX64,
    uint256 upperPriceX64,
    uint256 priceLimitX64,
    uint256 spreadFeeE6
  ) internal pure returns (uint256 finalBinPos, int256 delta0Scaled, int256 delta1Scaled, uint256 binLpFeeAmount) {
    unchecked {
      uint256 amountOutScaled = 0;

      if (state.amountSpecifiedRemainingScaled < binState.token1BalanceScaled) {
        finalBinPos = calculateBinPositionAfterSellingAmount1(
          currBinPos, state.amountSpecifiedRemainingScaled, binState.token1BalanceScaled, Math.Rounding.Ceil
        );
        amountOutScaled =
          state.amountSpecifiedRemainingScaled > MAX_POS_BIN ? MAX_POS_BIN : state.amountSpecifiedRemainingScaled;
      } else {
        finalBinPos = 0;
        amountOutScaled = binState.token1BalanceScaled;
      }

      if (lowerPriceX64 < priceLimitX64) {
        uint256 finalBinPosAtPriceLimit =
          calculateBinPositionAtPrice(lowerPriceX64, upperPriceX64, priceLimitX64, Math.Rounding.Ceil);
        if (finalBinPos < finalBinPosAtPriceLimit) {
          finalBinPos = finalBinPosAtPriceLimit;
          uint256 amountOutHelper =
            calculateOutputToken1FromBinPosition(binState.token1BalanceScaled, currBinPos, finalBinPos);
          amountOutScaled = amountOutHelper < amountOutScaled ? amountOutHelper : amountOutScaled;
        }
      }

      // Both uint104: sum ≤ 2 × 2^104, avg ≤ MAX_POS_BIN
      uint256 avgPos = (currBinPos + finalBinPos) / 2;
      uint256 avgPriceX64 = calculatePriceAtBinPosition(lowerPriceX64, upperPriceX64, avgPos, Math.Rounding.Floor);

      uint256 amountInScaled = calculateRequiredToken0(amountOutScaled, avgPriceX64);

      uint256 feeAmountScaled = Math.ceilDiv(amountInScaled * currBinSellFeeX64, ONE_X64);
      amountInScaled += feeAmountScaled;
      uint256 protocolFeeAmountScaled = (feeAmountScaled * spreadFeeE6) / 1e6;

      binState.token1BalanceScaled -= amountOutScaled.toUint104();
      binState.token0BalanceScaled =
        (uint256(binState.token0BalanceScaled) + amountInScaled - protocolFeeAmountScaled).toUint104();

      state.amountSpecifiedRemainingScaled -= amountOutScaled;
      state.amountCalculatedScaled += amountInScaled;
      state.protocolFeeAmountScaled += protocolFeeAmountScaled;

      delta0Scaled = (amountInScaled - protocolFeeAmountScaled).toInt256();
      delta1Scaled = -amountOutScaled.toInt256();
      binLpFeeAmount = feeAmountScaled - protocolFeeAmountScaled;
    }
  }

  /**
   * @notice Calculate swap amounts for a single bin iteration - exact input token1, output token0 (going up in price)
   * @dev Uses analytical quadratic solution with Math.sqrt and iterative refinement
   * @param binState Current bin state
   * @param currBinPos Current position in bin (uint104).
   * @param state Current swap state
   * @param currBinBuyFeeX64 Current bin buy fee in Q64.64 fixed-point.
   * @param lowerPriceX64 Lower bound price of bin. Assumes <= type(uint128).max.
   * @param upperPriceX64 Upper bound price of bin. Assumes lowerPriceX64 < upperPriceX64 <= type(uint128).max.
   * @param priceLimitX64 Price limit for the swap. Assumes <= type(uint128).max.
   * @param spreadFeeE6 Spread fee share in E6 units taken from LP fee. Assumes <= type(uint24).max.
   * @return finalBinPos End position in bin. Result <= MAX_POS_BIN.
   * @return out0Scaled Output token0 amount for this bin. Result <= MAX_POS_BIN.
   * @return delta0Scaled Net change in bin's scaled token0 balance (negative = token0 left bin).
   * @return delta1Scaled Net change in bin's scaled token1 balance (positive = token1 entered bin net of protocol fee).
   * @return binLpFeeAmount LP fee charged in this bin on the token1 input (excludes protocol portion).
   */
  function buyToken0InBinSpecifiedIn(
    BinState memory binState,
    uint256 currBinPos,
    SwapState memory state,
    uint256 currBinBuyFeeX64,
    uint256 lowerPriceX64,
    uint256 upperPriceX64,
    uint256 priceLimitX64,
    uint256 spreadFeeE6
  )
    internal
    pure
    returns (uint256 finalBinPos, uint256 out0Scaled, int256 delta0Scaled, int256 delta1Scaled, uint256 binLpFeeAmount)
  {
    unchecked {
      if (
        (state.amountSpecifiedRemainingScaled << 64)
          < calculatePriceAtBinPosition(lowerPriceX64, upperPriceX64, currBinPos, Math.Rounding.Ceil)
      ) {
        return (currBinPos, 0, 0, 0, 0);
      }

      uint256 maxFinalBinPos;
      if (upperPriceX64 <= priceLimitX64) {
        maxFinalBinPos = MAX_POS_BIN;
      } else {
        maxFinalBinPos = calculateBinPositionAtPrice(lowerPriceX64, upperPriceX64, priceLimitX64, Math.Rounding.Floor);
        if (maxFinalBinPos <= currBinPos) {
          return (currBinPos, 0, 0, 0, 0);
        }
      }

      uint256 onePlusBuy = ONE_X64 + currBinBuyFeeX64;

      // Check if we can consume up to maxFinalBinPos directly
      out0Scaled = calculateOutputToken0FromBinPosition(binState.token0BalanceScaled, currBinPos, maxFinalBinPos);

      // Both uint104: avg of two uint104 values ≤ MAX_POS_BIN
      uint256 avgPos = Math.ceilDiv(currBinPos + maxFinalBinPos, 2);
      uint256 avgPrice = calculatePriceAtBinPosition(lowerPriceX64, upperPriceX64, avgPos, Math.Rounding.Ceil);
      uint256 in1WithoutFeeScaled = calculateRequiredToken1(out0Scaled, avgPrice);
      uint256 totalIn1Scaled = grossInputWithBinFeeCeil(in1WithoutFeeScaled, onePlusBuy);

      uint256 targetPos;
      if (totalIn1Scaled <= state.amountSpecifiedRemainingScaled) {
        targetPos = maxFinalBinPos;
      } else {
        // Use analytical closed-form solution to compute initial target position
        targetPos = computeAnalyticalTargetPosForBuyToken0(
          currBinPos,
          maxFinalBinPos,
          state.amountSpecifiedRemainingScaled,
          binState.token0BalanceScaled,
          lowerPriceX64,
          upperPriceX64,
          currBinBuyFeeX64
        );

        out0Scaled = calculateOutputToken0FromBinPosition(binState.token0BalanceScaled, currBinPos, targetPos);

        avgPos = Math.ceilDiv(currBinPos + targetPos, 2);
        avgPrice = calculatePriceAtBinPosition(lowerPriceX64, upperPriceX64, avgPos, Math.Rounding.Ceil);
        in1WithoutFeeScaled = calculateRequiredToken1(out0Scaled, avgPrice);
        totalIn1Scaled = grossInputWithBinFeeCeil(in1WithoutFeeScaled, onePlusBuy);

        if (totalIn1Scaled < state.amountSpecifiedRemainingScaled && targetPos < maxFinalBinPos) {
          if (totalIn1Scaled == 0) totalIn1Scaled = 1;
          uint256 delta = targetPos - currBinPos;
          // remaining > totalIn1Scaled ⇒ scaledDelta > delta, may exceed MAX_POS_BIN → keep uint256
          uint256 scaledDelta = Math.ceilDiv(delta * state.amountSpecifiedRemainingScaled, totalIn1Scaled);
          if (scaledDelta == 0) scaledDelta = 1;
          uint256 scaledTarget = currBinPos + scaledDelta;
          if (scaledTarget > maxFinalBinPos) {
            targetPos = maxFinalBinPos;
          } else {
            // Safe: scaledTarget ≤ maxFinalBinPos ≤ MAX_POS_BIN
            targetPos = scaledTarget;
          }

          out0Scaled = calculateOutputToken0FromBinPosition(binState.token0BalanceScaled, currBinPos, targetPos);

          avgPos = Math.ceilDiv(currBinPos + targetPos, 2);
          avgPrice = calculatePriceAtBinPosition(lowerPriceX64, upperPriceX64, avgPos, Math.Rounding.Ceil);
          in1WithoutFeeScaled = calculateRequiredToken1(out0Scaled, avgPrice);
          totalIn1Scaled = grossInputWithBinFeeCeil(in1WithoutFeeScaled, onePlusBuy);
        }

        if (totalIn1Scaled < state.amountSpecifiedRemainingScaled && targetPos < maxFinalBinPos) {
          totalIn1Scaled = state.amountSpecifiedRemainingScaled;
        }

        if (totalIn1Scaled > state.amountSpecifiedRemainingScaled) {
          uint256 delta = targetPos - currBinPos;
          // remaining < totalIn1Scaled ⇒ ratio < 1 ⇒ scaledDelta ≤ delta ≤ MAX_POS_BIN
          uint256 scaledDelta = Math.ceilDiv(delta * state.amountSpecifiedRemainingScaled, totalIn1Scaled);
          if (scaledDelta == 0) scaledDelta = 1;
          targetPos = currBinPos + scaledDelta;

          // Rescale out0Scaled proportionally; remaining < totalIn1Scaled ⇒ result ≤ out0Scaled ≤ MAX_POS_BIN
          out0Scaled = (out0Scaled * state.amountSpecifiedRemainingScaled) / totalIn1Scaled;
          totalIn1Scaled = state.amountSpecifiedRemainingScaled;
        }
      }
      uint256 token1FeeScaled = lpFeeScaledFromGrossInput(totalIn1Scaled, currBinBuyFeeX64, onePlusBuy);

      uint256 protocolFeeAmountScaled = (token1FeeScaled * spreadFeeE6) / 1e6;
      binState.token0BalanceScaled -= out0Scaled.toUint104();
      binState.token1BalanceScaled =
        uint256((binState.token1BalanceScaled) + totalIn1Scaled - protocolFeeAmountScaled).toUint104();

      state.amountSpecifiedRemainingScaled -= totalIn1Scaled;
      state.amountCalculatedScaled += out0Scaled;
      state.protocolFeeAmountScaled += protocolFeeAmountScaled;

      delta0Scaled = -out0Scaled.toInt256();
      delta1Scaled = (totalIn1Scaled - protocolFeeAmountScaled).toInt256();
      binLpFeeAmount = token1FeeScaled - protocolFeeAmountScaled;
      return (targetPos, out0Scaled, delta0Scaled, delta1Scaled, binLpFeeAmount);
    }
  }

  /**
   * @notice Calculate swap amounts for a single bin iteration - exact input token0, output token1 (going down in price)
   * @dev Uses analytical quadratic solution with Math.sqrt and iterative refinement
   * @param binState Current bin state
   * @param currBinPos Current position in bin (uint104).
   * @param state Current swap state
   * @param currBinSellFeeX64 Current bin sell fee in Q64.64 fixed-point.
   * @param lowerPriceX64 Lower bound price of bin (Q64.64). Assumes <= type(uint128).max.
   * @param upperPriceX64 Upper bound price of bin. Assumes lowerPriceX64 < upperPriceX64 <= type(uint128).max.
   * @param priceLimitX64 Price limit for the swap. Assumes <= type(uint128).max.
   * @param spreadFeeE6 Spread fee share in E6 units taken from LP fee. Assumes <= type(uint24).max.
   * @return finalBinPos End position in bin. Result <= MAX_POS_BIN.
   * @return out1Scaled Output token1 amount for this bin. Result <= MAX_POS_BIN.
   * @return delta0Scaled Net change in bin's scaled token0 balance (positive = token0 entered bin net of protocol fee).
   * @return delta1Scaled Net change in bin's scaled token1 balance (negative = token1 left bin).
   * @return binLpFeeAmount LP fee charged in this bin on the token0 input (excludes protocol portion).
   */
  function buyToken1InBinSpecifiedIn(
    BinState memory binState,
    uint256 currBinPos,
    SwapState memory state,
    uint256 currBinSellFeeX64,
    uint256 lowerPriceX64,
    uint256 upperPriceX64,
    uint256 priceLimitX64,
    uint256 spreadFeeE6
  )
    internal
    pure
    returns (uint256 finalBinPos, uint256 out1Scaled, int256 delta0Scaled, int256 delta1Scaled, uint256 binLpFeeAmount)
  {
    unchecked {
      if (
        state.amountSpecifiedRemainingScaled
            * calculatePriceAtBinPosition(lowerPriceX64, upperPriceX64, currBinPos, Math.Rounding.Floor) <= (ONE_X64)
      ) {
        return (currBinPos, 0, 0, 0, 0);
      }

      uint256 minFinalBinPos;

      if (priceLimitX64 <= lowerPriceX64) {
        minFinalBinPos = 0;
      } else {
        minFinalBinPos = calculateBinPositionAtPrice(lowerPriceX64, upperPriceX64, priceLimitX64, Math.Rounding.Ceil);
        if (currBinPos <= minFinalBinPos) {
          return (currBinPos, 0, 0, 0, 0);
        }
      }

      uint256 onePlusSell = ONE_X64 + currBinSellFeeX64;

      // Check if we can consume up to minFinalBinPos directly
      out1Scaled = calculateOutputToken1FromBinPosition(binState.token1BalanceScaled, currBinPos, minFinalBinPos);

      // Both uint104: avg of two uint104 values ≤ MAX_POS_BIN
      uint256 avgPos = Math.ceilDiv(currBinPos + minFinalBinPos, 2);
      uint256 avgPrice = calculatePriceAtBinPosition(lowerPriceX64, upperPriceX64, avgPos, Math.Rounding.Floor);
      uint256 in0WithoutFeeScaled = calculateRequiredToken0(out1Scaled, avgPrice);
      uint256 totalIn0Scaled = grossInputWithBinFeeCeil(in0WithoutFeeScaled, onePlusSell);

      uint256 targetPos;
      if (totalIn0Scaled <= state.amountSpecifiedRemainingScaled) {
        targetPos = minFinalBinPos;
      } else {
        // Use analytical closed-form solution to compute initial target position
        targetPos = computeAnalyticalTargetPosForSellToken0(
          currBinPos,
          minFinalBinPos,
          state.amountSpecifiedRemainingScaled,
          binState.token1BalanceScaled,
          lowerPriceX64,
          upperPriceX64,
          currBinSellFeeX64
        );
        out1Scaled = calculateOutputToken1FromBinPosition(binState.token1BalanceScaled, currBinPos, targetPos);

        avgPos = (currBinPos + targetPos) / 2;
        avgPrice = calculatePriceAtBinPosition(lowerPriceX64, upperPriceX64, avgPos, Math.Rounding.Floor);
        in0WithoutFeeScaled = calculateRequiredToken0(out1Scaled, avgPrice);
        totalIn0Scaled = grossInputWithBinFeeCeil(in0WithoutFeeScaled, onePlusSell);

        if (totalIn0Scaled < state.amountSpecifiedRemainingScaled && targetPos > minFinalBinPos) {
          if (totalIn0Scaled == 0) totalIn0Scaled = 1;

          uint256 delta = currBinPos - targetPos;
          // remaining > totalIn0Scaled ⇒ scaledDelta > delta, may exceed MAX_POS_BIN → keep uint256
          uint256 scaledDelta = Math.ceilDiv(delta * state.amountSpecifiedRemainingScaled, totalIn0Scaled);
          if (scaledDelta == 0) scaledDelta = 1;
          targetPos = currBinPos > scaledDelta ? currBinPos - scaledDelta : 0;
          if (targetPos < minFinalBinPos) {
            targetPos = minFinalBinPos;
          }

          out1Scaled = calculateOutputToken1FromBinPosition(binState.token1BalanceScaled, currBinPos, targetPos);

          avgPos = (currBinPos + targetPos) / 2;
          avgPrice = calculatePriceAtBinPosition(lowerPriceX64, upperPriceX64, avgPos, Math.Rounding.Floor);
          in0WithoutFeeScaled = calculateRequiredToken0(out1Scaled, avgPrice);
          totalIn0Scaled = grossInputWithBinFeeCeil(in0WithoutFeeScaled, onePlusSell);
        }
        if (totalIn0Scaled < state.amountSpecifiedRemainingScaled && targetPos > minFinalBinPos) {
          totalIn0Scaled = state.amountSpecifiedRemainingScaled;
        }

        if (totalIn0Scaled > state.amountSpecifiedRemainingScaled) {
          uint256 delta = currBinPos - targetPos;
          // remaining < totalIn0Scaled ⇒ ratio < 1 ⇒ scaledDelta ≤ delta ≤ currBinPos ≤ MAX_POS_BIN
          uint256 scaledDelta =
            Math.mulDiv(delta, state.amountSpecifiedRemainingScaled, totalIn0Scaled, Math.Rounding.Ceil);
          if (scaledDelta == 0) scaledDelta = 1;
          targetPos = currBinPos > scaledDelta ? currBinPos - scaledDelta : 0;

          // Rescale out1Scaled proportionally; remaining < totalIn0Scaled ⇒ result ≤ out1Scaled ≤ MAX_POS_BIN
          out1Scaled = (out1Scaled * state.amountSpecifiedRemainingScaled) / totalIn0Scaled;
          totalIn0Scaled = state.amountSpecifiedRemainingScaled;
        }
      }
      uint256 token0FeeScaled = lpFeeScaledFromGrossInput(totalIn0Scaled, currBinSellFeeX64, onePlusSell);

      uint256 protocolFeeAmountScaled = (token0FeeScaled * spreadFeeE6) / 1e6;

      binState.token1BalanceScaled -= out1Scaled.toUint104();
      binState.token0BalanceScaled =
        (uint256(binState.token0BalanceScaled) + totalIn0Scaled - protocolFeeAmountScaled).toUint104();

      state.amountSpecifiedRemainingScaled -= totalIn0Scaled;
      state.amountCalculatedScaled += out1Scaled;
      state.protocolFeeAmountScaled += protocolFeeAmountScaled;

      delta0Scaled = (totalIn0Scaled - protocolFeeAmountScaled).toInt256();
      delta1Scaled = -out1Scaled.toInt256();
      binLpFeeAmount = token0FeeScaled - protocolFeeAmountScaled;
      return (targetPos, out1Scaled, delta0Scaled, delta1Scaled, binLpFeeAmount);
    }
  }
}
