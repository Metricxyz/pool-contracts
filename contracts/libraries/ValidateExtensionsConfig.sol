// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {ExtensionOrders} from "../types/PoolExtensionsConfig.sol";

/// @title ValidateExtensionsConfig
/// @notice Factory validation for extension addresses, init data, and per-action call orders.
library ValidateExtensionsConfig {
  uint8 internal constant MAX_EXTENSIONS = 7;

  error InvalidExtensionsConfig();
  error InvalidExtensionOrder();

  function validateExtensionsConfig(
    address[] calldata extensions,
    ExtensionOrders calldata orders,
    bytes[] calldata extensionInitData
  ) internal pure {
    if (extensions.length > MAX_EXTENSIONS) revert InvalidExtensionsConfig();
    if (extensionInitData.length != extensions.length) revert InvalidExtensionsConfig();

    if (extensions.length == 0) {
      if (!_ordersAreZero(orders)) revert InvalidExtensionsConfig();
      return;
    }

    for (uint256 i = 0; i < extensions.length; i++) {
      if (extensions[i] == address(0)) revert InvalidExtensionsConfig();
      for (uint256 j = 0; j < i; j++) {
        if (extensions[i] == extensions[j]) revert InvalidExtensionsConfig();
      }
    }

    if (_ordersAreZero(orders)) revert InvalidExtensionsConfig();

    _validateExtensionOrder(orders.beforeAddLiquidity, extensions.length);
    _validateExtensionOrder(orders.afterAddLiquidity, extensions.length);
    _validateExtensionOrder(orders.beforeRemoveLiquidity, extensions.length);
    _validateExtensionOrder(orders.afterRemoveLiquidity, extensions.length);
    _validateExtensionOrder(orders.beforeSwap, extensions.length);
    _validateExtensionOrder(orders.afterSwap, extensions.length);
  }

  function _ordersAreZero(ExtensionOrders memory orders) private pure returns (bool) {
    return orders.beforeAddLiquidity == 0 && orders.afterAddLiquidity == 0 && orders.beforeRemoveLiquidity == 0
      && orders.afterRemoveLiquidity == 0 && orders.beforeSwap == 0 && orders.afterSwap == 0;
  }

  /// @notice Validate that only indices from 1 to extensionCount are present in the order and that there are no duplicates.
  function _validateExtensionOrder(uint256 order, uint256 extensionCount) private pure {
    unchecked {
      if (order == 0) return;

      uint256 seen;

      // this loop can run at most 7 times
      while (order != 0) {
        uint256 extensionIndex = order & 0x7;
        if (extensionIndex == 0 || extensionIndex > extensionCount) {
          revert InvalidExtensionOrder();
        }
        // forge-lint: disable-next-line(incorrect-shift) -- `1 << extensionIndex` sets bit `extensionIndex`; operands are correct.
        if (seen & (1 << extensionIndex) != 0) revert InvalidExtensionOrder();
        // forge-lint: disable-next-line(incorrect-shift) -- `1 << extensionIndex` sets bit `extensionIndex`; operands are correct.
        seen |= (1 << extensionIndex);
        order >>= 3;
      }
    }
  }
}
