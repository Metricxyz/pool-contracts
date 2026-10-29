// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title IMetricOmmPoolCollectFees
/// @notice Factory-only extension to distribute accrued protocol and admin fee balances held on the pool.
/// @dev Only `MetricOmmPoolFactory` should call this; the pool enforces `msg.sender == FACTORY`. Emits `ProtocolFeesCollected` with token amounts allocated to protocol vs admin destinations according to the rates passed in.
interface IMetricOmmPoolCollectFees {
  // ============ Events ============

  /// @notice Emitted after a successful fee collection pass.
  /// @param amount0ToProtocol Token0 amount sent to protocol recipients (scaled path as implemented by pool).
  /// @param amount1ToProtocol Token1 amount sent to protocol recipients.
  /// @param amount0ToAdmin Token0 amount allocated to the admin leg for this collection.
  /// @param amount1ToAdmin Token1 amount allocated to the admin leg for this collection.
  event ProtocolFeesCollected(
    uint256 amount0ToProtocol, uint256 amount1ToProtocol, uint256 amount0ToAdmin, uint256 amount1ToAdmin
  );

  // ============ Mutating ============

  /// @notice Distribute accrued protocol and admin fee balances held by the pool using supplied component rates.
  /// @param protocolSpreadFeeE6 Protocol spread component in E6 at collection time (must match factory policy).
  /// @param adminSpreadFeeE6 Admin spread component in E6 at collection time.
  /// @param protocolNotionalFeeE8 Protocol notional component in E8 at collection time.
  /// @param adminNotionalFeeE8 Admin notional component in E8 at collection time.
  /// @param adminFeeDestination Recipient for the admin share of collected tokens (per factory configuration).
  function collectFees(
    uint256 protocolSpreadFeeE6,
    uint256 adminSpreadFeeE6,
    uint256 protocolNotionalFeeE8,
    uint256 adminNotionalFeeE8,
    address adminFeeDestination
  ) external;
}
