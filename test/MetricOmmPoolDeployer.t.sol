// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {FactoryFeeCapsStub} from "./FactoryFeeCapsStub.sol";
import {PoolInitPreprocessor} from "./PoolInitPreprocessor.sol";
import {MetricOmmPool} from "../contracts/MetricOmmPool.sol";
import {MetricOmmPoolDeployer} from "../contracts/MetricOmmPoolDeployer.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {BinState} from "../contracts/types/PoolStorage.sol";
import {PoolExtensions, ExtensionOrders} from "../contracts/types/PoolExtensionsConfig.sol";

contract MetricOmmPoolDeployerTest is Test, FactoryFeeCapsStub, PoolInitPreprocessor {
  MockERC20 internal token0;
  MockERC20 internal token1;
  MockOracle internal oracle;
  MetricOmmPoolDeployer internal deployer;

  function setUp() public {
    token0 = new MockERC20("Token0", "TK0", 18);
    token1 = new MockERC20("Token1", "TK1", 18);
    oracle = new MockOracle();
    oracle.setBidAndAskPrice(uint128(2 ** 64), uint128(2 ** 64 + 1));

    deployer = new MetricOmmPoolDeployer(address(this));
  }

  function test_deployerAndDirectDeployment_haveEqualRuntimeBytecode() public {
    uint256[] memory nonNegativeBinDataArray = _singleBinDataArray();
    uint256[] memory negativeBinDataArray = _singleBinDataArray();
    (uint256 token0ScaleMultiplier, uint256 token1ScaleMultiplier) =
      _getScaleMultipliers(address(token0), address(token1));
    (BinState[] memory nonNegativeBinStates, BinState[] memory negativeBinStates) =
      _unpackBinStates(nonNegativeBinDataArray, negativeBinDataArray);

    address poolViaDeployer = deployer.deploy(
      MetricOmmPoolDeployer.DeployParams({
        salt: keccak256("POOL_SALT"),
        factory: address(this),
        admin: address(this),
        adminFeeDestination: address(this),
        token0: address(token0),
        token1: address(token1),
        priceProvider: address(oracle),
        extensions: _emptyExtensions(),
        extensionOrders: _emptyExtensionOrders(),
        immutablePriceProvider: true,
        token0ScaleMultiplier: token0ScaleMultiplier,
        token1ScaleMultiplier: token1ScaleMultiplier,
        initialScaledAmount0PerShareE18: uint104(1e18),
        initialScaledAmount1PerShareE18: uint104(1e18),
        minimalMintableLiquidity: uint104(1000),
        spreadFeeE6: uint24(1e4 + 5e3),
        curBinDistFromProvidedPriceE6: int24(0),
        nonNegativeBinStates: nonNegativeBinStates,
        negativeBinStates: negativeBinStates,
        notionalFeeE8: 0
      })
    );

    address poolDirect = address(
      new MetricOmmPool(
        address(this),
        address(this),
        address(this),
        address(token0),
        address(token1),
        address(oracle),
        _emptyExtensions(),
        _emptyExtensionOrders(),
        true,
        token0ScaleMultiplier,
        token1ScaleMultiplier,
        uint104(1e18),
        uint104(1e18),
        uint104(1000),
        uint24(1e4 + 5e3),
        int24(0),
        nonNegativeBinStates,
        negativeBinStates,
        0
      )
    );

    bytes memory viaDeployerCode = poolViaDeployer.code;
    bytes memory directCode = poolDirect.code;

    assertEq(viaDeployerCode.length, directCode.length, "Runtime bytecode length mismatch");
    assertEq(keccak256(viaDeployerCode), keccak256(directCode), "Runtime bytecode hash mismatch");
  }

  function test_onlyFactory_canDeploy() public {
    uint256[] memory nonNegativeBinDataArray = _singleBinDataArray();
    uint256[] memory negativeBinDataArray = _singleBinDataArray();
    (uint256 token0ScaleMultiplier, uint256 token1ScaleMultiplier) =
      _getScaleMultipliers(address(token0), address(token1));
    (BinState[] memory nonNegativeBinStates, BinState[] memory negativeBinStates) =
      _unpackBinStates(nonNegativeBinDataArray, negativeBinDataArray);

    MetricOmmPoolDeployer otherDeployer = new MetricOmmPoolDeployer(address(0xdead));

    vm.expectRevert(MetricOmmPoolDeployer.OnlyFactory.selector);
    otherDeployer.deploy(
      MetricOmmPoolDeployer.DeployParams({
        salt: keccak256("POOL_SALT"),
        factory: address(this),
        admin: address(this),
        adminFeeDestination: address(this),
        token0: address(token0),
        token1: address(token1),
        priceProvider: address(oracle),
        extensions: _emptyExtensions(),
        extensionOrders: _emptyExtensionOrders(),
        immutablePriceProvider: true,
        token0ScaleMultiplier: token0ScaleMultiplier,
        token1ScaleMultiplier: token1ScaleMultiplier,
        initialScaledAmount0PerShareE18: uint104(1e18),
        initialScaledAmount1PerShareE18: uint104(1e18),
        minimalMintableLiquidity: uint104(1000),
        spreadFeeE6: uint24(1e4 + 5e3),
        curBinDistFromProvidedPriceE6: int24(0),
        nonNegativeBinStates: nonNegativeBinStates,
        negativeBinStates: negativeBinStates,
        notionalFeeE8: 0
      })
    );
  }

  function _emptyExtensions() internal pure returns (PoolExtensions memory extensions) {}

  function _emptyExtensionOrders() internal pure returns (ExtensionOrders memory orders) {}

  function _singleBinDataArray() internal pure returns (uint256[] memory binDataArray) {
    binDataArray = new uint256[](1);
    uint16 lengthE6 = 100;
    uint16 buyFee = 0;
    uint16 sellFee = 0;

    uint48 binData = uint48(lengthE6) | (uint48(buyFee) << 16) | (uint48(sellFee) << 32);
    binDataArray[0] = uint256(binData);
  }
}
