// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Authority} from "../../contracts/auth/Auth.sol";

contract MockAuthority is Authority {
  error AuthorityUnavailable();

  mapping(address user => mapping(address target => mapping(bytes4 selector => bool))) public permissions;
  bool public unavailable;

  function setPermission(address user, address target, bytes4 selector, bool allowed) external {
    permissions[user][target][selector] = allowed;
  }

  function setUnavailable(bool value) external {
    unavailable = value;
  }

  function canCall(address user, address target, bytes4 selector) external view returns (bool) {
    if (unavailable) revert AuthorityUnavailable();
    return permissions[user][target][selector];
  }
}
