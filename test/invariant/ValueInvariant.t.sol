// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;
// forge-lint: disable-start(unsafe-typecast)

// Stateful value-conservation invariants for MetricOmmPool.
// With a constant oracle quote, every trade executes at bid*(1+d) / ask*(1+d) and the pool keeps the spread,
// so: (1) an attacker who trades and provides liquidity can never end with more value at the reference mid
// than it started with; (2) a passive LP's withdrawable value at the mid never falls; (3) the pool stays solvent.
// Config by env: INV_DEC0, INV_DEC1 (token decimals), INV_PRICE_E6 (human token1 per token0, x1e6),
// INV_HALFSPREAD_E6 (bid/ask half spread), INV_BINS (bins per side), INV_BINLEN (lengthE6), INV_ADDFEE (per-bin E6),
// INV_SPREADFEE (platform share E6), INV_NOTIONAL (E8), INV_LPMODE (0 all bins, 1 not -1/0, 2 every other bin),
// INV_TICKS (with INV_HALFSPREAD_E6 = 0: ask = bid + INV_TICKS in Q64).

import {Test} from "forge-std/Test.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MockPriceProvider} from "../MetricOmmPool.base.t.sol";
import {FactoryFeeCapsStub} from "../FactoryFeeCapsStub.sol";
import {PoolInitPreprocessor} from "../PoolInitPreprocessor.sol";
import {MetricOmmPool} from "../../contracts/MetricOmmPool.sol";
import {MetricOmmPoolDeployer} from "../../contracts/MetricOmmPoolDeployer.sol";
import {BinState} from "../../contracts/types/PoolStorage.sol";
import {LiquidityDelta} from "../../contracts/types/PoolOperation.sol";
import {PoolFeeConfig} from "../../contracts/types/FactoryStorage.sol";
import {PoolStateLibrary} from "../../contracts/libraries/PoolStateLibrary.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {TestCaller} from "../mocks/TestCaller.sol";

library Val {
  uint256 internal constant Q64 = 1 << 64;

  /// value of everything `owner` (salt 0) holds in [lo, hi], in scaled token1 units at `refX64`, rounded down
  function lpValue(address pool, address owner, int16 lo, int16 hi, uint256 refX64) internal view returns (uint256 v) {
    for (int16 b = lo; b <= hi; b++) {
      uint256 s = PoolStateLibrary._positionBinShares(pool, owner, 0, b);
      if (s == 0) continue;
      uint256 tot = PoolStateLibrary._binTotalShares(pool, b);
      (uint104 t0, uint104 t1,,,) = PoolStateLibrary._binState(pool, b);
      uint256 a0 = Math.mulDiv(t0, s, tot);
      uint256 a1 = Math.mulDiv(t1, s, tot);
      v += Math.mulDiv(a0, refX64, Q64) + a1;
    }
  }

  function walletValue(address who, MockERC20 t0, MockERC20 t1, uint256 m0, uint256 m1, uint256 refX64)
    internal
    view
    returns (uint256)
  {
    return Math.mulDiv(t0.balanceOf(who) * m0, refX64, Q64) + t1.balanceOf(who) * m1;
  }
}

