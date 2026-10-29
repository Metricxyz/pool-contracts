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

| Parameter                  | Role                                                               | Guidelines                                                                                                                       |
| -------------------------- | ------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------- |
| **`token0`**, **`token1`** | The two ERC-20 assets; must match the price provider’s base/quote. | Distinct, non-zero addresses. Ordering must be consistent with `IPriceProvider.getTokens()` (`token0` = base, `token1` = quote). |

### 2.2 Price oracle

| Parameter                   | Role                                                                                                                                                                                                                                                                         | Guidelines                                                                                                                                                     |
| --------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`priceProvider`**         | Oracle implementing `IPriceProvider`; pool reads bid/ask for pricing.                                                                                                                                                                                                        | Non-zero; `getTokens()` must return `(token0, token1)`. Choose an implementation you trust to be available and correct for the pool’s lifetime.                |
| **`priceProviderTimelock`** | If **`type(uint256).max`**, the pool treats the oracle as **immutable** (`IMMUTABLE_PRICE_PROVIDER` is set; no rotations). Otherwise, seconds to wait after `proposePoolPriceProvider` before `executePoolPriceProviderUpdate`, stored in **`priceProviderTimelock[pool]`**. | Use `type(uint256).max` only when you want the oracle address fixed forever. For rotatable oracles, pick a finite delay that balances security and operations. |

### 2.3 Access control for deposits and swaps

| Parameter             | Role                                                                                                                                                         | Guidelines                                                                                                                                                                           |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **`extensions`**      | Up to seven optional contracts implementing `IMetricOmmExtensions`, with per-action call order via **`extensionOrders`**.                                    | Use an empty `extensions` array with zeroed `extensionOrders` for no extensions. Reference implementations: **metric-periphery** (allowlist, price guard, swap reporter extensions). |
| **`extensionOrders`** | Encodes invocation order per action (`beforeAddLiquidity`, `afterAddLiquidity`, `beforeRemoveLiquidity`, `afterRemoveLiquidity`, `beforeSwap`, `afterSwap`). | Must be zero when `extensions` is empty; at least one non-zero order when extensions are set.                                                                                        |

### 2.4 Admin and fee routing at creation

| Parameter                 | Role                                                                                                                                                             | Guidelines                                                                                                                                |
| ------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| **`admin`**               | Becomes **`poolAdmin[pool]`** on the factory; this address controls pool-scoped admin actions (fees, pause L1, oracle proposal/execute, admin transfer).         | Non-zero; use a multisig or explicit admin contract, not an EOA unless you accept key risk.                                               |
| **`adminSpreadFeeE6`**    | **Admin spread fee** component in **E6** (`1e6 = 100%`). **Protocol spread** is the factory’s current **`spreadProtocolFeeE6`** (not in `PoolParameters`).       | Must be ≤ factory **`maxAdminSpreadFeeE6`**. Total spread on the pool is `spreadProtocolFeeE6 + adminSpreadFeeE6` at deploy time.         |
| **`adminNotionalFeeE8`**  | **Admin notional fee** component in **E8** (`1e8 = 100%`). **Protocol notional** is the factory’s current **`protocolNotionalFeeE8`** (not in `PoolParameters`). | Must be ≤ factory **`maxAdminNotionalFeeE8`**. Total notional on the pool is `protocolNotionalFeeE8 + adminNotionalFeeE8` at deploy time. |
| **`adminFeeDestination`** | Address that receives the **admin share** when fees are collected via the factory.                                                                               | Non-zero. Must be able to receive both tokens (and any ETH policy you use off-pool).                                                      |

**Note:** Protocol defaults are set at factory construction / via **`setDefaultSpreadProtocolFeeE6`** and **`setDefaultProtocolNotionalFeeE8`**. Admin components are chosen per pool in **`PoolParameters`**. All four components can be tuned later within caps via **`setPoolAdminFees`** (pool admin, §5.1) and **`setPoolProtocolFee`** (factory owner, §6.2).

