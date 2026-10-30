# Metric OMM Core

Core smart contracts for the Metric OMM protocol: oracle-based pools with bin-based liquidity, factory deployment, and EXTSLOAD-aligned state reads.

## Overview

Pools use external price providers for bid/ask, maintain liquidity in configurable bins, and enforce pause levels and optional per-pool extensions. Integrators typically interact via **`IMetricOmmPool`** (liquidity and swap actions); fee collection and the remaining pool controls are driven through the factory.

## Contracts

### Pool and factory

- **MetricOmmPool.sol** — Main pool (liquidity, swap, simulation, factory/protocol controls).
- **MetricOmmPoolFactory.sol** — Pool registry, fee caps, `createPool`, deployer wiring, and pool administration.
- **MetricOmmPoolDeployer.sol** — CREATE2 deployment of pool bytecode (factory-only).

### Supporting contracts

- **ExtensionCalling.sol** — Abstract base for ordered per-pool extension invocation.
- **Extsload.sol** — `EXTSLOAD`-based storage reads (forked from Uniswap v4-style pattern); pool layout must stay aligned with **PoolStateLibrary**.
- **Extensions** — Optional per-pool `IMetricOmmExtensions` (up to seven extensions with a per-extension-point call order set at deployment). Product extensions live in **metric-periphery**; core tests plumbing via `test/mocks/MockMetricExtension.sol` and `test/mocks/extensions/GateExtension.sol`.

### Libraries

- **SwapMath.sol** — Pure swap/step math.
- **FeeMath.sol** — Spread, per-bin and notional fee math in Q64.64.
- **LiquidityLib.sol** — `addLiquidity` / `removeLiquidity` logic, linked into the pool via `DELEGATECALL`.
- **BinDataLibrary.sol** — Bin encoding helpers.
- **PoolStateLibrary.sol** — Slot helpers for EXTSLOAD readers; must match **MetricOmmPool** storage packing.
- **Slot0Library.sol** — Pack/unpack storage slot 0 (`packedSlot0Initial` / `packedSlot0Final` on swap extension point functions).
- **CallExtension.sol** — Low-level extension call and selector validation.
- **ValidateExtensionsConfig.sol** — Factory validation for extension addresses, init data, and call orders.
- **PoolActions.sol**, **SignedMath.sol** — Reentrancy action ids and signed-integer helpers.

### Auth and utilities

- **auth/Auth.sol**, **auth/Auth2Step.sol** — Ownership and authority pattern used by the factory.
- **utils/MetricReentrancyGuardTransient.sol** — Transient-storage reentrancy guard that records the running action.

## Requirements

