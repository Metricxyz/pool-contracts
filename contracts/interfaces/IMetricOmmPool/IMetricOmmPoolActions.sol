// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {BinBalanceDelta, LiquidityDelta} from "../../types/PoolOperation.sol";
import {Packed2Int128, Packed2Uint128, PackedSwapDetails} from "../../types/Packed.sol";

/// @title IMetricOmmPoolActions
/// @notice User-facing mutators on Metric OMM pools: liquidity (shares per bin) and swap execution.
/// @dev State reads live on the concrete pool or libraries. Liquidity paths use native ERC20 amounts in callbacks; bin events carry scaled balances (`BinBalanceDelta`, see `PoolOperation.sol`). Successful `swap` consults the live price provider and is blocked when `pauseLevel != 0` (`PoolPaused`); `addLiquidity` / `removeLiquidity` are not gated by pause so ops policy can diverge (e.g. unwind while swaps are off).
interface IMetricOmmPoolActions {
  // ============ Events: Liquidity ============

  /// @notice Liquidity was minted into one or more bins for a single position key.
  /// @dev Arrays are parallel: `binIdxs[i]`, `binBalanceDeltas[i]`, and `shares[i]` describe the same bin. Zero-share rows remain in the arrays with zero deltas; indexers can reconcile bins from `binBalanceDeltas` (scaled) separately from callback token flows (native).
  /// @param provider `owner` leg of the position key; indexed for position-scoped subscriptions.
  /// @param salt `salt` leg of the position key; indexed with `provider` to disambiguate positions.
  /// @param binIdxs Bin index per input row (pool-configured range).
  /// @param binBalanceDeltas Scaled token0/token1 balance change inside each bin (`BinBalanceDelta`); not wallet transfer amounts.
  /// @param shares Liquidity shares minted per input row for this position.
  event LiquidityAdded(
    address indexed provider,
    uint80 indexed salt,
    int256[] binIdxs,
    BinBalanceDelta[] binBalanceDeltas,
    uint256[] shares
  );

  /// @notice Liquidity was burned from one or more bins for a single position key.
  /// @dev Same parallel-array layout as `LiquidityAdded`. `removeLiquidity` requires `msg.sender == owner`, so the position key always matches the caller for this event.
  /// @param provider Position owner (equals `msg.sender` for the removing call).
  /// @param salt Position salt with `provider` in the key.
  /// @param binIdxs Bin index per input row.
  /// @param binBalanceDeltas Scaled balance change per bin (non-positive: tokens leaving the bin).
  /// @param shares Shares burned per input row.
  event LiquidityRemoved(
    address indexed provider,
    uint80 indexed salt,
    int256[] binIdxs,
    BinBalanceDelta[] binBalanceDeltas,
    uint256[] shares
  );

  // ============ Events: Swap ============

  /// @notice One step of routing updated a bin during `swap` (may emit multiple times per call).
  /// @dev Refer to types/Packed.sol to decode the packed values.
  /// @param binIdx Bin touched in this step.
  /// @param binDeltas Change in THAT BIN's scaled balances, packed: `high` = token0, `low` = token1.
  /// @param fees This step's two fee legs, packed: `high` = LP leg (stays in the bin), `low` = platform leg (protocol + admin, withheld). Scaled units.
  event BinSwapped(int256 binIdx, Packed2Int128 binDeltas, Packed2Uint128 fees);

  /// @notice Terminal summary after a successful `swap`.
  /// @dev Refer to types/Packed.sol to decode the packed values.
  /// @param sender `msg.sender` of `swap` (the account that may receive swap callback).
  /// @param recipient Address that received the output token leg.
  /// @param details Swap mode and resulting bin position packed into one word: `exactInput()`,
  ///        `binIdx()` (signed), `posInBin()`. Check details in PackedSwapDetailsLib.
  /// @param amountDeltas Net native-token flows for the whole call, packed: `high` = token0, `low` = token1 (positive = the pool gained that token).
  /// @param platformFees Platform (protocol + admin) fee for this swap on the input-token leg, packed: `high` = SPREAD leg, `low` = NOTIONAL leg. Scaled units.
  event Swap(
    address indexed sender,
    address indexed recipient,
    PackedSwapDetails details,
    Packed2Int128 amountDeltas,
    Packed2Uint128 platformFees
  );

