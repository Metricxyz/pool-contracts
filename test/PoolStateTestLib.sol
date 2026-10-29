// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {PoolStateLibrary} from "../contracts/libraries/PoolStateLibrary.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @notice Thin external library for tests (keeps MetricOmmPoolBaseTest stack shallow).
library PoolStateTestLib {
  using SafeCast for uint256;

  function binTotalShares(address pool, int8 binIdx) external view returns (uint104) {
    return PoolStateLibrary._binTotalShares(pool, binIdx).toUint104();
  }

  function positionBinShares(address pool, address owner, uint80 salt, int8 bin) external view returns (uint104) {
    return PoolStateLibrary._positionBinShares(pool, owner, salt, bin).toUint104();
  }

  function binState(address pool, int8 binIdx)
    external
    view
    returns (uint104 token0Balance, uint104 token1Balance, uint16 lengthE6, uint16 addFeeBuyE6, uint16 addFeeSellE6)
  {
    return PoolStateLibrary._binState(pool, binIdx);
  }

  function curBinIdx(address pool) external view returns (int8) {
    (, int8 value,,,,) = PoolStateLibrary._slot0(pool);
    return value;
  }

  function curPosInBin(address pool) external view returns (uint104) {
    (,, uint104 value,,,) = PoolStateLibrary._slot0(pool);
    return value;
  }

  function multipleBinTotalShares(address pool, int8[] memory binIdxs) external view returns (bytes32[] memory) {
    return PoolStateLibrary._multipleBinTotalShares(pool, binIdxs);
  }

  function multiplePositionBinShares(address pool, address owner, uint80 salt, int8[] memory binIdxs)
    external
    view
    returns (bytes32[] memory)
  {
    return PoolStateLibrary._multiplePositionBinShares(pool, owner, salt, binIdxs);
  }

  function decodeBinTotalShares(bytes32 data) external pure returns (uint256) {
    return PoolStateLibrary._decodeBinTotalShares(data);
  }

  function decodePositionBinShares(bytes32 data) external pure returns (uint256) {
    return PoolStateLibrary._decodePositionBinShares(data);
  }
}
