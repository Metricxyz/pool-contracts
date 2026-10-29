// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title IMetricOmmSwapCallback
/// @notice Callback invoked by the pool during `swap` so the caller can settle token flows with the pool.
/// @dev Implementations must treat `msg.sender` as the pool they intended to call (verify against a known pool).
///      Positive `amount0Delta` / `amount1Delta` mean the pool must receive that many tokens from the callback payer.
///      Negative deltas mean the pool sends tokens out (handled by the pool before this callback for output legs).
///      Both deltas may be zero if no settlement is required for that step.
interface IMetricOmmSwapCallback {
  // ============ Mutating ============

  /// @notice Settle token0 and token1 deltas for the swap on `msg.sender` (the pool).
  /// @param amount0Delta Token0 delta from pool perspective: positive = pool must receive from payer.
  /// @param amount1Delta Token1 delta from pool perspective: positive = pool must receive from payer.
  /// @param callbackData Opaque bytes forwarded from swap; conventionally ABI-encoded router context.
  function metricOmmSwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata callbackData) external;
}
