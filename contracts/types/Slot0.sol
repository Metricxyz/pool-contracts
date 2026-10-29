// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @dev Decoded storage slot 0; pack/unpack via `Slot0Library`.
struct PoolSlot0 {
  uint8 pauseLevel;
  int8 curBinIdx;
  uint104 curPosInBin;
  int24 curBinDistFromProvidedPriceE6;
  uint24 spreadFeeE6;
  uint24 notionalFeeE8;
}
