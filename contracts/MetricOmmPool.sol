// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {MetricReentrancyGuardTransient} from "./utils/MetricReentrancyGuardTransient.sol";
import {PoolActions} from "./libraries/PoolActions.sol";
import {BinBalanceDelta, LiquidityDelta} from "./types/PoolOperation.sol";
import {BinState, BinTotals} from "./types/PoolStorage.sol";
import {SwapMath, ONE_X64} from "./libraries/SwapMath.sol";
import {SignedMath} from "./libraries/SignedMath.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPriceProvider} from "./interfaces/IPriceProvider/IPriceProvider.sol";
import {Slot0Library} from "./libraries/Slot0Library.sol";
import {LiquidityLib} from "./libraries/LiquidityLib.sol";
import {ExtensionCalling} from "./ExtensionCalling.sol";
import {IMetricOmmPool, PoolImmutables} from "./interfaces/IMetricOmmPool/IMetricOmmPool.sol";
import {IMetricOmmPoolActions} from "./interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {IMetricOmmPoolCollectFees} from "./interfaces/IMetricOmmPool/IMetricOmmPoolCollectFees.sol";
import {IMetricOmmPoolFactoryActions} from "./interfaces/IMetricOmmPool/IMetricOmmPoolFactoryActions.sol";
import {PoolExtensions, ExtensionOrders} from "./types/PoolExtensionsConfig.sol";
import {IMetricOmmSwapCallback} from "./interfaces/callbacks/IMetricOmmSwapCallback.sol";
import {Extsload} from "./Extsload.sol";

/**
 * @title MetricOmmPool
 * @notice Oracle-Based OMM Pool with separate bin accounting
 * @dev Layout: immutables, state variables, constructor, modifiers,
 *      external state-changing functions, then internal helpers.
 * @dev Contract uses `Extsload` for all external storage reads.
 * @dev External function order follows `IMetricOmmPool` composition: `IMetricOmmPoolActions`, then `IMetricOmmPoolCollectFees`, then `IMetricOmmPoolFactoryActions`.
 * @dev Contract coupling: storage layout and packing are mirrored by `contracts/libraries/PoolStateLibrary.sol`
 *      for EXTSLOAD-based reads. Any storage reorder or repack is a breaking change for EXTSLOAD readers.
 */