- [Foundry](https://book.getfoundry.sh/getting-started/installation) **1.7.1** (the version pinned in CI) with `solc` **0.8.35**.
- Node.js 20+ (only for formatting and git hooks).

## Installation

```bash
git clone --recursive https://github.com/Metricxyz/pool-contracts.git
cd pool-contracts
forge build
```

If you cloned without `--recursive`:

```bash
git submodule update --init --recursive
```

## Build

```bash
forge build
```

## Testing

```bash
# All tests (Solidity tests under test/)
forge test

forge test -vvv

# Example: single file
forge test --match-path test/MetricOmmPool.swap.t.sol

forge test --gas-report
```

## Contributing

### Formatting

- **Solidity** (`contracts/`, `test/`): use Foundry only so CI and locals stay aligned.

```bash
npm run format:forge:check   # same as CI
forge fmt
```

Or run both Prettier and Foundry checks: `npm run format:check`.

- **Other text** (Markdown, JSON, YAML, and other Prettier-supported files outside ignored paths): `npm install` then `npm run format:prettier` / `npm run format:prettier:check`. Solidity and `contracts/` / `test/` are excluded via `.prettierignore`; use **`forge fmt`** for `.sol` files.

CI runs Prettier check and `forge fmt --check` (see `.github/workflows/test.yml`). Match the pinned toolchain locally (`forge --version`, `solc` from `foundry.toml`).

### Git hooks

Running **`npm install`** executes the **`prepare`** script, which sets **`core.hooksPath`** to the absolute path of `.githooks`. Verify hooks are active:

```bash
git config --local --get core.hooksPath   # prints the absolute path to .githooks (or `.githooks` if enabled manually)
```

If empty, enable manually:

```bash
git config --local core.hooksPath .githooks
```

The hook runs **`npm run format:prettier:check`**, **`forge fmt --check`** (fails the commit on format drift), and **`forge test`**. Requires Foundry on `PATH`, plus Node/npm with `npm install` already run (Prettier in `node_modules`). Skip with **`git commit --no-verify`**.

## Documentation

- **[Pool configuration and management](docs/POOL_CONFIGURATION_AND_MANAGEMENT.md)** — `createPool` / constructor parameters, bins, admin vs protocol roles.
- **[Swap math](docs/SwapMath.md)** — In-bin pricing, specified-in / specified-out derivations, fee sizing, and balance limits.
- **Periphery** — Routers, quoters, lenses and product extensions live in [periphery-contracts](https://github.com/Metricxyz/periphery-contracts).

## Project structure

```text
contracts/
├── MetricOmmPool.sol
├── MetricOmmPoolFactory.sol
├── MetricOmmPoolDeployer.sol
├── ExtensionCalling.sol
├── Extsload.sol
├── auth/
├── interfaces/
│   ├── IExtsload.sol
│   ├── IMetricOmmPool/
│   ├── IMetricOmmPoolFactory/
│   ├── IPriceProvider/
│   ├── callbacks/
│   └── extensions/
├── libraries/
├── types/
└── utils/

test/                  # Foundry tests (*.t.sol, harnesses)
test/mocks/            # Test doubles (e.g. MockERC20, MockOracle, TestCaller)
```

## Security and audits

Audit reports and instructions for reporting vulnerabilities are published at [docs.metric.xyz — Security and audits](https://docs.metric.xyz/reference/security-and-audits).

### Audited code

Every commit named in the audit reports is published here as a tag named `audit-<commit>`. A tag is a new commit without the private history, so its own hash differs from the audited one. Its `contracts/` folder, though, is identical to the audited commit's, and the tag's `VERIFY.md` proves that from the commit hash printed in the report, without access to the private repository.

| Tag                                                                               | Audits                                                                                               | `contracts/` hash                          | Proof                                                                                 |
| --------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- | ------------------------------------------ | ------------------------------------------------------------------------------------- |
| [`audit-6aa6c3b`](https://github.com/Metricxyz/pool-contracts/tree/audit-6aa6c3b) | Zellic audit (Jun 2026), audited. Sherlock collaborative audit (May–Jun 2026), audited               | `2f9590d9f9929afeec08e21840bc42dc2abc31cc` | [VERIFY.md](https://github.com/Metricxyz/pool-contracts/blob/audit-6aa6c3b/VERIFY.md) |
| [`audit-7b9ab56`](https://github.com/Metricxyz/pool-contracts/tree/audit-7b9ab56) | Sherlock collaborative audit, fixes. Sherlock bug bounty contest (Jul 2026), audited                 | `b8b61255c99811f2bbd81d0e3d588446cc01c7b4` | [VERIFY.md](https://github.com/Metricxyz/pool-contracts/blob/audit-7b9ab56/VERIFY.md) |
| [`audit-4410fec`](https://github.com/Metricxyz/pool-contracts/tree/audit-4410fec) | Sherlock bug bounty contest, fixes. Zellic re-audit (Sep 2026), final                                | `3c289ab9536fb1296fecb72d9ae43b10b0a67f92` | [VERIFY.md](https://github.com/Metricxyz/pool-contracts/blob/audit-4410fec/VERIFY.md) |
| [`audit-33d0a34`](https://github.com/Metricxyz/pool-contracts/tree/audit-33d0a34) | Zellic re-audit (Sep 2026), starting point: the re-audit reviewed the changes from here to `4410fec` | `6f035fef61d3e6a154206c152a94f45a5bee4cbe` | [VERIFY.md](https://github.com/Metricxyz/pool-contracts/blob/audit-33d0a34/VERIFY.md) |

Two more tags hold the versions of this code that [periphery-contracts](https://github.com/Metricxyz/periphery-contracts) uses as its `lib/metric-core` dependency in its audited commits: [`audit-72c65de`](https://github.com/Metricxyz/pool-contracts/tree/audit-72c65de) (`contracts/` `30585c3ce8632be5e8be64b66853c945234b22e1`, [VERIFY.md](https://github.com/Metricxyz/pool-contracts/blob/audit-72c65de/VERIFY.md)) and [`audit-d4d0e2a`](https://github.com/Metricxyz/pool-contracts/tree/audit-d4d0e2a) (`contracts/` `77ccd4f0bbc452ed47f3aa6394e23b90037c241a`, [VERIFY.md](https://github.com/Metricxyz/pool-contracts/blob/audit-d4d0e2a/VERIFY.md)).

To verify a tag, clone it and run its check script (Python 3 and git only):

```bash
git clone --branch audit-4410fec https://github.com/Metricxyz/pool-contracts.git
cd pool-contracts
python verify/verify.py .
```

It ends with `OK: contracts/ at this tag is identical to contracts/ in audited commit …`. Each tag's `VERIFY.md` explains the check step by step. For a quick look, compare the hash directly:

```bash
git rev-parse audit-4410fec:contracts   # 3c289ab9536fb1296fecb72d9ae43b10b0a67f92
```

### Changes since the last audit

Since `4410fec` there is one logic change: [`d4d0e2a`](https://github.com/Metricxyz/pool-contracts/tree/audit-d4d0e2a) fixes precision loss in the bid/ask/reference asymmetry check and raises the optimizer runs setting. That version is the `lib/metric-core` dependency of the periphery code Sherlock reviewed in September 2026. Every other change is to NatSpec, documentation or formatting.

## License

Multi-licensed; the SPDX header on each file is authoritative.

- **BUSL-1.1** (`licenses/BUSL_LICENSE`) — `MetricOmmPool.sol`, `MetricOmmPoolFactory.sol`,
  `MetricOmmPoolDeployer.sol`, `libraries/SwapMath.sol`, `libraries/FeeMath.sol`,
  `libraries/LiquidityLib.sol`. Production use
  is granted except for a Competing Use as defined in the license. Change Date **2029-07-02** (or the third anniversary of a version's first public distribution, whichever comes first), after
  which these files fall under the Change License (MIT).
- **AGPL-3.0-only** (`licenses/AGPL_LICENSE`) — `auth/Auth.sol`, derived from Solmate.
- **MIT** (`licenses/MIT_LICENSE`) — every other file, including all interfaces and types, so
  integrators can build against the ABI without restriction.
