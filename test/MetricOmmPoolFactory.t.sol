// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {MetricOmmPoolFactory} from "../contracts/MetricOmmPoolFactory.sol";
import {IMetricOmmPoolFactory} from "../contracts/interfaces/IMetricOmmPoolFactory/IMetricOmmPoolFactory.sol";
import {IMetricOmmPoolFactoryOwner} from "../contracts/interfaces/IMetricOmmPoolFactory/IMetricOmmPoolFactoryOwner.sol";
import {
  IMetricOmmPoolFactoryPoolAdmin
} from "../contracts/interfaces/IMetricOmmPoolFactory/IMetricOmmPoolFactoryPoolAdmin.sol";
import {IMetricOmmPoolFactoryActions} from "../contracts/interfaces/IMetricOmmPool/IMetricOmmPoolFactoryActions.sol";
import {PoolParameters} from "../contracts/types/FactoryOperation.sol";
import {ExtensionOrders} from "../contracts/types/PoolExtensionsConfig.sol";
import {IMetricOmmPoolActions} from "../contracts/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {MetricOmmPoolDeployer} from "../contracts/MetricOmmPoolDeployer.sol";
import {PoolStateLibrary} from "../contracts/libraries/PoolStateLibrary.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockOracle} from "./mocks/MockOracle.sol";

