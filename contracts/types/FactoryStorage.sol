// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @notice Canonical per-pool fee rates persisted on factory and mirrored into pool totals.
/// @dev Units: spread fields are E6 (`1e6 = 100%`), notional fields are E8 (`1e8 = 100%`).
struct PoolFeeConfig {
  uint24 protocolSpreadFeeE6;
  uint24 adminSpreadFeeE6;
  uint24 protocolNotionalFeeE8;
  uint24 adminNotionalFeeE8;
}
