// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title IMetricOmmPoolFactoryOwner
/// @notice Factory owner (`onlyOwner`) mutators on `MetricOmmPoolFactory` (excluding permissionless `createPool`, which stays on `IMetricOmmPoolFactory`).
/// @dev Events and custom errors declared here are only those emitted or exclusively reverted by owner mutators. Errors also used by `createPool`, the constructor, or pool-admin paths are declared on `IMetricOmmPoolFactory` only.
interface IMetricOmmPoolFactoryOwner {
  // ============ Events ============

  event SpreadProtocolFeeDefaultUpdated(uint24 oldFeeE6, uint24 newFeeE6);
  event ProtocolNotionalFeeDefaultUpdated(uint24 oldFeeE8, uint24 newFeeE8);
  event PoolProtocolSpreadFeeUpdated(address indexed pool, uint24 newProtocolSpreadFeeE6);
  event PoolProtocolNotionalFeeUpdated(address indexed pool, uint24 newProtocolNotionalFeeE8);
  event FeeCapsUpdated(
    uint24 maxProtocolSpreadFeeE6,
    uint24 maxAdminSpreadFeeE6,
    uint24 maxProtocolNotionalFeeE8,
    uint24 maxAdminNotionalFeeE8
  );
  event PoolDeployerSet(address indexed poolDeployer);
  event TokensCollected(address indexed token, address indexed to, uint256 amount);

  // ============ Errors ============

  error PoolDeployerAlreadySet();
  error FeeCapsExceedHardLimit();

  // ============ Mutating: Factory owner ============

  // --- Initialization and treasury ---

  /// @notice One-time wire of the pool deployer contract. Reverts `PoolDeployerAlreadySet` if non-zero.
  function setPoolDeployer(address _poolDeployer) external;

  /// @notice Rescue ERC20 held by the factory.
  function collectTokens(address token, address to, uint256 amount) external;

  /// @notice Rescue native ETH held by the factory.
  function collectEth(address payable to, uint256 amount) external;

  /// @notice Update per-component fee caps; each must be at most hard caps from `maxOwnerSpreadCapE6` / `maxOwnerNotionalCapE8`.
  function setFeeCaps(
    uint24 newMaxProtocolSpreadFeeE6,
    uint24 newMaxAdminSpreadFeeE6,
    uint24 newMaxProtocolNotionalFeeE8,
    uint24 newMaxAdminNotionalFeeE8
  ) external;

  // --- Default and per-pool protocol fees ---

  /// @notice Override protocol fee components for a specific `pool` within caps.
  function setPoolProtocolFee(address pool, uint24 newProtocolSpreadFeeE6, uint24 newProtocolNotionalFeeE8) external;

  /// @notice Update default protocol spread fee for future pools and existing pools that track the default.
  function setDefaultSpreadProtocolFeeE6(uint24 newFeeE6) external;

  /// @notice Update default protocol notional fee for future pools and existing pools that track the default.
  function setDefaultProtocolNotionalFeeE8(uint24 newFeeE8) external;

  // --- Protocol pause ---

  /// @notice Force pool to protocol pause level `2`.
  function protocolPausePool(address pool) external;

  /// @notice Clear protocol pause on `pool` when allowed by pause rules.
  /// @dev Intentionally transitions only **2 → 1**. Full resume to level **0** requires the pool admin to call `unpausePool`.
  function protocolUnpausePool(address pool) external;
}
