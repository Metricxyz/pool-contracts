// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {MetricOmmPoolBaseTest} from "./MetricOmmPool.base.t.sol";
import {IMetricOmmPool} from "../contracts/interfaces/IMetricOmmPool/IMetricOmmPool.sol";
import {IMetricOmmPoolActions} from "../contracts/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {MetricReentrancyGuardTransient} from "../contracts/utils/MetricReentrancyGuardTransient.sol";
import {InSwapProbeCaller} from "./mocks/InSwapProbeCaller.sol";

contract MetricOmmPoolInSwapTest is MetricOmmPoolBaseTest {
  function test_inSwap_returnsZeroOutsideSwap() public view {
    assertEq(IMetricOmmPool(address(pool)).inSwap(), address(0));
  }

  function test_inSwap_returnsPriceProviderDuringSwapCallback() public {
    _approveUsersForPool(address(pool));
    _addLiquidity(1, -5, 4, 100_000, 0);

    InSwapProbeCaller caller = new InSwapProbeCaller(users[0]);
    _approveCallerForPool(address(caller), address(pool));

    vm.prank(users[0]);
    caller.swap(address(pool), users[0], false, int128(1000), type(uint128).max);

    assertEq(caller.providerSeenInCallback(), address(oracle));
    assertEq(IMetricOmmPool(address(pool)).inSwap(), address(0));
  }

  function test_swap_revertsWhenNestedSwapFromCallback() public {
    _approveUsersForPool(address(pool));
    _addLiquidity(1, -5, 4, 100_000, 0);

    InSwapProbeCaller caller = new InSwapProbeCaller(users[0]);
    _approveCallerForPool(address(caller), address(pool));

    bytes memory nested = abi.encode(address(pool), users[0], false, int128(1), uint128(type(uint128).max));

    vm.prank(users[0]);
    vm.expectRevert(MetricReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
    caller.swapWithCallbackData(address(pool), users[0], false, int128(1000), type(uint128).max, nested);
  }

  function _approveCallerForPool(address caller, address poolAddr) internal {
    token0.mint(caller, 1_000_000_000);
    token1.mint(caller, 1_000_000_000);
    vm.startPrank(caller);
    token0.approve(poolAddr, type(uint256).max);
    token1.approve(poolAddr, type(uint256).max);
    vm.stopPrank();
  }
}
