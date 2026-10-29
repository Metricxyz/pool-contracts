// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {IMetricOmmHooks} from "../../contracts/interfaces/hooks/IMetricOmmHooks.sol";
import {LiquidityDelta} from "../../contracts/types/PoolOperation.sol";

/// @title MockMetricHook
/// @notice Records which hook entrypoints were invoked (for tests).
contract MockMetricHook is IMetricOmmHooks {
  address public boundPool;

  bool public calledBeforeAddLiquidity;
  bool public calledAfterAddLiquidity;
  bool public calledBeforeRemoveLiquidity;
  bool public calledAfterRemoveLiquidity;
  bool public calledBeforeSwap;
  bool public calledAfterSwap;

  uint256 public lastPackedSlot0Initial;
  uint256 public lastPackedSlot0Final;
  uint128 public lastBidPriceX64;
  uint128 public lastAskPriceX64;

  modifier onlyPool() {
    require(msg.sender == boundPool, "OnlyPool");
    _;
  }

  function bindPool(address pool) external {
    require(boundPool == address(0) && pool != address(0), "PoolAlreadyBound");
    boundPool = pool;
  }

  function resetCalls() external {
    calledBeforeAddLiquidity = false;
    calledAfterAddLiquidity = false;
    calledBeforeRemoveLiquidity = false;
    calledAfterRemoveLiquidity = false;
    calledBeforeSwap = false;
    calledAfterSwap = false;
  }

  function beforeAddLiquidity(address, address, uint80, LiquidityDelta calldata, bytes calldata)
    external
    onlyPool
    returns (bytes4)
  {
    calledBeforeAddLiquidity = true;
    return IMetricOmmHooks.beforeAddLiquidity.selector;
  }

  function afterAddLiquidity(address, address, uint80, LiquidityDelta calldata, uint256, uint256, bytes calldata)
    external
    onlyPool
    returns (bytes4)
  {
    calledAfterAddLiquidity = true;
    return IMetricOmmHooks.afterAddLiquidity.selector;
  }

  function beforeRemoveLiquidity(address, address, uint80, LiquidityDelta calldata, bytes calldata)
    external
    onlyPool
    returns (bytes4)
  {
    calledBeforeRemoveLiquidity = true;
    return IMetricOmmHooks.beforeRemoveLiquidity.selector;
  }

  function afterRemoveLiquidity(address, address, uint80, LiquidityDelta calldata, uint256, uint256, bytes calldata)
    external
    onlyPool
    returns (bytes4)
  {
    calledAfterRemoveLiquidity = true;
    return IMetricOmmHooks.afterRemoveLiquidity.selector;
  }

  function beforeSwap(
    address,
    address,
    bool,
    int128,
    uint128,
    uint256 packedSlot0Initial,
    uint128 bidPriceX64,
    uint128 askPriceX64,
    bytes calldata
  ) external onlyPool returns (bytes4) {
    calledBeforeSwap = true;
    lastPackedSlot0Initial = packedSlot0Initial;
    lastBidPriceX64 = bidPriceX64;
    lastAskPriceX64 = askPriceX64;
    return IMetricOmmHooks.beforeSwap.selector;
  }

  function afterSwap(
    address,
    address,
    bool,
    int128,
    uint128,
    uint256 packedSlot0Initial,
    uint256 packedSlot0Final,
    uint128 bidPriceX64,
    uint128 askPriceX64,
    int128,
    int128,
    uint256,
    bytes calldata
  ) external onlyPool returns (bytes4) {
    calledAfterSwap = true;
    lastPackedSlot0Initial = packedSlot0Initial;
    lastPackedSlot0Final = packedSlot0Final;
    lastBidPriceX64 = bidPriceX64;
    lastAskPriceX64 = askPriceX64;
    return IMetricOmmHooks.afterSwap.selector;
  }
}
