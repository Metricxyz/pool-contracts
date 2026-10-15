// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IMetricOmmPool, PoolImmutables} from "../../contracts/interfaces/IMetricOmmPool/IMetricOmmPool.sol";
import {IMetricOmmPoolActions} from "../../contracts/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @notice Swap callback that records pool.inSwap() and can attempt nested pool calls.
contract InSwapProbeCaller {
  using SafeERC20 for IERC20;
  using SafeCast for int256;

  address public immutable OWNER;

  address public providerSeenInCallback;

  error OnlyOwner();

  modifier onlyOwner() {
    if (msg.sender != OWNER) revert OnlyOwner();
    _;
  }

  constructor(address owner) {
    OWNER = owner;
  }

  function swap(address pool, address recipient, bool zeroForOne, int128 amountSpecified, uint128 priceLimitX64)
    external
    onlyOwner
    returns (int256 amount0Delta, int256 amount1Delta)
  {
    return IMetricOmmPoolActions(pool).swap(recipient, zeroForOne, amountSpecified, priceLimitX64, "", "");
  }

  function swapWithCallbackData(
    address pool,
    address recipient,
    bool zeroForOne,
    int128 amountSpecified,
    uint128 priceLimitX64,
    bytes calldata callbackData
  ) external onlyOwner returns (int256 amount0Delta, int256 amount1Delta) {
    return IMetricOmmPoolActions(pool).swap(recipient, zeroForOne, amountSpecified, priceLimitX64, callbackData, "");
  }

  function metricOmmSwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
    providerSeenInCallback = IMetricOmmPool(msg.sender).inSwap();

    if (data.length > 0) {
      (address pool, address recipient, bool zeroForOne, int128 amountSpecified, uint128 priceLimitX64) =
        abi.decode(data, (address, address, bool, int128, uint128));
      IMetricOmmPoolActions(pool).swap(recipient, zeroForOne, amountSpecified, priceLimitX64, "", "");
    }

    PoolImmutables memory immutables = IMetricOmmPool(msg.sender).getImmutables();
    if (amount0Delta > 0) {
      IERC20(immutables.token0).safeTransfer(msg.sender, amount0Delta.toUint256());
    }
    if (amount1Delta > 0) {
      IERC20(immutables.token1).safeTransfer(msg.sender, amount1Delta.toUint256());
    }
  }
}
