// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title BinDataLibrary
/// @notice Packing helpers for factory-supplied bin configuration data
/// @dev Each bin packs three uint16 fields into 48 bits:
///      - lengthE6
///      - addFeeBuyE6
///      - addFeeSellE6
///      Five bins are packed into one uint256 (240 bits used, 16 bits unused).
library BinDataLibrary {
  type BinData is uint48;
  type BinDataPackedx5 is uint256;

  /// @notice Extract lengthE6 from packed bin data
  function lengthE6(BinData self) internal pure returns (uint16 length) {
    assembly {
      length := and(self, 0xFFFF) // Lower 16 bits
    }
  }

  /// @notice Extract addFeeBuyE6 from packed bin data
  function addFeeBuyE6(BinData self) internal pure returns (uint16 fee) {
    assembly {
      fee := and(shr(16, self), 0xFFFF) // Bits 16-31 (16 bits)
    }
  }

  /// @notice Extract addFeeSellE6 from packed bin data
  function addFeeSellE6(BinData self) internal pure returns (uint16 fee) {
    assembly {
      fee := and(shr(32, self), 0xFFFF) // Bits 32-47 (16 bits)
    }
  }

  /// @notice Unpack all fields from bin data
  function unpack(BinData self) internal pure returns (uint16 length, uint16 buyFee, uint16 sellFee) {
    assembly {
      length := and(self, 0xFFFF)
      buyFee := and(shr(16, self), 0xFFFF)
      sellFee := and(shr(32, self), 0xFFFF)
    }
  }

  /// @notice Pack bin data fields into BinData
  function pack(uint16 length, uint16 buyFee, uint16 sellFee) internal pure returns (BinData) {
    return BinData.wrap(uint48(length) | (uint48(buyFee) << 16) | (uint48(sellFee) << 32));
  }

  /// @notice Extract a BinData from a packed uint256 at the given position (0-4)
  function toBinData(uint256 packed, uint8 position) internal pure returns (BinData binData) {
    assembly {
      // position * 48: shift by 48 bits per position
      let shift := mul(position, 48)
      binData := and(shr(shift, packed), 0xFFFFFFFFFFFF) // Mask to 48 bits
    }
  }

  /// @notice Extract a BinData from a BinDataPackedx5 at the given position (0-4)
  function getBinData(BinDataPackedx5 self, uint8 position) internal pure returns (BinData binData) {
    assembly {
      // position * 48: shift by 48 bits per position
      let shift := mul(position, 48)
      binData := and(shr(shift, self), 0xFFFFFFFFFFFF) // Mask to 48 bits
    }
  }
}
