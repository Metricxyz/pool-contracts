// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IMetricOmmPoolActions} from "./IMetricOmmPoolActions.sol";
import {IMetricOmmPoolCollectFees} from "./IMetricOmmPoolCollectFees.sol";
import {IMetricOmmPoolFactoryActions} from "./IMetricOmmPoolFactoryActions.sol";

/// @notice All constructor-set immutables of a `MetricOmmPool`, returned by `getImmutables()`.
/// @dev Scale multipliers convert native token amounts to internal precision; initial scaled per-share
///      amounts are the `createPool` inputs `initialScaledAmount{0,1}PerE18Shares`, stored unchanged.
struct PoolImmutables {
  address factory;
  address token0;
  address token1;
  /// @notice `10^(max(18, token0Decimals, token1Decimals) - token0Decimals)`.
  uint256 token0ScaleMultiplier;
  /// @notice `10^(max(18, token0Decimals, token1Decimals) - token1Decimals)`.
  uint256 token1ScaleMultiplier;
  /// @notice Scaled token0 per `1e18` shares minted into an empty bin (pro-rated by position in the current bin).
  uint256 initialScaledToken0PerShareE18;
  /// @notice Scaled token1 per `1e18` shares minted into an empty bin (pro-rated by position in the current bin).
  uint256 initialScaledToken1PerShareE18;
  /// @notice Minimum non-zero share delta per bin, and minimum non-zero leftover after removal.
  uint256 minimalOperationalLiquidity;
  /// @notice Fixed provider, or zero in mutable mode (read the provider from storage slot 3).
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
/// @dev Composition: user liquidity and swap (`IMetricOmmPoolActions`), factory fee sweep (`IMetricOmmPoolCollectFees`), factory-only pool controls (`IMetricOmmPoolFactoryActions`). User-facing custom errors are on `IMetricOmmPoolActions` (`InvalidBinIndex` is also raised by factory-only `setBinAdditionalFees`); factory-only errors are on `IMetricOmmPoolFactoryActions`. The reentrancy error `ReentrancyGuardReentrantCall` is declared on `MetricReentrancyGuardTransient`.
interface IMetricOmmPool is IMetricOmmPoolActions, IMetricOmmPoolCollectFees, IMetricOmmPoolFactoryActions {
  /// @notice Return every constructor-set immutable in a single call.
  /// @dev Immutables live in contract bytecode, not storage, so they cannot be read via EXTSLOAD.
  function getImmutables() external view returns (PoolImmutables memory);

  /// @notice Whether a live swap or `getSellAndBuyPrices` is executing and which price provider supplies its quotes.
  /// @return priceProvider Active price provider during either; address(0) otherwise, including during simulation.
  function inSwap() external view returns (address priceProvider);

  /// @notice Live sell/buy prices (Q64.64) for token0 at the pool's current marginal bin position.
  /// @dev Informational only — not a guaranteed executable quote. Sell = token0 → token1; buy = token1 → token0.
  ///      Includes oracle spread, per-bin additional fees, and notional fees (zero-size exact-in marginal prices)
  ///      via the active price provider (same path as `swap`). For real pricing/execution decisions, call `swap`
  ///      and decide in the swap callback, or use the periphery quoter. The quote may update provider state.
  ///      Shares the swap reentrancy guard; callable while paused, but not during another guarded action.
  /// @return sellPriceX64 Fee-adjusted sell price (token1 per token0, Q64.64).
  /// @return buyPriceX64 Fee-adjusted buy price (token1 per token0, Q64.64).
  function getSellAndBuyPrices() external returns (uint128 sellPriceX64, uint128 buyPriceX64);
}
