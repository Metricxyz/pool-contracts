// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {MetricOmmPool} from "../contracts/MetricOmmPool.sol";
import {BinState} from "../contracts/types/PoolStorage.sol";
import {PoolExtensions, ExtensionOrders} from "../contracts/types/PoolExtensionsConfig.sol";

contract MetricOmmPoolHarness is MetricOmmPool {
  constructor(
    address _factory,
    address _admin,
    address _adminFeeDestination,
    address _token0,
    address _token1,
    address _priceProvider,
    bool immutablePriceProvider_,
    uint256 token0ScaleMultiplier,
    uint256 token1ScaleMultiplier,
    uint104 initialScaledAmount0PerShareE18,
    uint104 initialScaledAmount1PerShareE18,
    uint104 minimalMintableLiquidity,
    PoolExtensions memory extensions,
    ExtensionOrders memory extensionOrders,
    uint24 spreadFeeE6_,
    int24 _curBinDistFromProvidedPrice,
    BinState[] memory nonNegativeBinStates,
    BinState[] memory negativeBinStates,
    uint24 notionalFeeE8_
  )
    MetricOmmPool(
      _factory,
      _admin,
      _adminFeeDestination,
      _token0,
      _token1,
      _priceProvider,
      extensions,
      extensionOrders,
      immutablePriceProvider_,
      token0ScaleMultiplier,
      token1ScaleMultiplier,
      initialScaledAmount0PerShareE18,
      initialScaledAmount1PerShareE18,
      minimalMintableLiquidity,
      spreadFeeE6_,
      _curBinDistFromProvidedPrice,
      nonNegativeBinStates,
      negativeBinStates,
      notionalFeeE8_
    )
  {}

  function exposedSetCurBinIdx(int8 value) external {
    curBinIdx = value;
  }

  function exposedSetCurPosInBin(uint104 value) external {
    curPosInBin = value;
  }

  function exposedSetCurBinDistFromProvidedPriceE6(int24 value) external {
    curBinDistFromProvidedPriceE6 = value;
  }

  function exposedSetSpreadFeeE6(uint24 value) external {
    spreadFeeE6 = value;
  }

  function exposedSetPauseLevel(uint8 value) external {
    pauseLevel = value;
  }

  function exposedSetNotionalFeeE8(uint24 value) external {
    notionalFeeE8 = value;
  }

  function exposedSetTotalScaledToken0InBins(uint128 value) external {
    binTotals.scaledToken0 = value;
  }

  function exposedSetTotalScaledToken1InBins(uint128 value) external {
    binTotals.scaledToken1 = value;
  }

  function exposedSetPriceProvider(address value) external {
    priceProvider = value;
  }
}
