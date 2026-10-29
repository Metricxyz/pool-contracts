// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {MetricOmmPoolBaseTest, MockERC20, MockPriceProvider, TestCaller, Q64} from "./MetricOmmPool.base.t.sol";
import {BinState} from "../contracts/types/PoolStorage.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title Spread regression test — verifies no artificial rounding spread.
///
/// With X64 fee representation and oracle ask = bid + 1, the baseFeeX64 is 0
/// (because ceilDiv(ask * 2^64, mid) - 2^64 rounds to 0 for near-equal ask/bid).
/// Combined with zero protocol/admin fees and zero bin fees, swaps should be
/// essentially free — the only loss comes from integer rounding in swap math.
/// For sufficiently large amounts (>= 1e10) this rounding loss must be < 1e-8 relative.
contract MetricOmmPoolSpreadTest is MetricOmmPoolBaseTest {
  using SafeCast for uint256;
  using SafeCast for int256;

  uint256 constant SWAPPER = 0;
  uint256 constant LP = 1;

  function setUp() public override {
    factory = address(this);
    admin = address(this);
    adminFeeDestination = makeAddr("fees");

    token0 = new MockERC20("Token0", "TK0", 6);
    token1 = new MockERC20("Token1", "TK1", 6);

    // ask = bid + 1 → baseFeeX64 = 0 with X64 precision
    oracle = new MockPriceProvider();
    oracle.setBidAndAskPrice(Q64.toUint128(), (Q64 + 1).toUint128());

    uint256[] memory posBins = _singleBinDataLegacyOneSlot(1);
    uint256[] memory negBins = _singleBinDataLegacyOneSlot(1);
    (BinState[] memory nonNegativeBinStates, BinState[] memory negativeBinStates) = _unpackBinStates(posBins, negBins);

    delete users;
    delete callers;

    pool = _deployPoolAndRegister(
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

    for (uint256 i = 0; i < 2; i++) {
      address user = makeAddr(string(abi.encodePacked("u", vm.toString(i))));
      users.push(user);
      TestCaller c = new TestCaller(user, factory);
      callers.push(c);
      _setupUser(user, c, address(pool));
    }

    // With 6-decimal tokens the scale multiplier is 1e12, so each share provides
    // only 1 scaled unit (= 1e-12 external).  Use 1e27 shares so each bin holds
    // ~1e15 external tokens — swap amounts (up to 1e12) move < 0.1% of the bin,
    // keeping solver rounding negligible.
    _addLiquidity(LP, -1, 0, 1e27, 0);
  }

  function _singleBinDataLegacyOneSlot(uint16 len) internal pure returns (uint256[] memory d) {
    d = new uint256[](1);
    d[0] = uint256(uint48(len));
  }

  // ─── tests ───

  /// @notice Roundtrip token1 → token0 → token1 with zero fees.
  ///         The total roundtrip loss must be < 1e-8 relative to the swap amount.
  function test_roundtrip_noArtificialSpread() public {
    uint128[3] memory amounts = [uint128(1e10), uint128(1e11), uint128(1e12)];

    for (uint256 i; i < amounts.length; i++) {
      if (i > 0) setUp();
      uint128 A = amounts[i];

      // leg 1: token1 → token0
      (int256 d0,) = _swap(SWAPPER, address(callers[SWAPPER]), false, _i128ExactIn(A), type(uint128).max);
      uint256 got0 = _u128FromNegDelta(d0);

      // leg 2: token0 → token1
      (, int256 d1) = _swap(SWAPPER, address(callers[SWAPPER]), true, _i128ExactIn(got0.toUint128()), 0);
      uint256 got1 = _u128FromNegDelta(d1);

      uint256 loss = A - got1;

      // With X64 fee = 0, loss is purely from integer rounding → must be < 1e-8 relative
      assertLt(loss * 1e8, uint256(A), "Roundtrip loss exceeds 1e-8");
    }
  }

  /// @notice Roundtrip token0 → token1 → token0 with zero fees.
  function test_roundtrip_noArtificialSpread_reverseDirection() public {
    uint128[3] memory amounts = [uint128(1e10), uint128(1e11), uint128(1e12)];

    for (uint256 i; i < amounts.length; i++) {
      if (i > 0) setUp();
      uint128 A = amounts[i];

      // Seed just enough token1 into the current bin for the roundtrip
      _swap(SWAPPER, address(callers[SWAPPER]), false, _i128ExactIn(A * 2), type(uint128).max);

      // leg 1: token0 → token1
      (, int256 d1) = _swap(SWAPPER, address(callers[SWAPPER]), true, _i128ExactIn(A), 0);
      uint256 got1 = _u128FromNegDelta(d1);

      // leg 2: token1 → token0
      (int256 d0,) = _swap(SWAPPER, address(callers[SWAPPER]), false, _i128ExactIn(got1.toUint128()), type(uint128).max);
      uint256 got0 = _u128FromNegDelta(d0);

      uint256 loss = A - got0;

      assertLt(loss * 1e8, uint256(A), "Reverse roundtrip loss exceeds 1e-8");
    }
  }
}
