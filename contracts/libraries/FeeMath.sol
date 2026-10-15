// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ONE_X64} from "./SwapMath.sol";

/// @title FeeMath
/// @notice Fee-rate composition and platform/LP split helpers for swaps (Q64.64).
library FeeMath {
  /// @notice Notional fee as a Q64.64 fraction.
  /// @param notionalFeeE8 Pool's total notional fee in E8 (`1e8 = 100%`).
  function _notionalFeeX64(uint24 notionalFeeE8) internal pure returns (uint256) {
    unchecked {
      return (uint256(notionalFeeE8) * ONE_X64) / 1e8;
    }
  }

  /// @notice Whole fee a trader pays in a bin, in Q64.64: oracle base spread + per-bin add + notional.
  /// @param baseFeeX64 Oracle base spread fee for the active direction.
  /// @param addFeeE6 Per-bin additional fee for the active direction, in E6. Assumes
  ///        `<= type(uint16).max` (both `BinState` add-fee fields are `uint16`); the unchecked
  ///        multiply below relies on that bound.
  /// @param notionalFeeX64_ Notional fee as a Q64.64 fraction (see `_notionalFeeX64`).
  function binTotalFeeX64(uint256 baseFeeX64, uint256 addFeeE6, uint256 notionalFeeX64_)
    internal
    pure
    returns (uint256)
  {
    unchecked {
      return baseFeeX64 + (addFeeE6 * ONE_X64) / 1e6 + notionalFeeX64_;
    }
  }

  /// @notice Fold a bin fee into a reference-anchored price to get the price the trader executes at.
  /// @param priceX64 Reference-anchored (fee-exclusive) price.
  /// @param totalFeeX64 Whole fee for the direction: base + per-bin add + notional.
  /// @param zeroForOne True when selling token0 (price divides), false when buying token0 (price multiplies).
  function effectivePriceX64(uint256 priceX64, uint256 totalFeeX64, bool zeroForOne) internal pure returns (uint256) {
    return zeroForOne
      ? Math.mulDiv(priceX64, ONE_X64, ONE_X64 + totalFeeX64, Math.Rounding.Floor)
      : Math.mulDiv(priceX64, ONE_X64 + totalFeeX64, ONE_X64, Math.Rounding.Ceil);
  }

  /// @notice PLATFORM share of the carved fee, in Q64.64 (`ONE_X64` = the platform takes all of it).
  /// @param totalFeeX64 Whole fee folded into the prices: base + per-bin add + notional.
  /// @param notionalFeeX64 Notional leg of `totalFeeX64`. Assumes <= totalFeeX64.
  /// @param spreadFeeE6 Platform share of the SPREAD leg in E6 (`protocolSpreadFeeE6 + adminSpreadFeeE6`).
  function platformPartOfTotalFeeX64(uint256 totalFeeX64, uint256 notionalFeeX64, uint256 spreadFeeE6)
    internal
    pure
    returns (uint256)
  {
    unchecked {
      if (totalFeeX64 == 0) return 0;
      uint256 platformRateX64 = notionalFeeX64 + ((totalFeeX64 - notionalFeeX64) * spreadFeeE6) / 1e6;
      return Math.mulDiv(platformRateX64, ONE_X64, totalFeeX64);
    }
  }

  /// @notice Notional leg of a platform take.
  /// @param platformTakeScaled Combined platform fee withheld from the trader's input, in scaled units.
  /// @param totalFeeX64 Whole fee folded into the prices.
  /// @param notionalFeeX64 Notional amount in `totalFeeX64`. Assumes <= totalFeeX64.
  /// @param spreadFeeE6 Platform share of the SPREAD leg in E6.
  function notionalPartOfPlatformTake(
    uint256 platformTakeScaled,
    uint256 totalFeeX64,
    uint256 notionalFeeX64,
    uint256 spreadFeeE6
  ) internal pure returns (uint256) {
    unchecked {
      if (platformTakeScaled == 0 || notionalFeeX64 == 0) return 0;

      uint256 totalSpreadFeeX64 = totalFeeX64 - notionalFeeX64;
      uint256 platformRateX64 = notionalFeeX64 + (totalSpreadFeeX64 * spreadFeeE6) / 1e6;
      return Math.mulDiv(platformTakeScaled, notionalFeeX64, platformRateX64);
    }
  }

  /// @notice Whole carved fee as a fraction of the trader's GROSS input, in Q64.64.
  function totalFeeOfGrossX64(uint256 totalFeeX64) internal pure returns (uint256) {
    if (totalFeeX64 == 0) return 0;
    return Math.mulDiv(totalFeeX64, ONE_X64, ONE_X64 + totalFeeX64);
  }
}
