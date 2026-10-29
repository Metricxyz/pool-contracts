// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {IDepositAllowlistProvider} from "../../contracts/interfaces/IDepositAllowlistProvider.sol";

/// @title MockDepositAllowlistProvider
/// @notice Test double for `IDepositAllowlistProvider` plus an unrestricted test-only `setAllowedToDeposit`.
contract MockDepositAllowlistProvider is IDepositAllowlistProvider {
  mapping(address => mapping(address => bool)) internal _allowedToDeposit;

  /// @inheritdoc IDepositAllowlistProvider
  function isAllowedToDeposit(address depositor) external view override returns (bool) {
    return _allowedToDeposit[msg.sender][depositor];
  }

  /// @inheritdoc IDepositAllowlistProvider
  function isAllowedToDeposit(address pool, address depositor) external view override returns (bool) {
    return _allowedToDeposit[pool][depositor];
  }

  function setAllowedToDeposit(address pool, address depositor, bool allowed) external {
    _allowedToDeposit[pool][depositor] = allowed;
  }
}
