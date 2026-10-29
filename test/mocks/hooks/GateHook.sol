// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {IMetricOmmHooks} from "../../../contracts/interfaces/hooks/IMetricOmmHooks.sol";
import {IMetricOmmPoolActions} from "../../../contracts/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {LiquidityDelta} from "../../../contracts/types/PoolOperation.sol";

/// @title GateHook
/// @notice Minimal test hook that gates deposit/swap via booleans (core plumbing tests only).
contract GateHook is IMetricOmmHooks {
  address public boundPool;
  bool public allowDeposit = true;
  bool public allowSwap = true;

  modifier onlyPool() {
    require(msg.sender == boundPool, "OnlyPool");
    _;
  }

  function bindPool(address pool) external {
    require(boundPool == address(0) && pool != address(0), "PoolAlreadyBound");
    boundPool = pool;
  }

  function setAllowDeposit(bool allowed) external {
    allowDeposit = allowed;
  }

  function setAllowSwap(bool allowed) external {
    allowSwap = allowed;
  }

  function beforeAddLiquidity(address, address, uint80, LiquidityDelta calldata, bytes calldata)
    external
    onlyPool
    returns (bytes4)
  {
    if (!allowDeposit) revert IMetricOmmPoolActions.NotAllowedToDeposit();
    return IMetricOmmHooks.beforeAddLiquidity.selector;
  }

  function afterAddLiquidity(address, address, uint80, LiquidityDelta calldata, uint256, uint256, bytes calldata)
    external
    onlyPool
    returns (bytes4)
  {
    return IMetricOmmHooks.afterAddLiquidity.selector;
  }

  function beforeRemoveLiquidity(address, address, uint80, LiquidityDelta calldata, bytes calldata)
    external
    onlyPool
    returns (bytes4)
  {
    return IMetricOmmHooks.beforeRemoveLiquidity.selector;
  }

  function afterRemoveLiquidity(address, address, uint80, LiquidityDelta calldata, uint256, uint256, bytes calldata)
    external
    onlyPool
    returns (bytes4)
  {
    return IMetricOmmHooks.afterRemoveLiquidity.selector;
  }

  function beforeSwap(address, address, bool, int128, uint128, uint256, uint128, uint128, bytes calldata)
    external
    onlyPool
    returns (bytes4)
  {
    if (!allowSwap) revert IMetricOmmPoolActions.NotAllowedToSwap();
    return IMetricOmmHooks.beforeSwap.selector;
  }

  function afterSwap(
    address,
    address,
    bool,
    int128,
    uint128,
    uint256,
    uint256,
    uint128,
    uint128,
    int128,
    int128,
    uint256,
    bytes calldata
  ) external onlyPool returns (bytes4) {
    return IMetricOmmHooks.afterSwap.selector;
  }
}
