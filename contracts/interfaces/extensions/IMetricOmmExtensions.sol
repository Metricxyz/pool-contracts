// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {LiquidityDelta} from "../../types/PoolOperation.sol";

/// @title IMetricOmmExtensions
/// @notice Optional per-pool extension invoked by `MetricOmmPool` at liquidity and swap extension points.
/// @dev Each function below (except for `initialize`) is an extension point function: the pool calls it at the matching extension
///      point (before/after add, remove, swap). Return the ABI-encoded function selector on success.
///      `sender` is the pool caller. In `simulateSwapAndRevert`, `sender` and the bid/ask/reference prices are
///      caller-supplied (not read from the price provider) and all effects revert.
interface IMetricOmmExtensions {
  /// @notice One-time extension setup invoked by the factory immediately after pool deployment.
  /// @dev Runs before factory registration and per-pool metadata are stored; authenticate the factory caller.
  function initialize(address pool, bytes calldata data) external returns (bytes4);

  function beforeAddLiquidity(
    address sender,
    address owner,
    uint80 salt,
    LiquidityDelta calldata deltas,
    bytes calldata extensionData
  ) external returns (bytes4);

  function afterAddLiquidity(
    address sender,
    address owner,
    uint80 salt,
    LiquidityDelta calldata deltas,
    uint256 amount0Added,
    uint256 amount1Added,
    bytes calldata extensionData
  ) external returns (bytes4);

  function beforeRemoveLiquidity(
    address sender,
    address owner,
    uint80 salt,
    LiquidityDelta calldata deltas,
    bytes calldata extensionData
  ) external returns (bytes4);

  function afterRemoveLiquidity(
    address sender,
    address owner,
    uint80 salt,
    LiquidityDelta calldata deltas,
    uint256 amount0Removed,
    uint256 amount1Removed,
    bytes calldata extensionData
  ) external returns (bytes4);

  function beforeSwap(
    address sender,
    address recipient,
    bool zeroForOne,
    int128 amountSpecified,
    uint128 priceLimitX64,
    uint256 packedSlot0Initial,
    uint128 bidPriceX64,
    uint128 askPriceX64,
    uint128 referencePriceX64,
    bytes calldata extensionData
  ) external returns (bytes4);

  function afterSwap(
    address sender,
    address recipient,
    bool zeroForOne,
    int128 amountSpecified,
    uint128 priceLimitX64,
    uint256 packedSlot0Initial,
    uint256 packedSlot0Final,
    uint128 bidPriceX64,
    uint128 askPriceX64,
    uint128 referencePriceX64,
    int128 amount0Delta,
    int128 amount1Delta,
    uint256 platformFeeAmount,
    bytes calldata extensionData
  ) external returns (bytes4);
}
