// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {PoolFeeConfig} from "../contracts/types/FactoryStorage.sol";

/// @dev Tests using `address(this)` as factory expose `priceProviderTimelock` and related stubs for pool/factory reads.
abstract contract FactoryFeeCapsStub {
  mapping(address => uint256) public priceProviderTimelock;

  mapping(address => address) public poolAdmin;

  mapping(address => PoolFeeConfig) public poolFeeConfig;

  mapping(address => address) public poolAdminFeeDestination;

  mapping(address => address) public pendingPriceProvider;

  mapping(address => uint256) public pendingPriceProviderExecuteAfter;

  function getFeeCaps()
    external
    view
    virtual
    returns (
      uint24 maxProtocolSpreadFeeE6,
      uint24 maxAdminSpreadFeeE6,
      uint24 maxProtocolNotionalFeeE8,
      uint24 maxAdminNotionalFeeE8
    )
  {
    return (200_000, 200_000, 1_000_000, 1_000_000);
  }
}
