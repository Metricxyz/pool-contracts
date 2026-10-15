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
git clone --recursive https://github.com/Metricxyz/metric-core.git
cd metric-core
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
- **Periphery** — Routers, quoters, lenses and product extensions live in [metric-periphery](https://github.com/Metricxyz/metric-periphery).

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
