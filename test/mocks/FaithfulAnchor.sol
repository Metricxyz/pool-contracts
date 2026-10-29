// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPriceProvider} from "../../contracts/interfaces/IPriceProvider/IPriceProvider.sol";

/// @dev The pool surface the abuse-protected oracle inspects to attribute a read.
interface IInSwap {
  function inSwap() external view returns (address priceProvider);
}

/// @dev The oracle read surface the provider uses (mirrors smart-contracts-poc IPricedOracle.price).
interface IAnchorPricedOracle {
  function price(bytes32 feedId, address pool)
    external
    returns (uint256 mid, uint256 spread, uint16 volatility, uint256 refTime);
}

/// @title FaithfulAnchorOracle
/// @notice Faithful in-repo stand-in for the abuse-protected providers oracle from smart-contracts-poc.
///         Reads are attributed: the caller (the provider) is only served when the `pool` it names is
///         currently mid-swap bound to that exact provider (`pool.inSwap() == msg.sender`). Mids are
///         8-decimal; spreads are whole bps; a spread >= 10_000 (ORACLE_BPS) is the off-hours/stall marker.
contract FaithfulAnchorOracle is IAnchorPricedOracle {
  struct Feed {
    uint256 mid8; // 8-decimal mid price
    uint256 spreadBps; // whole bps
    uint16 volatility;
    uint256 refTime;
  }

  mapping(bytes32 => Feed) public feeds;

  error ReadNotAttributed(address pool, address provider, address boundProvider);

  function setFeed(bytes32 feedId, uint256 mid8, uint256 spreadBps, uint16 volatility, uint256 refTime) external {
    feeds[feedId] = Feed({mid8: mid8, spreadBps: spreadBps, volatility: volatility, refTime: refTime});
  }

  /// @inheritdoc IAnchorPricedOracle
  function price(bytes32 feedId, address pool)
    external
    view
    returns (uint256 mid, uint256 spread, uint16 volatility, uint256 refTime)
  {
    address bound = IInSwap(pool).inSwap();
    if (bound != msg.sender) revert ReadNotAttributed(pool, msg.sender, bound);
    Feed memory f = feeds[feedId];
    return (f.mid8, f.spreadBps, f.volatility, f.refTime);
  }
}

/// @title FaithfulAnchoredPriceProvider
/// @notice Faithful in-repo stand-in for AnchoredPriceProvider (reference mode): clamps the quote to the
///         band `mid ± (spreadBps + minMargin)` and converts the 8-decimal oracle mid to a Q64.64 price,
///         byte-for-byte with the real provider's `_bandEdge`. Reads go through the attributed,
///         non-view `price(feedId, pool)` path, forwarding the pool (its `msg.sender`). Optional second
///         feed gives a synthetic ratio (price(base)/price(quote)) with per-leg spreads added.
contract FaithfulAnchoredPriceProvider is IPriceProvider {
  uint256 internal constant Q64 = 1 << 64;
  uint256 internal constant ORACLE_DECIMALS = 1e8;
  uint256 internal constant BPS_BASE_U = 1e18;
  uint256 internal constant ONE_BPS_E18 = 1e14;
  uint16 internal constant ORACLE_BPS = 10_000;
  uint256 internal constant STEP_DENOM = ORACLE_DECIMALS * BPS_BASE_U; // 1e26

  IAnchorPricedOracle public immutable oracle;
  bytes32 public immutable baseFeedId;
  bytes32 public immutable quoteFeedId; // 0 = single feed (no synthetic conversion)
  uint256 public immutable minMargin;
  uint256 public immutable maxRefStaleness;
  uint16 public immutable maxSpreadBps;

  address internal immutable _token0;
  address internal immutable _token1;

  error FeedStalled();

  constructor(
    address _oracle,
    bytes32 _baseFeedId,
    bytes32 _quoteFeedId,
    uint256 _minMargin,
    uint256 _maxRefStaleness,
    uint16 _maxSpreadBps,
    address token0_,
    address token1_
  ) {
    oracle = IAnchorPricedOracle(_oracle);
    baseFeedId = _baseFeedId;
    quoteFeedId = _quoteFeedId;
    minMargin = _minMargin;
    maxRefStaleness = _maxRefStaleness;
    maxSpreadBps = _maxSpreadBps;
    _token0 = token0_;
    _token1 = token1_;
  }

  function token0() external view returns (address) {
    return _token0;
  }

  function token1() external view returns (address) {
    return _token1;
  }

  function getBidAndAskPrice() external returns (uint128 bid, uint128 ask) {
    (uint256 mid, uint256 spreadBps, bool ok) = _readLeg(baseFeedId);
    if (!ok) revert FeedStalled();

    if (quoteFeedId != bytes32(0)) {
      (uint256 mid2, uint256 spreadBps2, bool ok2) = _readLeg(quoteFeedId);
      if (!ok2 || mid2 == 0) revert FeedStalled();
      mid = Math.mulDiv(mid, ORACLE_DECIMALS, mid2); // synthetic ratio, 8-decimal
      spreadBps += spreadBps2;
    }

    (bid, ask) = _computeBidAsk(mid, spreadBps);
    if (bid == 0 || ask == type(uint128).max) revert FeedStalled();
  }

  function _readLeg(bytes32 feedId) internal returns (uint256 mid, uint256 spreadBps, bool ok) {
    uint256 refTime;
    (mid, spreadBps,, refTime) = oracle.price(feedId, msg.sender); // forwards the pool (msg.sender)

    // Staleness: any future or too-old refTime halts (never clamp to a stale anchor).
    if (refTime == 0 || refTime > block.timestamp || block.timestamp - refTime > maxRefStaleness) {
      return (mid, spreadBps, false);
    }
    // mid positive; spread not the stalled/off-hours marker.
    if (mid == 0 || spreadBps >= ORACLE_BPS) return (mid, spreadBps, false);
    ok = true;
  }

  function _computeBidAsk(uint256 mid, uint256 spreadBps) internal view returns (uint128, uint128) {
    uint256 half = spreadBps * ONE_BPS_E18 + minMargin;
    // Circuit breaker / band-width guards (real provider validates maxSpreadBps + band width).
    if (spreadBps > maxSpreadBps || half >= BPS_BASE_U) return (0, type(uint128).max);

    uint256 refBid = Math.mulDiv(mid, Q64 * (BPS_BASE_U - half), STEP_DENOM, Math.Rounding.Floor);
    uint256 refAsk = Math.mulDiv(mid, Q64 * (BPS_BASE_U + half), STEP_DENOM, Math.Rounding.Ceil);
    if (refBid == 0 || refAsk > type(uint128).max || refBid >= refAsk) return (0, type(uint128).max);
    return (uint128(refBid), uint128(refAsk));
  }
}
