// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {IMetricOmmHooks} from "../../../contracts/interfaces/hooks/IMetricOmmHooks.sol";
import {LiquidityDelta} from "../../../contracts/types/PoolOperation.sol";

/// @title RevertHook
/// @notice Test hook that always reverts from `beforeSwap` (core revert-bubbling tests).
contract RevertHook is IMetricOmmHooks {
  error DeliberateHookRevert();
  error DeliberateAfterSwapHookRevert();

  address public boundPool;

  modifier onlyPool() {
    require(msg.sender == boundPool, "OnlyPool");
    _;
  }

  function bindPool(address pool) external {
    require(boundPool == address(0) && pool != address(0), "PoolAlreadyBound");
    boundPool = pool;
  }

  function beforeAddLiquidity(address, address, uint80, LiquidityDelta calldata, bytes calldata)
    external
    pure
    returns (bytes4)
  {
    return IMetricOmmHooks.beforeAddLiquidity.selector;
  }

  function afterAddLiquidity(address, address, uint80, LiquidityDelta calldata, uint256, uint256, bytes calldata)
    external
    pure
    returns (bytes4)
  {
    return IMetricOmmHooks.afterAddLiquidity.selector;
  }

  function beforeRemoveLiquidity(address, address, uint80, LiquidityDelta calldata, bytes calldata)
    external
    pure
    returns (bytes4)
  {
    return IMetricOmmHooks.beforeRemoveLiquidity.selector;
  }

  function afterRemoveLiquidity(address, address, uint80, LiquidityDelta calldata, uint256, uint256, bytes calldata)
    external
    pure
    returns (bytes4)
  {
    return IMetricOmmHooks.afterRemoveLiquidity.selector;
  }

  function beforeSwap(address, address, bool, int128, uint128, uint256, uint128, uint128, bytes calldata)
    external
    pure
    returns (bytes4)
  {
    revert DeliberateHookRevert();
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
  ) external pure returns (bytes4) {
    revert DeliberateAfterSwapHookRevert();
  }
}