  // ============ Errors: Liquidity ============

  /// @notice Add or remove share delta is below the pool operational floor.
  /// @dev Raised when non-zero `sharesToAdd` / `sharesToRemove` is `< MINIMAL_OPERATIONAL_LIQUIDITY`.
  /// @param binIdx Bin where the offending delta was applied.
  /// @param sharesDelta Offending share delta.
  /// @param minimalRequired Pool immutable `MINIMAL_OPERATIONAL_LIQUIDITY`.
  error SharesDeltaSmallerThanMinimalOperationalLiquidity(int256 binIdx, uint256 sharesDelta, uint256 minimalRequired);

  /// @notice Remove would leave a non-zero position below the pool operational floor.
  /// @dev Raised when leftover shares are `> 0` and `< MINIMAL_OPERATIONAL_LIQUIDITY`; remove more or exit to zero.
  /// @param binIdx Bin where the leftover would remain.
  /// @param leftovers Remaining shares after the attempted remove.
  /// @param minimalRequired Pool immutable `MINIMAL_OPERATIONAL_LIQUIDITY`.
  error LeftoversSmallerThanMinimalOperationalLiquidity(int256 binIdx, uint256 leftovers, uint256 minimalRequired);

  /// @notice Burn asked for more shares than exist for that position in a bin.
  /// @param requested `deltas.shares[i]` for the offending bin.
  /// @param available Shares recorded for `owner`+`salt` in that bin when this entry is processed.
  error InsufficientLiquidity(uint256 requested, uint256 available);

  /// @notice The modify-liquidity callback sent fewer tokens than the pool debt for this add.
  /// @dev Fires after the pool computed required `amount0`/`amount1` and invoked `msg.sender`; safe for retry once the callback actually pays.
  error InsufficientTokenBalance();

  /// @notice `removeLiquidity` caller is not the position owner.
  /// @dev Only `owner` may burn; `addLiquidity` may use a different `msg.sender` when `owner` is supplied, but removal is stricter.
  error NotPositionOwner();

  /// @notice Deposit allowlist rejected this `owner` for `addLiquidity`.
  /// @dev Never reverted by the pool itself; gating extensions raise it from the add-liquidity extension points.
  error NotAllowedToDeposit();

  /// @notice `LiquidityDelta` arrays are not the same length.
  /// @dev Checked only for non-empty `binIdxs`; an empty array returns `(0, 0)`.
  error LiquidityDeltaLengthMismatch();

  /// @notice A bin index in `deltas.binIdxs` (or `setBinAdditionalFees`) is outside this pool’s
  ///         `[LOWEST_BIN, HIGHEST_BIN]`.
  /// @param binIdx First failing index from the caller payload.
  error InvalidBinIndex(int256 binIdx);

  /// @notice A row's shares exceed `type(uint192).max`, or its required scaled token amount exceeds `type(uint104).max`.
  /// @dev Overflow of the resulting bin or pool totals reverts with a `SafeCast` error instead.
  error SharesAmountTooLarge();

  // ============ Errors: Swap ============

  /// @notice Swap callback paid less than the input amount the pool requested.
  /// @dev Distinct from `InsufficientTokenBalance` (liquidity path); the swap callback left the pool balance short of the input amount the pool requested.
  error IncorrectDelta();

  /// @notice Swap allowlist rejected the swap `sender` (`msg.sender` for `swap`, the supplied `sender` for `simulateSwapAndRevert`).
  /// @dev Never reverted by the pool itself; gating extensions raise it from `beforeSwap`, which `swap` and `simulateSwapAndRevert` run identically.
  error NotAllowedToSwap();

  /// @notice `amountSpecified == 0` on `swap` / `simulateSwapAndRevert`.
  error InvalidAmount();

  /// @notice Swap math settled with a zero input or output delta (native units).
  /// @dev After conversion to native units, either `amount0Delta` or `amount1Delta` is zero — e.g. price limit blocks all progress or amounts round away.
  error FinalAmountIsZero();

  /// @notice The scaled `amountSpecified` (native × token scale multiplier) exceeds `type(uint128).max`.
  /// @dev Exact-output requests are capped to the pool's available output before this check.
  error AmountScaledExceedsMax();

