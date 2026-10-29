// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {MetricOmmPool} from "../contracts/MetricOmmPool.sol";
import {SwapMath} from "../contracts/libraries/SwapMath.sol";
import {BinState} from "../contracts/types/PoolStorage.sol";
import {PoolExtensions, ExtensionOrders} from "../contracts/types/PoolExtensionsConfig.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/**
 * @title SwapInBinHarness
 * @notice Test harness to expose SwapMath swapInBin functions for testing
 * @dev Inherits from MetricOmmPool and exposes library functions as external
 */
contract SwapInBinHarness is MetricOmmPool {
  using SafeCast for uint256;

  constructor(
    address _factory,
    address _admin,
    address _adminFeeDestination,
    address _token0,
    address _token1,
    address _priceProvider,
    bool _immutablePriceProvider,
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
      _immutablePriceProvider,
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

  /**
   * @notice Expose buyToken0InBinSpecifiedOut for testing
   */
  function exposedBuyToken0InBinSpecifiedOut(
    BinState memory binState,
    uint104 currBinPos,
    SwapMath.SwapState memory state,
    uint256 currBinBuyFeeX64,
    uint128 lowerPrice,
    uint128 upperPrice,
    uint128 priceLimitX64
  ) external pure returns (uint256 finalBinPos, SwapMath.SwapState memory, BinState memory) {
    (finalBinPos,,,) = SwapMath.buyToken0InBinSpecifiedOut(
        binState,
        currBinPos,
        state,
        currBinBuyFeeX64,
        lowerPrice,
        upperPrice,
        priceLimitX64,
        0 // spreadFeeE6 = 0 for testing
      );
    return (finalBinPos, state, binState);
  }

  /**
   * @notice Expose buyToken1InBinSpecifiedOut for testing
   */
  function exposedBuyToken1InBinSpecifiedOut(
    BinState memory binState,
    uint104 currBinPos,
    SwapMath.SwapState memory state,
    uint256 currBinSellFeeX64,
    uint128 lowerPrice,
    uint128 upperPrice,
    uint128 priceLimitX64
  ) external pure returns (uint256 finalBinPos, SwapMath.SwapState memory, BinState memory) {
    (finalBinPos,,,) = SwapMath.buyToken1InBinSpecifiedOut(
        binState,
        currBinPos,
        state,
        currBinSellFeeX64,
        lowerPrice,
        upperPrice,
        priceLimitX64,
        0 // spreadFeeE6 = 0 for testing
      );
    return (finalBinPos, state, binState);
  }

  /**
   * @notice Expose buyToken0InBinSpecifiedIn for testing
   */
  function exposedBuyToken0InBinSpecifiedIn(
    BinState memory binState,
    uint104 currBinPos,
    SwapMath.SwapState memory state,
    uint256 currBinBuyFeeX64,
    uint128 lowerPrice,
    uint128 upperPrice,
    uint128 priceLimitX64
  ) external pure returns (uint256 finalBinPos, SwapMath.SwapState memory, uint128 outToken0, BinState memory) {
    uint256 out0;
    (finalBinPos, out0,,,) = SwapMath.buyToken0InBinSpecifiedIn(
      binState,
      currBinPos,
      state,
      currBinBuyFeeX64,
      lowerPrice,
      upperPrice,
      priceLimitX64,
      0 // spreadFeeE6 = 0 for testing
    );
    return (finalBinPos, state, out0.toUint128(), binState);
  }

  /**
   * @notice Expose buyToken1InBinSpecifiedIn for testing
   */
  function exposedBuyToken1InBinSpecifiedIn(
    BinState memory binState,
    uint104 currBinPos,
    SwapMath.SwapState memory state,
    uint256 currBinSellFeeX64,
    uint128 lowerPrice,
    uint128 upperPrice,
    uint128 priceLimitX64
  ) external pure returns (uint256 finalBinPos, SwapMath.SwapState memory, uint128 outToken1, BinState memory) {
    uint256 out1;
    (finalBinPos, out1,,,) = SwapMath.buyToken1InBinSpecifiedIn(
      binState,
      currBinPos,
      state,
      currBinSellFeeX64,
      lowerPrice,
      upperPrice,
      priceLimitX64,
      0 // spreadFeeE6 = 0 for testing
    );
    return (finalBinPos, state, out1.toUint128(), binState);
  }

  /**
   * @notice Expose computeAnalyticalTargetPosForSellToken0 for formula regression tests
   */
  function exposedComputeAnalyticalTargetPosForSellToken0(
    uint256 currBinPos,
    uint256 minFinalBinPos,
    uint256 inputAmount,
    uint256 token1Balance,
    uint256 lowerPriceX64,
    uint256 upperPriceX64,
    uint256 feeX64
  ) external pure returns (uint256 targetPos) {
    return SwapMath.computeAnalyticalTargetPosForSellToken0(
      currBinPos, minFinalBinPos, inputAmount, token1Balance, lowerPriceX64, upperPriceX64, feeX64
    );
  }
}
