// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {BinBalanceDelta, LiquidityDelta} from "../../types/PoolOperation.sol";

/// @title IMetricOmmPoolActions
/// @notice User-facing mutators on Metric OMM pools: liquidity (shares per bin) and swap execution.
/// @dev State reads live on the concrete pool or libraries. Liquidity paths use native ERC20 amounts in callbacks; bin events carry scaled balances (`BinBalanceDelta`, see `PoolOperation.sol`). Successful `swap` consults the live price provider and is blocked when `pauseLevel != 0` (`PoolPaused`); `addLiquidity` / `removeLiquidity` are not gated by pause so ops policy can diverge (e.g. unwind while swaps are off).
interface IMetricOmmPoolActions {
  // ============ Events: Liquidity ============

  /// @notice Liquidity was minted into one or more bins for a single position key.
  /// @dev Arrays are parallel: `binIdxs[i]`, `binBalanceDeltas[i]`, and `shares[i]` describe the same bin. Emitted after balances and position shares are updated; indexers can reconcile bins from `binBalanceDeltas` (scaled) separately from callback token flows (native).
  /// @param provider `owner` leg of the position key; indexed for position-scoped subscriptions.
  /// @param salt `salt` leg of the position key; indexed with `provider` to disambiguate positions.
  /// @param binIdxs Bin index per touched row (pool-configured range).
  /// @param binBalanceDeltas Scaled token0/token1 balance change inside each bin (`BinBalanceDelta`); not wallet transfer amounts.
  /// @param shares Liquidity shares minted per touched bin for this position.
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
  /// @param binIdxs Bin index per touched row.
  /// @param binBalanceDeltas Scaled balance change per bin (signs reflect token leaving or entering the bin on burn).
  /// @param shares Shares burned per touched bin.
  event LiquidityRemoved(
    address indexed provider,
    uint80 indexed salt,
    int256[] binIdxs,
    BinBalanceDelta[] binBalanceDeltas,
    uint256[] shares
  );

  // ============ Events: Swap ============

  /// @notice One step of routing updated a bin during `swap` (may emit multiple times per call).
  /// @dev Fires in traversal order, not necessarily increasing `binIdx`. `lpFeeAmount` is the LP-facing fee on the input-token leg for this step in scaled pool units; protocol fee for the whole swap is aggregated on `Swap`, not repeated here per bin.
  /// @param binIdx Bin touched in this step.
  /// @param delta Scaled token0/token1 balance delta applied inside that bin for this step.
  /// @param lpFeeAmount LP spread/notional slice attributed to this bin on the input leg for this step (scaled).
  event BinSwapped(int256 binIdx, BinBalanceDelta delta, uint256 lpFeeAmount);

  /// @notice Terminal summary after a successful `swap`.
  /// @dev `amount0Delta` / `amount1Delta` are native-token net flows for the full call (positive = pool gained that token, negative = pool paid out). `newTick` / `newPositionInBin` describe active-bin cursor after execution; use with bin events for full path reconstruction.
  /// @param sender `msg.sender` of `swap` (the account that may receive swap callback).
  /// @param recipient Address that received the output token leg.
  /// @param exactInput Whether `amountSpecified` was treated as exact input (`true`) or exact output (`false`).
  /// @param amount0Delta Net token0 moved into (`>0`) or out of (`<0`) the pool for the whole swap (native decimals).
  /// @param amount1Delta Net token1 moved into or out of the pool for the whole swap (native decimals).
  /// @param newTick Active bin index after the swap.
  /// @param newPositionInBin Cursor within `newTick` after the swap (pool-internal position-in-bin encoding).
  /// @param protocolFeeAmount Protocol’s share of fee on the input-token leg for this swap in scaled units (see pool fee split vs `lpFeeAmount` on `BinSwapped`).
  event Swap(
    address indexed sender,
    address indexed recipient,
    bool exactInput,
    int256 amount0Delta,
    int256 amount1Delta,
    int8 newTick,
    uint104 newPositionInBin,
    uint256 protocolFeeAmount
  );

  // ============ Errors: Liquidity ============

  /// @notice Mint would leave the position with non-zero liquidity in a bin but below the pool’s dust floor.
  /// @dev Raised when the resulting share balance is `> 0` and `< MINIMAL_MINTABLE_LIQUIDITY` so tiny positions cannot clog storage; either add more shares or remove to zero.
  /// @param afterOperation Share amount in the affected bin after the attempted operation.
  /// @param minimalRequired Pool immutable `MINIMAL_MINTABLE_LIQUIDITY`.
  error MinimalLiquidity(uint256 afterOperation, uint256 minimalRequired);

