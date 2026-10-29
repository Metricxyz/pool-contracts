// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {MetricOmmPoolBaseTest} from "./MetricOmmPool.base.t.sol";
import {PoolStateLibrary} from "../contracts/libraries/PoolStateLibrary.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract PoolStateLibraryTest is MetricOmmPoolBaseTest {
  using SafeCast for uint256;

  uint80 constant SALT = 0;
  uint256 constant USER = 0;

  /// @dev Add liquidity across negative and positive bins, then batch-read bin total shares
  ///      and verify each decoded value matches the single-bin reader.
  function test_multipleBinTotalShares_matchesSingleReads() public {
    int8 lower = -5;
    int8 upper = 4;
    uint104 sharesPerBin = 50_000;
    _addLiquidity(USER, lower, upper, sharesPerBin, SALT);

    int8[] memory bins = _int8Range(lower, upper);
    bytes32[] memory batchRaw = _getMultipleBinTotalShares(bins);
    assertEq(batchRaw.length, bins.length, "batch length");

    for (uint256 i = 0; i < bins.length; i++) {
      uint256 decoded = _decodeBinTotalShares(batchRaw[i]);
      uint104 single = _getBinTotalShares(bins[i]);
      assertEq(decoded, uint256(single), "bin total shares mismatch");
      assertEq(decoded, sharesPerBin, "expected shares per bin");
    }
  }

  /// @dev Add liquidity across negative and positive bins, then batch-read position bin shares
  ///      and verify each decoded value matches the single-bin reader.
  function test_multiplePositionBinShares_matchesSingleReads() public {
    int8 lower = -5;
    int8 upper = 4;
    uint104 sharesPerBin = 50_000;
    _addLiquidity(USER, lower, upper, sharesPerBin, SALT);

    address owner = _getCallerAddress(USER);
    int8[] memory bins = _int8Range(lower, upper);
    bytes32[] memory batchRaw = _getMultiplePositionBinShares(owner, SALT, bins);
    assertEq(batchRaw.length, bins.length, "batch length");

    for (uint256 i = 0; i < bins.length; i++) {
      uint256 decoded = _decodePositionBinShares(batchRaw[i]);
      uint104 single = _getPositionBinShares(owner, SALT, bins[i]);
      assertEq(decoded, uint256(single), "position shares mismatch");
      assertEq(decoded, sharesPerBin, "expected shares per bin");
    }
  }

  /// @dev Two users add different amounts to overlapping ranges spanning negative and positive bins.
  ///      Batch-read bin total shares (sum of both users) and per-position shares for each user.
  function test_batchReads_twoUsers_negativeAndPositiveBins() public {
    uint256 user0 = 0;
    uint256 user1 = 1;
    uint80 salt0 = 0;
    uint80 salt1 = 1;

    int8 lower0 = -3;
    int8 upper0 = 2;
    uint104 shares0 = 30_000;
    _addLiquidity(user0, lower0, upper0, shares0, salt0);

    int8 lower1 = -1;
    int8 upper1 = 4;
    uint104 shares1 = 20_000;
    _addLiquidity(user1, lower1, upper1, shares1, salt1);

    int8[] memory allBins = _int8Range(-3, 4);
    bytes32[] memory totalSharesRaw = _getMultipleBinTotalShares(allBins);
    assertEq(totalSharesRaw.length, allBins.length, "batch length");

    for (uint256 i = 0; i < allBins.length; i++) {
      int8 bin = allBins[i];
      uint256 decoded = _decodeBinTotalShares(totalSharesRaw[i]);

      bool inRange0 = bin >= lower0 && bin <= upper0;
      bool inRange1 = bin >= lower1 && bin <= upper1;
      uint256 expected = (inRange0 ? shares0 : uint104(0)) + (inRange1 ? shares1 : uint104(0));

      assertEq(decoded, expected, "bin total shares mismatch");
    }

    address owner0 = _getCallerAddress(user0);
    int8[] memory bins0 = _int8Range(lower0, upper0);
    bytes32[] memory pos0Raw = _getMultiplePositionBinShares(owner0, salt0, bins0);
    for (uint256 i = 0; i < bins0.length; i++) {
      assertEq(_decodePositionBinShares(pos0Raw[i]), shares0, "user0 position shares");
    }

    address owner1 = _getCallerAddress(user1);
    int8[] memory bins1 = _int8Range(lower1, upper1);
    bytes32[] memory pos1Raw = _getMultiplePositionBinShares(owner1, salt1, bins1);
    for (uint256 i = 0; i < bins1.length; i++) {
      assertEq(_decodePositionBinShares(pos1Raw[i]), shares1, "user1 position shares");
    }
  }

  /// @dev Querying bins that have no liquidity returns zero for each element.
  function test_batchReads_emptyBins_returnZero() public view {
    int8[] memory bins = new int8[](3);
    bins[0] = -5;
    bins[1] = 0;
    bins[2] = 4;

    bytes32[] memory totalSharesRaw = _getMultipleBinTotalShares(bins);
    for (uint256 i = 0; i < bins.length; i++) {
      assertEq(_decodeBinTotalShares(totalSharesRaw[i]), 0, "empty bin total shares");
    }

    address owner = _getCallerAddress(USER);
    bytes32[] memory posSharesRaw = _getMultiplePositionBinShares(owner, SALT, bins);
    for (uint256 i = 0; i < bins.length; i++) {
      assertEq(_decodePositionBinShares(posSharesRaw[i]), 0, "empty position shares");
    }
  }

  /// @dev After partial removal, batch reads reflect the updated shares correctly.
  function test_batchReads_afterPartialRemoval() public {
    int8 lower = -2;
    int8 upper = 3;
    uint104 initialShares = 40_000;
    _addLiquidity(USER, lower, upper, initialShares, SALT);

    uint104 removeShares = 15_000;
    _removeLiquidity(USER, lower, upper, removeShares, SALT);

    uint104 expectedShares = initialShares - removeShares;
    address owner = _getCallerAddress(USER);
    int8[] memory bins = _int8Range(lower, upper);

    bytes32[] memory totalSharesRaw = _getMultipleBinTotalShares(bins);
    bytes32[] memory posSharesRaw = _getMultiplePositionBinShares(owner, SALT, bins);

    for (uint256 i = 0; i < bins.length; i++) {
      assertEq(_decodeBinTotalShares(totalSharesRaw[i]), expectedShares, "total shares after removal");
      assertEq(_decodePositionBinShares(posSharesRaw[i]), expectedShares, "position shares after removal");
    }
  }

  // ---- helpers ----

  function _int8Range(int8 lower, int8 upper) internal pure returns (int8[] memory arr) {
    // forge-lint: disable-next-line(unsafe-typecast) -- `upper >= lower` in test inputs, so the range length is non-negative.
    uint256 len = uint256(int256(upper) - int256(lower) + 1);
    arr = new int8[](len);
    for (uint256 i = 0; i < len; i++) {
      // forge-lint: disable-next-line(unsafe-typecast) -- `lower + i` stays within `int8` since `i < len <= upper - lower`.
      arr[i] = int8(int256(lower) + int256(i));
    }
  }
}
