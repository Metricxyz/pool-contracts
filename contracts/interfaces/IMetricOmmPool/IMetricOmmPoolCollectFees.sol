// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title IMetricOmmPoolCollectFees
/// @notice Allocate and distribute protocol and admin fee balances held on the pool.
/// @dev Collection is factory-only. Unpaid allocations retain their split
///      and are retried using the latest destinations. `ProtocolFeesCollected` reports amounts actually transferred.
interface IMetricOmmPoolCollectFees {
  // ============ Events ============

  event FeeTransferFailed(address indexed token, address indexed destination, uint256 amount);

  /// @notice Emitted after a successful fee collection pass.
  /// @param amount0ToProtocol Token0 amount sent to `protocolFeeDestination` (native).
  /// @param amount1ToProtocol Token1 amount sent to `protocolFeeDestination` (native).
  /// @param amount0ToAdmin Token0 amount sent to `adminFeeDestination` (native).
  /// @param amount1ToAdmin Token1 amount sent to `adminFeeDestination` (native).
  event ProtocolFeesCollected(
    uint256 amount0ToProtocol, uint256 amount1ToProtocol, uint256 amount0ToAdmin, uint256 amount1ToAdmin
  );

  // ============ Mutating ============

  /// @notice Allocate accrued fees using supplied rates, then attempt payouts including previously unpaid fees.
  /// @dev Pending balances retain scaled rounding remainders; transfer failures do not revert allocation.
  ///      Supported tokens must not move funds when reporting a failed transfer.
  /// @param protocolSpreadFeeE6 Protocol spread component in E6 at collection time (must match factory policy).
  /// @param adminSpreadFeeE6 Admin spread component in E6 at collection time.
  /// @param protocolNotionalFeeE8 Protocol notional component in E8 at collection time.
  /// @param adminNotionalFeeE8 Admin notional component in E8 at collection time.
  /// @param adminFeeDestination Recipient for the admin share of collected tokens (per factory configuration).
  /// @param protocolFeeDestination Recipient for the protocol share (the factory's `feeReceiver`).
  function collectFees(
    uint256 protocolSpreadFeeE6,
    uint256 adminSpreadFeeE6,
    uint256 protocolNotionalFeeE8,
    uint256 adminNotionalFeeE8,
    address adminFeeDestination,
    address protocolFeeDestination
  ) external;
}
