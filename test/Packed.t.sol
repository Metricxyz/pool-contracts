// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;
// forge-lint: disable-start(unsafe-typecast, mixed-case-function, mixed-case-variable)

import {Test} from "forge-std/Test.sol";
import {
  Packed2Uint128,
  Packed2Uint128Lib,
  Packed2Int128,
  Packed2Int128Lib,
  PackedSwapDetails,
  PackedSwapDetailsLib
} from "../contracts/types/Packed.sol";

/// @notice Unit tests for the packing primitives, independent of the pool.
/// @dev These libraries are written in inline assembly, which opts out of the compiler's cleanliness
///      and sign-extension guarantees. The masks and `SIGNEXTEND` are therefore load-bearing, and these
///      tests exist to prove that rather than assume it.
contract PackedTest is Test {
  uint256 internal constant MASK = type(uint128).max;

  // ---------------------------------------------------------------- Packed2Uint128

  function testFuzz_uint128_roundTrips(uint128 high_, uint128 low_) public pure {
    Packed2Uint128 p = Packed2Uint128Lib_pack(high_, low_);
    assertEq(p.high(), high_, "high half round-trips");
    assertEq(p.low(), low_, "low half round-trips");
  }

  function test_uint128_boundaries() public pure {
    Packed2Uint128 maxBoth = Packed2Uint128Lib_pack(type(uint128).max, type(uint128).max);
    assertEq(maxBoth.high(), type(uint128).max, "max high");
    assertEq(maxBoth.low(), type(uint128).max, "max low");
    assertEq(Packed2Uint128.unwrap(maxBoth), type(uint256).max, "both halves saturate the word");

    Packed2Uint128 zero = Packed2Uint128Lib_pack(0, 0);
    assertEq(Packed2Uint128.unwrap(zero), 0, "zero packs to zero");

    // A max low must not bleed into the high half -- the case the mask exists for.
    Packed2Uint128 lowOnly = Packed2Uint128Lib_pack(0, type(uint128).max);
    assertEq(lowOnly.high(), 0, "max low leaves high untouched");
    assertEq(lowOnly.low(), type(uint128).max, "max low preserved");
  }

  /// @dev The halves must be independent: changing one may never disturb the other.
  function testFuzz_uint128_halvesAreIndependent(uint128 high_, uint128 lowA, uint128 lowB) public pure {
    vm.assume(lowA != lowB);
    assertEq(Packed2Uint128Lib_pack(high_, lowA).high(), Packed2Uint128Lib_pack(high_, lowB).high(), "high unaffected");
  }

  function testFuzz_uint128_sumMatchesAddingTheHalves(uint128 high_, uint128 low_) public pure {
    assertEq(Packed2Uint128Lib_pack(high_, low_).sum(), uint256(high_) + uint256(low_), "sum adds both halves");
  }

  /// @dev `addBoth` is a single ADD on the whole word. It is only valid while neither running total
  ///      reaches 2^128; below that a carry can never cross from the low half into the high one.
  function testFuzz_uint128_addBothAccumulatesIndependently(uint128 h0, uint128 l0, uint128 dh, uint128 dl)
    public
    pure
  {
    // Keep both halves inside the no-carry regime the helper documents.
    h0 = uint128(bound(h0, 0, type(uint128).max / 2));
    l0 = uint128(bound(l0, 0, type(uint128).max / 2));
    dh = uint128(bound(dh, 0, type(uint128).max / 2));
    dl = uint128(bound(dl, 0, type(uint128).max / 2));

    Packed2Uint128 acc = Packed2Uint128Lib_pack(h0, l0).addBoth(dh, dl);
    assertEq(acc.high(), uint256(h0) + uint256(dh), "high accumulated");
    assertEq(acc.low(), uint256(l0) + uint256(dl), "low accumulated -- no carry into high");
  }

  /// @dev Pins the documented failure mode: once the low half exceeds 128 bits it carries into the
  ///      high half. Callers must keep totals bounded; this proves the boundary is where it is claimed.
  function test_uint128_addBothCarriesOnceLowHalfOverflows() public pure {
    Packed2Uint128 acc = Packed2Uint128Lib_pack(0, type(uint128).max);
    assertEq(acc.high(), 0, "high starts clean");
    acc = acc.addBoth(0, 1); // pushes the low half exactly over 2^128
    assertEq(acc.high(), 1, "carry lands in the high half, as documented");
    assertEq(acc.low(), 0, "low half wrapped");
  }

  // ---------------------------------------------------------------- Packed2Int128

  function testFuzz_int128_roundTripsIncludingNegatives(int128 high_, int128 low_) public pure {
    Packed2Int128 p = Packed2Int128Lib_pack(high_, low_);
    assertEq(p.high(), int256(high_), "high half round-trips with sign");
    assertEq(p.low(), int256(low_), "low half round-trips with sign");
  }

  function test_int128_boundaries() public pure {
    Packed2Int128 p = Packed2Int128Lib_pack(type(int128).min, type(int128).max);
    assertEq(p.high(), int256(type(int128).min), "int128 min survives");
    assertEq(p.low(), int256(type(int128).max), "int128 max survives");

    Packed2Int128 q = Packed2Int128Lib_pack(type(int128).max, type(int128).min);
    assertEq(q.high(), int256(type(int128).max), "swapped: max in high");
    assertEq(q.low(), int256(type(int128).min), "swapped: min in low");
  }

  /// @dev THE landmine this library exists to avoid. A negative `int128` is sign-extended on the stack,
  ///      so an unmasked `or(shl(128, high), low)` ORs all-ones over the high half and destroys it.
  ///      Every swap packs one negative leg by construction, so this would corrupt essentially all of them.
  function test_int128_negativeLowDoesNotCorruptHighHalf() public pure {
    Packed2Int128 p = Packed2Int128Lib_pack(int128(7), int128(-1));
    assertEq(p.high(), int256(7), "high half survives a negative low half");
    assertEq(p.low(), int256(-1), "low half is still -1");

    // What the unmasked version would have produced, for contrast.
    uint256 unmasked;
    int128 high_ = 7;
    int128 low_ = -1;
    assembly ("memory-safe") {
      unmasked := or(shl(128, high_), low_)
    }
    assertTrue(Packed2Int128.unwrap(p) != unmasked, "masked and unmasked genuinely differ");
    assertEq(int256(int128(uint128(unmasked >> 128))), int256(-1), "unmasked would read high back as -1");
  }

  /// @dev Sign of one half must never leak into the other, in either direction.
  function testFuzz_int128_signsDoNotLeak(int128 high_, int128 low_) public pure {
    Packed2Int128 p = Packed2Int128Lib_pack(high_, low_);
    if (high_ >= 0) assertGe(p.high(), 0, "non-negative high stays non-negative");
    if (high_ < 0) assertLt(p.high(), 0, "negative high stays negative");
    if (low_ >= 0) assertGe(p.low(), 0, "non-negative low stays non-negative");
    if (low_ < 0) assertLt(p.low(), 0, "negative low stays negative");
  }

  /// @dev The two types share a word layout, so a value packed as unsigned must read back through the
  ///      signed accessors as the same bits reinterpreted -- no accidental shifting between them.
  function testFuzz_layoutsAgreeBetweenTheTwoTypes(uint128 high_, uint128 low_) public pure {
    Packed2Uint128 u = Packed2Uint128Lib_pack(high_, low_);
    Packed2Int128 i = Packed2Int128.wrap(Packed2Uint128.unwrap(u));
    assertEq(uint256(uint128(int128(i.high()))), uint256(high_), "same high bits");
    assertEq(uint256(uint128(int128(i.low()))), uint256(low_), "same low bits");
  }

  // ---------------------------------------------------------------- PackedSwapDetails

  function testFuzz_details_roundTrips(bool exactInput_, int16 binIdx_, uint104 posInBin_) public pure {
    PackedSwapDetails d = PackedSwapDetailsLib.pack(exactInput_, binIdx_, posInBin_);
    assertEq(d.exactInput(), exactInput_, "exactInput round-trips");
    assertEq(d.binIdx(), int256(binIdx_), "binIdx round-trips with sign");
    assertEq(d.posInBin(), uint256(posInBin_), "posInBin round-trips");
  }

  function test_outcome_boundaries() public pure {
    PackedSwapDetails maxAll = PackedSwapDetailsLib.pack(true, type(int16).max, type(uint104).max);
    assertEq(maxAll.exactInput(), true, "flag set");
    assertEq(maxAll.binIdx(), int256(type(int16).max), "max bin index");
    assertEq(maxAll.posInBin(), uint256(type(uint104).max), "max position");

    PackedSwapDetails minIdx = PackedSwapDetailsLib.pack(false, type(int16).min, type(uint104).max);
    assertEq(minIdx.exactInput(), false, "flag clear");
    assertEq(minIdx.binIdx(), int256(type(int16).min), "min bin index");
    assertEq(minIdx.posInBin(), uint256(type(uint104).max), "max position beside min index");

    assertEq(PackedSwapDetails.unwrap(PackedSwapDetailsLib.pack(false, int16(0), uint104(0))), 0, "zero packs to zero");
  }

  /// @dev The three fields must not bleed into one another. A max position is the case most likely to
  ///      overflow into `binIdx`, and a negative `binIdx` the one most likely to smear into the flag.
  function test_outcome_fieldsAreIndependent() public pure {
    PackedSwapDetails a = PackedSwapDetailsLib.pack(false, int16(0), type(uint104).max);
    assertEq(a.binIdx(), int256(0), "max position must not touch binIdx");
    assertEq(a.exactInput(), false, "max position must not touch the flag");

    PackedSwapDetails b = PackedSwapDetailsLib.pack(false, int16(-1), uint104(0));
    assertEq(b.exactInput(), false, "a negative binIdx must not set the flag");
    assertEq(b.posInBin(), 0, "a negative binIdx must not smear into posInBin");

    PackedSwapDetails c = PackedSwapDetailsLib.pack(true, int16(-1), type(uint104).max);
    assertEq(c.exactInput(), true, "all three set");
    assertEq(c.binIdx(), int256(-1), "negative index beside max position");
    assertEq(c.posInBin(), uint256(type(uint104).max), "position intact");
  }

  /// @dev The full `uint104` range must survive and must not bleed into its neighbours.
  function test_details_fullWidthPositionSurvivesAndDoesNotBleed() public pure {
    PackedSwapDetails d = PackedSwapDetailsLib.pack(true, int16(-2), type(uint104).max);
    assertEq(d.posInBin(), uint256(type(uint104).max), "the whole uint104 range round-trips");
    assertEq(d.binIdx(), int256(-2), "a saturated position must not reach binIdx");
    assertEq(d.exactInput(), true, "a saturated position must not reach the flag");

    // A binIdx with a CLEAR low bit, so any stray bit from the position field would be visible.
    PackedSwapDetails e = PackedSwapDetailsLib.pack(false, int16(2), uint104(1) << 103);
    assertEq(e.binIdx(), int256(2), "top position bit must not reach binIdx");
    assertEq(e.exactInput(), false, "top position bit must not reach the flag");
  }

  /// @dev Only the documented 113 bits may be used, so the whole word is never dirtied.
  function testFuzz_details_usesOnlyItsDocumentedBits(bool e, int16 b, uint104 pos) public pure {
    assertEq(PackedSwapDetails.unwrap(PackedSwapDetailsLib.pack(e, b, pos)) >> 121, 0, "nothing above bit 120");
  }

  // `pack` is a library function on the type, not a method, so wrap it for readability above.
  function Packed2Uint128Lib_pack(uint128 h, uint128 l) private pure returns (Packed2Uint128) {
    return Packed2Uint128Lib.pack(h, l);
  }

  function Packed2Int128Lib_pack(int128 h, int128 l) private pure returns (Packed2Int128) {
    return Packed2Int128Lib.pack(h, l);
  }
}