### 2.5 Initial liquidity geometry and limits

| Parameter                                                        | Role                                                                                                                                                                                                                                                            | Guidelines                                                                                                                                                                                                                                      |
| ---------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`initialAmount0PerShareE18`**, **`initialAmount1PerShareE18`** | Initial token0/token1 **per liquidity share** in each token’s **native smallest units**, before the factory applies **`token*ScaleMultiplier`**. The factory stores **`initialAmount × multiplier`** on the pool as **`INITIAL_SCALED_TOKEN_*_PER_SHARE_E18`**. | Both must be **non-zero** (revert **`InvalidInitialAmount`**). For 18-decimal tokens the multiplier is **1**, so values match the legacy “density” numerics; for lower decimals, express amounts in raw token units (e.g. USDC **6** decimals). |
| **`minimalMintableLiquidity`**                                   | Minimum **per-position per-bin** share balance after an add; enforced on `addLiquidity`.                                                                                                                                                                        | Must be **non-zero**. Too high excludes small LPs; too low can increase dust and rounding edge cases.                                                                                                                                           |

### 2.6 Swap extension point context (oracle + slot0)

| Topic                                         | Role                                                                                                                                                                                                      | Guidelines                                                                                                                                                                            |
| --------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`packedSlot0Initial` / `packedSlot0Final`** | `uint256` word matching storage slot 0 before and after the bin walk. Decode with `Slot0Library.unpack` (`curBinIdx`, `curPosInBin`, fees, pause).                                                        | Use for analytics, price guards, and reporting final cursor position.                                                                                                                 |
| **`bidPriceX64` / `askPriceX64`**             | Passed to both swap extension point functions from the pool’s single `getBidAndAskPrice()` per `swap` (same quotes used for swap math).                                                                   | Extensions should not re-read the oracle unless a fresher quote is intentional.                                                                                                       |
| **Reporting**                                 | Replace legacy `reportSwapToPriceProvider` with an **`afterSwap`** extension point function in **metric-periphery** (e.g. `SwapReporterExtension`).                                                       | Use `try/catch` inside the extension for best-effort reporting. Core tests extension plumbing only (`test/mocks/MockMetricExtension.sol`, `test/mocks/extensions/GateExtension.sol`). |
| **`simulateSwapAndRevert`**                   | Invokes the same swap extension point functions as `swap` when `extensionOrders` are configured; uses caller-supplied `bidPriceX64` / `askPriceX64` for extension context and math (not the live oracle). | Pass the same `recipient` and `extensionData` you intend for a live swap so simulation matches extension gates and side effects.                                                      |

### 2.7 Bin ladder anchor

| Parameter                           | Role                                                                                                                                          | Guidelines                                                                                                                                                                                                                                              |
| ----------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --- | --------------- |
| **`curBinDistFromProvidedPriceE6`** | **int24** distance in **E6** units anchoring the bin ladder relative to the oracle mid-price (same distance domain the pool uses internally). | Must lie in **[-999_999, 999_999]** (factory constants `MIN_BIN_CUMULATIVE_DISTANCE_E6` / `MAX_BIN_CUMULATIVE_DISTANCE_E6`); walking packed bins must keep every partial cumulative in the same range (matches `MetricOmmPool.distanceE6ToPriceX64`’s ` | d   | < 1e6` domain). |

### 2.8 Packed bin arrays

| Parameter                     | Role                                                                                 | Guidelines                                                                                                          |
| ----------------------------- | ------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------- |
| **`nonNegativeBinDataArray`** | Packed config for bins **0 … highest** (above/on the “positive” side of the ladder). | Must be **non-empty** and respect packing rules (§2.9).                                                             |
| **`negativeBinDataArray`**    | Packed config for bins **-1 … lowest** (below side).                                 | Can be empty only if you have no negative bins; combined with non-negative must yield valid `int8` bin index range. |
| **`salt`**                    | CREATE2 **`salt`** for deterministic pool address.                                   | Choose uniqueness vs other pools (same factory, tokens, and salt would collide).                                    |

