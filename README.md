# Metric OMM Core

Core smart contracts for the Metric OMM protocol: oracle-based pools with bin-based liquidity, factory deployment, and EXTSLOAD-aligned state reads.

## Overview

Pools use external price providers for bid/ask, maintain liquidity in configurable bins, and enforce pause levels and optional per-pool extensions. Integrators typically interact via **`IMetricOmmPool`** (composed actions, fee collection, and factory-only controls).

## Contracts

### Pool and factory

- **MetricOmmPool.sol** — Main pool (liquidity, swap, simulation, factory/protocol controls).
- **MetricOmmPoolFactory.sol** — Pool registry, fee caps, `createPool`, deployer wiring, pools' administrative actions
- **MetricOmmPoolDeployer.sol** — CREATE2-style deployment of pool bytecode (factory-only).

### Supporting contracts

- **Extsload.sol** — `EXTSLOAD`-based storage reads (forked from Uniswap v4-style pattern); pool layout must stay aligned with **PoolStateLibrary**.
- **Extensions** — Optional per-pool `IMetricOmmExtensions` (up to seven extensions with per extension point call order at deploy). Product extensions live in **metric-periphery**; core tests plumbing via `test/mocks/MockMetricExtension.sol` and `test/mocks/extensions/GateExtension.sol` (see `test/README.extensions.md`).

### Libraries

- **SwapMath.sol** — Pure swap/step math.
- **BinDataLibrary.sol** — Bin encoding helpers.
- **PoolStateLibrary.sol** — Slot helpers for EXTSLOAD readers; must match **MetricOmmPool** storage packing.
- **Slot0Library.sol** — Pack/unpack storage slot 0 (`packedSlot0` on swap extension point functions).
- **CallExtension.sol** — Low-level extension call and selector validation.
- **ValidateExtensionsConfig.sol** — Factory validation for extension addresses, init data, and call orders.
- **ExtensionCalling.sol** — Abstract base for ordered per-pool extension invocation.

## Requirements

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (pin locally to the version in `.github/workflows/test.yml` for consistent `forge fmt --check`).

## Installation

```bash
git clone --recursive https://github.com/Metric-OMM/metric-core.git
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

## Formatting

- **Solidity** (`contracts/`, `test/`): use Foundry only so CI and locals stay aligned.

```bash
npm run format:forge:check   # same as CI
forge fmt
```

Or run both Prettier and Foundry checks: `npm run format:check`.

- **Other text** (Markdown, JSON, YAML, and other Prettier-supported files outside ignored paths): `npm install` then `npm run format:prettier` / `npm run format:prettier:check`. Solidity and `contracts/` / `test/` are excluded via `.prettierignore`; use **`forge fmt`** for `.sol` files.

CI runs Prettier check and `forge fmt --check` (see `.github/workflows/test.yml`). Workflows pin **Foundry 1.7.0** and **`solc` 0.8.35** — match locally (`forge --version`, same `foundry.toml` `solc`).

### Local pre-commit hook

Running **`npm install`** executes the **`prepare`** script, which sets **`git config --local core.hooksPath .githooks`**. Verify hooks are active:

```bash
git config --local --get core.hooksPath   # must print: .githooks
```

If empty, enable manually:

```bash
git config --local core.hooksPath .githooks
```

The hook runs **`npm run format:prettier:check`**, **`forge fmt --check`** (fails the commit on format drift), and **`forge test`**. Foundry must be on `PATH`. Skip with **`git commit --no-verify`**.

## Documentation

- **[Pool configuration and management](docs/POOL_CONFIGURATION_AND_MANAGEMENT.md)** — `createPool` / constructor parameters, bins, admin vs protocol roles.

## Project structure

```text
contracts/
├── MetricOmmPool.sol
├── MetricOmmPoolFactory.sol
├── MetricOmmPoolDeployer.sol
├── Extsload.sol
├── interfaces/
│   ├── IMetricOmmPool/
│   ├── IMetricOmmPoolFactory/
│   ├── IPriceProvider/
│   └── callbacks/
├── libraries/
└── types/

test/                  # Foundry tests (*.t.sol, harnesses)
test/mocks/            # Test doubles (e.g. MockERC20, MockOracle, TestCaller)
```

## License

UNLICENSED
