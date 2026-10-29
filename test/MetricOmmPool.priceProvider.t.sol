// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {MetricOmmPoolFactory} from "../contracts/MetricOmmPoolFactory.sol";
import {MetricOmmPoolDeployer} from "../contracts/MetricOmmPoolDeployer.sol";
import {
  IMetricOmmPoolFactoryPoolAdmin
} from "../contracts/interfaces/IMetricOmmPoolFactory/IMetricOmmPoolFactoryPoolAdmin.sol";
import {PoolParameters} from "../contracts/types/FactoryOperation.sol";
import {ExtensionOrders} from "../contracts/types/PoolExtensionsConfig.sol";
import {PoolStateLibrary} from "../contracts/libraries/PoolStateLibrary.sol";
import {IMetricOmmPool} from "../contracts/interfaces/IMetricOmmPool/IMetricOmmPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockOracle} from "./mocks/MockOracle.sol";

contract MetricOmmPoolPriceProviderTest is Test {
  uint256 internal constant PRICE_PROVIDER_TIMELOCK = 1 days;

  MetricOmmPoolFactory internal factory;
  MetricOmmPoolDeployer internal deployer;
  MockERC20 internal token0;
  MockERC20 internal token1;
  MockOracle internal oracle;
  address internal admin;
  address internal adminFeeDestination;

  function setUp() public {
    admin = makeAddr("admin");
    adminFeeDestination = makeAddr("adminFeeDestination");

    token0 = new MockERC20("Token0", "TK0", 18);
    token1 = new MockERC20("Token1", "TK1", 18);
    oracle = new MockOracle();
    oracle.setBidAndAskPrice(uint128(2 ** 64), uint128(2 ** 64 + 1));

    factory = new MetricOmmPoolFactory(address(this));
    factory.setDefaultSpreadProtocolFeeE6(10_000);
    deployer = new MetricOmmPoolDeployer(address(factory));
    factory.setPoolDeployer(address(deployer));
  }

  function _defaultParams() internal returns (PoolParameters memory p) {
    address orderedToken0 = address(token0) < address(token1) ? address(token0) : address(token1);
    address orderedToken1 = address(token0) < address(token1) ? address(token1) : address(token0);
    oracle.setTokens(orderedToken0, orderedToken1);
    p = PoolParameters({
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
      adminSpreadFeeE6: 5_000,
      adminNotionalFeeE8: 0,
      adminFeeDestination: adminFeeDestination,
      curBinDistFromProvidedPriceE6: int24(0),
      nonNegativeBinDataArray: _singleBinDataArray(),
      negativeBinDataArray: _singleBinDataArray(),
      salt: keccak256("price_provider_immutable")
    });
  }

  function _singleBinDataArray() internal pure returns (uint256[] memory binDataArray) {
    binDataArray = new uint256[](1);
    uint16 lengthE6 = 100;
    uint16 buyFee = 0;
    uint16 sellFee = 0;
    uint48 binData = uint48(lengthE6) | (uint48(buyFee) << 16) | (uint48(sellFee) << 32);
    binDataArray[0] = uint256(binData);
  }

  function test_priceProviderTimelock_immutableMode_revertsPropose() public {
    PoolParameters memory params = _defaultParams();
    address pool = factory.createPool(params);

    address newProvider = makeAddr("newProvider");

    vm.prank(admin);
    vm.expectRevert(IMetricOmmPoolFactoryPoolAdmin.PriceProviderImmutable.selector);
    factory.proposePoolPriceProvider(pool, newProvider);
  }

  function test_priceProviderTimelock_proposeAndExecute() public {
    PoolParameters memory params = _defaultParams();
    params.priceProviderTimelock = PRICE_PROVIDER_TIMELOCK;
    params.salt = keccak256("price_provider_mutable");
    address pool = factory.createPool(params);

    MockOracle newOracle = new MockOracle();
    newOracle.setTokens(
      address(token0) < address(token1) ? address(token0) : address(token1),
      address(token0) < address(token1) ? address(token1) : address(token0)
    );
    newOracle.setBidAndAskPrice(uint128(2 ** 64), uint128(2 ** 64 + 1));

    uint256 executeAfter = block.timestamp + PRICE_PROVIDER_TIMELOCK;

    vm.expectEmit(true, true, true, true, address(factory));
    emit IMetricOmmPoolFactoryPoolAdmin.PoolPriceProviderChangeProposed(
      pool, address(oracle), address(newOracle), executeAfter
    );
    vm.prank(admin);
    factory.proposePoolPriceProvider(pool, address(newOracle));

    assertEq(factory.pendingPriceProvider(pool), address(newOracle), "pending via factory");
    assertEq(factory.pendingPriceProviderExecuteAfter(pool), executeAfter, "pending executeAfter via factory");

    vm.prank(admin);
    vm.expectRevert(
      abi.encodeWithSelector(
        IMetricOmmPoolFactoryPoolAdmin.PriceProviderTimelockNotElapsed.selector, executeAfter, block.timestamp
      )
    );
    factory.executePoolPriceProviderUpdate(pool);

    vm.warp(executeAfter);

    vm.expectEmit(true, true, false, true, address(factory));
    emit IMetricOmmPoolFactoryPoolAdmin.PoolPriceProviderUpdated(pool, address(newOracle));
    vm.prank(admin);
    factory.executePoolPriceProviderUpdate(pool);

    assertEq(_activePriceProvider(pool), address(newOracle), "active price provider should update");
    assertEq(factory.pendingPriceProvider(pool), address(0), "pending cleared");
    assertEq(factory.pendingPriceProviderExecuteAfter(pool), 0, "executeAfter cleared");

    assertEq(factory.priceProviderTimelock(pool), PRICE_PROVIDER_TIMELOCK, "timelock from factory mapping");
    address immSlot = IMetricOmmPool(pool).getImmutables().immutablePriceProvider;
    assertEq(immSlot, address(0), "mutable mode: no burned immutable oracle");
  }

  function _activePriceProvider(address pool) private view returns (address) {
    address mutableProvider = PoolStateLibrary._slot3(pool);
    if (mutableProvider != address(0)) return mutableProvider;
    return IMetricOmmPool(pool).getImmutables().immutablePriceProvider;
  }
}
