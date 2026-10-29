// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title IExtsload
/// @notice Read arbitrary contract storage via `EXTSLOAD`-style external calls (Uniswap V4-style pattern).
/// @dev Off-chain callers and libraries must interpret slot values using the target contract's storage layout.
///      Miscomputed slots read unrelated data; there is no runtime validation of layout at this boundary.
interface IExtsload {
  // ============ View ============

  /// @notice Read a single 32-byte storage slot.
  /// @param slot Keccak-derived or raw slot key as used by the implementation contract.
  /// @return value Raw `bytes32` contents of the slot.
  function extsload(bytes32 slot) external view returns (bytes32 value);

  /// @notice Read many storage slots in one call.
  /// @param slots Each entry is a slot key as for `extsload(bytes32)`.
  /// @return values One `bytes32` per slot, same order as `slots`.
  function extsload(bytes32[] calldata slots) external view returns (bytes32[] memory values);

  /// @notice Read a contiguous run of slots starting at `startSlot` for `nSlots` steps.
  /// @param startSlot First slot (inclusive).
  /// @param nSlots Number of consecutive slots to read (`startSlot`, `startSlot + 1`, ...).
  /// @return values Raw slot values in order.
  function extsload(bytes32 startSlot, uint256 nSlots) external view returns (bytes32[] memory values);
}
