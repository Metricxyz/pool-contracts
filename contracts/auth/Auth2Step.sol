// SPDX-License-Identifier: MIT
// Adapted from OpenZeppelin Contracts v5.1.0 (access/Ownable2Step.sol), built on Solmate-style `Auth`.

pragma solidity ^0.8.20;

import {Auth} from "./Auth.sol";

/**
 * @dev Contract module which provides access control mechanism, where
 * there is an account (an owner), plus any callers approved by the optional
 * `Authority`, that can be granted access to specific functions.
 *
 * This extension of the {Auth} contract includes a two-step mechanism to transfer
 * ownership, where the new owner must call {acceptOwnership} in order to replace the
 * old one. This can help prevent common mistakes, such as transfers of ownership to
 * incorrect accounts, or to contracts that are unable to interact with the
 * permission system.
 *
 * The initial owner is specified at deployment time in the constructor for `Auth`. This
 * can later be changed with {transferOwnership} and {acceptOwnership}.
 *
 * This module is used through inheritance. It will make available all functions
 * from parent (Auth).
 */
abstract contract Auth2Step is Auth {
  address private _pendingOwner;

  event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);

  /**
   * @dev Returns the address of the pending owner.
   */
  function pendingOwner() public view virtual returns (address) {
    return _pendingOwner;
  }

  /**
   * @dev Starts the ownership transfer of the contract to a new account. Replaces the pending transfer if there is one.
   * Can only be called by the current owner.
   *
   * Setting `newOwner` to the zero address is allowed; this can be used to cancel an initiated ownership transfer.
   */
  function transferOwnership(address newOwner) public override onlyOwner {
    _pendingOwner = newOwner;
    emit OwnershipTransferStarted(owner, newOwner);
  }

  /**
   * @dev Transfers ownership of the contract to a new account (`newOwner`) and deletes any pending owner.
   * Internal function without access restriction.
   */
  function _transferOwnership(address newOwner) internal {
    delete _pendingOwner;
    address previousOwner = owner;
    owner = newOwner;
    emit OwnershipTransferred(previousOwner, newOwner);
  }

  /**
   * @dev The new owner accepts the ownership transfer.
   * The authority and its delegated permissions remain unchanged. The new owner can call
   * {setAuthority} with the zero address to disconnect all delegated protocol access.
   */
  function acceptOwnership() public virtual {
    address sender = msg.sender;
    if (pendingOwner() != sender) {
      revert Auth_Unauthorized();
    }
    _transferOwnership(sender);
  }
}
