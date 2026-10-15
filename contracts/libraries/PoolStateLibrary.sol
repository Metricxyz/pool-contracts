// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IExtsload} from "../interfaces/IExtsload.sol";
import {PoolSlot0} from "../types/Slot0.sol";
import {Slot0Library} from "./Slot0Library.sol";

/// @title PoolStateLibrary
/// @notice Read MetricOmmPool mutable storage via EXTSLOAD; immutables use the pool's `getImmutables()`.
/// @dev Contract coupling: this library is tightly coupled to `contracts/MetricOmmPool.sol` storage
///      layout and packing. Any storage reorder or repack in the pool is a breaking change for
///      EXTSLOAD readers (including off-chain integrations using these slot calculations).
/// @dev Constants and packing must match MetricOmmPool storage layout exactly.
///
/// Storage Layout:
/// Slot 0: pauseLevel(uint8,0) | curBinIdx(int16,8) | curPosInBin(uint104,24) | curBinDistE6(int24,128) |
///         spreadFeeE6(uint24,152) | notionalFeeE8(uint24,176) | bidAskRefAsymmetryX8(uint16,200)
/// Slot 1: binTotals.scaledToken0(uint128,0) | binTotals.scaledToken1(uint128,128)
/// Slot 2: notionalFeeToken0Scaled(uint128,0) | notionalFeeToken1Scaled(uint128,128)
/// Slot 3: priceProvider(address) (mutable mode; immutable oracle is an immutable on the pool)
/// Slot 4: _binStates mapping(int256 => BinState)
/// Slot 5: _binTotalShares mapping(int256 => uint256)
/// Slot 6: _positionBinShares mapping(bytes32 => uint256)
/// Slot 7: pendingAdminFeeToken0Scaled(uint256)
/// Slot 8: pendingAdminFeeToken1Scaled(uint256)
/// Slot 9: pendingProtocolFeeToken0Scaled(uint256)
/// Slot 10: pendingProtocolFeeToken1Scaled(uint256)
/// @dev Bin indices are treated as `int16` throughout pool configuration; the factory caps the grid at
///      32,768 bins per side so keys computed here match the `int256` mapping keys on the pool.
/// @dev This library intentionally exposes underscored helpers to keep call sites explicit.
library PoolStateLibrary {
  using SafeCast for uint256;
  using SafeCast for int256;

  uint256 internal constant SLOT0 = 0;
  uint256 internal constant SLOT1_TOTALS = 1;
  uint256 internal constant SLOT2_NOTIONAL_ACCUMULATORS = 2;
  uint256 internal constant SLOT3_PRICE_PROVIDER = 3;
  uint256 internal constant MAPPING_BIN_STATES = 4;
  uint256 internal constant MAPPING_BIN_TOTAL_SHARES = 5;
  uint256 internal constant MAPPING_POSITION_BIN_SHARES = 6;
  uint256 internal constant SLOT7_PENDING_FEES = 7;

  // ========= Slot0 =========

  function _decodeSlot0(bytes32 data)
    internal
    pure
    returns (
      uint8 pauseLevel,
      int16 curBinIdx,
      uint104 curPosInBin,
      int24 curBinDistFromProvidedPriceE6,
      uint24 spreadFeeE6,
      uint24 notionalFeeE8,
      uint16 bidAskRefAsymmetryX8
    )
  {
    PoolSlot0 memory s = Slot0Library.unpack(uint256(data));
    pauseLevel = s.pauseLevel;
    curBinIdx = s.curBinIdx;
    curPosInBin = s.curPosInBin;
    curBinDistFromProvidedPriceE6 = s.curBinDistFromProvidedPriceE6;
    spreadFeeE6 = s.spreadFeeE6;
    notionalFeeE8 = s.notionalFeeE8;
    bidAskRefAsymmetryX8 = s.bidAskRefAsymmetryX8;
  }

  /// @notice Get all slot0 values in a single call
  function _slot0(address pool)
    internal
    view
    returns (
      uint8 _pauseLevel,
      int16 _curBinIdx,
      uint104 _curPosInBin,
      int24 _curBinDistFromProvidedPriceE6,
      uint24 _spreadFeeE6,
      uint24 _notionalFeeE8,
      uint16 _bidAskRefAsymmetryX8
    )
  {
    bytes32 slot0 = IExtsload(pool).extsload(bytes32(uint256(SLOT0)));
    return _decodeSlot0(slot0);
  }

  // ========= Slot1 =========
  function _decodeSlot1(bytes32 data)
    internal
    pure
    returns (uint128 totalScaledToken0InBins, uint128 totalScaledToken1InBins)
  {
    uint256 packed = uint256(data);
    // forge-lint: disable-next-line(unsafe-typecast)
    totalScaledToken0InBins = uint128(packed & type(uint128).max);
    // forge-lint: disable-next-line(unsafe-typecast)
    totalScaledToken1InBins = uint128(packed >> 128);
  }

  /// @notice Get all slot1 values in a single call
  function _slot1(address pool)
    internal
    view
    returns (uint128 _totalScaledToken0InBins, uint128 _totalScaledToken1InBins)
  {
    bytes32 data = IExtsload(pool).extsload(bytes32(uint256(SLOT1_TOTALS)));
    return _decodeSlot1(data);
  }

  // ========= Slot2 =========
  function _decodeSlot2(bytes32 data)
    internal
    pure
    returns (uint128 notionalFeeToken0Scaled, uint128 notionalFeeToken1Scaled)
  {
    uint256 packed = uint256(data);
    // forge-lint: disable-next-line(unsafe-typecast)
    notionalFeeToken0Scaled = uint128(packed & type(uint128).max);
    // forge-lint: disable-next-line(unsafe-typecast)
    notionalFeeToken1Scaled = uint128(packed >> 128);
  }

  /// @notice Get all slot2 values in a single call
  function _slot2(address pool)
    internal
    view
    returns (uint128 _notionalFeeToken0Scaled, uint128 _notionalFeeToken1Scaled)
  {
    bytes32 data = IExtsload(pool).extsload(bytes32(uint256(SLOT2_NOTIONAL_ACCUMULATORS)));
    return _decodeSlot2(data);
  }

  // ========= Slot3 =========
  function _decodeSlot3(bytes32 data) internal pure returns (address priceProvider) {
    // forge-lint: disable-next-line(unsafe-typecast)
    priceProvider = address(uint160(uint256(data)));
  }

  /// @notice Get the price provider from slot3 (`address(0)` for pools with an immutable provider)
  function _slot3(address pool) internal view returns (address _priceProvider) {
    bytes32 data = IExtsload(pool).extsload(bytes32(uint256(SLOT3_PRICE_PROVIDER)));
    return _decodeSlot3(data);
  }

  // ========= Slot4: Bins States =========

  /// @notice Calculate the storage slot for a bin state
  /// @dev For mapping(int256 => BinState), slot = keccak256(abi.encode(key, baseSlot)); `int16` keys match int256 encoding for values in int16 range.
  function _calculateBinStateSlot(int16 binIdx) internal pure returns (bytes32 slot) {
    uint256 baseSlot = MAPPING_BIN_STATES;
    assembly {
      mstore(0x00, binIdx)
      mstore(0x20, baseSlot)
      slot := keccak256(0x00, 0x40)
    }
  }

  function _decodeBinState(bytes32 data)
    internal
    pure
    returns (uint104 token0Balance, uint104 token1Balance, uint16 lengthE6, uint16 addFeeBuyE6, uint16 addFeeSellE6)
  {
    uint256 packed = uint256(data);
    // forge-lint: disable-next-line(unsafe-typecast)
    token0Balance = uint104(packed & type(uint104).max);
    // forge-lint: disable-next-line(unsafe-typecast)
    token1Balance = uint104((packed >> 104) & type(uint104).max);
    // forge-lint: disable-next-line(unsafe-typecast)
    lengthE6 = uint16((packed >> 208) & 0xFFFF);
    // forge-lint: disable-next-line(unsafe-typecast)
    addFeeBuyE6 = uint16((packed >> 224) & 0xFFFF);
    // forge-lint: disable-next-line(unsafe-typecast)
    addFeeSellE6 = uint16((packed >> 240) & 0xFFFF);
  }

  /// @notice Get bin state (scaled balances and configuration)
  /// @dev BinState: token0BalanceScaled(uint104,0) | token1BalanceScaled(uint104,104) | lengthE6(uint16,208) | addFeeBuyE6(uint16,224) | addFeeSellE6(uint16,240)
  function _binState(address pool, int16 binIdx)
    internal
    view
    returns (
      uint104 _token0Balance,
      uint104 _token1Balance,
      uint16 _lengthE6,
      uint16 _addFeeBuyE6,
      uint16 _addFeeSellE6
    )
  {
    bytes32 slot = _calculateBinStateSlot(binIdx);
    bytes32 data = IExtsload(pool).extsload(slot);
    return _decodeBinState(data);
  }

  /// @notice Get bin states for multiple bins in batch
  /// @dev Decode each returned item with `_decodeBinState`.
  function _multipleBinStates(address pool, int16[] memory binIdxs)
    internal
    view
    returns (bytes32[] memory binStatesAsBytes32)
  {
    uint256 length = binIdxs.length;

    bytes32[] memory slots = new bytes32[](length);
    for (uint256 i = 0; i < length; i++) {
      slots[i] = _calculateBinStateSlot(binIdxs[i]);
    }
    binStatesAsBytes32 = IExtsload(pool).extsload(slots);
  }

  // ========= Slot5: Bin Total Shares =========

  /// @notice Calculate the storage slot for bin total shares
  function _calculateBinTotalSharesSlot(int16 binIdx) private pure returns (bytes32 slot) {
    uint256 baseSlot = MAPPING_BIN_TOTAL_SHARES;
    assembly {
      mstore(0x00, binIdx)
      mstore(0x20, baseSlot)
      slot := keccak256(0x00, 0x40)
    }
  }

  function _decodeBinTotalShares(bytes32 data) internal pure returns (uint256 totalShares) {
    totalShares = uint256(data);
  }

  /// @notice Get bin total shares
  function _binTotalShares(address pool, int16 binIdx) internal view returns (uint256) {
    bytes32 slot = _calculateBinTotalSharesSlot(binIdx);
    bytes32 data = IExtsload(pool).extsload(slot);
    return _decodeBinTotalShares(data);
  }

  /// @notice Get bin total shares for multiple bins in batch
  /// @dev Decode each returned item with `_decodeBinTotalShares`.
  function _multipleBinTotalShares(address pool, int16[] memory binIdxs)
    internal
    view
    returns (bytes32[] memory totalSharesAsBytes32)
  {
    uint256 length = binIdxs.length;

    bytes32[] memory slots = new bytes32[](length);
    for (uint256 i = 0; i < length; i++) {
      slots[i] = _calculateBinTotalSharesSlot(binIdxs[i]);
    }

    totalSharesAsBytes32 = IExtsload(pool).extsload(slots);
  }

  // ========= Slot6: Position Bin Shares =========

  // ========= Position Readers =========

  /// @notice Calculate the storage slot for position bin shares
  /// @dev `positionBinKey` equals `keccak256(abi.encode(owner, salt, bin))` (see `_toPositionBinKey`).
  function _calculatePositionBinSharesSlot(bytes32 positionBinKey) private pure returns (bytes32 slot) {
    uint256 baseSlot = MAPPING_POSITION_BIN_SHARES;
    assembly {
      mstore(0x00, positionBinKey)
      mstore(0x20, baseSlot)
      slot := keccak256(0x00, 0x40)
    }
  }

  function _decodePositionBinShares(bytes32 data) internal pure returns (uint256 shares) {
    return uint256(data);
  }

  /// @notice Create a position bin key (same as `LiquidityLib._positionBinKey`)
  function _toPositionBinKey(address owner, uint80 salt, int16 bin) internal pure returns (bytes32 key) {
    // abi.encode layout is intentionally matched with `LiquidityLib._positionBinKey` for storage compatibility.
    // forge-lint: disable-next-line(asm-keccak256)
    return keccak256(abi.encode(owner, salt, bin));
  }

  /// @notice Get position bin shares
  function _positionBinShares(address pool, address owner, uint80 salt, int16 bin) internal view returns (uint256) {
    bytes32 positionBinKey = _toPositionBinKey(owner, salt, bin);
    bytes32 slot = _calculatePositionBinSharesSlot(positionBinKey);
    bytes32 data = IExtsload(pool).extsload(slot);
    return _decodePositionBinShares(data);
  }

  /// @notice Get position bin shares by key
  /// @dev Build keys with `_toPositionBinKey`.
  function _positionBinShares(address pool, bytes32 positionBinKey) internal view returns (uint256) {
    bytes32 slot = _calculatePositionBinSharesSlot(positionBinKey);
    bytes32 data = IExtsload(pool).extsload(slot);
    return _decodePositionBinShares(data);
  }

  /// @notice Get position bin shares for multiple bins in a single call
  /// @dev Decode each returned item with `_decodePositionBinShares`.
  function _multiplePositionBinShares(address pool, address owner, uint80 salt, int16[] memory binIdxs)
    internal
    view
    returns (bytes32[] memory sharesAsBytes32)
  {
    uint256 length = binIdxs.length;
    bytes32[] memory slots = new bytes32[](length);
    for (uint256 i = 0; i < length; i++) {
      slots[i] = _calculatePositionBinSharesSlot(_toPositionBinKey(owner, salt, binIdxs[i]));
    }
    sharesAsBytes32 = IExtsload(pool).extsload(slots);
  }

  /// @notice Get all pending fee balances in scaled units with a single call.
  function _pendingFeesScaled(address pool)
    internal
    view
    returns (
      uint256 pendingAdminFeeToken0Scaled,
      uint256 pendingAdminFeeToken1Scaled,
      uint256 pendingProtocolFeeToken0Scaled,
      uint256 pendingProtocolFeeToken1Scaled
    )
  {
    bytes32[] memory data = IExtsload(pool).extsload(bytes32(SLOT7_PENDING_FEES), 4);
    return (uint256(data[0]), uint256(data[1]), uint256(data[2]), uint256(data[3]));
  }
}
