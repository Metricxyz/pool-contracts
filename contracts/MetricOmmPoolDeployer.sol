// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {MetricOmmPool} from "./MetricOmmPool.sol";
import {BinState} from "./types/PoolStorage.sol";
import {PoolExtensions, ExtensionOrders} from "./types/PoolExtensionsConfig.sol";

/// @title MetricOmmPoolDeployer
/// @notice Deploys MetricOmmPool instances with embedded bytecode, only callable by the factory
contract MetricOmmPoolDeployer {
  /// @notice The factory address that is allowed to deploy pools
  address public immutable FACTORY;

  /// @notice Thrown when caller is not the factory
  error OnlyFactory();

  /// @notice Parameters for deploying a pool
  struct DeployParams {
    bytes32 salt;
    address factory;
    address token0;
    address token1;
    address priceProvider;
    PoolExtensions extensions;
    ExtensionOrders extensionOrders;
    bool immutablePriceProvider;
    uint256 token0ScaleMultiplier;
    uint256 token1ScaleMultiplier;
    uint256 initialScaledAmount0PerShareE18;
    uint256 initialScaledAmount1PerShareE18;
    uint256 minimalOperationalLiquidity;
    uint24 spreadFeeE6;
    int24 curBinDistFromProvidedPriceE6;
    BinState[] nonNegativeBinStates;
    BinState[] negativeBinStates;
    uint24 notionalFeeE8;
    uint16 bidAskRefAsymmetryX8;
  }

  /// @param factory The factory address
  constructor(address factory) {
    FACTORY = factory;
  }

  function _checkFactory() private view {
    if (msg.sender != FACTORY) revert OnlyFactory();
  }

  /// @notice Restricts function to factory only
  modifier onlyFactory() {
    _checkFactory();
    _;
  }

  /// @notice Deploys a new MetricOmmPool
  /// @dev Only callable by the factory. Fee and parameter validation is the factory’s responsibility.
  /// @param params The deployment parameters
  /// @return pool The deployed pool address
  function deploy(DeployParams calldata params) external onlyFactory returns (address pool) {
    // Copy to memory so CREATE2 encoding stays within stack limits under via-IR.
    DeployParams memory p = params;
    pool = address(
      new MetricOmmPool{salt: p.salt}(
        p.factory,
        p.token0,
        p.token1,
        p.priceProvider,
        p.extensions,
        p.extensionOrders,
        p.immutablePriceProvider,
        p.token0ScaleMultiplier,
        p.token1ScaleMultiplier,
        p.initialScaledAmount0PerShareE18,
        p.initialScaledAmount1PerShareE18,
        p.minimalOperationalLiquidity,
        p.spreadFeeE6,
        p.curBinDistFromProvidedPriceE6,
        p.nonNegativeBinStates,
        p.negativeBinStates,
        p.notionalFeeE8,
        p.bidAskRefAsymmetryX8
      )
    );
  }
}
