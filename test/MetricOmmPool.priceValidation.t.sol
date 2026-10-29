// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;
// forge-lint: disable-start(unsafe-typecast)

import {MetricOmmPoolBaseTest, Q64} from "./MetricOmmPool.base.t.sol";
import {IMetricOmmPoolActions} from "../contracts/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";

/// @notice Covers `simulateSwapAndRevert`'s bid/ask/reference validation, including boundary reference prices.
contract MetricOmmPoolPriceValidationTest is MetricOmmPoolBaseTest {
  uint128 internal constant BID = uint128(Q64);
  uint128 internal constant ASK = uint128(Q64 + Q64 / 100); // 1% spread

  function setUp() public override {
    super.setUp();
    _addLiquidity(1, -5, 4, 10_000_000, 0);
  }

  function _simulate(uint128 bid, uint128 ask, uint128 referencePrice) internal {
    pool.simulateSwapAndRevert(
      address(this), users[0], false, int128(1000), type(uint128).max, bid, ask, referencePrice, bytes("")
    );
  }

  /// @dev `simulateSwapAndRevert` always reverts on success too (with `SimulateSwap`), so validation-passed
  ///      cases are asserted by decoding the revert selector rather than `vm.expectRevert`.
  function _assertValidationPasses(uint128 bid, uint128 ask, uint128 referencePrice) internal {
    (bool success, bytes memory reason) = address(pool)
      .call(
        abi.encodeCall(
          IMetricOmmPoolActions.simulateSwapAndRevert,
          (address(this), users[0], false, int128(1000), type(uint128).max, bid, ask, referencePrice, bytes(""))
        )
      );
    assertFalse(success, "simulateSwapAndRevert should revert");
    // forge-lint: disable-next-line(unsafe-typecast)
    assertEq(bytes4(reason), IMetricOmmPoolActions.SimulateSwap.selector, "expected SimulateSwap (validation passed)");
  }

  function test_simulateSwap_revertsWhenBidGreaterThanAsk() public {
    vm.expectRevert(IMetricOmmPoolActions.BidGreaterThanAsk.selector);
    _simulate(ASK, BID, BID);
  }

  function test_simulateSwap_revertsWhenBidIsZero() public {
    vm.expectRevert(IMetricOmmPoolActions.BidIsZero.selector);
    _simulate(0, ASK, 0);
  }

  function test_simulateSwap_revertsWhenReferenceBelowBid() public {
    vm.expectRevert(IMetricOmmPoolActions.ReferencePriceOutOfRange.selector);
    _simulate(BID, ASK, BID - 1);
  }

  function test_simulateSwap_revertsWhenReferenceAboveAsk() public {
    vm.expectRevert(IMetricOmmPoolActions.ReferencePriceOutOfRange.selector);
    _simulate(BID, ASK, ASK + 1);
  }

  /// @dev Reference exactly at the bid boundary is valid and intentionally waives the sell-side base fee;
  ///      a successful validation falls through to swap execution, which always ends in `SimulateSwap`.
  function test_simulateSwap_allowsReferenceAtBidBoundary() public {
    _assertValidationPasses(BID, ASK, BID);
  }

  /// @dev Reference exactly at the ask boundary is valid and intentionally waives the buy-side base fee.
  function test_simulateSwap_allowsReferenceAtAskBoundary() public {
    _assertValidationPasses(BID, ASK, ASK);
  }
}
