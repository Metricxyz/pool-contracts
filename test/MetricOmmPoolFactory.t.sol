// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {MetricOmmPoolFactory} from "../contracts/MetricOmmPoolFactory.sol";
import {Auth, Authority} from "../contracts/auth/Auth.sol";
import {Auth2Step} from "../contracts/auth/Auth2Step.sol";
import {IMetricOmmPoolFactory} from "../contracts/interfaces/IMetricOmmPoolFactory/IMetricOmmPoolFactory.sol";
import {IMetricOmmPoolFactoryOwner} from "../contracts/interfaces/IMetricOmmPoolFactory/IMetricOmmPoolFactoryOwner.sol";
import {
  IMetricOmmPoolFactoryPoolAdmin
} from "../contracts/interfaces/IMetricOmmPoolFactory/IMetricOmmPoolFactoryPoolAdmin.sol";
import {IMetricOmmPoolFactoryActions} from "../contracts/interfaces/IMetricOmmPool/IMetricOmmPoolFactoryActions.sol";
import {PoolParameters} from "../contracts/types/FactoryOperation.sol";
import {ExtensionOrders} from "../contracts/types/PoolExtensionsConfig.sol";
import {IMetricOmmPoolActions} from "../contracts/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {IMetricOmmPoolCollectFees} from "../contracts/interfaces/IMetricOmmPool/IMetricOmmPoolCollectFees.sol";
import {IMetricOmmPool, PoolImmutables} from "../contracts/interfaces/IMetricOmmPool/IMetricOmmPool.sol";
import {MetricOmmPoolDeployer} from "../contracts/MetricOmmPoolDeployer.sol";
import {PoolStateLibrary} from "../contracts/libraries/PoolStateLibrary.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFeeTransferToken} from "./mocks/MockFeeTransferToken.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {MockAuthority} from "./mocks/MockAuthority.sol";

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

    factory = new MetricOmmPoolFactory(address(this), address(this), 0, 0, type(uint16).max);
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

  function test_setPoolAdminFeeDestination_updatesAndEmits() public {
    address pool = _createPool();
    address newDest = makeAddr("newAdminFeeDestination");

    vm.expectEmit(true, false, false, true, address(factory));
    emit IMetricOmmPoolFactoryPoolAdmin.PoolAdminFeeDestinationUpdated(pool, newDest);

    vm.prank(admin);
    factory.setPoolAdminFeeDestination(pool, newDest);

    assertEq(factory.poolAdminFeeDestination(pool), newDest);
  }

  // ============ Roles: fee receiver, protocol pause ============

  function test_authority_ownerCanPauseWhenAuthorityReverts() public {
    address pool = _createPool();
    MockAuthority authority = new MockAuthority();
    factory.setAuthority(authority);
    authority.setUnavailable(true);

    factory.protocolPausePool(pool);
    (uint8 level,,,,,,) = PoolStateLibrary._slot0(pool);
    assertEq(level, 2);

    vm.prank(nonOwner);
    vm.expectRevert(MockAuthority.AuthorityUnavailable.selector);
    factory.setFeeReceiver(nonOwner);

    factory.setAuthority(Authority(address(0)));
    factory.protocolUnpausePool(pool);
  }

  function test_authority_ownerCanPauseWhenAuthorityHasNoCode() public {
    address pool = _createPool();
    factory.setAuthority(Authority(nonOwner));
    factory.protocolPausePool(pool);
    (uint8 level,,,,,,) = PoolStateLibrary._slot0(pool);
    assertEq(level, 2);

    vm.prank(nonOwner);
    vm.expectRevert();
    factory.setFeeReceiver(nonOwner);

    factory.setAuthority(Authority(address(0)));
    factory.protocolUnpausePool(pool);
  }

  function test_authority_denialRejectsStrangerButNotOwner() public {
    factory.setAuthority(new MockAuthority());
    vm.prank(nonOwner);
    vm.expectRevert(Auth.Auth_Unauthorized.selector);
    factory.setFeeReceiver(nonOwner);

    factory.setFeeReceiver(address(this));
    assertEq(factory.feeReceiver(), address(this));
  }

  function test_authority_pausePermissionIsScopedAndRevocable() public {
    address pool = _createPool();
    MockAuthority authority = new MockAuthority();
    authority.setPermission(nonOwner, address(factory), factory.protocolPausePool.selector, true);
    factory.setAuthority(authority);

    vm.startPrank(nonOwner);
    factory.protocolPausePool(pool);
    vm.expectRevert(Auth.Auth_Unauthorized.selector);
    factory.protocolUnpausePool(pool);
    vm.expectRevert(Auth.Auth_Unauthorized.selector);
    factory.setFeeReceiver(nonOwner);
    vm.expectRevert(Auth.Auth_Unauthorized.selector);
    factory.setAuthority(Authority(address(0)));
    vm.expectRevert(Auth.Auth_Unauthorized.selector);
    factory.transferOwnership(nonOwner);
    vm.expectRevert(IMetricOmmPoolFactoryPoolAdmin.NotPoolAdmin.selector);
    factory.setPoolAdminFees(pool, 0, 0);
    vm.stopPrank();

    authority.setPermission(nonOwner, address(factory), factory.protocolPausePool.selector, false);
    factory.protocolUnpausePool(pool);
    vm.prank(nonOwner);
    vm.expectRevert(Auth.Auth_Unauthorized.selector);
    factory.protocolPausePool(pool);
  }

  function test_transferOwnership_preservesDelegationUntilNewOwnerDisconnectsAuthority() public {
    address newOwner = makeAddr("newOwner");
    MockAuthority authority = new MockAuthority();
    authority.setPermission(address(this), address(factory), factory.setFeeReceiver.selector, true);
    authority.setPermission(nonOwner, address(factory), factory.setFeeReceiver.selector, true);
    factory.setAuthority(authority);
    factory.transferOwnership(newOwner);
    vm.prank(newOwner);
    factory.acceptOwnership();
    assertEq(factory.owner(), newOwner);
    assertEq(address(factory.authority()), address(authority));

    // Both an existing operator and the former owner retain explicit authority permissions.
    vm.prank(nonOwner);
    factory.setFeeReceiver(nonOwner);
    assertEq(factory.feeReceiver(), nonOwner);
    factory.setFeeReceiver(address(this));
    assertEq(factory.feeReceiver(), address(this));
    vm.expectRevert(Auth.Auth_Unauthorized.selector);
    factory.setAuthority(Authority(address(0)));

    vm.prank(newOwner);
    factory.setAuthority(Authority(address(0)));
    assertEq(address(factory.authority()), address(0));
    vm.expectRevert(Auth.Auth_Unauthorized.selector);
    factory.setFeeReceiver(address(this));
    vm.prank(nonOwner);
    vm.expectRevert(Auth.Auth_Unauthorized.selector);
    factory.setFeeReceiver(nonOwner);
    vm.prank(newOwner);
    factory.setFeeReceiver(newOwner);
    assertEq(factory.feeReceiver(), newOwner);
  }

  function test_constructor_revertsWhenOwnerIsZero() public {
    vm.expectRevert(Auth.Auth_InvalidOwner.selector);
    new MetricOmmPoolFactory(address(0), address(this), 0, 0, type(uint16).max);
  }

  function test_transferOwnership_requiresAcceptanceAndEmitsPreviousOwner() public {
    address newOwner = makeAddr("newOwner");
    vm.expectEmit(true, true, false, true, address(factory));
    emit Auth2Step.OwnershipTransferStarted(address(this), newOwner);
    factory.transferOwnership(newOwner);
    assertEq(factory.owner(), address(this));
    assertEq(factory.pendingOwner(), newOwner);

    vm.prank(newOwner);
    vm.expectRevert(Auth.Auth_Unauthorized.selector);
    factory.setFeeReceiver(newOwner);

    vm.expectEmit(true, true, false, true, address(factory));
    emit Auth.OwnershipTransferred(address(this), newOwner);
    vm.prank(newOwner);
    factory.acceptOwnership();
    assertEq(factory.owner(), newOwner);
    assertEq(factory.pendingOwner(), address(0));

    vm.expectRevert(Auth.Auth_Unauthorized.selector);
    factory.setFeeReceiver(newOwner);
    vm.prank(newOwner);
    factory.setFeeReceiver(newOwner);
    assertEq(factory.feeReceiver(), newOwner);
  }

  function test_transferOwnership_zeroCancelsPendingTransfer() public {
    address newOwner = makeAddr("newOwner");
    factory.transferOwnership(newOwner);
    factory.transferOwnership(address(0));
    assertEq(factory.owner(), address(this));
    assertEq(factory.pendingOwner(), address(0));

    vm.prank(newOwner);
    vm.expectRevert(Auth.Auth_Unauthorized.selector);
    factory.acceptOwnership();
  }

  function test_transferOwnership_revertsForStranger() public {
    vm.prank(nonOwner);
    vm.expectRevert(Auth.Auth_Unauthorized.selector);
    factory.transferOwnership(nonOwner);
  }

  function test_acceptOwnership_revertsForStranger() public {
    factory.transferOwnership(makeAddr("newOwner"));
    vm.prank(nonOwner);
    vm.expectRevert(Auth.Auth_Unauthorized.selector);
    factory.acceptOwnership();
  }

  /// @dev `feeReceiver` no longer defaults to the owner; `setUp` happens to pass the same address for both.
  function test_constructor_setsFeeReceiverFromArgument() public view {
    assertEq(factory.feeReceiver(), address(this), "feeReceiver comes from initialFeeReceiver");
  }

  function test_setFeeReceiver_updatesAndEmits() public {
    address treasury = makeAddr("treasury");
    vm.expectEmit(true, false, false, false, address(factory));
    emit IMetricOmmPoolFactoryOwner.FeeReceiverUpdated(treasury);
    factory.setFeeReceiver(treasury);
    assertEq(factory.feeReceiver(), treasury);
  }

  function test_setFeeReceiver_revertsZero() public {
    vm.expectRevert(IMetricOmmPoolFactoryOwner.InvalidFeeReceiver.selector);
    factory.setFeeReceiver(address(0));
  }

  function test_setFeeReceiver_onlyOwner() public {
    vm.prank(nonOwner);
    vm.expectRevert();
    factory.setFeeReceiver(makeAddr("treasury"));
  }

  function test_protocolPausePool_ownerCanPause() public {
    address pool = _createPool();
    factory.protocolPausePool(pool); // owner == address(this)
  }

  function test_protocolPausePool_revertsForStranger() public {
    address pool = _createPool();
    vm.prank(nonOwner);
    vm.expectRevert();
    factory.protocolPausePool(pool);
  }

  function test_protocolUnpausePool_revertsForStranger() public {
    address pool = _createPool();
    factory.protocolPausePool(pool); // to level 2

    vm.prank(nonOwner);
    vm.expectRevert();
    factory.protocolUnpausePool(pool);

    factory.protocolUnpausePool(pool); // owner, 2 -> 1
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
    factory.setPoolProtocolFee(pool, 500_001, 0);
  }

  function test_getFeeCaps_returnsInitialValues() public view {
    (uint24 p, uint24 a, uint24 pn, uint24 an) = factory.getFeeCaps();
    assertEq(p, 500_000);
    assertEq(a, 500_000);
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
    factory.setFeeCaps(500_001, 500_000, 1_000_000, 1_000_000);
  }

  function test_setFeeCaps_revertsWhenNotionalCapExceedsHardLimit() public {
    vm.expectRevert(IMetricOmmPoolFactoryOwner.FeeCapsExceedHardLimit.selector);
    factory.setFeeCaps(500_000, 500_000, 1_000_001, 1_000_000);
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

  function test_setPoolProtocolFee_revertsWhenNotionalAboveCap() public {
    address pool = _createPool();

    vm.expectRevert(IMetricOmmPoolFactory.ProtocolFeeTooHigh.selector);
    factory.setPoolProtocolFee(pool, 10_000, 1_000_001);
  }

  /// @notice `setPoolProtocolFee` respects the current, owner-adjustable cap — not the hard limit. Lowering
  ///         the cap first blocks a pool update above it; the owner must raise the cap again to exceed it.
  function test_setPoolProtocolFee_revertsWhenAboveLoweredCap() public {
    address pool = _createPool();
    factory.setFeeCaps(200_000, 200_000, 200_000, 200_000);

    vm.expectRevert(IMetricOmmPoolFactory.ProtocolFeeTooHigh.selector);
    factory.setPoolProtocolFee(pool, 300_000, 0);
  }

  /// @notice A `0` creation cap admits no valid `bidAskRefAsymmetryX8` at all — `createPool` rejects both
  ///         values above the cap and `0` itself — so the constructor must reject it outright. Regression:
  ///         the guard originally sat after the unchanged-value early return, and storage is `0` during
  ///         construction, so a `0` argument returned early and deployed a factory that could create no pools.
  function test_constructor_revertsWhenOnCreationMaxBidAskRefAsymmetryIsZero() public {
    vm.expectRevert(IMetricOmmPoolFactory.BidAskRefAsymmetryTooLow.selector);
    new MetricOmmPoolFactory(address(this), address(this), 0, 0, 0);
  }

  function test_constructor_revertsWhenFeeReceiverIsZero() public {
    vm.expectRevert(IMetricOmmPoolFactoryOwner.InvalidFeeReceiver.selector);
    new MetricOmmPoolFactory(address(this), address(0), 0, 0, type(uint16).max);
  }

  /// @notice The constructor must actually apply its arguments, not just accept them.
  function test_constructor_appliesInitialConfig() public {
    MetricOmmPoolFactory f = new MetricOmmPoolFactory(address(this), address(0xFEE), 12_345, 6_789, 4_242);
    assertEq(f.spreadProtocolFeeE6(), 12_345, "initialSpreadProtocolFeeE6");
    assertEq(f.protocolNotionalFeeE8(), 6_789, "initialProtocolNotionalFeeE8");
    assertEq(f.onCreationMaxBidAskRefAsymmetryX8(), 4_242, "initialOnCreationMaxBidAskRefAsymmetryX8");
    assertEq(f.feeReceiver(), address(0xFEE), "initialFeeReceiver");
  }

  function test_setOnCreationMaxBidAskRefAsymmetryX8_revertsOnZero() public {
    vm.expectRevert(IMetricOmmPoolFactory.BidAskRefAsymmetryTooLow.selector);
    factory.setOnCreationMaxBidAskRefAsymmetryX8(0);
  }

  /// @notice `0` makes `M = 1`, which no quote can satisfy, so every path that could set it must reject it.
  function test_setPoolBidAskRefAsymmetryX8_revertsOnZero() public {
    address pool = _createPool();
    vm.expectRevert(IMetricOmmPoolFactory.BidAskRefAsymmetryTooLow.selector);
    factory.setPoolBidAskRefAsymmetryX8(pool, 0);
  }

  function test_setPoolBidAskRefAsymmetryX8Batch_revertsOnZeroEntry() public {
    address poolA = _createPool();
    address poolB = _createPool(keccak256("ZERO_ENTRY"));
    address[] memory pools = new address[](2);
    pools[0] = poolA;
    pools[1] = poolB;
    uint16[] memory values = new uint16[](2);
    values[0] = 1000;
    values[1] = 0;

    vm.expectRevert(IMetricOmmPoolFactory.BidAskRefAsymmetryTooLow.selector);
    factory.setPoolBidAskRefAsymmetryX8Batch(pools, values);

    (,,,,,, uint16 storedA) = PoolStateLibrary._slot0(poolA);
    assertEq(storedA, type(uint16).max, "poolA must be untouched: the whole batch reverted");
  }

  function test_setPoolBidAskRefAsymmetryX8Batch_revertsOnArrayLengthMismatch() public {
    address[] memory pools = new address[](1);
    pools[0] = _createPool();

    vm.expectRevert(IMetricOmmPoolFactoryOwner.ArrayLengthMismatch.selector);
    factory.setPoolBidAskRefAsymmetryX8Batch(pools, new uint16[](2));
  }

  /// @notice The create-time cap is the only bound `onCreationMaxBidAskRefAsymmetryX8` still enforces after
  ///         `setPoolBidAskRefAsymmetryX8` stopped consulting it, so it needs its own coverage.
  function test_createPool_revertsWhenBidAskRefAsymmetryAboveCap() public {
    factory.setOnCreationMaxBidAskRefAsymmetryX8(1000);

    PoolParameters memory params = _defaultPoolParams();
    params.salt = keccak256("ABOVE_CAP");
    params.bidAskRefAsymmetryX8 = 1001;

    vm.expectRevert(IMetricOmmPoolFactory.BidAskRefAsymmetryTooHigh.selector);
    factory.createPool(params);
  }

  function test_createPool_acceptsBidAskRefAsymmetryAtExactCap() public {
    factory.setOnCreationMaxBidAskRefAsymmetryX8(1000);

    PoolParameters memory params = _defaultPoolParams();
    params.salt = keccak256("AT_CAP");
    params.bidAskRefAsymmetryX8 = 1000;

    address pool = factory.createPool(params);
    (,,,,,, uint16 stored) = PoolStateLibrary._slot0(pool);
    assertEq(stored, 1000, "a value exactly at the cap must be accepted");
  }

  function test_createPool_revertsWhenBidAskRefAsymmetryIsZero() public {
    PoolParameters memory params = _defaultPoolParams();
    params.salt = keccak256("ZERO_ASYM");
    params.bidAskRefAsymmetryX8 = 0;

    vm.expectRevert(IMetricOmmPoolFactory.BidAskRefAsymmetryTooLow.selector);
    factory.createPool(params);
  }

  function test_setPoolBidAskRefAsymmetryX8_succeedsAboveCurrentCap() public {
    address pool = _createPool();
    factory.setOnCreationMaxBidAskRefAsymmetryX8(100);

    vm.expectEmit(true, false, false, true, address(factory));
    emit IMetricOmmPoolFactoryOwner.PoolBidAskRefAsymmetryUpdated(pool, 50_000);
    factory.setPoolBidAskRefAsymmetryX8(pool, 50_000);

    (,,,,,, uint16 storedAsymmetryX8) = PoolStateLibrary._slot0(pool);
    assertEq(storedAsymmetryX8, 50_000, "pool's bidAskRefAsymmetryX8 must actually be updated");
  }

  function test_setPoolProtocolFeeBatch_updatesAllPools() public {
    address poolA = _createPool();
    address poolB = _createPool(keccak256("PROTO_BATCH"));
    address[] memory pools = new address[](2);
    pools[0] = poolA;
    pools[1] = poolB;
    uint24[] memory spreads = new uint24[](2);
    spreads[0] = 111_000;
    spreads[1] = 222_000;
    uint24[] memory notionals = new uint24[](2);
    notionals[0] = 1_000;
    notionals[1] = 2_000;

    factory.setPoolProtocolFeeBatch(pools, spreads, notionals);

    (uint24 aSpread,, uint24 aNotional,) = factory.poolFeeConfig(poolA);
    (uint24 bSpread,, uint24 bNotional,) = factory.poolFeeConfig(poolB);
    assertEq(aSpread, 111_000);
    assertEq(aNotional, 1_000);
    assertEq(bSpread, 222_000);
    assertEq(bNotional, 2_000);
  }

  function test_setPoolProtocolFeeBatch_revertsOnArrayLengthMismatch() public {
    address[] memory pools = new address[](1);
    pools[0] = _createPool();
    uint24[] memory spreads = new uint24[](2);

    vm.expectRevert(IMetricOmmPoolFactoryOwner.ArrayLengthMismatch.selector);
    factory.setPoolProtocolFeeBatch(pools, spreads, new uint24[](1));
  }

  /// @notice The batch is atomic: one pool with an out-of-hard-max value reverts the whole call, so an
  ///         earlier pool in the same batch is not left partially updated.
  function test_setPoolProtocolFeeBatch_revertsWholeBatchWhenOnePoolInvalid() public {
    address poolA = _createPool();
    address poolB = _createPool(keccak256("PROTO_ATOMIC"));
    address[] memory pools = new address[](2);
    pools[0] = poolA;
    pools[1] = poolB;
    uint24[] memory spreads = new uint24[](2);
    spreads[0] = 111_000;
    spreads[1] = 500_001; // above hard max
    uint24[] memory notionals = new uint24[](2);

    vm.expectRevert(IMetricOmmPoolFactory.ProtocolFeeTooHigh.selector);
    factory.setPoolProtocolFeeBatch(pools, spreads, notionals);

    (uint24 aSpread,,,) = factory.poolFeeConfig(poolA);
    assertEq(aSpread, INITIAL_PROTOCOL_FEE_E6, "poolA must be untouched: the whole batch reverted");
  }

  function test_setPoolBidAskRefAsymmetryX8Batch_updatesAllPools() public {
    address poolA = _createPool();
    address poolB = _createPool(keccak256("ASYM_BATCH"));
    address[] memory pools = new address[](2);
    pools[0] = poolA;
    pools[1] = poolB;
    uint16[] memory values = new uint16[](2);
    values[0] = 1000;
    values[1] = 2000;

    vm.expectEmit(true, false, false, true, address(factory));
    emit IMetricOmmPoolFactoryOwner.PoolBidAskRefAsymmetryUpdated(poolA, 1000);
    vm.expectEmit(true, false, false, true, address(factory));
    emit IMetricOmmPoolFactoryOwner.PoolBidAskRefAsymmetryUpdated(poolB, 2000);
    factory.setPoolBidAskRefAsymmetryX8Batch(pools, values);

    // Events alone would pass if the factory emitted without forwarding to the pools.
    (,,,,,, uint16 storedA) = PoolStateLibrary._slot0(poolA);
    (,,,,,, uint16 storedB) = PoolStateLibrary._slot0(poolB);
    assertEq(storedA, 1000, "poolA bidAskRefAsymmetryX8 must actually be updated");
    assertEq(storedB, 2000, "poolB bidAskRefAsymmetryX8 must actually be updated");
  }

  function test_createPool_usesFactoryDefaultProtocolNotionalFee() public {
    MetricOmmPoolFactory f = new MetricOmmPoolFactory(address(this), address(this), 0, 0, type(uint16).max);
    f.setDefaultSpreadProtocolFeeE6(INITIAL_PROTOCOL_FEE_E6);
    f.setDefaultProtocolNotionalFeeE8(50_000);
    MetricOmmPoolDeployer d = new MetricOmmPoolDeployer(address(f));
    f.setPoolDeployer(address(d));

    PoolParameters memory params = _defaultPoolParams();
    params.protocolSpreadFeeE6 = INITIAL_PROTOCOL_FEE_E6;
    params.protocolNotionalFeeE8 = 50_000;
    address pool = f.createPool(params);
    assertEq(_notionalFeeE8(pool), 50_000);
    (,, uint24 pNotional,) = f.poolFeeConfig(pool);
    assertEq(pNotional, 50_000);
  }

  function test_createPool_allowsProtocolFeesAboveDefaultsWithinCaps() public {
    PoolParameters memory params = _defaultPoolParams();
    params.protocolSpreadFeeE6 = INITIAL_PROTOCOL_FEE_E6 + 5_000;
    params.protocolNotionalFeeE8 = 25_000;

    address pool = factory.createPool(params);
    (uint24 pSpread,, uint24 pNotional,) = factory.poolFeeConfig(pool);
    assertEq(pSpread, INITIAL_PROTOCOL_FEE_E6 + 5_000);
    assertEq(pNotional, 25_000);
    assertEq(_spreadFeeE6(pool), uint256(INITIAL_PROTOCOL_FEE_E6 + 5_000) + ADMIN_FEE_E6);
    assertEq(_notionalFeeE8(pool), 25_000);
  }

  function test_createPool_clampsProtocolFeesBelowDefaultsUp() public {
    PoolParameters memory params = _defaultPoolParams();
    params.protocolSpreadFeeE6 = INITIAL_PROTOCOL_FEE_E6 - 1;
    params.protocolNotionalFeeE8 = 0;

    factory.setDefaultProtocolNotionalFeeE8(10_000);
    address pool = factory.createPool(params);
    (uint24 pSpread,, uint24 pNotional,) = factory.poolFeeConfig(pool);
    assertEq(pSpread, INITIAL_PROTOCOL_FEE_E6);
    assertEq(pNotional, 10_000);
  }

  function test_createPool_revertsWhenProtocolSpreadAboveCap() public {
    PoolParameters memory params = _defaultPoolParams();
    params.protocolSpreadFeeE6 = 500_001;

    vm.expectRevert(IMetricOmmPoolFactory.ProtocolFeeTooHigh.selector);
    factory.createPool(params);
  }

  function test_setDefaultSpreadProtocolFeeE6_revertsWhenFeeTooHigh() public {
    vm.expectRevert(IMetricOmmPoolFactory.ProtocolFeeTooHigh.selector);
    factory.setDefaultSpreadProtocolFeeE6(500_001);
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
    params.curBinDistFromProvidedPriceE6 = 1_000_001;

    vm.expectRevert(
      abi.encodeWithSelector(IMetricOmmPoolFactory.BinDistanceOutOfRange.selector, int16(0), int64(1_000_001))
    );
    factory.createPool(params);
  }

  function test_createPool_revertsWhenPositiveBinsExceedDistanceDomain() public {
    PoolParameters memory params = _defaultPoolParams();
    params.curBinDistFromProvidedPriceE6 = 999_950;
    params.nonNegativeBinDataArray = _singleBinDataArrayWithLength(100);

    vm.expectRevert(
      abi.encodeWithSelector(IMetricOmmPoolFactory.BinDistanceOutOfRange.selector, int16(0), int64(1_000_050))
    );
    factory.createPool(params);
  }

  function test_createPool_revertsWhenNegativeBinsExceedDistanceDomain() public {
    PoolParameters memory params = _defaultPoolParams();
    params.curBinDistFromProvidedPriceE6 = -499_950;
    params.negativeBinDataArray = _singleBinDataArrayWithLength(100);

    vm.expectRevert(
      abi.encodeWithSelector(IMetricOmmPoolFactory.BinDistanceOutOfRange.selector, int16(-1), int64(-500_050))
    );
    factory.createPool(params);
  }

  // ---- Bin distance limits: owner configuration ----

  function test_constructor_binDistanceLimitsDefault() public view {
    assertEq(factory.minBinDistanceE6(), -500_000);
    assertEq(factory.maxBinDistanceE6(), 1_000_000);
    assertEq(factory.hardMinBinDistanceLimitE6(), -999_999);
    // The ceiling is the pool's `int24` running-distance domain; above it `_clampInt256ToInt24` saturates.
    assertEq(factory.hardMaxBinDistanceLimitE6(), int256(type(int24).max));
  }

  function test_setBinDistanceLimits_acceptsExactHardBoundsAndEmits() public {
    vm.expectEmit(true, true, true, true, address(factory));
    emit IMetricOmmPoolFactoryOwner.BinDistanceLimitsUpdated(-999_999, int256(type(int24).max));
    factory.setBinDistanceLimits(-999_999, int128(type(int24).max));
    assertEq(factory.minBinDistanceE6(), -999_999);
    assertEq(factory.maxBinDistanceE6(), int128(type(int24).max));
  }

  function test_setBinDistanceLimits_acceptsNarrowRangeAndEmits() public {
    vm.expectEmit(true, true, true, true, address(factory));
    emit IMetricOmmPoolFactoryOwner.BinDistanceLimitsUpdated(-50_000, 50_000);
    factory.setBinDistanceLimits(-50_000, 50_000);
    assertEq(factory.minBinDistanceE6(), -50_000);
    assertEq(factory.maxBinDistanceE6(), 50_000);
  }

  function test_setBinDistanceLimits_revertsWhenMinBelowHardFloor() public {
    vm.expectRevert(IMetricOmmPoolFactoryOwner.InvalidBinDistanceLimits.selector);
    factory.setBinDistanceLimits(-1_000_000, 500_000);
  }

  /// @dev Without this bound the owner can admit pools whose cumulative distance leaves the pool's
  ///      `int24` domain, where the swap loop silently saturates instead of reverting.
  function test_setBinDistanceLimits_revertsWhenMaxAboveHardCeiling() public {
    vm.expectRevert(IMetricOmmPoolFactoryOwner.InvalidBinDistanceLimits.selector);
    factory.setBinDistanceLimits(-500_000, int128(type(int24).max) + 1);
  }

  function test_setBinDistanceLimits_revertsWhenMinNotNegative() public {
    vm.expectRevert(IMetricOmmPoolFactoryOwner.InvalidBinDistanceLimits.selector);
    factory.setBinDistanceLimits(0, 500_000);

    vm.expectRevert(IMetricOmmPoolFactoryOwner.InvalidBinDistanceLimits.selector);
    factory.setBinDistanceLimits(100_000, 500_000);
  }

  function test_setBinDistanceLimits_revertsWhenMaxNotPositive() public {
    vm.expectRevert(IMetricOmmPoolFactoryOwner.InvalidBinDistanceLimits.selector);
    factory.setBinDistanceLimits(-100_000, 0);

    vm.expectRevert(IMetricOmmPoolFactoryOwner.InvalidBinDistanceLimits.selector);
    factory.setBinDistanceLimits(-100_000, -50_000);
  }

  function test_setBinDistanceLimits_onlyOwner() public {
    vm.prank(nonOwner);
    vm.expectRevert();
    factory.setBinDistanceLimits(-999_999, 2_000_000);
  }

  // ---- Bin distance limits: enforcement at pool creation ----

  function test_createPool_seedAtExactMaxClearsSeedCheckThenOverflowsOnFirstBin() public {
    PoolParameters memory params = _defaultPoolParams();
    params.salt = keccak256("SEED_AT_MAX");
    params.curBinDistFromProvidedPriceE6 = 1_000_000;
    params.nonNegativeBinDataArray = _singleBinDataArrayWithLength(1);
    params.negativeBinDataArray = _singleBinDataArrayWithLength(100);

    vm.expectRevert(
      abi.encodeWithSelector(IMetricOmmPoolFactory.BinDistanceOutOfRange.selector, int16(0), int64(1_000_001))
    );
    factory.createPool(params);
  }

  function test_createPool_acceptsSeedAtExactMin() public {
    PoolParameters memory params = _defaultPoolParams();
    params.salt = keccak256("SEED_AT_MIN");
    params.curBinDistFromProvidedPriceE6 = -500_000;
    params.negativeBinDataArray = new uint256[](0);

    assertTrue(factory.createPool(params) != address(0));
  }

  function test_createPool_revertsWhenSeedOnePastMin() public {
    PoolParameters memory params = _defaultPoolParams();
    params.curBinDistFromProvidedPriceE6 = -500_001;
    params.negativeBinDataArray = new uint256[](0);

    vm.expectRevert(
      abi.encodeWithSelector(IMetricOmmPoolFactory.BinDistanceOutOfRange.selector, int16(0), int64(-500_001))
    );
    factory.createPool(params);
  }

  function test_createPool_acceptsCumulativeAtExactMax() public {
    PoolParameters memory params = _defaultPoolParams();
    params.salt = keccak256("CUM_AT_MAX");
    params.curBinDistFromProvidedPriceE6 = 999_900;
    params.nonNegativeBinDataArray = _singleBinDataArrayWithLength(100); // 999_900 + 100 == max

    assertTrue(factory.createPool(params) != address(0));
  }

  function test_createPool_revertsWhenCumulativeOnePastMax() public {
    PoolParameters memory params = _defaultPoolParams();
    params.curBinDistFromProvidedPriceE6 = 999_901;
    params.nonNegativeBinDataArray = _singleBinDataArrayWithLength(100);

    vm.expectRevert(
      abi.encodeWithSelector(IMetricOmmPoolFactory.BinDistanceOutOfRange.selector, int16(0), int64(1_000_001))
    );
    factory.createPool(params);
  }

  function test_createPool_acceptsCumulativeAtExactMin() public {
    PoolParameters memory params = _defaultPoolParams();
    params.salt = keccak256("CUM_AT_MIN");
    params.curBinDistFromProvidedPriceE6 = -499_900;
    params.negativeBinDataArray = _singleBinDataArrayWithLength(100); // -499_900 - 100 == min

    assertTrue(factory.createPool(params) != address(0));
  }

  function test_createPool_revertsWhenCumulativeOnePastMin() public {
    PoolParameters memory params = _defaultPoolParams();
    params.curBinDistFromProvidedPriceE6 = -499_901;
    params.negativeBinDataArray = _singleBinDataArrayWithLength(100);

    vm.expectRevert(
      abi.encodeWithSelector(IMetricOmmPoolFactory.BinDistanceOutOfRange.selector, int16(-1), int64(-500_001))
    );
    factory.createPool(params);
  }

  /// @dev The point of the feature: a shape rejected under the defaults becomes valid once the owner
  ///      widens the window, and nothing else about creation changes.
  function test_createPool_widenedLimitsAdmitDistanceBeyondDefaultMax() public {
    PoolParameters memory params = _defaultPoolParams();
    params.salt = keccak256("WIDENED");
    params.curBinDistFromProvidedPriceE6 = 0;
    params.nonNegativeBinDataArray = _binDataArrayOfLength(40, 65_535); // cumulative 2_621_400

    vm.expectRevert(
      abi.encodeWithSelector(IMetricOmmPoolFactory.BinDistanceOutOfRange.selector, int16(15), int64(1_048_560))
    );
    factory.createPool(params);

    factory.setBinDistanceLimits(-500_000, 4_000_000);
    assertTrue(factory.createPool(params) != address(0));
  }

  /// @dev Tightening the window gates future pools only; it must not be possible to sneak a shape in
  ///      that the current limits reject.
  function test_createPool_tightenedLimitsRejectPreviouslyValidShape() public {
    PoolParameters memory params = _defaultPoolParams();
    params.salt = keccak256("TIGHTENED_BEFORE");
    params.curBinDistFromProvidedPriceE6 = 900_000;
    assertTrue(factory.createPool(params) != address(0));

    factory.setBinDistanceLimits(-50_000, 50_000);

    params.salt = keccak256("TIGHTENED_AFTER");
    vm.expectRevert(
      abi.encodeWithSelector(IMetricOmmPoolFactory.BinDistanceOutOfRange.selector, int16(0), int64(900_000))
    );
    factory.createPool(params);
  }

  /// @dev The hard floor exists so `distanceE6ToPriceX64` never computes a zero price factor
  ///      (`1e6 - |d|` is unchecked). Pin that the most extreme admissible pool is still constructible.
  function test_createPool_acceptsCumulativeAtHardMinFloor() public {
    factory.setBinDistanceLimits(-999_999, 1_000_000);

    PoolParameters memory params = _defaultPoolParams();
    params.salt = keccak256("HARD_FLOOR");
    params.curBinDistFromProvidedPriceE6 = -999_899;
    params.negativeBinDataArray = _singleBinDataArrayWithLength(100); // -999_899 - 100 == -999_999

    assertTrue(factory.createPool(params) != address(0));
  }

  function test_createPool_revertsWhenNonNegativeBinsEmpty() public {
    PoolParameters memory params = _defaultPoolParams();
    params.nonNegativeBinDataArray = new uint256[](0);

    vm.expectRevert(IMetricOmmPoolFactory.BinArraysEmpty.selector);
    factory.createPool(params);
  }

  function test_createPool_revertsWhenInitialScaledAmountExceedsUint128() public {
    PoolParameters memory params = _defaultPoolParams();
    params.initialScaledAmount0PerE18Shares = uint256(type(uint128).max);
    params.initialScaledAmount1PerE18Shares = uint256(type(uint128).max);

    vm.expectRevert(IMetricOmmPoolFactory.InvalidInitialAmount.selector);
    factory.createPool(params);
  }

  function test_createPool_revertsWhenMinimalOperationalLiquidityTooLow() public {
    PoolParameters memory params = _defaultPoolParams();
    // With P̂ = 1e18, required is L >= 1e6.
    params.minimalOperationalLiquidity = 1e6 - 1;

    vm.expectRevert(
      abi.encodeWithSelector(
        IMetricOmmPoolFactory.MinimalOperationalLiquidityTooSmallComparedToInitialScaledTokenAmounts.selector,
        uint256(1e6 - 1),
        uint256(1e6)
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
      initialScaledAmount0PerE18Shares: uint104(1e18),
      initialScaledAmount1PerE18Shares: uint104(1e18),
      minimalOperationalLiquidity: uint104(1e6),
      protocolSpreadFeeE6: factory.spreadProtocolFeeE6(),
      adminSpreadFeeE6: ADMIN_FEE_E6,
      protocolNotionalFeeE8: factory.protocolNotionalFeeE8(),
      adminNotionalFeeE8: 0,
      adminFeeDestination: adminFeeDestination,
      curBinDistFromProvidedPriceE6: int24(0),
      nonNegativeBinDataArray: _singleBinDataArray(),
      negativeBinDataArray: _singleBinDataArray(),
      salt: keccak256("POOL_SALT"),
      bidAskRefAsymmetryX8: type(uint16).max
    });
  }

  function _createPool() internal returns (address) {
    PoolParameters memory params = _defaultPoolParams();
    return factory.createPool(params);
  }

  function _createPool(bytes32 salt) internal returns (address) {
    PoolParameters memory params = _defaultPoolParams();
    params.salt = salt;
    return factory.createPool(params);
  }

  /// @dev Bin indices are `int16`, so the type allows far more bins than are practical: each one costs
  ///      a cold SSTORE at construction on top of the ~4M code-deposit charge. The factory therefore
  ///      caps the grid so a pool stays deployable in a single transaction. Untested, that cap is just
  ///      a comment -- these pin both sides of it.
  /// @dev Each packed word holds FIVE bins at 48 bits each; a zero `lengthE6` terminates the grid. So
  ///      `count` bins need `ceil(count/5)` words, with any unused trailing slots left zero.
  function _binDataArrayOfLength(uint256 count) internal pure returns (uint256[] memory) {
    return _binDataArrayOfLength(count, 100);
  }

  function _binDataArrayOfLength(uint256 count, uint16 lengthE6) internal pure returns (uint256[] memory binDataArray) {
    uint256 words = (count + 4) / 5;
    binDataArray = new uint256[](words);
    uint256 remaining = count;
    for (uint256 w = 0; w < words; w++) {
      uint256 packed;
      for (uint256 j = 0; j < 5 && remaining > 0; j++) {
        packed |= uint256(uint48(lengthE6)) << (48 * j); // no additional fees
        remaining--;
      }
      binDataArray[w] = packed;
    }
  }

  /// @dev The helper is load-bearing for the cap tests below, so pin that it really does produce the
  ///      requested number of bins -- an under-filled array would make those tests pass vacuously.
  function test_binDataArrayHelperProducesTheRequestedBinCount() public {
    PoolParameters memory params = _defaultPoolParams();
    params.salt = keccak256("HELPER_CHECK");
    params.nonNegativeBinDataArray = _binDataArrayOfLength(7);
    params.negativeBinDataArray = _binDataArrayOfLength(3);
    address pool = factory.createPool(params);

    PoolImmutables memory imm = IMetricOmmPool(pool).getImmutables();
    assertEq(imm.highestBin, int256(6), "7 non-negative bins => highest index 6");
    assertEq(imm.lowestBin, int256(-3), "3 negative bins => lowest index -3");
  }

  /// @dev There is no policy cap on grid size any more -- only the block gas limit. Prove a grid well
  ///      past the old 500-per-side limit is accepted, and record what it costs so the gas-bound nature
  ///      of the limit stays visible.
  function test_createPool_acceptsAGridBeyondTheOldPolicyCap() public {
    PoolParameters memory params = _defaultPoolParams();
    params.salt = keccak256("WIDE_GRID");
    params.nonNegativeBinDataArray = _binDataArrayOfLength(600);
    params.negativeBinDataArray = _binDataArrayOfLength(600);

    uint256 before = gasleft();
    address pool = factory.createPool(params);
    emit log_named_uint("createPool gas for 600+600 bins", before - gasleft());

    PoolImmutables memory imm = IMetricOmmPool(pool).getImmutables();
    assertEq(imm.highestBin, int256(599), "600 non-negative bins => highest index 599");
    assertEq(imm.lowestBin, int256(-600), "600 negative bins => lowest index -600");
  }

  /// @dev The one remaining bound is a TYPE invariant: a bin index must fit `int16`, the width of
  ///      `curBinIdx` in slot0 and of the position-key derivation. The bin-distance guards admit
  ///      ~2,000,000 bins, so they do not protect it -- without this check a chain with a high enough
  ///      gas limit would silently wrap indices. Cheap to test because the check fires during
  ///      validation, before a single bin is written.
  function test_createPool_revertsWhenABinIndexCannotFitInt16() public {
    PoolParameters memory params = _defaultPoolParams();
    params.salt = keccak256("INT16_OVERFLOW");
    params.nonNegativeBinDataArray = _binDataArrayOfLength(32_769, 1); // one past int16's 0..32767
    params.negativeBinDataArray = _binDataArrayOfLength(1);
    vm.expectRevert(abi.encodeWithSelector(IMetricOmmPoolFactory.BinIndexRangeExceededInt16.selector));
    factory.createPool(params);
  }

  function test_createPool_revertsWhenANegativeBinIndexCannotFitInt16() public {
    PoolParameters memory params = _defaultPoolParams();
    params.salt = keccak256("INT16_OVERFLOW_NEG");
    params.nonNegativeBinDataArray = _binDataArrayOfLength(1);
    params.negativeBinDataArray = _binDataArrayOfLength(32_769, 1); // one past int16's -1..-32768
    vm.expectRevert(abi.encodeWithSelector(IMetricOmmPoolFactory.BinIndexRangeExceededInt16.selector));
    factory.createPool(params);
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
    emit IMetricOmmPoolFactoryActions.BinAdditionalFeesUpdated(int16(0), uint16(500), uint16(700));

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
    vm.expectRevert(abi.encodeWithSelector(IMetricOmmPoolActions.InvalidBinIndex.selector, int16(3)));
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
    (uint8 pl,,,,,,) = PoolStateLibrary._slot0(pool);
    return pl;
  }

  function _notionalFeeE8(address pool) private view returns (uint24) {
    (,,,,, uint24 nf,) = PoolStateLibrary._slot0(pool);
    return nf;
  }

  function _spreadFeeE6(address pool) private view returns (uint24) {
    (,,,, uint24 sf,,) = PoolStateLibrary._slot0(pool);
    return sf;
  }
}