### 2.9 Bin packing format (`BinDataLibrary`)

Each logical bin is **48 bits**:

- **bits 0–15:** `lengthE6` (uint16) — segment length in E6 distance units along the ladder.
- **bits 16–31:** `addFeeBuyE6` (uint16) — extra fee for the “buy token0” direction (E6).
- **bits 32–47:** `addFeeSellE6` (uint16) — extra fee for the “buy token1” direction (E6).

Up to **five** bins are packed per **`uint256`**, little-endian within the word (position `0` = lowest bits).

**Factory rules (high level):**

- First slot in each packed word must have **non-zero** `lengthE6` (partial words allowed: inner slots may be zero to terminate).
- Walking **non-negative** bins: start from `curBinDistFromProvidedPriceE6` and **add** each bin’s `lengthE6`; every partial cumulative must stay inside the allowed distance range.
- Walking **negative** bins: start from the same anchor and **subtract** lengths; same range checks.
- Total bin counts on each side must be **≤ 128** so bin indices stay in **`int8`** range (factory reverts **`BinIndexRangeExceedsInt8`** otherwise).

---

## 3. Deploy-time derived inputs and fee wiring

| Value                                                                        | Source                                                                                                                                                                              |
| ---------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`factory`**                                                                | The creating factory address (`address(this)`).                                                                                                                                     |
| **`token0ScaleMultiplier`**, **`token1ScaleMultiplier`**                     | Derived from **`IERC20Metadata.decimals()`** for both tokens: internal precision is `max(18, token0Decimals, token1Decimals)`, then multipliers `10 ** (internal - tokenDecimals)`. |
| **`initialScaledAmount0PerShareE18`**, **`initialScaledAmount1PerShareE18`** | `initialAmount*PerShareE18 × token*ScaleMultiplier` (checked multiply in the factory), then passed to the deployer and pool constructor.                                            |
| **`spreadFeeE6`** (total)                                                    | `spreadProtocolFeeE6 + adminSpreadFeeE6` at deploy time; passed to the deployer and stored on the pool.                                                                             |
| **`notionalFeeE8`** (total)                                                  | `protocolNotionalFeeE8 + adminNotionalFeeE8` at deploy time; passed to the deployer and stored on the pool.                                                                         |
| **Per-component config**                                                     | Factory stores protocol and admin components separately in **`poolFeeConfig`** for fee collection splits; only totals are passed to the pool.                                       |

The deployer forwards those four values into **`MetricOmmPool`’s constructor**; the pool derives its stored total rates from their sums.

---

## 4. Pool management: roles

| Role           | On-chain identity                                 | Primary contract                                  |
| -------------- | ------------------------------------------------- | ------------------------------------------------- |
| **Protocol**   | `MetricOmmPoolFactory` **owner** (`Ownable2Step`) | Factory                                           |
| **Pool admin** | **`poolAdmin[pool]`**                             | Factory-gated entrypoints that call into the pool |

The **pool contract** only accepts privileged calls from **`FACTORY`** (`onlyFactory`); admins and protocol act **through the factory** for fee collection, pausing, oracle updates, and per-bin fee tweaks.

---

## 5. Pool admin: functions and guidelines

All of the following require **`msg.sender == poolAdmin[pool]`** unless noted.

### 5.1 Fees and destination