  /// @notice Burn asked for more shares than exist for that position in a bin.
  /// @param requested `deltas.shares[i]` for the offending bin.
  /// @param available Shares recorded for `owner`+`salt` in that bin before the call.
  error InsufficientLiquidity(uint256 requested, uint256 available);

  /// @notice The modify-liquidity callback sent fewer tokens than the pool debt for this add.
  /// @dev Fires after the pool computed required `amount0`/`amount1` and invoked `msg.sender`; safe for retry once the callback actually pays.
  error InsufficientTokenBalance();

  /// @notice `removeLiquidity` caller is not the position owner.
  /// @dev Only `owner` may burn; `addLiquidity` may use a different `msg.sender` when `owner` is supplied, but removal is stricter.
  error NotPositionOwner();

  /// @notice Deposit allowlist rejected this `owner` for `addLiquidity`.
  /// @dev Only when `DEPOSIT_ALLOWLIST_PROVIDER` is configured on the pool; removal is not subject to the same check.
  error NotAllowedToDeposit();

  /// @notice `LiquidityDelta` arrays are not the same length.
  /// @dev Checked before touching state; fix the payload and resubmit.
  error LiquidityDeltaLengthMismatch();

  /// @notice A bin index in `deltas.binIdxs` is outside this pool’s `[LOWEST_BIN, HIGHEST_BIN]`.
  /// @param binIdx First failing index from the caller payload.
  error InvalidBinIndex(int256 binIdx);

  // ============ Errors: Swap ============

  /// @notice Swap callback paid the wrong token amount vs what the pool requested.
  /// @dev Distinct from `InsufficientTokenBalance` (liquidity path); indicates `IMetricOmmSwapCallback` settlement mismatch, not bare underpay.
  error IncorrectDelta();

  /// @notice Swap allowlist rejected `msg.sender`.
  /// @dev Only `swap` checks this when `SWAP_ALLOWLIST_PROVIDER` is set; `simulateSwapAndRevert` does not, so a passing simulation does not imply an allowed live swap.
  error NotAllowedToSwap();

  /// @notice `amountSpecified == 0` (or otherwise non-actionable amount) on `swap` / `simulateSwapAndRevert`.
  error InvalidAmount();

  /// @notice An intermediate scaled swap quantity did not fit in `uint128`.
  /// @dev Surfaces overflow-style failures in swap math before silent wrap; typically extreme size or price inputs.
  error AmountScaledExceedsMax();

  /// @notice Swaps are disabled while the pool pause level is non-zero.
  /// @dev Pause level is factory-controlled; liquidity mutators are intentionally not blocked by the same check.
  error PoolPaused();

  /// @notice Bid price is not strictly below ask (`bidPriceX64 >= askPriceX64`).
  /// @dev On `swap`, comes from the live `IPriceProvider` quote; on `simulateSwapAndRevert`, from the arguments you passed.
  error BidGreaterThanAsk();

  /// @notice Bid price was zero, so mid/spread cannot be formed.
  /// @dev On `swap`, from the live provider; on `simulateSwapAndRevert`, from `bidPriceX64` you passed.
  error BidIsZero();

  /// @notice External call to the active `IPriceProvider` reverted or bubbled a failure.
  /// @param reason Opaque revert data from the provider (decode off-chain if the provider documents errors).
  error PriceProviderFailed(bytes reason);

  /// @notice Deliberate revert carrying simulated swap deltas; no callbacks and no token transfers.
  /// @dev Runs the same swap math and extension path as `swap` (with caller-supplied bid/ask instead of the live oracle) then always `revert SimulateSwap(...)`, rolling back any transient storage writes, so committed chain state is unchanged. Omits `whenNotPaused` and swap-allowlist checks present on `swap`, so results can differ from what a live transaction would allow. Decode `SimulateSwap` from the revert data (`eth_call` / `try/catch`); ABI return values are unused.
  /// @param amount0Delta Simulated net token0 delta for the pool (same sign convention as `swap` returns).
  /// @param amount1Delta Simulated net token1 delta for the pool.
  error SimulateSwap(int256 amount0Delta, int256 amount1Delta);

  // ============ Mutating: Liquidity ============

