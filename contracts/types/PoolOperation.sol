// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @notice Batched per-bin liquidity add or remove payload (parallel arrays).
/// @param binIdxs Bin indices to modify.
/// @param shares Shares to add or remove per corresponding bin index.
struct LiquidityDelta {
  int256[] binIdxs;
  uint256[] shares;
}

/// @notice Per-bin balance change used in liquidity and swap events.
/// @dev `delta0Scaled` and `delta1Scaled` are scaled token balances inside bins (not raw ERC20 amounts).
///      Positive means net token entered the bin; negative means net token left the bin.
/// @param delta0Scaled Net change in the bin scaled token0 balance.
/// @param delta1Scaled Net change in the bin scaled token1 balance.
struct BinBalanceDelta {
  int256 delta0Scaled;
  int256 delta1Scaled;
}
