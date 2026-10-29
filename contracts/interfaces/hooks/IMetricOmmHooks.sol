// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {LiquidityDelta} from "../../types/PoolOperation.sol";

/// @title IMetricOmmHooks
/// @notice Optional per-pool hooks invoked by `MetricOmmPool` at liquidity and swap boundaries.
/// @dev Only callable by the pool (`msg.sender` must be the pool address). Return the function selector on success.
interface IMetricOmmHooks {
  function beforeAddLiquidity(
    address sender,
    address owner,
    uint80 salt,
    LiquidityDelta calldata deltas,
    bytes calldata hookData
  ) external returns (bytes4);

  function afterAddLiquidity(
    address sender,
    address owner,
    uint80 salt,
    LiquidityDelta calldata deltas,
    uint256 amount0Added,
    uint256 amount1Added,
    bytes calldata hookData
  ) external returns (bytes4);

  function beforeRemoveLiquidity(
    address sender,
    address owner,
    uint80 salt,
    LiquidityDelta calldata deltas,
    bytes calldata hookData
  ) external returns (bytes4);

  function afterRemoveLiquidity(
    address sender,
    address owner,
    uint80 salt,
    LiquidityDelta calldata deltas,
    uint256 amount0Removed,
    uint256 amount1Removed,
    bytes calldata hookData
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
    bytes calldata hookData
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
    int128 amount0Delta,
    int128 amount1Delta,
    uint256 protocolFeeAmount,
    bytes calldata hookData
  ) external returns (bytes4);
}