  /// @notice A swap would write a bin's scaled token balance above `type(uint104).max`.
  /// @dev Happens when the input credited to a bin would grow its incoming-side balance past the packed `BinState` width.
  ///      That direction can remain blocked until liquidity is removed or the opposite swap drains the incoming side; prefer smaller bins / less dense liquidity.
  /// @param attemptedScaledBalance The balance that would have been stored (internal scaled units).
  error OverflowedOnFittingBinBalances(uint256 attemptedScaledBalance);

  /// @notice Swaps are disabled while the pool pause level is non-zero.
  /// @dev Pause level is factory-controlled; liquidity mutators are intentionally not blocked by the same check.
  error PoolPaused();

  /// @notice Bid price is not strictly below ask (`bidPriceX64 >= askPriceX64`).
  /// @dev On `swap`, comes from the live `IPriceProvider` quote; on `simulateSwapAndRevert`, from the arguments you passed.
  error BidGreaterThanAsk();

  /// @notice Bid price was zero, so mid/spread cannot be formed.
  /// @dev On `swap`, from the live provider; on `simulateSwapAndRevert`, from `bidPriceX64` you passed.
  error BidIsZero();

  /// @notice Reference price was not within `[bidPriceX64, askPriceX64]`, or was zero.
  /// @dev On `swap`, from the live provider; on `simulateSwapAndRevert`, from `referencePriceX64` you passed.
  error ReferencePriceOutOfRange();

  /// @notice Bid/ask returns about the reference are too asymmetric for the pool's `bidAskRefAsymmetryX8` bound.
  /// @dev With `r1 = reference/bid - 1`, `r2 = ask/reference - 1`, and `M = 1 + m` (`m` stored in X8), requires
  ///      `1/M <= r1/r2 <= M`. Skipped when `bidAskRefAsymmetryX8 == type(uint16).max`. Otherwise a reference on bid/ask reverts.
  error BidAskRefAsymmetryOutOfBounds();

  /// @notice External call to the active `IPriceProvider` reverted or bubbled a failure.
  /// @param reason Opaque revert data from the provider (decode off-chain if the provider documents errors).
  error PriceProviderFailed(bytes reason);

  /// @notice Deliberate revert carrying simulated swap deltas; no settlement callback or token transfers.
  /// @dev Uses validated caller-supplied quotes and runs swap hooks, even while paused. All state changes revert.
  ///      Both deltas must fit `int128` before `afterSwap`, despite the error using `int256` fields.
  ///      Decode this error from revert data; execution failures propagate their own errors instead.
  /// @param amount0Delta Net token0 the swap would move into (`>0`) or out of (`<0`) the pool (native decimals).
  /// @param amount1Delta Net token1 the swap would move into or out of the pool (native decimals).
  error SimulateSwap(int256 amount0Delta, int256 amount1Delta);

  // ============ Mutating: Liquidity ============

  /// @notice Mint shares across bins for `(owner, salt)`; pulls tokens via `IMetricOmmModifyLiquidityCallback` on `msg.sender`.
  /// @dev Callback amounts round up per bin and again on conversion to native units; underpay reverts
  ///      `InsufficientTokenBalance`. `msg.sender` pays but need not equal `owner`. Empty `binIdxs` skips hooks and callbacks.
  /// @param owner Position owner encoded in the pool’s position key.
  /// @param salt Caller-chosen second leg of the position key.
  /// @param deltas Parallel `binIdxs` / `shares` arrays (see `LiquidityDelta`).
  /// @param callbackData Opaque bytes forwarded unmodified to the modify-liquidity callback.
  /// @param extensionData Opaque bytes forwarded to liquidity extensions (beforeAddLiquidity / afterAddLiquidity).
  /// @return amount0Added Token0 amount the pool required from the callback (native).
  /// @return amount1Added Token1 amount the pool required from the callback (native).
  /// @dev Reverts `LiquidityDeltaLengthMismatch` when `binIdxs` is non-empty and its length differs from `shares`.
  function addLiquidity(
    address owner,
    uint80 salt,
    LiquidityDelta calldata deltas,
    bytes calldata callbackData,
    bytes calldata extensionData
  ) external returns (uint256 amount0Added, uint256 amount1Added);

