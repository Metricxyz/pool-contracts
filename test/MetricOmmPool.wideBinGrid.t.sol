// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;
// forge-lint: disable-start(unsafe-typecast, mixed-case-function, mixed-case-variable)

import {MetricOmmPoolBaseTest, Q64} from "./MetricOmmPool.base.t.sol";
import {MetricOmmPool} from "../contracts/MetricOmmPool.sol";
import {BinState} from "../contracts/types/PoolStorage.sol";
import {PoolStateTestLib} from "./PoolStateTestLib.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @notice Bin indices are `int16`, so the grid may exceed the old `int8` range of +-128.
/// @dev Every other test uses a handful of bins, so none of them would notice if indices silently
///      truncated past 127. These drive a grid well beyond that boundary end to end: deploy, trade
///      across it, and hold liquidity at a bin index no `int8` could represent.
contract MetricOmmPoolWideBinGridTest is MetricOmmPoolBaseTest {
  /// @dev Comfortably past the old int8 ceiling on both sides.
  uint256 internal constant BINS_PER_SIDE = 200;

  MetricOmmPool internal wide;
  address internal swapper;

  function setUp() public override {
    super.setUp();
    swapper = users[0];

    BinState[] memory nn = new BinState[](BINS_PER_SIDE);
    BinState[] memory neg = new BinState[](BINS_PER_SIDE);
    for (uint256 i = 0; i < BINS_PER_SIDE; i++) {
      nn[i] = BinState({token0BalanceScaled: 0, token1BalanceScaled: 0, lengthE6: 100, addFeeBuyE6: 0, addFeeSellE6: 0});
      neg[i] =
        BinState({token0BalanceScaled: 0, token1BalanceScaled: 0, lengthE6: 100, addFeeBuyE6: 0, addFeeSellE6: 0});
    }

    wide = _deployPoolAndRegister(
      PoolDeployParams({
        priceProvider: address(oracle),
        extensions: _emptyExtensions(),
        extensionOrders: _emptyExtensionOrders(),
        immutablePriceProvider: true,
        protocolSpreadFeeE6: PROTOCOL_FEE,
        adminSpreadFeeE6: ADMIN_FEE,
        curBinDistFromProvidedPriceE6: 0,
        nonNegativeBinStates: nn,
        negativeBinStates: neg,
        protocolNotionalFeeE8: 0,
        adminNotionalFeeE8: 0,
        immutablePriceProviderForRegistry: address(oracle),
        lowestBin: -int16(int256(BINS_PER_SIDE)),
        highestBin: int16(int256(BINS_PER_SIDE)) - 1
      })
    );
    _approveUsersForPool(address(wide));
  }

  /// @dev The bin the pool reports must be the bin we asked for, at an index `int8` cannot hold.
  function test_liquidityAndStateAtBinIndexBeyondInt8() public {
    int16 highBin = 150; // > int8 max (127)
    int16 lowBin = -150; // < int8 min (-128)

    _addLiquidityOn(address(wide), 1, highBin, highBin, 10_000_000, 0);
    _addLiquidityOn(address(wide), 1, lowBin, lowBin, 10_000_000, 0);

    // Shares must be recorded against the requested bins -- position keys derive from the bin index,
    // so a truncating index would file them under 150-256 = -106 and &c.
    assertGt(PoolStateTestLib.binTotalShares(address(wide), highBin), 0, "shares at bin 150");
    assertGt(PoolStateTestLib.binTotalShares(address(wide), lowBin), 0, "shares at bin -150");
    assertEq(PoolStateTestLib.binTotalShares(address(wide), int16(-106)), 0, "nothing leaked to the int8 alias");
    assertEq(PoolStateTestLib.binTotalShares(address(wide), int16(106)), 0, "nothing leaked to the int8 alias");
  }

  /// @dev slot0 stores the active bin index; walk it past the old boundary and read it back.
  function test_activeBinIndexCrossesTheInt8BoundaryDuringSwaps() public {
    _addLiquidityOn(address(wide), 1, -180, 180, 1_000_000, 0);

    // Buy token0 hard enough to walk the active bin well past 127.
    _swapOnPool(address(wide), 0, swapper, false, _i128ExactIn(type(uint96).max), type(uint128).max);
    int16 afterBuy = PoolStateTestLib.curBinIdx(address(wide));
    assertGt(afterBuy, int16(127), "active bin must exceed the old int8 ceiling");

    // ...and back down past -128 the other way.
    _swapOnPool(address(wide), 0, swapper, true, _i128ExactIn(type(uint96).max), 0);
    int16 afterSell = PoolStateTestLib.curBinIdx(address(wide));
    assertLt(afterSell, int16(-127), "active bin must go below the old int8 floor");
  }

  function _addLiquidityOn(address poolAddr, uint256 userIndex, int16 lo, int16 hi, uint104 shares, uint80 salt)
    internal
  {
    vm.prank(users[userIndex]);
    callers[userIndex].addLiquidity(poolAddr, salt, _rangeDeltas(lo, hi, shares));
  }
}