contract InvHandler is CommonBase, StdUtils {
  MetricOmmPool public pool;
  MockERC20 public t0;
  MockERC20 public t1;
  TestCaller public atk;
  address public atkEOA;
  int16 public lo;
  int16 public hi;
  uint128 public bid;
  uint128 public ask;
  uint256 public m0;
  uint256 public m1;

  uint256 public nSwaps;
  uint256 public nSwapOk;
  uint256 public nAdd;
  uint256 public nRemove;
  bytes4 public lastAddErr;
  bytes4 public lastSwapErr;
  mapping(bytes4 => uint256) public addErrs;
  mapping(bytes4 => uint256) public swapErrs;

  constructor(
    MetricOmmPool pool_,
    MockERC20 t0_,
    MockERC20 t1_,
    TestCaller atk_,
    address atkEOA_,
    int16 lo_,
    int16 hi_,
    uint128 bid_,
    uint128 ask_
  ) {
    (pool, t0, t1, atk, atkEOA, lo, hi, bid, ask) = (pool_, t0_, t1_, atk_, atkEOA_, lo_, hi_, bid_, ask_);
    m0 = pool_.getImmutables().token0ScaleMultiplier;
    m1 = pool_.getImmutables().token1ScaleMultiplier;
  }

  function _amount(uint256 seed, MockERC20 tok) internal view returns (uint256) {
    uint256 bal = tok.balanceOf(address(atk));
    uint256 mode = seed % 5;
    if (mode == 0) return bound(seed >> 8, 1, 1000); // wei-level dust
    if (mode == 1) return bound(seed >> 8, 1, 10 ** tok.decimals()); // up to one whole token
    uint256 cap = bal / 4 + 1;
    return bound(seed >> 8, 1, cap);
  }

  function swap(bool zeroForOne, bool exactOut, uint256 amtSeed, uint256 limitSeed) external {
    nSwaps++;
    MockERC20 tin = zeroForOne ? t0 : t1;
    MockERC20 tout = zeroForOne ? t1 : t0;
    uint256 amt = exactOut ? _amount(amtSeed, tout) : _amount(amtSeed, tin);
    if (amt > uint256(uint128(type(int128).max))) amt = uint256(uint128(type(int128).max));
    int128 spec = exactOut ? -int128(int256(amt)) : int128(int256(amt));
    uint128 limit;
    uint256 lm = limitSeed % 3;
    if (lm == 0) {
      limit = zeroForOne ? 0 : type(uint128).max;
    } else {
      // a limit somewhere within +-20% of the quote
      uint256 base = zeroForOne ? bid : ask;
      uint256 pct = bound(limitSeed >> 8, 800_000, 1_200_000);
      limit = uint128(Math.mulDiv(base, pct, 1_000_000));
      if (limit == 0) limit = 1;
    }
    vm.prank(atkEOA);
    try atk.swap(address(pool), address(atk), zeroForOne, spec, limit) {
      nSwapOk++;
    } catch (bytes memory r) {
      swapErrs[bytes4(r)]++;
      lastSwapErr = bytes4(r);
    }
  }

  function addLiq(uint256 binSeed, uint256 widthSeed, uint256 sharesSeed) external {
    int256 span = int256(hi) - int256(lo);
    int16 a = int16(int256(lo) + int256(bound(binSeed, 0, uint256(span))));
    int16 w = int16(int256(bound(widthSeed, 0, 3)));
    int16 b = a + w > hi ? hi : a + w;
    uint256 n = uint256(int256(b) - int256(a) + 1);
    int256[] memory idx = new int256[](n);
    uint256[] memory sh = new uint256[](n);
    uint256 mode = sharesSeed % 3;
    uint256 s = mode == 0 ? bound(sharesSeed >> 8, 1e6, 2e6) : bound(sharesSeed >> 8, 1e6, 5e19);
    for (uint256 i = 0; i < n; i++) {
      idx[i] = int256(a) + int256(i);
      sh[i] = s;
    }
    vm.prank(atkEOA);
    try atk.addLiquidity(address(pool), 0, LiquidityDelta({binIdxs: idx, shares: sh})) {
      nAdd++;
    } catch (bytes memory r) {
      lastAddErr = bytes4(r);
      addErrs[bytes4(r)]++;
    }
  }

  function removeLiq(uint256 binSeed, uint256 fracSeed) external {
    int256 span = int256(hi) - int256(lo);
    int16 a = int16(int256(lo) + int256(bound(binSeed, 0, uint256(span))));
    uint256 have = PoolStateLibrary._positionBinShares(address(pool), address(atk), 0, a);
    if (have == 0) return;
    uint256 mode = fracSeed % 3;
    uint256 s = mode == 0 ? have : (mode == 1 ? bound(fracSeed >> 8, 1, have) : bound(fracSeed >> 8, 1e6 < have ? 1e6 : have, have < 2e6 ? have : 2e6));
    int256[] memory idx = new int256[](1);
    uint256[] memory sh = new uint256[](1);
    idx[0] = a;
    sh[0] = s;
    vm.prank(atkEOA);
    try atk.removeLiquidity(address(pool), 0, LiquidityDelta({binIdxs: idx, shares: sh})) {
      nRemove++;
    } catch {}
  }
}

