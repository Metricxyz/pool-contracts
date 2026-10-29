// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @notice Two `uint128` values in one word: `high` in the top 128 bits, `low` in the bottom.
/// @dev Used to keep event payloads to a single word where two quantities always travel together.
///      What `high` and `low` mean is documented at each use site, not here.
///      `pack` takes `uint128` halves so narrowing -- and the choice of a checked or unchecked cast --
///      is the caller's, made visibly at the call site.
type Packed2Uint128 is uint256;

using Packed2Uint128Lib for Packed2Uint128 global;

/// @dev Implemented in assembly. Inline assembly reads the raw stack slot, which Solidity does not
///      guarantee to be free of dirty high-order bits, so every half is masked to 128 bits before use.
///      The masks are load-bearing, not defensive: see `test/Packed.t.sol`.
library Packed2Uint128Lib {
  uint256 private constant MASK = 0xffffffffffffffffffffffffffffffff;

  function pack(uint128 high_, uint128 low_) internal pure returns (Packed2Uint128 packed) {
    assembly ("memory-safe") {
      packed := or(shl(128, and(high_, MASK)), and(low_, MASK))
    }
  }

  /// @notice Add to BOTH halves at once.
  /// @dev One word, one ADD -- valid because a running total can never reach 2^128 and so cannot carry
  ///      out of the low half into the high one. Callers relying on this must keep both halves bounded.
  function addBoth(Packed2Uint128 acc, uint128 high_, uint128 low_) internal pure returns (Packed2Uint128 packed) {
    assembly ("memory-safe") {
      packed := add(acc, or(shl(128, and(high_, MASK)), and(low_, MASK)))
    }
  }

  function high(Packed2Uint128 packed) internal pure returns (uint256 value) {
    assembly ("memory-safe") {
      value := shr(128, packed)
    }
  }

  function low(Packed2Uint128 packed) internal pure returns (uint256 value) {
    assembly ("memory-safe") {
      value := and(packed, MASK)
    }
  }

  function sum(Packed2Uint128 packed) internal pure returns (uint256 value) {
    assembly ("memory-safe") {
      value := add(shr(128, packed), and(packed, MASK))
    }
  }
}

/// @notice Two `int128` values in one word: `high` in the top 128 bits, `low` in the bottom.
/// @dev Two's-complement halves. Same contract as `Packed2Uint128`: meaning is documented at the use
///      site, and `pack` takes `int128` halves so the narrowing happens visibly in the caller.
type Packed2Int128 is uint256;

using Packed2Int128Lib for Packed2Int128 global;

/// @dev Implemented in assembly. The `low_` mask in `pack` is ESSENTIAL, not defensive: a negative
///      `int128` is sign-extended on the stack, so without it the all-ones upper half would be OR'd
///      straight over `high_` and destroy it. Reading back uses `SIGNEXTEND`, which is exactly the
///      `int256(int128(uint128(...)))` cast chain in one opcode.
library Packed2Int128Lib {
  uint256 private constant MASK = 0xffffffffffffffffffffffffffffffff;
  /// @dev Byte index for `SIGNEXTEND` on a 16-byte (128-bit) value.
  uint256 private constant SIGN_BYTE = 15;

  function pack(int128 high_, int128 low_) internal pure returns (Packed2Int128 packed) {
    assembly ("memory-safe") {
      packed := or(shl(128, and(high_, MASK)), and(low_, MASK))
    }
  }

  function high(Packed2Int128 packed) internal pure returns (int256 value) {
    assembly ("memory-safe") {
      value := signextend(SIGN_BYTE, shr(128, packed))
    }
  }

  function low(Packed2Int128 packed) internal pure returns (int256 value) {
    assembly ("memory-safe") {
      value := signextend(SIGN_BYTE, packed)
    }
  }
}

/// @notice A swap's mode flag and resulting bin position in one word.
/// @dev Purpose-built (unlike the two generic pairs above) because the three fields are heterogeneous
///      and always travel together on `Swap`. Layout, low bits first:
///
///        bits   0..103 : posInBin   (uint104)
///        bits 104..119 : binIdx     (int16, two's complement)
///        bit       120 : exactInput (1 = the caller specified an exact input)
///
///      121 bits total, so the three fit one word with room to spare and cost one log word instead of
///      three. `binIdx` is signed, so reads sign-extend it -- see `test/Packed.t.sol`.
///
///      Each field is exactly as wide as its parameter, so nothing a caller can construct is ever
///      truncated.
type PackedSwapDetails is uint256;

using PackedSwapDetailsLib for PackedSwapDetails global;

library PackedSwapDetailsLib {
  uint256 private constant POS_MASK = 0xffffffffffffffffffffffffff;
  uint256 private constant BIN_IDX_MASK = 0xffff;
  uint256 private constant BIN_IDX_SHIFT = 104;
  uint256 private constant EXACT_INPUT_SHIFT = 120;
  /// @dev Byte index for `SIGNEXTEND` on a 2-byte (16-bit) value.
  uint256 private constant SIGN_BYTE = 1;

  /// @dev The `binIdx_` mask is load-bearing: a negative index is sign-extended and would otherwise
  ///      smear over the flag, which `test/Packed.t.sol` pins.
  ///
  ///      The `posInBin_` mask is NOT reachable and no test covers it: a `uint104` cannot hold a value
  ///      above the field, and Solidity cleans the parameter at this boundary. It is kept only because
  ///      the optimizer elides it (measured: zero bytes) and it would matter if the field or the
  ///      parameter ever diverged. Do not read it as verified behaviour.
  function pack(bool exactInput_, int16 binIdx_, uint104 posInBin_) internal pure returns (PackedSwapDetails packed) {
    assembly ("memory-safe") {
      packed := or(
        or(shl(EXACT_INPUT_SHIFT, and(exactInput_, 1)), shl(BIN_IDX_SHIFT, and(binIdx_, BIN_IDX_MASK))),
        and(posInBin_, POS_MASK)
      )
    }
  }

  /// @notice Whether `amountSpecified` was treated as an exact input.
  function exactInput(PackedSwapDetails packed) internal pure returns (bool value) {
    assembly ("memory-safe") {
      value := and(shr(EXACT_INPUT_SHIFT, packed), 1)
    }
  }

  /// @notice Active bin index after the swap. Signed, so this sign-extends.
  function binIdx(PackedSwapDetails packed) internal pure returns (int256 value) {
    assembly ("memory-safe") {
      value := signextend(SIGN_BYTE, shr(BIN_IDX_SHIFT, packed))
    }
  }

  /// @notice Position within `binIdx` after the swap.
  function posInBin(PackedSwapDetails packed) internal pure returns (uint256 value) {
    assembly ("memory-safe") {
      value := and(packed, POS_MASK)
    }
  }
}
