// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {MetricOmmPoolDeployer} from "./MetricOmmPoolDeployer.sol";
import {ValidateExtensionsConfig} from "./libraries/ValidateExtensionsConfig.sol";
import {CallExtension} from "./libraries/CallExtension.sol";
import {BinDataLibrary} from "./libraries/BinDataLibrary.sol";
import {BinState} from "./types/PoolStorage.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPriceProvider} from "./interfaces/IPriceProvider/IPriceProvider.sol";
import {IMetricOmmPoolFactory} from "./interfaces/IMetricOmmPoolFactory/IMetricOmmPoolFactory.sol";
import {IMetricOmmPoolFactoryOwner} from "./interfaces/IMetricOmmPoolFactory/IMetricOmmPoolFactoryOwner.sol";
import {IMetricOmmPoolCollectFees} from "./interfaces/IMetricOmmPool/IMetricOmmPoolCollectFees.sol";
import {IMetricOmmPoolFactoryActions} from "./interfaces/IMetricOmmPool/IMetricOmmPoolFactoryActions.sol";
import {IMetricOmmPoolFactoryPoolAdmin} from "./interfaces/IMetricOmmPoolFactory/IMetricOmmPoolFactoryPoolAdmin.sol";
import {IMetricOmmPool, PoolImmutables} from "./interfaces/IMetricOmmPool/IMetricOmmPool.sol";
import {IMetricOmmExtensions} from "./interfaces/extensions/IMetricOmmExtensions.sol";
import {PoolParameters} from "./types/FactoryOperation.sol";
import {PoolExtensions, ExtensionOrders} from "./types/PoolExtensionsConfig.sol";
import {PoolFeeConfig} from "./types/FactoryStorage.sol";
import {PoolStateLibrary} from "./libraries/PoolStateLibrary.sol";

/**
 * @title MetricOmmPoolFactory
 * @notice Factory for deploying Metric OMM pools via `MetricOmmPoolDeployer`.
 * @dev Implements Ownable2Step; see `IMetricOmmPoolFactory` for the full API.
 * @dev Layout matches `MetricOmmPool`: constants, state variables, constructor, modifiers, external views, external mutators (`createPool` first), internal helpers.
 * @dev Auto-generated getters from `public` state variables follow declaration order and may differ from explicit view ordering in `IMetricOmmPoolFactory.sol`.
 */
