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
    address admin;
    address adminFeeDestination;
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
    uint256 minimalMintableLiquidity;
    uint24 spreadFeeE6;
    int24 curBinDistFromProvidedPriceE6;
    BinState[] nonNegativeBinStates;
    BinState[] negativeBinStates;
    uint24 notionalFeeE8;
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
    pool = address(
      new MetricOmmPool{salt: params.salt}(
        params.factory,
        params.admin,
        params.adminFeeDestination,
        params.token0,
        params.token1,
        params.priceProvider,
        params.extensions,
        params.extensionOrders,
        params.immutablePriceProvider,
        params.token0ScaleMultiplier,
        params.token1ScaleMultiplier,
        params.initialScaledAmount0PerShareE18,
        params.initialScaledAmount1PerShareE18,
        params.minimalMintableLiquidity,
        params.spreadFeeE6,
        params.curBinDistFromProvidedPriceE6,
        params.nonNegativeBinStates,
        params.negativeBinStates,
        params.notionalFeeE8
      )
    );
  }
}
