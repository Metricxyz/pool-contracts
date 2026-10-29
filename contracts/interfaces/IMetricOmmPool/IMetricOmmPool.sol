// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {IMetricOmmPoolActions} from "./IMetricOmmPoolActions.sol";
import {IMetricOmmPoolCollectFees} from "./IMetricOmmPoolCollectFees.sol";
import {IMetricOmmPoolFactoryActions} from "./IMetricOmmPoolFactoryActions.sol";

/// @notice All constructor-set immutables of a `MetricOmmPool`, returned by `getImmutables()`.
struct PoolImmutables {
  address factory;
  address token0;
  address token1;
  uint256 token0ScaleMultiplier;
  uint256 token1ScaleMultiplier;
  uint256 initialScaledToken0PerShareE18;
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
}
