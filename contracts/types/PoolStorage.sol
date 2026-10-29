// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @notice Packed bin-level totals occupying a single storage slot.
/// @dev Layout must stay `uint128, uint128` so the slot packing matches `PoolStateLibrary` EXTSLOAD decoding.
/// @param scaledToken0 Sum of `token0BalanceScaled` across all bins.
/// @param scaledToken1 Sum of `token1BalanceScaled` across all bins.
struct BinTotals {
  uint128 scaledToken0;
  uint128 scaledToken1;
}

/// @notice State of a single bin in the OMM pool
/// @param token0BalanceScaled Current token0 in bin (in internal scaled units)
/// @param token1BalanceScaled Current token1 in bin (in internal scaled units)
/// @param lengthE6 Length of the bin; 1e6 = 100%
/// @param addFeeBuyE6 Additional fee for buying token0; 1e6 = 100%
/// @param addFeeSellE6 Additional fee for buying token1; 1e6 = 100%
struct BinState {
  uint104 token0BalanceScaled;
  uint104 token1BalanceScaled;
  uint16 lengthE6;
  uint16 addFeeBuyE6;
  uint16 addFeeSellE6;
}
