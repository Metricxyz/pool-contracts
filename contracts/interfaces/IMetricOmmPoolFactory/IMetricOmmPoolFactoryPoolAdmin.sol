// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title IMetricOmmPoolFactoryPoolAdmin
/// @notice Per-pool admin (`poolAdmin[pool] == msg.sender`) mutators on `MetricOmmPoolFactory`.
/// @dev Events and custom errors declared here are only those emitted or exclusively reverted by pool-admin mutators. Errors also used by `createPool` or the factory owner are declared on `IMetricOmmPoolFactory` only.
interface IMetricOmmPoolFactoryPoolAdmin {
  // ============ Events ============

  event PoolAdminSpreadFeeUpdated(address indexed pool, uint24 newAdminSpreadFeeE6);
  event PoolAdminNotionalFeeUpdated(address indexed pool, uint24 newAdminNotionalFeeE8);
  event PoolAdminFeeDestinationUpdated(address indexed pool, address newAdminFeeDestination);
  event PoolAdminTransferred(address indexed pool, address indexed previousAdmin, address indexed newAdmin);
  event PoolAdminTransferProposed(address indexed pool, address indexed currentAdmin, address indexed newAdmin);
  event PoolAdminTransferCancelled(address indexed pool, address indexed cancelledPendingAdmin);
  event PoolPriceProviderChangeProposed(
    address indexed pool, address indexed currentPriceProvider, address indexed newPriceProvider, uint256 executeAfter
  );
  event PoolPriceProviderUpdated(address indexed pool, address indexed newPriceProvider);

  // ============ Errors ============

  error NotPoolAdmin();
  error NoPriceProviderChangeProposed();
  /// @notice Thrown when scheduling or applying a price provider rotation for a pool whose oracle is immutable at creation.
  error PriceProviderImmutable();
  error PriceProviderTimelockNotElapsed(uint256 executeAfter, uint256 currentTimestamp);
  error NoPendingPoolAdminTransfer();
  error NotPendingPoolAdmin(address pool, address caller, address pendingAdmin);

  // ============ Mutating: Pool admin ============

  // --- Fees and per-bin ---

  /// @notice Update admin spread and notional components for `pool` within configured caps.
  function setPoolAdminFees(address pool, uint24 newAdminSpreadFeeE6, uint24 newAdminNotionalFeeE8) external;

  /// @notice Update admin fee destination for `pool`.
  function setPoolAdminFeeDestination(address pool, address newAdminFeeDestination) external;

  /// @notice Configure per-bin additional fees on `pool`.
  function setPoolBinAdditionalFees(address pool, int8 bin, uint16 addFeeBuyE6, uint16 addFeeSellE6) external;

  // --- Pause (admin level) ---

  /// @notice Set pool to admin pause level `1`.
  function pausePool(address pool) external;

  /// @notice Clear admin pause on `pool` when allowed by pause rules.
  function unpausePool(address pool) external;

  // --- Price provider (mutable oracle only) ---

  /// @notice Schedule price provider rotation for `pool` after timelock; reverts if the pool oracle is immutable.
  function proposePoolPriceProvider(address pool, address newPriceProvider) external;

  /// @notice Finalize scheduled provider update after `pendingPriceProviderExecuteAfter`.
  function executePoolPriceProviderUpdate(address pool) external;

  // --- Admin transfer ---

  /// @notice Start two-step admin transfer to `newAdmin`.
  function proposePoolAdminTransfer(address pool, address newAdmin) external;

  /// @notice Accept pending admin role for `pool` (must be pending admin).
  function acceptPoolAdmin(address pool) external;

  /// @notice Cancel a pending admin transfer for `pool`.
  function cancelPoolAdminTransfer(address pool) external;
}
