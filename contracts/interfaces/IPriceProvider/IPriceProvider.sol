// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title IPriceProvider
/// @notice Oracle surface used by pools for bid/ask and token pair metadata.
/// @dev Price values returned by `getBidAndAskPrice` are Q64.64 fixed-point unless a concrete implementation documents otherwise.
interface IPriceProvider {
  /// @notice Base token quoted by this provider; for Metric pools this must equal pool `token0`.
  function token0() external view returns (address baseToken);

  /// @notice Quote token quoted by this provider; for Metric pools this must equal pool `token1`.
  function token1() external view returns (address quoteToken);

  /// @notice Bid and ask in Q64.64 fixed-point as `uint128` pair (canonical for pool mid/spread math when applicable).
  function getBidAndAskPrice() external returns (uint128 bidPrice, uint128 askPrice);
}
