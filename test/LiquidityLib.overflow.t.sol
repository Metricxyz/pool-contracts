// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {MetricOmmPoolBaseTest} from "./MetricOmmPool.base.t.sol";
import {MetricOmmPool} from "../contracts/MetricOmmPool.sol";
import {MetricOmmPoolFactory} from "../contracts/MetricOmmPoolFactory.sol";
import {MetricOmmPoolDeployer} from "../contracts/MetricOmmPoolDeployer.sol";
import {PoolParameters} from "../contracts/types/FactoryOperation.sol";
import {LiquidityDelta} from "../contracts/types/PoolOperation.sol";

/// @notice Regression coverage for the `addLiquidity`/`removeLiquidity` overflow: `token{0,1}BalanceScaled * shares`
///         must not overflow before the division by `binTotalShares`, even when the final amount fits. Pools are
///         deployed through a real `MetricOmmPoolFactory.createPool`, not the deployer directly, so the extreme
///         `initialScaledAmount1PerE18Shares = 1` / `minimalOperationalLiquidity` combination is proven reachable
///         under the factory's own `_validatePoolParameters` floor, not just at the deployer level.
contract LiquidityLibOverflowTest is MetricOmmPoolBaseTest {
  // `minimalOperationalLiquidity >= PRECISION * 1e18 / min(initialScaledAmount0PerE18Shares, initialScaledAmount1PerE18Shares)`
  // with PRECISION = 1e6 and the tiny per-share rate below (`1`) floors this at 1e24.
  uint256 internal constant EXTREME_MINIMAL_OPERATIONAL_LIQUIDITY = 1e24;

  /// @dev Deploys a pool via a real factory with a per-share rate of `1` on token1 (instead of the harness
  ///      default `1e18`), which is what lets `sharesToAdd` grow large enough to overflow the old
  ///      multiply-before-divide math while the resulting bin balance still fits in `uint104`.
  function _deployExtremePoolViaFactory() internal returns (MetricOmmPool) {
    MetricOmmPoolFactory f = new MetricOmmPoolFactory(address(this), address(this), 0, 0, type(uint16).max);
    MetricOmmPoolDeployer d = new MetricOmmPoolDeployer(address(f));
    f.setPoolDeployer(address(d));
    oracle.setTokens(address(token0), address(token1));

    PoolParameters memory params = PoolParameters({
      token0: address(token0),
      token1: address(token1),
      priceProvider: address(oracle),
      extensions: new address[](0),
      extensionOrders: _emptyExtensionOrders(),
      extensionInitData: new bytes[](0),
      priceProviderTimelock: type(uint256).max,
      admin: address(this),
      initialScaledAmount0PerE18Shares: 1e18,
      initialScaledAmount1PerE18Shares: 1,
      minimalOperationalLiquidity: EXTREME_MINIMAL_OPERATIONAL_LIQUIDITY,
      protocolSpreadFeeE6: 0,
      adminSpreadFeeE6: 0,
      protocolNotionalFeeE8: 0,
      adminNotionalFeeE8: 0,
      adminFeeDestination: makeAddr("extremePoolAdminFeeDest"),
      curBinDistFromProvidedPriceE6: 0,
      nonNegativeBinDataArray: _createBinDataArray(),
      negativeBinDataArray: _createBinDataArray(),
      salt: keccak256("LiquidityLibOverflowTest"),
      bidAskRefAsymmetryX8: type(uint16).max
    });

    return MetricOmmPool(f.createPool(params));
  }

  function test_removeLiquidity_succeedsWhenIntermediateProductWouldOverflowUint256() public {
    MetricOmmPool extremePool = _deployExtremePoolViaFactory();

    address depositor = address(callers[0]);
    uint256 hugeShares = 1e48;
    uint256 expectedAmount1 = 1e30; // hugeShares * 1 / 1e18, exact

    token1.mint(depositor, expectedAmount1);

    LiquidityDelta memory deltas = _singleBinDelta(-1, hugeShares); // below curBinIdx (0): token1-only branch

    vm.prank(users[0]);
    (uint256 amount0Added, uint256 amount1Added) = callers[0].addLiquidity(address(extremePool), 0, deltas);
    assertEq(amount0Added, 0, "bin -1 is token1-only");
    assertEq(amount1Added, expectedAmount1, "deposit must match the tiny per-share rate exactly");

    // Pre-fix, this reverted with an arithmetic overflow: token1BalanceScaled (1e30) * sharesToRemove (1e48)
    // is ~1e78, past type(uint256).max (~1.16e77), even though the true quotient (1e30) fits in uint104.
    vm.prank(users[0]);
    (uint256 amount0Removed, uint256 amount1Removed) = callers[0].removeLiquidity(address(extremePool), 0, deltas);

    assertEq(amount0Removed, 0);
    assertEq(amount1Removed, expectedAmount1, "full withdrawal by the sole depositor must return the whole deposit");
  }

  function test_addLiquidity_succeedsWhenIntermediateProductWouldOverflowUint256() public {
    MetricOmmPool extremePool = _deployExtremePoolViaFactory();

    uint256 firstShares = 1e48;
    uint256 firstAmount1 = 1e30; // firstShares * 1 / 1e18, exact
    token1.mint(address(callers[0]), firstAmount1);
    vm.prank(users[0]);
    callers[0].addLiquidity(address(extremePool), 0, _singleBinDelta(-1, firstShares));

    // Second deposit into the now-non-empty bin -1 takes the `binTotalSharesVal != 0` branch:
    // amount1Scaled = ceilDiv(token1BalanceScaled * secondShares, binTotalSharesVal). Pre-fix, the raw
    // product (1e30 * 1e48 = 1e78) overflows uint256 (~1.16e77) even though the true quotient (1e30, since
    // token1BalanceScaled == binTotalSharesVal here) fits comfortably in uint104.
    uint256 secondShares = 1e48;
    uint256 expectedSecondAmount1 = 1e30;
    token1.mint(address(callers[1]), expectedSecondAmount1);
    vm.prank(users[1]);
    (uint256 amount0Added, uint256 amount1Added) =
      callers[1].addLiquidity(address(extremePool), 0, _singleBinDelta(-1, secondShares));

    assertEq(amount0Added, 0, "bin -1 is token1-only");
    assertEq(amount1Added, expectedSecondAmount1, "second deposit must be proportional to the existing bin balance");
  }

  function _singleBinDelta(int256 binIdx, uint256 shares) internal pure returns (LiquidityDelta memory deltas) {
    int256[] memory binIdxs = new int256[](1);
    binIdxs[0] = binIdx;
    uint256[] memory sharesArr = new uint256[](1);
    sharesArr[0] = shares;
    return LiquidityDelta({binIdxs: binIdxs, shares: sharesArr});
  }
}
