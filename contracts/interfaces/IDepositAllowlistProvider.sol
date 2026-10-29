// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

/// @title IDepositAllowlistProvider
/// @notice Optional gate for `addLiquidity`: pools with a non-zero deposit allowlist provider consult this contract.
/// @dev The pool calls `isAllowedToDeposit(pool, depositor)` with `pool` set to the pool address. Implementations
///      that only implement the two-argument form may still be used; the one-argument overload is for contracts
///      that key off `msg.sender` as the pool. Configuration entrypoints live on implementation-specific interfaces
///      (see metric-periphery `IDepositAllowlist`).
interface IDepositAllowlistProvider {
  /// @notice Whether `depositor` may add liquidity when the pool is `msg.sender`.
  /// @param depositor Address attempting to deposit (typically the liquidity callback owner or router).
  function isAllowedToDeposit(address depositor) external view returns (bool);

  /// @notice Whether `depositor` may add liquidity on `pool`.
  /// @param pool Pool contract address.
  /// @param depositor Address attempting to deposit.
  function isAllowedToDeposit(address pool, address depositor) external view returns (bool);
}
