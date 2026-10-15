// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {PoolParameters} from "../../types/FactoryOperation.sol";
import {ExtensionOrders} from "../../types/PoolExtensionsConfig.sol";
import {IMetricOmmPoolFactoryOwner} from "./IMetricOmmPoolFactoryOwner.sol";
import {IMetricOmmPoolFactoryPoolAdmin} from "./IMetricOmmPoolFactoryPoolAdmin.sol";

/// @title IMetricOmmPoolFactory
/// @notice Full factory API: pool creation, views, deployment validation, factory owner actions (`IMetricOmmPoolFactoryOwner`), and pool admin actions (`IMetricOmmPoolFactoryPoolAdmin`).
/// @dev `createPool` is permissionless once `poolDeployer` is set (not `onlyOwner`). Role interfaces hold that role’s mutators, events and errors; `createPool` and most views live here. Errors used by more than one path (`ProtocolFeeTooHigh`, `AdminFeeTooHigh`, `InvalidPauseTransition`, `BidAskRefAsymmetryTooLow`) are declared only on this aggregate to avoid duplicate declarations across parents.
interface IMetricOmmPoolFactory is IMetricOmmPoolFactoryOwner, IMetricOmmPoolFactoryPoolAdmin {
  // ============ Events ============

  // --- Deployment ---

  /// @dev Protocol fee components are the effective values after applying factory floors, not the raw inputs.
  event PoolCreated(
    address indexed poolAddress,
    address indexed token0,
    address indexed token1,
    uint256 poolIdx,
    address factory,
    address admin,
    address priceProvider,
    address[] extensions,
    ExtensionOrders extensionOrders,
    uint256 priceProviderTimelock,
    uint256 initialScaledAmount0PerE18Shares,
    uint256 initialScaledAmount1PerE18Shares,
    uint256 minimalOperationalLiquidity,
    uint24 spreadProtocolFeeE6,
    uint24 protocolNotionalFeeE8,
    uint24 adminSpreadFeeE6,
    uint24 adminNotionalFeeE8,
    address adminFeeDestination,
    int24 curBinDistFromProvidedPriceE6,
    uint256[] nonNegativeBinDataArray,
    uint256[] negativeBinDataArray
  );

  // ============ Errors ============

  // --- Deployment and validation (`createPool`; several also revert from pool-admin mutators) ---

  error PoolDeployerNotSet();
  error InvalidTokenConfig();
  error InvalidAdmin();
  error InvalidPriceProvider();
  error PriceProviderTokenMismatch();
  error InvalidAdminFeeDestination();
  error InvalidInitialAmount();
  error MinimalOperationalLiquidityTooSmallComparedToInitialScaledTokenAmounts(
    uint256 provided, uint256 minimalRequired
  );
  /// @notice More bins were supplied on one side of the grid than a bin index can address.
  error BinIndexRangeExceededInt16();
  error BinArraysEmpty();
  error BinLengthZero(int256 binIdx);
  error BinDistanceOutOfRange(int256 binIdx, int256 cumulativeDistanceE6);
  error BidAskRefAsymmetryTooHigh();

  // --- Shared across two or more of `createPool`, owner and pool-admin paths (single declaration) ---

  error ProtocolFeeTooHigh();
  error AdminFeeTooHigh();
  error InvalidPauseTransition(uint8 currentLevel, uint8 requestedLevel);
  error BidAskRefAsymmetryTooLow();

  // ============ View ============

  /// @notice Passive protocol-fee sink; protocol fees route here at collection. Owner-settable.
  function feeReceiver() external view returns (address);

  // --- Hard limits ---

  /// @notice Hard protocol spread fee cap limit used by `setFeeCaps` (`1e6 = 100%`, `5e5 = 50%`).
  function maxOwnerProtocolSpreadCapE6() external pure returns (uint24);

  /// @notice Hard admin spread fee cap limit used by `setFeeCaps` (`1e6 = 100%`, `5e5 = 50%`).
  function maxOwnerAdminSpreadCapE6() external pure returns (uint24);

  /// @notice Hard protocol notional fee cap limit used by `setFeeCaps` (`1e8 = 100%`, `1e6 = 1%`).
  function maxOwnerProtocolNotionalCapE8() external pure returns (uint24);

  /// @notice Hard admin notional fee cap limit used by `setFeeCaps` (`1e8 = 100%`, `1e6 = 1%`).
  function maxOwnerAdminNotionalCapE8() external pure returns (uint24);

  // --- Global configuration ---

  /// @notice `MetricOmmPoolDeployer` authorized to create pools; set once via `setPoolDeployer` (owner or `Authority`).
  function poolDeployer() external view returns (address);

  /// @notice Default protocol spread fee floor applied to new pools (E6).
  function spreadProtocolFeeE6() external view returns (uint24);

  /// @notice Default protocol notional fee floor applied to new pools (E8).
  function protocolNotionalFeeE8() external view returns (uint24);

