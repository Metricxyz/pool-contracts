// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Panic} from "@openzeppelin/contracts/utils/Panic.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title SignedMath
/// @notice Helpers for signed integer arithmetic
library SignedMath {
  using SafeCast for uint256;

  /// @notice Returns ceil(a / b), rounded toward positive infinity
  /// @dev Reverts on division by zero and on int256 min / -1 overflow (same behavior as Solidity division)
  function ceilDiv(int256 a, int256 b) internal pure returns (int256) {
    if (b == 0) {
      // Guarantee the same behavior as in a regular Solidity division.
      Panic.panic(Panic.DIVISION_BY_ZERO);
    }

    int256 quotient = a / b;
    int256 remainder = a % b;

    // If there is a remainder and the exact result is positive, round up by 1.
    if (remainder != 0 && (a ^ b) >= 0) {
      unchecked {
        quotient += 1;
      }
    }

    return quotient;
  }

  /// @notice Returns ceil(a / b), rounded toward positive infinity
  /// @dev Reverts on division by zero (same behavior as Solidity division).
  ///      Also reverts if b > type(int256).max due to checked conversion.
  function ceilDiv(int256 a, uint256 b) internal pure returns (int256) {
    if (b == 0) {
      // Guarantee the same behavior as in a regular Solidity division.
      Panic.panic(Panic.DIVISION_BY_ZERO);
    }

    return ceilDiv(a, b.toInt256());
  }
}
