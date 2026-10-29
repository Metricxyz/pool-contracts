// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;
// forge-lint: disable-start(unsafe-typecast, named-struct-fields)

import {MetricOmmPoolBaseTest, MockERC20, MockPriceProvider} from "./MetricOmmPool.base.t.sol";
import {PoolStateLibrary} from "../contracts/libraries/PoolStateLibrary.sol";
import {MetricOmmPool} from "../contracts/MetricOmmPool.sol";
import {LiquidityDelta} from "../contracts/types/PoolOperation.sol";
import {IMetricOmmPoolFactory} from "../contracts/interfaces/IMetricOmmPoolFactory/IMetricOmmPoolFactory.sol";
import {IMetricOmmPool, PoolImmutables} from "../contracts/interfaces/IMetricOmmPool/IMetricOmmPool.sol";
import {PoolFeeConfig} from "../contracts/types/FactoryStorage.sol";
import {BinState} from "../contracts/types/PoolStorage.sol";
import {SwapMath} from "../contracts/libraries/SwapMath.sol";

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

  function _addLiquidityOn(address poolAddr, uint256 userIndex, int8 lo, int8 hi, uint104 shares, uint80 salt)
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

  /// @notice Exact input (!zeroForOne): notional is charged on token0 output; user receives less token0.
  function test_notional_exactIn_chargesOnOutputToken_token1ForToken0() public {
    uint256 liqIdx = 1;
    _addLiquidityOn(address(poolNoNotional), liqIdx, -5, 4, 100_000, 0);
    _addLiquidityOn(address(poolWithNotional), liqIdx, -5, 4, 100_000, 0);

    uint128 amountIn = 50_000;
    uint256 swapper = 0;
    address recipient = users[swapper];

    (uint128 accBefore,) = PoolStateLibrary._slot2(address(poolWithNotional));

    (int256 a0Ref, int256 a1Ref) = _swapOn(address(poolNoNotional), swapper, recipient, false, int128(amountIn));
    (int256 a0Fee, int256 a1Fee) = _swapOn(address(poolWithNotional), swapper, recipient, false, int128(amountIn));

    (uint128 accAfter,) = PoolStateLibrary._slot2(address(poolWithNotional));

    assertEq(a1Ref, a1Fee, "exact in: token1 input unchanged");
    assertGt(a0Fee, a0Ref, "with notional: less token0 out (delta less negative)");

    uint256 outRef = uint256(uint128(uint256(-a0Ref)));
    uint256 outFee = uint256(uint128(uint256(-a0Fee)));
    uint256 feeTaken = outRef - outFee;
    uint256 feeExpected = (outRef * uint256(FEE_1_PCT_E8)) / 1e8;

    assertEq(feeTaken, feeExpected, "output fee matches 1% of pre-fee output (external units)");
    assertEq(uint256(accAfter - accBefore), feeExpected, "notionalFeeToken0Scaled increases by fee in scaled units");
  }

  /// @notice Exact output (!zeroForOne): notional is charged on pre-bin-fee input; user pays more token1.
  function test_notional_exactOut_chargesOnInputToken_token1ForToken0() public {
    uint256 liqIdx = 1;
    _addLiquidityOn(address(poolNoNotional), liqIdx, -5, 4, 100_000, 0);
    _addLiquidityOn(address(poolWithNotional), liqIdx, -5, 4, 100_000, 0);

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
    assertEq(uint256(accAfter - accBefore), expectedExtra, "notionalFeeToken1Scaled increases by fee");
  }

  /// @notice Exact input (zeroForOne): notional on token1 output.
  function test_notional_exactIn_chargesOnOutputToken_token0ForToken1() public {
    uint256 liqIdx = 1;
    _addLiquidityOn(address(poolNoNotional), liqIdx, -5, 4, 100_000, 0);
    _addLiquidityOn(address(poolWithNotional), liqIdx, -5, 4, 100_000, 0);

    uint128 amountIn = 10_000;
    uint256 swapper = 0;
    address recipient = users[swapper];

    (int256 a0Ref, int256 a1Ref) = _swapOn(address(poolNoNotional), swapper, recipient, true, int128(amountIn));
    (int256 a0Fee, int256 a1Fee) = _swapOn(address(poolWithNotional), swapper, recipient, true, int128(amountIn));

    assertEq(a0Ref, a0Fee, "exact in: token0 input unchanged");
    assertGt(a1Fee, a1Ref, "with notional: less token1 out (delta less negative)");

    uint256 outRef = uint256(uint128(uint256(-a1Ref)));
    uint256 outFee = uint256(uint128(uint256(-a1Fee)));
    assertEq(outRef - outFee, (outRef * uint256(FEE_1_PCT_E8)) / 1e8, "fee on token1 output");
  }

  /// @notice Exact output (zeroForOne): notional on pre-bin-fee token0 input.
  function test_notional_exactOut_chargesOnInputToken_token0ForToken1() public {
    uint256 liqIdx = 1;
    _addLiquidityOn(address(poolNoNotional), liqIdx, -5, 4, 100_000, 0);
    _addLiquidityOn(address(poolWithNotional), liqIdx, -5, 4, 100_000, 0);

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

  /// @notice After `collectProtocolFees`, notional fee accumulators are cleared (scaled units).
  function test_collectProtocolFees_resetsNotionalFeeTokenScaledToZero() public {
    uint256 liqIdx = 1;
    _addLiquidityOn(address(poolWithNotional), liqIdx, -5, 4, 100_000, 0);

    uint256 swapper = 0;
    address recipient = users[swapper];

    _swapOn(address(poolWithNotional), swapper, recipient, false, int128(50_000));
    _swapOn(address(poolWithNotional), swapper, recipient, true, int128(10_000));

    (uint128 n0Before, uint128 n1Before) = PoolStateLibrary._slot2(address(poolWithNotional));
    assertTrue(n0Before > 0 && n1Before > 0, "both notional accumulators should be non-zero after swaps");

    poolWithNotional.collectFees(0, 0, FEE_1_PCT_E8, 0, adminFeeDestination);

    (uint128 n0After, uint128 n1After) = PoolStateLibrary._slot2(address(poolWithNotional));
    assertEq(n0After, 0, "notionalFeeToken0Scaled after collect");
    assertEq(n1After, 0, "notionalFeeToken1Scaled after collect");
  }

  function test_collectProtocolFees_math_overallocates_whenSpreadAndNotionalBothActive() public {
    pool.collectFees(PROTOCOL_FEE, ADMIN_FEE, 0, 0, adminFeeDestination);
    poolFeeConfig[address(pool)] = PoolFeeConfig({
      protocolSpreadFeeE6: PROTOCOL_FEE,
      adminSpreadFeeE6: ADMIN_FEE,
      protocolNotionalFeeE8: FEE_1_PCT_E8,
      adminNotionalFeeE8: 0
    });
    pool.setPoolFees(PROTOCOL_FEE + ADMIN_FEE, FEE_1_PCT_E8);

    _addLiquidity(1, -5, 4, 100_000, 0);
    for (uint256 i = 0; i < 8; i++) {
      _swap(0, users[0], false, int128(50_000), type(uint128).max);
      _swap(0, users[0], true, int128(10_000), 0);
    }

    (uint128 totalScaledToken0InBins, uint128 totalScaledToken1InBins) = PoolStateLibrary._slot1(_poolAddr());
    (uint128 notional0, uint128 notional1) = PoolStateLibrary._slot2(_poolAddr());
    assertGt(uint256(notional0) + uint256(notional1), 10, "notional accumulators should be non-zero");

    address adminAddr = IMetricOmmPoolFactory(factory).poolAdmin(_poolAddr());
    (uint24 protocolSpreadFeeE6, uint24 adminSpreadFeeE6,,) = IMetricOmmPoolFactory(factory).poolFeeConfig(_poolAddr());
    assertEq(adminAddr, admin);
    PoolFeeConfig memory feeConfig = poolFeeConfig[address(pool)];
    uint24 protocolNotionalFeeE8 = feeConfig.protocolNotionalFeeE8;
    uint24 adminNotionalFeeE8 = feeConfig.adminNotionalFeeE8;

    uint24 spreadFeeE6 = protocolSpreadFeeE6 + adminSpreadFeeE6;
    uint24 notionalFeeE8 = protocolNotionalFeeE8 + adminNotionalFeeE8;

    PoolImmutables memory immutables = IMetricOmmPool(address(pool)).getImmutables();
    address token0Addr = immutables.token0;
    address token1Addr = immutables.token1;
    uint256 token0Mul = immutables.token0ScaleMultiplier;
    uint256 token1Mul = immutables.token1ScaleMultiplier;

    uint256 surplus0Scaled = (MockERC20(token0Addr).balanceOf(address(pool)) * token0Mul) - totalScaledToken0InBins;
    uint256 surplus1Scaled = (MockERC20(token1Addr).balanceOf(address(pool)) * token1Mul) - totalScaledToken1InBins;

    // Mirror collect fee-split math for scaled amounts (rates passed into collectFees).
    uint256 spread0ToAdmin = spreadFeeE6 == 0 ? 0 : (surplus0Scaled * adminSpreadFeeE6) / spreadFeeE6;
    uint256 spread1ToAdmin = spreadFeeE6 == 0 ? 0 : (surplus1Scaled * adminSpreadFeeE6) / spreadFeeE6;
    uint256 spread0ToProtocol = spreadFeeE6 == 0 ? 0 : (surplus0Scaled * protocolSpreadFeeE6) / spreadFeeE6;
    uint256 spread1ToProtocol = spreadFeeE6 == 0 ? 0 : (surplus1Scaled * protocolSpreadFeeE6) / spreadFeeE6;

    uint256 notional0ToAdmin = notionalFeeE8 == 0 ? 0 : (uint256(notional0) * adminNotionalFeeE8) / notionalFeeE8;
    uint256 notional1ToAdmin = notionalFeeE8 == 0 ? 0 : (uint256(notional1) * adminNotionalFeeE8) / notionalFeeE8;
    uint256 notional0ToProtocol = uint256(notional0) - notional0ToAdmin;
    uint256 notional1ToProtocol = uint256(notional1) - notional1ToAdmin;

    uint256 total0Attempted = spread0ToAdmin + spread0ToProtocol + notional0ToAdmin + notional0ToProtocol;
    uint256 total1Attempted = spread1ToAdmin + spread1ToProtocol + notional1ToAdmin + notional1ToProtocol;

    assertGt(total0Attempted, surplus0Scaled, "token0 attempted payout exceeds computed surplus");
    assertGt(total1Attempted, surplus1Scaled, "token1 attempted payout exceeds computed surplus");
  }

  /// @notice Exact-out notional fee depends on pre-bin-fee input, not oracle spread / base fee.
  function test_notional_exactOut_feeIndependentOfOracleSpread() public {
    MockPriceProvider oracleLowSpread = new MockPriceProvider();
    MockPriceProvider oracleHighSpread = new MockPriceProvider();

    (uint128 bidLow, uint128 askLow) = _bidAskWithSameMidBps(1);
    (uint128 bidHigh, uint128 askHigh) = _bidAskWithSameMidBps(500);
    oracleLowSpread.setBidAndAskPrice(bidLow, askLow);
    oracleHighSpread.setBidAndAskPrice(bidHigh, askHigh);

    (uint256 midLow, uint256 baseFeeLow) = SwapMath.midAndSpreadFeeX64FromBidAsk(bidLow, askLow);
    (uint256 midHigh, uint256 baseFeeHigh) = SwapMath.midAndSpreadFeeX64FromBidAsk(bidHigh, askHigh);
    assertApproxEqAbs(midLow, midHigh, 2, "oracles share mid price");
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
    _addLiquidityOn(address(poolLowSpread), liqIdx, -5, 4, 100_000, 0);
    _addLiquidityOn(address(poolHighSpread), liqIdx, -5, 4, 100_000, 0);

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
    assertEq(notionalLow, (uint256(amountOut) * uint256(FEE_1_PCT_E8)) / 1e8, "notional fee is 1% of output");

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
