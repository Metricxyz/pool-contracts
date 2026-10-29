# Audit Findings Resolution Notes

This document tracks our resolution decisions for external audit findings.

## C01 - Pool can be drained via reentrancy

### Resolution status

Already fixed in history.

### Fix commit

- `a4e72f153382a327c4fa14ac2b78c0ab45428142` (`2026-02-17`)
- Message: `fix bugs found by auditors on 17.02.26`
- File: `contracts/MetricOmmPool.sol`

### Notes

- In audited baseline `b0770dc8a5775fb5c4393c7713d4e7f08df7d08a`, `modifyLiquidity` had no reentrancy guard.
- Commit `a4e72f1...` added `nonReentrant` to `modifyLiquidity`, preventing callback-driven reentry during swap execution.

---

## C02 - Incorrect swap formula

### Finding summary

`computeAnalyticalTargetPosForSellToken0()` used a quadratic-root expression for token0->token1 specified-in target estimation.

### Resolution

Fixed.

For sell-token0 direction, midpoint-price math gives an exact rational closed form:

- `in0 = A * d / (1 - r * d)`
- `A = T1 * 2^64 * (1 + fee/1e6) / (c * Pc)`
- `r = ΔP / (2 * M * Pc)`
- `d = in0 / (A + in0 * r)` (equivalently `d = Q / (1 + rQ)`, `Q = in0 / A`)

Implementation now uses this rational form directly in `SwapMath.computeAnalyticalTargetPosForSellToken0` instead of the quadratic-root approximation.

---

## M01 - Admin can arbitrarily change the pool priceProvider

### Finding summary

`setPriceProvider()` allowed admin to replace oracle at runtime, and `priceProvider` was returned by `getImmutables()`.

### Resolution

Fixed.

Changes:

- Added constructor config `priceProviderTimelock`.
- Added admin flow:
  - `proposePriceProvider(address newPriceProvider)`
  - `executePriceProviderUpdate()`
- Added events:
  - `PriceProviderChangeProposed(currentPriceProvider, newPriceProvider, executeAfter)`
  - `PriceProviderUpdated(newPriceProvider)`

Behavior now:

- `priceProviderTimelock == type(uint256).max` => immutable mode (admin updates disabled).
- `priceProviderTimelock < type(uint256).max` => mutable mode with delayed execution.
- Price provider used by swaps/reports resolves through timelock mode; active provider is read via `MetricOmmPoolStateView.priceProvider(pool)`.

### Verification

- Added tests:
  - `test_priceProviderTimelock_immutableMode_revertsPropose`
  - `test_priceProviderTimelock_proposeAndExecute`

---

## M02 - Drift update uses the wrong reference price

### Finding summary

The audit claims drift should be updated against the oracle mid-price.

### Project intent (confirmed)

In this protocol, `driftE8` is a short-horizon movement accumulator with time decay. It is used to limit how much additional move can happen in the same direction over recent time. It is **not** intended to represent absolute pool-vs-oracle distance.

Implication:

- Large absolute pool/oracle deviation is allowed if reached slowly.
- Rapid directional movement is constrained.

### Resolution

Marked as **Not Applicable by Design**.

We keep movement-tracking semantics in swap finalization:

- Up move: add positive trade drift.
- Down move: add negative trade drift.
- Trade drift is measured from swap start to swap end (relative move), then accumulated into `driftE8`.

### Verification

Added regression test:

- `test_finalizeSwap_updatesDriftFromSwapMove`

---

## M03 - Incorrect drift price-limit calculation

### Finding summary

The audit notes drift price limits are calculated around oracle mid-price, which can incorrectly disable one direction when the pool is already far from mid.

### Root cause

The old implementation used a mid-centered bound:

- Upward bound was derived directly from `midPrice`.
- Downward bound was derived directly from `midPrice`.

This does not match movement-rate semantics because the swap should be limited relative to the **current swap start price**, not absolute mid anchor.

### Resolution

Fixed.

We now:

1. Compute `initialPriceX64` first in `_updateDriftAndGetInitialStateForSwap`.
2. Apply drift limit around that initial price.
3. Keep drift step size based on oracle mid-price (stable unit scale).

Formulas:

- `availableDriftE8(up) = MAX_DRIFT_E8 - driftE8`
- `availableDriftE8(down) = MAX_DRIFT_E8 + driftE8`
- `moveX64 = ceil(midPriceX64 * availableDriftE8 / 1e8)`
- Upward drift bound: `driftLimit = initialPriceX64 + moveX64`
- Downward drift bound: `driftLimit = max(0, initialPriceX64 - moveX64)`

