// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {MetricOmmPoolBaseTest} from "./MetricOmmPool.base.t.sol";
import {MetricOmmPoolFactory} from "../contracts/MetricOmmPoolFactory.sol";
import {MetricOmmPoolDeployer} from "../contracts/MetricOmmPoolDeployer.sol";
import {PoolParameters} from "../contracts/types/FactoryOperation.sol";
import {ExtensionOrders} from "../contracts/types/PoolExtensionsConfig.sol";
import {ValidateExtensionsConfig} from "../contracts/libraries/ValidateExtensionsConfig.sol";
import {ExtensionOrderTestLib} from "./ExtensionOrderTestLib.sol";
import {Slot0Library} from "../contracts/libraries/Slot0Library.sol";
import {PoolSlot0} from "../contracts/types/Slot0.sol";
import {LiquidityDelta} from "../contracts/types/PoolOperation.sol";
import {MockMetricExtension} from "./mocks/MockMetricExtension.sol";
import {GateExtension} from "./mocks/extensions/GateExtension.sol";
import {RevertExtension} from "./mocks/extensions/RevertExtension.sol";
import {BinState} from "../contracts/types/PoolStorage.sol";
import {IMetricOmmPoolActions} from "../contracts/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";

contract MetricOmmPoolExtensionsTest is MetricOmmPoolBaseTest {
  uint72 constant EXTENSION_TEST_SALT = 12345;

  function test_factory_revertsWhenExtensionsEmptyButOrdersSet() public {
    MetricOmmPoolFactory f = new MetricOmmPoolFactory(address(this));
    MetricOmmPoolDeployer d = new MetricOmmPoolDeployer(address(f));
    f.setPoolDeployer(address(d));

    PoolParameters memory params = _factoryPoolParams(address(f));
    (params.extensions, params.extensionInitData) = _emptyExtensionArrays();
    params.extensionOrders = _extensionOrdersWithBeforeSwap();

    vm.expectRevert(ValidateExtensionsConfig.InvalidExtensionsConfig.selector);
    f.createPool(params);
  }

  function test_factory_revertsWhenExtensionsSetButAllOrdersZero() public {
    MetricOmmPoolFactory f = new MetricOmmPoolFactory(address(this));
    MetricOmmPoolDeployer d = new MetricOmmPoolDeployer(address(f));
    f.setPoolDeployer(address(d));

    PoolParameters memory params = _factoryPoolParams(address(f));
    params.extensions = new address[](1);
    params.extensions[0] = makeAddr("extensions");
    params.extensionInitData = new bytes[](1);

    vm.expectRevert(ValidateExtensionsConfig.InvalidExtensionsConfig.selector);
    f.createPool(params);
  }

  function test_factory_revertsWhenDuplicateExtensionAddresses() public {
    MetricOmmPoolFactory f = new MetricOmmPoolFactory(address(this));
    MetricOmmPoolDeployer d = new MetricOmmPoolDeployer(address(f));
    f.setPoolDeployer(address(d));

    MockMetricExtension extension = new MockMetricExtension();
    PoolParameters memory params = _factoryPoolParams(address(f));
    params.extensions = new address[](2);
    params.extensions[0] = address(extension);
    params.extensions[1] = address(extension);
    params.extensionInitData = new bytes[](2);
    params.extensionOrders = _extensionOrdersWithBeforeSwap();

    vm.expectRevert(ValidateExtensionsConfig.InvalidExtensionsConfig.selector);
    f.createPool(params);
  }

  function test_factory_revertsWhenExtensionOrderReferencesMissingExtension() public {
    MetricOmmPoolFactory f = new MetricOmmPoolFactory(address(this));
    MetricOmmPoolDeployer d = new MetricOmmPoolDeployer(address(f));
    f.setPoolDeployer(address(d));

    PoolParameters memory params = _factoryPoolParams(address(f));
    (params.extensions, params.extensionInitData) = _singleExtensionArrays(makeAddr("extensions"));
    ExtensionOrders memory orders;
    orders.beforeSwap = ExtensionOrderTestLib.encodeExtensionOrder(2, 0, 0, 0, 0, 0, 0);
    params.extensionOrders = orders;

    vm.expectRevert(ValidateExtensionsConfig.InvalidExtensionOrder.selector);
    f.createPool(params);
  }

  function test_factory_initializesExtensions() public {
    MetricOmmPoolFactory f = new MetricOmmPoolFactory(address(this));
    MetricOmmPoolDeployer d = new MetricOmmPoolDeployer(address(f));
    f.setPoolDeployer(address(d));

    MockMetricExtension extension = new MockMetricExtension();
    PoolParameters memory params = _factoryPoolParams(address(f));
    (params.extensions, params.extensionInitData) = _singleExtensionArrays(address(extension));
    params.extensionOrders = _extensionOrdersWithBeforeSwap();

    address deployedPool = f.createPool(params);
    assertEq(extension.boundPool(), deployedPool);
  }

  function test_swap_callsOnlyEnabledExtensionFlags() public {
    MockMetricExtension extension = new MockMetricExtension();
    _deployPoolWithExtension(address(extension), _extensionOrdersWithBeforeAndAfterSwap());
    extension.bindPool(address(pool));
    _approveUsersForPool(address(pool));
    _addLiquidity(1, -5, 4, 100000, 0);

    extension.resetCalls();
    _swap(0, users[0], false, int128(1000), type(uint128).max);

    assertTrue(extension.calledBeforeSwap());
    assertTrue(extension.calledAfterSwap());
    assertFalse(extension.calledBeforeAddLiquidity());
    assertGt(extension.lastBidPriceX64(), 0);
    assertGe(extension.lastAskPriceX64(), extension.lastBidPriceX64());
  }

  function test_simulateSwap_beforeSwapRevertBubblesToCaller() public {
    RevertExtension extension = new RevertExtension();
    _deployPoolWithExtension(address(extension), _extensionOrdersWithBeforeSwap());
    extension.bindPool(address(pool));
    _approveUsersForPool(address(pool));
    _addLiquidity(1, -5, 4, 100000, 0);

    vm.expectRevert(RevertExtension.DeliberateExtensionRevert.selector);
    pool.simulateSwapAndRevert(
      users[0], false, int128(1000), type(uint128).max, uint128(2 ** 64), uint128(2 ** 64 + 1), bytes("")
    );
  }

  function test_simulateSwap_afterSwapRevertBubblesToCaller() public {
    RevertExtension extension = new RevertExtension();
    _deployPoolWithExtension(address(extension), _extensionOrdersWithAfterSwap());
    extension.bindPool(address(pool));
    _approveUsersForPool(address(pool));
    _addLiquidity(1, -5, 4, 100000, 0);

    vm.expectRevert(RevertExtension.DeliberateAfterSwapExtensionRevert.selector);
    pool.simulateSwapAndRevert(
      users[0], false, int128(1000), type(uint128).max, uint128(2 ** 64), uint128(2 ** 64 + 1), bytes("")
    );
  }

  function test_simulateSwap_gateExtensionBlocksWhenClosed() public {
    GateExtension extension = new GateExtension();
    _deployPoolWithExtension(address(extension), _extensionOrdersWithBeforeSwap());
    extension.bindPool(address(pool));
    _approveUsersForPool(address(pool));
    _addLiquidity(1, -5, 4, 100000, 0);

    extension.setAllowSwap(false);
    vm.expectRevert(IMetricOmmPoolActions.NotAllowedToSwap.selector);
    pool.simulateSwapAndRevert(
      users[0], false, int128(1000), type(uint128).max, uint128(2 ** 64), uint128(2 ** 64 + 1), bytes("")
    );
  }

  function test_afterSwap_passesPackedSlot0FinalMatchingPool() public {
    MockMetricExtension extension = new MockMetricExtension();
    _deployPoolWithExtension(address(extension), _extensionOrdersWithAfterSwap());
    extension.bindPool(address(pool));
    _approveUsersForPool(address(pool));
    _addLiquidity(1, -5, 4, 100000, 0);

    _swap(0, users[0], false, int128(1000), type(uint128).max);

    assertTrue(extension.calledAfterSwap());
    PoolSlot0 memory fromExtension = Slot0Library.unpack(extension.lastPackedSlot0Final());
    assertEq(fromExtension.curBinIdx, _getCurBinIdx());
    assertEq(fromExtension.curPosInBin, _getCurPosInBin());
  }

  function test_beforeSwap_revertBubblesToCaller() public {
    RevertExtension extension = new RevertExtension();
    _deployPoolWithExtension(address(extension), _extensionOrdersWithBeforeSwap());
    extension.bindPool(address(pool));
    _approveUsersForPool(address(pool));
    _addLiquidity(1, -5, 4, 100000, 0);

    vm.expectRevert(RevertExtension.DeliberateExtensionRevert.selector);
    _swap(0, users[0], false, int128(1000), type(uint128).max);
  }

  function test_gateExtension_blocksSwapWhenClosed() public {
    GateExtension extension = new GateExtension();
    _deployPoolWithExtension(address(extension), _extensionOrdersWithBeforeSwap());
    extension.bindPool(address(pool));
    _approveUsersForPool(address(pool));
    _addLiquidity(1, -5, 4, 100000, 0);

    extension.setAllowSwap(false);
    vm.expectRevert(IMetricOmmPoolActions.NotAllowedToSwap.selector);
    _swap(0, users[0], false, int128(1000), type(uint128).max);
  }

  function test_gateExtension_allowsSwapWhenOpen() public {
    GateExtension extension = new GateExtension();
    _deployPoolWithExtension(address(extension), _extensionOrdersWithBeforeSwap());
    extension.bindPool(address(pool));
    _approveUsersForPool(address(pool));
    _addLiquidity(1, -5, 4, 100000, 0);

    (int256 amount0,) = _swap(0, users[0], false, int128(1000), type(uint128).max);
    assertLt(amount0, 0);
  }

  function test_gateExtension_blocksDepositWhenClosed() public {
    GateExtension extension = new GateExtension();
    _deployPoolWithExtension(address(extension), _extensionOrdersWithBeforeAddLiquidity());
    extension.bindPool(address(pool));
    _approveUsersForPool(address(pool));

    extension.setAllowDeposit(false);
    vm.expectRevert(IMetricOmmPoolActions.NotAllowedToDeposit.selector);
    _addLiquidity(0, -5, 4, 10_000, EXTENSION_TEST_SALT);
  }

  function test_gateExtension_removeLiquidityIgnoresDepositGate() public {
    GateExtension extension = new GateExtension();
    _deployPoolWithExtension(address(extension), _extensionOrdersWithBeforeAddLiquidity());
    extension.bindPool(address(pool));
    _approveUsersForPool(address(pool));

    extension.setAllowDeposit(true);
    _addLiquidity(0, -5, 4, 10_000, EXTENSION_TEST_SALT);

    extension.setAllowDeposit(false);
    _removeLiquidity(0, -5, 4, 10_000, EXTENSION_TEST_SALT);
  }

  function test_addLiquidity_lengthMismatch_doesNotCallBeforeExtension() public {
    MockMetricExtension extension = new MockMetricExtension();
    _deployPoolWithExtension(address(extension), _extensionOrdersWithBeforeAddLiquidity());
    extension.bindPool(address(pool));

    int256[] memory binIdxs = new int256[](1);
    binIdxs[0] = 0;
    uint256[] memory shares = new uint256[](2);
    shares[0] = 1000;
    shares[1] = 1000;
    LiquidityDelta memory deltas = LiquidityDelta({binIdxs: binIdxs, shares: shares});

    vm.expectRevert(IMetricOmmPoolActions.LiquidityDeltaLengthMismatch.selector);
    pool.addLiquidity(users[0], EXTENSION_TEST_SALT, deltas, "", "");
    assertFalse(extension.calledBeforeAddLiquidity());
  }

  function test_removeLiquidity_lengthMismatch_doesNotCallBeforeExtension() public {
    MockMetricExtension extension = new MockMetricExtension();
    ExtensionOrders memory orders;
    orders.beforeRemoveLiquidity = ExtensionOrderTestLib.encodeExtensionOrder(1, 0, 0, 0, 0, 0, 0);
    _deployPoolWithExtension(address(extension), orders);
    extension.bindPool(address(pool));

    int256[] memory binIdxs = new int256[](1);
    binIdxs[0] = 0;
    uint256[] memory shares = new uint256[](2);
    shares[0] = 1000;
    shares[1] = 1000;
    LiquidityDelta memory deltas = LiquidityDelta({binIdxs: binIdxs, shares: shares});

    vm.expectRevert(IMetricOmmPoolActions.LiquidityDeltaLengthMismatch.selector);
    pool.removeLiquidity(users[0], EXTENSION_TEST_SALT, deltas, "");
    assertFalse(extension.calledBeforeRemoveLiquidity());
  }

  function test_removeLiquidity_notOwner_doesNotCallBeforeExtension() public {
    MockMetricExtension extension = new MockMetricExtension();
    ExtensionOrders memory orders;
    orders.beforeRemoveLiquidity = ExtensionOrderTestLib.encodeExtensionOrder(1, 0, 0, 0, 0, 0, 0);
    _deployPoolWithExtension(address(extension), orders);
    extension.bindPool(address(pool));
    _approveUsersForPool(address(pool));
    _addLiquidity(0, -5, 4, 10_000, EXTENSION_TEST_SALT);

    LiquidityDelta memory deltas = _rangeDeltas(-5, 4, 10_000);

    vm.prank(users[1]);
    vm.expectRevert(IMetricOmmPoolActions.NotPositionOwner.selector);
    pool.removeLiquidity(users[0], EXTENSION_TEST_SALT, deltas, "");
    assertFalse(extension.calledBeforeRemoveLiquidity());
  }

  function _deployPoolWithExtension(address extension, ExtensionOrders memory orders) internal {
    (BinState[] memory nn, BinState[] memory neg) = _defaultBinStateArrays();
    pool = _deployPoolAndRegister(
      PoolDeployParams({
        priceProvider: address(oracle),
        extensions: _singleExtensionPoolExtensions(extension),
        extensionOrders: orders,
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
    (address[] memory extensions, bytes[] memory extensionInitData) = _emptyExtensionArrays();
    params = PoolParameters({
      token0: address(token0),
      token1: address(token1),
      priceProvider: address(oracle),
      extensions: extensions,
      extensionOrders: _emptyExtensionOrders(),
      extensionInitData: extensionInitData,
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
      salt: keccak256("EXTENSIONS_TEST_SALT")
    });
    oracle.setTokens(params.token0, params.token1);
  }
}
