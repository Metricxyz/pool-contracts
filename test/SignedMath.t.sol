// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {SignedMath} from "../contracts/libraries/SignedMath.sol";

contract SignedMathHarness {
  function ceilDiv(int256 a, int256 b) external pure returns (int256) {
    return SignedMath.ceilDiv(a, b);
  }

  function ceilDivU(int256 a, uint256 b) external pure returns (int256) {
    return SignedMath.ceilDiv(a, b);
  }
}

contract SignedMathTest is Test {
  SignedMathHarness internal harness;

  function setUp() external {
    harness = new SignedMathHarness();
  }

  function test_ceilDiv_roundsUpForPositiveDivision() external pure {
    assertEq(SignedMath.ceilDiv(int256(7), int256(3)), 3);
    assertEq(SignedMath.ceilDiv(int256(6), int256(3)), 2);
    assertEq(SignedMath.ceilDiv(int256(1), int256(3)), 1);
  }

  function test_ceilDiv_roundsTowardHigherNumberForNegativeResults() external pure {
    assertEq(SignedMath.ceilDiv(int256(-7), int256(3)), -2);
    assertEq(SignedMath.ceilDiv(int256(7), int256(-3)), -2);
    assertEq(SignedMath.ceilDiv(int256(-1), int256(2)), 0);
  }

  function test_ceilDiv_roundsUpForBothNegativeOperands() external pure {
    assertEq(SignedMath.ceilDiv(int256(-7), int256(-3)), 3);
    assertEq(SignedMath.ceilDiv(int256(-6), int256(-3)), 2);
    assertEq(SignedMath.ceilDiv(int256(-1), int256(-2)), 1);
  }

  function test_ceilDiv_zeroNumerator() external pure {
    assertEq(SignedMath.ceilDiv(int256(0), int256(3)), 0);
    assertEq(SignedMath.ceilDiv(int256(0), int256(-3)), 0);
  }

  function test_ceilDiv_intByUint_roundsTowardHigherNumber() external pure {
    assertEq(SignedMath.ceilDiv(int256(7), uint256(3)), 3);
    assertEq(SignedMath.ceilDiv(int256(-7), uint256(3)), -2);
    assertEq(SignedMath.ceilDiv(int256(-1), uint256(2)), 0);
  }

  function test_ceilDiv_revertsOnDivisionByZero() external {
    vm.expectRevert();
    harness.ceilDiv(1, 0);
  }

  function test_ceilDiv_revertsOnMinIntDivNegativeOne() external {
    vm.expectRevert();
    harness.ceilDiv(type(int256).min, -1);
  }

  function test_ceilDiv_intByUint_revertsOnDivisionByZero() external {
    vm.expectRevert();
    harness.ceilDivU(1, 0);
  }
}