Final effective limit:

- Going up: `min(userPriceLimit, driftLimit)`
- Going down: `max(userPriceLimit, driftLimit)`

This preserves the intended behavior: directional movement is rate-limited, but long-term drift can continue if it happens slowly enough (with decay).

### Verification

Added regression tests:

- `test_driftLimit_appliedAroundInitialPrice_goingUp`
- `test_driftLimit_appliedAroundInitialPrice_goingDown`

Existing drift suite remains green:

- `forge test --match-contract MetricOmmPoolDriftTest -vv`

---

## M04 - Missing bin index bound checks

### Resolution status

Already fixed in history.

### Fix commit

- `504af3f1bbd88b86e81b20b41251fdf647ded8db` (`2026-02-18`)
- Message: `fix: add HIGHEST_BIN/LOWEST_BIN guards to swap loops to prevent unbounded traversal on donated tokens`
- Files: `contracts/MetricOmmPool.sol`, `test/MetricOmmPool.swap.t.sol`

### Notes

The fix added explicit edge-bin guards in swap traversal and regression tests covering donated-token boundary scenarios:

- `test_swap_terminatesAtHighestBin_specifiedOutput`
- `test_swap_terminatesAtHighestBin_specifiedInput`
- `test_swap_terminatesAtLowestBin_specifiedOutput`
- `test_swap_terminatesAtLowestBin_specifiedInput`

---

## M05 - Uncallable setProtocolFee function

### Finding summary

Pool `setProtocolFee()` was `onlyFactory`, but factory had no method that called it.

### Resolution

Fixed.

Added owner-gated factory function:

- `MetricOmmPoolFactory.setPoolProtocolFee(address pool, uint24 newProtocolFeeE6)`

This enables protocol governance to call pool `setProtocolFee()` through the factory (which satisfies `onlyFactory` in pool).

### Verification

Added tests:

- `test_setPoolProtocolFee_updatesPoolFee`
- `test_setPoolProtocolFee_onlyOwner`
- `test_setPoolProtocolFee_revertsWhenFeeTooHigh`

---

## L01 - Excessive use of shorter integer types

### Resolution status

Addressed via two commits:

1. Historical partial refactor:
   - `1cfcc9b3af56aef3bdee8352bab0e7f5f8f7abc3`
   - Message: `refactor: widen prices/amounts/fees to uint256 in SwapMath and MetricOmmPool; keep  bin-position types as uint104`

2. Current pending commit (this changeset):
   - Completes remaining L01-focused widening where it reduces cast overhead and improves readability.

### Conclusion

L01 is resolved as a combined effort of the historical widening refactor (`1cfcc9b...`) and the current commit.

---

## L02 - Lack of basic configuration checks

### Finding summary

Pools could be deployed with unsafe constructor parameters (notably drift settings and distance configuration), which is risky given unchecked-heavy math paths.

### Resolution

Fixed.

Validation is now centralized in `MetricOmmPoolFactory.createPool()` before deployment:

- Drift bounds:
  - `0 < maxDriftE8 < 50_000_000` (strictly below 50%)
  - `0 <= driftDecayPerSecondE8 <= maxDriftE8`
- Bin-distance domain:
  - `curBinDistFromProvidedPriceE6` must stay within `[-999_999, 999_999]`
  - While traversing configured bins, every cumulative boundary must stay in that same range
  - This guarantees positive price multipliers in `distanceE6ToPriceX64` and prevents invalid negative/zero price configurations
- Basic deployment sanity:
  - token pair must be non-zero and non-identical
  - `priceProvider`, `admin`, `adminFeeDestination` must be non-zero
  - `adminFee <= 200_000`
  - initial per-liquidity densities and `minimalMintableLiquidity` must be non-zero
  - non-negative bin array must not be empty

To reduce pool bytecode size, these checks are enforced at factory level and redundant constructor checks were removed from `MetricOmmPool`.

### Verification

Added factory regression tests:

- `test_createPool_revertsWhenMaxDriftNonPositive`
- `test_createPool_revertsWhenMaxDriftAtOrAboveFiftyPercent`
- `test_createPool_revertsWhenDriftDecayNegative`
- `test_createPool_revertsWhenDriftDecayAboveMaxDrift`
- `test_createPool_revertsWhenCurrentDistanceOutOfRange`
- `test_createPool_revertsWhenPositiveBinsExceedDistanceDomain`
- `test_createPool_revertsWhenNegativeBinsExceedDistanceDomain`
- `test_createPool_revertsWhenNonNegativeBinsEmpty`