contract ValueInvariantTest is Test, FactoryFeeCapsStub, PoolInitPreprocessor {
  MetricOmmPoolDeployer internal poolDeployer;
  InvHandler internal h;
  MetricOmmPool internal p;
  MockERC20 internal a0;
  MockERC20 internal a1;
  TestCaller internal atkC;
  TestCaller internal lpC;
  address internal atkU;
  address internal lpU;
  int16 internal LO;
  int16 internal HI;
  uint256 internal ref;
  uint256 internal M0;
  uint256 internal M1;
  uint256 internal atkStart;
  uint256 internal lpStart;
  uint256 internal maxAtkGain;
  uint256 internal maxLpLoss;

  function _env(string memory k, uint256 d) internal view returns (uint256) {
    return vm.envOr(k, d);
  }

  uint128 internal bidP;
  uint128 internal askP;
  uint256 internal priceE6;

  function _deployInvPool() internal {
    uint256 bins = _env("INV_BINS", 10);
    uint16 binLen = uint16(_env("INV_BINLEN", 100));
    uint16 addFee = uint16(_env("INV_ADDFEE", 0));
    BinState[] memory nn = new BinState[](bins);
    BinState[] memory ng = new BinState[](bins);
    for (uint256 i = 0; i < bins; i++) {
      nn[i] = BinState({token0BalanceScaled: 0, token1BalanceScaled: 0, lengthE6: binLen, addFeeBuyE6: addFee, addFeeSellE6: addFee});
      ng[i] = BinState({token0BalanceScaled: 0, token1BalanceScaled: 0, lengthE6: binLen, addFeeBuyE6: addFee, addFeeSellE6: addFee});
    }
    LO = -int16(int256(bins));
    HI = int16(int256(bins)) - 1;
    MetricOmmPoolDeployer.DeployParams memory dp;
    dp.salt = keccak256("inv");
    dp.factory = address(this);
    dp.token0 = address(a0);
    dp.token1 = address(a1);
    dp.priceProvider = address(oracleInv);
    dp.immutablePriceProvider = true;
    dp.token0ScaleMultiplier = M0;
    dp.token1ScaleMultiplier = M1;
    // initial composition for first deposits: 1 scaled token0 and `price` scaled token1 per 1e18 shares
    dp.initialScaledAmount0PerShareE18 = 1e18;
    dp.initialScaledAmount1PerShareE18 = Math.mulDiv(1e18, priceE6, 1e6);
    dp.minimalOperationalLiquidity = _env("INV_MINLIQ", 1e6);
    dp.spreadFeeE6 = uint24(_env("INV_SPREADFEE", 150_000));
    dp.nonNegativeBinStates = nn;
    dp.negativeBinStates = ng;
    dp.notionalFeeE8 = uint24(_env("INV_NOTIONAL", 0));
    dp.bidAskRefAsymmetryX8 = type(uint16).max;
    p = MetricOmmPool(poolDeployer.deploy(dp));
    priceProviderTimelock[address(p)] = type(uint256).max;
    poolAdmin[address(p)] = address(this);
    poolFeeConfig[address(p)] = PoolFeeConfig({
      protocolSpreadFeeE6: dp.spreadFeeE6, adminSpreadFeeE6: 0, protocolNotionalFeeE8: dp.notionalFeeE8, adminNotionalFeeE8: 0
    });
    poolAdminFeeDestination[address(p)] = makeAddr("adminDest");
  }

  MockPriceProvider internal oracleInv;

  function setUp() public {
    poolDeployer = new MetricOmmPoolDeployer(address(this));
    uint8 dec0 = uint8(_env("INV_DEC0", 8));
    uint8 dec1 = uint8(_env("INV_DEC1", 6));
    priceE6 = _env("INV_PRICE_E6", 100_000e6); // 100,000 token1 per token0
    uint256 halfSpreadE6 = _env("INV_HALFSPREAD_E6", 500); // 5 bps each side

    a0 = new MockERC20("A0", "A0", dec0);
    a1 = new MockERC20("A1", "A1", dec1);
    oracleInv = new MockPriceProvider();
    // scaled price == human price when both tokens have <= 18 decimals (internal decimals 18)
    uint256 midX64 = Math.mulDiv(1 << 64, priceE6, 1e6);
    bidP = uint128(Math.mulDiv(midX64, 1e6 - halfSpreadE6, 1e6));
    askP = uint128(Math.mulDiv(midX64, 1e6 + halfSpreadE6, 1e6));
    // INV_HALFSPREAD_E6 = 0: the tightest legal quote, ask = bid + INV_TICKS (Q64 units)
    if (halfSpreadE6 == 0) askP = bidP + uint128(_env("INV_TICKS", 1));
    oracleInv.setBidAndAskPrice(bidP, askP);
    (,, uint128 r) = oracleInv.getQuote();
    ref = r;
    (M0, M1) = _getScaleMultipliers(address(a0), address(a1));
    _deployInvPool();
    _setupActors(dec0, dec1);
  }

  function _setupActors(uint8 dec0, uint8 dec1) internal {
    atkU = makeAddr("attacker");
    lpU = makeAddr("honestLP");
    atkC = new TestCaller(atkU, address(this));
    lpC = new TestCaller(lpU, address(this));
    uint256 big0 = 1_000 * 10 ** dec0;
    uint256 big1 = Math.mulDiv(1_000 * 10 ** dec1, priceE6, 1e6);
    a0.mint(address(atkC), big0);
    a1.mint(address(atkC), big1);
    a0.mint(address(lpC), big0 * 10);
    a1.mint(address(lpC), big1 * 10);
    vm.startPrank(address(atkC));
    a0.approve(address(p), type(uint256).max);
    a1.approve(address(p), type(uint256).max);
    vm.stopPrank();
    vm.startPrank(address(lpC));
    a0.approve(address(p), type(uint256).max);
    a1.approve(address(p), type(uint256).max);
    vm.stopPrank();

    // the honest LP spreads liquidity over every bin (shares sized to use part of its balance)
    // INV_LPMODE: 0 every bin; 1 every bin except -1 and 0 (the attacker can own the starting bins alone);
    // 2 every other bin (gaps the attacker can own alone)
    uint256 mode = _env("INV_LPMODE", 0);
    uint256 all = uint256(int256(HI) - int256(LO) + 1);
    uint256 n;
    for (uint256 i = 0; i < all; i++) if (_lpIn(mode, int256(LO) + int256(i), i)) n++;
    int256[] memory idx = new int256[](n);
    uint256[] memory sh = new uint256[](n);
    uint256 j;
    for (uint256 i = 0; i < all; i++) {
      if (!_lpIn(mode, int256(LO) + int256(i), i)) continue;
      idx[j] = int256(LO) + int256(i);
      sh[j] = _env("INV_LPSHARES", 1e20);
      j++;
    }
    vm.prank(lpU);
    lpC.addLiquidity(address(p), 0, LiquidityDelta({binIdxs: idx, shares: sh}));

    h = new InvHandler(p, a0, a1, atkC, atkU, LO, HI, bidP, askP);
    targetContract(address(h));
    bytes4[] memory sel = new bytes4[](3);
    sel[0] = InvHandler.swap.selector;
    sel[1] = InvHandler.addLiq.selector;
    sel[2] = InvHandler.removeLiq.selector;
    targetSelector(FuzzSelector({addr: address(h), selectors: sel}));

    atkStart = _atkValue();
    lpStart = Val.lpValue(address(p), address(lpC), LO, HI, ref);
  }

  function _lpIn(uint256 mode, int256 bin, uint256 i) internal pure returns (bool) {
    if (mode == 1) return bin != -1 && bin != 0;
    if (mode == 2) return i % 2 == 0;
    return true;
  }

  function _atkValue() internal view returns (uint256) {
    return Val.walletValue(address(atkC), a0, a1, M0, M1, ref) + Val.lpValue(address(p), address(atkC), LO, HI, ref);
  }

  function invariant_attackerCannotProfit() public {
    uint256 v = _atkValue();
    if (v > atkStart) {
      emit log_named_uint("attacker gain (scaled token1)", v - atkStart);
      emit log_named_uint("swaps ok", h.nSwapOk());
    }
    assertLe(v, atkStart, "attacker gained value at a constant oracle");
  }

  function invariant_honestLpNeverLoses() public view {
    uint256 v = Val.lpValue(address(p), address(lpC), LO, HI, ref);
    // floor rounding of the measurement itself: up to 2 scaled units per bin (one per token), priced
    uint256 tol = 2 * uint256(int256(HI) - int256(LO) + 1) * (1 + ref / (1 << 64));
    assertGe(v + tol, lpStart, "passive LP lost value at a constant oracle");
  }

  function _owed() internal view returns (uint256 o0, uint256 o1) {
    (uint128 bt0, uint128 bt1) = PoolStateLibrary._slot1(address(p));
    (uint128 n0, uint128 n1) = PoolStateLibrary._slot2(address(p));
    o0 = uint256(bt0) + n0;
    o1 = uint256(bt1) + n1;
    (uint256 pa0, uint256 pa1, uint256 pp0, uint256 pp1) = PoolStateLibrary._pendingFeesScaled(address(p));
    o0 += pa0 + pp0;
    o1 += pa1 + pp1;
  }

  function _sumBins() internal view returns (uint256 s0, uint256 s1) {
    for (int16 b = LO; b <= HI; b++) {
      (uint104 x0, uint104 x1,,,) = PoolStateLibrary._binState(address(p), b);
      s0 += x0;
      s1 += x1;
    }
  }

  function invariant_solvent() public view {
    (uint256 o0, uint256 o1) = _owed();
    assertGe(a0.balanceOf(address(p)) * M0, o0, "token0 insolvent");
    assertGe(a1.balanceOf(address(p)) * M1, o1, "token1 insolvent");
  }

  function invariant_binTotalsMatch() public view {
    (uint128 bt0, uint128 bt1) = PoolStateLibrary._slot1(address(p));
    (uint256 s0, uint256 s1) = _sumBins();
    assertEq(s0, bt0, "binTotals0 != sum of bins");
    assertEq(s1, bt1, "binTotals1 != sum of bins");
  }

  function afterInvariant() public {
    emit log_named_uint("swaps", h.nSwaps());
    emit log_named_uint("swaps ok", h.nSwapOk());
    emit log_named_uint("adds ok", h.nAdd());
    emit log_named_uint("removes ok", h.nRemove());
    emit log_named_bytes32("last add err", bytes32(h.lastAddErr()));
    emit log_named_bytes32("last swap err", bytes32(h.lastSwapErr()));
  }
}