contract MetricOmmPoolFactoryTest is Test {
  MetricOmmPoolFactory internal factory;
  MetricOmmPoolDeployer internal deployer;

  MockERC20 internal token0;
  MockERC20 internal token1;
  MockOracle internal oracle;

  address internal admin;
  address internal adminFeeDestination;
  address internal nonOwner;

  uint24 internal constant INITIAL_PROTOCOL_FEE_E6 = 10_000; // 1%
  uint24 internal constant ADMIN_FEE_E6 = 5_000; // 0.5%

  function setUp() public {
    admin = makeAddr("admin");
    adminFeeDestination = makeAddr("adminFeeDestination");
    nonOwner = makeAddr("nonOwner");

    token0 = new MockERC20("Token0", "TK0", 18);
    token1 = new MockERC20("Token1", "TK1", 18);
    oracle = new MockOracle();
    oracle.setBidAndAskPrice(uint128(2 ** 64), uint128(2 ** 64 + 1));

    factory = new MetricOmmPoolFactory(address(this));
    factory.setDefaultSpreadProtocolFeeE6(INITIAL_PROTOCOL_FEE_E6);
    deployer = new MetricOmmPoolDeployer(address(factory));
    factory.setPoolDeployer(address(deployer));
  }

  function test_setPoolProtocolFee_updatesPoolFee() public {
    address pool = _createPool();

    uint24 newProtocolFeeE6 = 12_345;
    factory.setPoolProtocolFee(pool, newProtocolFeeE6, 0);

    (uint24 protocolSpreadFeeE6,,,) = factory.poolFeeConfig(pool);
    assertEq(protocolSpreadFeeE6, newProtocolFeeE6, "protocol spread fee should be updated via factory");
  }

  function test_setPoolProtocolFee_onlyOwner() public {
    address pool = _createPool();

    vm.prank(nonOwner);
    vm.expectRevert();
    factory.setPoolProtocolFee(pool, 12_345, 0);
  }

  function test_setPoolProtocolFee_revertsWhenFeeTooHigh() public {
    address pool = _createPool();

    vm.expectRevert(IMetricOmmPoolFactory.ProtocolFeeTooHigh.selector);
    factory.setPoolProtocolFee(pool, 300_000, 0);
  }

  function test_getFeeCaps_returnsInitialValues() public view {
    (uint24 p, uint24 a, uint24 pn, uint24 an) = factory.getFeeCaps();
    assertEq(p, 200_000);
    assertEq(a, 200_000);
    assertEq(pn, 1_000_000);
    assertEq(an, 1_000_000);
  }

  function test_setFeeCaps_onlyOwner() public {
    vm.prank(nonOwner);
    vm.expectRevert();
    factory.setFeeCaps(1, 2, 3, 4);
  }

  function test_setFeeCaps_revertsWhenSpreadCapExceedsHardLimit() public {
    vm.expectRevert(IMetricOmmPoolFactoryOwner.FeeCapsExceedHardLimit.selector);
    factory.setFeeCaps(200_001, 200_000, 1_000_000, 1_000_000);
  }

  function test_setFeeCaps_revertsWhenNotionalCapExceedsHardLimit() public {
    vm.expectRevert(IMetricOmmPoolFactoryOwner.FeeCapsExceedHardLimit.selector);
    factory.setFeeCaps(200_000, 200_000, 1_000_001, 1_000_000);
  }

  function test_setPoolProtocolFee_clampsAdminSpreadWhenAboveCap() public {
    address pool = _createPool();
    vm.prank(admin);
    factory.setPoolAdminFees(pool, 150_000, 0);

    factory.setFeeCaps(200_000, 100_000, 1_000_000, 1_000_000);

    factory.setPoolProtocolFee(pool, 10_000, 0);

    (, uint24 adminSpreadFee,,) = factory.poolFeeConfig(pool);
    assertEq(adminSpreadFee, 100_000);
  }

  function test_setPoolProtocolFee_clampsAdminNotionalWhenAboveCap() public {
    address pool = _createPool();
    vm.prank(admin);
    factory.setPoolAdminFees(pool, 0, 900_000);

    factory.setFeeCaps(200_000, 200_000, 1_000_000, 400_000);

    factory.setPoolProtocolFee(pool, INITIAL_PROTOCOL_FEE_E6, 0);

    (,,, uint24 adminNotionalFeeE8) = factory.poolFeeConfig(pool);
    assertEq(adminNotionalFeeE8, 400_000);
  }

  function test_setPoolProtocolFee_revertsWhenProtocolNotionalAboveCap() public {
    address pool = _createPool();
    factory.setFeeCaps(200_000, 200_000, 1_000_000, 1_000_000);

    vm.expectRevert(IMetricOmmPoolFactory.ProtocolFeeTooHigh.selector);
    factory.setPoolProtocolFee(pool, 10_000, 2_000_000);
  }

  function test_createPool_usesFactoryDefaultProtocolNotionalFee() public {
    MetricOmmPoolFactory f = new MetricOmmPoolFactory(address(this));
    f.setDefaultSpreadProtocolFeeE6(INITIAL_PROTOCOL_FEE_E6);
    f.setDefaultProtocolNotionalFeeE8(50_000);
    MetricOmmPoolDeployer d = new MetricOmmPoolDeployer(address(f));
    f.setPoolDeployer(address(d));

    PoolParameters memory params = _defaultPoolParams();
    address pool = f.createPool(params);
    assertEq(_notionalFeeE8(pool), 50_000);
    (,, uint24 pNotional,) = f.poolFeeConfig(pool);
    assertEq(pNotional, 50_000);
  }

  function test_setDefaultSpreadProtocolFeeE6_revertsWhenFeeTooHigh() public {
    vm.expectRevert(IMetricOmmPoolFactory.ProtocolFeeTooHigh.selector);
    factory.setDefaultSpreadProtocolFeeE6(200_001);
  }

  function test_setDefaultProtocolNotionalFeeE8_revertsWhenFeeTooHigh() public {
    vm.expectRevert(IMetricOmmPoolFactory.ProtocolFeeTooHigh.selector);
    factory.setDefaultProtocolNotionalFeeE8(1_000_001);
  }

  function test_createPool_revertsWhenAdminNotionalFeeTooHigh() public {
    PoolParameters memory params = _defaultPoolParams();
    params.adminNotionalFeeE8 = 1_000_001;

    vm.expectRevert(IMetricOmmPoolFactory.AdminFeeTooHigh.selector);
    factory.createPool(params);
  }

  function test_createPool_wiresAdminNotionalFeeFromParams() public {
    PoolParameters memory params = _defaultPoolParams();
    params.adminNotionalFeeE8 = 25_000;

    address pool = factory.createPool(params);
    assertEq(_notionalFeeE8(pool), 25_000);
    (,, uint24 pNotional, uint24 aNotional) = factory.poolFeeConfig(pool);
    assertEq(pNotional, 0);
    assertEq(aNotional, 25_000);
  }

  function test_createPool_revertsWhenCurrentDistanceOutOfRange() public {
    PoolParameters memory params = _defaultPoolParams();
    params.curBinDistFromProvidedPriceE6 = 1_000_000;

    vm.expectRevert(
      abi.encodeWithSelector(IMetricOmmPoolFactory.BinDistanceOutOfRange.selector, int8(0), int64(1_000_000))
    );
    factory.createPool(params);
  }

  function test_createPool_revertsWhenPositiveBinsExceedDistanceDomain() public {
    PoolParameters memory params = _defaultPoolParams();
    params.curBinDistFromProvidedPriceE6 = 999_950;
    params.nonNegativeBinDataArray = _singleBinDataArrayWithLength(100);

    vm.expectRevert(
      abi.encodeWithSelector(IMetricOmmPoolFactory.BinDistanceOutOfRange.selector, int8(0), int64(1_000_050))
    );
    factory.createPool(params);
  }

  function test_createPool_revertsWhenNegativeBinsExceedDistanceDomain() public {
    PoolParameters memory params = _defaultPoolParams();
    params.curBinDistFromProvidedPriceE6 = -999_950;
    params.negativeBinDataArray = _singleBinDataArrayWithLength(100);

    vm.expectRevert(
      abi.encodeWithSelector(IMetricOmmPoolFactory.BinDistanceOutOfRange.selector, int8(-1), int64(-1_000_050))
    );
    factory.createPool(params);
  }

  function test_createPool_revertsWhenNonNegativeBinsEmpty() public {
    PoolParameters memory params = _defaultPoolParams();
    params.nonNegativeBinDataArray = new uint256[](0);

    vm.expectRevert(IMetricOmmPoolFactory.BinArraysEmpty.selector);
    factory.createPool(params);
  }

  function test_createPool_revertsWhenInitialScaledAmountExceedsUint128() public {
    PoolParameters memory params = _defaultPoolParams();
    params.initialAmount0PerShareE18 = uint256(type(uint128).max);

    vm.expectRevert(
      abi.encodeWithSelector(
        IMetricOmmPoolFactory.InitialScaledAmountExceedsUint128.selector, uint256(type(uint128).max), uint256(1e18)
      )
    );
    factory.createPool(params);
  }

  function _defaultPoolParams() internal returns (PoolParameters memory params) {
    address orderedToken0 = address(token0) < address(token1) ? address(token0) : address(token1);
    address orderedToken1 = address(token0) < address(token1) ? address(token1) : address(token0);
    oracle.setTokens(orderedToken0, orderedToken1);
    params = PoolParameters({
      token0: orderedToken0,
      token1: orderedToken1,
      priceProvider: address(oracle),
      extensions: new address[](0),
      extensionOrders: ExtensionOrders({
        beforeAddLiquidity: 0,
        afterAddLiquidity: 0,
        beforeRemoveLiquidity: 0,
        afterRemoveLiquidity: 0,
        beforeSwap: 0,
        afterSwap: 0
      }),
      extensionInitData: new bytes[](0),
      priceProviderTimelock: type(uint256).max,
      admin: admin,
      initialAmount0PerShareE18: uint104(1e18),
      initialAmount1PerShareE18: uint104(1e18),
      minimalMintableLiquidity: uint104(1000),
      adminSpreadFeeE6: ADMIN_FEE_E6,
      adminNotionalFeeE8: 0,
      adminFeeDestination: adminFeeDestination,
      curBinDistFromProvidedPriceE6: int24(0),
      nonNegativeBinDataArray: _singleBinDataArray(),
      negativeBinDataArray: _singleBinDataArray(),
      salt: keccak256("POOL_SALT")
    });
  }

  function _createPool() internal returns (address) {
    PoolParameters memory params = _defaultPoolParams();
    return factory.createPool(params);
  }

  function _singleBinDataArray() internal pure returns (uint256[] memory binDataArray) {
    return _singleBinDataArrayWithLength(100);
  }

  function _singleBinDataArrayWithLength(uint16 lengthE6) internal pure returns (uint256[] memory binDataArray) {
    binDataArray = new uint256[](1);
    uint16 buyFee = 0;
    uint16 sellFee = 0;
    uint48 binData = uint48(lengthE6) | (uint48(buyFee) << 16) | (uint48(sellFee) << 32);
    binDataArray[0] = uint256(binData);
  }

  function test_nextPoolIdx_startsAtOne() public view {
    assertEq(factory.nextPoolIdx(), 1);
  }

  function test_createPool_assignsSequentialPoolIdx() public {
    assertEq(factory.nextPoolIdx(), 1);

    address pool0 = _createPool();
    assertEq(factory.poolToIdx(pool0), 1);
    assertEq(factory.idxToPool(1), pool0);
    assertEq(factory.nextPoolIdx(), 2);

    PoolParameters memory params = _defaultPoolParams();
    params.salt = keccak256("POOL_SALT_2");
    address pool1 = factory.createPool(params);
    assertEq(factory.poolToIdx(pool1), 2);
    assertEq(factory.idxToPool(2), pool1);
    assertEq(factory.nextPoolIdx(), 3);
  }

  function test_poolToIdx_returnsZeroForUnknownPool() public view {
    assertEq(factory.poolToIdx(address(0xdead)), 0);
    assertEq(factory.idxToPool(0), address(0));
  }

  function test_isPool() public {
    assertFalse(factory.isPool(address(0xdead)));

    address pool0 = _createPool();
    assertTrue(factory.isPool(pool0));

    PoolParameters memory params = _defaultPoolParams();
    params.salt = keccak256("POOL_SALT_IS_POOL");
    address pool1 = factory.createPool(params);
    assertTrue(factory.isPool(pool1));
    assertFalse(factory.isPool(address(factory)));
  }

  function test_pausePool_adminUnpause_respectsProtocolLayering() public {
    address pool = _createPool();
    assertEq(_pauseLevel(pool), 0);

    vm.prank(admin);
    factory.pausePool(pool);
    assertEq(_pauseLevel(pool), 1);

    factory.protocolPausePool(pool);
    assertEq(_pauseLevel(pool), 2);

    vm.prank(admin);
    vm.expectRevert(abi.encodeWithSelector(IMetricOmmPoolFactory.InvalidPauseTransition.selector, uint8(2), uint8(0)));
    factory.unpausePool(pool);

    factory.protocolUnpausePool(pool);
    assertEq(_pauseLevel(pool), 1);

    vm.prank(admin);
    factory.unpausePool(pool);
    assertEq(_pauseLevel(pool), 0);
  }

  function test_protocolPausePool_fromZero_skipsAdminLevel() public {
    address pool = _createPool();
    factory.protocolPausePool(pool);
    assertEq(_pauseLevel(pool), 2);

    factory.protocolUnpausePool(pool);
    assertEq(_pauseLevel(pool), 1);

    vm.prank(admin);
    factory.unpausePool(pool);
    assertEq(_pauseLevel(pool), 0);
  }

  function test_protocolPausePool_revertsWhenAlreadyProtocolPaused() public {
    address pool = _createPool();
    factory.protocolPausePool(pool);
    vm.expectRevert(abi.encodeWithSelector(IMetricOmmPoolFactory.InvalidPauseTransition.selector, uint8(2), uint8(2)));
    factory.protocolPausePool(pool);
  }

  function test_protocolUnpausePool_revertsWhenNotProtocolPaused() public {
    address pool = _createPool();
    vm.expectRevert(abi.encodeWithSelector(IMetricOmmPoolFactory.InvalidPauseTransition.selector, uint8(0), uint8(1)));
    factory.protocolUnpausePool(pool);
  }

  function test_pausePool_revertsWhenNotUnpaused() public {
    address pool = _createPool();
    vm.prank(admin);
    factory.pausePool(pool);
    vm.prank(admin);
    vm.expectRevert(abi.encodeWithSelector(IMetricOmmPoolFactory.InvalidPauseTransition.selector, uint8(1), uint8(1)));
    factory.pausePool(pool);
  }

  function test_setPoolBinAdditionalFees_updatesStorage_emitsEvent() public {
    address pool = _createPool();
    (,,, uint16 buy0Before, uint16 sell0Before) = PoolStateLibrary._binState(pool, 0);
    assertEq(buy0Before, 0);
    assertEq(sell0Before, 0);

    vm.expectEmit(true, false, false, true, pool);
    emit IMetricOmmPoolFactoryActions.BinAdditionalFeesUpdated(int8(0), uint16(500), uint16(700));

    vm.prank(admin);
    factory.setPoolBinAdditionalFees(pool, 0, 500, 700);

    (,,, uint16 buy0After, uint16 sell0After) = PoolStateLibrary._binState(pool, 0);
    assertEq(buy0After, 500);
    assertEq(sell0After, 700);

    (,,, uint16 buyNeg, uint16 sellNeg) = PoolStateLibrary._binState(pool, -1);
    assertEq(buyNeg, 0);
    assertEq(sellNeg, 0);

    vm.prank(admin);
    factory.setPoolBinAdditionalFees(pool, -1, 10, 20);
    (,,, buyNeg, sellNeg) = PoolStateLibrary._binState(pool, -1);
    assertEq(buyNeg, 10);
    assertEq(sellNeg, 20);
  }

  function test_setPoolBinAdditionalFees_onlyPoolAdmin() public {
    address pool = _createPool();
    vm.prank(nonOwner);
    vm.expectRevert(IMetricOmmPoolFactoryPoolAdmin.NotPoolAdmin.selector);
    factory.setPoolBinAdditionalFees(pool, 0, 1, 1);
  }

  function test_setPoolBinAdditionalFees_revertsWhenBinOutOfRange() public {
    address pool = _createPool();
    vm.prank(admin);
    vm.expectRevert(abi.encodeWithSelector(IMetricOmmPoolActions.InvalidBinIndex.selector, int8(3)));
    factory.setPoolBinAdditionalFees(pool, 3, 1, 1);
  }

  function test_setBinAdditionalFees_revertsWhenNotFactory() public {
    address pool = _createPool();
    vm.expectRevert(IMetricOmmPoolFactoryActions.OnlyFactory.selector);
    IMetricOmmPoolFactoryActions(pool).setBinAdditionalFees(0, 1, 1);
  }

  function test_proposePoolAdminTransfer_onlyCurrentAdmin() public {
    address pool = _createPool();
    address newAdmin = makeAddr("newAdmin");

    vm.prank(nonOwner);
    vm.expectRevert(IMetricOmmPoolFactoryPoolAdmin.NotPoolAdmin.selector);
    factory.proposePoolAdminTransfer(pool, newAdmin);
  }

  function test_acceptPoolAdmin_revertsWhenNoPending() public {
    address pool = _createPool();
    address newAdmin = makeAddr("newAdmin");

    vm.prank(newAdmin);
    vm.expectRevert(IMetricOmmPoolFactoryPoolAdmin.NoPendingPoolAdminTransfer.selector);
    factory.acceptPoolAdmin(pool);
  }

  function test_acceptPoolAdmin_revertsWhenNotPendingAdmin() public {
    address pool = _createPool();
    address newAdmin = makeAddr("newAdmin");

    vm.prank(admin);
    factory.proposePoolAdminTransfer(pool, newAdmin);

    vm.prank(nonOwner);
    vm.expectRevert(
      abi.encodeWithSelector(IMetricOmmPoolFactoryPoolAdmin.NotPendingPoolAdmin.selector, pool, nonOwner, newAdmin)
    );
    factory.acceptPoolAdmin(pool);
  }

  function test_propose_then_accept_transfersAdmin() public {
    address pool = _createPool();
    address newAdmin = makeAddr("newAdmin");

    vm.prank(admin);
    factory.proposePoolAdminTransfer(pool, newAdmin);
    assertEq(factory.pendingPoolAdmin(pool), newAdmin);

    vm.prank(newAdmin);
    factory.acceptPoolAdmin(pool);

    assertEq(factory.poolAdmin(pool), newAdmin);
    assertEq(factory.pendingPoolAdmin(pool), address(0));
  }

  function test_cancelPoolAdminTransfer_clearsPending() public {
    address pool = _createPool();
    address newAdmin = makeAddr("newAdmin");

    vm.prank(admin);
    factory.proposePoolAdminTransfer(pool, newAdmin);

    vm.prank(admin);
    factory.cancelPoolAdminTransfer(pool);

    assertEq(factory.pendingPoolAdmin(pool), address(0));
    assertEq(factory.poolAdmin(pool), admin);
  }

  function test_proposePoolAdminTransfer_revertsWhenNewAdminZero() public {
    address pool = _createPool();
    vm.prank(admin);
    vm.expectRevert(IMetricOmmPoolFactory.InvalidAdmin.selector);
    factory.proposePoolAdminTransfer(pool, address(0));
  }

  function test_proposePoolAdminTransfer_revertsWhenSameAsCurrent() public {
    address pool = _createPool();
    vm.prank(admin);
    vm.expectRevert(IMetricOmmPoolFactory.InvalidAdmin.selector);
    factory.proposePoolAdminTransfer(pool, admin);
  }

  function _pauseLevel(address pool) private view returns (uint8) {
    (uint8 pl,,,,,) = PoolStateLibrary._slot0(pool);
    return pl;
  }

  function _notionalFeeE8(address pool) private view returns (uint24) {
    (,,,,, uint24 nf) = PoolStateLibrary._slot0(pool);
    return nf;
  }
}
