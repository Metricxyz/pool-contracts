// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";

/// @title MetricReentrancyGuardTransient
/// @notice Transient reentrancy guard keyed by action id (function-name hash), forked from OpenZeppelin ReentrancyGuardTransient.
/// @dev Stores a non-zero uint256 while an action runs; any second guarded entry reverts.
abstract contract MetricReentrancyGuardTransient {
  bytes32 private constant REENTRANCY_GUARD_STORAGE =
    keccak256(abi.encode(uint256(keccak256("metric.storage.ReentrancyGuard")) - 1)) & ~bytes32(uint256(0xff));

  /// @dev Unauthorized reentrant call or overlapping guarded action.
  error ReentrancyGuardReentrantCall();

  /// @dev `actionId` must be the keccak256-based id for the external function (see PoolActions).
  modifier nonReentrant(uint256 actionId) {
    _nonReentrantBefore(actionId);
    _;
    _nonReentrantAfter();
  }

  /// @dev Blocks view functions while any guarded action is active.
  modifier nonReentrantView() {
    _nonReentrantBeforeView();
    _;
  }

  function _nonReentrantBeforeView() private view {
    if (_currentAction() != 0) {
      revert ReentrancyGuardReentrantCall();
    }
  }

  function _nonReentrantBefore(uint256 actionId) private {
    _nonReentrantBeforeView();
    TransientSlot.tstore(TransientSlot.asUint256(_reentrancyGuardStorageSlot()), actionId);
  }

  function _nonReentrantAfter() internal {
    TransientSlot.tstore(TransientSlot.asUint256(_reentrancyGuardStorageSlot()), 0);
  }

  /// @dev Returns the active action id, or 0 if no guarded function is on the call stack.
  function _currentAction() internal view returns (uint256) {
    return TransientSlot.tload(TransientSlot.asUint256(_reentrancyGuardStorageSlot()));
  }

  function _reentrancyGuardStorageSlot() internal pure virtual returns (bytes32) {
    return REENTRANCY_GUARD_STORAGE;
  }
}
