// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {MetricHooks} from "../contracts/libraries/MetricHooks.sol";
import {IMetricOmmHooks} from "../contracts/interfaces/hooks/IMetricOmmHooks.sol";
import {WrongSelectorHook} from "./mocks/hooks/WrongSelectorHook.sol";

contract MetricHooksHarness {
  function validateHooksConfig(address hooks, uint16 permissions) external pure {
    MetricHooks.validateHooksConfig(hooks, permissions);
  }

  function callHook(address hooks, bytes memory data) external {
    MetricHooks.callHook(hooks, data);
  }
}

contract MetricHooksTest is Test {
  MetricHooksHarness internal harness = new MetricHooksHarness();

  function test_validateHooksConfig_revertsWhenHooksZeroButPermissionsSet() public {
    vm.expectRevert(MetricHooks.InvalidHooksConfig.selector);
    harness.validateHooksConfig(address(0), MetricHooks.BEFORE_SWAP_FLAG);
  }

  function test_validateHooksConfig_revertsWhenHooksSetButPermissionsZero() public {
    vm.expectRevert(MetricHooks.InvalidHooksConfig.selector);
    harness.validateHooksConfig(makeAddr("hooks"), 0);
  }

  function test_callHook_revertsOnWrongSelector() public {
    WrongSelectorHook hook = new WrongSelectorHook();
    hook.bindPool(address(harness));

    bytes memory data = abi.encodeCall(
      IMetricOmmHooks.beforeSwap,
      (address(0), address(0), false, int128(0), uint128(0), uint256(0), uint128(0), uint128(0), "")
    );

    vm.expectRevert(MetricHooks.InvalidHookResponse.selector);
    harness.callHook(address(hook), data);
  }
}
