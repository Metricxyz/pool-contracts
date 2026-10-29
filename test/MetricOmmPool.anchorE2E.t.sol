// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {MetricOmmPoolBaseTest, Q64} from "./MetricOmmPool.base.t.sol";
import {MetricOmmPool} from "../contracts/MetricOmmPool.sol";
import {BinState} from "../contracts/types/PoolStorage.sol";
import {FaithfulAnchorOracle, FaithfulAnchoredPriceProvider} from "./mocks/FaithfulAnchor.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @notice End-to-end test of the full price path with a FAITHFUL Anchored provider + abuse-protected
///         oracle (in-repo mocks mirroring smart-contracts-poc): oracle → AnchoredPriceProvider →
///         MetricOmmPool → swap. Exercises the `pool.inSwap() == provider` attribution handshake, the
///         band clamp / 8-decimal→Q64.64 conversion, the staleness halt, and the synthetic ratio feed.
contract MetricOmmPoolAnchorE2ETest is MetricOmmPoolBaseTest {
  uint256 internal constant SWAPPER = 0;
  address internal swapper;

  FaithfulAnchorOracle internal anchorOracle;
  FaithfulAnchoredPriceProvider internal provider;

  bytes32 internal constant FEED = keccak256("BASE/QUOTE");

  // Band params (8-decimal / bps world).
  uint256 internal constant MIN_MARGIN = 1e14; // 1 bps
  uint256 internal constant MAX_STALENESS = 1 hours;
  uint16 internal constant MAX_SPREAD_BPS = 1000; // 10%
  uint256 internal constant MID8 = 10 * 1e8; // price 10
  uint256 internal constant SPREAD_BPS = 50; // 0.5%

  function setUp() public override {
    super.setUp();
    swapper = users[SWAPPER];

    anchorOracle = new FaithfulAnchorOracle();
    provider = new FaithfulAnchoredPriceProvider(
      address(anchorOracle),
      FEED,
      bytes32(0),
      MIN_MARGIN,
      MAX_STALENESS,
      MAX_SPREAD_BPS,
      address(token0),
      address(token1)
    );

    // Replace the base pool with one wired to the faithful provider.
    pool = _deployAnchorPool(address(provider));
    _approveUsersForPool(address(pool));
    _addLiquidity(1, -5, 4, 100_000, 0);

    anchorOracle.setFeed(FEED, MID8, SPREAD_BPS, 0, block.timestamp);
  }

  function _deployAnchorPool(address priceProvider) internal returns (MetricOmmPool p) {
    (BinState[] memory nn, BinState[] memory ng) = _defaultBinStateArrays();
    p = _deployPoolAndRegister(
      PoolDeployParams({
        priceProvider: priceProvider,
        extensions: _emptyExtensions(),
        extensionOrders: _emptyExtensionOrders(),
        immutablePriceProvider: true,
        protocolSpreadFeeE6: PROTOCOL_FEE,
        adminSpreadFeeE6: ADMIN_FEE,
        curBinDistFromProvidedPriceE6: 0,
        nonNegativeBinStates: nn,
        negativeBinStates: ng,
        protocolNotionalFeeE8: 0,
        adminNotionalFeeE8: 0,
        immutablePriceProviderForRegistry: priceProvider,
        lowestBin: -1,
        highestBin: 0
      })
    );
  }

  /// @dev Expected band edges in Q64.64 from the feed: mid·(1 ± (spreadBps + minMargin)).
  function _expectedBand() internal pure returns (uint256 bidX64, uint256 askX64) {
    uint256 half = SPREAD_BPS * 1e14 + MIN_MARGIN; // 1e18-scaled
    uint256 midX64 = (MID8 * Q64) / 1e8; // 10 · Q64
    bidX64 = midX64 * (1e18 - half) / 1e18;
    askX64 = midX64 * (1e18 + half) / 1e18;
  }

  // ── Happy path: oracle → provider → pool → swap ───────────────────────────

  function test_e2e_swapExecutesAtOraclePrice() public {
    (uint256 bidX64, uint256 askX64) = _expectedBand();

    // The pool's own quote comes through the full provider/oracle path and sits in the band.
    (uint128 poolBid, uint128 poolAsk) = pool.getSellAndBuyPrices();
    assertGt(poolAsk, poolBid, "ask > bid");
    assertApproxEqRel(uint256(poolBid), bidX64, 0.01e18, "pool bid tracks provider band");
    assertApproxEqRel(uint256(poolAsk), askX64, 0.01e18, "pool ask tracks provider band");

    // Buy token0 with token1 (exact input). Realized price must land in the band.
    (int256 amount0, int256 amount1) = _swap(SWAPPER, swapper, false, _i128ExactIn(100_000), type(uint128).max);
    assertLt(amount0, 0, "token0 out");
    assertGt(amount1, 0, "token1 in");

    uint256 realizedX64 = SafeCast.toUint256(amount1) * Q64 / SafeCast.toUint256(-amount0);
    assertGe(realizedX64, bidX64, "realized below band");
    assertLe(realizedX64, askX64 * 101 / 100, "realized above band (+slippage)");
  }

  // ── Abuse protection: reads are gated to in-swap pool attribution ──────────

  function test_e2e_directProviderReadIsGated() public {
    // Calling the provider outside a pool swap → it forwards THIS test as the "pool"; the oracle's
    // inSwap() attribution check rejects it, so the read cannot be performed off the swap path.
    vm.expectRevert();
    provider.getBidAndAskPrice();
  }

  // ── Staleness halt propagates oracle → provider → pool ─────────────────────

  function test_e2e_staleFeedHaltsSwap() public {
    // Push time past the provider's max staleness without refreshing the feed.
    vm.warp(block.timestamp + MAX_STALENESS + 1);

    vm.expectRevert(); // provider reverts FeedStalled → pool reverts PriceProviderFailed
    _swap(SWAPPER, swapper, false, _i128ExactIn(100_000), type(uint128).max);
  }

  // ── Synthetic ratio feed: price(base)/price(quote) ─────────────────────────

  function test_e2e_syntheticRatioQuote() public {
    bytes32 feedBase = keccak256("BTC/USD");
    bytes32 feedQuote = keccak256("ETH/USD");

    FaithfulAnchoredPriceProvider synthProvider = new FaithfulAnchoredPriceProvider(
      address(anchorOracle),
      feedBase,
      feedQuote,
      MIN_MARGIN,
      MAX_STALENESS,
      MAX_SPREAD_BPS,
      address(token0),
      address(token1)
    );
    MetricOmmPool synthPool = _deployAnchorPool(address(synthProvider));

    // BTC/USD = 30_000, ETH/USD = 2_000 → synthetic BTC/ETH = 15.
    anchorOracle.setFeed(feedBase, 30_000 * 1e8, 30, 0, block.timestamp);
    anchorOracle.setFeed(feedQuote, 2_000 * 1e8, 20, 0, block.timestamp);

    (uint128 bid, uint128 ask) = synthPool.getSellAndBuyPrices();
    uint256 expectedMidX64 = 15 * Q64;
    assertLt(uint256(bid), expectedMidX64, "bid below synthetic mid");
    assertGt(uint256(ask), expectedMidX64, "ask above synthetic mid");
    // Mid of the band ≈ 15 (combined spread 30+20 bps is tight).
    assertApproxEqRel((uint256(bid) + uint256(ask)) / 2, expectedMidX64, 0.01e18, "synthetic mid ~= 15");
  }
}
