// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {MockERC20} from "./MockERC20.sol";

contract MockFeeTransferToken is MockERC20 {
  error RejectedDestination();

  address private rejectedDestination;
  bool private returnsFalse;

  constructor(uint8 decimals_) MockERC20("FeeTransferToken", "FEE", decimals_) {}

  function setRejectedDestination(address destination, bool returnsFalse_) external {
    rejectedDestination = destination;
    returnsFalse = returnsFalse_;
  }

  function transfer(address to, uint256 amount) public override returns (bool) {
    if (to == rejectedDestination) {
      if (!returnsFalse) revert RejectedDestination();
      return false;
    }
    return super.transfer(to, amount);
  }
}
