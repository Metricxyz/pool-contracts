// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IMetricOmmExtensions} from "../../contracts/interfaces/extensions/IMetricOmmExtensions.sol";
import {LiquidityDelta} from "../../contracts/types/PoolOperation.sol";

/// @title MockMetricExtension
/// @notice Records which extension point functions were invoked (for tests).
contract MockMetricExtension is IMetricOmmExtensions {
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
    return IMetricOmmExtensions.beforeAddLiquidity.selector;
  }

  function afterAddLiquidity(address, address, uint80, LiquidityDelta calldata, uint256, uint256, bytes calldata)
    external
    onlyPool
    returns (bytes4)
  {
    calledAfterAddLiquidity = true;
    return IMetricOmmExtensions.afterAddLiquidity.selector;
  }

  function beforeRemoveLiquidity(address, address, uint80, LiquidityDelta calldata, bytes calldata)
    external
    onlyPool
    returns (bytes4)
  {
    calledBeforeRemoveLiquidity = true;
    return IMetricOmmExtensions.beforeRemoveLiquidity.selector;
  }

  function afterRemoveLiquidity(address, address, uint80, LiquidityDelta calldata, uint256, uint256, bytes calldata)
    external
    onlyPool
    returns (bytes4)
  {
    calledAfterRemoveLiquidity = true;
    return IMetricOmmExtensions.afterRemoveLiquidity.selector;
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
    return IMetricOmmExtensions.beforeSwap.selector;
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
    return IMetricOmmExtensions.afterSwap.selector;
  }
}
