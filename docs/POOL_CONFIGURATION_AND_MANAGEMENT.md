# Pool configuration and management

This document describes how **Metric OMM pools** are configured at creation and how the **pool admin** and **protocol (factory owner)** manage them after deployment. It maps to `MetricOmmPoolFactory`, `MetricOmmPoolDeployer`, and `MetricOmmPool` in `contracts/`.

---

## 1. Configuration overview

Operational entrypoint for new pools is **`MetricOmmPoolFactory.createPool(PoolParameters)`**. The factory validates parameters, derives a few values, and calls the deployer, which runs **`MetricOmmPool`’s constructor** via CREATE2.

You should think in three layers:

| Layer                           | What it is                                                                                                                                                                                                                   |
| ------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`PoolParameters`**            | What integrators pass to `createPool`.                                                                                                                                                                                       |
| **`DeployParams`**              | Arguments to `MetricOmmPoolDeployer.deploy`: **scaled** initial per-share amounts, multipliers, bin state, oracle flags, and **total** spread/notional fees (`spreadFeeE6`, `notionalFeeE8`) passed to the pool constructor. |
| **`MetricOmmPool` constructor** | Final immutables and initial bin state burned into the pool bytecode/instance.                                                                                                                                               |

---

## 2. `PoolParameters` and constructor mapping

The struct is defined as **`PoolParameters`** in `contracts/types/FactoryOperation.sol` (argument to `IMetricOmmPoolFactory.createPool`). Below, each field lists its **role**, how it maps to the pool, and **guidelines**.

### 2.1 Tokens and ordering

| Parameter                  | Role                                                               | Guidelines                                                                                                                    |
| -------------------------- | ------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------- |
| **`token0`**, **`token1`** | The two ERC-20 assets; must match the price provider’s base/quote. | Distinct, non-zero addresses. Ordering must match `IPriceProvider.token0()` / `token1()` (`token0` = base, `token1` = quote). |

### 2.2 Price oracle

| Parameter                   | Role                                                                                                                                                                                                                                                                                            | Guidelines                                                                                                                                                                                                                                       |
| --------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **`priceProvider`**         | Oracle implementing `IPriceProvider`; pool reads bid/ask for pricing.                                                                                                                                                                                                                           | Non-zero; its `token0()` / `token1()` must equal the pool's or `createPool` reverts **`PriceProviderTokenMismatch`**. Choose an implementation you trust to be available and correct for the pool’s lifetime.                                    |
| **`priceProviderTimelock`** | If **`type(uint256).max`**, the pool treats the oracle as **immutable** (`getImmutables().immutablePriceProvider` is non-zero; no rotations). Otherwise, seconds to wait after `proposePoolPriceProvider` before `executePoolPriceProviderUpdate`, stored in **`priceProviderTimelock[pool]`**. | Use `type(uint256).max` only when you want the oracle address fixed forever. For rotatable oracles, pick a finite delay that balances security and operations; a value where `block.timestamp + timelock` overflows makes every proposal revert. |

#### 2.2.1 Reference price and the asymmetry bound

The provider returns **three** prices from `getQuote()`: `bid`, `ask`, and a `reference` that must satisfy `bid <= reference <= ask`. The reference anchors the bin ladder and sets each side's base fee (`ask/reference - 1` when buying token0, `reference/bid - 1` when selling it). Ignoring fixed-point rounding, those two effects cancel, so the marginal execution price is `ask * (1 + d)` on a buy and `bid * (1 + d)` on a sell **regardless of where the provider puts the reference**, as long as the per-bin add fee and notional fee are zero (`d` is the current E6 distance divided by `1e6`). Finite swaps use endpoint-average costs, as described in [Swap math](SwapMath.md). Those fees are added on top of a reference-anchored price, so that part of the execution price still moves with the reference.

What it does control is how the spread is split between the two sides. `bidAskRefAsymmetryX8` bounds that split.

