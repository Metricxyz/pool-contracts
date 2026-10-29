// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

/// @title IPriceProviderSwapReporter
/// @notice Optional extension: pool may call `reportSwap` after swaps when configured to report to the provider.
/// @dev Implementations should not assume ordering relative to other pool state; failures are swallowed by the pool
///      when reporting is best-effort. All amounts are the same signed convention as pool `Swap` event deltas.
interface IPriceProviderSwapReporter {
  // ============ Mutating ============

  /// @notice Report a completed swap to the price provider.
  /// @param sender Original `msg.sender` to the pool `swap` call (often a router).
  /// @param recipient Swap output recipient passed to the pool.
  /// @param zeroForOne Swap direction (`true` = token0 in, token1 out).
  /// @param amountSpecified Signed exact-in or exact-out magnitude as passed to `swap`.
  /// @param priceLimitX64 Q64.64 price limit from the swap call.
  /// @param amount0Delta Signed token0 balance change (pool perspective).
  /// @param amount1Delta Signed token1 balance change (pool perspective).
  /// @param curBinIdx Bin index after the swap.
  /// @param curPosInBin Position within bin after the swap.
  function reportSwap(
    address sender,
    address recipient,
    bool zeroForOne,
    int128 amountSpecified,
    uint128 priceLimitX64,
    int256 amount0Delta,
    int256 amount1Delta,
    int8 curBinIdx,
    uint104 curPosInBin
  ) external;
}
