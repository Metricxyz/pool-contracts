// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.0;

/// @notice Provides a flexible and updatable auth pattern which is completely separate from application logic.
/// @author Solmate (https://github.com/transmissions11/solmate/blob/main/src/auth/Auth.sol)
/// @author Modified from Dappsys (https://github.com/dapphub/ds-auth/blob/master/src/auth.sol)
abstract contract Auth {
  event OwnershipTransferred(address indexed user, address indexed newOwner);

  event AuthorityUpdated(address indexed user, Authority indexed newAuthority);

  address public owner;

  Authority public authority;

  error Auth_Unauthorized();
  error Auth_InvalidOwner();

  constructor(address _owner, Authority _authority) {
    if (_owner == address(0)) revert Auth_InvalidOwner();
    owner = _owner;
    authority = _authority;

    emit OwnershipTransferred(msg.sender, _owner);
    emit AuthorityUpdated(msg.sender, _authority);
  }

  modifier onlyOwner() virtual {
    if (msg.sender != owner) {
      revert Auth_Unauthorized();
    }

    _;
  }

  modifier requiresAuth() virtual {
    if (!isAuthorized(msg.sender, msg.sig)) {
      revert Auth_Unauthorized();
    }

    _;
  }

  function isAuthorized(address user, bytes4 functionSig) internal view virtual returns (bool) {
    Authority auth = authority; // Memoizing authority saves us a warm SLOAD, around 100 gas.

    // The owner must remain able to act even if the authority reverts or is misconfigured.
    return user == owner || (address(auth) != address(0) && auth.canCall(user, address(this), functionSig));
  }

  function setAuthority(Authority newAuthority) public virtual onlyOwner {
    authority = newAuthority;

    emit AuthorityUpdated(msg.sender, newAuthority);
  }

  function transferOwnership(address newOwner) public virtual onlyOwner {
    owner = newOwner;

    emit OwnershipTransferred(msg.sender, newOwner);
  }
}

/// @notice A generic interface for a contract which provides authorization data to an Auth instance.
/// @author Solmate (https://github.com/transmissions11/solmate/blob/main/src/auth/Auth.sol)
/// @author Modified from Dappsys (https://github.com/dapphub/ds-auth/blob/master/src/auth.sol)
interface Authority {
  function canCall(address user, address target, bytes4 functionSig) external view returns (bool);
}
