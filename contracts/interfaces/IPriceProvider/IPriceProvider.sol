// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

/// @title IPriceProvider
/// @notice Oracle surface used by pools for bid/ask and token pair metadata.
/// @dev Price values returned by `getBidAndAskPrice` / `getBidAndAskPriceUi` are Q64.64 fixed-point unless a concrete
///      implementation documents otherwise. `getBidPrice` / `getAskPrice` may return wider `uint256` encodings for
///      legacy or UI paths; integrators should prefer the paired `getBidAndAskPrice*` view when enforcing consistency.
///      Mutating methods are implementation-defined; pools only require `getTokens` and bid/ask readers for core logic.
interface IPriceProvider {
  // ============ Mutating: Configuration (implementation-defined) ============

  /// @notice Optional confidence or tuning parameter (semantics defined by implementation).
  function setConfidenceParam(uint256 newValue) external;

  /// @dev Debug or staging hook; semantics defined by implementation. Not relied on by core pool math in production paths.
  function setCexStep(int256 newCexStep) external;

  /// @notice Register or update a Chainlink-style oracle for `token` (implementation-defined).
  function setClOracle(address token, address oracle, uint32 heartbeat) external;

  /// @notice Remove oracle association for `token` (implementation-defined).
  function removeClOracle(address token) external;

  /// @notice Set maximum allowed deviation versus CL answer (implementation-defined units).
  function setMaxClDeviation(uint16 newMaxDeviation) external;

  // ============ View: Token pair ============

  /// @notice Tokens quoted by this provider; for Metric pools this must match pool `(token0, token1)` order.
  /// @return baseToken Typically pool token0.
  /// @return quoteToken Typically pool token1.
  function getTokens() external view returns (address baseToken, address quoteToken);

  // ============ View: Bid / ask (wide encoding) ============

  /// @notice Bid side price; encoding is implementation-defined (often Q64.64 or UI-scaled `uint256`).
  function getBidPrice() external view returns (uint256 bidPrice);

  /// @notice Bid price for UI or alternate scaling (implementation-defined).
  function getBidPriceUi() external view returns (uint256 bidPrice);

  /// @notice Ask side price; encoding is implementation-defined.
  function getAskPrice() external view returns (uint256 askPrice);

  /// @notice Ask price for UI or alternate scaling (implementation-defined).
  function getAskPriceUi() external view returns (uint256 askPrice);

  // ============ View: Bid / ask (canonical uint128 pair) ============

  /// @notice Bid and ask in Q64.64 fixed-point as `uint128` pair (canonical for pool mid/spread math when applicable).
  function getBidAndAskPrice() external view returns (uint128 bidPrice, uint128 askPrice);

  /// @notice Bid and ask for UI or alternate scaling (implementation-defined; often same width as canonical pair).
  function getBidAndAskPriceUi() external view returns (uint128 bidPrice, uint128 askPrice);
}