  /// @notice Owner-set cap on per-pool protocol spread fee (E6).
  function maxProtocolSpreadFeeE6() external view returns (uint24);

  /// @notice Owner-set cap on per-pool admin spread fee (E6).
  function maxAdminSpreadFeeE6() external view returns (uint24);

  /// @notice Owner-set cap on per-pool protocol notional fee (E8).
  function maxProtocolNotionalFeeE8() external view returns (uint24);

  /// @notice Owner-set cap on per-pool admin notional fee (E8).
  function maxAdminNotionalFeeE8() external view returns (uint24);

  /// @notice Cap for `bidAskRefAsymmetryX8` slack `m` in X8 (`M = 1 + m`), enforced only at `createPool`.
  function onCreationMaxBidAskRefAsymmetryX8() external view returns (uint16);

  /// @notice Inclusive lower bound on the cumulative bin distance enforced at pool creation (E6).
  function minBinDistanceE6() external view returns (int128);

  /// @notice Inclusive upper bound on the cumulative bin distance enforced at pool creation (E6).
  function maxBinDistanceE6() external view returns (int128);

  /// @notice All four fee caps in one call.
  /// @return maxProtocolSpreadFeeE6 Cap for protocol spread (E6).
  /// @return maxAdminSpreadFeeE6 Cap for admin spread (E6).
  /// @return maxProtocolNotionalFeeE8 Cap for protocol notional (E8).
  /// @return maxAdminNotionalFeeE8 Cap for admin notional (E8).
  function getFeeCaps()
    external
    view
    returns (
      uint24 maxProtocolSpreadFeeE6,
      uint24 maxAdminSpreadFeeE6,
      uint24 maxProtocolNotionalFeeE8,
      uint24 maxAdminNotionalFeeE8
    );

  // --- Pool registry and metadata ---

  /// @notice Monotonic pool creation counter; next index to assign is this value. Starts at 1; index 0 is reserved.
  function nextPoolIdx() external view returns (uint256);

  /// @notice Pool deployed at creation order `idx`. Index 0 is reserved and never assigned.
  function idxToPool(uint256 idx) external view returns (address);

  /// @notice Creation index for `pool`; zero if the pool was not created by this factory.
  function poolToIdx(address pool) external view returns (uint256);

  /// @notice Whether `pool` was deployed and registered by this factory.
  /// @return true if `pool` is a pool deployed/tracked by this factory.
  function isPool(address pool) external view returns (bool);

  /// @notice Persisted protocol and admin fee components for `pool`.
  function poolFeeConfig(address pool)
    external
    view
    returns (
      uint24 protocolSpreadFeeE6,
      uint24 adminSpreadFeeE6,
      uint24 protocolNotionalFeeE8,
      uint24 adminNotionalFeeE8
    );

  /// @notice Admin fee sweep destination for `pool`.
  function poolAdminFeeDestination(address pool) external view returns (address);

  /// @notice Current pool admin for governance actions on `pool`.
  function poolAdmin(address pool) external view returns (address);

  /// @notice Pending admin during two-step transfer, or zero if none.
  function pendingPoolAdmin(address pool) external view returns (address);

  /// @notice Timelock duration in seconds for price provider updates; `type(uint256).max` if immutable.
  function priceProviderTimelock(address pool) external view returns (uint256);

  /// @notice Proposed next price provider after `proposePoolPriceProvider`, or zero if none.
  function pendingPriceProvider(address pool) external view returns (address);

  /// @notice Timestamp from which `executePoolPriceProviderUpdate` succeeds, if a proposal exists.
  function pendingPriceProviderExecuteAfter(address pool) external view returns (uint256);

  // ============ Mutating: Fee collection (permissionless) ============

  /// @notice Pull accrued protocol and admin fees from `pool` using stored `poolFeeConfig` splits.
  /// @dev Callable by any address (keepers, admins, or bots). Does not change fee configuration.
  /// @dev Pool accounting errors propagate; rejected token payouts remain pending on the pool.
  function collectPoolFees(address pool) external;

  // ============ Mutating: Pool creation ============

  /// @notice Deploy a new pool via `poolDeployer` using validated `params`.
  /// @dev Callers should follow `docs/POOL_CONFIGURATION_AND_MANAGEMENT.md` when choosing
  ///      `PoolParameters` (densities, minimalOperationalLiquidity, fees, bins, extensions, salt).
  ///      Exotic token pairs with a very large `decimals()` spread may result in revert (overflow) at creation, or may later result in revert on
  ///      `addLiquidity` (`SharesAmountTooLarge` or `SafeCast` overflow) or `swap` (`OverflowedOnFittingBinBalances`) when scaled amounts exceed internal `uint104`/`uint128` bounds.
  /// @return pool Address of the pool the deployer created with `CREATE2`.
  function createPool(PoolParameters calldata params) external returns (address pool);
}
