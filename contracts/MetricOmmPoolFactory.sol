// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {MetricOmmPoolDeployer} from "./MetricOmmPoolDeployer.sol";
import {ValidateExtensionsConfig} from "./libraries/ValidateExtensionsConfig.sol";
import {CallExtension} from "./libraries/CallExtension.sol";
import {BinDataLibrary} from "./libraries/BinDataLibrary.sol";
import {BinState} from "./types/PoolStorage.sol";
import {Auth2Step} from "./auth/Auth2Step.sol";
import {Auth, Authority} from "./auth/Auth.sol";
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
 * @dev Inherits from Auth2Step; see `IMetricOmmPoolFactory` for the full API.
 * @dev Layout: constants, state variables, constructor, modifiers, external views, external mutators (`createPool`, permissionless `collectPoolFees`, owner, pool admin), internal helpers.
 * @dev Auto-generated getters from `public` state variables follow declaration order and may differ from explicit view ordering in `IMetricOmmPoolFactory.sol`.
 */
contract MetricOmmPoolFactory is Auth2Step, IMetricOmmPoolFactory, ReentrancyGuardTransient {
  using SafeERC20 for IERC20;
  using SafeCast for uint256;
  using SafeCast for int256;
  using BinDataLibrary for BinDataLibrary.BinData;

  // ============ Constants ============
  int256 internal constant MAX_BINS_PER_SIDE = 32_768;

  /// @dev Owner `setFeeCaps` values cannot exceed these (spread: 1e6 = 100%; notional: 1e8 = 100%)
  uint24 internal constant HARD_MAX_PROTOCOL_SPREAD_FEE_E6 = 500_000;
  uint24 internal constant HARD_MAX_ADMIN_SPREAD_FEE_E6 = 500_000;
  uint24 internal constant HARD_MAX_PROTOCOL_NOTIONAL_FEE_E8 = 1_000_000;
  uint24 internal constant HARD_MAX_ADMIN_NOTIONAL_FEE_E8 = 1_000_000;

  /// @dev `minimalOperationalLiquidity` must be at least `PRECISION * 1e18 / min(P̂0, P̂1)` so leftover /
  ///      min-delta share ops keep ~ppm-level composition precision vs empty-bin density.
  uint256 internal constant MINIMAL_OPERATIONAL_LIQUIDITY_PRECISION = 1e6;

  int256 internal constant HARD_MIN_BIN_DISTANCE_LIMIT_E6 = -999_999;
  int256 internal constant HARD_MAX_BIN_DISTANCE_LIMIT_E6 = int256(type(int24).max);

  // ============ State Variables ============

  /// @inheritdoc IMetricOmmPoolFactory
  address public override poolDeployer;

  /// @inheritdoc IMetricOmmPoolFactory
  uint24 public override maxProtocolSpreadFeeE6;
  /// @inheritdoc IMetricOmmPoolFactory
  uint24 public override spreadProtocolFeeE6;

  /// @inheritdoc IMetricOmmPoolFactory
  uint24 public override maxProtocolNotionalFeeE8;
  /// @inheritdoc IMetricOmmPoolFactory
  uint24 public override protocolNotionalFeeE8;

  /// @inheritdoc IMetricOmmPoolFactory
  uint24 public override maxAdminSpreadFeeE6;

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

  /// @inheritdoc IMetricOmmPoolFactory
  /// @dev Cap for create-time `bidAskRefAsymmetryX8` only; `setPoolBidAskRefAsymmetryX8` is not gated by this.
  ///      `type(uint16).max` allows pools to disable the check.
  uint16 public override onCreationMaxBidAskRefAsymmetryX8;

  /// @inheritdoc IMetricOmmPoolFactory
  address public override feeReceiver;

  /// @inheritdoc IMetricOmmPoolFactory
  int128 public override minBinDistanceE6;

  /// @inheritdoc IMetricOmmPoolFactory
  int128 public override maxBinDistanceE6;

  // ============ Constructor ============

  /// @notice Creates the factory with the given owner and initial protocol-fee defaults; fee caps open at
  ///         their hard ceilings and bin distance limits take the factory's standard range.
  constructor(
    address initialOwner,
    address initialFeeReceiver,
    uint24 initialSpreadProtocolFeeE6,
    uint24 initialProtocolNotionalFeeE8,
    uint16 initialOnCreationMaxBidAskRefAsymmetryX8
  ) Auth(initialOwner, Authority(address(0))) {
    _setFeeCaps(
      HARD_MAX_PROTOCOL_SPREAD_FEE_E6,
      HARD_MAX_ADMIN_SPREAD_FEE_E6,
      HARD_MAX_PROTOCOL_NOTIONAL_FEE_E8,
      HARD_MAX_ADMIN_NOTIONAL_FEE_E8
    );
    _setDefaultSpreadProtocolFeeE6(initialSpreadProtocolFeeE6);
    _setDefaultProtocolNotionalFeeE8(initialProtocolNotionalFeeE8);
    _setOnCreationMaxBidAskRefAsymmetryX8(initialOnCreationMaxBidAskRefAsymmetryX8);
    _setBinDistanceLimits(-500_000, 1_000_000);
    _setFeeReceiver(initialFeeReceiver);

    nextPoolIdx = 1;
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
  function maxOwnerProtocolSpreadCapE6() external pure override returns (uint24) {
    return HARD_MAX_PROTOCOL_SPREAD_FEE_E6;
  }

  /// @inheritdoc IMetricOmmPoolFactory
  function maxOwnerAdminSpreadCapE6() external pure override returns (uint24) {
    return HARD_MAX_ADMIN_SPREAD_FEE_E6;
  }

  /// @inheritdoc IMetricOmmPoolFactory
  function maxOwnerProtocolNotionalCapE8() external pure override returns (uint24) {
    return HARD_MAX_PROTOCOL_NOTIONAL_FEE_E8;
  }

  /// @inheritdoc IMetricOmmPoolFactory
  function maxOwnerAdminNotionalCapE8() external pure override returns (uint24) {
    return HARD_MAX_ADMIN_NOTIONAL_FEE_E8;
  }

  /// @inheritdoc IMetricOmmPoolFactoryOwner
  function hardMinBinDistanceLimitE6() external pure override returns (int256) {
    return HARD_MIN_BIN_DISTANCE_LIMIT_E6;
  }

  /// @inheritdoc IMetricOmmPoolFactoryOwner
  function hardMaxBinDistanceLimitE6() external pure override returns (int256) {
    return HARD_MAX_BIN_DISTANCE_LIMIT_E6;
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

    ValidateExtensionsConfig.validateExtensionsConfig(
      params.extensions, params.extensionOrders, params.extensionInitData
    );

    uint24 totalProtocolSpreadFeeE6 =
      params.protocolSpreadFeeE6 < spreadProtocolFeeE6 ? spreadProtocolFeeE6 : params.protocolSpreadFeeE6;
    uint24 totalProtocolNotionalFeeE8 =
      params.protocolNotionalFeeE8 < protocolNotionalFeeE8 ? protocolNotionalFeeE8 : params.protocolNotionalFeeE8;
    uint24 spreadFeeE6 = uint24(uint256(totalProtocolSpreadFeeE6) + uint256(params.adminSpreadFeeE6));
    uint24 notionalFeeE8 = uint24(uint256(totalProtocolNotionalFeeE8) + uint256(params.adminNotionalFeeE8));
    PoolExtensions memory poolExtensions = _poolExtensionsFromArray(params.extensions);

    pool = MetricOmmPoolDeployer(poolDeployer)
      .deploy(
        MetricOmmPoolDeployer.DeployParams({
        // Factory-owned identity (admin, fee destination, extension init, oracle timelock, individual fee
        // legs) is folded into the CREATE2 salt rather than unused pool constructor args; pool init code
        // stays limited to real immutables. The timelock is never a constructor arg, and only the *summed*
        // spread/notional fee reaches the constructor, so both must be salted explicitly or distinct
        // configurations (e.g. differing timelocks, or fee splits with the same total) collide on one address.
        salt: keccak256(
          abi.encode(
            params.salt,
            params.admin,
            params.adminFeeDestination,
            params.extensionInitData,
            params.priceProviderTimelock,
            totalProtocolSpreadFeeE6,
            params.adminSpreadFeeE6,
            totalProtocolNotionalFeeE8,
            params.adminNotionalFeeE8
          )
        ),
        factory: address(this),
        token0: params.token0,
        token1: params.token1,
        priceProvider: params.priceProvider,
        extensions: poolExtensions,
        extensionOrders: params.extensionOrders,
        immutablePriceProvider: immutablePriceProvider,
        token0ScaleMultiplier: token0ScaleMultiplier,
        token1ScaleMultiplier: token1ScaleMultiplier,
        initialScaledAmount0PerShareE18: params.initialScaledAmount0PerE18Shares,
        initialScaledAmount1PerShareE18: params.initialScaledAmount1PerE18Shares,
        minimalOperationalLiquidity: params.minimalOperationalLiquidity,
        spreadFeeE6: spreadFeeE6,
        curBinDistFromProvidedPriceE6: params.curBinDistFromProvidedPriceE6,
        nonNegativeBinStates: nonNegativeBinStates,
        negativeBinStates: negativeBinStates,
        notionalFeeE8: notionalFeeE8,
        bidAskRefAsymmetryX8: params.bidAskRefAsymmetryX8
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
      protocolSpreadFeeE6: totalProtocolSpreadFeeE6,
      adminSpreadFeeE6: params.adminSpreadFeeE6,
      protocolNotionalFeeE8: totalProtocolNotionalFeeE8,
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
      params.initialScaledAmount0PerE18Shares,
      params.initialScaledAmount1PerE18Shares,
      params.minimalOperationalLiquidity,
      totalProtocolSpreadFeeE6,
      totalProtocolNotionalFeeE8,
      params.adminSpreadFeeE6,
      params.adminNotionalFeeE8,
      params.adminFeeDestination,
      params.curBinDistFromProvidedPriceE6,
      params.nonNegativeBinDataArray,
      params.negativeBinDataArray
    );
  }

  // ============ External: fee collection (permissionless) ============

  /// @inheritdoc IMetricOmmPoolFactory
  function collectPoolFees(address pool) external override nonReentrant {
    _collectFees(pool, poolFeeConfig[pool]);
  }

  // ============ External: factory owner ============

  /// @inheritdoc IMetricOmmPoolFactoryOwner
  function setPoolDeployer(address _poolDeployer) external override requiresAuth {
    if (poolDeployer != address(0)) revert PoolDeployerAlreadySet();
    poolDeployer = _poolDeployer;
    emit PoolDeployerSet(_poolDeployer);
  }

  /// @inheritdoc IMetricOmmPoolFactoryOwner
  function setFeeReceiver(address newFeeReceiver) external override requiresAuth {
    _setFeeReceiver(newFeeReceiver);
  }

  /// @inheritdoc IMetricOmmPoolFactoryOwner
  function collectTokens(address token, address to, uint256 amount) external override requiresAuth {
    uint256 balance = IERC20(token).balanceOf(address(this));
    uint256 amountToCollect = amount == 0 ? balance : amount;
    if (amountToCollect > 0) {
      IERC20(token).safeTransfer(to, amountToCollect);
      emit TokensCollected(token, to, amountToCollect);
    }
  }

  /// @inheritdoc IMetricOmmPoolFactoryOwner
  function collectEth(address payable to, uint256 amount) external override requiresAuth {
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
  ) external override requiresAuth {
    _setFeeCaps(
      newMaxProtocolSpreadFeeE6, newMaxAdminSpreadFeeE6, newMaxProtocolNotionalFeeE8, newMaxAdminNotionalFeeE8
    );
  }

  /// @inheritdoc IMetricOmmPoolFactoryOwner
  function setPoolProtocolFee(address pool, uint24 newProtocolSpreadFeeE6, uint24 newProtocolNotionalFeeE8)
    external
    override
    requiresAuth
    nonReentrant
  {
    _updatePoolProtocolFee(pool, newProtocolSpreadFeeE6, newProtocolNotionalFeeE8);
  }

  /// @inheritdoc IMetricOmmPoolFactoryOwner
  function setPoolProtocolFeeBatch(
    address[] calldata pools,
    uint24[] calldata newProtocolSpreadFeeE6s,
    uint24[] calldata newProtocolNotionalFeeE8s
  ) external override requiresAuth nonReentrant {
    if (pools.length != newProtocolSpreadFeeE6s.length || pools.length != newProtocolNotionalFeeE8s.length) {
      revert ArrayLengthMismatch();
    }
    for (uint256 i = 0; i < pools.length; i++) {
      _updatePoolProtocolFee(pools[i], newProtocolSpreadFeeE6s[i], newProtocolNotionalFeeE8s[i]);
    }
  }

  /// @inheritdoc IMetricOmmPoolFactoryOwner
  function setDefaultSpreadProtocolFeeE6(uint24 newFeeE6) external override requiresAuth {
    _setDefaultSpreadProtocolFeeE6(newFeeE6);
  }

  /// @inheritdoc IMetricOmmPoolFactoryOwner
  function setDefaultProtocolNotionalFeeE8(uint24 newFeeE8) external override requiresAuth {
    _setDefaultProtocolNotionalFeeE8(newFeeE8);
  }

  /// @inheritdoc IMetricOmmPoolFactoryOwner
  function setBinDistanceLimits(int128 newMinBinDistanceE6, int128 newMaxBinDistanceE6) external override requiresAuth {
    _setBinDistanceLimits(newMinBinDistanceE6, newMaxBinDistanceE6);
  }

  /// @inheritdoc IMetricOmmPoolFactoryOwner
  function setOnCreationMaxBidAskRefAsymmetryX8(uint16 newMaxX8) external override requiresAuth {
    _setOnCreationMaxBidAskRefAsymmetryX8(newMaxX8);
  }

  /// @inheritdoc IMetricOmmPoolFactoryOwner
  function setPoolBidAskRefAsymmetryX8(address pool, uint16 newBidAskRefAsymmetryX8)
    external
    override
    requiresAuth
    nonReentrant
  {
    _updatePoolBidAskRefAsymmetryX8(pool, newBidAskRefAsymmetryX8);
  }

  /// @inheritdoc IMetricOmmPoolFactoryOwner
  function setPoolBidAskRefAsymmetryX8Batch(address[] calldata pools, uint16[] calldata newBidAskRefAsymmetryX8s)
    external
    override
    requiresAuth
    nonReentrant
  {
    if (pools.length != newBidAskRefAsymmetryX8s.length) revert ArrayLengthMismatch();
    for (uint256 i = 0; i < pools.length; i++) {
      _updatePoolBidAskRefAsymmetryX8(pools[i], newBidAskRefAsymmetryX8s[i]);
    }
  }

  /// @inheritdoc IMetricOmmPoolFactoryOwner
  function protocolPausePool(address pool) external override nonReentrant requiresAuth {
    (uint8 cur,,,,,,) = PoolStateLibrary._slot0(pool);
    if (cur != 0 && cur != 1) revert InvalidPauseTransition(cur, 2);
    IMetricOmmPoolFactoryActions(pool).setPause(2);
  }

  /// @inheritdoc IMetricOmmPoolFactoryOwner
  function protocolUnpausePool(address pool) external override nonReentrant requiresAuth {
    (uint8 cur,,,,,,) = PoolStateLibrary._slot0(pool);
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
    _collectFees(pool, c);

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

    _collectFees(pool, poolFeeConfig[pool]);

    poolAdminFeeDestination[pool] = newAdminFeeDestination;
    emit PoolAdminFeeDestinationUpdated(pool, newAdminFeeDestination);
  }

  /// @inheritdoc IMetricOmmPoolFactoryPoolAdmin
  function setPoolBinAdditionalFees(address pool, int16 bin, uint16 addFeeBuyE6, uint16 addFeeSellE6)
    external
    override
    nonReentrant
    onlyPoolAdmin(pool)
  {
    IMetricOmmPoolFactoryActions(pool).setBinAdditionalFees(bin, addFeeBuyE6, addFeeSellE6);
  }

  /// @inheritdoc IMetricOmmPoolFactoryPoolAdmin
  function pausePool(address pool) external override nonReentrant onlyPoolAdmin(pool) {
    (uint8 cur,,,,,,) = PoolStateLibrary._slot0(pool);
    if (cur != 0) revert InvalidPauseTransition(cur, 1);
    IMetricOmmPoolFactoryActions(pool).setPause(1);
  }

  /// @inheritdoc IMetricOmmPoolFactoryPoolAdmin
  function unpausePool(address pool) external override nonReentrant onlyPoolAdmin(pool) {
    (uint8 cur,,,,,,) = PoolStateLibrary._slot0(pool);
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

  function _setFeeCaps(
    uint24 newMaxProtocolSpreadFeeE6,
    uint24 newMaxAdminSpreadFeeE6,
    uint24 newMaxProtocolNotionalFeeE8,
    uint24 newMaxAdminNotionalFeeE8
  ) private {
    if (
      newMaxProtocolSpreadFeeE6 > HARD_MAX_PROTOCOL_SPREAD_FEE_E6
        || newMaxAdminSpreadFeeE6 > HARD_MAX_ADMIN_SPREAD_FEE_E6
        || newMaxProtocolNotionalFeeE8 > HARD_MAX_PROTOCOL_NOTIONAL_FEE_E8
        || newMaxAdminNotionalFeeE8 > HARD_MAX_ADMIN_NOTIONAL_FEE_E8
    ) {
      revert FeeCapsExceedHardLimit();
    }
    if (
      newMaxProtocolSpreadFeeE6 == maxProtocolSpreadFeeE6 && newMaxAdminSpreadFeeE6 == maxAdminSpreadFeeE6
        && newMaxProtocolNotionalFeeE8 == maxProtocolNotionalFeeE8 && newMaxAdminNotionalFeeE8 == maxAdminNotionalFeeE8
    ) {
      return;
    }

    maxProtocolSpreadFeeE6 = newMaxProtocolSpreadFeeE6;
    maxAdminSpreadFeeE6 = newMaxAdminSpreadFeeE6;
    maxProtocolNotionalFeeE8 = newMaxProtocolNotionalFeeE8;
    maxAdminNotionalFeeE8 = newMaxAdminNotionalFeeE8;

    _setDefaultSpreadProtocolFeeE6(
      spreadProtocolFeeE6 < newMaxProtocolSpreadFeeE6 ? spreadProtocolFeeE6 : newMaxProtocolSpreadFeeE6
    );
    _setDefaultProtocolNotionalFeeE8(
      protocolNotionalFeeE8 < newMaxProtocolNotionalFeeE8 ? protocolNotionalFeeE8 : newMaxProtocolNotionalFeeE8
    );

    emit FeeCapsUpdated(
      newMaxProtocolSpreadFeeE6, newMaxAdminSpreadFeeE6, newMaxProtocolNotionalFeeE8, newMaxAdminNotionalFeeE8
    );
  }

  function _setDefaultSpreadProtocolFeeE6(uint24 newFeeE6) private {
    if (newFeeE6 > maxProtocolSpreadFeeE6) revert ProtocolFeeTooHigh();
    if (newFeeE6 == spreadProtocolFeeE6) return;
    spreadProtocolFeeE6 = newFeeE6;
    emit SpreadProtocolFeeDefaultUpdated(newFeeE6);
  }

  function _setDefaultProtocolNotionalFeeE8(uint24 newFeeE8) private {
    if (newFeeE8 > maxProtocolNotionalFeeE8) revert ProtocolFeeTooHigh();
    if (newFeeE8 == protocolNotionalFeeE8) return;
    protocolNotionalFeeE8 = newFeeE8;
    emit ProtocolNotionalFeeDefaultUpdated(newFeeE8);
  }

  function _setBinDistanceLimits(int128 newMinBinDistanceE6, int128 newMaxBinDistanceE6) private {
    if (
      newMinBinDistanceE6 < HARD_MIN_BIN_DISTANCE_LIMIT_E6 || newMinBinDistanceE6 >= 0
        || newMaxBinDistanceE6 > HARD_MAX_BIN_DISTANCE_LIMIT_E6 || newMaxBinDistanceE6 <= 0
    ) {
      revert InvalidBinDistanceLimits();
    }
    if (newMinBinDistanceE6 == minBinDistanceE6 && newMaxBinDistanceE6 == maxBinDistanceE6) return;
    minBinDistanceE6 = newMinBinDistanceE6;
    maxBinDistanceE6 = newMaxBinDistanceE6;
    emit BinDistanceLimitsUpdated(newMinBinDistanceE6, newMaxBinDistanceE6);
  }

  /// @dev The zero check must precede the unchanged-value early return: storage is `0` during construction,
  ///      so ordering it the other way makes the guard unreachable from the constructor.
  function _setOnCreationMaxBidAskRefAsymmetryX8(uint16 newMaxX8) private {
    if (newMaxX8 == 0) revert BidAskRefAsymmetryTooLow();
    if (newMaxX8 == onCreationMaxBidAskRefAsymmetryX8) return;
    onCreationMaxBidAskRefAsymmetryX8 = newMaxX8;
    emit OnCreationMaxBidAskRefAsymmetryUpdated(newMaxX8);
  }

  function _setFeeReceiver(address newFeeReceiver) private {
    if (newFeeReceiver == address(0)) revert InvalidFeeReceiver();
    if (newFeeReceiver == feeReceiver) return;
    feeReceiver = newFeeReceiver;
    emit FeeReceiverUpdated(newFeeReceiver);
  }

  // ---- Fee collection ----
  function _collectFees(address pool, PoolFeeConfig memory c) private {
    IMetricOmmPoolCollectFees(pool)
      .collectFees(
        c.protocolSpreadFeeE6,
        c.adminSpreadFeeE6,
        c.protocolNotionalFeeE8,
        c.adminNotionalFeeE8,
        poolAdminFeeDestination[pool],
        feeReceiver
      );
  }

  function _updatePoolProtocolFee(address pool, uint24 newProtocolSpreadFeeE6, uint24 newProtocolNotionalFeeE8)
    private
  {
    if (newProtocolSpreadFeeE6 > maxProtocolSpreadFeeE6) revert ProtocolFeeTooHigh();
    if (newProtocolNotionalFeeE8 > maxProtocolNotionalFeeE8) revert ProtocolFeeTooHigh();

    PoolFeeConfig memory c = poolFeeConfig[pool];
    _collectFees(pool, c);

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

  function _updatePoolBidAskRefAsymmetryX8(address pool, uint16 newBidAskRefAsymmetryX8) private {
    if (newBidAskRefAsymmetryX8 == 0) revert BidAskRefAsymmetryTooLow();
    IMetricOmmPoolFactoryActions(pool).setBidAskRefAsymmetryX8(newBidAskRefAsymmetryX8);
    emit PoolBidAskRefAsymmetryUpdated(pool, newBidAskRefAsymmetryX8);
  }

  // ---- `createPool` validation and packing ----

  /// @dev Reverts unless `priceProvider` is non-zero and exposes `IPriceProvider.token0()/token1()` matching `(token0, token1)`.
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
    if (params.protocolSpreadFeeE6 > maxProtocolSpreadFeeE6) revert ProtocolFeeTooHigh();
    if (params.protocolNotionalFeeE8 > maxProtocolNotionalFeeE8) revert ProtocolFeeTooHigh();
    if (params.adminSpreadFeeE6 > maxAdminSpreadFeeE6) revert AdminFeeTooHigh();
    if (params.adminNotionalFeeE8 > maxAdminNotionalFeeE8) revert AdminFeeTooHigh();
    if (params.bidAskRefAsymmetryX8 > onCreationMaxBidAskRefAsymmetryX8) revert BidAskRefAsymmetryTooHigh();
    if (params.bidAskRefAsymmetryX8 == 0) revert BidAskRefAsymmetryTooLow();
    if (
      params.initialScaledAmount0PerE18Shares == 0 || params.initialScaledAmount1PerE18Shares == 0
        || params.initialScaledAmount0PerE18Shares >= type(uint128).max
        || params.initialScaledAmount1PerE18Shares >= type(uint128).max
    ) {
      revert InvalidInitialAmount();
    }
    uint256 minInitialScaled = params.initialScaledAmount0PerE18Shares < params.initialScaledAmount1PerE18Shares
      ? params.initialScaledAmount0PerE18Shares
      : params.initialScaledAmount1PerE18Shares;
    // Require L >= PRECISION * 1e18 / min(P̂). `minInitialScaled > 0` is already enforced above;
    // when the quotient floors to 0, the explicit L > 0 check is the binding bound.
    uint256 minimalRequired = (MINIMAL_OPERATIONAL_LIQUIDITY_PRECISION * 1e18) / minInitialScaled;
    if (params.minimalOperationalLiquidity == 0 || params.minimalOperationalLiquidity < minimalRequired) {
      revert MinimalOperationalLiquidityTooSmallComparedToInitialScaledTokenAmounts(
        params.minimalOperationalLiquidity, minimalRequired == 0 ? 1 : minimalRequired
      );
    }
  }

  /// @dev Single source of truth for packed-bin validation and `BinState` unpacking: two passes per side
  ///      (validate+count, then fill) to avoid extra full-array iterations.
  function _unpackAndValidateBinStates(
    int24 curBinDistFromProvidedPriceE6,
    uint256[] calldata nonNegativeBinDataArray,
    uint256[] calldata negativeBinDataArray
  ) internal view returns (BinState[] memory nonNegativeBinStates, BinState[] memory negativeBinStates) {
    int256 minDistance = minBinDistanceE6;
    int256 maxDistance = maxBinDistanceE6;

    int256 cumulativeDistance = int256(curBinDistFromProvidedPriceE6);
    if (cumulativeDistance > maxDistance || cumulativeDistance < minDistance) {
      revert BinDistanceOutOfRange(0, cumulativeDistance);
    }
    if (nonNegativeBinDataArray.length == 0) revert BinArraysEmpty();

    int256 posBinCount = int256(0);
    for (uint256 i = 0; i < nonNegativeBinDataArray.length; i++) {
      uint256 packed = nonNegativeBinDataArray[i];
      for (uint8 j = 0; j < 5; j++) {
        BinDataLibrary.BinData binData = BinDataLibrary.toBinData(packed, j);
        (uint256 length,,) = binData.unpack();
        if (length == 0) {
          if (j == 0) revert BinLengthZero(posBinCount);
          i = type(uint256).max - 1;
          break;
        }

        cumulativeDistance += length.toInt256();
        if (cumulativeDistance > maxDistance) {
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
          i = type(uint256).max - 1;
          break;
        }

        cumulativeDistance -= length.toInt256();
        if (cumulativeDistance < minDistance) {
          revert BinDistanceOutOfRange(-negBinCount - 1, cumulativeDistance);
        }
        negBinCount++;
      }
    }

    if (posBinCount > MAX_BINS_PER_SIDE || negBinCount > MAX_BINS_PER_SIDE) {
      revert BinIndexRangeExceededInt16();
    }

    nonNegativeBinStates = new BinState[](posBinCount.toUint256());
    negativeBinStates = new BinState[](negBinCount.toUint256());

    {
      uint256 k = 0;
      for (uint256 i = 0; i < nonNegativeBinDataArray.length; i++) {
        uint256 packed = nonNegativeBinDataArray[i];
        for (uint8 j = 0; j < 5; j++) {
          BinDataLibrary.BinData binData = BinDataLibrary.toBinData(packed, j);
          (uint16 length, uint16 buyFee, uint16 sellFee) = binData.unpack();
          if (length == 0) {
            i = type(uint256).max - 1;
            break;
          }
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
          if (length == 0) {
            i = type(uint256).max - 1;
            break;
          }
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
