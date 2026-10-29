// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;
// forge-lint: disable-start(unsafe-typecast)

import {MetricOmmPoolBaseTest, Q64} from "./MetricOmmPool.base.t.sol";
import {PoolStateLibrary} from "../contracts/libraries/PoolStateLibrary.sol";
import {PoolStateTestLib} from "./PoolStateTestLib.sol";
import {IMetricOmmPool, PoolImmutables} from "../contracts/interfaces/IMetricOmmPool/IMetricOmmPool.sol";
import {Vm} from "forge-std/Vm.sol";
import {Packed2Int128, Packed2Uint128, PackedSwapDetails} from "../contracts/types/Packed.sol";

/// @notice Core accounting invariants of the fee-inclusive-price swap path.
contract MetricOmmPoolAccountingInvariantsTest is MetricOmmPoolBaseTest {
  address internal swapper;

  uint128 internal constant BID_P = uint128(uint256(Q64) * 99 / 100);
  uint128 internal constant ASK_P = uint128(uint256(Q64) * 101 / 100);

  bytes32 internal constant SWAP_TOPIC = keccak256("Swap(address,address,uint256,uint256,uint256)");

  function setUp() public override {
    super.setUp();
    swapper = users[0];
    _addLiquidity(1, -1, 0, 10_000_000, 0);
    oracle.setBidAndAskPrice(BID_P, ASK_P);
  }

  function _sumBinBalances() internal view returns (uint256 t0, uint256 t1) {
    for (int16 b = -1; b <= 0; b++) {
      (uint104 b0, uint104 b1,,,) = PoolStateTestLib.binState(address(pool), b);
      t0 += b0;
      t1 += b1;
    }
  }

  function _reportedPlatformFee(Vm.Log[] memory logs) internal view returns (uint256 fee) {
    for (uint256 i = 0; i < logs.length; i++) {
      if (logs[i].emitter == address(pool) && logs[i].topics[0] == SWAP_TOPIC) {
        (,, Packed2Uint128 fees_) = abi.decode(logs[i].data, (PackedSwapDetails, Packed2Int128, Packed2Uint128));
        fee = fees_.sum();
      }
    }
  }

  /// @dev binTotals is updated in aggregate (`amountIn - totalPlatformFee`) while each bin is credited
  ///      individually (`grossIn_bin - platformFee_bin`). If per-bin flooring and the aggregate ever
  ///      disagree the pool's books silently drift. Fuzzed across sizes, directions and fee configs.
  function testFuzz_binTotalsMatchSumOfBinBalances(
    uint128 amount,
    bool zeroForOne,
    bool exactOut,
    uint16 addFeeE6,
    uint24 notionalFeeE8_,
    uint24 spreadE6
  ) public {
    amount = uint128(bound(amount, 1_000, 5_000_000));
    addFeeE6 = uint16(bound(addFeeE6, 0, 20_000));
    notionalFeeE8_ = uint24(bound(notionalFeeE8_, 0, 1_000_000));
    spreadE6 = uint24(bound(spreadE6, 0, 1_000_000));

    IMetricOmmPoolFactoryActionsLike(address(pool)).setBinAdditionalFees(0, addFeeE6, addFeeE6);
    IMetricOmmPoolFactoryActionsLike(address(pool)).setBinAdditionalFees(-1, addFeeE6, addFeeE6);
    pool.setPoolFees(spreadE6, notionalFeeE8_);

    vm.prank(users[0]);
    try callers[0].swap(
      address(pool),
      swapper,
      zeroForOne,
      exactOut ? _i128ExactOut(amount) : _i128ExactIn(amount),
      zeroForOne ? 0 : type(uint128).max
    ) returns (
      int256, int256
    ) {
      (uint256 sum0, uint256 sum1) = _sumBinBalances();
      (uint128 totals0, uint128 totals1) = PoolStateLibrary._slot1(address(pool));
      assertEq(uint256(totals0), sum0, "binTotals.scaledToken0 must equal the sum of bin balances");
      assertEq(uint256(totals1), sum1, "binTotals.scaledToken1 must equal the sum of bin balances");
    } catch {
      return;
    }
  }

  /// @dev Everything withheld from the bins must be exactly what the swap reports as the platform take,
  ///      and it must be fully backed by real tokens sitting in the pool (solvency).
  function testFuzz_surplusEqualsReportedPlatformFee(
    uint128 amount,
    bool zeroForOne,
    bool exactOut,
    uint16 addFeeE6,
    uint24 notionalFeeE8_,
    uint24 spreadE6
  ) public {
    amount = uint128(bound(amount, 100_000, 5_000_000));
    addFeeE6 = uint16(bound(addFeeE6, 0, 20_000));
    notionalFeeE8_ = uint24(bound(notionalFeeE8_, 0, 1_000_000));
    spreadE6 = uint24(bound(spreadE6, 0, 1_000_000));

    IMetricOmmPoolFactoryActionsLike(address(pool)).setBinAdditionalFees(0, addFeeE6, addFeeE6);
    IMetricOmmPoolFactoryActionsLike(address(pool)).setBinAdditionalFees(-1, addFeeE6, addFeeE6);
    pool.setPoolFees(spreadE6, notionalFeeE8_);

    PoolImmutables memory imm = IMetricOmmPool(address(pool)).getImmutables();
    (uint128 before0, uint128 before1) = PoolStateLibrary._slot1(address(pool));
    uint256 bal0Before = token0.balanceOf(address(pool)) * imm.token0ScaleMultiplier;
    uint256 bal1Before = token1.balanceOf(address(pool)) * imm.token1ScaleMultiplier;
    assertEq(bal0Before, before0, "clean start: no surplus");
    assertEq(bal1Before, before1, "clean start: no surplus");

    vm.recordLogs();
    vm.prank(users[0]);
    try callers[0].swap(
      address(pool),
      swapper,
      zeroForOne,
      exactOut ? _i128ExactOut(amount) : _i128ExactIn(amount),
      zeroForOne ? 0 : type(uint128).max
    ) returns (
      int256, int256
    ) {
      uint256 reported = _reportedPlatformFee(vm.getRecordedLogs());
      (uint128 after0, uint128 after1) = PoolStateLibrary._slot1(address(pool));
      uint256 surplus = zeroForOne
        ? (token0.balanceOf(address(pool)) * imm.token0ScaleMultiplier) - after0
        : (token1.balanceOf(address(pool)) * imm.token1ScaleMultiplier) - after1;

      // Solvency + faithful reporting in one: the tokens held back from the bins are exactly the
      // amount the swap told callers and extensions it took.
      assertEq(surplus, reported, "withheld tokens must equal the reported platform take");
    } catch {
      return;
    }
  }

  bytes32 internal constant BIN_SWAPPED_TOPIC = keccak256("BinSwapped(int256,uint256,uint256)");

  /// @dev `BinSwapped.delta` is documented as the change in that BIN's balances. Verify the emitted
  ///      numbers actually equal the observed bin balance change (i.e. they are net of the platform
  ///      take, not the trader's gross flow).
  function testFuzz_binSwappedDeltaEqualsActualBinBalanceChange(
    uint128 amount,
    bool zeroForOne,
    bool exactOut,
    uint16 addFeeE6,
    uint24 notionalFeeE8_,
    uint24 spreadE6
  ) public {
    amount = uint128(bound(amount, 100_000, 2_000_000));
    addFeeE6 = uint16(bound(addFeeE6, 0, 20_000));
    notionalFeeE8_ = uint24(bound(notionalFeeE8_, 0, 1_000_000));
    spreadE6 = uint24(bound(spreadE6, 0, 1_000_000));

    IMetricOmmPoolFactoryActionsLike(address(pool)).setBinAdditionalFees(0, addFeeE6, addFeeE6);
    IMetricOmmPoolFactoryActionsLike(address(pool)).setBinAdditionalFees(-1, addFeeE6, addFeeE6);
    pool.setPoolFees(spreadE6, notionalFeeE8_);

    (uint256 before0, uint256 before1) = _sumBinBalances();

    vm.recordLogs();
    vm.prank(users[0]);
    try callers[0].swap(
      address(pool),
      swapper,
      zeroForOne,
      exactOut ? _i128ExactOut(amount) : _i128ExactIn(amount),
      zeroForOne ? 0 : type(uint128).max
    ) returns (
      int256, int256
    ) {
      Vm.Log[] memory logs = vm.getRecordedLogs();
      int256 sumDelta0;
      int256 sumDelta1;
      uint256 seen;
      for (uint256 i = 0; i < logs.length; i++) {
        if (logs[i].emitter == address(pool) && logs[i].topics[0] == BIN_SWAPPED_TOPIC) {
          (, Packed2Int128 d,) = abi.decode(logs[i].data, (int256, Packed2Int128, Packed2Uint128));
          sumDelta0 += d.high();
          sumDelta1 += d.low();
          seen++;
        }
      }
      if (seen == 0) return;

      (uint256 after0, uint256 after1) = _sumBinBalances();
      assertEq(int256(after0) - int256(before0), sumDelta0, "BinSwapped delta0 must equal the bin balance change");
      assertEq(int256(after1) - int256(before1), sumDelta1, "BinSwapped delta1 must equal the bin balance change");
    } catch {
      return;
    }
  }

  /// @dev The notional leg of the platform take is never more than the reported take, is zero when
  ///      `notionalFeeE8 == 0`, and is the whole take when `spreadFeeE6 == 0` (only notional remains).
  function testFuzz_notionalLegWithinReportedPlatformTake(
    uint128 amount,
    bool zeroForOne,
    bool exactOut,
    uint16 addFeeE6,
    uint24 notionalFeeE8_,
    uint24 spreadE6
  ) public {
    amount = uint128(bound(amount, 100_000, 5_000_000));
    addFeeE6 = uint16(bound(addFeeE6, 0, 20_000));
    notionalFeeE8_ = uint24(bound(notionalFeeE8_, 0, 1_000_000));
    spreadE6 = uint24(bound(spreadE6, 0, 1_000_000));

    IMetricOmmPoolFactoryActionsLike(address(pool)).setBinAdditionalFees(0, addFeeE6, addFeeE6);
    IMetricOmmPoolFactoryActionsLike(address(pool)).setBinAdditionalFees(-1, addFeeE6, addFeeE6);
    pool.setPoolFees(spreadE6, notionalFeeE8_);

    (uint128 n0Before, uint128 n1Before) = PoolStateLibrary._slot2(address(pool));

    vm.recordLogs();
    vm.prank(users[0]);
    try callers[0].swap(
      address(pool),
      swapper,
      zeroForOne,
      exactOut ? _i128ExactOut(amount) : _i128ExactIn(amount),
      zeroForOne ? 0 : type(uint128).max
    ) returns (
      int256, int256
    ) {
      uint256 reported = _reportedPlatformFee(vm.getRecordedLogs());
      (uint128 n0After, uint128 n1After) = PoolStateLibrary._slot2(address(pool));
      uint256 notionalLeg = zeroForOne ? uint256(n0After - n0Before) : uint256(n1After - n1Before);

      assertLe(notionalLeg, reported, "notional leg must not exceed the reported platform take");
      if (notionalFeeE8_ == 0) {
        assertEq(notionalLeg, 0, "no notional fee => no notional leg");
      }
      if (spreadE6 == 0) {
        assertEq(notionalLeg, reported, "no spread share => platform take is all notional");
      }
    } catch {
      return;
    }
  }

  /// @dev The point of packing the platform leg into `BinSwapped`: the delta alone is NET, so an
  ///      implied price taken from it understates what the trader paid. With the platform leg emitted,
  ///      `grossIn = binDelta_in + platformFee` must reconstruct the trader's actual input exactly.
  function testFuzz_binSwappedFeesRecoverTradersGrossInput(
    uint128 amount,
    bool zeroForOne,
    uint24 notionalFeeE8_,
    uint24 spreadE6
  ) public {
    amount = uint128(bound(amount, 100_000, 2_000_000));
    notionalFeeE8_ = uint24(bound(notionalFeeE8_, 0, 1_000_000));
    spreadE6 = uint24(bound(spreadE6, 0, 1_000_000));
    pool.setPoolFees(spreadE6, notionalFeeE8_);

    vm.recordLogs();
    vm.prank(users[0]);
    try callers[0].swap(
      address(pool), swapper, zeroForOne, _i128ExactIn(amount), zeroForOne ? 0 : type(uint128).max
    ) returns (
      int256 a0, int256 a1
    ) {
      Vm.Log[] memory logs = vm.getRecordedLogs();
      int256 reconstructedGross;
      uint256 seen;
      for (uint256 i = 0; i < logs.length; i++) {
        if (logs[i].emitter == address(pool) && logs[i].topics[0] == BIN_SWAPPED_TOPIC) {
          (, Packed2Int128 d, Packed2Uint128 fees) = abi.decode(logs[i].data, (int256, Packed2Int128, Packed2Uint128));
          // Incoming leg is net of the platform take; add it back to recover the gross flow.
          reconstructedGross += (zeroForOne ? d.high() : d.low()) + int256(fees.low());
          seen++;
        }
      }
      if (seen == 0) return;

      // Bin deltas are SCALED; the swap's return is EXTERNAL. Assert the multiplier is 1 so the
      // comparison is unit-correct -- if the base test ever moves to non-18-decimal tokens this
      // fails loudly instead of silently comparing different units.
      PoolImmutables memory imm = IMetricOmmPool(address(pool)).getImmutables();
      assertEq(zeroForOne ? imm.token0ScaleMultiplier : imm.token1ScaleMultiplier, 1, "test assumes multiplier 1");
      int256 actualGross = zeroForOne ? a0 : a1;
      assertEq(reconstructedGross, actualGross, "binDelta_in + platformFee must recover the gross input");
    } catch {
      return;
    }
  }

  /// @dev `finalPosition` packs a SIGNED bin index beside an unsigned position. The risk case is a
  ///      NEGATIVE bin index: it is sign-extended on the stack, so a missing mask on pack or a missing
  ///      SIGNEXTEND on read corrupts one half. Drive the pool into bin -1 and check both halves match
  ///      the pool's own state.
  function test_swapEventFinalPositionRoundTripsNegativeBinIndex() public {
    pool.setPoolFees(500_000, 0);

    vm.recordLogs();
    // Selling token0 walks the price down into the negative bin.
    _swap(0, swapper, true, _i128ExactIn(3_000_000), 0);
    Vm.Log[] memory logs = vm.getRecordedLogs();

    int256 emittedTick;
    int256 emittedPos;
    bool found;
    for (uint256 i = 0; i < logs.length; i++) {
      if (logs[i].emitter == address(pool) && logs[i].topics[0] == SWAP_TOPIC) {
        (PackedSwapDetails details,,) = abi.decode(logs[i].data, (PackedSwapDetails, Packed2Int128, Packed2Uint128));
        emittedTick = details.binIdx();
        emittedPos = int256(details.posInBin());
        found = true;
      }
    }
    assertTrue(found, "Swap event not found");

    assertEq(emittedTick, int256(PoolStateTestLib.curBinIdx(address(pool))), "bin index round-trips");
    assertEq(emittedPos, int256(uint256(PoolStateTestLib.curPosInBin(address(pool)))), "position round-trips");
    assertLt(emittedTick, int256(0), "precondition: the swap really did land in a negative bin");
  }
}

interface IMetricOmmPoolFactoryActionsLike {
  function setBinAdditionalFees(int16 bin, uint16 addFeeBuyE6, uint16 addFeeSellE6) external;
}