| Function                                                                 | What it does                                                                                                                                                                                      | Guidelines                                                                                                                                                                                  |
| ------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`setPoolAdminFees(pool, newAdminSpreadFeeE6, newAdminNotionalFeeE8)`** | Accrues and transfers fees using **current** stored rates, then updates **admin** spread/notional components in **`poolFeeConfig`**, and calls **`setPoolFees`** on the pool with new **totals**. | New values must be ≤ **`maxAdminSpreadFeeE6`** / **`maxAdminNotionalFeeE8`**. Changing fees triggers a **collection** first—plan timing so destination addresses and balances are expected. |
| **`setPoolAdminFeeDestination(pool, newAdminFeeDestination)`**           | Updates where the admin fee share is sent on **`collectPoolFees`**.                                                                                                                               | Non-zero address. Coordinate with treasury operations.                                                                                                                                      |
| **`setPoolBinAdditionalFees(pool, bin, addFeeBuyE6, addFeeSellE6)`**     | Updates **per-bin** additional buy/sell fees on the pool (E6).                                                                                                                                    | Use for fine-grained incentives or disincentives on specific bins; understand interaction with global spread fee.                                                                           |

### 5.2 Pausing (level 1)

| Function                | What it does                              | Guidelines                                                                                          |
| ----------------------- | ----------------------------------------- | --------------------------------------------------------------------------------------------------- |
| **`pausePool(pool)`**   | Sets pause level **1** (from **0** only). | Disables swaps (and generally “active” trading); use for incidents, upgrades, or market conditions. |
| **`unpausePool(pool)`** | Sets level **0** (from **1** only).       | After protocol releases an L2 pause, admin **cannot** unpause directly to **0**—see below.          |

### 5.3 Oracle rotation (mutable provider only)

| Function                                               | What it does                                                                                                                               | Guidelines                                                                                                                    |
| ------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------- |
| **`proposePoolPriceProvider(pool, newPriceProvider)`** | Validates `newPriceProvider` matches pool tokens, records **pending** provider and **`executeAfter = now + priceProviderTimelock[pool]`**. | Reverts if the pool has **immutable** oracle. Announce off-chain; ensure stakeholders know the switch time.                   |
| **`executePoolPriceProviderUpdate(pool)`**             | After timelock, validates again and calls **`setPriceProvider`** on the pool.                                                              | Anyone could theoretically watch timing, but only **pool admin** may call; ensure admin bot or multisig executes after delay. |

### 5.4 Governance of admin role

| Function                                       | What it does                                                                                                                                              | Guidelines                                                                                                        |
| ---------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| **`pendingPoolAdmin(pool)`** (view)            | Returns the address awaiting **`acceptPoolAdmin`**, or **`address(0)`** if none.                                                                          | Use for UIs, multisig payloads, and monitoring between propose and accept.                                        |
| **`proposePoolAdminTransfer(pool, newAdmin)`** | Current **`poolAdmin[pool]`** records **`pendingPoolAdmin[pool] = newAdmin`**. Emits **`PoolAdminTransferProposed`**.                                     | Non-zero **`newAdmin`** and must differ from the current admin. Can be called again to replace a pending nominee. |
| **`acceptPoolAdmin(pool)`**                    | **`msg.sender`** must equal **`pendingPoolAdmin[pool]`**; then **`poolAdmin[pool]`** is updated and pending is cleared. Emits **`PoolAdminTransferred`**. | Two-step handover (like **`Ownable2Step`**): the **incoming** admin must accept.                                  |
| **`cancelPoolAdminTransfer(pool)`**            | Current **`poolAdmin[pool]`** clears a pending transfer. Emits **`PoolAdminTransferCancelled`**.                                                          | Use if a proposal was mistaken or the nominee will not accept. Reverts if there is no pending admin.              |

---

## 6. Protocol (factory owner): functions and guidelines

These require **`onlyOwner`** on **`MetricOmmPoolFactory`**.

### 6.1 Global defaults and caps

The factory **`constructor`** takes **`(initialOwner, initialSpreadProtocolFeeE6, initialNotionalProtocolFeeE8)`**, which set the initial **`spreadProtocolFeeE6`** and **`protocolNotionalFeeE8`** storage used for **new** pools (each must be ≤ the initial hard caps). Owner updates later use the setters below.

