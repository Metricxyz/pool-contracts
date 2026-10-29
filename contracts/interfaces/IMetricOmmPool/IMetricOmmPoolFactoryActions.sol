// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title IMetricOmmPoolFactoryActions
/// @notice Entrypoints on `MetricOmmPool` that only the pool factory may call (`msg.sender == FACTORY`).
/// @dev Integrators must use `MetricOmmPoolFactory` (owner or pool admin flows); calling these on the pool directly reverts with `OnlyFactory` unless `msg.sender` is the factory contract address.
interface IMetricOmmPoolFactoryActions {
  // ============ Events ============

  /// @notice Emitted when total spread fee on the pool is updated.
  /// @param spreadFeeE6 New aggregate spread fee in E6 (`1e6 = 100%`).
  event SpreadFeeUpdated(uint24 spreadFeeE6);

  /// @notice Emitted when total notional fee on the pool is updated.
  /// @param notionalFeeE8 New aggregate notional fee in E8 (`1e8 = 100%`).
  event NotionalFeeUpdated(uint24 notionalFeeE8);

  /// @notice Emitted when pause level changes.
  /// @param previousLevel Prior pause level (`0` active, `1` admin pause, `2` protocol pause).
  /// @param newLevel New pause level after the update.
  event PauseLevelUpdated(uint8 previousLevel, uint8 newLevel);

  /// @notice Emitted when the mutable price provider address stored on the pool is updated.
  /// @param newPriceProvider New active `IPriceProvider` (immutable pools never emit this from rotation).
  event PriceProviderUpdated(address indexed newPriceProvider);

  /// @notice Emitted when per-bin additional spread fees are set.
  /// @param bin Bin index whose overrides were updated.
  /// @param addFeeBuyE6 Additional buy-side spread fee in E6 on top of base spread.
  /// @param addFeeSellE6 Additional sell-side spread fee in E6 on top of base spread.
  event BinAdditionalFeesUpdated(int8 indexed bin, uint16 addFeeBuyE6, uint16 addFeeSellE6);

  // ============ Errors ============

  /// @notice Thrown when `msg.sender` is not the pool factory.
  error OnlyFactory();

  /// @notice Thrown when `setPause` is called with a level outside `0..2`.
  error InvalidPauseLevel();

  // ============ Mutating ============

  /// @notice Set aggregate pool spread and notional fee rates (sum of protocol + admin components).
  /// @param newSpreadFeeE6 Total spread fee in E6 (`1e6 = 100%`).
  /// @param newNotionalFeeE8 Total notional fee in E8 (`1e8 = 100%`).
  function setPoolFees(uint24 newSpreadFeeE6, uint24 newNotionalFeeE8) external;

  /// @notice Set pool pause level (`0` active, `1` admin paused, `2` protocol paused).
  /// @param newLevel Pause level enforced by the pool; must be at most `2`.
  function setPause(uint8 newLevel) external;

  /// @notice Set per-bin additional buy and sell spread fees in E6 on top of base spread.
  /// @param bin Bin index within the pool configured bin range.
  /// @param addFeeBuyE6 Additional fee on buys into the bin (E6).
  /// @param addFeeSellE6 Additional fee on sells out of the bin (E6).
  function setBinAdditionalFees(int8 bin, uint16 addFeeBuyE6, uint16 addFeeSellE6) external;

  /// @notice Update the pool active price provider (only for pools created with a mutable provider).
  /// @param newPriceProvider New provider contract; must pass pool validation (tokens, implementation).
  function setPriceProvider(address newPriceProvider) external;
}
