// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {ISwapAllowlistProvider} from "../../contracts/interfaces/ISwapAllowlistProvider.sol";

/// @title MockSwapAllowlistProvider
/// @notice Test double for `ISwapAllowlistProvider` plus an unrestricted test-only `setAllowedToSwap`.
contract MockSwapAllowlistProvider is ISwapAllowlistProvider {
  mapping(address => mapping(address => bool)) internal _allowedToSwap;

  /// @inheritdoc ISwapAllowlistProvider
  function isAllowedToSwap(address swapper) external view override returns (bool) {
    return _allowedToSwap[msg.sender][swapper];
  }

  /// @inheritdoc ISwapAllowlistProvider
  function isAllowedToSwap(address pool, address swapper) external view override returns (bool) {
    return _allowedToSwap[pool][swapper];
  }

  function setAllowedToSwap(address pool, address swapper, bool allowed) external {
    _allowedToSwap[pool][swapper] = allowed;
  }
}
