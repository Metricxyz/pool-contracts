// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @notice Each field encodes the invocation order for a extension action.
/// @dev Pool contains up to 7 extensions that are numbered from 1 to 7 in the pool's `extensions` array.
///      To encode invocation order we pack array of 3-bit (values 0-7) into a single uint256.
///      Least significant slot is first element of the array.
///      0 represents termination of the sequence.
///      The sequence defines which extensions will be called for a given action.
struct ExtensionOrders {
  uint256 beforeAddLiquidity;
  uint256 afterAddLiquidity;
  uint256 beforeRemoveLiquidity;
  uint256 afterRemoveLiquidity;
  uint256 beforeSwap;
  uint256 afterSwap;
}

/// @notice Contains addresses of all extensions that are configured for the pool.
struct PoolExtensions {
  address extension1;
  address extension2;
  address extension3;
  address extension4;
  address extension5;
  address extension6;
  address extension7;
}
