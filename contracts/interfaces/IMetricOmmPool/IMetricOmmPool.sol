// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IMetricOmmPoolActions} from "./IMetricOmmPoolActions.sol";
import {IMetricOmmPoolCollectFees} from "./IMetricOmmPoolCollectFees.sol";
import {IMetricOmmPoolFactoryActions} from "./IMetricOmmPoolFactoryActions.sol";

/// @notice All constructor-set immutables of a `MetricOmmPool`, returned by `getImmutables()`.
/// @dev Scale multipliers convert native token amounts to internal precision; initial scaled per-share
///      amounts are `createPool` inputs (`initialAmount*PerShareE18`) times the matching multiplier.
struct PoolImmutables {
  address factory;
  address token0;
  address token1;
  /// @notice `10^(max(18, token0Decimals, token1Decimals) - token0Decimals)`.
  uint256 token0ScaleMultiplier;
  /// @notice `10^(max(18, token0Decimals, token1Decimals) - token1Decimals)`.
  uint256 token1ScaleMultiplier;
  /// @notice Token0 per share at empty-bin mint, in internal precision (`initialAmount0PerShareE18 × token0ScaleMultiplier`).
  uint256 initialScaledToken0PerShareE18;
  /// @notice Token1 per share at empty-bin mint, in internal precision (`initialAmount1PerShareE18 × token1ScaleMultiplier`).
  uint256 initialScaledToken1PerShareE18;
  uint256 minimalMintableLiquidity;
  address immutablePriceProvider;
  int256 lowestBin;
  int256 highestBin;
  address extension1;
  address extension2;
  address extension3;
  address extension4;
  address extension5;
  address extension6;
  address extension7;
  uint256 beforeAddLiquidityOrder;
  uint256 afterAddLiquidityOrder;
  uint256 beforeRemoveLiquidityOrder;
  uint256 afterRemoveLiquidityOrder;
  uint256 beforeSwapOrder;
  uint256 afterSwapOrder;
}

/// @title IMetricOmmPool
/// @notice Full external API of `MetricOmmPool` for typing integrators and the factory.
/// @dev Composition: user liquidity and swap (`IMetricOmmPoolActions`), factory fee sweep (`IMetricOmmPoolCollectFees`), factory-only pool controls (`IMetricOmmPoolFactoryActions`). User-facing custom errors are on `IMetricOmmPoolActions`; factory-only errors are on `IMetricOmmPoolFactoryActions`.
interface IMetricOmmPool is IMetricOmmPoolActions, IMetricOmmPoolCollectFees, IMetricOmmPoolFactoryActions {
  /// @notice Return every constructor-set immutable in a single call.
  /// @dev Immutables live in contract bytecode, not storage, so they cannot be read via EXTSLOAD.
  function getImmutables() external view returns (PoolImmutables memory);

  /// @notice Whether a live swap is executing and which price provider supplies its quotes.
  /// @return priceProvider Active price provider during swap; address(0) outside swap.
  function inSwap() external view returns (address priceProvider);

  /// @notice Live sell/buy prices (Q64.64) for token0 at the pool's current marginal bin position.
  /// @dev Sell = token0 → token1; buy = token1 → token0. Quotes include oracle spread, per-bin
  ///      additional fees, and notional fees — the prices a zero-size exact-in swap would execute at.
  ///      Consults the active price provider (same path as `swap`).
  /// @return sellPriceX64 Fee-adjusted sell price (token1 per token0, Q64.64).
  /// @return buyPriceX64 Fee-adjusted buy price (token1 per token0, Q64.64).
  function getSellAndBuyPrices() external returns (uint128 sellPriceX64, uint128 buyPriceX64);
}
