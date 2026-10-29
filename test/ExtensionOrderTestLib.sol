// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @notice Test helper for packing extension call orders the same way pools decode them.
library ExtensionOrderTestLib {
  function encodeExtensionOrder(
    uint8 slot0,
    uint8 slot1,
    uint8 slot2,
    uint8 slot3,
    uint8 slot4,
    uint8 slot5,
    uint8 slot6
  ) internal pure returns (uint256 order) {
    order = slot0 | (uint256(slot1) << 3) | (uint256(slot2) << 6) | (uint256(slot3) << 9) | (uint256(slot4) << 12)
      | (uint256(slot5) << 15) | (uint256(slot6) << 18);
  }
}
