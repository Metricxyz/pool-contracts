// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title PoolActions
/// @notice Transient reentrancy action ids for MetricOmmPool (keccak256 of the external function name).
library PoolActions {
  uint256 internal constant ADD_LIQUIDITY = uint256(keccak256("addLiquidity"));
  uint256 internal constant REMOVE_LIQUIDITY = uint256(keccak256("removeLiquidity"));
  uint256 internal constant SWAP = uint256(keccak256("swap"));
  uint256 internal constant SIMULATE_SWAP_AND_REVERT = uint256(keccak256("simulateSwapAndRevert"));
  uint256 internal constant COLLECT_FEES = uint256(keccak256("collectFees"));
  uint256 internal constant SET_POOL_FEES = uint256(keccak256("setPoolFees"));
  uint256 internal constant SET_BIN_ADDITIONAL_FEES = uint256(keccak256("setBinAdditionalFees"));
}
