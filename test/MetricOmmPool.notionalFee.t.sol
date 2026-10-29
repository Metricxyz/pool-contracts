// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;
// forge-lint: disable-start(unsafe-typecast, named-struct-fields)

import {MetricOmmPoolBaseTest, MockPriceProvider} from "./MetricOmmPool.base.t.sol";
import {PoolStateLibrary} from "../contracts/libraries/PoolStateLibrary.sol";
import {MetricOmmPool} from "../contracts/MetricOmmPool.sol";
import {LiquidityDelta} from "../contracts/types/PoolOperation.sol";
import {BinState} from "../contracts/types/PoolStorage.sol";
import {SwapMath} from "../contracts/libraries/SwapMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Notional fees use 1e8 = 100%. Spread fees are set to zero so assertions isolate notional only.
contract MetricOmmPoolNotionalFeeTest is MetricOmmPoolBaseTest {
  /// @dev 1% in E8 units
  uint24 internal constant FEE_1_PCT_E8 = 1_000_000;

  /// @dev Q64.64 price of 1.0
  uint128 internal constant MID_PRICE_X64 = uint128(uint256(1) << 64);

  MetricOmmPool internal poolNoNotional;
  MetricOmmPool internal poolWithNotional;

  function setUp() public override {
    super.setUp();

    (BinState[] memory nonNegativeBinStates, BinState[] memory negativeBinStates) = _defaultBinStateArrays();
    poolNoNotional = _deployPoolAndRegister(
      PoolDeployParams({
        priceProvider: address(oracle),
        extensions: _emptyExtensions(),
        extensionOrders: _emptyExtensionOrders(),
        immutablePriceProvider: true,
        protocolSpreadFeeE6: 0,
        adminSpreadFeeE6: 0,
        curBinDistFromProvidedPriceE6: 0,
        nonNegativeBinStates: nonNegativeBinStates,
        negativeBinStates: negativeBinStates,
        protocolNotionalFeeE8: 0,
        adminNotionalFeeE8: 0,
        immutablePriceProviderForRegistry: address(oracle),
        lowestBin: -1,
        highestBin: 0
      })
    );

    poolWithNotional = _deployPoolAndRegister(
      PoolDeployParams({
        priceProvider: address(oracle),
        extensions: _emptyExtensions(),
        extensionOrders: _emptyExtensionOrders(),
        immutablePriceProvider: true,
        protocolSpreadFeeE6: 0,
        adminSpreadFeeE6: 0,
        curBinDistFromProvidedPriceE6: 0,
        nonNegativeBinStates: nonNegativeBinStates,
        negativeBinStates: negativeBinStates,
        protocolNotionalFeeE8: FEE_1_PCT_E8,
        adminNotionalFeeE8: 0,
        immutablePriceProviderForRegistry: address(oracle),
        lowestBin: -1,
        highestBin: 0
      })
    );

    _approveUsersForPool(address(poolNoNotional));
    _approveUsersForPool(address(poolWithNotional));
  }

  function _addLiquidityOn(address poolAddr, uint256 userIndex, int16 lo, int16 hi, uint104 shares, uint80 salt)
    internal
  {
    LiquidityDelta memory deltas = _rangeDeltas(lo, hi, shares);
    vm.prank(users[userIndex]);
    callers[userIndex].addLiquidity(poolAddr, salt, deltas);
  }

  function _swapOn(address poolAddr, uint256 userIndex, address recipient, bool zeroForOne, int128 amountSpecified)
    internal
    returns (int256 amount0Delta, int256 amount1Delta)
  {
    uint128 priceLimit = zeroForOne ? 0 : type(uint128).max;
    return _swapOnPool(poolAddr, userIndex, recipient, zeroForOne, amountSpecified, priceLimit);
  }

  /// @notice Exact input (!zeroForOne): the notional fee is part of the effective execution price, so
  ///         it is carved from the token1 INPUT. The trader's token1 spend is unchanged (exact-in) and
  ///         they receive less token0 because the price they trade against is worse.
  function test_notional_exactIn_chargesOnInputToken_token1ForToken0() public {
    uint256 liqIdx = 1;
    _addLiquidityOn(address(poolNoNotional), liqIdx, -5, 4, 10_000_000, 0);
    _addLiquidityOn(address(poolWithNotional), liqIdx, -5, 4, 10_000_000, 0);

    uint128 amountIn = 50_000;
    uint256 swapper = 0;
    address recipient = users[swapper];

    (uint128 acc0Before, uint128 acc1Before) = PoolStateLibrary._slot2(address(poolWithNotional));

    (int256 a0Ref, int256 a1Ref) = _swapOn(address(poolNoNotional), swapper, recipient, false, int128(amountIn));
    (int256 a0Fee, int256 a1Fee) = _swapOn(address(poolWithNotional), swapper, recipient, false, int128(amountIn));

    (uint128 acc0After, uint128 acc1After) = PoolStateLibrary._slot2(address(poolWithNotional));

    assertEq(a1Ref, a1Fee, "exact in: token1 input unchanged");
    assertGt(a0Fee, a0Ref, "with notional: less token0 out (delta less negative)");

    // Carved from the gross input: in * nf / (1 + nf). The base spread fee is ~0 for this oracle, and
    // cancels out of the notional leg in any case (see test_notional_exactOut_feeIndependentOfOracleSpread).
    uint256 expectedNotional = (uint256(amountIn) * uint256(FEE_1_PCT_E8)) / (1e8 + uint256(FEE_1_PCT_E8));

    // Rounds DOWN: the platform take is floored, so the residual sub-wei stays with the LPs. The
    // invariant that matters is that the platform never collects MORE than the stated rate.
    assertApproxEqAbs(uint256(acc1After - acc1Before), expectedNotional, 1, "notional accrues on the token1 input");
    assertLe(uint256(acc1After - acc1Before), expectedNotional, "platform notional must never round up");
    assertEq(acc0After, acc0Before, "buying token0 must not accrue notional in token0");

    // The trader's shortfall in token0 is the same fee expressed at the ~1.0 execution price.
    uint256 outRef = uint256(uint128(uint256(-a0Ref)));
    uint256 outFee = uint256(uint128(uint256(-a0Fee)));
    assertApproxEqAbs(outRef - outFee, expectedNotional, 1, "token0 shortfall matches the carved fee");
  }

  /// @notice Exact output (!zeroForOne): notional is charged on pre-bin-fee input; user pays more token1.
  function test_notional_exactOut_chargesOnInputToken_token1ForToken0() public {
    uint256 liqIdx = 1;
    _addLiquidityOn(address(poolNoNotional), liqIdx, -5, 4, 10_000_000, 0);
    _addLiquidityOn(address(poolWithNotional), liqIdx, -5, 4, 10_000_000, 0);

    uint128 amountOut = 20_000;
    uint256 swapper = 0;
    address recipient = users[swapper];

    (, uint128 accBefore) = PoolStateLibrary._slot2(address(poolWithNotional));

    (int256 a0Ref, int256 a1Ref) = _swapOn(address(poolNoNotional), swapper, recipient, false, -int128(amountOut));
    (int256 a0Fee, int256 a1Fee) = _swapOn(address(poolWithNotional), swapper, recipient, false, -int128(amountOut));

    (, uint128 accAfter) = PoolStateLibrary._slot2(address(poolWithNotional));

    assertEq(a0Ref, a0Fee, "exact out: token0 output unchanged");
    assertGt(a1Fee, a1Ref, "with notional: more token1 in");

    uint256 inRef = uint256(uint128(uint256(a1Ref)));
    uint256 inWithFee = uint256(uint128(uint256(a1Fee)));
    uint256 extraIn = inWithFee - inRef;
    uint256 expectedExtra = (uint256(amountOut) * uint256(FEE_1_PCT_E8)) / 1e8;

    assertEq(extraIn, expectedExtra, "extra input matches fee on fee-exclusive input notional");
    // Rounds DOWN (see above): at most the stated fee, never more.
    assertApproxEqAbs(uint256(accAfter - accBefore), expectedExtra, 1, "notionalFeeToken1Scaled increases by fee");
    assertLe(uint256(accAfter - accBefore), expectedExtra, "platform notional must never round up");
  }

  /// @notice Exact input (zeroForOne): mirror of the above -- notional is carved from the token0 INPUT.
  function test_notional_exactIn_chargesOnInputToken_token0ForToken1() public {
    uint256 liqIdx = 1;
    _addLiquidityOn(address(poolNoNotional), liqIdx, -5, 4, 10_000_000, 0);
    _addLiquidityOn(address(poolWithNotional), liqIdx, -5, 4, 10_000_000, 0);

    uint128 amountIn = 10_000;
    uint256 swapper = 0;
    address recipient = users[swapper];

    (uint128 acc0Before, uint128 acc1Before) = PoolStateLibrary._slot2(address(poolWithNotional));

    (int256 a0Ref, int256 a1Ref) = _swapOn(address(poolNoNotional), swapper, recipient, true, int128(amountIn));
    (int256 a0Fee, int256 a1Fee) = _swapOn(address(poolWithNotional), swapper, recipient, true, int128(amountIn));

    (uint128 acc0After, uint128 acc1After) = PoolStateLibrary._slot2(address(poolWithNotional));

    assertEq(a0Ref, a0Fee, "exact in: token0 input unchanged");
    assertGt(a1Fee, a1Ref, "with notional: less token1 out (delta less negative)");

    uint256 expectedNotional = (uint256(amountIn) * uint256(FEE_1_PCT_E8)) / (1e8 + uint256(FEE_1_PCT_E8));
    assertApproxEqAbs(uint256(acc0After - acc0Before), expectedNotional, 1, "notional accrues on the token0 input");
    assertLe(uint256(acc0After - acc0Before), expectedNotional, "platform notional must never round up");
    assertEq(acc1After, acc1Before, "selling token0 must not accrue notional in token1");

    uint256 outRef = uint256(uint128(uint256(-a1Ref)));
    uint256 outFee = uint256(uint128(uint256(-a1Fee)));
    assertApproxEqAbs(outRef - outFee, expectedNotional, 1, "token1 shortfall matches the carved fee");
  }

  /// @notice Exact output (zeroForOne): notional on pre-bin-fee token0 input.
  function test_notional_exactOut_chargesOnInputToken_token0ForToken1() public {
    uint256 liqIdx = 1;
    _addLiquidityOn(address(poolNoNotional), liqIdx, -5, 4, 10_000_000, 0);
    _addLiquidityOn(address(poolWithNotional), liqIdx, -5, 4, 10_000_000, 0);

    uint128 amountOut = 5_000;
    uint256 swapper = 0;
    address recipient = users[swapper];

    (int256 a0Ref, int256 a1Ref) = _swapOn(address(poolNoNotional), swapper, recipient, true, -int128(amountOut));
    (int256 a0Fee, int256 a1Fee) = _swapOn(address(poolWithNotional), swapper, recipient, true, -int128(amountOut));

    assertEq(a1Ref, a1Fee, "exact out: token1 output unchanged");
    assertGt(a0Fee, a0Ref, "with notional: more token0 in");

    uint256 inRef = uint256(uint128(uint256(a0Ref)));
    uint256 inFee = uint256(uint128(uint256(a0Fee)));
    uint256 extraIn = inFee - inRef;
    uint256 expectedExtra = (uint256(amountOut) * uint256(FEE_1_PCT_E8)) / 1e8;
    assertEq(extraIn, expectedExtra, "extra token0 input for exact out");
  }

  /// @notice Exact-out notional fee depends on pre-bin-fee input, not oracle spread / base fee.
  function test_notional_exactOut_feeIndependentOfOracleSpread() public {
    MockPriceProvider oracleLowSpread = new MockPriceProvider();
    MockPriceProvider oracleHighSpread = new MockPriceProvider();

    (uint128 bidLow, uint128 askLow) = _bidAskWithSameMidBps(1);
    (uint128 bidHigh, uint128 askHigh) = _bidAskWithSameMidBps(500);
    oracleLowSpread.setBidAndAskPrice(bidLow, askLow);
    oracleHighSpread.setBidAndAskPrice(bidHigh, askHigh);

    uint256 refLow = Math.sqrt(uint256(bidLow) * askLow);
    uint256 refHigh = Math.sqrt(uint256(bidHigh) * askHigh);
    uint256 baseFeeLow = SwapMath.buyBaseFeeX64FromAskAndReference(askLow, refLow);
    uint256 baseFeeHigh = SwapMath.buyBaseFeeX64FromAskAndReference(askHigh, refHigh);
    assertApproxEqAbs(refLow, refHigh, 2, "oracles share reference price");
    assertLt(baseFeeLow, baseFeeHigh, "high-spread oracle has larger base fee");
    assertGt(baseFeeHigh, baseFeeLow * 10, "spread gap is material");

    (BinState[] memory nonNegativeBinStates, BinState[] memory negativeBinStates) = _defaultBinStateArrays();
    MetricOmmPool poolLowSpread =
      _deployNotionalPoolWithProvider(oracleLowSpread, nonNegativeBinStates, negativeBinStates);
    MetricOmmPool poolHighSpread =
      _deployNotionalPoolWithProvider(oracleHighSpread, nonNegativeBinStates, negativeBinStates);
    _approveUsersForPool(address(poolLowSpread));
    _approveUsersForPool(address(poolHighSpread));

    uint256 liqIdx = 1;
    _addLiquidityOn(address(poolLowSpread), liqIdx, -5, 4, 10_000_000, 0);
    _addLiquidityOn(address(poolHighSpread), liqIdx, -5, 4, 10_000_000, 0);

    uint256 swapper = 0;
    address recipient = users[swapper];
    uint128 amountOut = 20_000;

    // !zeroForOne exact-out: buy token0, pay token1; notional lands in token1 accumulator.
    (, uint128 n1BeforeLow) = PoolStateLibrary._slot2(address(poolLowSpread));
    (int256 a0Low, int256 a1Low) = _swapOn(address(poolLowSpread), swapper, recipient, false, -int128(amountOut));
    (, uint128 n1AfterLow) = PoolStateLibrary._slot2(address(poolLowSpread));
    uint256 notionalLow = uint256(n1AfterLow - n1BeforeLow);

    (, uint128 n1BeforeHigh) = PoolStateLibrary._slot2(address(poolHighSpread));
    (int256 a0High, int256 a1High) = _swapOn(address(poolHighSpread), swapper, recipient, false, -int128(amountOut));
    (, uint128 n1AfterHigh) = PoolStateLibrary._slot2(address(poolHighSpread));
    uint256 notionalHigh = uint256(n1AfterHigh - n1BeforeHigh);

    assertEq(a0Low, a0High, "exact out: same token0 output");
    assertGt(a1High, a1Low, "high-spread pool charges more token1 input");
    assertApproxEqAbs(notionalLow, notionalHigh, 1, "notional fee matches across oracle spreads");
    // Rounds DOWN: at most 1% of the output, never more.
    assertApproxEqAbs(
      notionalLow, (uint256(amountOut) * uint256(FEE_1_PCT_E8)) / 1e8, 1, "notional fee is 1% of output"
    );
    assertLe(notionalLow, (uint256(amountOut) * uint256(FEE_1_PCT_E8)) / 1e8, "notional must never round up");

    // zeroForOne exact-out: buy token1, pay token0; notional lands in token0 accumulator.
    amountOut = 5_000;
    (uint128 n0BeforeLow,) = PoolStateLibrary._slot2(address(poolLowSpread));
    (int256 a0OutLow, int256 a1OutLow) = _swapOn(address(poolLowSpread), swapper, recipient, true, -int128(amountOut));
    (uint128 n0AfterLow,) = PoolStateLibrary._slot2(address(poolLowSpread));
    uint256 notionalOutLow = uint256(n0AfterLow - n0BeforeLow);

    (uint128 n0BeforeHigh,) = PoolStateLibrary._slot2(address(poolHighSpread));
    (int256 a0OutHigh, int256 a1OutHigh) =
      _swapOn(address(poolHighSpread), swapper, recipient, true, -int128(amountOut));
    (uint128 n0AfterHigh,) = PoolStateLibrary._slot2(address(poolHighSpread));
    uint256 notionalOutHigh = uint256(n0AfterHigh - n0BeforeHigh);

    assertEq(a1OutLow, a1OutHigh, "exact out: same token1 output");
    assertGt(a0OutHigh, a0OutLow, "high-spread pool charges more token0 input");
    assertApproxEqAbs(notionalOutLow, notionalOutHigh, 1, "notional fee matches across oracle spreads (zeroForOne)");
  }

  /// @dev bid * ask ~= mid^2 so geometric mid stays at `MID_PRICE_X64` (within integer rounding).
  function _bidAskWithSameMidBps(uint256 spreadBps) internal pure returns (uint128 bid, uint128 ask) {
    uint256 mid = MID_PRICE_X64;
    ask = uint128(mid + (mid * spreadBps) / 10_000);
    bid = uint128((mid * mid) / ask);
  }

  function _deployNotionalPoolWithProvider(
    MockPriceProvider priceProvider,
    BinState[] memory nonNegativeBinStates,
    BinState[] memory negativeBinStates
  ) internal returns (MetricOmmPool deployedPool) {
    deployedPool = _deployPoolAndRegister(
      PoolDeployParams({
        priceProvider: address(priceProvider),
        extensions: _emptyExtensions(),
        extensionOrders: _emptyExtensionOrders(),
        immutablePriceProvider: true,
        protocolSpreadFeeE6: 0,
        adminSpreadFeeE6: 0,
        curBinDistFromProvidedPriceE6: 0,
        nonNegativeBinStates: nonNegativeBinStates,
        negativeBinStates: negativeBinStates,
        protocolNotionalFeeE8: FEE_1_PCT_E8,
        adminNotionalFeeE8: 0,
        immutablePriceProviderForRegistry: address(priceProvider),
        lowestBin: -1,
        highestBin: 0
      })
    );
  }
}
