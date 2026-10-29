// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

/// @title ISwapAllowlistProvider
/// @notice Optional gate for `swap`: pools with a non-zero swap allowlist provider consult this contract.
/// @dev The pool calls `isAllowedToSwap(pool, swapper)` with `pool` set to the pool address. The one-argument
///      overload treats `msg.sender` as the pool. Configuration entrypoints live on implementation-specific
///      interfaces (see metric-periphery `ISwapAllowlist`).
interface ISwapAllowlistProvider {
  /// @notice Whether `swapper` may swap when the pool is `msg.sender`.
  /// @param swapper Address initiating the swap (the pool's `msg.sender` to the callback path is the swap router).
  function isAllowedToSwap(address swapper) external view returns (bool);

  /// @notice Whether `swapper` may swap against `pool`.
  /// @param pool Pool contract address.
  /// @param swapper Address that must be authorized to swap.
  function isAllowedToSwap(address pool, address swapper) external view returns (bool);
}
