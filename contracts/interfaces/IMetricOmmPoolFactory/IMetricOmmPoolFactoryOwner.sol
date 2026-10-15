// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title IMetricOmmPoolFactoryOwner
/// @notice Factory owner mutators on `MetricOmmPoolFactory` (excluding permissionless `createPool`, which stays on `IMetricOmmPoolFactory`). All mutators are gated by `requiresAuth` (owner or the configured `Authority`); the pure hard-limit views `hardMinBinDistanceLimitE6` / `hardMaxBinDistanceLimitE6` are also declared here.
/// @dev Events and custom errors declared here are only those emitted or exclusively reverted by owner mutators. Errors also used by `createPool` or pool-admin paths are declared on `IMetricOmmPoolFactory` only.
interface IMetricOmmPoolFactoryOwner {
  // ============ Events ============

  event SpreadProtocolFeeDefaultUpdated(uint24 newFeeE6);
  event ProtocolNotionalFeeDefaultUpdated(uint24 newFeeE8);
  event OnCreationMaxBidAskRefAsymmetryUpdated(uint16 newMaxX8);
  event PoolBidAskRefAsymmetryUpdated(address indexed pool, uint16 newBidAskRefAsymmetryX8);
  event PoolProtocolSpreadFeeUpdated(address indexed pool, uint24 newProtocolSpreadFeeE6);
  event PoolProtocolNotionalFeeUpdated(address indexed pool, uint24 newProtocolNotionalFeeE8);
  event FeeCapsUpdated(
    uint24 maxProtocolSpreadFeeE6,
    uint24 maxAdminSpreadFeeE6,
    uint24 maxProtocolNotionalFeeE8,
    uint24 maxAdminNotionalFeeE8
  );
  event PoolDeployerSet(address indexed poolDeployer);
  /// @dev `token == address(0)` denotes native ETH.
  event TokensCollected(address indexed token, address indexed to, uint256 amount);
  event FeeReceiverUpdated(address indexed newReceiver);
  event BinDistanceLimitsUpdated(int256 newMinBinDistanceE6, int256 newMaxBinDistanceE6);

  // ============ Errors ============

  error PoolDeployerAlreadySet();
  error FeeCapsExceedHardLimit();
  error InvalidFeeReceiver();
  error InvalidBinDistanceLimits();
  error ArrayLengthMismatch();

  // ============ Mutating: Factory owner ============

  // --- Initialization and treasury ---

  /// @notice One-time wire of the pool deployer contract. Reverts `PoolDeployerAlreadySet` if a non-zero deployer is already set.
  /// @dev Setting zero leaves the deployer unset and permits another call.
  function setPoolDeployer(address _poolDeployer) external;

  /// @notice Set the passive protocol-fee sink. Protocol fees route directly here at collection; the
  ///         owner never custodies them. Reverts `InvalidFeeReceiver` on the zero address.
  function setFeeReceiver(address newFeeReceiver) external;

  /// @notice Rescue ERC20 held by the factory. Stray-token only — protocol fees route straight to
  ///         `feeReceiver` at collection and no longer accumulate here. `amount == 0` collects the full balance.
  function collectTokens(address token, address to, uint256 amount) external;

  /// @notice Rescue native ETH held by the factory (stray funds only; `amount == 0` collects the full balance).
  function collectEth(address payable to, uint256 amount) external;

  /// @notice Update per-component fee caps; each must be at most the matching `maxOwner*Cap*` hard limit.
  /// @dev Clamps default protocol fees to the new caps; existing pools' stored fees are unchanged.
  function setFeeCaps(
    uint24 newMaxProtocolSpreadFeeE6,
    uint24 newMaxAdminSpreadFeeE6,
    uint24 newMaxProtocolNotionalFeeE8,
    uint24 newMaxAdminNotionalFeeE8
  ) external;

  // --- Default and per-pool protocol fees ---

