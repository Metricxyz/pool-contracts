// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

library CallExtension {
  error ExtensionCallFailed();
  error InvalidExtensionResponse();

  /// @dev `data` must be ABI-encoded calldata; its selector is also the required return selector.
  function callExtension(address extension, bytes memory data) internal {
    (bool success, bytes memory result) = extension.call(data);
    if (!success) {
      if (result.length > 0) {
        assembly ("memory-safe") {
          revert(add(result, 32), mload(result))
        }
      }
      revert ExtensionCallFailed();
    }
    if (result.length < 32) {
      revert InvalidExtensionResponse();
    }
    bytes4 returnedSelector;
    assembly ("memory-safe") {
      returnedSelector := mload(add(result, 32))
    }
    bytes4 expectedSelector;
    assembly ("memory-safe") {
      expectedSelector := mload(add(data, 32))
    }
    if (returnedSelector != expectedSelector) {
      revert InvalidExtensionResponse();
    }
  }
}
