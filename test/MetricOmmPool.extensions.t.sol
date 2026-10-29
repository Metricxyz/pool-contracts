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
import {IMetricOmmExtensions} from "../contracts/interfaces/extensions/IMetricOmmExtensions.sol";

contract MetricOmmPoolExtensionsTest is MetricOmmPoolBaseTest {
  uint72 constant EXTENSION_TEST_SALT = 12345;

  function test_factory_revertsWhenExtensionsEmptyButOrdersSet() public {
    MetricOmmPoolFactory f = new MetricOmmPoolFactory(address(this), address(this), 0, 0, type(uint16).max);
    MetricOmmPoolDeployer d = new MetricOmmPoolDeployer(address(f));
    f.setPoolDeployer(address(d));

    PoolParameters memory params = _factoryPoolParams(address(f));
    (params.extensions, params.extensionInitData) = _emptyExtensionArrays();
    params.extensionOrders = _extensionOrdersWithBeforeSwap();

    vm.expectRevert(ValidateExtensionsConfig.InvalidExtensionsConfig.selector);
    f.createPool(params);
  }

  function test_factory_revertsWhenExtensionsSetButAllOrdersZero() public {
    MetricOmmPoolFactory f = new MetricOmmPoolFactory(address(this), address(this), 0, 0, type(uint16).max);
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
    MetricOmmPoolFactory f = new MetricOmmPoolFactory(address(this), address(this), 0, 0, type(uint16).max);
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
    MetricOmmPoolFactory f = new MetricOmmPoolFactory(address(this), address(this), 0, 0, type(uint16).max);
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
    MetricOmmPoolFactory f = new MetricOmmPoolFactory(address(this), address(this), 0, 0, type(uint16).max);
    MetricOmmPoolDeployer d = new MetricOmmPoolDeployer(address(f));
    f.setPoolDeployer(address(d));

    MockMetricExtension extension = new MockMetricExtension();
    PoolParameters memory params = _factoryPoolParams(address(f));
    (params.extensions, params.extensionInitData) = _singleExtensionArrays(address(extension));
    params.extensionOrders = _extensionOrdersWithBeforeSwap();

    address deployedPool = f.createPool(params);
    assertEq(extension.boundPool(), deployedPool);
  }

  /// @notice Same CREATE2 salt + different extensionInitData must yield different pool addresses
  ///         (init calldata is applied post-deploy and must still bind into the address).
  function test_factory_extensionInitDataAffectsPoolAddress() public {
    MetricOmmPoolFactory f = new MetricOmmPoolFactory(address(this), address(this), 0, 0, type(uint16).max);
    MetricOmmPoolDeployer d = new MetricOmmPoolDeployer(address(f));
    f.setPoolDeployer(address(d));

    MultiPoolInitExtension extension = new MultiPoolInitExtension();
    bytes32 sharedSalt = keccak256("SAME_SALT");

    PoolParameters memory paramsA = _factoryPoolParams(address(f));
    paramsA.extensions = new address[](1);
    paramsA.extensions[0] = address(extension);
    paramsA.extensionInitData = new bytes[](1);
    paramsA.extensionInitData[0] = hex"01";
    paramsA.extensionOrders = _extensionOrdersWithBeforeSwap();
    paramsA.salt = sharedSalt;

    PoolParameters memory paramsB = _factoryPoolParams(address(f));
    paramsB.extensions = new address[](1);
    paramsB.extensions[0] = address(extension);
    paramsB.extensionInitData = new bytes[](1);
    paramsB.extensionInitData[0] = hex"02";
    paramsB.extensionOrders = _extensionOrdersWithBeforeSwap();
    paramsB.salt = sharedSalt;

    address poolA = f.createPool(paramsA);
    address poolB = f.createPool(paramsB);

    assertTrue(poolA != poolB, "extensionInitData must affect CREATE2 address");
    assertEq(extension.initHash(poolA), keccak256(hex"01"));
    assertEq(extension.initHash(poolB), keccak256(hex"02"));
  }

  /// @notice Same CREATE2 salt + different admin/adminFeeDestination must yield different pool addresses.
  function test_factory_adminIdentityAffectsPoolAddress() public {
    MetricOmmPoolFactory f = new MetricOmmPoolFactory(address(this), address(this), 0, 0, type(uint16).max);
    MetricOmmPoolDeployer d = new MetricOmmPoolDeployer(address(f));
    f.setPoolDeployer(address(d));

    bytes32 sharedSalt = keccak256("SAME_SALT_ADMIN");

    PoolParameters memory paramsA = _factoryPoolParams(address(f));
    paramsA.salt = sharedSalt;
    paramsA.admin = makeAddr("adminA");
    paramsA.adminFeeDestination = makeAddr("feeDestA");

    PoolParameters memory paramsB = _factoryPoolParams(address(f));
    paramsB.salt = sharedSalt;
    paramsB.admin = makeAddr("adminB");
    paramsB.adminFeeDestination = makeAddr("feeDestB");

    address poolA = f.createPool(paramsA);
    address poolB = f.createPool(paramsB);

    assertTrue(poolA != poolB, "admin identity must affect CREATE2 address");
    assertEq(f.poolAdmin(poolA), paramsA.admin);
    assertEq(f.poolAdmin(poolB), paramsB.admin);
  }

  /// @notice Same CREATE2 salt + identical constructor immutables but different oracle timelocks must yield
  ///         different pool addresses (the timelock is never a pool constructor arg, only factory storage).
  function test_factory_priceProviderTimelockAffectsPoolAddress() public {
    MetricOmmPoolFactory f = new MetricOmmPoolFactory(address(this), address(this), 0, 0, type(uint16).max);
    MetricOmmPoolDeployer d = new MetricOmmPoolDeployer(address(f));
    f.setPoolDeployer(address(d));

    bytes32 sharedSalt = keccak256("SAME_SALT_TIMELOCK");

    PoolParameters memory paramsA = _factoryPoolParams(address(f));
    paramsA.salt = sharedSalt;
    paramsA.priceProviderTimelock = 0;

    PoolParameters memory paramsB = _factoryPoolParams(address(f));
    paramsB.salt = sharedSalt;
    paramsB.priceProviderTimelock = 7 days;

    address poolA = f.createPool(paramsA);
    address poolB = f.createPool(paramsB);

    assertTrue(poolA != poolB, "oracle timelock must affect CREATE2 address");
    assertEq(f.priceProviderTimelock(poolA), 0);
    assertEq(f.priceProviderTimelock(poolB), 7 days);
  }

  /// @notice Same CREATE2 salt + identical fee totals but different protocol/admin splits must yield different
  ///         pool addresses (only the summed spread/notional fee reaches the pool constructor).
  function test_factory_feeSplitAffectsPoolAddressEvenWhenTotalsMatch() public {
    MetricOmmPoolFactory f = new MetricOmmPoolFactory(address(this), address(this), 0, 0, type(uint16).max);
    MetricOmmPoolDeployer d = new MetricOmmPoolDeployer(address(f));
    f.setPoolDeployer(address(d));

    bytes32 sharedSalt = keccak256("SAME_SALT_FEESPLIT");

    PoolParameters memory paramsA = _factoryPoolParams(address(f));
    paramsA.salt = sharedSalt;
    paramsA.protocolSpreadFeeE6 = 1000;
    paramsA.adminSpreadFeeE6 = 4000;

    PoolParameters memory paramsB = _factoryPoolParams(address(f));
    paramsB.salt = sharedSalt;
    paramsB.protocolSpreadFeeE6 = 2000;
    paramsB.adminSpreadFeeE6 = 3000;

    address poolA = f.createPool(paramsA);
    address poolB = f.createPool(paramsB);

    assertTrue(poolA != poolB, "protocol/admin fee split must affect CREATE2 address even when totals match");
  }

  function test_swap_callsOnlyEnabledExtensionFlags() public {
    MockMetricExtension extension = new MockMetricExtension();
    _deployPoolWithExtension(address(extension), _extensionOrdersWithBeforeAndAfterSwap());
    extension.bindPool(address(pool));
    _approveUsersForPool(address(pool));
    _addLiquidity(1, -5, 4, 10_000_000, 0);

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
    _addLiquidity(1, -5, 4, 10_000_000, 0);

    vm.expectRevert(RevertExtension.DeliberateExtensionRevert.selector);
    pool.simulateSwapAndRevert(
      address(this),
      users[0],
      false,
      int128(1000),
      type(uint128).max,
      uint128(2 ** 64),
      uint128(2 ** 64 + 1),
      uint128(2 ** 64),
      bytes("")
    );
  }

  function test_simulateSwap_afterSwapRevertBubblesToCaller() public {
    RevertExtension extension = new RevertExtension();
    _deployPoolWithExtension(address(extension), _extensionOrdersWithAfterSwap());
    extension.bindPool(address(pool));
    _approveUsersForPool(address(pool));
    _addLiquidity(1, -5, 4, 10_000_000, 0);

    vm.expectRevert(RevertExtension.DeliberateAfterSwapExtensionRevert.selector);
    pool.simulateSwapAndRevert(
      address(this),
      users[0],
      false,
      int128(1000),
      type(uint128).max,
      uint128(2 ** 64),
      uint128(2 ** 64 + 1),
      uint128(2 ** 64),
      bytes("")
    );
  }

  function test_simulateSwap_gateExtensionBlocksWhenClosed() public {
    GateExtension extension = new GateExtension();
    _deployPoolWithExtension(address(extension), _extensionOrdersWithBeforeSwap());
    extension.bindPool(address(pool));
    _approveUsersForPool(address(pool));
    _addLiquidity(1, -5, 4, 10_000_000, 0);

    extension.setAllowSwap(false);
    vm.expectRevert(IMetricOmmPoolActions.NotAllowedToSwap.selector);
    pool.simulateSwapAndRevert(
      address(this),
      users[0],
      false,
      int128(1000),
      type(uint128).max,
      uint128(2 ** 64),
      uint128(2 ** 64 + 1),
      uint128(2 ** 64),
      bytes("")
    );
  }

  function test_afterSwap_passesPackedSlot0FinalMatchingPool() public {
    MockMetricExtension extension = new MockMetricExtension();
    _deployPoolWithExtension(address(extension), _extensionOrdersWithAfterSwap());
    extension.bindPool(address(pool));
    _approveUsersForPool(address(pool));
    _addLiquidity(1, -5, 4, 10_000_000, 0);

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
    _addLiquidity(1, -5, 4, 10_000_000, 0);

    vm.expectRevert(RevertExtension.DeliberateExtensionRevert.selector);
    _swap(0, users[0], false, int128(1000), type(uint128).max);
  }

  function test_gateExtension_blocksSwapWhenClosed() public {
    GateExtension extension = new GateExtension();
    _deployPoolWithExtension(address(extension), _extensionOrdersWithBeforeSwap());
    extension.bindPool(address(pool));
    _approveUsersForPool(address(pool));
    _addLiquidity(1, -5, 4, 10_000_000, 0);

    extension.setAllowSwap(false);
    vm.expectRevert(IMetricOmmPoolActions.NotAllowedToSwap.selector);
    _swap(0, users[0], false, int128(1000), type(uint128).max);
  }

  function test_gateExtension_allowsSwapWhenOpen() public {
    GateExtension extension = new GateExtension();
    _deployPoolWithExtension(address(extension), _extensionOrdersWithBeforeSwap());
    extension.bindPool(address(pool));
    _approveUsersForPool(address(pool));
    _addLiquidity(1, -5, 4, 10_000_000, 0);

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
    _addLiquidity(0, -5, 4, 10000000, EXTENSION_TEST_SALT);
  }

  function test_gateExtension_removeLiquidityIgnoresDepositGate() public {
    GateExtension extension = new GateExtension();
    _deployPoolWithExtension(address(extension), _extensionOrdersWithBeforeAddLiquidity());
    extension.bindPool(address(pool));
    _approveUsersForPool(address(pool));

    extension.setAllowDeposit(true);
    _addLiquidity(0, -5, 4, 10000000, EXTENSION_TEST_SALT);

    extension.setAllowDeposit(false);
    _removeLiquidity(0, -5, 4, 10_000_000, EXTENSION_TEST_SALT);
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
    _addLiquidity(0, -5, 4, 10000000, EXTENSION_TEST_SALT);

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
      initialScaledAmount0PerE18Shares: 1e18,
      initialScaledAmount1PerE18Shares: 1e18,
      minimalOperationalLiquidity: 1e6,
      protocolSpreadFeeE6: 0,
      adminSpreadFeeE6: ADMIN_FEE,
      protocolNotionalFeeE8: 0,
      adminNotionalFeeE8: 0,
      adminFeeDestination: makeAddr("adminFeeDest"),
      curBinDistFromProvidedPriceE6: 0,
      nonNegativeBinDataArray: _createBinDataArray(),
      negativeBinDataArray: _createBinDataArray(),
      salt: keccak256("EXTENSIONS_TEST_SALT"),
      bidAskRefAsymmetryX8: type(uint16).max
    });
    oracle.setTokens(params.token0, params.token1);
  }
}

