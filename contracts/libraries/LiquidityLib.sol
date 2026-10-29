// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BinBalanceDelta, LiquidityDelta} from "../types/PoolOperation.sol";
import {BinState, BinTotals} from "../types/PoolStorage.sol";
import {IMetricOmmPoolActions} from "../interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {IMetricOmmModifyLiquidityCallback} from "../interfaces/callbacks/IMetricOmmModifyLiquidityCallback.sol";

/// @title LiquidityLib
/// @notice Holds `addLiquidity` / `removeLiquidity` logic as a deployable (DELEGATECALL-linked)
///         library so it does not inflate `MetricOmmPool` bytecode.
/// @dev Because every `public` function is called via DELEGATECALL from the pool:
///      - `msg.sender` is the original external caller.
///      - `address(this)` is the pool contract.
///      - Storage references resolve against the pool's state.
///      - ERC-20 calls (`balanceOf`, `safeTransfer`) operate on the pool's holdings.
library LiquidityLib {
  using SafeCast for uint256;
  using SafeERC20 for IERC20;

  /// @notice Immutables + snapshot of mutable state the pool passes into every liquidity call.
  struct PoolContext {
    address token0;
    address token1;
    uint256 token0ScaleMultiplier;
    uint256 token1ScaleMultiplier;
    uint256 initialScaledToken0PerShareE18;
    uint256 initialScaledToken1PerShareE18;
    uint256 minimalMintableLiquidity;
    int256 lowestBin;
    int256 highestBin;
    int256 curBinIdx;
    uint104 curPosInBin;
  }

  function addLiquidity(
    PoolContext memory ctx,
    address owner,
    uint80 salt,
    LiquidityDelta calldata deltas,
    bytes calldata callbackData,
    BinTotals storage binTotals,
    mapping(int256 => BinState) storage binStates,
    mapping(int256 => uint256) storage binTotalShares,
    mapping(bytes32 => uint256) storage positionBinShares
  ) public returns (uint256 amount0Added, uint256 amount1Added) {
    unchecked {
      uint256 length = deltas.binIdxs.length;
      if (length == 0) return (0, 0);

      uint256 totalToken0ToAddScaled = 0;
      uint256 totalToken1ToAddScaled = 0;

      BinBalanceDelta[] memory binBalanceDeltas = new BinBalanceDelta[](length);

      int256 curBinIdxCache = ctx.curBinIdx;

      for (uint256 i = 0; i < length; i++) {
        int256 binIdx = deltas.binIdxs[i];
        uint256 sharesToAdd = deltas.shares[i];

        if (binIdx < ctx.lowestBin || binIdx > ctx.highestBin) revert IMetricOmmPoolActions.InvalidBinIndex(binIdx);
        if (sharesToAdd == 0) continue;

        {
          // safe because -128 <= LOWEST_BIN <= HIGHEST_BIN <= 127 (enforced by factory)
          // forge-lint: disable-next-line(unsafe-typecast)
          bytes32 posKey = _positionBinKey(owner, salt, int8(binIdx));
          uint256 binTotalSharesVal = binTotalShares[binIdx];
          uint256 userShares = positionBinShares[posKey];

          uint256 newUserShares = userShares + sharesToAdd;
          if (newUserShares < ctx.minimalMintableLiquidity) {
            revert IMetricOmmPoolActions.MinimalLiquidity(newUserShares, ctx.minimalMintableLiquidity);
          }

          BinState storage binState = binStates[binIdx];

          uint256 amount0Scaled = 0;
          uint256 amount1Scaled = 0;
          if (binTotalSharesVal == 0) {
            if (binIdx < curBinIdxCache) {
              amount1Scaled = Math.ceilDiv(_checkedMul(ctx.initialScaledToken1PerShareE18, sharesToAdd), 1e18);
            } else if (binIdx > curBinIdxCache) {
              amount0Scaled = Math.ceilDiv(_checkedMul(ctx.initialScaledToken0PerShareE18, sharesToAdd), 1e18);
            } else {
              uint256 token0Proportion = type(uint104).max - ctx.curPosInBin;
              uint256 token1Proportion = ctx.curPosInBin;
              amount0Scaled =
              (Math.mulDiv(
                  token0Proportion * ctx.initialScaledToken0PerShareE18,
                  sharesToAdd,
                  uint256(type(uint104).max) * 1e18,
                  Math.Rounding.Ceil
                ));
              amount1Scaled =
              (Math.mulDiv(
                  token1Proportion * ctx.initialScaledToken1PerShareE18,
                  sharesToAdd,
                  uint256(type(uint104).max) * 1e18,
                  Math.Rounding.Ceil
                ));
            }
          } else {
            amount0Scaled = Math.ceilDiv(_checkedMul(binState.token0BalanceScaled, sharesToAdd), binTotalSharesVal);
            amount1Scaled = Math.ceilDiv(_checkedMul(binState.token1BalanceScaled, sharesToAdd), binTotalSharesVal);
          }
          if (amount0Scaled > 0) {
            totalToken0ToAddScaled += amount0Scaled;
            binState.token0BalanceScaled = (uint256(binState.token0BalanceScaled) + amount0Scaled).toUint104();
          }
          if (amount1Scaled > 0) {
            totalToken1ToAddScaled += amount1Scaled;
            binState.token1BalanceScaled = (uint256(binState.token1BalanceScaled) + amount1Scaled).toUint104();
          }
          binTotalShares[binIdx] = binTotalSharesVal + sharesToAdd;
          positionBinShares[posKey] = newUserShares;

          binBalanceDeltas[i] = BinBalanceDelta({
            // Safe: per-bin deltas are bounded by uint104 bin balances.
            // forge-lint: disable-next-line(unsafe-typecast)
            delta0Scaled: int256(amount0Scaled),
            // casting to int256 is safe because amount1Scaled is bounded by uint104 bin balances.
            // forge-lint: disable-next-line(unsafe-typecast)
            delta1Scaled: int256(amount1Scaled)
          });
        }
      }

      if (totalToken0ToAddScaled > 0) {
        binTotals.scaledToken0 = (uint256(binTotals.scaledToken0) + totalToken0ToAddScaled).toUint128();
      }
      if (totalToken1ToAddScaled > 0) {
        binTotals.scaledToken1 = (uint256(binTotals.scaledToken1) + totalToken1ToAddScaled).toUint128();
      }

      (amount0Added, amount1Added) =
        _deltasScaledToExternal(totalToken0ToAddScaled, totalToken1ToAddScaled, ctx, Math.Rounding.Ceil);

      if (amount0Added > 0 || amount1Added > 0) {
        uint256 balance0Before = IERC20(ctx.token0).balanceOf(address(this));
        uint256 balance1Before = IERC20(ctx.token1).balanceOf(address(this));
        IMetricOmmModifyLiquidityCallback(msg.sender)
          .metricOmmModifyLiquidityCallback(amount0Added, amount1Added, callbackData);
        if (amount0Added > 0 && balance0Before + amount0Added > IERC20(ctx.token0).balanceOf(address(this))) {
          revert IMetricOmmPoolActions.InsufficientTokenBalance();
        }
        if (amount1Added > 0 && balance1Before + amount1Added > IERC20(ctx.token1).balanceOf(address(this))) {
          revert IMetricOmmPoolActions.InsufficientTokenBalance();
        }
      }

      emit IMetricOmmPoolActions.LiquidityAdded(owner, salt, deltas.binIdxs, binBalanceDeltas, deltas.shares);
    }
  }

  function removeLiquidity(
    PoolContext memory ctx,
    address owner,
    uint80 salt,
    LiquidityDelta calldata deltas,
    BinTotals storage binTotals,
    mapping(int256 => BinState) storage binStates,
    mapping(int256 => uint256) storage binTotalShares,
    mapping(bytes32 => uint256) storage positionBinShares
  ) public returns (uint256 amount0Removed, uint256 amount1Removed) {
    unchecked {
      uint256 length = deltas.binIdxs.length;
      if (length == 0) return (0, 0);

      uint256 totalToken0ToRemoveScaled = 0;
      uint256 totalToken1ToRemoveScaled = 0;

      BinBalanceDelta[] memory binBalanceDeltas = new BinBalanceDelta[](length);

      for (uint256 i = 0; i < length; i++) {
        int256 binIdx = deltas.binIdxs[i];
        uint256 sharesToRemove = deltas.shares[i];

        if (binIdx < ctx.lowestBin || binIdx > ctx.highestBin) {
          revert IMetricOmmPoolActions.InvalidBinIndex(binIdx);
        }
        if (sharesToRemove == 0) continue;

        {
          // safe because -128 <= LOWEST_BIN <= HIGHEST_BIN <= 127 (enforced by factory)
          // forge-lint: disable-next-line(unsafe-typecast)
          bytes32 posKey = _positionBinKey(owner, salt, int8(binIdx));
          uint256 binTotalSharesVal = binTotalShares[binIdx];
          uint256 userShares = positionBinShares[posKey];

          if (userShares < sharesToRemove) {
            revert IMetricOmmPoolActions.InsufficientLiquidity(sharesToRemove, userShares);
          }
          uint256 newUserShares = userShares - sharesToRemove;
          if (newUserShares > 0 && newUserShares < ctx.minimalMintableLiquidity) {
            revert IMetricOmmPoolActions.MinimalLiquidity(newUserShares, ctx.minimalMintableLiquidity);
          }

          BinState storage binState = binStates[binIdx];
          uint256 amount0Scaled = _checkedMul(binState.token0BalanceScaled, sharesToRemove) / binTotalSharesVal;
          uint256 amount1Scaled = _checkedMul(binState.token1BalanceScaled, sharesToRemove) / binTotalSharesVal;

          // casting to uint104 is safe because amount0Scaled and amount1Scaled are less than token(0|1)BalanceScaled
          // forge-lint: disable-next-line(unsafe-typecast)
          binState.token0BalanceScaled -= uint104(amount0Scaled);
          // forge-lint: disable-next-line(unsafe-typecast)
          binState.token1BalanceScaled -= uint104(amount1Scaled);
          binTotalShares[binIdx] = binTotalSharesVal - sharesToRemove;
          positionBinShares[posKey] = newUserShares;

          totalToken0ToRemoveScaled += amount0Scaled;
          totalToken1ToRemoveScaled += amount1Scaled;

          binBalanceDeltas[i] = BinBalanceDelta({
            // safe because amount0Scaled is bounded by uint104 bin balances.
            // forge-lint: disable-next-line(unsafe-typecast)
            delta0Scaled: -int256(amount0Scaled),
            // safe because amount1Scaled is bounded by uint104 bin balances.
            // forge-lint: disable-next-line(unsafe-typecast)
            delta1Scaled: -int256(amount1Scaled)
          });
        }
      }

      if (totalToken0ToRemoveScaled > 0) {
        // forge-lint: disable-next-line(unsafe-typecast)
        binTotals.scaledToken0 = uint128(uint256(binTotals.scaledToken0) - totalToken0ToRemoveScaled);
      }
      if (totalToken1ToRemoveScaled > 0) {
        // forge-lint: disable-next-line(unsafe-typecast)
        binTotals.scaledToken1 = uint128(uint256(binTotals.scaledToken1) - totalToken1ToRemoveScaled);
      }

      (amount0Removed, amount1Removed) =
        _deltasScaledToExternal(totalToken0ToRemoveScaled, totalToken1ToRemoveScaled, ctx, Math.Rounding.Floor);

      if (amount0Removed > 0) {
        IERC20(ctx.token0).safeTransfer(owner, amount0Removed);
      }
      if (amount1Removed > 0) {
        IERC20(ctx.token1).safeTransfer(owner, amount1Removed);
      }

      emit IMetricOmmPoolActions.LiquidityRemoved(owner, salt, deltas.binIdxs, binBalanceDeltas, deltas.shares);
    }
  }

  // ---- Internal helpers (inlined into the public functions above) ----

  /// @notice Deterministic key for position-bin shares; must match `PoolStateLibrary.toPositionBinKey`.
  function _positionBinKey(address owner, uint80 salt, int8 bin) internal pure returns (bytes32 key) {
    // forge-lint: disable-next-line(asm-keccak256)
    return keccak256(abi.encode(owner, salt, bin));
  }

  function _checkedMul(uint256 a, uint256 b) internal pure returns (uint256) {
    return a * b;
  }

  function _deltasScaledToExternal(
    uint256 scaledDeltaAmount0,
    uint256 scaledDeltaAmount1,
    PoolContext memory ctx,
    Math.Rounding rounding
  ) internal pure returns (uint256 deltaAmount0, uint256 deltaAmount1) {
    if (rounding == Math.Rounding.Ceil) {
      deltaAmount0 = Math.ceilDiv(scaledDeltaAmount0, ctx.token0ScaleMultiplier);
      deltaAmount1 = Math.ceilDiv(scaledDeltaAmount1, ctx.token1ScaleMultiplier);
    } else {
      deltaAmount0 = scaledDeltaAmount0 / ctx.token0ScaleMultiplier;
      deltaAmount1 = scaledDeltaAmount1 / ctx.token1ScaleMultiplier;
    }
  }
}