  /// @notice Mint shares across bins for `(owner, salt)`; pulls tokens via `IMetricOmmModifyLiquidityCallback` on `msg.sender`.
  /// @dev Callback receives native token amounts the pool expects; underpay reverts `InsufficientTokenBalance`. If `DEPOSIT_ALLOWLIST_PROVIDER` is set, `owner` must pass allowlist. `msg.sender` pays but need not equal `owner` (operator pattern).
  /// @param owner Position owner encoded in the pool’s position key.
  /// @param salt Namespace byte width for the key (`uint80`).
  /// @param deltas Parallel `binIdxs` / `shares` arrays (see `LiquidityDelta`).
  /// @param callbackData Opaque bytes forwarded unmodified to the modify-liquidity callback.
  /// @param extensionData Opaque bytes forwarded to liquidity extensions (beforeAddLiquidity / afterAddLiquidity).
  /// @return amount0Added Total token0 actually pulled from the callback into the pool (native).
  /// @return amount1Added Total token1 actually pulled from the callback into the pool (native).
  /// @dev Reverts `LiquidityDeltaLengthMismatch` when `binIdxs` and `shares` lengths differ.
  function addLiquidity(
    address owner,
    uint80 salt,
    LiquidityDelta calldata deltas,
    bytes calldata callbackData,
    bytes calldata extensionData
  ) external returns (uint256 amount0Added, uint256 amount1Added);

  /// @notice Burn shares across bins for `(owner, salt)` and send underlying tokens to `owner`.
  /// @dev Requires `msg.sender == owner` (`NotPositionOwner` otherwise). No callback: tokens are transferred out directly.
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
  /// @dev Reverts `PoolPaused` when paused. Pulls input from `msg.sender` through `IMetricOmmSwapCallback`; sends output toward `recipient` for the owed token leg. `priceLimitX64` is compared against Q64.64 marginal prices along the bin path (`SwapMath` vs segment bounds); inequality direction depends on `zeroForOne` and exact-in vs exact-out—values that never cross the active path behave as no-op swaps (zero deltas). Some legs treat `priceLimitX64 == 0` as “no extra crossing constraint”; see `MetricOmmPool` / `SwapMath` for exact comparisons.
  /// @param recipient Address that receives the output token (subject to callback flow settling the input first).
  /// @param zeroForOne `true` sells token0 for token1 along the pool’s ordering.
  /// @param amountSpecified Exact input if `>0`, exact output magnitude if `<0`, in native units of that leg.
  /// @param priceLimitX64 Q64.64 execution bound along the swap direction (see `@dev`).
  /// @param callbackData Opaque bytes forwarded to the swap callback.
  /// @param extensionData Opaque bytes forwarded to swap extension point functions (beforeSwap / afterSwap).
  /// @return amount0Delta Net token0 change for the pool (signed, native).
  /// @return amount1Delta Net token1 change for the pool (signed, native).
  function swap(
    address recipient,
    bool zeroForOne,
    int128 amountSpecified,
    uint128 priceLimitX64,
    bytes calldata callbackData,
    bytes calldata extensionData
  ) external returns (int128 amount0Delta, int128 amount1Delta);

  /// @notice Run swap math with caller-supplied bid/ask; always reverts with `SimulateSwap` carrying the net deltas.
  /// @dev Does not use the pool’s live oracle prices for the mid—use for quotes/off-chain routing. Invokes the same swap extension point functions as `swap` when enabled; still enforces `priceLimitX64` and path logic; no ERC20 transfers or swap callback. Typical usage: `eth_call` or `try/catch` decoding `SimulateSwap`.
  /// @param recipient Same as `swap` (forwarded to swap extension point functions).
  /// @param zeroForOne Same as `swap`.
  /// @param amountSpecified Same sign convention as `swap`.
  /// @param priceLimitX64 Same encoding as `swap`.
  /// @param bidPriceX64 Bid used for extension context and swap math in this simulation (Q64.64).
  /// @param askPriceX64 Ask used for extension context and swap math in this simulation (Q64.64).
  /// @param extensionData Opaque bytes forwarded to swap extension point functions (beforeSwap / afterSwap).
  /// @return amount0Delta Unused in practice; values appear only on the reverting `SimulateSwap` error.
  /// @return amount1Delta Unused in practice; values appear only on the reverting `SimulateSwap` error.
  function simulateSwapAndRevert(
    address recipient,
    bool zeroForOne,
    int128 amountSpecified,
    uint128 priceLimitX64,
    uint128 bidPriceX64,
    uint128 askPriceX64,
    bytes calldata extensionData
  ) external returns (int128 amount0Delta, int128 amount1Delta);
}
