// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {IMetricOmmHooks} from "../interfaces/hooks/IMetricOmmHooks.sol";
import {LiquidityDelta} from "../types/PoolOperation.sol";

/// @title MetricHooks
/// @notice Permission flags and helpers for invoking per-pool hooks from `MetricOmmPool`.
library MetricHooks {
  uint16 public constant BEFORE_ADD_LIQUIDITY_FLAG = 1 << 0;
  uint16 public constant AFTER_ADD_LIQUIDITY_FLAG = 1 << 1;
  uint16 public constant BEFORE_REMOVE_LIQUIDITY_FLAG = 1 << 2;
  uint16 public constant AFTER_REMOVE_LIQUIDITY_FLAG = 1 << 3;
  uint16 public constant BEFORE_SWAP_FLAG = 1 << 4;
  uint16 public constant AFTER_SWAP_FLAG = 1 << 5;

  error InvalidHooksConfig();
  error InvalidHookResponse();
  error HookCallFailed();

  function hasPermission(uint16 permissions, uint16 flag) internal pure returns (bool) {
    return permissions & flag != 0;
  }

  function validateHooksConfig(address hooks, uint16 permissions) internal pure {
    if (hooks == address(0)) {
      if (permissions != 0) revert InvalidHooksConfig();
      return;
    }
    if (permissions == 0) revert InvalidHooksConfig();
  }

  function callHook(address hooks, bytes memory data) internal {
    (bool success, bytes memory result) = hooks.call(data);
    if (!success) {
      if (result.length > 0) {
        assembly ("memory-safe") {
          revert(add(result, 32), mload(result))
        }
      }
      revert HookCallFailed();
    }
    if (result.length < 32) {
      revert InvalidHookResponse();
    }
    bytes4 returnedSelector;
    assembly ("memory-safe") {
      returnedSelector := mload(add(result, 32))
    }
    bytes4 expectedSelector;
    assembly ("memory-safe") {
      expectedSelector := mload(add(data, 32))
    }
    if (returnedSelector != expectedSelector) {
      revert InvalidHookResponse();
    }
  }

  function beforeAddLiquidity(
    address hooks,
    uint16 permissions,
    address sender,
    address owner,
    uint80 salt,
    LiquidityDelta calldata deltas,
    bytes calldata hookData
  ) internal {
    if (hooks == address(0)) {
      return;
    }
    if (!hasPermission(permissions, BEFORE_ADD_LIQUIDITY_FLAG)) {
      return;
    }
    callHook(hooks, abi.encodeCall(IMetricOmmHooks.beforeAddLiquidity, (sender, owner, salt, deltas, hookData)));
  }

  function afterAddLiquidity(
    address hooks,
    uint16 permissions,
    address sender,
    address owner,
    uint80 salt,
    LiquidityDelta calldata deltas,
    uint256 amount0Added,
    uint256 amount1Added,
    bytes calldata hookData
  ) internal {
    if (hooks == address(0)) {
      return;
    }
    if (!hasPermission(permissions, AFTER_ADD_LIQUIDITY_FLAG)) {
      return;
    }
    callHook(
      hooks,
      abi.encodeCall(
        IMetricOmmHooks.afterAddLiquidity, (sender, owner, salt, deltas, amount0Added, amount1Added, hookData)
      )
    );
  }

  function beforeRemoveLiquidity(
    address hooks,
    uint16 permissions,
    address sender,
    address owner,
    uint80 salt,
    LiquidityDelta calldata deltas,
    bytes calldata hookData
  ) internal {
    if (hooks == address(0)) {
      return;
    }
    if (!hasPermission(permissions, BEFORE_REMOVE_LIQUIDITY_FLAG)) {
      return;
    }
    callHook(hooks, abi.encodeCall(IMetricOmmHooks.beforeRemoveLiquidity, (sender, owner, salt, deltas, hookData)));
  }

  function afterRemoveLiquidity(
    address hooks,
    uint16 permissions,
    address sender,
    address owner,
    uint80 salt,
    LiquidityDelta calldata deltas,
    uint256 amount0Removed,
    uint256 amount1Removed,
    bytes calldata hookData
  ) internal {
    if (hooks == address(0)) {
      return;
    }
    if (!hasPermission(permissions, AFTER_REMOVE_LIQUIDITY_FLAG)) {
      return;
    }
    callHook(
      hooks,
      abi.encodeCall(
        IMetricOmmHooks.afterRemoveLiquidity, (sender, owner, salt, deltas, amount0Removed, amount1Removed, hookData)
      )
    );
  }

  function beforeSwap(
    address hooks,
    uint16 permissions,
    address sender,
    address recipient,
    bool zeroForOne,
    int128 amountSpecified,
    uint128 priceLimitX64,
    uint256 packedSlot0Initial,
    uint128 bidPriceX64,
    uint128 askPriceX64,
    bytes calldata hookData
  ) internal {
    if (hooks == address(0)) {
      return;
    }
    if (!hasPermission(permissions, BEFORE_SWAP_FLAG)) {
      return;
    }
    callHook(
      hooks,
      abi.encodeCall(
        IMetricOmmHooks.beforeSwap,
        (
          sender,
          recipient,
          zeroForOne,
          amountSpecified,
          priceLimitX64,
          packedSlot0Initial,
          bidPriceX64,
          askPriceX64,
          hookData
        )
      )
    );
  }

  function afterSwap(
    address hooks,
    uint16 permissions,
    address sender,
    address recipient,
    bool zeroForOne,
    int128 amountSpecified,
    uint128 priceLimitX64,
    uint256 packedSlot0Initial,
    uint256 packedSlot0Final,
    uint128 bidPriceX64,
    uint128 askPriceX64,
    int128 amount0Delta,
    int128 amount1Delta,
    uint256 protocolFeeAmount,
    bytes calldata hookData
  ) internal {
    if (hooks == address(0)) {
      return;
    }
    if (!hasPermission(permissions, AFTER_SWAP_FLAG)) {
      return;
    }
    callHook(
      hooks,
      abi.encodeCall(
        IMetricOmmHooks.afterSwap,
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
          amount0Delta,
          amount1Delta,
          protocolFeeAmount,
          hookData
        )
      )
    );
  }
}
