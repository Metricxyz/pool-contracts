// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {ValidateExtensionsConfig} from "../contracts/libraries/ValidateExtensionsConfig.sol";
import {CallExtension} from "../contracts/libraries/CallExtension.sol";
import {ExtensionOrders} from "../contracts/types/PoolExtensionsConfig.sol";
import {IMetricOmmExtensions} from "../contracts/interfaces/extensions/IMetricOmmExtensions.sol";
import {WrongSelectorExtension} from "./mocks/extensions/WrongSelectorExtension.sol";
import {ExtensionOrderTestLib} from "./ExtensionOrderTestLib.sol";

contract ValidateExtensionsConfigHarness {
  function validateExtensionsConfig(
    address[] calldata extensions,
    ExtensionOrders calldata orders,
    bytes[] calldata extensionInitData
  ) external pure {
    ValidateExtensionsConfig.validateExtensionsConfig(extensions, orders, extensionInitData);
  }

  function callExtension(address extension, bytes memory data) external {
    CallExtension.callExtension(extension, data);
  }
}

contract MetricExtensionsTest is Test {
  ValidateExtensionsConfigHarness internal harness = new ValidateExtensionsConfigHarness();

  function test_validateExtensionsConfig_revertsWhenExtensionsEmptyButOrdersSet() public {
    address[] memory extensions = new address[](0);
    bytes[] memory extensionInitData = new bytes[](0);
    ExtensionOrders memory orders;
    orders.beforeSwap = ExtensionOrderTestLib.encodeExtensionOrder(1, 0, 0, 0, 0, 0, 0);

    vm.expectRevert(ValidateExtensionsConfig.InvalidExtensionsConfig.selector);
    harness.validateExtensionsConfig(extensions, orders, extensionInitData);
  }

  function test_validateExtensionsConfig_revertsWhenExtensionsSetButAllOrdersZero() public {
    address[] memory extensions = new address[](1);
    extensions[0] = makeAddr("extensions");
    bytes[] memory extensionInitData = new bytes[](1);
    ExtensionOrders memory orders;

    vm.expectRevert(ValidateExtensionsConfig.InvalidExtensionsConfig.selector);
    harness.validateExtensionsConfig(extensions, orders, extensionInitData);
  }

  function test_validateExtensionsConfig_revertsOnDuplicateExtensionAddress() public {
    address extension = makeAddr("extension");
    address[] memory extensions = new address[](2);
    extensions[0] = extension;
    extensions[1] = extension;
    bytes[] memory extensionInitData = new bytes[](2);
    ExtensionOrders memory orders;
    orders.beforeSwap = ExtensionOrderTestLib.encodeExtensionOrder(1, 0, 0, 0, 0, 0, 0);

    vm.expectRevert(ValidateExtensionsConfig.InvalidExtensionsConfig.selector);
    harness.validateExtensionsConfig(extensions, orders, extensionInitData);
  }

  function test_validateExtensionOrder_revertsOnDuplicateExtensionIndex() public {
    address[] memory extensions = new address[](2);
    extensions[0] = makeAddr("extension1");
    extensions[1] = makeAddr("extension2");
    bytes[] memory extensionInitData = new bytes[](2);
    ExtensionOrders memory orders;
    orders.beforeSwap = ExtensionOrderTestLib.encodeExtensionOrder(1, 1, 0, 0, 0, 0, 0);

    vm.expectRevert(ValidateExtensionsConfig.InvalidExtensionOrder.selector);
    harness.validateExtensionsConfig(extensions, orders, extensionInitData);
  }

  function test_callExtension_revertsOnWrongSelector() public {
    WrongSelectorExtension extension = new WrongSelectorExtension();
    extension.bindPool(address(harness));

    bytes memory data = abi.encodeCall(
      IMetricOmmExtensions.beforeSwap,
      (address(0), address(0), false, int128(0), uint128(0), uint256(0), uint128(0), uint128(0), "")
    );

    vm.expectRevert(CallExtension.InvalidExtensionResponse.selector);
    harness.callExtension(address(extension), data);
  }
}
