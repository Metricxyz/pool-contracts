// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {ExtensionOrders} from "./PoolExtensionsConfig.sol";

/// @notice Inputs used by `IMetricOmmPoolFactory.createPool`.
/// @dev Parameter selection guidelines (initial scaled densities, minimalOperationalLiquidity,
///      fees, bins, extensions, salt): see `docs/POOL_CONFIGURATION_AND_MANAGEMENT.md`.
struct PoolParameters {
  address token0;
  address token1;
  address priceProvider;
  /// @dev Up to seven extension contracts; stored as immutables on the pool in array order.
  address[] extensions;
  /// @dev Per-action extension call orders; each value encodes up to seven 3-bit extension indices.
  ExtensionOrders extensionOrders;
  /// @dev Per-extension initialization calldata; length must match `extensions`.
  bytes[] extensionInitData;
  /// @notice Delay for mutable provider rotation; `type(uint256).max` means immutable provider.
  uint256 priceProviderTimelock;
  address admin;
  /// @notice Token0 empty-bin mint density in **internal (scaled) precision** for `1e18` shares.
  /// @dev Stored on the pool as `INITIAL_SCALED_TOKEN_0_PER_SHARE_E18`. Liquidity uses
  ///      `amountScaled = initialScaledAmount0PerE18Shares * shares / 1e18`.
  ///      Whole tokens for `1e18` shares are `A0 = this / 10^D` where `D = max(18, d0, d1)`.
  ///      Must be non-zero and `< 2^128`.
  uint256 initialScaledAmount0PerE18Shares;
  /// @notice Token1 empty-bin mint density in **internal (scaled) precision** for `1e18` shares.
  /// @dev Same semantics as `initialScaledAmount0PerE18Shares` for token1.
  uint256 initialScaledAmount1PerE18Shares;
  /// @notice Minimum per-bin share delta for add/remove and minimum non-zero position size.
  /// @dev Must be at least `1e6 * 1e18 / min(initialScaledAmount0PerE18Shares, initialScaledAmount1PerE18Shares)`.
  uint256 minimalOperationalLiquidity;
  /// @notice Protocol spread fee for this pool in E6 (`1e6 = 100%`).
  /// @dev Must be `<= factory.maxProtocolSpreadFeeE6`. Values below `factory.spreadProtocolFeeE6` are clamped up to the default.
  uint24 protocolSpreadFeeE6;
  /// @notice Admin spread fee component in E6 (`1e6 = 100%`).
  uint24 adminSpreadFeeE6;
  /// @notice Protocol notional fee for this pool in E8 (`1e8 = 100%`).
  /// @dev Must be `<= factory.maxProtocolNotionalFeeE8`. Values below `factory.protocolNotionalFeeE8` are clamped up to the default.
  uint24 protocolNotionalFeeE8;
  /// @notice Admin notional fee component in E8 (`1e8 = 100%`).
  uint24 adminNotionalFeeE8;
  address adminFeeDestination;
  int24 curBinDistFromProvidedPriceE6;
  uint256[] nonNegativeBinDataArray;
  uint256[] negativeBinDataArray;
  /// @dev Caller-chosen CREATE2 salt input. The factory deploys with
  ///      `keccak256(abi.encode(salt, admin, adminFeeDestination, extensionInitData))`.
  bytes32 salt;
  /// @notice Bid/ask/ref asymmetry slack `m` in X8 (`M = 1 + m`). Must be non-zero and
  ///         `<= factory.onCreationMaxBidAskRefAsymmetryX8`.
  /// @dev `type(uint16).max` disables the provider bid/ask/ref asymmetry check on the pool.
  uint16 bidAskRefAsymmetryX8;
}
