// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IMetricOmmPoolActions} from "../../contracts/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {IMetricOmmPool, PoolImmutables} from "../../contracts/interfaces/IMetricOmmPool/IMetricOmmPool.sol";
import {LiquidityDelta} from "../../contracts/types/PoolOperation.sol";
import {IMetricOmmSwapCallback} from "../../contracts/interfaces/callbacks/IMetricOmmSwapCallback.sol";
import {
  IMetricOmmModifyLiquidityCallback
} from "../../contracts/interfaces/callbacks/IMetricOmmModifyLiquidityCallback.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @notice Test caller contract that implements callbacks
/// @dev Each user has their own TestCaller to execute pool operations
contract TestCaller is IMetricOmmSwapCallback, IMetricOmmModifyLiquidityCallback {
  using SafeERC20 for IERC20;
  using SafeCast for int256;

  address public immutable OWNER;

  error OnlyOwner();

  modifier onlyOwner() {
    if (msg.sender != OWNER) revert OnlyOwner();
    _;
  }

  constructor(address owner, address) {
    OWNER = owner;
  }

  /// @notice Execute a swap on the pool
  function swap(address pool, address recipient, bool zeroForOne, int128 amountSpecified, uint128 priceLimitX64)
    external
    onlyOwner
    returns (int256 amount0Delta, int256 amount1Delta)
  {
    return IMetricOmmPoolActions(pool).swap(recipient, zeroForOne, amountSpecified, priceLimitX64, "", "");
  }

  /// @notice Execute addLiquidity on the pool
  function addLiquidity(address pool, uint80 salt, LiquidityDelta memory deltas)
    external
    onlyOwner
    returns (uint256 amount0Added, uint256 amount1Added)
  {
    return IMetricOmmPoolActions(pool).addLiquidity(address(this), salt, deltas, "", "");
  }

  /// @notice Execute removeLiquidity on the pool
  function removeLiquidity(address pool, uint80 salt, LiquidityDelta memory deltas)
    external
    onlyOwner
    returns (uint256 amount0Removed, uint256 amount1Removed)
  {
    return IMetricOmmPoolActions(pool).removeLiquidity(address(this), salt, deltas, "");
  }

  /// @notice Swap callback - transfers tokens to the pool
  function metricOmmSwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external override {
    PoolImmutables memory immutables = IMetricOmmPool(msg.sender).getImmutables();
    address token0 = immutables.token0;
    address token1 = immutables.token1;
    // Transfer tokens owed to the pool
    if (amount0Delta > 0) {
      IERC20(token0).safeTransfer(msg.sender, amount0Delta.toUint256());
    }
    if (amount1Delta > 0) {
      IERC20(token1).safeTransfer(msg.sender, amount1Delta.toUint256());
    }
  }

  /// @inheritdoc IMetricOmmModifyLiquidityCallback
  function metricOmmModifyLiquidityCallback(uint256 amount0Delta, uint256 amount1Delta, bytes calldata)
    external
    override
  {
    PoolImmutables memory immutables = IMetricOmmPool(msg.sender).getImmutables();
    address token0 = immutables.token0;
    address token1 = immutables.token1;
    if (amount0Delta > 0) {
      IERC20(token0).safeTransfer(msg.sender, amount0Delta);
    }
    if (amount1Delta > 0) {
      IERC20(token1).safeTransfer(msg.sender, amount1Delta);
    }
  }
}