  /// @notice Burn shares across bins for `(owner, salt)` and send underlying tokens to `owner`.
  /// @dev Requires `msg.sender == owner` except for empty `binIdxs`, which returns `(0, 0)`.
  ///      Payouts round down per bin and again on conversion to native units; no callback.
  ///      Emptying the current bin resets its position to `0` for non-negative bins or `type(uint104).max` for negative bins.
  /// @param owner Must equal `msg.sender`.
  /// @param salt Position salt with `owner`.
  /// @param deltas Parallel arrays of bins and share burns.
  /// @param extensionData Opaque bytes forwarded to liquidity extensions (beforeRemoveLiquidity / afterRemoveLiquidity).
  /// @return amount0Removed Total token0 sent from the pool to `owner` (native).
  /// @return amount1Removed Total token1 sent from the pool to `owner` (native).
  function removeLiquidity(address owner, uint80 salt, LiquidityDelta calldata deltas, bytes calldata extensionData)
    external
    returns (uint256 amount0Removed, uint256 amount1Removed);

  // ============ Mutating: Swap ============

  /// @notice Execute a spot swap against pool liquidity using live oracle prices.
  /// @dev Pulls input from `msg.sender` through `IMetricOmmSwapCallback` after sending output to `recipient`.
  /// @param recipient Address that receives the output token (sent before the callback; the swap reverts if the
  ///        callback then underpays the input).
  /// @param zeroForOne `true` sells token0 for token1 along the pool’s ordering.
  /// @param amountSpecified Exact input if `>0`, exact output magnitude if `<0`, in native units of that leg.
  ///        May be partially filled; check the returned deltas.
  /// @param priceLimitX64 Fee-inclusive token1-per-token0 price in Q64.64: a floor when `zeroForOne`, a cap otherwise.
  ///        Zero permits sells but prevents buys; rounding can significantly breach the bound for tiny amounts.
  /// @param callbackData Opaque bytes forwarded to the swap callback.
  /// @param extensionData Opaque bytes forwarded to swap extension point functions (beforeSwap / afterSwap).
  /// @return amount0Delta Net token0 change for the pool (signed, native; positive = pool received).
  /// @return amount1Delta Net token1 change for the pool (signed, native; positive = pool received).
  function swap(
    address recipient,
    bool zeroForOne,
    int128 amountSpecified,
    uint128 priceLimitX64,
    bytes calldata callbackData,
    bytes calldata extensionData
  ) external returns (int128 amount0Delta, int128 amount1Delta);

  /// @notice Run swap math with caller-supplied bid/ask/reference; reverts with `SimulateSwap` on success or an execution error on failure.
  /// @dev Does not use the pool’s live oracle prices for the mid—use for quotes/off-chain routing. Invokes the same swap extension point functions as `swap` when enabled; still enforces `priceLimitX64` and path logic; no ERC20 transfers or swap callback. Typical usage: `eth_call` or `try/catch` decoding `SimulateSwap`. `sender` is forwarded to the extension points as-is instead of `msg.sender`, so you can simulate as an arbitrary address (e.g. checking a sender-gated extension for a specific user) — safe only because the call always reverts and nothing persists.
  /// @param sender Address forwarded to swap extension point functions in place of `msg.sender`; has no other effect since the call always reverts.
  /// @param recipient Same as `swap` (forwarded to swap extension point functions).
  /// @param zeroForOne Same as `swap`.
  /// @param amountSpecified Same sign convention as `swap`.
  /// @param priceLimitX64 Same encoding as `swap`.
  /// @param bidPriceX64 Bid used for extension context and swap math in this simulation (Q64.64).
  /// @param askPriceX64 Ask used for extension context and swap math in this simulation (Q64.64).
  /// @param referencePriceX64 Reference price used as the mid/price-path anchor and for fee calculation in this simulation (Q64.64).
  /// @param extensionData Opaque bytes forwarded to swap extension point functions (beforeSwap / afterSwap).
  /// @return amount0Delta Unused in practice; values appear only on the reverting `SimulateSwap` error.
  /// @return amount1Delta Unused in practice; values appear only on the reverting `SimulateSwap` error.
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
  ) external returns (int128 amount0Delta, int128 amount1Delta);
}