| Function                                        | What it does                                                                                                               | Guidelines                                                                                                                                                                                                     |
| ----------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`setDefaultSpreadProtocolFeeE6(newFeeE6)`**   | Updates the **default protocol spread fee** used for **future** `createPool` calls (`spreadProtocolFeeE6` storage).        | Bounded by **`maxProtocolSpreadFeeE6`**. Does **not** retroactively change existing pools’ stored protocol component until owner calls **`setPoolProtocolFee`**.                                               |
| **`setDefaultProtocolNotionalFeeE8(newFeeE8)`** | Updates the **default protocol notional fee** used for **future** `createPool` calls (`protocolNotionalFeeE8` storage).    | Bounded by **`maxProtocolNotionalFeeE8`**. Does **not** retroactively change existing pools until owner calls **`setPoolProtocolFee`**.                                                                        |
| **`setFeeCaps(...)`**                           | Sets **`maxProtocolSpreadFeeE6`**, **`maxAdminSpreadFeeE6`**, **`maxProtocolNotionalFeeE8`**, **`maxAdminNotionalFeeE8`**. | Cannot exceed hard ceilings (`maxOwnerSpreadCapE6` = 20%, `maxOwnerNotionalCapE8` = 1%). If a new cap is below the current default protocol fee, the default is **auto-clamped** to the new cap (with events). |
| **`setPoolDeployer(_poolDeployer)`**            | One-time wiring of the deployer contract.                                                                                  | Must be called before any `createPool`; cannot be changed once set (factory reverts if already set).                                                                                                           |

### 6.2 Per-pool protocol fees

| Function                                                                         | What it does                                                                                                                                                                                                                                                                          | Guidelines                                                                                                 |
| -------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| **`setPoolProtocolFee(pool, newProtocolSpreadFeeE6, newProtocolNotionalFeeE8)`** | Collects accrued fees at **old** rates, updates **protocol** components in **`poolFeeConfig`**, clamps admin components to current admin caps if needed (emits **`PoolAdminSpreadFeeUpdated`** / **`PoolAdminNotionalFeeUpdated`** when clamped), then **`setPoolFees`** on the pool. | Use to tune protocol revenue per pool; coordinate communication with pool admin because **totals** change. |

### 6.3 Fee collection and sweeps

| Function                           | What it does                                                                                                                                                                                                                   | Guidelines                                                                                                                                                                                                                                                 |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`collectPoolFees(pool)`**        | Uses **`poolFeeConfig`** to split accrued fees on the pool: **admin** share goes to **`poolAdminFeeDestination`**; **protocol** share is transferred to the **`FACTORY`** address (the pool’s `transferToken0/1(FACTORY, …)`). | **Permissionless** — any address may call (keepers, pool admin, or bots). Does not change fee configuration. Run on an operational schedule; sweep protocol balances from the factory with **`collectTokens`** / **`collectEth`** when moving to treasury. |
| **`collectTokens` / `collectEth`** | Moves ERC-20 or native ETH **from the factory balance** to a chosen recipient (`amount == 0` means “all”).                                                                                                                     | Primary operational use: withdraw **protocol fees** after **`collectPoolFees`**; also handles accidental transfers to the factory.                                                                                                                         |

### 6.4 Pausing (level 2)

| Function                        | What it does                                | Guidelines                                                                                                                                                                           |
| ------------------------------- | ------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **`protocolPausePool(pool)`**   | Sets pause level **2** from **0** or **1**. | Strongest halt (e.g. security event). Swaps remain disabled at L2.                                                                                                                   |
| **`protocolUnpausePool(pool)`** | Moves **2 → 1** (not to **0**).             | **Intentional design:** after a protocol pause, the pool admin must explicitly call **`unpausePool`** to resume trading. The owner cannot bypass admin consent to reach level **0**. |

---

## 7. Pause levels (summary)