---

## L03 - Inconsistent protocol fee limits

### Finding summary

Factory allowed up to 50% protocol fee while pool enforced 20%, and constructor-time fee limits were not fully aligned with runtime checks.

### Resolution

Fixed.

Changes:

- Unified factory limit to 20% (`MAX_PROTOCOL_FEE = 200_000`) to match pool.
- Added upfront validation in `MetricOmmPool` constructor for:
  - `_protocolFee <= MAX_PROTOCOL_FEE_E6`
  - `_adminFee <= MAX_ADMIN_FEE_E6`
- Added factory-side guard in `setPoolProtocolFee` before forwarding call to pool.

### Verification

Added tests:

- `test_factoryConstructor_revertsWhenInitialProtocolFeeTooHigh`
- `test_setprotocolFee_revertsWhenFeeTooHigh`
- Updated `test_setPoolProtocolFee_revertsWhenFeeTooHigh`

---

## L04 - Misleading poolKey

### Finding summary

`poolKey` omitted some constructor-relevant fields (notably `admin` and `adminFeeDestination`), which could make the key misleading as an identifier.

### Resolution

Fixed.

Removed the derived `poolKey` concept entirely:

- `createPool` now forwards `params.salt` directly as CREATE2 salt.
- Factory emits `PoolCreated(poolAddress, constructorArgs...)` with full deployment context.

This avoids having a second identifier that could diverge from actual deployment semantics.

---

## L05 - Misleading custom error

### Finding summary

`onlyAdmin` was previously reported as reverting with `OnlyFactory()`.

### Resolution

Already fixed.

Current `onlyAdmin` in `MetricOmmPool` reverts with `OnlyAdmin()` and corresponding interface error is present in `IMetricOmmPoolAdmin`.

---

## L06 - Unused custom error

### Finding summary

`InvalidTokenOrder()` existed in factory but was not used.

### Resolution

Fixed.

Removed `InvalidTokenOrder()` from the factory since token-order validation is not part of the current factory design.

---

## L07 - Unused pool parameter (`minimalMintableLiquidity`)

### Finding summary

`MINIMAL_MINTABLE_LIQUIDITY` was stored but not enforced, allowing dust positions.

### Resolution

Fixed.

`modifyLiquidity` now enforces minimum position shares:

- On add: resulting position shares must be `>= MINIMAL_MINTABLE_LIQUIDITY`
- On remove: resulting non-zero position shares must be `>= MINIMAL_MINTABLE_LIQUIDITY`
- Reverts with `MinimalLiquidity(afterOperation, minimalRequired)` otherwise.

### Verification

Added tests:

- `test_modifyLiquidity_revertsWhenMintBelowMinimalLiquidity`
- `test_modifyLiquidity_revertsWhenWithdrawalLeavesDust`

---

## L08 - Unnecessary linear correction for rounding gap

### Resolution status

Accepted by Design.

Current exact-input in-bin logic intentionally keeps scaling/correction behavior as a budget-control mechanism under integer rounding.

Design rationale:

- Enforce input-budget safety (`consumed <= amountSpecified`) in all exact-input paths.
- Treat this as a deliberate execution-policy choice to always consume amountSpecified if possible.

### Verification

Existing tests cover the intended behavior:

- `testFuzz_exactInput_consumedNeverExceedsSpecified`
- `test_exactInput_consumesExactAmount_token1ForToken0`
- `test_exactInput_consumesExactAmount_token0ForToken1`

---

## L09 - Redundant rounding compounds numerical error

### Finding summary

`calculateRequiredToken0()` and `calculateRequiredToken1()` applied manual `+1` adjustments while also using `Math.ceilDiv`, adding redundant upward bias.

### Resolution

Fixed.

Changes in `SwapMath`:

- `calculateRequiredToken1`: removed `+1` from `token0Amount` before multiplication.
- `calculateRequiredToken0`: removed `+1` from `token1Amount` before left-shift.

Both paths still round conservatively via `Math.ceilDiv`, but without double-rounding adjustments.

### Verification

- `forge test -q`
- `forge test --match-test testFuzz_BenchmarkComparison_Token0 -vv`
