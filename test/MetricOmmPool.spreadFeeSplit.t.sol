// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;
// forge-lint: disable-start(unsafe-typecast)

import {MetricOmmPoolBaseTest, Q64} from "./MetricOmmPool.base.t.sol";
import {PoolStateLibrary} from "../contracts/libraries/PoolStateLibrary.sol";
import {IMetricOmmPool, PoolImmutables} from "../contracts/interfaces/IMetricOmmPool/IMetricOmmPool.sol";
import {Vm} from "forge-std/Vm.sol";
import {Packed2Int128, Packed2Uint128, PackedSwapDetails} from "../contracts/types/Packed.sol";
import {SwapMath} from "../contracts/libraries/SwapMath.sol";
import {FeeMath} from "../contracts/libraries/FeeMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Tests pinning the meaning of `spreadFeeE6`.
/// @dev `spreadFeeE6` is the PLATFORM share (protocol + admin) taken FROM the bin swap fee inside
///      `SwapMath` (`platformSpreadFee = spreadLeg * spreadFeeE6 / 1e6`), NOT a markup applied on
///      top of it. Therefore changing `spreadFeeE6` must redistribute the fee between LPs and the
///      platform while leaving the amounts the trader pays/receives — and the quoted prices — untouched.
///      Grossing the fee up by `(1e6 + spreadFeeE6) / 1e6` would double-count the spread share and
///      inflate trader fees by up to 2x at the factory's hard caps.
contract MetricOmmPoolSpreadFeeSplitTest is MetricOmmPoolBaseTest {
  address internal swapper;

  // ~2% oracle spread => a materially non-zero baseFeeX64 (~1%), so the fee path is actually live.
  uint128 internal constant BID_P = uint128(uint256(Q64) * 99 / 100);
  uint128 internal constant ASK_P = uint128(uint256(Q64) * 101 / 100);

  uint128 internal constant SWAP_AMOUNT = 1_000_000;
  // Total spread share at the factory hard caps (500_000 protocol + 500_000 admin would be 1e6);
  // 500_000 is a large but legal value that makes any double-count obvious.
  uint24 internal constant SPREAD_MAX_E6 = 500_000;

  function setUp() public override {
    super.setUp();
    swapper = users[0];
    _addLiquidity(1, -1, 0, 10_000_000, 0);
    oracle.setBidAndAskPrice(BID_P, ASK_P);
  }

  /// @dev The platform spread fee accrues as pool balance in excess of the bins' scaled totals.
  function _surplus0Scaled() internal view returns (uint256) {
    PoolImmutables memory imm = IMetricOmmPool(address(pool)).getImmutables();
    (uint128 inBins0,) = PoolStateLibrary._slot1(address(pool));
    return (token0.balanceOf(address(pool)) * imm.token0ScaleMultiplier) - inBins0;
  }

  function _surplus1Scaled() internal view returns (uint256) {
    PoolImmutables memory imm = IMetricOmmPool(address(pool)).getImmutables();
    (, uint128 inBins1) = PoolStateLibrary._slot1(address(pool));
    return (token1.balanceOf(address(pool)) * imm.token1ScaleMultiplier) - inBins1;
  }

  function test_exactIn_traderAmountsIndependentOfSpreadShare() public {
    uint256 snap = vm.snapshotState();

    pool.setPoolFees(0, 0);
    (int256 a0Zero, int256 a1Zero) = _swap(0, swapper, false, _i128ExactIn(SWAP_AMOUNT), type(uint128).max);
    uint256 surplusZero = _surplus1Scaled();

    vm.revertToState(snap);

    pool.setPoolFees(SPREAD_MAX_E6, 0);
    (int256 a0Max, int256 a1Max) = _swap(0, swapper, false, _i128ExactIn(SWAP_AMOUNT), type(uint128).max);
    uint256 surplusMax = _surplus1Scaled();

    // The trader's economics must not depend on how the fee is split.
    assertEq(a0Max, a0Zero, "exact-in: token0 out changed with spread share");
    assertEq(a1Max, a1Zero, "exact-in: token1 in changed with spread share");

    // Sanity: the split is real and the fee path is non-trivial, so the test above is not vacuous.
    assertEq(surplusZero, 0, "no protocol surplus expected at spreadFeeE6 = 0");
    assertGt(surplusMax, 0, "protocol must accrue its share at spreadFeeE6 > 0");
  }

  function test_exactOut_traderAmountsIndependentOfSpreadShare() public {
    uint256 snap = vm.snapshotState();

    pool.setPoolFees(0, 0);
    (int256 a0Zero, int256 a1Zero) = _swap(0, swapper, false, _i128ExactOut(SWAP_AMOUNT), type(uint128).max);

    vm.revertToState(snap);

    pool.setPoolFees(SPREAD_MAX_E6, 0);
    (int256 a0Max, int256 a1Max) = _swap(0, swapper, false, _i128ExactOut(SWAP_AMOUNT), type(uint128).max);

    assertEq(a0Max, a0Zero, "exact-out: token0 out changed with spread share");
    assertEq(a1Max, a1Zero, "exact-out: token1 in changed with spread share");
  }

  /// @dev The same invariant on the sell side (zeroForOne), which uses `addFeeSellE6`.
  function test_sellSide_traderAmountsIndependentOfSpreadShare() public {
    uint256 snap = vm.snapshotState();

    pool.setPoolFees(0, 0);
    (int256 a0Zero, int256 a1Zero) = _swap(0, swapper, true, _i128ExactIn(SWAP_AMOUNT), 0);
    uint256 surplusZero = _surplus0Scaled();

    vm.revertToState(snap);

    pool.setPoolFees(SPREAD_MAX_E6, 0);
    (int256 a0Max, int256 a1Max) = _swap(0, swapper, true, _i128ExactIn(SWAP_AMOUNT), 0);
    uint256 surplusMax = _surplus0Scaled();

    assertEq(a0Max, a0Zero, "sell: token0 in changed with spread share");
    assertEq(a1Max, a1Zero, "sell: token1 out changed with spread share");

    assertEq(surplusZero, 0, "no protocol surplus expected at spreadFeeE6 = 0");
    assertGt(surplusMax, 0, "protocol must accrue its share at spreadFeeE6 > 0");
  }

  /// @dev `getSellAndBuyPrices` must quote what a swap actually executes at, so it is subject to
  ///      the same invariant — it shares `_binSwapFeeX64` with the swap loop.
  function test_quotedPricesIndependentOfSpreadShare() public {
    pool.setPoolFees(0, 0);
    (uint128 bidZero, uint128 askZero) = pool.getSellAndBuyPrices();

    pool.setPoolFees(SPREAD_MAX_E6, 0);
    (uint128 bidMax, uint128 askMax) = pool.getSellAndBuyPrices();

    assertEq(bidMax, bidZero, "quoted sell price changed with spread share");
    assertEq(askMax, askZero, "quoted buy price changed with spread share");
  }

  /// @dev The `Swap` event's fee field must actually carry the carved platform spread fee.
  ///      Regression guard: nothing in the suite read this value, so when `_executeSwap`'s named
  ///      return was accidentally shadowed by a same-named local the event silently reported 0 and
  ///      all 252 tests still passed. Integrators and extensions consume this number.
  function test_swapEventReportsPlatformSpreadFee() public {
    bytes32 swapTopic = keccak256("Swap(address,address,uint256,uint256,uint256)");

    pool.setPoolFees(SPREAD_MAX_E6, 0);

    vm.recordLogs();
    _swap(0, swapper, false, _i128ExactIn(SWAP_AMOUNT), type(uint128).max);
    Vm.Log[] memory logs = vm.getRecordedLogs();

    uint256 reported = type(uint256).max;
    for (uint256 i = 0; i < logs.length; i++) {
      if (logs[i].emitter == address(pool) && logs[i].topics[0] == swapTopic) {
        (,, Packed2Uint128 f) = abi.decode(logs[i].data, (PackedSwapDetails, Packed2Int128, Packed2Uint128));
        reported = f.sum();
      }
    }
    assertTrue(reported != type(uint256).max, "Swap event not found");

    assertGt(reported, 0, "Swap event must report a non-zero platform spread fee");
    // The platform spread fee is exactly what is held back from the bins, i.e. the pool's surplus.
    assertEq(reported, _surplus1Scaled(), "reported fee must equal the accrued platform surplus");
  }

  /// @dev ...and it must be zero when the platform takes no share, so the assertion above cannot be
  ///      satisfied by reporting some unrelated non-zero quantity.
  function test_swapEventReportsZeroWhenPlatformShareIsZero() public {
    bytes32 swapTopic = keccak256("Swap(address,address,uint256,uint256,uint256)");

    pool.setPoolFees(0, 0);

    vm.recordLogs();
    _swap(0, swapper, false, _i128ExactIn(SWAP_AMOUNT), type(uint128).max);
    Vm.Log[] memory logs = vm.getRecordedLogs();

    for (uint256 i = 0; i < logs.length; i++) {
      if (logs[i].emitter == address(pool) && logs[i].topics[0] == swapTopic) {
        (,, Packed2Uint128 f) = abi.decode(logs[i].data, (PackedSwapDetails, Packed2Int128, Packed2Uint128));
        uint256 reported = f.sum();
        assertEq(reported, 0, "no platform share => no platform fee reported");
      }
    }
  }

  bytes32 internal constant BIN_SWAPPED_TOPIC = keccak256("BinSwapped(int256,uint256,uint256)");

  function _sumBinSwappedLpFees(Vm.Log[] memory logs) internal view returns (uint256 total, uint256 count) {
    for (uint256 i = 0; i < logs.length; i++) {
      if (logs[i].emitter == address(pool) && logs[i].topics[0] == BIN_SWAPPED_TOPIC) {
        (,, Packed2Uint128 fees) = abi.decode(logs[i].data, (int256, Packed2Int128, Packed2Uint128));
        total += fees.high();
        count++;
      }
    }
  }

  /// @dev When the platform takes 100% of the spread, LPs get nothing, so every `BinSwapped` must
  ///      report a zero LP fee. This is the sharpest available check that `lpFeeAmount` is derived
  ///      from the right base: reconstructing the gross input by adding the platform take back onto
  ///      a delta that is ALREADY gross double-counts, and inflates this number above zero.
  function test_binSwappedLpFeeIsZeroWhenPlatformTakesTheWholeSpread() public {
    pool.setPoolFees(1e6, 0); // platform takes 100% of the spread leg

    vm.recordLogs();
    _swap(0, swapper, false, _i128ExactIn(SWAP_AMOUNT), type(uint128).max);
    (uint256 lpTotal, uint256 count) = _sumBinSwappedLpFees(vm.getRecordedLogs());

    assertGt(count, 0, "expected at least one BinSwapped");
    assertEq(lpTotal, 0, "LPs must earn nothing when the platform takes the entire spread");
  }

  /// @dev Mirror: when the platform takes nothing, the LP fee is the whole carved fee, so it must be
  ///      strictly positive and must not exceed what the trader actually paid over the fee-exclusive
  ///      notional. Guards against the LP fee being understated or unbounded.
  function test_binSwappedLpFeeIsWholeCarvedFeeWhenPlatformTakesNothing() public {
    pool.setPoolFees(0, 0);

    vm.recordLogs();
    (, int256 a1) = _swap(0, swapper, false, _i128ExactIn(SWAP_AMOUNT), type(uint128).max);
    (uint256 lpTotal, uint256 count) = _sumBinSwappedLpFees(vm.getRecordedLogs());

    assertGt(count, 0, "expected at least one BinSwapped");
    assertGt(lpTotal, 0, "LPs must earn the fee when the platform takes nothing");
    // The whole fee is carved out of the trader's input, so it can never exceed that input.
    assertLt(lpTotal, uint256(a1), "LP fee cannot exceed the trader's input");
    // With no platform take, nothing leaves the bins: the pool holds no surplus.
    assertEq(_surplus1Scaled(), 0, "no platform take => no surplus");
  }

  /// @dev Platform take as a fraction of gross: carve the whole fee out, then take the platform's part.
  function _platformTakeOfGrossX64(uint256 totalFeeX64, uint256 notionalX64) internal pure returns (uint256) {
    return (FeeMath.totalFeeOfGrossX64(totalFeeX64)
          * FeeMath.platformPartOfTotalFeeX64(totalFeeX64, notionalX64, SPREAD_MAX_E6)) >> 64;
  }

  /// @dev The fee rates are applied identically in both directions, which is only sound if
  ///      `gross = net * (1 + f)` holds in the INPUT token either way. It does: on a buy the token1
  ///      input scales with price and `effectivePriceX64` multiplies; on a sell the token0 input
  ///      scales with 1/price and it divides. The direction asymmetry is absorbed entirely by the
  ///      price construction, so everything downstream -- the carve and the split -- is
  ///      direction-agnostic. This test pins that: the same rate governs both legs.
  function test_platformTakeRateIsDirectionIndependent() public {
    uint24 notionalFeeE8 = 500_000; // 0.5%
    pool.setPoolFees(SPREAD_MAX_E6, notionalFeeE8);

    // The mock oracle's reference is the geometric mean of bid/ask, which makes the two base fees
    // equal by construction (`ask/ref == ref/bid == sqrt(ask/bid)`), so any residual asymmetry in the
    // measured take would have to come from the fee math itself.
    uint256 ref = Math.sqrt(uint256(BID_P) * uint256(ASK_P));
    uint256 buyBaseX64 = SwapMath.buyBaseFeeX64FromAskAndReference(ASK_P, ref);
    uint256 sellBaseX64 = SwapMath.sellBaseFeeX64FromBidAndReference(BID_P, ref);
    // Equal to within one ULP (`Math.sqrt` floors the reference before either mulDiv rounds up).
    assertApproxEqAbs(buyBaseX64, sellBaseX64, 1, "geometric-mean reference must give symmetric base fees");

    uint256 notionalX64 = FeeMath._notionalFeeX64(notionalFeeE8);
    uint256 buyRateX64 = _platformTakeOfGrossX64(buyBaseX64 + notionalX64, notionalX64);
    uint256 sellRateX64 = _platformTakeOfGrossX64(sellBaseX64 + notionalX64, notionalX64);
    assertGt(buyRateX64, 0, "expected a non-zero platform rate");

    assertEq(_surplus0Scaled(), 0, "clean start");
    assertEq(_surplus1Scaled(), 0, "clean start");

    // Buy: token1 is the input leg. Everything withheld from the bins is the platform take.
    uint256 snap = vm.snapshotState();
    (, int256 a1) = _swap(0, swapper, false, _i128ExactIn(SWAP_AMOUNT), type(uint128).max);
    uint256 buyGross = uint256(a1);
    uint256 buyTake = _surplus1Scaled();
    vm.revertToState(snap);

    // Sell: token0 is the input leg.
    (int256 a0,) = _swap(0, swapper, true, _i128ExactIn(SWAP_AMOUNT), 0);
    uint256 sellGross = uint256(a0);
    uint256 sellTake = _surplus0Scaled();

    // The SAME formula, applied to the gross input, reproduces the take in both directions. Tolerance
    // of 1 covers the per-bin flooring if the swap happens to straddle a bin boundary.
    assertApproxEqAbs(buyTake, (buyGross * buyRateX64) >> 64, 1, "buy take must equal gross * rate");
    assertApproxEqAbs(sellTake, (sellGross * sellRateX64) >> 64, 1, "sell take must equal gross * rate");
    // Same specified input and (to a ULP) the same fee either way, so the same take must fall out.
    assertApproxEqAbs(buyTake, sellTake, 1, "the platform rate must be direction-independent");
  }
}
