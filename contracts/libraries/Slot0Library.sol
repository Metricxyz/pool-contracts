// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {PoolSlot0} from "../types/Slot0.sol";

/// @title Slot0Library
/// @notice Pack and unpack MetricOmmPool storage slot 0.
/// @dev Bit layout must match `MetricOmmPool` and `PoolStateLibrary`:
///      pauseLevel(uint8,0) | curBinIdx(int16,8) | curPosInBin(uint104,24) |
///      curBinDistE6(int24,128) | spreadFeeE6(uint24,152) | notionalFeeE8(uint24,176) |
///      bidAskRefAsymmetryX8(uint16,200)
///      Top bit used is 215, so the word still has 40 bits spare.
library Slot0Library {
  function pack(
    uint8 pauseLevel,
    int16 curBinIdx,
    uint104 curPosInBin,
    int24 curBinDistFromProvidedPriceE6,
    uint24 spreadFeeE6,
    uint24 notionalFeeE8,
    uint16 bidAskRefAsymmetryX8
  ) internal pure returns (uint256 packed) {
    packed = uint256(pauseLevel);
    // casting int16 -> int256 is lossless; outer uint256 is masked to 16 bits so no truncation
    // forge-lint: disable-next-line(unsafe-typecast)
    packed |= (uint256(uint256(int256(curBinIdx)) & 0xffff) << 8);
    packed |= uint256(curPosInBin) << 24;
    // casting int24 -> int256 is lossless; outer uint256 is masked to 24 bits so no truncation
    // forge-lint: disable-next-line(unsafe-typecast)
    packed |= (uint256(uint256(int256(curBinDistFromProvidedPriceE6)) & 0xffffff) << 128);
    packed |= uint256(spreadFeeE6) << 152;
    packed |= uint256(notionalFeeE8) << 176;
    packed |= uint256(bidAskRefAsymmetryX8) << 200;
  }

  function unpack(uint256 packed) internal pure returns (PoolSlot0 memory s) {
    uint8 pauseLevel;
    int256 binIdxWide;
    int256 distWide;
    assembly ("memory-safe") {
      pauseLevel := and(packed, 0xff)
      binIdxWide := signextend(1, shr(8, packed))
      distWide := signextend(2, shr(128, packed))
    }
    s.pauseLevel = pauseLevel;
    // forge-lint: disable-next-line(unsafe-typecast)
    s.curBinIdx = int16(binIdxWide);
    // forge-lint: disable-next-line(unsafe-typecast)
    s.curPosInBin = uint104((packed >> 24) & type(uint104).max);
    // forge-lint: disable-next-line(unsafe-typecast)
    s.curBinDistFromProvidedPriceE6 = int24(distWide);
    // forge-lint: disable-next-line(unsafe-typecast)
    s.spreadFeeE6 = uint24((packed >> 152) & 0xFFFFFF);
    // forge-lint: disable-next-line(unsafe-typecast)
    s.notionalFeeE8 = uint24((packed >> 176) & 0xFFFFFF);
    // forge-lint: disable-next-line(unsafe-typecast)
    s.bidAskRefAsymmetryX8 = uint16((packed >> 200) & 0xFFFF);
  }

  /// @notice Read the pool's packed slot 0 (caller must be `MetricOmmPool` or delegate context).
  function loadPackedSlot0() internal view returns (uint256 packed) {
    assembly ("memory-safe") {
      packed := sload(0)
    }
  }
}