| Level | Meaning                  | Typical setter                              |
| ----- | ------------------------ | ------------------------------------------- |
| **0** | Active                   | —                                           |
| **1** | Paused by **pool admin** | `pausePool` / `unpausePool`                 |
| **2** | Paused by **protocol**   | `protocolPausePool` / `protocolUnpausePool` |

Invalid transitions revert with **`InvalidPauseTransition`**.

---

## 8. On-pool factory callbacks (reference)

The factory drives these **`IMetricOmmPoolFactoryActions`** methods on the pool (not user-facing):

- **`collectFees`** — realize fee splits using the supplied component rates and admin destination.
- **`setPoolFees`** — update total spread and notional fee rates stored on the pool.
- **`setPause`** — set pause level.
- **`setBinAdditionalFees`** — per-bin additional fees.
- **`setPriceProvider`** — apply new oracle after **`MetricOmmPoolFactory`** has allowed rotation (mutable oracle at creation); the factory reverts **`PriceProviderImmutable`** on propose and execute for immutable pools and does not rely on the pool to repeat that check.

Integrators normally **never call these on the pool directly**; use the factory as the policy layer.

---

## 9. Quick checklist before `createPool`

1. **Tokens** match **`IPriceProvider.getTokens()`** and are ERC-20 with readable **decimals**.
2. **Oracle** address correct; **immutable** vs **timelock** chosen deliberately.
3. **`admin`** and **`adminFeeDestination`** are correct and secured.
4. **`adminSpreadFeeE6`** / **`adminNotionalFeeE8`** within **`maxAdminSpreadFeeE6`** / **`maxAdminNotionalFeeE8`**; aware of factory **`spreadProtocolFeeE6`** and **`protocolNotionalFeeE8`** for **total** spread and notional at deploy.
5. **`initialAmount0PerShareE18` / `initialAmount1PerShareE18`** (and resulting scaled immutables) and **`minimalMintableLiquidity`** reviewed for economics.
6. **Bin arrays** validated off-chain against the same rules as the factory (distances, packing, counts).
7. **`salt`** chosen for deterministic address without collision.

---

## Related source files

- `contracts/MetricOmmPoolFactory.sol` — validation, `createPool`, admin/owner entrypoints (source layout mirrors `MetricOmmPool`: constants, state, constructor, modifiers, views, `createPool` as the first mutator, owner mutators, pool-admin mutators, then internal helpers).
- `contracts/MetricOmmPoolDeployer.sol` — CREATE2 deploy; **`DeployParams`** matches the pool constructor (factory enforces caps and totals before calling `deploy`).
- `contracts/MetricOmmPool.sol` — constructor immutables, swap/liquidity, `onlyFactory` extensions.
- `contracts/types/` — `FactoryOperation.sol` (`PoolParameters`); `FactoryStorage.sol` (`PoolFeeConfig`, `PoolImmutables`); `PoolOperation.sol` (`LiquidityDelta`, `BinBalanceDelta`); `PoolStorage.sol` (`BinState`).
- `contracts/interfaces/IMetricOmmPoolFactory/` — `IMetricOmmPoolFactoryOwner.sol` (owner-only events and errors, owner mutators); `IMetricOmmPoolFactoryPoolAdmin.sol` (pool-admin-only events and errors, pool-admin mutators); `IMetricOmmPoolFactory.sol` (`PoolCreated`, deploy-time validation errors, errors shared with `createPool` or multiple roles, all views, permissionless `collectPoolFees`, `createPool`, composition of the two role interfaces).
- `contracts/interfaces/IMetricOmmPool/` — `IMetricOmmPoolActions.sol` (user liquidity and swap mutators, events, and errors); `IMetricOmmPoolFactoryActions.sol` (factory-only pool extensions except `collectFees`); `IMetricOmmPoolCollectFees.sol` (`collectFees`); `IMetricOmmPool.sol` composes user actions, fee collection, and factory actions.
- `contracts/libraries/BinDataLibrary.sol` — bin packing layout.
