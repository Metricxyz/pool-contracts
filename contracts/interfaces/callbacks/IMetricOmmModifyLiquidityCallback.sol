// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title IMetricOmmModifyLiquidityCallback
/// @notice Callback invoked by the pool during `addLiquidity` so the caller can transfer tokens owed to the pool.
/// @dev Implementations must treat `msg.sender` as the pool address they intended to call (verify against a known pool).
///      After the callback returns, the pool checks balances: for each token, if the owed delta is positive, the pool
///      balance must have increased by at least that amount or the call reverts.
interface IMetricOmmModifyLiquidityCallback {
  // ============ Mutating ============

  /// @notice Pay token0 and token1 amounts owed to the pool after liquidity is added.
  /// @param amount0Delta Token0 amount the pool must receive (native smallest units).
  /// @param amount1Delta Token1 amount the pool must receive (native smallest units).
  /// @param callbackData Opaque bytes forwarded from addLiquidity; conventionally ABI-encoded router context.
  function metricOmmModifyLiquidityCallback(uint256 amount0Delta, uint256 amount1Delta, bytes calldata callbackData)
    external;
}