  /// @notice Override protocol fee components for a specific `pool` within the current fee caps.
  /// @dev Bounded by the owner-adjustable `maxProtocolSpreadFeeE6` / `maxProtocolNotionalFeeE8`, not by the
  ///      `HARD_MAX_*` ceilings. Allocates accrued fees at the old rates first; accounting errors propagate
  ///      unchanged, while failed token payouts remain pending on the pool. Admin
  ///      components are clamped to the current admin caps if they now exceed them.
  function setPoolProtocolFee(address pool, uint24 newProtocolSpreadFeeE6, uint24 newProtocolNotionalFeeE8) external;

  /// @notice Batch form of `setPoolProtocolFee`, applied in array order.
  /// @dev Reverts `ArrayLengthMismatch` unless all three arrays are the same length. Atomic: any per-entry
  ///      revert rolls back the whole call, and the revert carries no entry index. Duplicates are allowed;
  ///      they re-run settlement and the last write wins. Failed payouts emit `FeeTransferFailed` on the pool.
  function setPoolProtocolFeeBatch(
    address[] calldata pools,
    uint24[] calldata newProtocolSpreadFeeE6s,
    uint24[] calldata newProtocolNotionalFeeE8s
  ) external;

  /// @notice Update default protocol spread fee floor for future pools (create-time values below this clamp up).
  function setDefaultSpreadProtocolFeeE6(uint24 newFeeE6) external;

  /// @notice Update default protocol notional fee floor for future pools (create-time values below this clamp up).
  function setDefaultProtocolNotionalFeeE8(uint24 newFeeE8) external;

  /// @notice Most permissive negative cumulative bin distance the owner may configure (E6).
  function hardMinBinDistanceLimitE6() external pure returns (int256);

  /// @notice Most permissive positive cumulative bin distance the owner may configure (E6).
  function hardMaxBinDistanceLimitE6() external pure returns (int256);

  /// @notice Update the inclusive cumulative bin distance bounds enforced at pool creation (E6).
  function setBinDistanceLimits(int128 newMinBinDistanceE6, int128 newMaxBinDistanceE6) external;

  /// @notice Update the cap on `bidAskRefAsymmetryX8` enforced at `createPool` for new pools.
  /// @dev Reverts `BidAskRefAsymmetryTooLow` on `0`: a zero cap admits no valid value, since `createPool`
  ///      rejects both values above the cap and `0` itself, and would block pool creation entirely.
  function setOnCreationMaxBidAskRefAsymmetryX8(uint16 newMaxX8) external;

  /// @notice Update bid/ask/ref asymmetry bound for an existing `pool`. Any non-zero `uint16` is valid.
  /// @dev Deliberately NOT gated by `onCreationMaxBidAskRefAsymmetryX8` — that cap bounds only what third-party
  ///      `createPool` callers may request, never the owner. Consequence: `type(uint16).max` disables the pool's
  ///      bid/ask/ref asymmetry check in a single owner call, with no cap-level event emitted.
  ///      `0` reverts `BidAskRefAsymmetryTooLow` because it makes practically every quote on the pool revert.
  function setPoolBidAskRefAsymmetryX8(address pool, uint16 newBidAskRefAsymmetryX8) external;

  /// @notice Batch form of `setPoolBidAskRefAsymmetryX8`, applied in array order.
  /// @dev Reverts `ArrayLengthMismatch` unless both arrays are the same length. Atomic: any per-entry revert
  ///      rolls back the whole call, and the revert carries no entry index. Duplicate entries are allowed; the last write wins.
  function setPoolBidAskRefAsymmetryX8Batch(address[] calldata pools, uint16[] calldata newBidAskRefAsymmetryX8s)
    external;

  // --- Protocol pause ---

  /// @notice Set pool to protocol pause level `2` (from `0` or `1`). Callable by the owner or an `Authority`-approved caller.
  function protocolPausePool(address pool) external;

  /// @notice Clear protocol pause on `pool` when allowed by pause rules.
  /// @dev Intentionally transitions only **2 → 1**. Full resume to level **0** requires the pool admin to call `unpausePool`.
  function protocolUnpausePool(address pool) external;
}
