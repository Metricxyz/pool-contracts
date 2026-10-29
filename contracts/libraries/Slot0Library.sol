// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {PoolSlot0} from "../types/Slot0.sol";

/// @title Slot0Library
/// @notice Pack and unpack MetricOmmPool storage slot 0.
/// @dev Bit layout must match `MetricOmmPool` and `PoolStateLibrary`:
///      pauseLevel(uint8,0) | curBinIdx(int8,8) | curPosInBin(uint104,16) |
///      curBinDistE6(int24,120) | spreadFeeE6(uint24,144) | notionalFeeE8(uint24,168)
library Slot0Library {
  function pack(
    uint8 pauseLevel,
    int8 curBinIdx,
    uint104 curPosInBin,
    int24 curBinDistFromProvidedPriceE6,
    uint24 spreadFeeE6,
    uint24 notionalFeeE8
  ) internal pure returns (uint256 packed) {
    packed = uint256(pauseLevel);
    // casting int8 -> int256 is lossless; outer uint256 is masked to 8 bits so no truncation
    // forge-lint: disable-next-line(unsafe-typecast)
    packed |= (uint256(uint256(int256(curBinIdx)) & 0xff) << 8);
    packed |= uint256(curPosInBin) << 16;
    // casting int24 -> int256 is lossless; outer uint256 is masked to 24 bits so no truncation
    // forge-lint: disable-next-line(unsafe-typecast)
    packed |= (uint256(uint256(int256(curBinDistFromProvidedPriceE6)) & 0xffffff) << 120);
    packed |= uint256(spreadFeeE6) << 144;
    packed |= uint256(notionalFeeE8) << 168;
  }

  function unpack(uint256 packed) internal pure returns (PoolSlot0 memory s) {
    uint8 pauseLevel;
    int256 binIdxWide;
    int256 distWide;
    assembly ("memory-safe") {
      pauseLevel := and(packed, 0xff)
      binIdxWide := signextend(0, shr(8, packed))
      distWide := signextend(2, shr(120, packed))
    }
    s.pauseLevel = pauseLevel;
    // forge-lint: disable-next-line(unsafe-typecast)
    s.curBinIdx = int8(binIdxWide);
    // forge-lint: disable-next-line(unsafe-typecast)
    s.curPosInBin = uint104((packed >> 16) & type(uint104).max);
    // forge-lint: disable-next-line(unsafe-typecast)
    s.curBinDistFromProvidedPriceE6 = int24(distWide);
    // forge-lint: disable-next-line(unsafe-typecast)
    s.spreadFeeE6 = uint24((packed >> 144) & 0xFFFFFF);
    // forge-lint: disable-next-line(unsafe-typecast)
    s.notionalFeeE8 = uint24((packed >> 168) & 0xFFFFFF);
  }

  /// @notice Read the pool's packed slot 0 (caller must be `MetricOmmPool` or delegate context).
  function loadPackedSlot0() internal view returns (uint256 packed) {
    assembly ("memory-safe") {
      packed := sload(0)
    }
  }
}
