// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {SwapMath, ONE_X64} from "../contracts/libraries/SwapMath.sol";
import {FeeMath} from "../contracts/libraries/FeeMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Locks in the fee carve-out and effective-price construction used by the bin paths.
/// @dev Prices handed to the bin math are fee-INCLUSIVE, so the fee is carved out of the gross input
///      rather than added on top. The bin math is told ONE number -- the combined platform take as a
///      fraction of gross -- and keeps everything else (the whole LP fee) in the bin. The orchestrator
///      splits that one amount back into its notional and spread legs.
contract SwapMathRoundingTest is Test {
  function test_platformPartOfTotalFee_isZeroWhenPlatformTakesNothing() public pure {
    uint256 fee = 1 << 60;
    // No notional leg and no platform share of the spread => the LPs keep the entire fee.
    assertEq(FeeMath.platformPartOfTotalFeeX64(fee, 0, 0), 0, "platform takes nothing");
    assertEq(FeeMath.platformPartOfTotalFeeX64(0, 0, 1e6), 0, "no fee at all");
  }

  function test_platformPartOfTotalFee_matchesRateOverTotal() public pure {
    uint256 notionalFeeX64 = 1 << 58;
    uint256 spreadFeeX64 = 1 << 60;
    uint256 totalFeeX64 = notionalFeeX64 + spreadFeeX64;
    uint256 shareE6 = 300_000; // 30% of the spread leg

    uint256 expectedRateX64 = notionalFeeX64 + Math.mulDiv(spreadFeeX64, shareE6, 1e6);
    assertEq(
      FeeMath.platformPartOfTotalFeeX64(totalFeeX64, notionalFeeX64, shareE6),
      Math.mulDiv(expectedRateX64, ONE_X64, totalFeeX64),
      "platform rate as a share of the whole fee"
    );
  }

  /// @dev The whole point of carving instead of adding on top: revenue must be identical.
  function test_carveFromGross_isInverseOfAddingFeeOnTop() public pure {
    uint256 fee = 1 << 60;
    uint256 net = 123_456_789;
    uint256 gross = Math.ceilDiv(net * (ONE_X64 + fee), ONE_X64);

    // Everything to the LPs: platform take is 0, so the LP leg is the entire carved fee.
    uint256 lp = (gross * FeeMath.totalFeeOfGrossX64(fee)) >> 64;
    assertApproxEqAbs(lp, gross - net, 1, "carved fee must match the fee that was added on top");
    assertEq(lp, (gross * fee) / (ONE_X64 + fee), "carve-out formula");
  }

  /// @dev The two legs must sum to EXACTLY the amount the bin withheld, or the platform accumulators
  ///      would drift away from the bin balances.
  /// @dev The notional leg splits the platform take the bin already withheld. At the boundary where
  ///      the platform's share is entirely notional it must be the WHOLE take -- computing it from the
  ///      gross instead would floor a wei off, which the pool-level notional tests pin exactly.
  function test_notionalPartOfPlatformTake_isWholeTakeWhenShareIsAllNotional() public pure {
    uint256 notionalFeeX64 = 1 << 58;
    uint256 totalFeeX64 = notionalFeeX64 + (1 << 60);

    // spreadFeeE6 == 0 => the platform's only claim is the notional leg.
    assertEq(
      FeeMath.notionalPartOfPlatformTake(12_345, totalFeeX64, notionalFeeX64, 0),
      12_345,
      "all-notional share must take the whole platform fee"
    );
  }

  function test_notionalPartOfPlatformTake_isProRataAndSumsToTheTake() public pure {
    uint256 notionalFeeX64 = 1 << 58;
    uint256 totalFeeX64 = notionalFeeX64 + (1 << 60);
    uint256 take = 1_000_003; // deliberately not divisible

    uint256 leg = FeeMath.notionalPartOfPlatformTake(take, totalFeeX64, notionalFeeX64, 300_000);
    assertGt(leg, 0, "a configured notional fee must produce a notional leg");
    assertLe(leg, take, "the notional leg can never exceed the take");
    // The caller derives the spread leg by subtraction, so the two always reconstruct the take.
    assertEq(leg + (take - leg), take, "legs sum to the take exactly");
  }

  function test_notionalPartOfPlatformTake_degenerateCases() public pure {
    assertEq(FeeMath.notionalPartOfPlatformTake(0, 1 << 60, 1 << 58, 1e6), 0, "no take => no leg");
    assertEq(FeeMath.notionalPartOfPlatformTake(100, 1 << 60, 0, 1e6), 0, "no notional fee => no leg");
  }

  function test_effectivePriceX64_buyMultipliesSellDivides() public pure {
    uint256 price = ONE_X64;
    uint256 fee = ONE_X64 / 100; // 1%

    uint256 buy = FeeMath.effectivePriceX64(price, fee, false);
    uint256 sell = FeeMath.effectivePriceX64(price, fee, true);

    assertEq(buy, Math.mulDiv(price, ONE_X64 + fee, ONE_X64, Math.Rounding.Ceil), "buy grosses up");
    assertEq(sell, Math.mulDiv(price, ONE_X64, ONE_X64 + fee, Math.Rounding.Floor), "sell nets down");
    assertGt(buy, price, "buyer pays above reference");
    assertLt(sell, price, "seller receives below reference");
  }

  /// @dev Zero fee must be an exact identity, or every fee-free path would drift by a wei.
  function testFuzz_effectivePriceX64_zeroFeeIsIdentity(uint128 priceX64) public pure {
    vm.assume(priceX64 > 0);
    assertEq(FeeMath.effectivePriceX64(priceX64, 0, false), priceX64, "buy identity");
    assertEq(FeeMath.effectivePriceX64(priceX64, 0, true), priceX64, "sell identity");
  }

  /// @dev The buy and sell legs are DUALS, not copies, and the asymmetry is deliberate.
  ///
  ///      The fee is always a markup on the INPUT token. On a buy the token1 input scales with price,
  ///      so charging it means multiplying by `1 + f`. On a sell the token0 input scales with 1/price,
  ///      so the same markup means DIVIDING by `1 + f`. The base fees are defined to match:
  ///      `ask/ref - 1` for buys and `ref/bid - 1` for sells.
  ///
  ///      The observable consequence, pinned here: a trade at the reference price lands exactly on the
  ///      oracle's own ask / bid. That is what makes the fee model self-consistent with the quote.
  function testFuzz_effectivePriceAtReferenceLandsOnTheOracleQuote(uint128 bidSeed, uint64 spreadSeed) public pure {
    uint256 bid = bound(bidSeed, 1e12, uint256(type(uint96).max));
    uint256 ask = bid + bound(spreadSeed, 1, bid / 4);
    uint256 ref = Math.sqrt(bid * ask);

    uint256 buyFeeX64 = SwapMath.buyBaseFeeX64FromAskAndReference(ask, ref);
    uint256 sellFeeX64 = SwapMath.sellBaseFeeX64FromBidAndReference(bid, ref);

    // Tolerance is RELATIVE because the base fee is a Q64.64 quantity: representing `ask/ref` in X64
    // costs ~2^-64 relative (~5e-20), which scales with the price. 1e-12 sits eight orders above that
    // floor and ten orders below an actual formula error (a `P * (1 - f)` sell leg is off by ~f^2).
    assertApproxEqRel(FeeMath.effectivePriceX64(ref, buyFeeX64, false), ask, 1e6, "buy leg must land on the ask");
    assertApproxEqRel(FeeMath.effectivePriceX64(ref, sellFeeX64, true), bid, 1e6, "sell leg must land on the bid");
  }

  /// @dev And the tempting "symmetric" alternative is wrong: `P * (1 - f)` is only the first-order
  ///      approximation of `P / (1 + f)`, so it undershoots the bid by roughly `f^2` -- real money once
  ///      the spread is wide. This test exists so the sell leg is not "simplified" into a multiply.
  function test_sellLegAsMultiplyWouldMissTheBid() public pure {
    uint256 bid = (90 * ONE_X64) / 100;
    uint256 ask = (110 * ONE_X64) / 100;
    uint256 ref = Math.sqrt(bid * ask);
    uint256 sellFeeX64 = SwapMath.sellBaseFeeX64FromBidAndReference(bid, ref);

    // What the implementation does: divide. Lands on the quote.
    assertApproxEqAbs(FeeMath.effectivePriceX64(ref, sellFeeX64, true), bid, 1, "divide lands on the bid");

    // What multiplying would do: pay the seller strictly less than the quoted bid.
    uint256 naive = Math.mulDiv(ref, ONE_X64 - sellFeeX64, ONE_X64);
    assertLt(naive, bid, "P*(1-f) undershoots the bid");
  }
}