| Parameter                  | Role                                                                                                                                                                                                                                                                                                                                                                         | Guidelines                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| -------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`bidAskRefAsymmetryX8`** | Slack `m` in **X8** (`m = bidAskRefAsymmetryX8 / 256`, `M = 1 + m`) on how far the reference may sit from the geometric mean of bid and ask. With `r1 = reference/bid - 1` and `r2 = ask/reference - 1`, the pool requires `1/M <= r1/r2 <= M` after every quote, reverting `BidAskRefAsymmetryOutOfBounds`. The geometric mean is the exactly-symmetric point (`r1 == r2`). | Must be **non-zero** or `createPool` reverts `BidAskRefAsymmetryTooLow`, and `<= factory.onCreationMaxBidAskRefAsymmetryX8` or `createPool` reverts `BidAskRefAsymmetryTooHigh`. **`type(uint16).max` disables the check** and is the only setting that also permits a reference sitting exactly on `bid` or `ask` (which waives that side's base fee). Larger values are looser: `M = 2` (`256`) admits approximately the middle third for a narrow spread; the exact bound is on `r1/r2`. |

> **`0` is rejected.** `0` means `M = 1`, which demands `r1 == r2` exactly, i.e. `reference² == bid · ask` in Q64.64 integers. Almost no real quote meets that, so a pool holding `0` would revert practically **every swap, simulation and quote**. Because `0` is the zero value of the struct field, the factory rejects it on every path that can set it — `createPool`, `setPoolBidAskRefAsymmetryX8` and `setPoolBidAskRefAsymmetryX8Batch` all revert **`BidAskRefAsymmetryTooLow`**. Pick `type(uint16).max` to disable the check, or a deliberate non-zero bound to enable it.

### 2.3 Extensions

| Parameter               | Role                                                                                                                                                         | Guidelines                                                                                                                                                                       |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`extensions`**        | Up to seven optional contracts implementing `IMetricOmmExtensions`, with per-action call order via **`extensionOrders`**.                                    | Use an empty `extensions` array with zeroed `extensionOrders` for no extensions. Reference implementations: **metric-periphery** (allowlist, price guard, stop-loss extensions). |
| **`extensionOrders`**   | Encodes invocation order per action (`beforeAddLiquidity`, `afterAddLiquidity`, `beforeRemoveLiquidity`, `afterRemoveLiquidity`, `beforeSwap`, `afterSwap`). | Must be zero when `extensions` is empty; at least one non-zero order when extensions are set.                                                                                    |
| **`extensionInitData`** | Per-extension initialization calldata.                                                                                                                       | Length must equal `extensions` (`InvalidExtensionsConfig` otherwise); use an empty array when there are no extensions. It also feeds the CREATE2 salt (§2.8).                    |

Extension addresses must be non-zero and distinct. Each order packs 1-based extension indices in 3-bit groups, least significant group first; indices must be within the supplied array and cannot repeat within one order. A zero group below a non-zero group is invalid (`InvalidExtensionOrder`). Every supplied extension is initialized in array order after deployment, before the factory records the pool admin, fees, timelock or registry entry. Initialization and hook calls must return at least 32 bytes with the called selector in the first four bytes; failures revert the transaction.

### 2.4 Admin and fee routing at creation

| Parameter                   | Role                                                                                                                                                                                                     | Guidelines                                                                                                                                                                           |
| --------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **`admin`**                 | Becomes **`poolAdmin[pool]`** on the factory; this address controls pool-scoped admin actions (fees, admin fee destination, per-bin additional fees, pause L1, oracle proposal/execute, admin transfer). | Non-zero; use a multisig or explicit admin contract, not an EOA unless you accept key risk.                                                                                          |
| **`protocolSpreadFeeE6`**   | **Protocol spread fee** for this pool in **E6**.                                                                                                                                                         | Must be ≤ **`maxProtocolSpreadFeeE6`**. Values below the factory default **`spreadProtocolFeeE6`** are clamped up to that default. Total spread is effective protocol + admin.       |
| **`adminSpreadFeeE6`**      | **Admin spread fee** component in **E6** (`1e6 = 100%`).                                                                                                                                                 | Must be ≤ factory **`maxAdminSpreadFeeE6`**.                                                                                                                                         |
| **`protocolNotionalFeeE8`** | **Protocol notional fee** for this pool in **E8**.                                                                                                                                                       | Must be ≤ **`maxProtocolNotionalFeeE8`**. Values below the factory default **`protocolNotionalFeeE8`** are clamped up to that default. Total notional is effective protocol + admin. |
| **`adminNotionalFeeE8`**    | **Admin notional fee** component in **E8** (`1e8 = 100%`).                                                                                                                                               | Must be ≤ factory **`maxAdminNotionalFeeE8`**.                                                                                                                                       |
| **`adminFeeDestination`**   | Address that receives the **admin share** when fees are collected via the factory.                                                                                                                       | Non-zero. Must be able to receive both tokens (and any ETH policy you use off-pool).                                                                                                 |

**Note:** Factory defaults (`spreadProtocolFeeE6` / `protocolNotionalFeeE8`) are floors for create-time protocol fees (under-floor inputs are raised to the default). Creators may set higher values up to the caps. All four components can be tuned later within caps via **`setPoolAdminFees`** (pool admin, §5.1) and **`setPoolProtocolFee`** (factory owner, §6.2).

Spread components are shares of the oracle spread plus the per-bin additional fee, not extra fees added to the trader's price. The pool retains the remaining spread fee in the bin for LPs. Notional fees are added to the trader's fee and allocated entirely to protocol/admin. See [Swap math](SwapMath.md#fee-allocation).

### 2.5 Initial liquidity geometry and limits

| Parameter                                                                      | Role                                                                                                                                                                                                                                                   | Guidelines                                                                                                                                    |
| ------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------- |
| **`initialScaledAmount0PerE18Shares`**, **`initialScaledAmount1PerE18Shares`** | Empty-bin mint density in **internal (scaled) precision** for **`1e18` shares** (`P̂`). Passed through to the pool as **`INITIAL_SCALED_TOKEN_*_PER_SHARE_E18`**. Whole tokens for `1e18` shares are **`A = P̂ / 10^D`** with **`D = max(18, d0, d1)`**. | See **Choosing `P̂`** below. Both must be **non-zero** and **`< type(uint128).max`** (the factory rejects `>=`).                               |
| **`minimalOperationalLiquidity`**                                              | Minimum **non-zero per-row share delta** on add/remove, and minimum **non-zero** per-position per-bin share balance after a remove.                                                                                                                    | Must be at least `max(1, floor(1e6 · 1e18 / min(P̂0, P̂1)))`. Too high excludes small LPs; too low increases rounding / composition edge cases. |

#### Choosing `initialScaledAmount{0,1}` (`P̂`)

Notation: `P̂_i` = scaled initial per-share amount (pool immutable). `D = max(18, d0, d1)`. `π0` = opening price, token1 per token0 in whole-token terms. `ρ = max(π0, 1/π0)`.

**Always required (deployer duty — core does not validate the ratio):**

1. **`P̂1 / P̂0 = π0`.** `LiquidityLib` seeds the current bin by linearly blending both amounts via `curPosInBin`; a wrong ratio makes a share worth different amounts on either side of the current price. **Not validated on-chain and cannot be** — the price provider may not yet be serving a price at `createPool`.
2. **`P̂_i < type(uint128).max`** — factory-enforced (also non-zero).
3. **Bin capacity is independent of `P̂`:** `BinState.token{i}BalanceScaled` is `uint104`. Max whole tokens per bin: `(2^104−1)/10^D` ≈ `2.0282e13` at `D = 18`. A >18-decimal token raises `D` and shrinks every bin by `10^(D−18)`.
   - **Swaps:** writing the _incoming_ side past that cap reverts with `OverflowedOnFittingBinBalances(attemptedScaledBalance)`. This can stop trading in one direction in the bin until LPs withdraw or a swap in the opposite direction drains that side;
   - **Adds:** a deposit that would exceed the same width reverts with **`SharesAmountTooLarge`** or a `SafeCast` overflow.
4. `P̂` sets the share denomination and feeds `minimalOperationalLiquidity` sizing.

**Recommendation for pools using `OracleValueStopLossExtension`** (metric-periphery). That extension uses `METRIC_SCALE = 1e18` and `uint104` watermarks; each side’s watermark starts near `P̂_i` (set on the first swap through the bin) and must stay in `[1e6, 2^104−1]` as price moves (`1e6` is a precision floor). **`1e6` is a judgement call**, not a derivation.

```
K  = 1e6 · (2^104 − 1) ≈ 2.0282409603651670e37
P̂0 = √(K / π0)        P̂1 = √(K · π0)        √(P̂0·P̂1) ≈ 4.5036e18 always
F  = 4.5036e12 / √ρ    → supported price band [π0/F, π0·F]
```

| pair                 | `π0`   | `P̂0`      | `P̂1`      | `F` each way |
| -------------------- | ------ | --------- | --------- | ------------ |
| stable/stable        | 1      | 4.504e18  | 4.504e18  | 4.5e12×      |
| USDC/WETH ($1/$3000) | 1/3000 | 2.4667e20 | 8.2224e16 | 8.2e10×      |
| WBTC/USDC ($1e5/$1)  | 1e5    | 1.4242e16 | 1.4242e21 | 1.4e10×      |

```solidity
function initialScaledAmounts(uint256 pi0E18) pure returns (uint256 pHat0, uint256 pHat1) {
    uint256 K = 1e6 * uint256(type(uint104).max); // W_floor · W_max
    pHat0 = Math.sqrt(Math.mulDiv(K, 1e18, pi0E18));
    pHat1 = Math.sqrt(Math.mulDiv(K, pi0E18, 1e18));
}
```

Core enforces the non-zero density bounds and minimum share threshold, but does not validate `P̂1/P̂0 = π0`. The stop-loss formulas above are guidance only.

### 2.6 Swap extension point context (oracle + slot0)

| Topic                                                   | Role                                                                                                                                                                                                                                                                                                             | Guidelines                                                                                                                                                                                                                                                  |
| ------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`packedSlot0Initial` / `packedSlot0Final`**           | `uint256` word matching storage slot 0 before and after the bin walk. Decode with `Slot0Library.unpack` (`curBinIdx`, `curPosInBin`, fees, pause).                                                                                                                                                               | Use for analytics, price guards, and reporting final bin position.                                                                                                                                                                                          |
| **`bidPriceX64` / `askPriceX64` / `referencePriceX64`** | Passed to both swap extension point functions from the pool’s single `getQuote()` per `swap` (same quotes used for swap math).                                                                                                                                                                                   | Extensions should not re-read the oracle unless a fresher quote is intentional.                                                                                                                                                                             |
| **Reporting**                                           | The pool never calls back into the price provider; report swaps from an **`afterSwap`** extension point function in an integrator-written extension.                                                                                                                                                             | Use `try/catch` inside the extension for best-effort reporting.                                                                                                                                                                                             |
| **`simulateSwapAndRevert`**                             | Invokes the same swap extension point functions as `swap` when `extensionOrders` are configured; uses caller-supplied `bidPriceX64` / `askPriceX64` / `referencePriceX64` for extension context and math (not the live oracle), and a caller-supplied `sender` forwarded to extensions in place of `msg.sender`. | Pass the same `recipient`, `extensionData`, and (usually) `msg.sender` as `sender` that you intend for a live swap so simulation matches extension gates and side effects; pass a different `sender` to check a sender-gated extension for another address. |

Swap hooks receive native-unit `amount0Delta` / `amount1Delta`, but `platformFeeAmount` is the combined platform fee in **scaled input-token units**. Simulations validate the supplied quote, run both hooks, skip token transfers and the settlement callback, then revert with `SimulateSwap`; execution failures instead propagate their error. Both deltas must fit `int128` before `afterSwap`, even though the simulation error declares `int256` fields. The revert rolls back all state changes. `inSwap()` returns the active provider during live `swap` and `getSellAndBuyPrices`, but zero during simulation.

### 2.7 Bin ladder anchor

| Parameter                           | Role                                                                                                                                                | Guidelines                                                                                                                                                                                                                                                                                    |
| ----------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`curBinDistFromProvidedPriceE6`** | **int24** distance in **E6** units anchoring the bin ladder relative to the oracle reference price (same distance domain the pool uses internally). | The anchor must satisfy **`minBinDistanceE6 <= anchor <= maxBinDistanceE6`** (factory storage, owner-configurable; defaults `-500_000` and `1_000_000`), else `createPool` reverts **`BinDistanceOutOfRange(0, anchor)`**. The cumulative walk over the bins uses the same bounds — see §2.9. |

### 2.8 Packed bin arrays

| Parameter                     | Role                                                                                                                                                                                                                                                                                                                                                                                                                                                         | Guidelines                                                                                                                                                                                                                                                                                                                                                                            |
| ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`nonNegativeBinDataArray`** | Packed config for bins **0 … highest** (above/on the “positive” side of the ladder).                                                                                                                                                                                                                                                                                                                                                                         | Must be **non-empty** and respect packing rules (§2.9).                                                                                                                                                                                                                                                                                                                               |
| **`negativeBinDataArray`**    | Packed config for bins **-1 … lowest** (below side).                                                                                                                                                                                                                                                                                                                                                                                                         | May be empty. Each side is capped at **32,768** bins independently, so a pool can hold up to 65,536 bins.                                                                                                                                                                                                                                                                             |
| **`salt`**                    | Caller input to the CREATE2 salt. The factory deploys with `keccak256(abi.encode(salt, admin, adminFeeDestination, extensionInitData, priceProviderTimelock, protocolSpreadFeeE6, adminSpreadFeeE6, protocolNotionalFeeE8, adminNotionalFeeE8))`, using the protocol fees **after** clamping to the factory defaults (§2.4). CREATE2 executes inside **`MetricOmmPoolDeployer`**, so the **deployer** address (not the factory's) enters address derivation. | The pool address also depends on the pool init code, which contains every constructor argument (tokens, price provider, extensions, bins, fee totals, …). Two `createPool` calls on the same deployer therefore collide only when all of these and the salted fields match; the second call reverts. Change `salt` to deploy a second pool with an otherwise identical configuration. |

### 2.9 Bin packing format (`BinDataLibrary`)

Each logical bin is **48 bits**:

- **bits 0–15:** `lengthE6` (uint16) — segment length in E6 distance units along the ladder.
- **bits 16–31:** `addFeeBuyE6` (uint16) — extra fee for the “buy token0” direction (E6).
- **bits 32–47:** `addFeeSellE6` (uint16) — extra fee for the “buy token1” direction (E6).

Up to **five** bins are packed per **`uint256`**, little-endian within the word (position `0` = lowest bits).

**Factory rules (high level):**

- `nonNegativeBinDataArray` must be non-empty (**`BinArraysEmpty`**); `negativeBinDataArray` may be empty.
- Slot **0** of every visited packed word must have non-zero `lengthE6`, else **`BinLengthZero(binIdx)`**.
- A zero `lengthE6` at slot **1–4** terminates that side's walk **silently**: that bin and every remaining word of the array are discarded — not validated, not deployed. Only pad the tail you actually mean to drop.
- Walking **non-negative** bins: start from `curBinDistFromProvidedPriceE6` and **add** each bin’s `lengthE6`; every partial cumulative must be **`<= maxBinDistanceE6`**.
- Walking **negative** bins: start from the same anchor and **subtract** lengths; every partial cumulative must be **`>= minBinDistanceE6`**. Either bound reverts **`BinDistanceOutOfRange(binIdx, cumulative)`**.
- The bounds are factory storage read at `createPool`: defaults are **`-500_000`** and **`1_000_000`** (the downward budget is half the upward one, so a symmetric ladder is limited by the negative side). The owner can change them with **`setBinDistanceLimits`** (§6.1); existing pools are unaffected.
- Bin counts are capped **per side** at **32,768** (up to 65,536 bins total) so bin indices stay in **`int16`** range (factory reverts **`BinIndexRangeExceededInt16`** otherwise).

---

## 3. Deploy-time derived inputs and fee wiring

| Value                                                                        | Source                                                                                                                                                                              |
| ---------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`factory`**                                                                | The creating factory address (`address(this)`).                                                                                                                                     |
| **`token0ScaleMultiplier`**, **`token1ScaleMultiplier`**                     | Derived from **`IERC20Metadata.decimals()`** for both tokens: internal precision is `max(18, token0Decimals, token1Decimals)`, then multipliers `10 ** (internal - tokenDecimals)`. |
| **`initialScaledAmount0PerShareE18`**, **`initialScaledAmount1PerShareE18`** | Taken directly from **`PoolParameters.initialScaledAmount*PerE18Shares`** (already internal precision); passed to the deployer and pool constructor.                                |
| **`spreadFeeE6`** (total)                                                    | `max(params.protocolSpreadFeeE6, factory.spreadProtocolFeeE6) + params.adminSpreadFeeE6`; passed to the deployer and stored on the pool.                                            |
| **`notionalFeeE8`** (total)                                                  | `max(params.protocolNotionalFeeE8, factory.protocolNotionalFeeE8) + params.adminNotionalFeeE8`; passed to the deployer and stored on the pool.                                      |
| **Per-component config**                                                     | Factory stores the clamped protocol components and the admin components in **`poolFeeConfig`**; only the two totals are passed to the pool.                                         |

The deployer forwards only the two totals into **`MetricOmmPool`’s constructor**, which stores them as given.

---

## 4. Pool management: roles

| Role             | On-chain identity                                                 | Primary contract                                  |
| ---------------- | ----------------------------------------------------------------- | ------------------------------------------------- |
| **Protocol**     | `MetricOmmPoolFactory` **owner** or **`authority`** (`Auth2Step`) | Factory                                           |
| **Fee receiver** | **`feeReceiver()`**                                               | Passive sink; never calls anything                |
| **Pool admin**   | **`poolAdmin[pool]`**                                             | Factory-gated entrypoints that call into the pool |

The owner sets global fee policy, caps and defaults but never custodies protocol fees: those transfer
directly to **`feeReceiver`** at collection. Every protocol function is gated by **`requiresAuth`**: the
owner, or any caller the configured **`authority`** approves for that specific function selector — see
**`Auth`** / **`Auth2Step`** for the two-step ownership handover and authority-update mechanics.

The owner is checked before the authority, so a reverting or misconfigured authority cannot block
the owner's protocol actions, including pausing pools. Only the owner can call **`setAuthority`**;
setting it to **`address(0)`** disables delegated protocol access and leaves these actions owner-only.

### Ownership handover and delegated access

The current owner calls **`transferOwnership(newOwner)`**, then the incoming owner calls
**`acceptOwnership()`**. The configured authority and its permissions remain unchanged throughout
the handover. Existing operators retain their delegated permissions, including the former owner
if the authority separately authorizes that address. Ownership transfer alone does not revoke those
permissions.

For a handover that also revokes all delegated protocol access, the incoming owner should call
**`acceptOwnership()`** followed by **`setAuthority(address(0))`**. If the incoming owner is a multisig
that supports atomic batches, execute both calls in one transaction from that multisig so no separate
transaction can run between acceptance and disconnection. Otherwise, existing delegates remain
authorized until the authority is disconnected. This does not change per-pool admin rights.

During a routine ownership rotation, keep the authority connected if its existing operators should
remain authorized. To revoke selected delegates, use the authority's own permission-management
mechanism; becoming the factory owner does not automatically grant administrative control over the
authority contract.

The **pool contract** only accepts privileged calls from **`FACTORY`** (`onlyFactory`); admins and protocol act **through the factory** for fee collection, pausing, oracle updates, and per-bin fee tweaks.

---

## 5. Pool admin: functions and guidelines

All of the following require **`msg.sender == poolAdmin[pool]`** unless noted.

### 5.1 Fees and destination

| Function                                                                 | What it does                                                                                                                                                                                                       | Guidelines                                                                                                                                                                   |
| ------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`setPoolAdminFees(pool, newAdminSpreadFeeE6, newAdminNotionalFeeE8)`** | Allocates accrued fees using **current** stored rates and attempts payouts, then updates **admin** spread/notional components in **`poolFeeConfig`**, and calls **`setPoolFees`** on the pool with new **totals**. | New values must be ≤ **`maxAdminSpreadFeeE6`** / **`maxAdminNotionalFeeE8`**. Accounting must succeed before rates change; rejected payouts remain pending at the old split. |
| **`setPoolAdminFeeDestination(pool, newAdminFeeDestination)`**           | Reverts **`InvalidAdminFeeDestination`** on the zero address, then collects to the current destination, then updates it; pool accounting errors prevent the update.                                                | Coordinate with treasury operations.                                                                                                                                         |
| **`setPoolBinAdditionalFees(pool, bin, addFeeBuyE6, addFeeSellE6)`**     | Updates **per-bin** additional buy/sell fees on the pool (E6).                                                                                                                                                     | Use for fine-grained incentives or disincentives on specific bins; understand interaction with global spread fee.                                                            |

### 5.2 Pausing (level 1)

| Function                | What it does                              | Guidelines                                                                                 |
| ----------------------- | ----------------------------------------- | ------------------------------------------------------------------------------------------ |
| **`pausePool(pool)`**   | Sets pause level **1** (from **0** only). | Blocks **`swap` only** — see §7. Use for incidents, upgrades, or market conditions.        |
| **`unpausePool(pool)`** | Sets level **0** (from **1** only).       | Reverts at level **2**: the protocol must first move **2 → 1** with `protocolUnpausePool`. |

### 5.3 Oracle rotation (mutable provider only)

| Function                                               | What it does                                                                                                                               | Guidelines                                                                                                                                                                     |
| ------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **`proposePoolPriceProvider(pool, newPriceProvider)`** | Validates `newPriceProvider` matches pool tokens, records **pending** provider and **`executeAfter = now + priceProviderTimelock[pool]`**. | Reverts if the pool has an **immutable** oracle. A new proposal replaces any pending one and restarts the delay. Announce off-chain; ensure stakeholders know the switch time. |
| **`executePoolPriceProviderUpdate(pool)`**             | After timelock, validates again and calls **`setPriceProvider`** on the pool.                                                              | Only the **pool admin** can execute; it does not happen automatically when the timelock elapses.                                                                               |

### 5.4 Governance of admin role

| Function                                       | What it does                                                                                                                                              | Guidelines                                                                                                        |
| ---------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| **`pendingPoolAdmin(pool)`** (view)            | Returns the address awaiting **`acceptPoolAdmin`**, or **`address(0)`** if none.                                                                          | Use for UIs, multisig payloads, and monitoring between propose and accept.                                        |
| **`proposePoolAdminTransfer(pool, newAdmin)`** | Current **`poolAdmin[pool]`** records **`pendingPoolAdmin[pool] = newAdmin`**. Emits **`PoolAdminTransferProposed`**.                                     | Non-zero **`newAdmin`** and must differ from the current admin. Can be called again to replace a pending nominee. |
| **`acceptPoolAdmin(pool)`**                    | **`msg.sender`** must equal **`pendingPoolAdmin[pool]`**; then **`poolAdmin[pool]`** is updated and pending is cleared. Emits **`PoolAdminTransferred`**. | Two-step handover (like **`Auth2Step`**'s ownership transfer): the **incoming** admin must accept.                |
| **`cancelPoolAdminTransfer(pool)`**            | Current **`poolAdmin[pool]`** clears a pending transfer. Emits **`PoolAdminTransferCancelled`**.                                                          | Use if a proposal was mistaken or the nominee will not accept. Reverts if there is no pending admin.              |

---

## 6. Protocol (factory owner): functions and guidelines

These require **`requiresAuth`** on **`MetricOmmPoolFactory`** (owner or an **`authority`**-approved caller), with one exception: **`collectPoolFees`** (§6.3) is permissionless.

### 6.1 Global defaults and caps

The factory **`constructor`** takes **`(address initialOwner, address initialFeeReceiver, uint24 initialSpreadProtocolFeeE6, uint24 initialProtocolNotionalFeeE8, uint16 initialOnCreationMaxBidAskRefAsymmetryX8)`**. It opens all four fee caps at their hard ceilings, sets **`spreadProtocolFeeE6`**, **`protocolNotionalFeeE8`**, and **`onCreationMaxBidAskRefAsymmetryX8`** from the matching constructor arguments, and starts **`nextPoolIdx`** at **1**. **`initialFeeReceiver`** must be non-zero or the constructor reverts **`InvalidFeeReceiver`**. **`initialOnCreationMaxBidAskRefAsymmetryX8`** must also be non-zero: a `0` cap would admit no valid `bidAskRefAsymmetryX8` at all — creation rejects both values above the cap and `0` itself — so the constructor reverts **`BidAskRefAsymmetryTooLow`**. A zero `initialOwner` reverts **`Auth_InvalidOwner`**, and an initial protocol fee above its hard ceiling reverts **`ProtocolFeeTooHigh`**. The constructor also sets the bin distance limits to their defaults (`-500_000`, `1_000_000`) and leaves **`authority`** and **`poolDeployer`** unset.

Constructor events: **`OwnershipTransferred(msg.sender, initialOwner)`** and **`AuthorityUpdated(msg.sender, address(0))`** from `Auth`; **`FeeCapsUpdated(500000, 500000, 1000000, 1000000)`**; **`SpreadProtocolFeeDefaultUpdated`** / **`ProtocolNotionalFeeDefaultUpdated`** only for a non-zero initial fee; **`OnCreationMaxBidAskRefAsymmetryUpdated`**; **`BinDistanceLimitsUpdated(-500000, 1000000)`**; **`FeeReceiverUpdated`** (in emission order).

The owner setters for defaults, caps, bin distance limits and the fee receiver return **without an event** when the new value equals the stored one (`setFeeCaps`: only when all four caps are unchanged). Storage starts at zero, so a zero initial protocol fee emits nothing.

| Function                                                             | What it does                                                                                                                   | Guidelines                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| -------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`setDefaultSpreadProtocolFeeE6(newFeeE6)`**                        | Updates the **default protocol spread fee floor** for **future** `createPool` calls (`spreadProtocolFeeE6` storage).           | Bounded by **`maxProtocolSpreadFeeE6`**. Create-time values below this are clamped up. Does **not** change existing pools until owner calls **`setPoolProtocolFee`**. Emits `SpreadProtocolFeeDefaultUpdated`; no event if unchanged.                                                                                                                                                                                                                                                                                                                   |
| **`setDefaultProtocolNotionalFeeE8(newFeeE8)`**                      | Updates the **default protocol notional fee floor** for **future** `createPool` calls (`protocolNotionalFeeE8` storage).       | Bounded by **`maxProtocolNotionalFeeE8`**. Create-time values below this are clamped up. Does **not** change existing pools until owner calls **`setPoolProtocolFee`**. Emits `ProtocolNotionalFeeDefaultUpdated`; no event if unchanged.                                                                                                                                                                                                                                                                                                               |
| **`setOnCreationMaxBidAskRefAsymmetryX8(newMaxX8)`**                 | Updates the cap on `bidAskRefAsymmetryX8` checked only at `createPool` for new pools.                                          | Starts at **`initialOnCreationMaxBidAskRefAsymmetryX8`** from the constructor. Rejects `0` (**`BidAskRefAsymmetryTooLow`**), because a `0` cap blocks `createPool` entirely. Lowering it below the sentinel stops _new_ pools from disabling the check; it has no effect on existing pools — `setPoolBidAskRefAsymmetryX8` is not gated by it. Emits `OnCreationMaxBidAskRefAsymmetryUpdated`; no event if unchanged.                                                                                                                                   |
| **`setBinDistanceLimits(newMinBinDistanceE6, newMaxBinDistanceE6)`** | Sets **`minBinDistanceE6`** / **`maxBinDistanceE6`**, the inclusive cumulative distance bounds checked at `createPool` (§2.9). | Requires `hardMinBinDistanceLimitE6() <= newMinBinDistanceE6 < 0` and `0 < newMaxBinDistanceE6 <= hardMaxBinDistanceLimitE6()` (`-999_999` and `type(int24).max`), else **`InvalidBinDistanceLimits`**. Affects only future pools. Emits `BinDistanceLimitsUpdated`; no event if both are unchanged.                                                                                                                                                                                                                                                    |
| **`setPoolBidAskRefAsymmetryX8(pool, newBidAskRefAsymmetryX8)`**     | Sets the bid/ask/reference asymmetry bound on an existing pool (see §2.2.1).                                                   | Accepts any **non-zero** `uint16`: not bounded by `onCreationMaxBidAskRefAsymmetryX8`, but `0` reverts **`BidAskRefAsymmetryTooLow`**. Its batch form is covered under §6.2. Because the cap does not gate this path, setting `type(uint16).max` disables the asymmetry check on a live pool in a single protocol call (owner or `authority`-approved caller). The factory always emits `PoolBidAskRefAsymmetryUpdated`; the pool emits `BidAskRefAsymmetryUpdated` only when the value changes. Monitoring can key on `PoolBidAskRefAsymmetryUpdated`. |
| **`setFeeCaps(...)`**                                                | Sets **`maxProtocolSpreadFeeE6`**, **`maxAdminSpreadFeeE6`**, **`maxProtocolNotionalFeeE8`**, **`maxAdminNotionalFeeE8`**.     | Cannot exceed matching hard ceilings (`maxOwnerProtocol/AdminSpreadCapE6` = `500_000` = **50%** on the `1e6` base, `maxOwnerProtocol/AdminNotionalCapE8` = `1_000_000` = **1%** on the `1e8` base). If a new cap is below the current default protocol fee, the default is **auto-clamped** to the new cap (with events). Emits `FeeCapsUpdated`; no event (and no clamping) if all four caps are unchanged.                                                                                                                                            |
| **`setPoolDeployer(_poolDeployer)`**                                 | Wires the deployer contract. Emits `PoolDeployerSet`.                                                                          | Must be called before any `createPool`. Once a non-zero address is set it cannot be changed (**`PoolDeployerAlreadySet`**). The zero address is not rejected; setting it leaves the deployer unset, so the call can be repeated.                                                                                                                                                                                                                                                                                                                        |
| **`setFeeReceiver(newFeeReceiver)`**                                 | Sets the passive protocol-fee sink read by every `collectPoolFees`.                                                            | Reverts **`InvalidFeeReceiver`** on the zero address; emits `FeeReceiverUpdated`, or nothing if unchanged. Set from **`initialFeeReceiver`** at deployment, which the constructor also requires to be non-zero. Changing it redirects only **future** collections — fees already paid out stay where they went, so collect before rotating if you want a clean cut-over.                                                                                                                                                                                |

### 6.2 Per-pool protocol fees

| Function                                                                         | What it does                                                                                                                                                                                                                                                                          | Guidelines                                                                                                                                                                                                                                   |
| -------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`setPoolProtocolFee(pool, newProtocolSpreadFeeE6, newProtocolNotionalFeeE8)`** | Collects accrued fees at **old** rates, updates **protocol** components in **`poolFeeConfig`**, clamps admin components to current admin caps if needed (emits **`PoolAdminSpreadFeeUpdated`** / **`PoolAdminNotionalFeeUpdated`** when clamped), then **`setPoolFees`** on the pool. | New values must be ≤ **`maxProtocolSpreadFeeE6`** / **`maxProtocolNotionalFeeE8`**; they are not floored at the factory defaults. Use to tune protocol revenue per pool; coordinate communication with pool admin because **totals** change. |

**Batch forms.** `setPoolProtocolFeeBatch` and `setPoolBidAskRefAsymmetryX8Batch` take parallel arrays and apply the identical per-pool logic in order, reverting **`ArrayLengthMismatch`** if the lengths disagree. They are **atomic**: any per-entry revert (`ProtocolFeeTooHigh`, `BidAskRefAsymmetryTooLow`, a codeless address) rolls back the whole call, so a batch either fully applies or changes nothing. Note that only a **codeless** entry is guaranteed to revert: neither helper checks `isPool`, so a contract that merely tolerates the call would be accepted. Three operational notes:

- **Reverts carry no index.** A `ProtocolFeeTooHigh` from a 40-entry batch does not say which entry failed. Validate the array off-chain, or bisect, before assuming a pool is misconfigured.
- **Check the pool logs for `FeeTransferFailed`.** `setPoolProtocolFeeBatch` allocates each pool’s accrued fees at its **old** rates before updating them. Rejected token payouts remain pending without blocking the update. An accounting failure reverts the entire batch with the original pool error.
- **Entries should be unique.** Duplicates are not rejected; they are safe but wasteful: the flush runs once per occurrence and the last write wins.

### 6.3 Fee collection and sweeps

| Function                           | What it does                                                                                                                                                                                                                                                                                    | Guidelines                                                                                                                                                                                                                                       |
| ---------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **`collectPoolFees(pool)`**        | Uses **`poolFeeConfig`** to split accrued fees on the pool: **admin** share goes to **`poolAdminFeeDestination`**; **protocol** share goes straight to **`feeReceiver()`**. The factory passes both destinations into the pool’s `collectFees`; pool accounting errors propagate to the caller. | **Permissionless** — any address may call (keepers, pool admin, or bots). Does not change fee configuration. Safe to expose to keepers: the caller cannot influence either destination, both are governance-set. Run on an operational schedule. |
| **`collectTokens` / `collectEth`** | Moves ERC-20 or native ETH **from the factory balance** to a chosen recipient (`amount == 0` means “all”).                                                                                                                                                                                      | **Stray-token rescue only.** Protocol fees never accumulate on the factory; they go to `feeReceiver` at collection, so this is for assets sent to the factory by mistake.                                                                        |

### 6.4 Pausing (level 2)

| Function                        | What it does                                | Guidelines                                                                                                                                                                           |
| ------------------------------- | ------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **`protocolPausePool(pool)`**   | Sets pause level **2** from **0** or **1**. | `requiresAuth`, same as every other protocol function. Blocks the same thing level 1 does (`swap`); what it adds is that the pool admin cannot lift it.                              |
| **`protocolUnpausePool(pool)`** | Moves **2 → 1** (not to **0**).             | **Intentional design:** after a protocol pause, the pool admin must explicitly call **`unpausePool`** to resume trading. The owner cannot bypass admin consent to reach level **0**. |

---

## 7. Pause levels (summary)

| Level | Meaning                  | Typical setter                                                    |
| ----- | ------------------------ | ----------------------------------------------------------------- |
| **0** | Active                   | —                                                                 |
| **1** | Paused by **pool admin** | `pausePool` / `unpausePool`                                       |
| **2** | Paused by **protocol**   | `protocolPausePool` / `protocolUnpausePool` (both `requiresAuth`) |

**Levels 1 and 2 block exactly the same thing: `swap`.** `whenNotPaused` sits on `swap` and on nothing else, so `addLiquidity`, `removeLiquidity`, `simulateSwapAndRevert`, `getSellAndBuyPrices` and every factory admin/owner action keep working while a pool is paused — LPs can unwind at either level. The levels differ only in who may lift them: `protocolUnpausePool` moves **2 → 1** and never reaches **0**.

Invalid transitions revert with **`InvalidPauseTransition`**.

---

## 8. On-pool factory callbacks (reference)

The factory drives these `onlyFactory` methods on the pool (not user-facing). All are on **`IMetricOmmPoolFactoryActions`** except `collectFees`, which is declared on **`IMetricOmmPoolCollectFees`**:

- **`collectFees`** (`IMetricOmmPoolCollectFees`) — realize fee splits using the supplied component rates and the two destinations the factory passes in: `adminFeeDestination` for the admin share and `protocolFeeDestination` (the factory's `feeReceiver`) for the protocol share. The pool holds no destination of its own. Four scaled `uint256` pending balances preserve allocated admin/protocol entitlements for both tokens, including fractional remainders. Pending balances are excluded from fresh fee accrual; successful transfers reduce them, while failed transfers emit `FeeTransferFailed` and can be retried independently. Retries use the latest destinations even when current fee rates are zero. `ProtocolFeesCollected` reports only amounts actually transferred. Payouts use `SafeERC20.trySafeTransfer`, supporting tokens that return no value. Supported tokens must not move funds when reporting a failed transfer.
- **`setPoolFees`** — update total spread and notional fee rates stored on the pool.
- **`setBidAskRefAsymmetryX8`** — update the bid/ask/reference asymmetry bound (§2.2.1).
- **`setPause`** — set pause level.
- **`setBinAdditionalFees`** — per-bin additional fees.
- **`setPriceProvider`** — apply new oracle after **`MetricOmmPoolFactory`** has allowed rotation (mutable oracle at creation); the factory reverts **`PriceProviderImmutable`** on propose and execute for immutable pools and does not rely on the pool to repeat that check.

Integrators normally **never call these on the pool directly**; use the factory as the policy layer.

---

## 9. Quick checklist before `createPool`

1. **Tokens** match the provider's **`token0()`** / **`token1()`** and are ERC-20 with readable **decimals**.
2. **Oracle** address correct; **immutable** vs **timelock** chosen deliberately.
3. **`admin`** and **`adminFeeDestination`** are correct and secured.
4. **`protocolSpreadFeeE6` / `protocolNotionalFeeE8`** ≤ max caps (below-default inputs clamp to factory floors); **`adminSpreadFeeE6` / `adminNotionalFeeE8`** within admin caps.
5. **`initialScaledAmount0PerE18Shares` / `initialScaledAmount1PerE18Shares`**: enforce `P̂1/P̂0 = π0` off-chain (deployer duty); for `OracleValueStopLossExtension` pools prefer the §2.5 formulas. Also review **`minimalOperationalLiquidity`**.
6. **Bin arrays** validated off-chain against the same rules as the factory (§2.9) — note the **asymmetric** distance bounds and the **silent** tail truncation on a zero `lengthE6`.
7. **`salt`** changed if an otherwise identical pool already exists on this deployer (§2.8).
8. **`bidAskRefAsymmetryX8`** set **deliberately** (§2.2.1) — `type(uint16).max` to disable the check, or a non-zero bound to enable it. `0` reverts `createPool` (**`BidAskRefAsymmetryTooLow`**).

---

## Related source files

- `contracts/MetricOmmPoolFactory.sol` — validation, `createPool`, admin/owner entrypoints.
- `contracts/MetricOmmPoolDeployer.sol` — CREATE2 deploy; **`DeployParams`** matches the pool constructor (factory enforces caps and totals before calling `deploy`).
- `contracts/MetricOmmPool.sol` — constructor immutables, swap/liquidity, `onlyFactory` extensions.
- `contracts/types/` — `FactoryOperation.sol` (`PoolParameters`); `FactoryStorage.sol` (`PoolFeeConfig`); `PoolOperation.sol` (`LiquidityDelta`, `BinBalanceDelta`); `PoolStorage.sol` (`BinState`).
- `contracts/interfaces/IMetricOmmPoolFactory/` — `IMetricOmmPoolFactoryOwner.sol` (owner-only events and errors, owner mutators, `hardMinBinDistanceLimitE6` / `hardMaxBinDistanceLimitE6`); `IMetricOmmPoolFactoryPoolAdmin.sol` (pool-admin events and errors, pool-admin mutators); `IMetricOmmPoolFactory.sol` (`PoolCreated`, deploy-time validation errors, errors shared with `createPool` or multiple roles, all other views, permissionless `collectPoolFees`, `createPool`, composition of the two role interfaces).
- `contracts/interfaces/IMetricOmmPool/` — `IMetricOmmPoolActions.sol` (user liquidity and swap mutators, events, and errors); `IMetricOmmPoolFactoryActions.sol` (factory-only pool extensions except `collectFees`); `IMetricOmmPoolCollectFees.sol` (`collectFees`); `IMetricOmmPool.sol` (`PoolImmutables`; `getImmutables`, `inSwap`, `getSellAndBuyPrices`; composes user actions, fee collection, and factory actions).
- `contracts/libraries/BinDataLibrary.sol` — bin packing layout.
