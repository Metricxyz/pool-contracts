// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {MetricOmmPoolBaseTest, Q64} from "./MetricOmmPool.base.t.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {MetricOmmPool} from "../contracts/MetricOmmPool.sol";
import {BinState} from "../contracts/types/PoolStorage.sol";
import {LiquidityDelta} from "../contracts/types/PoolOperation.sol";

/// @notice Behavioral tests for getSellAndBuyPrices(): fee-adjusted sell/buy quotes at the pool's
///         current marginal bin position (spread + notional), not the raw price-provider quote.
contract MetricOmmPoolGetSellAndBuyPricesTest is MetricOmmPoolBaseTest {
  uint256 internal constant SWAPPER = 0;
  address internal swapper;

  // Provider quote at a price level well away from 1 (≈10) with a ~2% spread. The price level matters:
  // the original additive bug (mid ± fee) only diverges from the correct multiplicative quote when the
  // price differs from 1, so testing at ≈1 would mask it.
  uint128 internal constant BID_P = uint128(uint256(Q64) * 99 / 10); // 9.9
  uint128 internal constant ASK_P = uint128(uint256(Q64) * 101 / 10); // 10.1
  uint24 internal constant NOTIONAL_1_PCT_E8 = 1_000_000;

  function setUp() public override {
    super.setUp();
    swapper = users[SWAPPER];
    _addLiquidity(1, -5, 4, 100_000, 0);
    oracle.setBidAndAskPrice(BID_P, ASK_P);
  }

  /// @dev The original bug added the fee FRACTION to the mid PRICE (mid ± baseFee), collapsing the
  ///      spread to ~0 for any price ≫ 1. A correct quote applies the fee multiplicatively, so the
  ///      pool's ask/bid ratio must equal the provider's (both are (1 + fee)²).
  function test_getSellAndBuyPrices_preservesProviderFeeEnvelope() public {
    (uint128 bid, uint128 ask) = pool.getSellAndBuyPrices();

    assertGt(ask, bid, "ask must exceed bid");

    uint256 poolRatio = uint256(ask) * 1e18 / uint256(bid);
    uint256 providerRatio = uint256(ASK_P) * 1e18 / uint256(BID_P);
    // ~1.0202e18. The buggy additive version yields ~1e18 (no spread) and fails this.
    assertApproxEqRel(poolRatio, providerRatio, 0.005e18, "pool fee envelope must match provider");
  }

  /// @dev The pool quote is anchored on the pool's current marginal price, which moves with inventory.
  ///      A buy of token0 pushes the price up, so the quote's level (bid·ask, monotonic in the geometric
  ///      mid) must rise even though the provider's quote is unchanged — i.e. pool price ≠ provider price.
  function test_getSellAndBuyPrices_tracksInventoryAwayFromProvider() public {
    (uint128 bid0, uint128 ask0) = pool.getSellAndBuyPrices();
    uint256 level0 = uint256(bid0) * uint256(ask0);

    // Buy token0 (zeroForOne = false, exact input token1) to move the marginal price up.
    _swap(SWAPPER, swapper, false, _i128ExactIn(100_000), type(uint128).max);

    (uint128 bid1, uint128 ask1) = pool.getSellAndBuyPrices();
    uint256 level1 = uint256(bid1) * uint256(ask1);

    assertGt(level1, level0, "buying token0 must raise the pool's quoted price level");
  }

  /// @dev "Prices applied to swap": the realized price of a buy must not be better (lower) than the
  ///      quoted ask, and for a small size it should track the quoted ask closely.
  function test_getSellAndBuyPrices_askMatchesRealizedBuyPrice() public {
    (, uint128 ask) = pool.getSellAndBuyPrices();

    // Small exact-input buy of token0 with token1 (sized for the ≈10 price level so token0 out ≫ 0).
    (int256 amount0, int256 amount1) = _swap(SWAPPER, swapper, false, _i128ExactIn(10_000), type(uint128).max);

    uint256 token0Out = SafeCast.toUint256(-amount0);
    uint256 token1In = SafeCast.toUint256(amount1);
    uint256 realizedX64 = token1In * Q64 / token0Out; // token1 paid per token0, Q64.64

    // You can never buy below the marginal ask; for a small size it stays within ~2%.
    assertGe(realizedX64, uint256(ask) * 999 / 1000, "realized buy price below quoted ask");
    assertApproxEqRel(realizedX64, uint256(ask), 0.02e18, "realized buy price should track quoted ask");
  }

  /// @dev Direct, both-sided comparison of the quote against actual swap execution. From the SAME quoted
  ///      state (snapshot/revert), a small buy must realize ≈ the quoted ask and a small sell ≈ the quoted
  ///      bid — and neither side may execute better than its quote (buy ≥ ask, sell ≤ bid).
  function test_getSellAndBuyPrices_realizedSwapPricesMatchQuote() public {
    (uint128 bid, uint128 ask) = pool.getSellAndBuyPrices();

    uint256 snap = vm.snapshotState();

    // ── Buy token0 with token1 (zeroForOne = false): realized = token1 in per token0 out ──
    (int256 b0, int256 b1) = _swap(SWAPPER, swapper, false, _i128ExactIn(10_000), type(uint128).max);
    uint256 buyRealizedX64 = SafeCast.toUint256(b1) * Q64 / SafeCast.toUint256(-b0);
    assertGe(buyRealizedX64, uint256(ask) * 999 / 1000, "buy executed below quoted ask");
    assertApproxEqRel(buyRealizedX64, uint256(ask), 0.01e18, "buy realized vs quoted ask");

    // Rewind to the exact state the quote was taken at.
    vm.revertToState(snap);

    // ── Sell token0 for token1 (zeroForOne = true): realized = token1 out per token0 in ──
    (int256 s0, int256 s1) = _swap(SWAPPER, swapper, true, _i128ExactIn(10_000), 0);
    uint256 sellRealizedX64 = SafeCast.toUint256(-s1) * Q64 / SafeCast.toUint256(s0);
    assertLe(sellRealizedX64, uint256(bid) * 1001 / 1000, "sell executed above quoted bid");
    assertApproxEqRel(sellRealizedX64, uint256(bid), 0.01e18, "sell realized vs quoted bid");

    // Sanity: a buy costs more per token0 than a sell yields — the spread is real.
    assertGt(buyRealizedX64, sellRealizedX64, "buy must cost more than sell yields");
  }

  /// @dev With notional fee on output (exact-in path), buy quote must gross up and sell quote must net down
  ///      exactly as `_executeSwap` applies `notionalFeeE8` after spread.
  function test_getSellAndBuyPrices_notionalFeeMatchesExactInSwap() public {
    (BinState[] memory nonNegativeBinStates, BinState[] memory negativeBinStates) = _defaultBinStateArrays();
    MetricOmmPool notionalPool = _deployPoolAndRegister(
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
        protocolNotionalFeeE8: NOTIONAL_1_PCT_E8,
        adminNotionalFeeE8: 0,
        immutablePriceProviderForRegistry: address(oracle),
        lowestBin: -1,
        highestBin: 0
      })
    );
    _approveUsersForPool(address(notionalPool));
    _addLiquidityOn(address(notionalPool), 1, -5, 4, 100_000, 0);

    (uint128 sell, uint128 buy) = notionalPool.getSellAndBuyPrices();

    uint256 snap = vm.snapshotState();

    (int256 b0, int256 b1) =
      _swapOnPool(address(notionalPool), SWAPPER, swapper, false, _i128ExactIn(10_000), type(uint128).max);
    uint256 buyRealizedX64 = SafeCast.toUint256(b1) * Q64 / SafeCast.toUint256(-b0);
    assertGe(buyRealizedX64, uint256(buy) * 999 / 1000, "buy below quoted buy price with notional");
    assertApproxEqRel(buyRealizedX64, uint256(buy), 0.01e18, "buy realized vs quoted with notional");

    vm.revertToState(snap);

    (int256 s0, int256 s1) = _swapOnPool(address(notionalPool), SWAPPER, swapper, true, _i128ExactIn(10_000), 0);
    uint256 sellRealizedX64 = SafeCast.toUint256(-s1) * Q64 / SafeCast.toUint256(s0);
    assertLe(sellRealizedX64, uint256(sell) * 1001 / 1000, "sell above quoted sell price with notional");
    assertApproxEqRel(sellRealizedX64, uint256(sell), 0.01e18, "sell realized vs quoted with notional");
  }

  function _addLiquidityOn(address poolAddr, uint256 userIndex, int8 lo, int8 hi, uint104 shares, uint80 salt)
    internal
  {
    LiquidityDelta memory deltas = _rangeDeltas(lo, hi, shares);
    vm.prank(users[userIndex]);
    callers[userIndex].addLiquidity(poolAddr, salt, deltas);
  }
}
