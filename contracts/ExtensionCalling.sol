// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IMetricOmmExtensions} from "./interfaces/extensions/IMetricOmmExtensions.sol";
import {CallExtension} from "./libraries/CallExtension.sol";
import {LiquidityDelta} from "./types/PoolOperation.sol";
import {PoolExtensions, ExtensionOrders} from "./types/PoolExtensionsConfig.sol";

/// @title ExtensionCalling
/// @notice Abstract base holding per-pool extension immutables and ordered extension invocation.
/// @dev Extensions are numbered 1-7 (`EXTENSION_1`..`EXTENSION_7`). Each action has a packed order word of 3-bit
///      extension indices, least significant group first, terminated by a zero group (see `ExtensionOrders`).
///      Extensions run sequentially in that order; any revert, malformed response, or wrong returned selector
///      reverts the whole action.
abstract contract ExtensionCalling {
  /// @dev Should never happen if factory validates extensions config.
  error PanicInvalidExtensionIndex();
  /// @dev Should never happen if factory validates extensions config.
  error PanicEmptyExtension();

  address internal immutable EXTENSION_1;
  address internal immutable EXTENSION_2;
  address internal immutable EXTENSION_3;
  address internal immutable EXTENSION_4;
  address internal immutable EXTENSION_5;
  address internal immutable EXTENSION_6;
  address internal immutable EXTENSION_7;
  /// @dev Order of extension calls for before add liquidity.
  uint256 internal immutable BEFORE_ADD_LIQUIDITY_ORDER;
  /// @dev Order of extension calls for after add liquidity.
  uint256 internal immutable AFTER_ADD_LIQUIDITY_ORDER;
  /// @dev Order of extension calls for before remove liquidity.
  uint256 internal immutable BEFORE_REMOVE_LIQUIDITY_ORDER;
  /// @dev Order of extension calls for after remove liquidity.
  uint256 internal immutable AFTER_REMOVE_LIQUIDITY_ORDER;
  /// @dev Order of extension calls for before swap.
  uint256 internal immutable BEFORE_SWAP_ORDER;
  /// @dev Order of extension calls for after swap.
  uint256 internal immutable AFTER_SWAP_ORDER;

  constructor(PoolExtensions memory extensions, ExtensionOrders memory extensionOrders) {
    EXTENSION_1 = extensions.extension1;
    EXTENSION_2 = extensions.extension2;
    EXTENSION_3 = extensions.extension3;
    EXTENSION_4 = extensions.extension4;
    EXTENSION_5 = extensions.extension5;
    EXTENSION_6 = extensions.extension6;
    EXTENSION_7 = extensions.extension7;
    BEFORE_ADD_LIQUIDITY_ORDER = extensionOrders.beforeAddLiquidity;
    AFTER_ADD_LIQUIDITY_ORDER = extensionOrders.afterAddLiquidity;
    BEFORE_REMOVE_LIQUIDITY_ORDER = extensionOrders.beforeRemoveLiquidity;
    AFTER_REMOVE_LIQUIDITY_ORDER = extensionOrders.afterRemoveLiquidity;
    BEFORE_SWAP_ORDER = extensionOrders.beforeSwap;
    AFTER_SWAP_ORDER = extensionOrders.afterSwap;
  }

  /// @dev Reverts with `PanicInvalidExtensionIndex` for 0 or any index above 7.
  function _extensionAddress(uint256 extensionIndex) internal view returns (address extension) {
    if (extensionIndex < 4) {
      if (extensionIndex < 2) {
        if (extensionIndex == 1) return EXTENSION_1;
        revert PanicInvalidExtensionIndex();
      } else {
        if (extensionIndex == 2) return EXTENSION_2;
        return EXTENSION_3;
      }
    } else if (extensionIndex < 8) {
      if (extensionIndex < 6) {
        if (extensionIndex == 4) return EXTENSION_4;
        return EXTENSION_5;
      } else {
        if (extensionIndex == 6) return EXTENSION_6;
        return EXTENSION_7;
      }
    } else {
      revert PanicInvalidExtensionIndex();
    }
  }

  /// @dev Walks `order` three bits at a time until a zero group or an exhausted word; an order of 0 calls nothing.
  ///      Reverts with `PanicEmptyExtension` if an indexed slot holds the zero address.
  function _callExtensionsInOrder(uint256 order, bytes memory data) private {
    if (order == 0) return;

    while (true) {
      uint256 extensionIndex = order & 0x7;
      if (extensionIndex == 0) break;
      address extension = _extensionAddress(extensionIndex);
      if (extension == address(0)) revert PanicEmptyExtension();
      CallExtension.callExtension(extension, data);
      order >>= 3;
    }
  }

  function _beforeAddLiquidity(
    address sender,
    address owner,
    uint80 salt,
    LiquidityDelta calldata deltas,
    bytes calldata extensionData
  ) internal {
    _callExtensionsInOrder(
      BEFORE_ADD_LIQUIDITY_ORDER,
      abi.encodeCall(IMetricOmmExtensions.beforeAddLiquidity, (sender, owner, salt, deltas, extensionData))
    );
  }

  function _afterAddLiquidity(
    address sender,
    address owner,
    uint80 salt,
    LiquidityDelta calldata deltas,
    uint256 amount0Added,
    uint256 amount1Added,
    bytes calldata extensionData
  ) internal {
    _callExtensionsInOrder(
      AFTER_ADD_LIQUIDITY_ORDER,
      abi.encodeCall(
        IMetricOmmExtensions.afterAddLiquidity, (sender, owner, salt, deltas, amount0Added, amount1Added, extensionData)
      )
    );
  }

  function _beforeRemoveLiquidity(
    address sender,
    address owner,
    uint80 salt,
    LiquidityDelta calldata deltas,
    bytes calldata extensionData
  ) internal {
    _callExtensionsInOrder(
      BEFORE_REMOVE_LIQUIDITY_ORDER,
      abi.encodeCall(IMetricOmmExtensions.beforeRemoveLiquidity, (sender, owner, salt, deltas, extensionData))
    );
  }

  function _afterRemoveLiquidity(
    address sender,
    address owner,
    uint80 salt,
    LiquidityDelta calldata deltas,
    uint256 amount0Removed,
    uint256 amount1Removed,
    bytes calldata extensionData
  ) internal {
    _callExtensionsInOrder(
      AFTER_REMOVE_LIQUIDITY_ORDER,
      abi.encodeCall(
        IMetricOmmExtensions.afterRemoveLiquidity,
        (sender, owner, salt, deltas, amount0Removed, amount1Removed, extensionData)
      )
    );
  }

  function _beforeSwap(
    address sender,
    address recipient,
    bool zeroForOne,
    int128 amountSpecified,
    uint128 priceLimitX64,
    uint256 packedSlot0Initial,
    uint128 bidPriceX64,
    uint128 askPriceX64,
    uint128 referencePriceX64,
    bytes calldata extensionData
  ) internal {
    _callExtensionsInOrder(
      BEFORE_SWAP_ORDER,
      abi.encodeCall(
        IMetricOmmExtensions.beforeSwap,
        (
          sender,
          recipient,
          zeroForOne,
          amountSpecified,
          priceLimitX64,
          packedSlot0Initial,
          bidPriceX64,
          askPriceX64,
          referencePriceX64,
          extensionData
        )
      )
    );
  }

  function _afterSwap(
    address sender,
    address recipient,
    bool zeroForOne,
    int128 amountSpecified,
    uint128 priceLimitX64,
    uint256 packedSlot0Initial,
    uint256 packedSlot0Final,
    uint128 bidPriceX64,
    uint128 askPriceX64,
    uint128 referencePriceX64,
    int128 amount0Delta,
    int128 amount1Delta,
    uint256 platformFeeAmount,
    bytes calldata extensionData
  ) internal {
    _callExtensionsInOrder(
      AFTER_SWAP_ORDER,
      abi.encodeCall(
        IMetricOmmExtensions.afterSwap,
        (
          sender,
          recipient,
          zeroForOne,
          amountSpecified,
          priceLimitX64,
          packedSlot0Initial,
          packedSlot0Final,
          bidPriceX64,
          askPriceX64,
          referencePriceX64,
          amount0Delta,
          amount1Delta,
          platformFeeAmount,
          extensionData
        )
      )
    );
  }
}
