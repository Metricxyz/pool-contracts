// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {SwapMath, ONE_X64} from "../contracts/libraries/SwapMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Locks in documented gross-input rounding and LP-fee extraction helpers used in exact-in bin paths.
contract SwapMathRoundingTest is Test {
  function test_grossInputWithBinFeeCeil_matchesDirectCeilDiv() public pure {
    uint256 fee = 1 << 60;
    uint256 onePlus = ONE_X64 + fee;
    uint256 net = 123_456_789;
    uint256 a = SwapMath.grossInputWithBinFeeCeil(net, onePlus);
    uint256 b = Math.ceilDiv(net * onePlus, ONE_X64);
    assertEq(a, b);
  }

  function test_lpFeeScaledFromGrossInput_splitsAtOnePlusFee() public pure {
    uint256 fee = 1 << 62;
    uint256 onePlus = ONE_X64 + fee;
    uint256 gross = 9_999_999;
    uint256 leg = SwapMath.lpFeeScaledFromGrossInput(gross, fee, onePlus);
    uint256 legRef = (gross * fee) / onePlus;
    assertEq(leg, legRef);
  }
}
