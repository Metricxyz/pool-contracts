// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {MetricOmmPool} from "../contracts/MetricOmmPool.sol";
import {BinState} from "../contracts/types/PoolStorage.sol";
import {PoolExtensions, ExtensionOrders} from "../contracts/types/PoolExtensionsConfig.sol";

contract MetricOmmPoolHarness is MetricOmmPool {
  constructor(
    address _factory,
    address _token0,
    address _token1,
    address _priceProvider,
    bool immutablePriceProvider_,
    uint256 token0ScaleMultiplier,
    uint256 token1ScaleMultiplier,
    uint104 initialScaledAmount0PerShareE18,
    uint104 initialScaledAmount1PerShareE18,
    uint104 minimalOperationalLiquidity,
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
      minimalOperationalLiquidity,
      spreadFeeE6_,
      _curBinDistFromProvidedPrice,
      nonNegativeBinStates,
      negativeBinStates,
      notionalFeeE8_,
      type(uint16).max
    )
  {}

  /// @dev Test-only storage writes; never expose this on a production pool.
  function extsstore(bytes32 slot, bytes32 value) public {
    assembly ("memory-safe") {
      sstore(slot, value)
    }
  }

  function extsstore(bytes32 startSlot, bytes32[] calldata values) external {
    for (uint256 i = 0; i < values.length; ++i) {
      extsstore(bytes32(uint256(startSlot) + i), values[i]);
    }
  }

  function exposedSetCurBinIdx(int16 value) external {
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
