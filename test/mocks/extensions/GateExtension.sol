// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IMetricOmmExtensions} from "../../../contracts/interfaces/extensions/IMetricOmmExtensions.sol";
import {IMetricOmmPoolActions} from "../../../contracts/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {LiquidityDelta} from "../../../contracts/types/PoolOperation.sol";

/// @title GateExtension
/// @notice Minimal test extension that gates deposit/swap via booleans (core plumbing tests only).
contract GateExtension is IMetricOmmExtensions {
  address public boundPool;
  bool public allowDeposit = true;
  bool public allowSwap = true;

  modifier onlyPool() {
    require(msg.sender == boundPool, "OnlyPool");
    _;
  }

  function bindPool(address pool) external {
    _bindPool(pool);
  }

  function initialize(address pool, bytes calldata) external returns (bytes4) {
    _bindPool(pool);
    return IMetricOmmExtensions.initialize.selector;
  }

  function _bindPool(address pool) private {
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
    view
    onlyPool
    returns (bytes4)
  {
    if (!allowDeposit) revert IMetricOmmPoolActions.NotAllowedToDeposit();
    return IMetricOmmExtensions.beforeAddLiquidity.selector;
  }

  function afterAddLiquidity(address, address, uint80, LiquidityDelta calldata, uint256, uint256, bytes calldata)
    external
    view
    onlyPool
    returns (bytes4)
  {
    return IMetricOmmExtensions.afterAddLiquidity.selector;
  }

  function beforeRemoveLiquidity(address, address, uint80, LiquidityDelta calldata, bytes calldata)
    external
    view
    onlyPool
    returns (bytes4)
  {
    return IMetricOmmExtensions.beforeRemoveLiquidity.selector;
  }

  function afterRemoveLiquidity(address, address, uint80, LiquidityDelta calldata, uint256, uint256, bytes calldata)
    external
    view
    onlyPool
    returns (bytes4)
  {
    return IMetricOmmExtensions.afterRemoveLiquidity.selector;
  }

  function beforeSwap(address, address, bool, int128, uint128, uint256, uint128, uint128, bytes calldata)
    external
    view
    onlyPool
    returns (bytes4)
  {
    if (!allowSwap) revert IMetricOmmPoolActions.NotAllowedToSwap();
    return IMetricOmmExtensions.beforeSwap.selector;
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
  ) external view onlyPool returns (bytes4) {
    return IMetricOmmExtensions.afterSwap.selector;
  }
}
