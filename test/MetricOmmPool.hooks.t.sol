// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {MetricOmmPoolBaseTest} from "./MetricOmmPool.base.t.sol";
import {MetricOmmPoolFactory} from "../contracts/MetricOmmPoolFactory.sol";
import {MetricOmmPoolDeployer} from "../contracts/MetricOmmPoolDeployer.sol";
import {PoolParameters} from "../contracts/types/FactoryOperation.sol";
import {MetricHooks} from "../contracts/libraries/MetricHooks.sol";
import {Slot0Library} from "../contracts/libraries/Slot0Library.sol";
import {PoolSlot0} from "../contracts/types/HookTypes.sol";
import {MockMetricHook} from "./mocks/MockMetricHook.sol";
import {GateHook} from "./mocks/hooks/GateHook.sol";
import {RevertHook} from "./mocks/hooks/RevertHook.sol";
import {BinState} from "../contracts/types/PoolStorage.sol";
import {IMetricOmmPoolActions} from "../contracts/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";

contract MetricOmmPoolHooksTest is MetricOmmPoolBaseTest {
  uint72 constant HOOK_TEST_SALT = 12345;

  function test_factory_revertsWhenHooksZeroButPermissionsNonZero() public {
    MetricOmmPoolFactory f = new MetricOmmPoolFactory(address(this));
    MetricOmmPoolDeployer d = new MetricOmmPoolDeployer(address(f));
    f.setPoolDeployer(address(d));

    PoolParameters memory params = _factoryPoolParams(address(f));
    params.hooks = address(0);
    params.hooksPermissions = MetricHooks.BEFORE_SWAP_FLAG;

    vm.expectRevert(MetricHooks.InvalidHooksConfig.selector);
    f.createPool(params);
  }

  function test_factory_revertsWhenHooksSetButPermissionsZero() public {
    MetricOmmPoolFactory f = new MetricOmmPoolFactory(address(this));
    MetricOmmPoolDeployer d = new MetricOmmPoolDeployer(address(f));
    f.setPoolDeployer(address(d));

    PoolParameters memory params = _factoryPoolParams(address(f));
    params.hooks = makeAddr("hooks");
    params.hooksPermissions = 0;

    vm.expectRevert(MetricHooks.InvalidHooksConfig.selector);
    f.createPool(params);
  }

  function test_swap_callsOnlyEnabledHookFlags() public {
    MockMetricHook hook = new MockMetricHook();
    _deployPoolWithHook(address(hook), MetricHooks.BEFORE_SWAP_FLAG | MetricHooks.AFTER_SWAP_FLAG);
    hook.bindPool(address(pool));
    _approveUsersForPool(address(pool));
    _addLiquidity(1, -5, 4, 100000, 0);

    hook.resetCalls();
    _swap(0, users[0], false, int128(1000), type(uint128).max);

    assertTrue(hook.calledBeforeSwap());
    assertTrue(hook.calledAfterSwap());
    assertFalse(hook.calledBeforeAddLiquidity());
    assertGt(hook.lastBidPriceX64(), 0);
    assertGe(hook.lastAskPriceX64(), hook.lastBidPriceX64());
  }

  function test_simulateSwap_beforeSwapRevertBubblesToCaller() public {
    RevertHook hook = new RevertHook();
    _deployPoolWithHook(address(hook), MetricHooks.BEFORE_SWAP_FLAG);
    hook.bindPool(address(pool));
    _approveUsersForPool(address(pool));
    _addLiquidity(1, -5, 4, 100000, 0);

    vm.expectRevert(RevertHook.DeliberateHookRevert.selector);
    pool.simulateSwapAndRevert(
      users[0], false, int128(1000), type(uint128).max, uint128(2 ** 64), uint128(2 ** 64), bytes("")
    );
  }

  function test_simulateSwap_afterSwapRevertBubblesToCaller() public {
    RevertHook hook = new RevertHook();
    _deployPoolWithHook(address(hook), MetricHooks.AFTER_SWAP_FLAG);
    hook.bindPool(address(pool));
    _approveUsersForPool(address(pool));
    _addLiquidity(1, -5, 4, 100000, 0);

    vm.expectRevert(RevertHook.DeliberateAfterSwapHookRevert.selector);
    pool.simulateSwapAndRevert(
      users[0], false, int128(1000), type(uint128).max, uint128(2 ** 64), uint128(2 ** 64), bytes("")
    );
  }

  function test_simulateSwap_gateHookBlocksWhenClosed() public {
    GateHook hook = new GateHook();
    _deployPoolWithHook(address(hook), MetricHooks.BEFORE_SWAP_FLAG);
    hook.bindPool(address(pool));
    _approveUsersForPool(address(pool));
    _addLiquidity(1, -5, 4, 100000, 0);

    hook.setAllowSwap(false);
    vm.expectRevert(IMetricOmmPoolActions.NotAllowedToSwap.selector);
    pool.simulateSwapAndRevert(
      users[0], false, int128(1000), type(uint128).max, uint128(2 ** 64), uint128(2 ** 64), bytes("")
    );
  }

  function test_afterSwap_passesPackedSlot0FinalMatchingPool() public {
    MockMetricHook hook = new MockMetricHook();
    _deployPoolWithHook(address(hook), MetricHooks.AFTER_SWAP_FLAG);
    hook.bindPool(address(pool));
    _approveUsersForPool(address(pool));
    _addLiquidity(1, -5, 4, 100000, 0);

    _swap(0, users[0], false, int128(1000), type(uint128).max);

    assertTrue(hook.calledAfterSwap());
    PoolSlot0 memory fromHook = Slot0Library.unpack(hook.lastPackedSlot0Final());
    assertEq(fromHook.curBinIdx, _getCurBinIdx());
    assertEq(fromHook.curPosInBin, _getCurPosInBin());
  }

  function test_beforeSwap_revertBubblesToCaller() public {
    RevertHook hook = new RevertHook();
    _deployPoolWithHook(address(hook), MetricHooks.BEFORE_SWAP_FLAG);
    hook.bindPool(address(pool));
    _approveUsersForPool(address(pool));
    _addLiquidity(1, -5, 4, 100000, 0);

    vm.expectRevert(RevertHook.DeliberateHookRevert.selector);
    _swap(0, users[0], false, int128(1000), type(uint128).max);
  }

  function test_gateHook_blocksSwapWhenClosed() public {
    GateHook hook = new GateHook();
    _deployPoolWithHook(address(hook), MetricHooks.BEFORE_SWAP_FLAG);
    hook.bindPool(address(pool));
    _approveUsersForPool(address(pool));
    _addLiquidity(1, -5, 4, 100000, 0);

    hook.setAllowSwap(false);
    vm.expectRevert(IMetricOmmPoolActions.NotAllowedToSwap.selector);
    _swap(0, users[0], false, int128(1000), type(uint128).max);
  }

  function test_gateHook_allowsSwapWhenOpen() public {
    GateHook hook = new GateHook();
    _deployPoolWithHook(address(hook), MetricHooks.BEFORE_SWAP_FLAG);
    hook.bindPool(address(pool));
    _approveUsersForPool(address(pool));
    _addLiquidity(1, -5, 4, 100000, 0);

    (int256 amount0,) = _swap(0, users[0], false, int128(1000), type(uint128).max);
    assertLt(amount0, 0);
  }

  function test_gateHook_blocksDepositWhenClosed() public {
    GateHook hook = new GateHook();
    _deployPoolWithHook(address(hook), MetricHooks.BEFORE_ADD_LIQUIDITY_FLAG);
    hook.bindPool(address(pool));
    _approveUsersForPool(address(pool));

    hook.setAllowDeposit(false);
    vm.expectRevert(IMetricOmmPoolActions.NotAllowedToDeposit.selector);
    _addLiquidity(0, -5, 4, 10_000, HOOK_TEST_SALT);
  }

  function test_gateHook_removeLiquidityIgnoresDepositGate() public {
    GateHook hook = new GateHook();
    _deployPoolWithHook(address(hook), MetricHooks.BEFORE_ADD_LIQUIDITY_FLAG);
    hook.bindPool(address(pool));
    _approveUsersForPool(address(pool));

    hook.setAllowDeposit(true);
    _addLiquidity(0, -5, 4, 10_000, HOOK_TEST_SALT);

    hook.setAllowDeposit(false);
    _removeLiquidity(0, -5, 4, 10_000, HOOK_TEST_SALT);
  }

  function _deployPoolWithHook(address hooks, uint16 hooksPermissions) internal {
    (BinState[] memory nn, BinState[] memory neg) = _defaultBinStateArrays();
    pool = _deployPoolAndRegister(
      PoolDeployParams({
        priceProvider: address(oracle),
        hooks: hooks,
        hooksPermissions: hooksPermissions,
        immutablePriceProvider: true,
        protocolSpreadFeeE6: PROTOCOL_FEE,
        adminSpreadFeeE6: ADMIN_FEE,
        curBinDistFromProvidedPriceE6: 0,
        nonNegativeBinStates: nn,
        negativeBinStates: neg,
        protocolNotionalFeeE8: 0,
        adminNotionalFeeE8: 0,
        immutablePriceProviderForRegistry: address(oracle),
        lowestBin: -1,
        highestBin: 0
      })
    );
  }

  function _factoryPoolParams(address) internal returns (PoolParameters memory params) {
    params = PoolParameters({
      token0: address(token0),
      token1: address(token1),
      priceProvider: address(oracle),
      hooks: address(0),
      hooksPermissions: 0,
      priceProviderTimelock: type(uint256).max,
      admin: address(this),
      initialAmount0PerShareE18: 1e18,
      initialAmount1PerShareE18: 1e18,
      minimalMintableLiquidity: 1000,
      adminSpreadFeeE6: ADMIN_FEE,
      adminNotionalFeeE8: 0,
      adminFeeDestination: makeAddr("adminFeeDest"),
      curBinDistFromProvidedPriceE6: 0,
      nonNegativeBinDataArray: _createBinDataArray(),
      negativeBinDataArray: _createBinDataArray(),
      salt: keccak256("HOOKS_TEST_SALT")
    });
    oracle.setTokens(params.token0, params.token1);
  }
}
