// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title IPriceProvider
/// @notice Oracle surface used by pools for bid/ask and token pair metadata.
/// @dev Price values returned by `getQuote` are Q64.64 fixed-point unless a concrete implementation documents otherwise.
interface IPriceProvider {
  /// @notice Base token quoted by this provider; for Metric pools this must equal pool `token0`.
  function token0() external view returns (address baseToken);

  /// @notice Quote token quoted by this provider; for Metric pools this must equal pool `token1`.
  function token1() external view returns (address quoteToken);

  /// @notice Bid, ask, and reference in Q64.64 fixed-point.
  /// @dev Protocol expectation: `referencePrice` equals sqrt(bidPrice * askPrice) and is a faithful
  ///      geometric mid.
  ///      `referencePrice` is used for fee calculation and as the mid/price-path anchor; bid and ask bound it.
  ///      Providers that manipulate `referencePrice` to pay less fees may be blackilisted/deprioritized.
  function getQuote() external returns (uint128 bidPrice, uint128 askPrice, uint128 referencePrice);
}
