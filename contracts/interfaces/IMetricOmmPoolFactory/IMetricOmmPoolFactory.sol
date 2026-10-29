// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {PoolParameters} from "../../types/FactoryOperation.sol";
import {ExtensionOrders} from "../../types/PoolExtensionsConfig.sol";
import {IMetricOmmPoolFactoryOwner} from "./IMetricOmmPoolFactoryOwner.sol";
import {IMetricOmmPoolFactoryPoolAdmin} from "./IMetricOmmPoolFactoryPoolAdmin.sol";

/// @title IMetricOmmPoolFactory
/// @notice Full factory API: pool creation, views, deployment validation, factory owner actions (`IMetricOmmPoolFactoryOwner`), and pool admin actions (`IMetricOmmPoolFactoryPoolAdmin`).
/// @dev `createPool` is permissionless once `poolDeployer` is set (not `onlyOwner`). Role interfaces hold only events and errors for that role’s mutators; views and `createPool` live here. Errors and constructor checks shared by `createPool` and one or both roles (`ProtocolFeeTooHigh`, `AdminFeeTooHigh`, `InvalidPauseTransition`) are declared only on this aggregate to avoid duplicate declarations across parents.
interface IMetricOmmPoolFactory is IMetricOmmPoolFactoryOwner, IMetricOmmPoolFactoryPoolAdmin {
  // ============ Events ============

  // --- Deployment ---

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
    uint256 initialAmount0PerShareE18,
    uint256 initialAmount1PerShareE18,
    uint256 minimalMintableLiquidity,
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

  // --- Deployment and validation (`createPool` and internal deploy path) ---

  error PoolDeployerNotSet();
  error InvalidTokenConfig();
  error InvalidAdmin();
  error InvalidPriceProvider();
  error PriceProviderTokenMismatch();
  error InvalidAdminFeeDestination();
  error InvalidInitialAmount();
  error InitialScaledAmountExceedsUint128(
    uint256 initialScaledAmount0PerShareE18, uint256 initialScaledAmount1PerShareE18
  );
  error InvalidMinimalMintableLiquidity();
  error BinIndexRangeExceedsInt8();
  error BinArraysEmpty();
  error BinLengthZero(int256 binIdx);
  error BinDistanceOutOfRange(int256 binIdx, int256 cumulativeDistanceE6);

  // --- Shared by `createPool` / constructor and owner or pool-admin paths (single declaration) ---

  error ProtocolFeeTooHigh();
  error AdminFeeTooHigh();
  error InvalidPauseTransition(uint8 currentLevel, uint8 requestedLevel);

  // ============ View ============

  // --- Hard limits ---

  /// @notice Hard spread fee cap limit used by `setFeeCaps` (`1e6 = 100%`, `2e5 = 20%`).
  function maxOwnerSpreadCapE6() external pure returns (uint24);

  /// @notice Hard notional fee cap limit used by `setFeeCaps` (`1e8 = 100%`, `1e6 = 1%`).
  function maxOwnerNotionalCapE8() external pure returns (uint24);

  // --- Global configuration ---

  /// @notice `MetricOmmPoolDeployer` authorized to create pools; set once by owner.
  function poolDeployer() external view returns (address);

  /// @notice Default protocol spread fee applied to new pools (E6).
  function spreadProtocolFeeE6() external view returns (uint24);

  /// @notice Default protocol notional fee applied to new pools (E8).
  function protocolNotionalFeeE8() external view returns (uint24);

  /// @notice Upper bound owner may set for per-pool protocol spread fee (E6).
  function maxProtocolSpreadFeeE6() external view returns (uint24);

  /// @notice Upper bound owner may set for per-pool admin spread fee (E6).
  function maxAdminSpreadFeeE6() external view returns (uint24);

  /// @notice Upper bound owner may set for per-pool protocol notional fee (E8).
  function maxProtocolNotionalFeeE8() external view returns (uint24);

  /// @notice Upper bound owner may set for per-pool admin notional fee (E8).
  function maxAdminNotionalFeeE8() external view returns (uint24);

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

  /// @notice Timestamp after which `executePoolPriceProviderUpdate` succeeds, if a proposal exists.
  function pendingPriceProviderExecuteAfter(address pool) external view returns (uint256);

  // ============ Mutating: Fee collection (permissionless) ============

  /// @notice Pull accrued protocol and admin fees from `pool` using stored `poolFeeConfig` splits.
  /// @dev Callable by any address (keepers, admins, or bots). Does not change fee configuration.
  function collectPoolFees(address pool) external;

  // ============ Mutating: Pool creation ============

  /// @notice Deploy a new pool via `poolDeployer` using validated `params`.
  /// @dev Exotic token pairs with a very large `decimals()` spread may result in revert (overflow) at creation, or may later result in revert (overflow) on
  ///      `addLiquidity` or `swap` when scaled amounts exceed internal `uint104`/`uint128` bounds.
  /// @return pool Address of the new pool proxy or implementation as deployed by the deployer.
  function createPool(PoolParameters calldata params) external returns (address pool);
}
