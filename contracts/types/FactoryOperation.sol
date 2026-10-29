// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {ExtensionOrders} from "./PoolExtensionsConfig.sol";

/// @notice Inputs used by `IMetricOmmPoolFactory.createPool`.
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
  /// @notice Initial token0 per share in external units before scale multiplier.
  uint256 initialAmount0PerShareE18;
  /// @notice Initial token1 per share in external units before scale multiplier.
  uint256 initialAmount1PerShareE18;
  uint256 minimalMintableLiquidity;
  /// @notice Admin spread fee component in E6 (`1e6 = 100%`).
  uint24 adminSpreadFeeE6;
  /// @notice Admin notional fee component in E8 (`1e8 = 100%`).
  uint24 adminNotionalFeeE8;
  address adminFeeDestination;
  int24 curBinDistFromProvidedPriceE6;
  uint256[] nonNegativeBinDataArray;
  uint256[] negativeBinDataArray;
  bytes32 salt;
}
