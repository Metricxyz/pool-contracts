// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {MetricReentrancyGuardTransient} from "./utils/MetricReentrancyGuardTransient.sol";
import {PoolActions} from "./libraries/PoolActions.sol";
import {BinBalanceDelta, LiquidityDelta} from "./types/PoolOperation.sol";
import {
  Packed2Int128,
  Packed2Int128Lib,
  Packed2Uint128,
  Packed2Uint128Lib,
  PackedSwapDetailsLib
} from "./types/Packed.sol";
import {BinState, BinTotals} from "./types/PoolStorage.sol";
import {SwapMath, ONE_X64} from "./libraries/SwapMath.sol";
import {FeeMath} from "./libraries/FeeMath.sol";
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
  // Note: All immutables are internal; they are exposed via `getImmutables()`.

  address internal immutable FACTORY;
  address internal immutable TOKEN0;
  address internal immutable TOKEN1;

  /// @notice Multiplier to scale token0 external amounts to internal: 10^(max(18, token0.decimals(), token1.decimals()) - token0.decimals())
  uint256 internal immutable TOKEN_0_SCALE_MULTIPLIER;
  /// @notice Multiplier to scale token1 external amounts to internal: 10^(max(18, token0.decimals(), token1.decimals()) - token1.decimals())
  uint256 internal immutable TOKEN_1_SCALE_MULTIPLIER;

  uint256 internal immutable INITIAL_SCALED_TOKEN_0_PER_SHARE_E18;
  uint256 internal immutable INITIAL_SCALED_TOKEN_1_PER_SHARE_E18;
  uint256 internal immutable MINIMAL_OPERATIONAL_LIQUIDITY;

  /// @dev If set this is the address of the immutable price provider
  /// @dev If unset the `priceProvider` is the address of the mutable price provider.
  address internal immutable IMMUTABLE_PRICE_PROVIDER;

  int256 internal immutable LOWEST_BIN;
  int256 internal immutable HIGHEST_BIN;

  // ============ State Variables ============

  // +++++++++++ Used when swapping ++++++++++

  // Slot 0 ordering (from left to right):
  //   [6 bytes unused] [2 bytes bidAskRefAsymmetryX8] [3 bytes notionalFeeE8] [3 bytes spreadFeeE6]
  //   [3 bytes curBinDistFromProvidedPriceE6] [13 bytes curPosInBin] [1 byte curBinIdx] [1 byte pauseLevel]
  /// @dev 0 = active, 1 = paused by admin, 2 = paused by protocol. Transitions enforced by factory.
  uint8 internal pauseLevel;
  int16 internal curBinIdx; // current bin index
  uint104 internal curPosInBin; // current bin position
  int24 internal curBinDistFromProvidedPriceE6; // current bin distance from provided price
  uint24 internal spreadFeeE6;
  uint24 internal notionalFeeE8;
  uint16 internal bidAskRefAsymmetryX8;

  // Slot 1 ordering (from left to right):
  //   [16bytes binTotals.scaledToken1] [16bytes binTotals.scaledToken0]
  BinTotals internal binTotals;

  // Slot 2 ordering (from left to right):
  //   [16bytes notionalFeeToken1Scaled] [16bytes notionalFeeToken0Scaled]
  uint128 internal notionalFeeToken0Scaled;
  uint128 internal notionalFeeToken1Scaled;

  // Slot 3 ordering (from left to right):
  //   [12 bytes unused] [20 bytes priceProvider]
  /// @dev The price provider address - only used when `IMMUTABLE_PRICE_PROVIDER == address(0)`
  address internal priceProvider;

  mapping(int256 => BinState) internal _binStates;

  // ++++++++++ Unused when swapping ++++++++
  mapping(int256 => uint256) internal _binTotalShares;
  /// @dev Per-bin position shares keyed by `LiquidityLib._positionBinKey`.
  mapping(bytes32 => uint256) internal _positionBinShares;

  uint256 internal pendingAdminFeeToken0Scaled;
  uint256 internal pendingAdminFeeToken1Scaled;
  uint256 internal pendingProtocolFeeToken0Scaled;
  uint256 internal pendingProtocolFeeToken1Scaled;

  // ============ Constructor ============
  /// @dev All initial checks MUST be validated before construction at the factory/deployer level.
  constructor(
    address factory,
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
    uint256 minimalOperationalLiquidity,
    uint24 spreadFeeE6_,
    int24 initialCurBinDistFromProvidedPriceE6,
    BinState[] memory nonNegativeBinStates,
    BinState[] memory negativeBinStates,
    uint24 notionalFeeE8_,
    uint16 bidAskRefAsymmetryX8_
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
    MINIMAL_OPERATIONAL_LIQUIDITY = minimalOperationalLiquidity;

    spreadFeeE6 = spreadFeeE6_;
    notionalFeeE8 = notionalFeeE8_;
    bidAskRefAsymmetryX8 = bidAskRefAsymmetryX8_;

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
      owner, salt, deltas, callbackData, binTotals, _binStates, _binTotalShares, _positionBinShares
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
    bool emptiedCurrentBin;
    (amount0Removed, amount1Removed, emptiedCurrentBin) =
      LiquidityLib.removeLiquidity(owner, salt, deltas, binTotals, _binStates, _binTotalShares, _positionBinShares);
    if (emptiedCurrentBin) {
      curPosInBin = curBinIdx < 0 ? type(uint104).max : 0;
    }
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
    (uint128 bidPriceX64, uint128 askPriceX64, uint128 referencePriceX64) = _getBidAskReferencePriceX64();

    (int256 amount0Delta, int256 amount1Delta, Packed2Uint128 platformFees, uint256 packedSlot0Initial) = _swapCore(
      msg.sender,
      recipient,
      zeroForOne,
      amountSpecified,
      priceLimitX64,
      bidPriceX64,
      askPriceX64,
      referencePriceX64,
      extensionData
    );

    if (zeroForOne) {
      if (amount1Delta < 0) {
        // forge-lint: disable-next-line(unsafe-typecast)
        transferToken1(recipient, uint256(-amount1Delta));
      }

      uint256 balance0Before = balance0();
      IMetricOmmSwapCallback(msg.sender).metricOmmSwapCallback(amount0Delta, amount1Delta, callbackData);
      // forge-lint: disable-next-line(unsafe-typecast)
      if (amount0Delta > 0 && balance0Before + uint256(amount0Delta) > balance0()) {
        revert IncorrectDelta();
      }
    } else {
      if (amount0Delta < 0) {
        // forge-lint: disable-next-line(unsafe-typecast)
        transferToken0(recipient, uint256(-amount0Delta));
      }

      uint256 balance1Before = balance1();
      IMetricOmmSwapCallback(msg.sender).metricOmmSwapCallback(amount0Delta, amount1Delta, callbackData);
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
      referencePriceX64,
      amount0Delta.toInt128(),
      amount1Delta.toInt128(),
      platformFees.sum(),
      extensionData
    );

    emit Swap(
      msg.sender,
      recipient,
      PackedSwapDetailsLib.pack(amountSpecified > 0, curBinIdx, curPosInBin),
      // `_afterSwap` above already narrowed both with a checked cast, so an out-of-range value has reverted before this point.
      // forge-lint: disable-next-line(unsafe-typecast)
      Packed2Int128Lib.pack(int128(amount0Delta), int128(amount1Delta)),
      platformFees
    );
    return (amount0Delta.toInt128(), amount1Delta.toInt128());
  }

  // ============ External: swap simulation ============

  /// @inheritdoc IMetricOmmPoolActions
  function simulateSwapAndRevert(
    address sender,
    address recipient,
    bool zeroForOne,
    int128 amountSpecified,
    uint128 priceLimitX64,
    uint128 bidPriceX64,
    uint128 askPriceX64,
    uint128 referencePriceX64,
    bytes calldata extensionData
  ) external nonReentrant(PoolActions.SIMULATE_SWAP_AND_REVERT) returns (int128, int128) {
    _validateBidAskReferencePriceX64(bidPriceX64, askPriceX64, referencePriceX64);

    (int256 amount0Delta, int256 amount1Delta, Packed2Uint128 platformFees, uint256 packedSlot0Initial) = _swapCore(
      sender,
      recipient,
      zeroForOne,
      amountSpecified,
      priceLimitX64,
      bidPriceX64,
      askPriceX64,
      referencePriceX64,
      extensionData
    );

    uint256 packedSlot0Final = Slot0Library.loadPackedSlot0();
    _afterSwap(
      sender,
      recipient,
      zeroForOne,
      amountSpecified,
      priceLimitX64,
      packedSlot0Initial,
      packedSlot0Final,
      bidPriceX64,
      askPriceX64,
      referencePriceX64,
      amount0Delta.toInt128(),
      amount1Delta.toInt128(),
      platformFees.sum(),
      extensionData
    );

    revert SimulateSwap(amount0Delta, amount1Delta);
  }

  // ============ External: factory / protocol ============

  /// @inheritdoc IMetricOmmPoolCollectFees
  function collectFees(
    uint256 protocolSpreadFeeE6,
    uint256 adminSpreadFeeE6,
    uint256 protocolNotionalFeeE8,
    uint256 adminNotionalFeeE8,
    address adminFeeDestination,
    address protocolFeeDestination
  ) external onlyFactory nonReentrant(PoolActions.COLLECT_FEES) {
    (
      uint256 updatedAdminFeeToken0Scaled,
      uint256 updatedAdminFeeToken1Scaled,
      uint256 updatedProtocolFeeToken0Scaled,
      uint256 updatedProtocolFeeToken1Scaled
    ) = _calculateUpdatedPendingFees(protocolSpreadFeeE6, adminSpreadFeeE6, protocolNotionalFeeE8, adminNotionalFeeE8);

    uint256 paidAdmin0;
    uint256 paidAdmin1;
    uint256 paidProtocol0;
    uint256 paidProtocol1;
    (pendingAdminFeeToken0Scaled, paidAdmin0) =
      _payPendingFee(TOKEN0, adminFeeDestination, updatedAdminFeeToken0Scaled, TOKEN_0_SCALE_MULTIPLIER);
    (pendingAdminFeeToken1Scaled, paidAdmin1) =
      _payPendingFee(TOKEN1, adminFeeDestination, updatedAdminFeeToken1Scaled, TOKEN_1_SCALE_MULTIPLIER);
    (pendingProtocolFeeToken0Scaled, paidProtocol0) =
      _payPendingFee(TOKEN0, protocolFeeDestination, updatedProtocolFeeToken0Scaled, TOKEN_0_SCALE_MULTIPLIER);
    (pendingProtocolFeeToken1Scaled, paidProtocol1) =
      _payPendingFee(TOKEN1, protocolFeeDestination, updatedProtocolFeeToken1Scaled, TOKEN_1_SCALE_MULTIPLIER);

    emit ProtocolFeesCollected(paidProtocol0, paidProtocol1, paidAdmin0, paidAdmin1);
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
  function setBidAskRefAsymmetryX8(uint16 newBidAskRefAsymmetryX8)
    external
    onlyFactory
    nonReentrant(PoolActions.SET_BID_ASK_REF_ASYMMETRY_X8)
  {
    if (newBidAskRefAsymmetryX8 != bidAskRefAsymmetryX8) {
      bidAskRefAsymmetryX8 = newBidAskRefAsymmetryX8;
      emit BidAskRefAsymmetryUpdated(newBidAskRefAsymmetryX8);
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
  function setBinAdditionalFees(int16 bin, uint16 addFeeBuyE6, uint16 addFeeSellE6)
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
      minimalOperationalLiquidity: MINIMAL_OPERATIONAL_LIQUIDITY,
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
    (uint128 bidFromOracleX64, uint128 askFromOracleX64, uint128 referenceFromOracleX64) = _getBidAskReferencePriceX64();
    (uint256 baseBuyFeeX64, uint256 baseSellFeeX64) = SwapMath.buySellBaseFeesX64FromBidAskAndReference(
      uint256(bidFromOracleX64), uint256(askFromOracleX64), uint256(referenceFromOracleX64)
    );
    uint256 referencePriceX64 = uint256(referenceFromOracleX64);

    BinState memory binState = _binStates[curBinIdx];
    uint256 lowerPriceX64 = distanceE6ToPriceX64(curBinDistFromProvidedPriceE6, referencePriceX64);
    uint256 upperPriceX64 =
      distanceE6ToPriceX64(_addDistE6(curBinDistFromProvidedPriceE6, binState.lengthE6), referencePriceX64);

    uint256 marginalPriceX64 =
      SwapMath.calculatePriceAtBinPosition(lowerPriceX64, upperPriceX64, curPosInBin, Math.Rounding.Floor);

    uint256 notionalFeeX64 = FeeMath._notionalFeeX64(notionalFeeE8);
    buyPriceX64 = FeeMath.effectivePriceX64(
        marginalPriceX64, FeeMath.binTotalFeeX64(baseBuyFeeX64, binState.addFeeBuyE6, notionalFeeX64), false
      ).toUint128();
    sellPriceX64 = FeeMath.effectivePriceX64(
        marginalPriceX64, FeeMath.binTotalFeeX64(baseSellFeeX64, binState.addFeeSellE6, notionalFeeX64), true
      ).toUint128();
  }

  // ============ Internal ============

  function _calculateUpdatedPendingFees(
    uint256 protocolSpreadFeeE6,
    uint256 adminSpreadFeeE6,
    uint256 protocolNotionalFeeE8,
    uint256 adminNotionalFeeE8
  )
    private
    returns (
      uint256 updatedAdminFeeToken0Scaled,
      uint256 updatedAdminFeeToken1Scaled,
      uint256 updatedProtocolFeeToken0Scaled,
      uint256 updatedProtocolFeeToken1Scaled
    )
  {
    uint256 spreadSumE6;
    uint256 notionalSumE8;
    unchecked {
      spreadSumE6 = protocolSpreadFeeE6 + adminSpreadFeeE6;
      notionalSumE8 = protocolNotionalFeeE8 + adminNotionalFeeE8;

      updatedAdminFeeToken0Scaled = pendingAdminFeeToken0Scaled;
      updatedAdminFeeToken1Scaled = pendingAdminFeeToken1Scaled;
      updatedProtocolFeeToken0Scaled = pendingProtocolFeeToken0Scaled;
      updatedProtocolFeeToken1Scaled = pendingProtocolFeeToken1Scaled;
    }
    if (spreadSumE6 != 0) {
      //// checked block start - just sanity check for underflow
      uint256 surplus0Scaled = balance0() * TOKEN_0_SCALE_MULTIPLIER - uint256(binTotals.scaledToken0)
        - notionalFeeToken0Scaled - updatedAdminFeeToken0Scaled - updatedProtocolFeeToken0Scaled;
      uint256 surplus1Scaled = balance1() * TOKEN_1_SCALE_MULTIPLIER - uint256(binTotals.scaledToken1)
        - notionalFeeToken1Scaled - updatedAdminFeeToken1Scaled - updatedProtocolFeeToken1Scaled;
      //// checked block end
      unchecked {
        uint256 admin0Scaled = surplus0Scaled * adminSpreadFeeE6 / spreadSumE6;
        uint256 admin1Scaled = surplus1Scaled * adminSpreadFeeE6 / spreadSumE6;
        updatedAdminFeeToken0Scaled += admin0Scaled;
        updatedAdminFeeToken1Scaled += admin1Scaled;
        updatedProtocolFeeToken0Scaled += surplus0Scaled - admin0Scaled;
        updatedProtocolFeeToken1Scaled += surplus1Scaled - admin1Scaled;
      }
    }
    unchecked {
      if (notionalSumE8 != 0) {
        uint256 admin0Scaled = notionalFeeToken0Scaled * adminNotionalFeeE8 / notionalSumE8;
        uint256 admin1Scaled = notionalFeeToken1Scaled * adminNotionalFeeE8 / notionalSumE8;
        updatedAdminFeeToken0Scaled += admin0Scaled;
        updatedAdminFeeToken1Scaled += admin1Scaled;
        updatedProtocolFeeToken0Scaled += uint256(notionalFeeToken0Scaled) - admin0Scaled;
        updatedProtocolFeeToken1Scaled += uint256(notionalFeeToken1Scaled) - admin1Scaled;
        notionalFeeToken0Scaled = 0;
        notionalFeeToken1Scaled = 0;
      }
    }
  }

  function _payPendingFee(address token, address destination, uint256 pendingScaled, uint256 scaleMultiplier)
    private
    returns (uint256 remainingScaled, uint256 paid)
  {
    uint256 amount = pendingScaled / scaleMultiplier;
    if (amount == 0) return (pendingScaled, 0);

    if (IERC20(token).trySafeTransfer(destination, amount)) {
      return (pendingScaled - amount * scaleMultiplier, amount);
    }
    emit FeeTransferFailed(token, destination, amount);
    return (pendingScaled, 0);
  }

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

  /// @dev Converts distance-from-reference-price (E6 units) to an absolute price Q64.64:
  /// `referencePriceX64 * (1e6 + distanceValueE6) / 1e6`. Requires `distanceValueE6 > -1e6`; the negative branch computes `1e6 - |distanceValueE6|` unchecked.
  function distanceE6ToPriceX64(int256 distanceValueE6, uint256 referencePriceX64) internal pure returns (uint256) {
    unchecked {
      if (distanceValueE6 >= 0) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return Math.mulDiv(referencePriceX64, 1e6 + uint256(distanceValueE6), 1e6);
      } else {
        // forge-lint: disable-next-line(unsafe-typecast)
        return Math.mulDiv(referencePriceX64, 1e6 - uint256(-distanceValueE6), 1e6);
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
      // casting is safe because len is uint16
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

  // ---- Swap orchestration ----

  function _executeSwap(
    bool zeroForOne,
    int256 amountSpecified,
    uint256 referencePriceX64,
    uint256 baseFeeX64,
    uint256 priceLimitX64
  ) internal returns (int256 amount0DeltaScaled, int256 amount1DeltaScaled, Packed2Uint128 platformFees) {
    unchecked {
      // Safe while both tokens have ≤ 18 decimals: TOKEN_X_SCALE_MULTIPLIER ≤ 10^18 and |amountSpecified| ≤ int128.max ⇒ product < 2^188
      // forge-lint: disable-next-line(unsafe-typecast)
      uint256 amountSpecifiedScaled = amountSpecified > 0
        // forge-lint: disable-next-line(unsafe-typecast)
        ? (zeroForOne ? TOKEN_0_SCALE_MULTIPLIER : TOKEN_1_SCALE_MULTIPLIER) * uint256(amountSpecified)
        // forge-lint: disable-next-line(unsafe-typecast)
        : (zeroForOne ? TOKEN_1_SCALE_MULTIPLIER : TOKEN_0_SCALE_MULTIPLIER) * uint256(-amountSpecified);

      (amount0DeltaScaled, amount1DeltaScaled, platformFees) = _swapAcrossBins(
        zeroForOne, amountSpecified <= 0, amountSpecifiedScaled, referencePriceX64, baseFeeX64, priceLimitX64
      );
      uint256 platformNotionalFeeScaled = platformFees.low();

      // Update bin totals: the platform spread fee and the notional fee are both carved from the input
      // token and do NOT enter bins.
      // For zeroForOne: token0 enters bins (minus both fees), token1 leaves bins.
      // For !zeroForOne: token1 enters bins (minus both fees), token0 leaves bins.
      uint256 totalPlatformFeeScaled = platformFees.sum();
      if (zeroForOne) {
        // casting to uint256 is safe because amount0DeltaScaled is positive in zeroForOne flow.
        // forge-lint: disable-next-line(unsafe-typecast)
        binTotals.scaledToken0 =
          (uint256(binTotals.scaledToken0) + uint256(amount0DeltaScaled) - totalPlatformFeeScaled).toUint128(); // forge-lint: disable-line(unsafe-typecast)
        // casting to uint128/uint256 is safe because bin totals remain bounded by uint128-scaled accounting invariants.
        // forge-lint: disable-next-line(unsafe-typecast)
        binTotals.scaledToken1 = uint128(uint256(binTotals.scaledToken1) - uint256(-amount1DeltaScaled));
      } else {
        // casting to uint256 is safe because amount1DeltaScaled is positive in !zeroForOne flow.
        // forge-lint: disable-next-line(unsafe-typecast)
        binTotals.scaledToken1 =
          (uint256(binTotals.scaledToken1) + uint256(amount1DeltaScaled) - totalPlatformFeeScaled).toUint128(); // forge-lint: disable-line(unsafe-typecast)
        // casting to uint128/uint256 is safe because bin totals remain bounded by uint128-scaled accounting invariants.
        // forge-lint: disable-next-line(unsafe-typecast)
        binTotals.scaledToken0 = uint128(uint256(binTotals.scaledToken0) - uint256(-amount0DeltaScaled));
      }

      if (platformNotionalFeeScaled > 0) {
        if (zeroForOne) {
          notionalFeeToken0Scaled = (uint256(notionalFeeToken0Scaled) + platformNotionalFeeScaled).toUint128();
        } else {
          notionalFeeToken1Scaled = (uint256(notionalFeeToken1Scaled) + platformNotionalFeeScaled).toUint128();
        }
      }
    }
  }

  function _getBidAskReferencePriceX64()
    internal
    returns (uint128 bidPriceX64, uint128 askPriceX64, uint128 referencePriceX64)
  {
    address activePriceProvider = _resolvedPriceProvider();
    try IPriceProvider(activePriceProvider).getQuote() returns (uint128 bid, uint128 ask, uint128 referencePrice) {
      _validateBidAskReferencePriceX64(bid, ask, referencePrice);
      return (bid, ask, referencePrice);
    } catch (bytes memory reason) {
      revert PriceProviderFailed(reason);
    }
  }

  /// @dev Reverts unless `bid < ask` and `ref` lies within `[bid, ask]` (inclusive).
  ///      When `bidAskRefAsymmetryX8 == type(uint16).max`, a reference on `bid`/`ask` is allowed (waives that side's base fee).
  ///      Otherwise enforces `1/M <= r1/r2 <= M` with `r1 = ref/bid - 1`, `r2 = ask/ref - 1`, `M = 1 + m` (`m` in X8);
  function _validateBidAskReferencePriceX64(uint256 bidX64, uint256 askX64, uint256 refX64) internal view {
    if (bidX64 >= askX64) revert BidGreaterThanAsk();
    if (bidX64 == 0) revert BidIsZero();
    if (refX64 < bidX64 || refX64 > askX64) revert ReferencePriceOutOfRange();

    uint256 mX8 = bidAskRefAsymmetryX8;
    if (mX8 == type(uint16).max) return;
    if (refX64 == bidX64 || refX64 == askX64) revert BidAskRefAsymmetryOutOfBounds();

    uint256 M_X64 = ONE_X64 + (mX8 << 56);
    uint256 refMinusBid = refX64 - bidX64;
    uint256 askMinusRef = askX64 - refX64;

    uint256 numerator = refMinusBid * refX64;
    uint256 denominator = bidX64 * askMinusRef;

    if (
      numerator < Math.mulDiv(denominator, ONE_X64, M_X64, Math.Rounding.Ceil)
        || denominator < Math.mulDiv(numerator, ONE_X64, M_X64, Math.Rounding.Ceil)
    ) {
      revert BidAskRefAsymmetryOutOfBounds();
    }
  }

  /// @dev Shared swap execution: runs `beforeSwap`, computes fee/reference price, executes the swap, and enforces
  ///      the non-zero-delta invariant. Callers own price validation, token settlement, and `afterSwap`.
  /// @param sender Forwarded to `beforeSwap` as-is; `swap` passes `msg.sender`, `simulateSwapAndRevert` may pass any address.
  function _swapCore(
    address sender,
    address recipient,
    bool zeroForOne,
    int128 amountSpecified,
    uint128 priceLimitX64,
    uint128 bidPriceX64,
    uint128 askPriceX64,
    uint128 referencePriceX64,
    bytes calldata extensionData
  )
    internal
    returns (int256 amount0Delta, int256 amount1Delta, Packed2Uint128 platformFees, uint256 packedSlot0Initial)
  {
    require(amountSpecified != 0, InvalidAmount());

    packedSlot0Initial = Slot0Library.loadPackedSlot0();

    _beforeSwap(
      sender,
      recipient,
      zeroForOne,
      amountSpecified,
      priceLimitX64,
      packedSlot0Initial,
      bidPriceX64,
      askPriceX64,
      referencePriceX64,
      extensionData
    );

    uint256 baseFeeX64 = zeroForOne
      ? SwapMath.sellBaseFeeX64FromBidAndReference(uint256(bidPriceX64), uint256(referencePriceX64))
      : SwapMath.buyBaseFeeX64FromAskAndReference(uint256(askPriceX64), uint256(referencePriceX64));

    (int256 amount0DeltaScaled, int256 amount1DeltaScaled, Packed2Uint128 fees) =
      _executeSwap(zeroForOne, amountSpecified, uint256(referencePriceX64), baseFeeX64, priceLimitX64);
    platformFees = fees;

    (amount0Delta, amount1Delta) = deltasScaledToExternal(amount0DeltaScaled, amount1DeltaScaled);
    require(amount0Delta != 0 && amount1Delta != 0, FinalAmountIsZero());
  }

  /// @dev Loads current swap state and computes bin price bounds for current bin.
  /// @param amountSpecifiedScaled Reverts `AmountScaledExceedsMax` unless `<= type(uint128).max`.
  function _getInitialStateForSwap(uint256 referencePriceX64, uint256 amountSpecifiedScaled)
    internal
    view
    returns (
      BinState memory binState,
      SwapMath.SwapState memory state,
      int256 curBinIdxCache,
      uint256 curPosInBinCache,
      int256 curBinDistE6Cache,
      uint256 lowerReferencePriceX64,
      uint256 upperReferencePriceX64
    )
  {
    require(amountSpecifiedScaled <= type(uint128).max, AmountScaledExceedsMax());
    state = SwapMath.SwapState({amountSpecifiedRemainingScaled: amountSpecifiedScaled, amountCalculatedScaled: 0});

    curBinIdxCache = curBinIdx;
    curPosInBinCache = curPosInBin;
    curBinDistE6Cache = curBinDistFromProvidedPriceE6;

    binState = _binStates[curBinIdxCache];

    lowerReferencePriceX64 = distanceE6ToPriceX64(curBinDistE6Cache, referencePriceX64);
    upperReferencePriceX64 = distanceE6ToPriceX64(_addDistE6(curBinDistE6Cache, binState.lengthE6), referencePriceX64);
  }

  function _finalizeSwap(int256 curBinIdxCache, uint256 curPosInBinCache, int256 curBinDistE6Cache) internal {
    curBinIdx = curBinIdxCache.toInt16();
    curPosInBin = curPosInBinCache.toUint104();
    curBinDistFromProvidedPriceE6 = curBinDistE6Cache.toInt24();
  }

  // ---- Swap implementations ----

  /// @dev Cross-bin swap loop parameterized by direction (`zeroForOne`) and exact-out (`specifiedOut`).
  /// @return amount0DeltaScaled Net scaled token0 flow (positive = into the pool).
  /// @return amount1DeltaScaled Net scaled token1 flow (positive = into the pool).
  /// @return platformFees Platform (protocol + admin) fee legs, packed: `high` = spread, `low` = notional.
  function _swapAcrossBins(
    bool zeroForOne,
    bool specifiedOut,
    uint256 amountSpecifiedScaled,
    uint256 referencePriceX64,
    uint256 baseFeeX64,
    uint256 priceLimitX64
  ) internal returns (int256 amount0DeltaScaled, int256 amount1DeltaScaled, Packed2Uint128 platformFees) {
    unchecked {
      if (specifiedOut) {
        uint256 availableOutScaled = zeroForOne ? binTotals.scaledToken1 : binTotals.scaledToken0;
        if (amountSpecifiedScaled > availableOutScaled) {
          amountSpecifiedScaled = availableOutScaled;
        }
      }

      (
        BinState memory binState,
        SwapMath.SwapState memory state,
        int256 curBinIdxCache,
        uint256 curPosInBinCache,
        int256 curBinDistE6Cache,
        uint256 lowerReferencePriceX64,
        uint256 upperReferencePriceX64
      ) = _getInitialStateForSwap(referencePriceX64, amountSpecifiedScaled);

      uint256 notionalFeeX64 = FeeMath._notionalFeeX64(notionalFeeE8);

      // Exact-in only: remaining output liquidity across bins (exact-out caps up front).
      uint256 totalAvailableOutScaled =
        specifiedOut ? 0 : (zeroForOne ? binTotals.scaledToken1 : binTotals.scaledToken0);

      while (state.amountSpecifiedRemainingScaled > 0) {
        uint256 binTotalFeeX64 = FeeMath.binTotalFeeX64(
          baseFeeX64, zeroForOne ? binState.addFeeSellE6 : binState.addFeeBuyE6, notionalFeeX64
        );
        uint256 effLowerX64 = FeeMath.effectivePriceX64(lowerReferencePriceX64, binTotalFeeX64, zeroForOne);
        uint256 effUpperX64 = FeeMath.effectivePriceX64(upperReferencePriceX64, binTotalFeeX64, zeroForOne);

        bool nonEmptyBin = true;
        if (zeroForOne) {
          if (binState.token1BalanceScaled == 0 || curPosInBinCache == 0) {
            if (specifiedOut) {
              if (priceLimitX64 >= effLowerX64) break;
            } else {
              if (priceLimitX64 != 0 && priceLimitX64 >= effLowerX64) break;
              if (totalAvailableOutScaled == 0) break;
            }
            nonEmptyBin = false;
          }
        } else if (binState.token0BalanceScaled == 0 || curPosInBinCache >= type(uint104).max) {
          if (specifiedOut) {
            if (priceLimitX64 <= effUpperX64) break;
          } else {
            if (priceLimitX64 != 0 && priceLimitX64 <= effUpperX64) break;
            if (totalAvailableOutScaled == 0) break;
          }
          nonEmptyBin = false;
        }

        if (nonEmptyBin) {
          uint256 totalFeeOfGrossX64 = FeeMath.totalFeeOfGrossX64(binTotalFeeX64);
          uint256 platformPartX64 = FeeMath.platformPartOfTotalFeeX64(binTotalFeeX64, notionalFeeX64, spreadFeeE6);
          int256 binDelta0Scaled;
          int256 binDelta1Scaled;
          uint256 outAmountScaled;
          uint256 platformFeeScaled;
          uint256 lpFeeAmountScaled;

          if (zeroForOne) {
            if (specifiedOut) {
              (curPosInBinCache, binDelta0Scaled, binDelta1Scaled, platformFeeScaled, lpFeeAmountScaled) =
                SwapMath.buyToken1InBinSpecifiedOut(
                  binState,
                  curPosInBinCache,
                  state,
                  totalFeeOfGrossX64,
                  platformPartX64,
                  effLowerX64,
                  effUpperX64,
                  priceLimitX64
                );
            } else {
              (
                curPosInBinCache,
                outAmountScaled,
                binDelta0Scaled,
                binDelta1Scaled,
                platformFeeScaled,
                lpFeeAmountScaled
              ) =
                SwapMath.buyToken1InBinSpecifiedIn(
                  binState,
                  curPosInBinCache,
                  state,
                  totalFeeOfGrossX64,
                  platformPartX64,
                  effLowerX64,
                  effUpperX64,
                  priceLimitX64
                );
              totalAvailableOutScaled -= outAmountScaled;
            }
          } else if (specifiedOut) {
            (curPosInBinCache, binDelta0Scaled, binDelta1Scaled, platformFeeScaled, lpFeeAmountScaled) =
              SwapMath.buyToken0InBinSpecifiedOut(
                binState,
                curPosInBinCache,
                state,
                totalFeeOfGrossX64,
                platformPartX64,
                effLowerX64,
                effUpperX64,
                priceLimitX64
              );
          } else {
            (
              curPosInBinCache, outAmountScaled, binDelta0Scaled, binDelta1Scaled, platformFeeScaled, lpFeeAmountScaled
            ) =
              SwapMath.buyToken0InBinSpecifiedIn(
                binState,
                curPosInBinCache,
                state,
                totalFeeOfGrossX64,
                platformPartX64,
                effLowerX64,
                effUpperX64,
                priceLimitX64
              );
            totalAvailableOutScaled -= outAmountScaled;
          }

          if (binDelta0Scaled != 0 || binDelta1Scaled != 0) {
            {
              uint256 notionalLegScaled =
                FeeMath.notionalPartOfPlatformTake(platformFeeScaled, binTotalFeeX64, notionalFeeX64, spreadFeeE6);
              platformFees =
              // forge-lint: disable-next-line(unsafe-typecast)
              platformFees.addBoth(uint128(platformFeeScaled - notionalLegScaled), uint128(notionalLegScaled));
            }

            emit BinSwapped(
              curBinIdxCache,
              // Bin balances are uint104, so both deltas fit int128 with 23 bits to spare.
              // forge-lint: disable-next-line(unsafe-typecast)
              Packed2Int128Lib.pack(int128(binDelta0Scaled), int128(binDelta1Scaled)),
              // forge-lint: disable-next-line(unsafe-typecast)
              Packed2Uint128Lib.pack(uint128(lpFeeAmountScaled), uint128(platformFeeScaled))
            );
            _saveBinState(curBinIdxCache, binState);
          }
        }

        bool binExhausted = zeroForOne ? curPosInBinCache == 0 : curPosInBinCache >= type(uint104).max;
        if (binExhausted || !nonEmptyBin) {
          if (zeroForOne) {
            if (curBinIdxCache <= LOWEST_BIN) break;
            curBinIdxCache--;
            binState = _binStates[curBinIdxCache];
            curPosInBinCache = type(uint104).max;
            curBinDistE6Cache -= int24(uint24(binState.lengthE6));
            upperReferencePriceX64 = lowerReferencePriceX64;
            lowerReferencePriceX64 = distanceE6ToPriceX64(curBinDistE6Cache, referencePriceX64);
          } else {
            if (curBinIdxCache >= HIGHEST_BIN) break;
            curBinIdxCache++;
            curPosInBinCache = 0;
            curBinDistE6Cache = _clampInt256ToInt24(_addDistE6(int256(curBinDistE6Cache), binState.lengthE6));
            lowerReferencePriceX64 = upperReferencePriceX64;
            binState = _binStates[curBinIdxCache];
            upperReferencePriceX64 =
              distanceE6ToPriceX64(_addDistE6(curBinDistE6Cache, binState.lengthE6), referencePriceX64);
          }
        } else {
          break;
        }
      }

      _finalizeSwap(curBinIdxCache, curPosInBinCache, curBinDistE6Cache);

      uint256 amountInScaled;
      uint256 amountOutScaled;
      if (specifiedOut) {
        amountInScaled = state.amountCalculatedScaled;
        amountOutScaled = amountSpecifiedScaled - state.amountSpecifiedRemainingScaled;
      } else {
        amountInScaled = amountSpecifiedScaled - state.amountSpecifiedRemainingScaled;
        amountOutScaled = state.amountCalculatedScaled;
      }
      (amount0DeltaScaled, amount1DeltaScaled) = zeroForOne
        // forge-lint: disable-next-line(unsafe-typecast)
        ? (int256(amountInScaled), -int256(amountOutScaled))
        // forge-lint: disable-next-line(unsafe-typecast)
        : (-int256(amountOutScaled), int256(amountInScaled));
    }
  }
}