/// @dev Multi-pool extension proving CREATE2 uniqueness from extensionInitData alone.
contract MultiPoolInitExtension is IMetricOmmExtensions {
  mapping(address => bytes32) public initHash;

  function initialize(address pool, bytes calldata data) external returns (bytes4) {
    initHash[pool] = keccak256(data);
    return IMetricOmmExtensions.initialize.selector;
  }

  function beforeAddLiquidity(address, address, uint80, LiquidityDelta calldata, bytes calldata)
    external
    pure
    returns (bytes4)
  {
    return IMetricOmmExtensions.beforeAddLiquidity.selector;
  }

  function afterAddLiquidity(address, address, uint80, LiquidityDelta calldata, uint256, uint256, bytes calldata)
    external
    pure
    returns (bytes4)
  {
    return IMetricOmmExtensions.afterAddLiquidity.selector;
  }

  function beforeRemoveLiquidity(address, address, uint80, LiquidityDelta calldata, bytes calldata)
    external
    pure
    returns (bytes4)
  {
    return IMetricOmmExtensions.beforeRemoveLiquidity.selector;
  }

  function afterRemoveLiquidity(address, address, uint80, LiquidityDelta calldata, uint256, uint256, bytes calldata)
    external
    pure
    returns (bytes4)
  {
    return IMetricOmmExtensions.afterRemoveLiquidity.selector;
  }

  function beforeSwap(address, address, bool, int128, uint128, uint256, uint128, uint128, uint128, bytes calldata)
    external
    pure
    returns (bytes4)
  {
    return IMetricOmmExtensions.beforeSwap.selector;
  }

  function afterSwap(
    address,
    address,
    bool,
    int128,
    uint128,
    uint256,
    uint256,
    uint128,
    uint128,
    uint128,
    int128,
    int128,
    uint256,
    bytes calldata
  ) external pure returns (bytes4) {
    return IMetricOmmExtensions.afterSwap.selector;
  }
}