contract MetricOmmPoolFactory is Ownable2Step, IMetricOmmPoolFactory, ReentrancyGuardTransient {
  using SafeERC20 for IERC20;
  using SafeCast for uint256;
  using SafeCast for int256;
  using BinDataLibrary for BinDataLibrary.BinData;

  // ============ Constants ============

  /// @dev Owner `setFeeCaps` values cannot exceed these (spread: 1e6 = 100%; notional: 1e8 = 100%)
  uint24 internal constant HARD_MAX_SPREAD_FEE_E6 = 200_000;
  uint24 internal constant HARD_MAX_NOTIONAL_FEE_E8 = 1_000_000;

  // ============ State Variables ============

  /// @inheritdoc IMetricOmmPoolFactory
  address public override poolDeployer;

  /// @inheritdoc IMetricOmmPoolFactory
  uint24 public override spreadProtocolFeeE6;

  /// @inheritdoc IMetricOmmPoolFactory
  uint24 public override protocolNotionalFeeE8;

  /// @inheritdoc IMetricOmmPoolFactory
  uint24 public override maxProtocolSpreadFeeE6;

  /// @inheritdoc IMetricOmmPoolFactory
  uint24 public override maxAdminSpreadFeeE6;

  /// @inheritdoc IMetricOmmPoolFactory
  uint24 public override maxProtocolNotionalFeeE8;

  /// @inheritdoc IMetricOmmPoolFactory
  uint24 public override maxAdminNotionalFeeE8;

  /// @inheritdoc IMetricOmmPoolFactory
  mapping(address => address) public override poolAdmin;

  /// @inheritdoc IMetricOmmPoolFactory
  mapping(address => address) public override pendingPoolAdmin;

  /// @inheritdoc IMetricOmmPoolFactory
  mapping(address => address) public override pendingPriceProvider;

  /// @inheritdoc IMetricOmmPoolFactory
  mapping(address => uint256) public override pendingPriceProviderExecuteAfter;

  /// @inheritdoc IMetricOmmPoolFactory
  mapping(address => uint256) public override priceProviderTimelock;

  /// @inheritdoc IMetricOmmPoolFactory
  mapping(address => PoolFeeConfig) public override poolFeeConfig;

  /// @inheritdoc IMetricOmmPoolFactory
  mapping(address => address) public override poolAdminFeeDestination;

  /// @inheritdoc IMetricOmmPoolFactory
  uint256 public override nextPoolIdx;

  /// @inheritdoc IMetricOmmPoolFactory
  mapping(uint256 => address) public override idxToPool;

  /// @inheritdoc IMetricOmmPoolFactory
  mapping(address => uint256) public override poolToIdx;

  // ============ Constructor ============

  /// @notice Creates the factory with the given owner; default protocol spread and notional fees start at zero
  /// @param initialOwner The initial owner of the factory
  constructor(address initialOwner) Ownable(initialOwner) {
    maxProtocolSpreadFeeE6 = HARD_MAX_SPREAD_FEE_E6;
    maxAdminSpreadFeeE6 = HARD_MAX_SPREAD_FEE_E6;
    maxProtocolNotionalFeeE8 = HARD_MAX_NOTIONAL_FEE_E8;
    maxAdminNotionalFeeE8 = HARD_MAX_NOTIONAL_FEE_E8;
    spreadProtocolFeeE6 = 0;
    protocolNotionalFeeE8 = 0;
    nextPoolIdx = 1;

    emit FeeCapsUpdated(
      HARD_MAX_SPREAD_FEE_E6, HARD_MAX_SPREAD_FEE_E6, HARD_MAX_NOTIONAL_FEE_E8, HARD_MAX_NOTIONAL_FEE_E8
    );
    emit SpreadProtocolFeeDefaultUpdated(0, 0);
    emit ProtocolNotionalFeeDefaultUpdated(0, 0);
  }

  // ============ Modifiers ============

  function _checkPoolAdmin(address pool) private view {
    if (msg.sender != poolAdmin[pool]) revert NotPoolAdmin();
  }

  modifier onlyPoolAdmin(address pool) {
    _checkPoolAdmin(pool);
    _;
  }

  // ============ External: views ============

  /// @inheritdoc IMetricOmmPoolFactory
  function maxOwnerSpreadCapE6() external pure override returns (uint24) {
    return HARD_MAX_SPREAD_FEE_E6;
  }

  /// @inheritdoc IMetricOmmPoolFactory
  function maxOwnerNotionalCapE8() external pure override returns (uint24) {
    return HARD_MAX_NOTIONAL_FEE_E8;
  }

  /// @inheritdoc IMetricOmmPoolFactory
  function getFeeCaps() external view override returns (uint24, uint24, uint24, uint24) {
    return (maxProtocolSpreadFeeE6, maxAdminSpreadFeeE6, maxProtocolNotionalFeeE8, maxAdminNotionalFeeE8);
  }

  /// @inheritdoc IMetricOmmPoolFactory
  function isPool(address pool) external view override returns (bool) {
    return poolToIdx[pool] != 0;
  }

  // ============ External: pool creation ============

  /// @inheritdoc IMetricOmmPoolFactory
  function createPool(PoolParameters calldata params) external override returns (address pool) {
    if (poolDeployer == address(0)) revert PoolDeployerNotSet();
    _validatePoolParameters(params);
    (uint256 token0ScaleMultiplier, uint256 token1ScaleMultiplier) = _getScaleMultipliers(params.token0, params.token1);
    (BinState[] memory nonNegativeBinStates, BinState[] memory negativeBinStates) = _unpackAndValidateBinStates(
      params.curBinDistFromProvidedPriceE6, params.nonNegativeBinDataArray, params.negativeBinDataArray
    );

    bool immutablePriceProvider = params.priceProviderTimelock == type(uint256).max;

    uint256 initialScaledAmount0PerShareE18 = params.initialAmount0PerShareE18 * token0ScaleMultiplier;
    uint256 initialScaledAmount1PerShareE18 = params.initialAmount1PerShareE18 * token1ScaleMultiplier;
    if (initialScaledAmount0PerShareE18 >= type(uint128).max || initialScaledAmount1PerShareE18 >= type(uint128).max) {
      revert InitialScaledAmountExceedsUint128(initialScaledAmount0PerShareE18, initialScaledAmount1PerShareE18);
    }

    ValidateExtensionsConfig.validateExtensionsConfig(
      params.extensions, params.extensionOrders, params.extensionInitData
    );

    uint24 spreadFeeE6 = uint24(uint256(spreadProtocolFeeE6) + uint256(params.adminSpreadFeeE6));
    uint24 notionalFeeE8 = uint24(uint256(protocolNotionalFeeE8) + uint256(params.adminNotionalFeeE8));
    PoolExtensions memory poolExtensions = _poolExtensionsFromArray(params.extensions);

    pool = MetricOmmPoolDeployer(poolDeployer)
      .deploy(
        MetricOmmPoolDeployer.DeployParams({
        salt: params.salt,
        factory: address(this),
        admin: params.admin,
        adminFeeDestination: params.adminFeeDestination,
        token0: params.token0,
        token1: params.token1,
        priceProvider: params.priceProvider,
        extensions: poolExtensions,
        extensionOrders: params.extensionOrders,
        immutablePriceProvider: immutablePriceProvider,
        token0ScaleMultiplier: token0ScaleMultiplier,
        token1ScaleMultiplier: token1ScaleMultiplier,
        initialScaledAmount0PerShareE18: initialScaledAmount0PerShareE18,
        initialScaledAmount1PerShareE18: initialScaledAmount1PerShareE18,
        minimalMintableLiquidity: params.minimalMintableLiquidity,
        spreadFeeE6: spreadFeeE6,
        curBinDistFromProvidedPriceE6: params.curBinDistFromProvidedPriceE6,
        nonNegativeBinStates: nonNegativeBinStates,
        negativeBinStates: negativeBinStates,
        notionalFeeE8: notionalFeeE8
      })
      );

    for (uint256 i = 0; i < params.extensions.length; i++) {
      CallExtension.callExtension(
        params.extensions[i], abi.encodeCall(IMetricOmmExtensions.initialize, (pool, params.extensionInitData[i]))
      );
    }

    poolAdmin[pool] = params.admin;
    priceProviderTimelock[pool] = params.priceProviderTimelock;
    poolFeeConfig[pool] = PoolFeeConfig({
      protocolSpreadFeeE6: spreadProtocolFeeE6,
      adminSpreadFeeE6: params.adminSpreadFeeE6,
      protocolNotionalFeeE8: protocolNotionalFeeE8,
      adminNotionalFeeE8: params.adminNotionalFeeE8
    });
    poolAdminFeeDestination[pool] = params.adminFeeDestination;

    uint256 poolIdx = nextPoolIdx;
    nextPoolIdx++;
    idxToPool[poolIdx] = pool;
    poolToIdx[pool] = poolIdx;

    emit PoolCreated(
      pool,
      params.token0,
      params.token1,
      poolIdx,
      address(this),
      params.admin,
      params.priceProvider,
      params.extensions,
      params.extensionOrders,
      params.priceProviderTimelock,
      params.initialAmount0PerShareE18,
      params.initialAmount1PerShareE18,
      params.minimalMintableLiquidity,
      spreadProtocolFeeE6,
      protocolNotionalFeeE8,
      params.adminSpreadFeeE6,
      params.adminNotionalFeeE8,
      params.adminFeeDestination,
      params.curBinDistFromProvidedPriceE6,
      params.nonNegativeBinDataArray,
      params.negativeBinDataArray
    );
  }

  // ============ External: factory owner ============

  /// @inheritdoc IMetricOmmPoolFactoryOwner
  function setPoolDeployer(address _poolDeployer) external override onlyOwner {
    if (poolDeployer != address(0)) revert PoolDeployerAlreadySet();
    poolDeployer = _poolDeployer;
    emit PoolDeployerSet(_poolDeployer);
  }

  /// @inheritdoc IMetricOmmPoolFactoryOwner
  function collectTokens(address token, address to, uint256 amount) external override onlyOwner {
    uint256 balance = IERC20(token).balanceOf(address(this));
    uint256 amountToCollect = amount == 0 ? balance : amount;
    if (amountToCollect > 0) {
      IERC20(token).safeTransfer(to, amountToCollect);
      emit TokensCollected(token, to, amountToCollect);
    }
  }

  /// @inheritdoc IMetricOmmPoolFactoryOwner
  function collectEth(address payable to, uint256 amount) external override onlyOwner {
    uint256 balance = address(this).balance;
    uint256 amountToCollect = amount == 0 ? balance : amount;
    if (amountToCollect > 0) {
      (bool success,) = to.call{value: amountToCollect}("");
      require(success, "ETH transfer failed");
      emit TokensCollected(address(0), to, amountToCollect);
    }
  }
  receive() external payable {}

  /// @inheritdoc IMetricOmmPoolFactoryOwner
  function setFeeCaps(
    uint24 newMaxProtocolSpreadFeeE6,
    uint24 newMaxAdminSpreadFeeE6,
    uint24 newMaxProtocolNotionalFeeE8,
    uint24 newMaxAdminNotionalFeeE8
  ) external override onlyOwner {
    if (
      newMaxProtocolSpreadFeeE6 > HARD_MAX_SPREAD_FEE_E6 || newMaxAdminSpreadFeeE6 > HARD_MAX_SPREAD_FEE_E6
        || newMaxProtocolNotionalFeeE8 > HARD_MAX_NOTIONAL_FEE_E8 || newMaxAdminNotionalFeeE8 > HARD_MAX_NOTIONAL_FEE_E8
    ) {
      revert FeeCapsExceedHardLimit();
    }
    maxProtocolSpreadFeeE6 = newMaxProtocolSpreadFeeE6;
    maxAdminSpreadFeeE6 = newMaxAdminSpreadFeeE6;
    maxProtocolNotionalFeeE8 = newMaxProtocolNotionalFeeE8;
    maxAdminNotionalFeeE8 = newMaxAdminNotionalFeeE8;

    if (spreadProtocolFeeE6 > newMaxProtocolSpreadFeeE6) {
      uint24 oldFeeE6 = spreadProtocolFeeE6;
      spreadProtocolFeeE6 = newMaxProtocolSpreadFeeE6;
      emit SpreadProtocolFeeDefaultUpdated(oldFeeE6, newMaxProtocolSpreadFeeE6);
    }
    if (protocolNotionalFeeE8 > newMaxProtocolNotionalFeeE8) {
      uint24 oldFeeE8 = protocolNotionalFeeE8;
      protocolNotionalFeeE8 = newMaxProtocolNotionalFeeE8;
      emit ProtocolNotionalFeeDefaultUpdated(oldFeeE8, newMaxProtocolNotionalFeeE8);
    }

    emit FeeCapsUpdated(
      newMaxProtocolSpreadFeeE6, newMaxAdminSpreadFeeE6, newMaxProtocolNotionalFeeE8, newMaxAdminNotionalFeeE8
    );
  }

  /// @inheritdoc IMetricOmmPoolFactoryOwner
  function setPoolProtocolFee(address pool, uint24 newProtocolSpreadFeeE6, uint24 newProtocolNotionalFeeE8)
    external
    override
    onlyOwner
    nonReentrant
  {
    if (newProtocolSpreadFeeE6 > maxProtocolSpreadFeeE6) revert ProtocolFeeTooHigh();
    if (newProtocolNotionalFeeE8 > maxProtocolNotionalFeeE8) revert ProtocolFeeTooHigh();

    PoolFeeConfig memory c = poolFeeConfig[pool];
    IMetricOmmPoolCollectFees(pool)
      .collectFees(
        c.protocolSpreadFeeE6,
        c.adminSpreadFeeE6,
        c.protocolNotionalFeeE8,
        c.adminNotionalFeeE8,
        poolAdminFeeDestination[pool]
      );

    uint24 aSpread = c.adminSpreadFeeE6;
    uint24 aNotional = c.adminNotionalFeeE8;
    if (aSpread > maxAdminSpreadFeeE6) {
      aSpread = maxAdminSpreadFeeE6;
      emit PoolAdminSpreadFeeUpdated(pool, aSpread);
    }
    if (aNotional > maxAdminNotionalFeeE8) {
      aNotional = maxAdminNotionalFeeE8;
      emit PoolAdminNotionalFeeUpdated(pool, aNotional);
    }

    c = PoolFeeConfig({
      protocolSpreadFeeE6: newProtocolSpreadFeeE6,
      adminSpreadFeeE6: aSpread,
      protocolNotionalFeeE8: newProtocolNotionalFeeE8,
      adminNotionalFeeE8: aNotional
    });
    poolFeeConfig[pool] = c;

    IMetricOmmPoolFactoryActions(pool)
      .setPoolFees(c.protocolSpreadFeeE6 + c.adminSpreadFeeE6, c.protocolNotionalFeeE8 + c.adminNotionalFeeE8);
    emit PoolProtocolSpreadFeeUpdated(pool, newProtocolSpreadFeeE6);
    emit PoolProtocolNotionalFeeUpdated(pool, newProtocolNotionalFeeE8);
  }

  /// @inheritdoc IMetricOmmPoolFactoryOwner
  function setDefaultSpreadProtocolFeeE6(uint24 newFeeE6) external override onlyOwner {
    if (newFeeE6 > maxProtocolSpreadFeeE6) revert ProtocolFeeTooHigh();
    uint24 oldFeeE6 = spreadProtocolFeeE6;
    spreadProtocolFeeE6 = newFeeE6;
    emit SpreadProtocolFeeDefaultUpdated(oldFeeE6, newFeeE6);
  }

  /// @inheritdoc IMetricOmmPoolFactoryOwner
  function setDefaultProtocolNotionalFeeE8(uint24 newFeeE8) external override onlyOwner {
    if (newFeeE8 > maxProtocolNotionalFeeE8) revert ProtocolFeeTooHigh();
    uint24 oldFeeE8 = protocolNotionalFeeE8;
    protocolNotionalFeeE8 = newFeeE8;
    emit ProtocolNotionalFeeDefaultUpdated(oldFeeE8, newFeeE8);
  }

  /// @inheritdoc IMetricOmmPoolFactory
  function collectPoolFees(address pool) external override nonReentrant {
    PoolFeeConfig memory c = poolFeeConfig[pool];
    IMetricOmmPoolCollectFees(pool)
      .collectFees(
        c.protocolSpreadFeeE6,
        c.adminSpreadFeeE6,
        c.protocolNotionalFeeE8,
        c.adminNotionalFeeE8,
        poolAdminFeeDestination[pool]
      );
  }

  /// @inheritdoc IMetricOmmPoolFactoryOwner
  function protocolPausePool(address pool) external override nonReentrant onlyOwner {
    (uint8 cur,,,,,) = PoolStateLibrary._slot0(pool);
    if (cur != 0 && cur != 1) revert InvalidPauseTransition(cur, 2);
    IMetricOmmPoolFactoryActions(pool).setPause(2);
  }

  /// @inheritdoc IMetricOmmPoolFactoryOwner
  function protocolUnpausePool(address pool) external override nonReentrant onlyOwner {
    (uint8 cur,,,,,) = PoolStateLibrary._slot0(pool);
    if (cur != 2) revert InvalidPauseTransition(cur, 1);
    IMetricOmmPoolFactoryActions(pool).setPause(1);
  }

  // ============ External: pool admin ============

  /// @inheritdoc IMetricOmmPoolFactoryPoolAdmin
  function setPoolAdminFees(address pool, uint24 newAdminSpreadFeeE6, uint24 newAdminNotionalFeeE8)
    external
    override
    nonReentrant
    onlyPoolAdmin(pool)
  {
    if (newAdminSpreadFeeE6 > maxAdminSpreadFeeE6) revert AdminFeeTooHigh();
    if (newAdminNotionalFeeE8 > maxAdminNotionalFeeE8) revert AdminFeeTooHigh();

    PoolFeeConfig memory c = poolFeeConfig[pool];
    IMetricOmmPoolCollectFees(pool)
      .collectFees(
        c.protocolSpreadFeeE6,
        c.adminSpreadFeeE6,
        c.protocolNotionalFeeE8,
        c.adminNotionalFeeE8,
        poolAdminFeeDestination[pool]
      );

    c.adminSpreadFeeE6 = newAdminSpreadFeeE6;
    c.adminNotionalFeeE8 = newAdminNotionalFeeE8;
    poolFeeConfig[pool] = c;

    IMetricOmmPoolFactoryActions(pool)
      .setPoolFees(c.protocolSpreadFeeE6 + c.adminSpreadFeeE6, c.protocolNotionalFeeE8 + c.adminNotionalFeeE8);
    emit PoolAdminSpreadFeeUpdated(pool, newAdminSpreadFeeE6);
    emit PoolAdminNotionalFeeUpdated(pool, newAdminNotionalFeeE8);
  }

  /// @inheritdoc IMetricOmmPoolFactoryPoolAdmin
  function setPoolAdminFeeDestination(address pool, address newAdminFeeDestination)
    external
    override
    nonReentrant
    onlyPoolAdmin(pool)
  {
    if (newAdminFeeDestination == address(0)) revert InvalidAdminFeeDestination();
    poolAdminFeeDestination[pool] = newAdminFeeDestination;
    emit PoolAdminFeeDestinationUpdated(pool, newAdminFeeDestination);
  }

  /// @inheritdoc IMetricOmmPoolFactoryPoolAdmin
  function setPoolBinAdditionalFees(address pool, int8 bin, uint16 addFeeBuyE6, uint16 addFeeSellE6)
    external
    override
    nonReentrant
    onlyPoolAdmin(pool)
  {
    IMetricOmmPoolFactoryActions(pool).setBinAdditionalFees(bin, addFeeBuyE6, addFeeSellE6);
  }

  /// @inheritdoc IMetricOmmPoolFactoryPoolAdmin
  function pausePool(address pool) external override nonReentrant onlyPoolAdmin(pool) {
    (uint8 cur,,,,,) = PoolStateLibrary._slot0(pool);
    if (cur != 0) revert InvalidPauseTransition(cur, 1);
    IMetricOmmPoolFactoryActions(pool).setPause(1);
  }

  /// @inheritdoc IMetricOmmPoolFactoryPoolAdmin
  function unpausePool(address pool) external override nonReentrant onlyPoolAdmin(pool) {
    (uint8 cur,,,,,) = PoolStateLibrary._slot0(pool);
    if (cur != 1) revert InvalidPauseTransition(cur, 0);
    IMetricOmmPoolFactoryActions(pool).setPause(0);
  }

  /// @inheritdoc IMetricOmmPoolFactoryPoolAdmin
  function proposePoolPriceProvider(address pool, address newPriceProvider)
    external
    override
    nonReentrant
    onlyPoolAdmin(pool)
  {
    PoolImmutables memory p = IMetricOmmPool(pool).getImmutables();
    uint256 timelock = priceProviderTimelock[pool];
    if (p.immutablePriceProvider != address(0)) revert PriceProviderImmutable();
    _validatePriceProvider(p.token0, p.token1, newPriceProvider);

    address mutableProvider = PoolStateLibrary._slot3(pool);
    address current = mutableProvider != address(0) ? mutableProvider : p.immutablePriceProvider;
    uint256 executeAfter = block.timestamp + timelock;
    pendingPriceProvider[pool] = newPriceProvider;
    pendingPriceProviderExecuteAfter[pool] = executeAfter;
    emit PoolPriceProviderChangeProposed(pool, current, newPriceProvider, executeAfter);
  }

  /// @inheritdoc IMetricOmmPoolFactoryPoolAdmin
  function executePoolPriceProviderUpdate(address pool) external override nonReentrant onlyPoolAdmin(pool) {
    address pending = pendingPriceProvider[pool];
    if (pending == address(0)) revert NoPriceProviderChangeProposed();
    uint256 execAfter = pendingPriceProviderExecuteAfter[pool];
    // forge-lint: disable-next-line(block-timestamp) -- timelock enforcement legitimately relies on `block.timestamp`.
    if (block.timestamp < execAfter) revert PriceProviderTimelockNotElapsed(execAfter, block.timestamp);
    PoolImmutables memory p = IMetricOmmPool(pool).getImmutables();
    if (p.immutablePriceProvider != address(0)) revert PriceProviderImmutable();
    _validatePriceProvider(p.token0, p.token1, pending);
    IMetricOmmPoolFactoryActions(pool).setPriceProvider(pending);
    delete pendingPriceProvider[pool];
    delete pendingPriceProviderExecuteAfter[pool];
    emit PoolPriceProviderUpdated(pool, pending);
  }

  /// @inheritdoc IMetricOmmPoolFactoryPoolAdmin
  function proposePoolAdminTransfer(address pool, address newAdmin) external override nonReentrant onlyPoolAdmin(pool) {
    if (newAdmin == address(0)) revert InvalidAdmin();
    if (newAdmin == poolAdmin[pool]) revert InvalidAdmin();
    pendingPoolAdmin[pool] = newAdmin;
    emit PoolAdminTransferProposed(pool, poolAdmin[pool], newAdmin);
  }

  /// @inheritdoc IMetricOmmPoolFactoryPoolAdmin
  function acceptPoolAdmin(address pool) external override nonReentrant {
    address pending = pendingPoolAdmin[pool];
    if (pending == address(0)) revert NoPendingPoolAdminTransfer();
    if (msg.sender != pending) revert NotPendingPoolAdmin(pool, msg.sender, pending);
    address previousAdmin = poolAdmin[pool];
    poolAdmin[pool] = pending;
    delete pendingPoolAdmin[pool];
    emit PoolAdminTransferred(pool, previousAdmin, pending);
  }

  /// @inheritdoc IMetricOmmPoolFactoryPoolAdmin
  function cancelPoolAdminTransfer(address pool) external override nonReentrant onlyPoolAdmin(pool) {
    address pending = pendingPoolAdmin[pool];
    if (pending == address(0)) revert NoPendingPoolAdminTransfer();
    delete pendingPoolAdmin[pool];
    emit PoolAdminTransferCancelled(pool, pending);
  }

  // ============ Internal ============

  // ---- `createPool` validation and packing ----

  /// @dev Non-zero `priceProvider` must expose `IPriceProvider.token0()/token1()` matching this pool's `(token0, token1)`.
  function _validatePriceProvider(address token0, address token1, address priceProvider) internal view {
    if (priceProvider == address(0)) revert InvalidPriceProvider();
    if (IPriceProvider(priceProvider).token0() != token0 || IPriceProvider(priceProvider).token1() != token1) {
      revert PriceProviderTokenMismatch();
    }
  }

  function _validatePoolParameters(PoolParameters calldata params) internal view {
    if (params.token0 == address(0) || params.token1 == address(0) || params.token0 == params.token1) {
      revert InvalidTokenConfig();
    }
    if (params.admin == address(0)) revert InvalidAdmin();
    _validatePriceProvider(params.token0, params.token1, params.priceProvider);
    if (params.adminFeeDestination == address(0)) revert InvalidAdminFeeDestination();
    if (spreadProtocolFeeE6 > maxProtocolSpreadFeeE6) revert ProtocolFeeTooHigh();
    if (protocolNotionalFeeE8 > maxProtocolNotionalFeeE8) revert ProtocolFeeTooHigh();
    if (params.adminSpreadFeeE6 > maxAdminSpreadFeeE6) revert AdminFeeTooHigh();
    if (params.adminNotionalFeeE8 > maxAdminNotionalFeeE8) revert AdminFeeTooHigh();
    if (params.initialAmount0PerShareE18 == 0 || params.initialAmount1PerShareE18 == 0) {
      revert InvalidInitialAmount();
    }
    if (params.minimalMintableLiquidity == 0) revert InvalidMinimalMintableLiquidity();
  }

  /// @dev Single source of truth for packed-bin validation and `BinState` unpacking: two passes per side
  ///      (validate+count, then fill) to avoid extra full-array iterations.
  function _unpackAndValidateBinStates(
    int24 curBinDistFromProvidedPriceE6,
    uint256[] calldata nonNegativeBinDataArray,
    uint256[] calldata negativeBinDataArray
  ) internal pure returns (BinState[] memory nonNegativeBinStates, BinState[] memory negativeBinStates) {
    int256 cumulativeDistance = int256(curBinDistFromProvidedPriceE6);
    if (cumulativeDistance >= 1e6 || cumulativeDistance <= -1e6) revert BinDistanceOutOfRange(0, cumulativeDistance);
    if (nonNegativeBinDataArray.length == 0) revert BinArraysEmpty();

    int256 posBinCount = int256(0);
    for (uint256 i = 0; i < nonNegativeBinDataArray.length; i++) {
      uint256 packed = nonNegativeBinDataArray[i];
      for (uint8 j = 0; j < 5; j++) {
        BinDataLibrary.BinData binData = BinDataLibrary.toBinData(packed, j);
        (uint256 length,,) = binData.unpack();
        if (length == 0) {
          if (j == 0) revert BinLengthZero(posBinCount);
          break;
        }

        cumulativeDistance += length.toInt256();
        if (cumulativeDistance >= 1e6) {
          revert BinDistanceOutOfRange(posBinCount, cumulativeDistance);
        }
        posBinCount++;
      }
    }

    cumulativeDistance = int256(curBinDistFromProvidedPriceE6);
    int256 negBinCount = 0;
    for (uint256 i = 0; i < negativeBinDataArray.length; i++) {
      uint256 packed = negativeBinDataArray[i];
      for (uint8 j = 0; j < 5; j++) {
        BinDataLibrary.BinData binData = BinDataLibrary.toBinData(packed, j);
        (uint256 length,,) = binData.unpack();
        if (length == 0) {
          if (j == 0) revert BinLengthZero(-negBinCount - 1);
          break;
        }

        cumulativeDistance -= length.toInt256();
        if (cumulativeDistance <= -1e6) {
          revert BinDistanceOutOfRange(-negBinCount - 1, cumulativeDistance);
        }
        negBinCount++;
      }
    }

    if (posBinCount > 128 || negBinCount > 128) revert BinIndexRangeExceedsInt8();

    nonNegativeBinStates = new BinState[](posBinCount.toUint256());
    negativeBinStates = new BinState[](negBinCount.toUint256());

    {
      uint256 k = 0;
      for (uint256 i = 0; i < nonNegativeBinDataArray.length; i++) {
        uint256 packed = nonNegativeBinDataArray[i];
        for (uint8 j = 0; j < 5; j++) {
          BinDataLibrary.BinData binData = BinDataLibrary.toBinData(packed, j);
          (uint16 length, uint16 buyFee, uint16 sellFee) = binData.unpack();
          if (length == 0) break;
          nonNegativeBinStates[k] = BinState({
            token0BalanceScaled: 0, token1BalanceScaled: 0, lengthE6: length, addFeeBuyE6: buyFee, addFeeSellE6: sellFee
          });
          k++;
        }
      }
    }

    {
      uint256 k = 0;
      for (uint256 i = 0; i < negativeBinDataArray.length; i++) {
        uint256 packed = negativeBinDataArray[i];
        for (uint8 j = 0; j < 5; j++) {
          BinDataLibrary.BinData binData = BinDataLibrary.toBinData(packed, j);
          (uint16 length, uint16 buyFee, uint16 sellFee) = binData.unpack();
          if (length == 0) break;
          negativeBinStates[k] = BinState({
            token0BalanceScaled: 0, token1BalanceScaled: 0, lengthE6: length, addFeeBuyE6: buyFee, addFeeSellE6: sellFee
          });
          k++;
        }
      }
    }
  }

  function _getScaleMultipliers(address token0, address token1)
    internal
    view
    returns (uint256 token0ScaleMultiplier, uint256 token1ScaleMultiplier)
  {
    uint8 token0Decimals = IERC20Metadata(token0).decimals();
    uint8 token1Decimals = IERC20Metadata(token1).decimals();
    uint8 internalDecimals = 18;
    if (token0Decimals > internalDecimals) internalDecimals = token0Decimals;
    if (token1Decimals > internalDecimals) internalDecimals = token1Decimals;
    token0ScaleMultiplier = 10 ** (internalDecimals - token0Decimals);
    token1ScaleMultiplier = 10 ** (internalDecimals - token1Decimals);
  }

  function _poolExtensionsFromArray(address[] calldata extensions)
    private
    pure
    returns (PoolExtensions memory poolExtensions)
  {
    poolExtensions.extension1 = extensions.length > 0 ? extensions[0] : address(0);
    poolExtensions.extension2 = extensions.length > 1 ? extensions[1] : address(0);
    poolExtensions.extension3 = extensions.length > 2 ? extensions[2] : address(0);
    poolExtensions.extension4 = extensions.length > 3 ? extensions[3] : address(0);
    poolExtensions.extension5 = extensions.length > 4 ? extensions[4] : address(0);
    poolExtensions.extension6 = extensions.length > 5 ? extensions[5] : address(0);
    poolExtensions.extension7 = extensions.length > 6 ? extensions[6] : address(0);
  }
}