contract MetricOmmPool is IMetricOmmPool, Extsload, MetricReentrancyGuardTransient, ExtensionCalling {
  using SafeCast for uint256;
  using SafeCast for int256;
  using SafeERC20 for IERC20;

  // ============ Immutables ============
  // Note: All immutables are internal; they can be accessed via factory.

  address internal immutable FACTORY;
  address internal immutable TOKEN0;
  address internal immutable TOKEN1;

  /// @notice Multiplier to scale token0 external amounts to internal: 10^(max(18, decimals) - token0.decimals())
  uint256 internal immutable TOKEN_0_SCALE_MULTIPLIER;
  /// @notice Multiplier to scale token1 external amounts to internal: 10^(max(18, decimals) - token1.decimals())
  uint256 internal immutable TOKEN_1_SCALE_MULTIPLIER;

  uint256 internal immutable INITIAL_SCALED_TOKEN_0_PER_SHARE_E18;
  uint256 internal immutable INITIAL_SCALED_TOKEN_1_PER_SHARE_E18;
  uint256 internal immutable MINIMAL_MINTABLE_LIQUIDITY;

  /// @dev If set this is the address of the immutable price provider
  /// @dev If unset the `priceProvider` is the address of the mutable price provider.
  address internal immutable IMMUTABLE_PRICE_PROVIDER;

  int256 internal immutable LOWEST_BIN;
  int256 internal immutable HIGHEST_BIN;

  // ============ State Variables ============

  // +++++++++++ Used when swapping ++++++++++

  // Slot 0 ordering (from left to right):
  //   [3 bytes notionalFeeE8] [3 bytes spreadFeeE6] [3 bytes curBinDistFromProvidedPriceE6]
  //   [13 bytes curPosInBin] [1 byte curBinIdx] [ 1byte pauseLevel]
  /// @dev 0 = active, 1 = paused by admin, 2 = paused by protocol. Transitions enforced by factory.
  uint8 internal pauseLevel;
  int8 internal curBinIdx;
  uint104 internal curPosInBin;
  int24 internal curBinDistFromProvidedPriceE6;
  uint24 internal spreadFeeE6;
  uint24 internal notionalFeeE8;

  // Slot 1 ordering (from left to right):
  //   [16bytes binTotals.scaledToken1] [16bytes binTotals.scaledToken0]
  BinTotals internal binTotals;

  // Slot 2 ordering (from left to right):
  //   [16bytes notionalFeeToken1Scaled] [16bytes notionalFeeToken0Scaled]
  uint128 internal notionalFeeToken0Scaled;
  uint128 internal notionalFeeToken1Scaled;

  // Slot 3 ordering (from left to right):
  //   [16bytes unused] [20 bytes priceProvider]
  /// @dev The price provider address - only used when `IMMUTABLE_PRICE_PROVIDER == address(0)`
  address internal priceProvider;

  mapping(int256 => BinState) internal _binStates;

  // ++++++++++ Unused when swapping ++++++++
  mapping(int256 => uint256) internal _binTotalShares;
  /// @dev Per-bin position shares keyed by `_positionBinKey`.
  mapping(bytes32 => uint256) internal _positionBinShares;

  // ============ Constructor ============
  /// @dev All initial checks MUST be validated before construction at the factory/deployer level.
  constructor(
    address factory,
    address, // admin — encoded for CREATE2 address uniqueness; authority lives in factory poolAdmin
    address, // adminFeeDestination — encoded for CREATE2 address uniqueness; destination lives in factory poolAdminFeeDestination
    address token0,
    address token1,
    address priceProvider_,
    PoolExtensions memory extensions,
    ExtensionOrders memory extensionOrders,
    bool immutablePriceProvider,
    uint256 token0ScaleMultiplier,
    uint256 token1ScaleMultiplier,
    uint256 initialScaledAmount0PerShareE18,
    uint256 initialScaledAmount1PerShareE18,
    uint256 minimalMintableLiquidity,
    uint24 spreadFeeE6_,
    int24 initialCurBinDistFromProvidedPriceE6,
    BinState[] memory nonNegativeBinStates,
    BinState[] memory negativeBinStates,
    uint24 notionalFeeE8_
  ) ExtensionCalling(extensions, extensionOrders) {
    FACTORY = factory;
    TOKEN0 = token0;
    TOKEN1 = token1;

    if (immutablePriceProvider) {
      IMMUTABLE_PRICE_PROVIDER = priceProvider_;
      priceProvider = address(0);
    } else {
      IMMUTABLE_PRICE_PROVIDER = address(0);
      priceProvider = priceProvider_;
    }

    TOKEN_0_SCALE_MULTIPLIER = token0ScaleMultiplier;
    TOKEN_1_SCALE_MULTIPLIER = token1ScaleMultiplier;

    INITIAL_SCALED_TOKEN_0_PER_SHARE_E18 = initialScaledAmount0PerShareE18;
    INITIAL_SCALED_TOKEN_1_PER_SHARE_E18 = initialScaledAmount1PerShareE18;
    MINIMAL_MINTABLE_LIQUIDITY = minimalMintableLiquidity;

    spreadFeeE6 = spreadFeeE6_;
    notionalFeeE8 = notionalFeeE8_;

    curBinDistFromProvidedPriceE6 = initialCurBinDistFromProvidedPriceE6;

    for (uint256 i = 0; i < nonNegativeBinStates.length; i++) {
      // safe because factory caps array length to 128
      // forge-lint: disable-next-line(unsafe-typecast)
      _binStates[int256(i)] = nonNegativeBinStates[i];
    }
    for (uint256 i = 0; i < negativeBinStates.length; i++) {
      // safe because factory caps array length to 128
      // forge-lint: disable-next-line(unsafe-typecast)
      _binStates[-int256(i) - 1] = negativeBinStates[i];
    }

    uint256 nn = nonNegativeBinStates.length;
    uint256 nNeg = negativeBinStates.length;
    // safe because factory caps array length to 128
    // forge-lint: disable-next-line(unsafe-typecast)
    HIGHEST_BIN = nn == 0 ? int256(-1) : int256(nn) - 1;
    // safe because factory caps array length to 128
    // forge-lint: disable-next-line(unsafe-typecast)
    LOWEST_BIN = nNeg == 0 ? int256(0) : -int256(nNeg);
  }

  // ============ Modifiers ============
  modifier onlyFactory() {
    _checkFactory();
    _;
  }

  modifier whenNotPaused() {
    _checkNotPaused();
    _;
  }

  // ============ External: liquidity ============

  /// @inheritdoc IMetricOmmPoolActions
  function addLiquidity(
    address owner,
    uint80 salt,
    LiquidityDelta calldata deltas,
    bytes calldata callbackData,
    bytes calldata extensionData
  ) external nonReentrant(PoolActions.ADD_LIQUIDITY) returns (uint256 amount0Added, uint256 amount1Added) {
    if (deltas.binIdxs.length == 0) return (0, 0);
    if (deltas.binIdxs.length != deltas.shares.length) revert LiquidityDeltaLengthMismatch();
    _beforeAddLiquidity(msg.sender, owner, salt, deltas, extensionData);
    (amount0Added, amount1Added) = LiquidityLib.addLiquidity(
      _liquidityContext(), owner, salt, deltas, callbackData, binTotals, _binStates, _binTotalShares, _positionBinShares
    );
    _afterAddLiquidity(msg.sender, owner, salt, deltas, amount0Added, amount1Added, extensionData);
  }

  /// @inheritdoc IMetricOmmPoolActions
  function removeLiquidity(address owner, uint80 salt, LiquidityDelta calldata deltas, bytes calldata extensionData)
    external
    nonReentrant(PoolActions.REMOVE_LIQUIDITY)
    returns (uint256 amount0Removed, uint256 amount1Removed)
  {
    if (deltas.binIdxs.length == 0) return (0, 0);
    if (deltas.binIdxs.length != deltas.shares.length) revert LiquidityDeltaLengthMismatch();
    if (msg.sender != owner) revert NotPositionOwner();
    _beforeRemoveLiquidity(msg.sender, owner, salt, deltas, extensionData);
    (amount0Removed, amount1Removed) = LiquidityLib.removeLiquidity(
      _liquidityContext(), owner, salt, deltas, binTotals, _binStates, _binTotalShares, _positionBinShares
    );
    _afterRemoveLiquidity(msg.sender, owner, salt, deltas, amount0Removed, amount1Removed, extensionData);
  }

  // ============ External: swap ============

  /// @inheritdoc IMetricOmmPoolActions
  function swap(
    address recipient,
    bool zeroForOne,
    int128 amountSpecified,
    uint128 priceLimitX64,
    bytes calldata callbackData,
    bytes calldata extensionData
  ) external whenNotPaused nonReentrant(PoolActions.SWAP) returns (int128, int128) {
    require(amountSpecified != 0, InvalidAmount());

    uint256 packedSlot0Initial = Slot0Library.loadPackedSlot0();
    (uint128 bidPriceX64, uint128 askPriceX64) = _getBidAndAskPriceX64();

    _beforeSwap(
      msg.sender,
      recipient,
      zeroForOne,
      amountSpecified,
      priceLimitX64,
      packedSlot0Initial,
      bidPriceX64,
      askPriceX64,
      extensionData
    );

    (uint256 midPriceX64, uint256 baseFeeX64) =
      SwapMath.midAndSpreadFeeX64FromBidAsk(uint256(bidPriceX64), uint256(askPriceX64));
    SwapMath.InternalSwapParams memory params =
      SwapMath.InternalSwapParams({midPriceX64: midPriceX64, baseFeeX64: baseFeeX64, priceLimitX64: priceLimitX64});

    (int256 amount0Delta, int256 amount1Delta, uint256 protocolFeeAmount) =
      _executeSwap(zeroForOne, amountSpecified, params);

    if (zeroForOne) {
      if (amount1Delta < 0) {
        // casting to uint256 is safe because amount1Delta is negative and the ammount of tokens in pool is capped by uint128.max
        // forge-lint: disable-next-line(unsafe-typecast)
        transferToken1(recipient, uint256(-amount1Delta));
      }

      uint256 balance0Before = balance0();
      IMetricOmmSwapCallback(msg.sender).metricOmmSwapCallback(amount0Delta, amount1Delta, callbackData);
      // casting to uint256 is safe because amount0Delta is positive and the ammount of tokens in pool is capped by uint128.max
      // forge-lint: disable-next-line(unsafe-typecast)
      if (amount0Delta > 0 && balance0Before + uint256(amount0Delta) > balance0()) {
        revert IncorrectDelta();
      }
    } else {
      if (amount0Delta < 0) {
        // casting to uint256 is safe because amount0Delta is negative and the ammount of tokens in pool is capped by uint128.max
        // forge-lint: disable-next-line(unsafe-typecast)
        transferToken0(recipient, uint256(-amount0Delta));
      }

      uint256 balance1Before = balance1();
      IMetricOmmSwapCallback(msg.sender).metricOmmSwapCallback(amount0Delta, amount1Delta, callbackData);
      // casting to uint256 is safe because amount1Delta is positive and the ammount of tokens in pool is capped by uint128.max
      // forge-lint: disable-next-line(unsafe-typecast)
      if (amount1Delta > 0 && balance1Before + uint256(amount1Delta) > balance1()) {
        revert IncorrectDelta();
      }
    }

    uint256 packedSlot0Final = Slot0Library.loadPackedSlot0();
    _afterSwap(
      msg.sender,
      recipient,
      zeroForOne,
      amountSpecified,
      priceLimitX64,
      packedSlot0Initial,
      packedSlot0Final,
      bidPriceX64,
      askPriceX64,
      amount0Delta.toInt128(),
      amount1Delta.toInt128(),
      protocolFeeAmount,
      extensionData
    );

    emit Swap(
      msg.sender, recipient, amountSpecified > 0, amount0Delta, amount1Delta, curBinIdx, curPosInBin, protocolFeeAmount
    );
    return (amount0Delta.toInt128(), amount1Delta.toInt128());
  }

  // ============ External: swap simulation ============

  /// @inheritdoc IMetricOmmPoolActions
  function simulateSwapAndRevert(
    address recipient,
    bool zeroForOne,
    int128 amountSpecified,
    uint128 priceLimitX64,
    uint128 bidPriceX64,
    uint128 askPriceX64,
    bytes calldata extensionData
  ) external nonReentrant(PoolActions.SIMULATE_SWAP_AND_REVERT) returns (int128, int128) {
    require(amountSpecified != 0, InvalidAmount());
    if (bidPriceX64 >= askPriceX64) revert BidGreaterThanAsk();
    if (bidPriceX64 == 0) revert BidIsZero();

    uint256 packedSlot0Initial = Slot0Library.loadPackedSlot0();

    _beforeSwap(
      msg.sender,
      recipient,
      zeroForOne,
      amountSpecified,
      priceLimitX64,
      packedSlot0Initial,
      bidPriceX64,
      askPriceX64,
      extensionData
    );

    (uint256 midPriceX64, uint256 baseFeeX64) = SwapMath.midAndSpreadFeeX64FromBidAsk(bidPriceX64, askPriceX64);

    SwapMath.InternalSwapParams memory params =
      SwapMath.InternalSwapParams({midPriceX64: midPriceX64, baseFeeX64: baseFeeX64, priceLimitX64: priceLimitX64});

    (int256 amount0Delta, int256 amount1Delta, uint256 protocolFeeAmount) =
      _executeSwap(zeroForOne, amountSpecified, params);

    uint256 packedSlot0Final = Slot0Library.loadPackedSlot0();
    _afterSwap(
      msg.sender,
      recipient,
      zeroForOne,
      amountSpecified,
      priceLimitX64,
      packedSlot0Initial,
      packedSlot0Final,
      bidPriceX64,
      askPriceX64,
      amount0Delta.toInt128(),
      amount1Delta.toInt128(),
      protocolFeeAmount,
      extensionData
    );

    _nonReentrantAfter();
    revert SimulateSwap(amount0Delta, amount1Delta);
  }

  // ============ External: factory / protocol ============

  /// @inheritdoc IMetricOmmPoolCollectFees
  function collectFees(
    uint256 protocolSpreadFeeE6_,
    uint256 adminSpreadFeeE6_,
    uint256 protocolNotionalFeeE8_,
    uint256 adminNotionalFeeE8_,
    address adminFeeDestination_
  ) external onlyFactory nonReentrant(PoolActions.COLLECT_FEES) {
    uint256 spreadSumE6;
    uint256 notionalSumE8;
    unchecked {
      spreadSumE6 = protocolSpreadFeeE6_ + adminSpreadFeeE6_;
      notionalSumE8 = protocolNotionalFeeE8_ + adminNotionalFeeE8_;
      if (spreadSumE6 == 0 && notionalSumE8 == 0) {
        return;
      }
    }

    uint256 notionalFee0AmountScaled = notionalFeeToken0Scaled;
    uint256 notionalFee1AmountScaled = notionalFeeToken1Scaled;

    uint256 surplus0Scaled =
      balance0() * TOKEN_0_SCALE_MULTIPLIER - uint256(binTotals.scaledToken0) - notionalFee0AmountScaled;
    uint256 surplus1Scaled =
      balance1() * TOKEN_1_SCALE_MULTIPLIER - uint256(binTotals.scaledToken1) - notionalFee1AmountScaled;

    unchecked {
      uint256 spreadFee0ToAdminScaled = spreadSumE6 == 0 ? 0 : (surplus0Scaled * adminSpreadFeeE6_) / spreadSumE6;
      uint256 spreadFee1ToAdminScaled = spreadSumE6 == 0 ? 0 : (surplus1Scaled * adminSpreadFeeE6_) / spreadSumE6;

      uint256 spreadFee0ToProtocolScaled = spreadSumE6 == 0 ? 0 : (surplus0Scaled * protocolSpreadFeeE6_) / spreadSumE6;
      uint256 spreadFee1ToProtocolScaled = spreadSumE6 == 0 ? 0 : (surplus1Scaled * protocolSpreadFeeE6_) / spreadSumE6;

      uint256 notionalFee0ToAdminScaled =
        notionalSumE8 == 0 ? 0 : (notionalFee0AmountScaled * adminNotionalFeeE8_) / notionalSumE8;
      uint256 notionalFee1ToAdminScaled =
        notionalSumE8 == 0 ? 0 : (notionalFee1AmountScaled * adminNotionalFeeE8_) / notionalSumE8;

      uint256 notionalFee0ToProtocolScaled = notionalFee0AmountScaled - notionalFee0ToAdminScaled;
      uint256 notionalFee1ToProtocolScaled = notionalFee1AmountScaled - notionalFee1ToAdminScaled;

      uint256 totalFee0ToAdminScaled = spreadFee0ToAdminScaled + notionalFee0ToAdminScaled;
      uint256 totalFee1ToAdminScaled = spreadFee1ToAdminScaled + notionalFee1ToAdminScaled;

      uint256 totalFee0ToProtocolScaled = spreadFee0ToProtocolScaled + notionalFee0ToProtocolScaled;
      uint256 totalFee1ToProtocolScaled = spreadFee1ToProtocolScaled + notionalFee1ToProtocolScaled;

      (uint256 totalFee0ToAdmin, uint256 totalFee1ToAdmin) =
        deltasScaledToExternal(totalFee0ToAdminScaled, totalFee1ToAdminScaled, Math.Rounding.Floor);
      (uint256 totalFee0ToProtocol, uint256 totalFee1ToProtocol) =
        deltasScaledToExternal(totalFee0ToProtocolScaled, totalFee1ToProtocolScaled, Math.Rounding.Floor);

      if (totalFee0ToAdmin > 0) {
        transferToken0(adminFeeDestination_, totalFee0ToAdmin);
      }
      if (totalFee1ToAdmin > 0) {
        transferToken1(adminFeeDestination_, totalFee1ToAdmin);
      }
      if (totalFee0ToProtocol > 0) {
        transferToken0(FACTORY, totalFee0ToProtocol);
      }
      if (totalFee1ToProtocol > 0) {
        transferToken1(FACTORY, totalFee1ToProtocol);
      }

      notionalFeeToken0Scaled = 0;
      notionalFeeToken1Scaled = 0;

      emit ProtocolFeesCollected(totalFee0ToProtocol, totalFee1ToProtocol, totalFee0ToAdmin, totalFee1ToAdmin);
    }
  }

  /// @inheritdoc IMetricOmmPoolFactoryActions
  function setPoolFees(uint24 newSpreadFeeE6, uint24 newNotionalFeeE8)
    external
    onlyFactory
    nonReentrant(PoolActions.SET_POOL_FEES)
  {
    unchecked {
      if (newSpreadFeeE6 != spreadFeeE6) {
        spreadFeeE6 = newSpreadFeeE6;
        emit SpreadFeeUpdated(newSpreadFeeE6);
      }
      if (newNotionalFeeE8 != notionalFeeE8) {
        notionalFeeE8 = newNotionalFeeE8;
        emit NotionalFeeUpdated(newNotionalFeeE8);
      }
    }
  }

  /// @inheritdoc IMetricOmmPoolFactoryActions
  function setPause(uint8 newLevel) external onlyFactory {
    if (newLevel > 2) revert InvalidPauseLevel();
    if (newLevel == pauseLevel) return;
    uint8 prev = pauseLevel;
    pauseLevel = newLevel;
    emit PauseLevelUpdated(prev, newLevel);
  }

  /// @inheritdoc IMetricOmmPoolFactoryActions
  function setBinAdditionalFees(int8 bin, uint16 addFeeBuyE6, uint16 addFeeSellE6)
    external
    onlyFactory
    nonReentrant(PoolActions.SET_BIN_ADDITIONAL_FEES)
  {
    if (bin < LOWEST_BIN || bin > HIGHEST_BIN) revert InvalidBinIndex(bin);
    BinState storage s = _binStates[bin];
    s.addFeeBuyE6 = addFeeBuyE6;
    s.addFeeSellE6 = addFeeSellE6;
    emit BinAdditionalFeesUpdated(bin, addFeeBuyE6, addFeeSellE6);
  }

  /// @inheritdoc IMetricOmmPoolFactoryActions
  function setPriceProvider(address newPriceProvider) external onlyFactory {
    priceProvider = newPriceProvider;
    emit PriceProviderUpdated(newPriceProvider);
  }

  // ============ External: view ============

  /// @inheritdoc IMetricOmmPool
  function inSwap() external view returns (address priceProvider_) {
    if (_currentAction() == PoolActions.SWAP) {
      return _resolvedPriceProvider();
    }
    return address(0);
  }

  /// @inheritdoc IMetricOmmPool
  function getImmutables() external view returns (PoolImmutables memory) {
    return PoolImmutables({
      factory: FACTORY,
      token0: TOKEN0,
      token1: TOKEN1,
      token0ScaleMultiplier: TOKEN_0_SCALE_MULTIPLIER,
      token1ScaleMultiplier: TOKEN_1_SCALE_MULTIPLIER,
      initialScaledToken0PerShareE18: INITIAL_SCALED_TOKEN_0_PER_SHARE_E18,
      initialScaledToken1PerShareE18: INITIAL_SCALED_TOKEN_1_PER_SHARE_E18,
      minimalMintableLiquidity: MINIMAL_MINTABLE_LIQUIDITY,
      immutablePriceProvider: IMMUTABLE_PRICE_PROVIDER,
      lowestBin: LOWEST_BIN,
      highestBin: HIGHEST_BIN,
      extension1: EXTENSION_1,
      extension2: EXTENSION_2,
      extension3: EXTENSION_3,
      extension4: EXTENSION_4,
      extension5: EXTENSION_5,
      extension6: EXTENSION_6,
      extension7: EXTENSION_7,
      beforeAddLiquidityOrder: BEFORE_ADD_LIQUIDITY_ORDER,
      afterAddLiquidityOrder: AFTER_ADD_LIQUIDITY_ORDER,
      beforeRemoveLiquidityOrder: BEFORE_REMOVE_LIQUIDITY_ORDER,
      afterRemoveLiquidityOrder: AFTER_REMOVE_LIQUIDITY_ORDER,
      beforeSwapOrder: BEFORE_SWAP_ORDER,
      afterSwapOrder: AFTER_SWAP_ORDER
    });
  }

  /// @inheritdoc IMetricOmmPool
  function getSellAndBuyPrices()
    external
    nonReentrant(PoolActions.SWAP)
    returns (uint128 sellPriceX64, uint128 buyPriceX64)
  {
    (uint128 bidFromOracleX64, uint128 askFromOracleX64) = _getBidAndAskPriceX64();
    (uint256 midPriceX64, uint256 baseFeeX64) =
      SwapMath.midAndSpreadFeeX64FromBidAsk(uint256(bidFromOracleX64), uint256(askFromOracleX64));

    BinState memory binState = _binStates[curBinIdx];
    uint256 lowerPriceX64 = distanceE6ToPriceX64(curBinDistFromProvidedPriceE6, midPriceX64);
    uint256 upperPriceX64 =
      distanceE6ToPriceX64(_addDistE6(curBinDistFromProvidedPriceE6, binState.lengthE6), midPriceX64);

    uint256 marginalPriceX64 =
      SwapMath.calculatePriceAtBinPosition(lowerPriceX64, upperPriceX64, curPosInBin, Math.Rounding.Floor);

    uint256 buyFeeX64 = baseFeeX64 + Math.mulDiv(binState.addFeeBuyE6, ONE_X64, 1e6);
    uint256 sellFeeX64 = baseFeeX64 + Math.mulDiv(binState.addFeeSellE6, ONE_X64, 1e6);

    uint256 askBeforeNotional = Math.mulDiv(marginalPriceX64, ONE_X64 + buyFeeX64, ONE_X64, Math.Rounding.Ceil);
    uint256 bidAfterSpread = Math.mulDiv(marginalPriceX64, ONE_X64, ONE_X64 + sellFeeX64, Math.Rounding.Floor);

    uint256 nf = notionalFeeE8;
    buyPriceX64 = Math.mulDiv(askBeforeNotional, 1e8, 1e8 - nf, Math.Rounding.Ceil).toUint128();
    sellPriceX64 = Math.mulDiv(bidAfterSpread, 1e8 - nf, 1e8, Math.Rounding.Floor).toUint128();
  }

  // ============ Internal ============

  // ---- Token helpers ----

  /// @notice Get the current balance of token0 held by the pool
  function balance0() internal view returns (uint256) {
    return IERC20(TOKEN0).balanceOf(address(this));
  }

  /// @notice Get the current balance of token1 held by the pool
  function balance1() internal view returns (uint256) {
    return IERC20(TOKEN1).balanceOf(address(this));
  }

  function transferToken0(address to, uint256 amount) internal {
    IERC20(TOKEN0).safeTransfer(to, amount);
  }

  function transferToken1(address to, uint256 amount) internal {
    IERC20(TOKEN1).safeTransfer(to, amount);
  }

  // ---- Math helpers ----

  /// @dev Converts distance-from-mid-price (E6 units) to an absolute price Q64.64.
  /// Result ≤ type(uint128).max when midPriceX64 ≤ type(uint128).max and |distanceValueE6| < 1e6.
  function distanceE6ToPriceX64(int256 distanceValueE6, uint256 midPriceX64) internal pure returns (uint256) {
    unchecked {
      if (distanceValueE6 >= 0) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return Math.mulDiv(midPriceX64, 1e6 + uint256(distanceValueE6), 1e6);
      } else {
        // forge-lint: disable-next-line(unsafe-typecast)
        return Math.mulDiv(midPriceX64, 1e6 - uint256(-distanceValueE6), 1e6);
      }
    }
  }

  function _clampInt256ToInt24(int256 v) internal pure returns (int24) {
    unchecked {
      if (v > type(int24).max) return type(int24).max;
      if (v < type(int24).min) return type(int24).min;
      // casting to int24 is safe because values outside int24 bounds are clamped above.
      // forge-lint: disable-next-line(unsafe-typecast)
      return int24(v);
    }
  }

  function _addDistE6(int256 dist, uint16 len) internal pure returns (int256) {
    unchecked {
      // casting is obiously safe
      return dist + int256(uint256(len));
    }
  }

  /// @notice Convert scaled deltas to external token units
  function deltasScaledToExternal(int256 scaledDeltaAmount0, int256 scaledDeltaAmount1)
    internal
    view
    returns (int256 deltaAmount0, int256 deltaAmount1)
  {
    deltaAmount0 = SignedMath.ceilDiv(scaledDeltaAmount0, TOKEN_0_SCALE_MULTIPLIER);
    deltaAmount1 = SignedMath.ceilDiv(scaledDeltaAmount1, TOKEN_1_SCALE_MULTIPLIER);
  }

  /// @notice Convert scaled deltas to external token units
  function deltasScaledToExternal(uint256 scaledDeltaAmount0, uint256 scaledDeltaAmount1, Math.Rounding rounding)
    internal
    view
    returns (uint256 deltaAmount0, uint256 deltaAmount1)
  {
    if (rounding == Math.Rounding.Ceil) {
      deltaAmount0 = Math.ceilDiv(scaledDeltaAmount0, TOKEN_0_SCALE_MULTIPLIER);
      deltaAmount1 = Math.ceilDiv(scaledDeltaAmount1, TOKEN_1_SCALE_MULTIPLIER);
    } else {
      deltaAmount0 = scaledDeltaAmount0 / TOKEN_0_SCALE_MULTIPLIER;
      deltaAmount1 = scaledDeltaAmount1 / TOKEN_1_SCALE_MULTIPLIER;
    }
  }

  // ---- Shared helpers ----

  function _resolvedPriceProvider() internal view returns (address) {
    address imm = IMMUTABLE_PRICE_PROVIDER;
    if (imm != address(0)) return imm;
    return priceProvider;
  }

  function _checkFactory() internal view {
    if (msg.sender != FACTORY) revert OnlyFactory();
  }

  function _checkNotPaused() internal view {
    if (pauseLevel != 0) revert PoolPaused();
  }

  /// @dev Persists `binState` to `_binStates`. Exists primarily to reduce stack depth in swap paths.
  function _saveBinState(int256 binIdx, BinState memory binState) internal {
    _binStates[binIdx] = binState;
  }

  // ---- Liquidity helpers ----

  function _liquidityContext() internal view returns (LiquidityLib.PoolContext memory) {
    return LiquidityLib.PoolContext({
      token0: TOKEN0,
      token1: TOKEN1,
      token0ScaleMultiplier: TOKEN_0_SCALE_MULTIPLIER,
      token1ScaleMultiplier: TOKEN_1_SCALE_MULTIPLIER,
      initialScaledToken0PerShareE18: INITIAL_SCALED_TOKEN_0_PER_SHARE_E18,
      initialScaledToken1PerShareE18: INITIAL_SCALED_TOKEN_1_PER_SHARE_E18,
      minimalMintableLiquidity: MINIMAL_MINTABLE_LIQUIDITY,
      lowestBin: LOWEST_BIN,
      highestBin: HIGHEST_BIN,
      curBinIdx: curBinIdx,
      curPosInBin: curPosInBin
    });
  }

  // ---- Swap orchestration ----

  function _executeSwap(bool zeroForOne, int256 amountSpecified, SwapMath.InternalSwapParams memory params)
    internal
    returns (int256 amount0Delta, int256 amount1Delta, uint256 protocolFeeAmountScaled)
  {
    unchecked {
      int256 amount0DeltaScaled;
      int256 amount1DeltaScaled;
      uint256 protocolFeeScaled;
      uint256 feeExclusiveInputScaled;

      // Safe: TOKEN_X_SCALE_MULTIPLIER ≤ 10^18, |amountSpecified| ≤ int128.max ⇒ product < 2^196 < uint256.max
      if (amountSpecified > 0) {
        if (zeroForOne) {
          // forge-lint: disable-next-line(unsafe-typecast)
          uint256 amountInScaled = TOKEN_0_SCALE_MULTIPLIER * uint256(amountSpecified);
          uint256 amountOutScaled;
          (amountInScaled, amountOutScaled, protocolFeeScaled) =
            _swapToken0ForToken1SpecifiedInput(amountInScaled, params);
          // forge-lint: disable-next-line(unsafe-typecast)
          amount0DeltaScaled = int256(amountInScaled);
          // forge-lint: disable-next-line(unsafe-typecast)
          amount1DeltaScaled = -int256(amountOutScaled);
        } else {
          // forge-lint: disable-next-line(unsafe-typecast)
          uint256 amountInScaled = TOKEN_1_SCALE_MULTIPLIER * uint256(amountSpecified);
          uint256 amountOutScaled;
          (amountInScaled, amountOutScaled, protocolFeeScaled) =
            _swapToken1ForToken0SpecifiedInput(amountInScaled, params);
          // forge-lint: disable-next-line(unsafe-typecast)
          amount0DeltaScaled = -int256(amountOutScaled);
          // forge-lint: disable-next-line(unsafe-typecast)
          amount1DeltaScaled = int256(amountInScaled);
        }
      } else {
        if (zeroForOne) {
          // forge-lint: disable-next-line(unsafe-typecast)
          uint256 amountOutScaled = TOKEN_1_SCALE_MULTIPLIER * uint256(-amountSpecified);
          uint256 amountInScaled;
          (amountInScaled, amountOutScaled, protocolFeeScaled, feeExclusiveInputScaled) =
            _swapToken0ForToken1SpecifiedOutput(amountOutScaled, params);
          // forge-lint: disable-next-line(unsafe-typecast)
          amount0DeltaScaled = int256(amountInScaled);
          // forge-lint: disable-next-line(unsafe-typecast)
          amount1DeltaScaled = -int256(amountOutScaled);
        } else {
          // forge-lint: disable-next-line(unsafe-typecast)
          uint256 amountOutScaled = TOKEN_0_SCALE_MULTIPLIER * uint256(-amountSpecified);
          uint256 amountInScaled;
          (amountInScaled, amountOutScaled, protocolFeeScaled, feeExclusiveInputScaled) =
            _swapToken1ForToken0SpecifiedOutput(amountOutScaled, params);
          // forge-lint: disable-next-line(unsafe-typecast)
          amount0DeltaScaled = -int256(amountOutScaled);
          // forge-lint: disable-next-line(unsafe-typecast)
          amount1DeltaScaled = int256(amountInScaled);
        }
      }

      // Update bin totals: protocol fee is charged on the input token and does NOT enter bins.
      // For zeroForOne: token0 enters bins (minus protocolFeeScaled), token1 leaves bins.
      // For !zeroForOne: token1 enters bins (minus protocolFeeScaled), token0 leaves bins.
      if (zeroForOne) {
        // casting to uint256 is safe because amount0DeltaScaled is positive in zeroForOne flow.
        // forge-lint: disable-next-line(unsafe-typecast)
        binTotals.scaledToken0 =
          (uint256(binTotals.scaledToken0) + uint256(amount0DeltaScaled) - protocolFeeScaled).toUint128(); // forge-lint: disable-line(unsafe-typecast)
        // casting to uint128/uint256 is safe because bin totals remain bounded by uint128-scaled accounting invariants.
        // forge-lint: disable-next-line(unsafe-typecast)
        binTotals.scaledToken1 = uint128(uint256(binTotals.scaledToken1) - uint256(-amount1DeltaScaled));
      } else {
        // casting to uint256 is safe because amount1DeltaScaled is positive in !zeroForOne flow.
        // forge-lint: disable-next-line(unsafe-typecast)
        binTotals.scaledToken1 =
          (uint256(binTotals.scaledToken1) + uint256(amount1DeltaScaled) - protocolFeeScaled).toUint128(); // forge-lint: disable-line(unsafe-typecast)
        // casting to uint128/uint256 is safe because bin totals remain bounded by uint128-scaled accounting invariants.
        // forge-lint: disable-next-line(unsafe-typecast)
        binTotals.scaledToken0 = uint128(uint256(binTotals.scaledToken0) - uint256(-amount0DeltaScaled));
      }

      if (notionalFeeE8 > 0) {
        if (amountSpecified > 0) {
          // exact in: notional fee on output token
          if (zeroForOne) {
            // safe because amount1DeltaScaled is bounded by uint128 total scaled token1 in bins.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 notionalFeeScaled = uint256(-amount1DeltaScaled) * notionalFeeE8 / 1e8;
            if (notionalFeeScaled > 0) {
              // safe because notionalFeeScaled is bounded by uint128
              // forge-lint: disable-next-line(unsafe-typecast)
              amount1DeltaScaled = amount1DeltaScaled + int256(notionalFeeScaled);
              notionalFeeToken1Scaled = (uint256(notionalFeeToken1Scaled) + notionalFeeScaled).toUint128();
            }
          } else {
            // safe because amount0DeltaScaled is bounded by uint128 total scaled token0 in bins.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 notionalFeeScaled = uint256(-amount0DeltaScaled) * notionalFeeE8 / 1e8;
            if (notionalFeeScaled > 0) {
              // safe because notionalFeeScaled is bounded by uint128
              // forge-lint: disable-next-line(unsafe-typecast)
              amount0DeltaScaled = amount0DeltaScaled + int256(notionalFeeScaled);
              notionalFeeToken0Scaled = (uint256(notionalFeeToken0Scaled) + notionalFeeScaled).toUint128();
            }
          }
        } else {
          // Exact-out: notional fee on pre-bin-fee input notional, added to input token.
          if (zeroForOne) {
            uint256 notionalFeeScaled = feeExclusiveInputScaled * notionalFeeE8 / 1e8;
            if (notionalFeeScaled > 0) {
              // safe because notionalFeeScaled is bounded by uint128
              // forge-lint: disable-next-line(unsafe-typecast)
              amount0DeltaScaled = amount0DeltaScaled + int256(notionalFeeScaled);
              notionalFeeToken0Scaled = (uint256(notionalFeeToken0Scaled) + notionalFeeScaled).toUint128();
            }
          } else {
            uint256 notionalFeeScaled = feeExclusiveInputScaled * notionalFeeE8 / 1e8;
            if (notionalFeeScaled > 0) {
              // safe because notionalFeeScaled is bounded by uint128
              // forge-lint: disable-next-line(unsafe-typecast)
              amount1DeltaScaled = amount1DeltaScaled + int256(notionalFeeScaled);
              notionalFeeToken1Scaled = (uint256(notionalFeeToken1Scaled) + notionalFeeScaled).toUint128();
            }
          }
        }
      }

      (int256 amount0DeltaExternal, int256 amount1DeltaExternal) =
        deltasScaledToExternal(amount0DeltaScaled, amount1DeltaScaled);
      amount0Delta = amount0DeltaExternal;
      amount1Delta = amount1DeltaExternal;
      protocolFeeAmountScaled = protocolFeeScaled;
    }
  }

  function _getBidAndAskPriceX64() internal returns (uint128 bidPriceX64, uint128 askPriceX64) {
    address activePriceProvider = _resolvedPriceProvider();
    try IPriceProvider(activePriceProvider).getBidAndAskPrice() returns (uint128 bid, uint128 ask) {
      if (bid >= ask) revert BidGreaterThanAsk();
      if (bid == 0) revert BidIsZero();
      return (bid, ask);
    } catch (bytes memory reason) {
      revert PriceProviderFailed(reason);
    }
  }

  /// @dev Loads current swap state and computes bin price bounds for current bin.
  /// @param amountSpecifiedScaled Assumes amountSpecifiedScaled <= type(uint128).max.
  function _getInitialStateForSwap(
    bool zeroForOne,
    bool specifiedOut,
    SwapMath.InternalSwapParams memory params,
    uint256 amountSpecifiedScaled
  )
    internal
    view
    returns (
      BinState memory binState,
      SwapMath.SwapState memory state,
      int256 curBinIdxCache,
      uint256 curPosInBinCache,
      int256 curBinDistE6Cache,
      uint256 lowerPriceX64,
      uint256 upperPriceX64,
      uint256 initialPriceX64
    )
  {
    require(amountSpecifiedScaled <= type(uint128).max, AmountScaledExceedsMax());
    state = SwapMath.SwapState({
      amountSpecifiedRemainingScaled: amountSpecifiedScaled,
      amountCalculatedScaled: 0,
      protocolFeeAmountScaled: 0,
      feeExclusiveInputScaled: 0
    });

    curBinIdxCache = curBinIdx;
    curPosInBinCache = curPosInBin;
    curBinDistE6Cache = curBinDistFromProvidedPriceE6;

    binState = _binStates[curBinIdxCache];

    lowerPriceX64 = distanceE6ToPriceX64(curBinDistE6Cache, params.midPriceX64);
    upperPriceX64 = distanceE6ToPriceX64(_addDistE6(curBinDistE6Cache, binState.lengthE6), params.midPriceX64);

    Math.Rounding posRounding = (zeroForOne == specifiedOut) ? Math.Rounding.Ceil : Math.Rounding.Floor;

    initialPriceX64 = SwapMath.calculatePriceAtBinPosition(lowerPriceX64, upperPriceX64, curPosInBinCache, posRounding);
  }

  function _finalizeSwap(int256 curBinIdxCache, uint256 curPosInBinCache, int256 curBinDistE6Cache) internal {
    curBinIdx = curBinIdxCache.toInt8();
    curPosInBin = curPosInBinCache.toUint104();
    curBinDistFromProvidedPriceE6 = curBinDistE6Cache.toInt24();
  }

  // ---- Swap implementations ----

  function _swapToken1ForToken0SpecifiedOutput(uint256 amountOutScaled, SwapMath.InternalSwapParams memory params)
    internal
    returns (uint256, uint256, uint256, uint256)
  {
    unchecked {
      {
        uint256 totalAvailableToken0Scaled = binTotals.scaledToken0;
        if (amountOutScaled > totalAvailableToken0Scaled) {
          amountOutScaled = totalAvailableToken0Scaled;
        }
      }
      (
        BinState memory binState,
        SwapMath.SwapState memory state,
        int256 curBinIdxCache,
        uint256 curPosInBinCache,
        int256 curBinDistE6Cache,
        uint256 lowerPriceX64,
        uint256 upperPriceX64,
        uint256 initialPriceX64
      ) = _getInitialStateForSwap(false, true, params, amountOutScaled);

      if (params.priceLimitX64 <= initialPriceX64) {
        return (0, 0, 0, 0);
      }

      while (state.amountSpecifiedRemainingScaled > 0) {
        bool nonEmptyBin = true;
        if (binState.token0BalanceScaled == 0 || curPosInBinCache >= type(uint104).max) {
          if (params.priceLimitX64 <= upperPriceX64) {
            break;
          }
          nonEmptyBin = false;
        }

        if (nonEmptyBin) {
          int256 delta0Scaled;
          int256 delta1Scaled;
          uint256 binLpFeeAmountScaled;

          (curPosInBinCache, delta0Scaled, delta1Scaled, binLpFeeAmountScaled) = SwapMath.buyToken0InBinSpecifiedOut(
            binState,
            curPosInBinCache,
            state,
            params.baseFeeX64 + Math.mulDiv(binState.addFeeBuyE6, ONE_X64, 1e6),
            lowerPriceX64,
            upperPriceX64,
            params.priceLimitX64,
            spreadFeeE6
          );

          emit BinSwapped(
            curBinIdxCache,
            BinBalanceDelta({delta0Scaled: delta0Scaled, delta1Scaled: delta1Scaled}),
            binLpFeeAmountScaled
          );
          _saveBinState(curBinIdxCache, binState);
        }

        if (curPosInBinCache >= type(uint104).max || !nonEmptyBin) {
          if (curBinIdxCache >= HIGHEST_BIN) {
            break;
          }
          curBinIdxCache++;
          curPosInBinCache = 0;
          curBinDistE6Cache = _clampInt256ToInt24(_addDistE6(int256(curBinDistE6Cache), binState.lengthE6));

          lowerPriceX64 = upperPriceX64;
          binState = _binStates[curBinIdxCache];
          upperPriceX64 = distanceE6ToPriceX64(_addDistE6(curBinDistE6Cache, binState.lengthE6), params.midPriceX64);
        } else {
          break;
        }
      }

      _finalizeSwap(curBinIdxCache, curPosInBinCache, curBinDistE6Cache);

      return (
        state.amountCalculatedScaled,
        amountOutScaled - state.amountSpecifiedRemainingScaled,
        state.protocolFeeAmountScaled,
        state.feeExclusiveInputScaled
      );
    }
  }

  ///@dev Specified input token1, output token0
  ///@return (amountInScaled, amountOutScaled, protocolFeeAmountScaled)
  function _swapToken1ForToken0SpecifiedInput(uint256 amountInScaled, SwapMath.InternalSwapParams memory params)
    internal
    returns (uint256, uint256, uint256)
  {
    unchecked {
      (
        BinState memory binState,
        SwapMath.SwapState memory state,
        int256 curBinIdxCache,
        uint256 curPosInBinCache,
        int256 curBinDistE6Cache,
        uint256 lowerPriceX64,
        uint256 upperPriceX64,
        uint256 initialPriceX64
      ) = _getInitialStateForSwap(false, false, params, amountInScaled);

      if (params.priceLimitX64 <= initialPriceX64) {
        return (0, 0, 0);
      }

      uint256 totalAvailableToken0Scaled = binTotals.scaledToken0;

      while (state.amountSpecifiedRemainingScaled > 0) {
        bool nonEmptyBin = true;
        if (binState.token0BalanceScaled == 0 || curPosInBinCache >= type(uint104).max) {
          if (params.priceLimitX64 != 0 && params.priceLimitX64 <= upperPriceX64) {
            break;
          }
          if (totalAvailableToken0Scaled == 0) {
            break;
          }
          nonEmptyBin = false;
        }

        if (nonEmptyBin) {
          uint256 outToken0AmountScaled;
          int256 delta0Scaled;
          int256 delta1Scaled;
          uint256 binLpFeeAmountScaled;

          (curPosInBinCache, outToken0AmountScaled, delta0Scaled, delta1Scaled, binLpFeeAmountScaled) =
            SwapMath.buyToken0InBinSpecifiedIn(
              binState,
              curPosInBinCache,
              state,
              params.baseFeeX64 + Math.mulDiv(binState.addFeeBuyE6, ONE_X64, 1e6),
              lowerPriceX64,
              upperPriceX64,
              params.priceLimitX64,
              spreadFeeE6
            );

          emit BinSwapped(
            curBinIdxCache,
            BinBalanceDelta({delta0Scaled: delta0Scaled, delta1Scaled: delta1Scaled}),
            binLpFeeAmountScaled
          );
          _saveBinState(curBinIdxCache, binState);
          totalAvailableToken0Scaled -= outToken0AmountScaled;
        }

        if (curPosInBinCache >= type(uint104).max || !nonEmptyBin) {
          if (curBinIdxCache >= HIGHEST_BIN) {
            break;
          }
          curBinIdxCache++;
          curPosInBinCache = 0;
          curBinDistE6Cache = _clampInt256ToInt24(_addDistE6(int256(curBinDistE6Cache), binState.lengthE6));

          lowerPriceX64 = upperPriceX64;
          binState = _binStates[curBinIdxCache];
          upperPriceX64 = distanceE6ToPriceX64(_addDistE6(curBinDistE6Cache, binState.lengthE6), params.midPriceX64);
        } else {
          break;
        }
      }

      _finalizeSwap(curBinIdxCache, curPosInBinCache, curBinDistE6Cache);

      return (
        amountInScaled - state.amountSpecifiedRemainingScaled,
        state.amountCalculatedScaled,
        state.protocolFeeAmountScaled
      );
    }
  }

  ///@dev Input token0, specified output token1
  ///@return (amountInScaled, amountOutScaled, protocolFeeAmountScaled, feeExclusiveInputScaled)
  function _swapToken0ForToken1SpecifiedOutput(uint256 amountOutScaled, SwapMath.InternalSwapParams memory params)
    internal
    returns (uint256, uint256, uint256, uint256)
  {
    unchecked {
      {
        uint256 totalAvailableToken1Scaled = binTotals.scaledToken1;
        if (amountOutScaled > totalAvailableToken1Scaled) {
          amountOutScaled = totalAvailableToken1Scaled;
        }
      }

      (
        BinState memory binState,
        SwapMath.SwapState memory state,
        int256 curBinIdxCache,
        uint256 curPosInBinCache,
        int256 curBinDistE6Cache,
        uint256 lowerPriceX64,
        uint256 upperPriceX64,
        uint256 initialPriceX64
      ) = _getInitialStateForSwap(true, true, params, amountOutScaled);

      if (params.priceLimitX64 >= initialPriceX64) {
        return (0, 0, 0, 0);
      }

      while (state.amountSpecifiedRemainingScaled > 0) {
        bool nonEmptyBin = true;
        if (binState.token1BalanceScaled == 0 || curPosInBinCache == 0) {
          if (params.priceLimitX64 >= lowerPriceX64) {
            break;
          }
          nonEmptyBin = false;
        }

        if (nonEmptyBin) {
          int256 delta0Scaled;
          int256 delta1Scaled;
          uint256 binLpFeeAmountScaled;

          (curPosInBinCache, delta0Scaled, delta1Scaled, binLpFeeAmountScaled) = SwapMath.buyToken1InBinSpecifiedOut(
            binState,
            curPosInBinCache,
            state,
            params.baseFeeX64 + Math.mulDiv(binState.addFeeSellE6, ONE_X64, 1e6),
            lowerPriceX64,
            upperPriceX64,
            params.priceLimitX64,
            spreadFeeE6
          );

          emit BinSwapped(
            curBinIdxCache,
            BinBalanceDelta({delta0Scaled: delta0Scaled, delta1Scaled: delta1Scaled}),
            binLpFeeAmountScaled
          );
          _saveBinState(curBinIdxCache, binState);
        }

        if (curPosInBinCache == 0 || !nonEmptyBin) {
          if (curBinIdxCache <= LOWEST_BIN) {
            break;
          }
          curBinIdxCache--;
          binState = _binStates[curBinIdxCache];
          curPosInBinCache = type(uint104).max;
          curBinDistE6Cache -= int24(uint24(binState.lengthE6));

          upperPriceX64 = lowerPriceX64;
          lowerPriceX64 = distanceE6ToPriceX64(curBinDistE6Cache, params.midPriceX64);
        } else {
          break;
        }
      }

      _finalizeSwap(curBinIdxCache, curPosInBinCache, curBinDistE6Cache);

      return (
        state.amountCalculatedScaled,
        amountOutScaled - state.amountSpecifiedRemainingScaled,
        state.protocolFeeAmountScaled,
        state.feeExclusiveInputScaled
      );
    }
  }

  ///@dev Specified input token0, output token1
  ///@return (amountInScaled, amountOutScaled, protocolFeeAmountScaled)
  function _swapToken0ForToken1SpecifiedInput(uint256 amountInScaled, SwapMath.InternalSwapParams memory params)
    internal
    returns (uint256, uint256, uint256)
  {
    unchecked {
      (
        BinState memory binState,
        SwapMath.SwapState memory state,
        int256 curBinIdxCache,
        uint256 curPosInBinCache,
        int256 curBinDistE6Cache,
        uint256 lowerPriceX64,
        uint256 upperPriceX64,
        uint256 initialPriceX64
      ) = _getInitialStateForSwap(true, false, params, amountInScaled);

      if (params.priceLimitX64 >= initialPriceX64) {
        return (0, 0, 0);
      }

      uint256 totalAvailableToken1Scaled = binTotals.scaledToken1;

      while (state.amountSpecifiedRemainingScaled > 0) {
        bool nonEmptyBin = true;
        if (binState.token1BalanceScaled == 0 || curPosInBinCache == 0) {
          if (params.priceLimitX64 != 0 && params.priceLimitX64 >= lowerPriceX64) {
            break;
          }
          if (totalAvailableToken1Scaled == 0) {
            break;
          }
          nonEmptyBin = false;
        }

        if (nonEmptyBin) {
          uint256 outToken1AmountScaled;
          int256 delta0Scaled;
          int256 delta1Scaled;
          uint256 binLpFeeAmountScaled;

          (curPosInBinCache, outToken1AmountScaled, delta0Scaled, delta1Scaled, binLpFeeAmountScaled) =
            SwapMath.buyToken1InBinSpecifiedIn(
              binState,
              curPosInBinCache,
              state,
              params.baseFeeX64 + Math.mulDiv(binState.addFeeSellE6, ONE_X64, 1e6),
              lowerPriceX64,
              upperPriceX64,
              params.priceLimitX64,
              spreadFeeE6
            );

          emit BinSwapped(
            curBinIdxCache,
            BinBalanceDelta({delta0Scaled: delta0Scaled, delta1Scaled: delta1Scaled}),
            binLpFeeAmountScaled
          );
          _saveBinState(curBinIdxCache, binState);
          totalAvailableToken1Scaled -= outToken1AmountScaled;
        }

        if (curPosInBinCache == 0 || !nonEmptyBin) {
          if (curBinIdxCache <= LOWEST_BIN) {
            break;
          }
          curBinIdxCache--;
          binState = _binStates[curBinIdxCache];
          curPosInBinCache = type(uint104).max;
          curBinDistE6Cache -= int24(uint24(binState.lengthE6));

          upperPriceX64 = lowerPriceX64;
          lowerPriceX64 = distanceE6ToPriceX64(curBinDistE6Cache, params.midPriceX64);
        } else {
          break;
        }
      }

      _finalizeSwap(curBinIdxCache, curPosInBinCache, curBinDistE6Cache);

      return (
        amountInScaled - state.amountSpecifiedRemainingScaled,
        state.amountCalculatedScaled,
        state.protocolFeeAmountScaled
      );
    }
  }
}
