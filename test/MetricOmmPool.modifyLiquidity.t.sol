// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {GateExtension} from "./mocks/extensions/GateExtension.sol";
import {Vm} from "forge-std/Vm.sol";
import {MetricOmmPoolBaseTest} from "./MetricOmmPool.base.t.sol";
import {IMetricOmmPoolActions} from "../contracts/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {
  IMetricOmmModifyLiquidityCallback
} from "../contracts/interfaces/callbacks/IMetricOmmModifyLiquidityCallback.sol";
import {IMetricOmmPool, PoolImmutables} from "../contracts/interfaces/IMetricOmmPool/IMetricOmmPool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BinBalanceDelta, LiquidityDelta} from "../contracts/types/PoolOperation.sol";
import {BinState} from "../contracts/types/PoolStorage.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @notice Calls addLiquidity and can deliberately underpay one token in the callback (for InsufficientTokenBalance tests)
contract UnderpayingModifyLiquidityCaller is IMetricOmmModifyLiquidityCallback {
  using SafeERC20 for IERC20;

  enum Underpay {
    None,
    Token0,
    Token1
  }

  Underpay public underpay;

  function setUnderpay(Underpay u) external {
    underpay = u;
  }

  function addLiquidity(address pool, uint80 salt, LiquidityDelta memory deltas) external {
    IMetricOmmPoolActions(pool).addLiquidity(address(this), salt, deltas, "", "");
  }

  function metricOmmModifyLiquidityCallback(uint256 amount0Delta, uint256 amount1Delta, bytes calldata)
    external
    override
  {
    PoolImmutables memory immutables = IMetricOmmPool(msg.sender).getImmutables();
    address token0 = immutables.token0;
    address token1 = immutables.token1;
    if (amount0Delta > 0) {
      uint256 pay = amount0Delta;
      if (underpay == Underpay.Token0 && pay > 0) pay -= 1;
      IERC20(token0).safeTransfer(msg.sender, pay);
    }
    if (amount1Delta > 0) {
      uint256 pay = amount1Delta;
      if (underpay == Underpay.Token1 && pay > 0) pay -= 1;
      IERC20(token1).safeTransfer(msg.sender, pay);
    }
  }
}

contract MetricOmmPoolModifyLiquidityTest is MetricOmmPoolBaseTest {
  using SafeCast for uint256;
  using SafeCast for int256;

  uint72 constant DEFAULT_SALT = 12345;
  uint256 constant USER_INDEX = 0;

  function _deployPoolWithDepositGate() internal returns (GateExtension extension) {
    (BinState[] memory nonNegativeBinStates, BinState[] memory negativeBinStates) = _defaultBinStateArrays();
    extension = new GateExtension();
    pool = _deployPoolAndRegister(
      PoolDeployParams({
        priceProvider: address(oracle),
        extensions: _singleExtensionPoolExtensions(address(extension)),
        extensionOrders: _extensionOrdersWithBeforeAddLiquidity(),
        immutablePriceProvider: true,
        protocolSpreadFeeE6: PROTOCOL_FEE,
        adminSpreadFeeE6: ADMIN_FEE,
        curBinDistFromProvidedPriceE6: 0,
        nonNegativeBinStates: nonNegativeBinStates,
        negativeBinStates: negativeBinStates,
        protocolNotionalFeeE8: 0,
        adminNotionalFeeE8: 0,
        immutablePriceProviderForRegistry: address(oracle),
        lowestBin: -1,
        highestBin: 0
      })
    );
    _approveUsersForPool(address(pool));
    extension.bindPool(address(pool));
  }

  function _createDelta(int8 binIdx, uint104 shares) internal pure returns (LiquidityDelta memory) {
    int256[] memory bins = new int256[](1);
    uint256[] memory sharesArr = new uint256[](1);
    bins[0] = binIdx;
    sharesArr[0] = shares;
    return LiquidityDelta({binIdxs: bins, shares: sharesArr});
  }

  function _createDeltaArray(int8 binIdx, uint104 shares) internal pure returns (LiquidityDelta memory) {
    return _createDelta(binIdx, shares);
  }

  function _createDeltas(int256[] memory binIdxs, uint104[] memory shares)
    internal
    pure
    returns (LiquidityDelta memory)
  {
    uint256 length = binIdxs.length;
    uint256[] memory shares256 = new uint256[](length);
    for (uint256 i = 0; i < length; i++) {
      shares256[i] = shares[i];
    }
    return LiquidityDelta({binIdxs: binIdxs, shares: shares256});
  }

  function _doAddLiquidity(uint256 userIndex, uint80 salt, LiquidityDelta memory deltas)
    internal
    returns (uint256 amount0Added, uint256 amount1Added)
  {
    vm.prank(users[userIndex]);
    return callers[userIndex].addLiquidity(address(pool), salt, deltas);
  }

  function _doRemoveLiquidity(uint256 userIndex, uint80 salt, LiquidityDelta memory deltas)
    internal
    returns (uint256 amount0Removed, uint256 amount1Removed)
  {
    vm.prank(users[userIndex]);
    return callers[userIndex].removeLiquidity(address(pool), salt, deltas);
  }

  function _callAddLiquidity(uint256 userIndex, uint80 salt, LiquidityDelta memory deltas)
    internal
    returns (uint256 amount0Added, uint256 amount1Added)
  {
    vm.prank(users[userIndex]);
    return callers[userIndex].addLiquidity(address(pool), salt, deltas);
  }

  function _callRemoveLiquidity(uint256 userIndex, uint80 salt, LiquidityDelta memory deltas)
    internal
    returns (uint256 amount0Removed, uint256 amount1Removed)
  {
    vm.prank(users[userIndex]);
    return callers[userIndex].removeLiquidity(address(pool), salt, deltas);
  }

  /// @dev Adding liquidity above current tick should only require token0
  function test_modifyLiquidity_addToSingleBin_aboveCurrentTick() public {
    address caller = _getCallerAddress(USER_INDEX);
    int8 bin = 4; // Above current tick (0)
    uint104 shares = 10000;

    (uint256 amount0Added, uint256 amount1Added) =
      _doAddLiquidity(USER_INDEX, DEFAULT_SALT, _createDeltaArray(bin, shares));

    assertGt(amount0Added, 0, "Should require token0");
    assertEq(amount1Added, 0, "Should not require token1");

    uint104 posShares = _getPositionBinShares(caller, DEFAULT_SALT, bin);
    assertEq(posShares, uint104(shares), "Position shares mismatch");

    assertEq(_getBinTotalShares(bin), uint104(shares), "Bin total shares mismatch");
  }

  /// @dev Adding liquidity below current tick should only require token1
  function test_modifyLiquidity_addToSingleBin_belowCurrentTick() public {
    address caller = _getCallerAddress(USER_INDEX);
    int8 bin = -5; // Below current tick (0)
    uint104 shares = 10000;

    (uint256 amount0Added, uint256 amount1Added) =
      _doAddLiquidity(USER_INDEX, DEFAULT_SALT, _createDeltaArray(bin, shares));

    assertEq(amount0Added, 0, "Should not require token0");
    assertGt(amount1Added, 0, "Should require token1");

    uint104 posShares = _getPositionBinShares(caller, DEFAULT_SALT, bin);
    assertEq(posShares, uint104(shares), "Position shares mismatch");
  }

  /// @dev Adding liquidity to current bin requires tokens proportional to position in bin
  function test_modifyLiquidity_addToCurrentBin() public {
    address caller = _getCallerAddress(USER_INDEX);
    int8 bin = 0; // Current tick
    uint104 shares = 10000;

    (uint256 amount0Added,) = _doAddLiquidity(USER_INDEX, DEFAULT_SALT, _createDeltaArray(bin, shares));

    assertGt(amount0Added, 0, "Should require token0");

    uint104 posShares = _getPositionBinShares(caller, DEFAULT_SALT, bin);
    assertEq(posShares, uint104(shares), "Position shares mismatch");
  }

  /// @dev Can add liquidity to multiple bins in a single call
  function test_modifyLiquidity_addToMultipleBins() public {
    address caller = _getCallerAddress(USER_INDEX);

    int256[] memory bins = new int256[](3);
    bins[0] = -3;
    bins[1] = 0;
    bins[2] = 3;
    uint104[] memory sharesByBin = new uint104[](3);
    sharesByBin[0] = 5000;
    sharesByBin[1] = 10000;
    sharesByBin[2] = 5000;
    LiquidityDelta memory deltas = _createDeltas(bins, sharesByBin);

    (uint256 amount0Added, uint256 amount1Added) = _doAddLiquidity(USER_INDEX, DEFAULT_SALT, deltas);

    assertGt(amount0Added, 0, "Should require token0");
    assertGt(amount1Added, 0, "Should require token1");

    assertEq(_getPositionBinShares(caller, DEFAULT_SALT, -3), 5000, "Bin -3 shares mismatch");
    assertEq(_getPositionBinShares(caller, DEFAULT_SALT, 0), 10000, "Bin 0 shares mismatch");
    assertEq(_getPositionBinShares(caller, DEFAULT_SALT, 3), 5000, "Bin 3 shares mismatch");
  }

  /// @dev Removing liquidity returns tokens to user
  function test_modifyLiquidity_removeFromBin() public {
    address caller = _getCallerAddress(USER_INDEX);
    int8 bin = 4;
    uint104 sharesToAdd = 10000;

    _doAddLiquidity(USER_INDEX, DEFAULT_SALT, _createDeltaArray(bin, sharesToAdd));

    (uint256 amount0Removed, uint256 amount1Removed) =
      _doRemoveLiquidity(USER_INDEX, DEFAULT_SALT, _createDeltaArray(bin, 5000));

    assertGt(amount0Removed, 0, "Should return token0");
    assertEq(amount1Removed, 0, "Should not return token1");

    assertEq(_getPositionBinShares(caller, DEFAULT_SALT, bin), 5000, "Remaining shares mismatch");
    assertEq(_getBinTotalShares(bin), 5000, "Bin total shares mismatch");
  }

  /// @dev Removing from a bin below the current price returns token1 only (mirrors token0-only path above current)
  function test_modifyLiquidity_removeBelowCurrentBin_returnsToken1Only() public {
    address caller = _getCallerAddress(USER_INDEX);
    int8 bin = -5;
    uint104 sharesToAdd = 10_000;

    _doAddLiquidity(USER_INDEX, DEFAULT_SALT, _createDeltaArray(bin, sharesToAdd));

    (uint256 amount0Removed, uint256 amount1Removed) =
      _doRemoveLiquidity(USER_INDEX, DEFAULT_SALT, _createDeltaArray(bin, 5000));

    assertEq(amount0Removed, 0, "Should not return token0");
    assertGt(amount1Removed, 0, "Should return token1");

    assertEq(_getPositionBinShares(caller, DEFAULT_SALT, bin), 5000, "Remaining shares mismatch");
  }

  /// @dev Removing all shares from a bin zeroes out position
  function test_modifyLiquidity_removeAllFromBin() public {
    address caller = _getCallerAddress(USER_INDEX);
    int8 bin = 4;
    uint104 shares = 10000;

    _doAddLiquidity(USER_INDEX, DEFAULT_SALT, _createDeltaArray(bin, shares));

    _doRemoveLiquidity(USER_INDEX, DEFAULT_SALT, _createDeltaArray(bin, shares));

    assertEq(_getPositionBinShares(caller, DEFAULT_SALT, bin), 0, "Shares should be zero");
    assertEq(_getBinTotalShares(bin), 0, "Bin total shares should be zero");
  }

  /// @dev Can add to several bins, then remove from one bin and add to another in separate calls
  function test_modifyLiquidity_mixedAddRemove() public {
    address caller = _getCallerAddress(USER_INDEX);

    int256[] memory bins = new int256[](2);
    bins[0] = -5;
    bins[1] = 4;
    uint104[] memory sharesByBin = new uint104[](2);
    sharesByBin[0] = 10000;
    sharesByBin[1] = 10000;
    LiquidityDelta memory addDeltas = _createDeltas(bins, sharesByBin);

    _doAddLiquidity(USER_INDEX, DEFAULT_SALT, addDeltas);

    _doRemoveLiquidity(USER_INDEX, DEFAULT_SALT, _createDeltaArray(4, 5000));
    _doAddLiquidity(USER_INDEX, DEFAULT_SALT, _createDeltaArray(3, 5000));

    assertEq(_getPositionBinShares(caller, DEFAULT_SALT, -5), 10000, "Bin -5 unchanged");
    assertEq(_getPositionBinShares(caller, DEFAULT_SALT, 4), 5000, "Bin 4 reduced");
    assertEq(_getPositionBinShares(caller, DEFAULT_SALT, 3), 5000, "Bin 3 added");
  }

  /// @dev Empty deltas array returns zero amounts for add and remove
  function test_modifyLiquidity_emptyDeltas() public {
    int256[] memory bins = new int256[](0);
    uint104[] memory sharesByBin = new uint104[](0);
    LiquidityDelta memory deltas = _createDeltas(bins, sharesByBin);

    (uint256 a0, uint256 a1) = _callAddLiquidity(USER_INDEX, DEFAULT_SALT, deltas);
    assertEq(a0, 0, "add amount0Delta should be 0");
    assertEq(a1, 0, "add amount1Delta should be 0");

    (uint256 r0, uint256 r1) = _callRemoveLiquidity(USER_INDEX, DEFAULT_SALT, deltas);
    assertEq(r0, 0, "remove amount0Delta should be 0");
    assertEq(r1, 0, "remove amount1Delta should be 0");
  }

  /// @dev Zero deltaShares entries are skipped
  function test_modifyLiquidity_zeroDeltaShares() public {
    address caller = _getCallerAddress(USER_INDEX);

    int256[] memory bins = new int256[](2);
    bins[0] = 4;
    bins[1] = 3;
    uint104[] memory sharesByBin = new uint104[](2);
    sharesByBin[0] = 0;
    sharesByBin[1] = 10000;
    LiquidityDelta memory deltas = _createDeltas(bins, sharesByBin);

    _doAddLiquidity(USER_INDEX, DEFAULT_SALT, deltas);

    assertEq(_getPositionBinShares(caller, DEFAULT_SALT, 4), 0, "Bin 4 should have no shares");
    assertEq(_getPositionBinShares(caller, DEFAULT_SALT, 3), 10000, "Bin 3 should have shares");
  }

  /// @dev Multiple deltas pointing to the same bin are aggregated correctly
  function test_modifyLiquidity_duplicateBins_add() public {
    address caller = _getCallerAddress(USER_INDEX);
    int8 bin = 4;

    int256[] memory bins = new int256[](3);
    bins[0] = bin;
    bins[1] = bin;
    bins[2] = bin;
    uint104[] memory sharesByBin = new uint104[](3);
    sharesByBin[0] = 3000;
    sharesByBin[1] = 5000;
    sharesByBin[2] = 2000;
    LiquidityDelta memory deltas = _createDeltas(bins, sharesByBin);

    _doAddLiquidity(USER_INDEX, DEFAULT_SALT, deltas);

    assertEq(_getPositionBinShares(caller, DEFAULT_SALT, bin), 10000, "Total shares mismatch");
    assertEq(_getBinTotalShares(bin), 10000, "Bin total shares mismatch");
  }

  /// @dev Multiple deltas with mixed bins, some duplicated
  function test_modifyLiquidity_duplicateBins_mixed() public {
    address caller = _getCallerAddress(USER_INDEX);

    int256[] memory bins = new int256[](5);
    bins[0] = 3;
    bins[1] = 4;
    bins[2] = 3;
    bins[3] = 0;
    bins[4] = 4;
    uint104[] memory sharesByBin = new uint104[](5);
    sharesByBin[0] = 2000;
    sharesByBin[1] = 3000;
    sharesByBin[2] = 4000;
    sharesByBin[3] = 1000;
    sharesByBin[4] = 2000;
    LiquidityDelta memory deltas = _createDeltas(bins, sharesByBin);

    _doAddLiquidity(USER_INDEX, DEFAULT_SALT, deltas);

    assertEq(_getPositionBinShares(caller, DEFAULT_SALT, 3), 6000, "Bin 3: 2000+4000=6000");
    assertEq(_getPositionBinShares(caller, DEFAULT_SALT, 4), 5000, "Bin 4: 3000+2000=5000");
    assertEq(_getPositionBinShares(caller, DEFAULT_SALT, 0), 1000, "Bin 0: 1000");
  }

  /// @dev Sequenced add/remove on the same bin reaches the same net as the old single-call mixed deltas
  function test_modifyLiquidity_duplicateBins_netPositive() public {
    address caller = _getCallerAddress(USER_INDEX);
    int8 bin = 4;

    _doAddLiquidity(USER_INDEX, DEFAULT_SALT, _createDeltaArray(bin, 10000));
    assertEq(_getPositionBinShares(caller, DEFAULT_SALT, bin), 10000);

    _doAddLiquidity(USER_INDEX, DEFAULT_SALT, _createDeltaArray(bin, 5000));
    _doRemoveLiquidity(USER_INDEX, DEFAULT_SALT, _createDeltaArray(bin, 3000));
    _doAddLiquidity(USER_INDEX, DEFAULT_SALT, _createDeltaArray(bin, 2000));

    assertEq(_getPositionBinShares(caller, DEFAULT_SALT, bin), 14000, "10000+4000=14000");
  }

  /// @dev Sequenced add/remove on the same bin reaches the same net as the old single-call mixed deltas
  function test_modifyLiquidity_duplicateBins_netNegative() public {
    address caller = _getCallerAddress(USER_INDEX);
    int8 bin = 4;

    _doAddLiquidity(USER_INDEX, DEFAULT_SALT, _createDeltaArray(bin, 10000));
    assertEq(_getPositionBinShares(caller, DEFAULT_SALT, bin), 10000);

    _doAddLiquidity(USER_INDEX, DEFAULT_SALT, _createDeltaArray(bin, 2000));
    _doRemoveLiquidity(USER_INDEX, DEFAULT_SALT, _createDeltaArray(bin, 5000));
    _doAddLiquidity(USER_INDEX, DEFAULT_SALT, _createDeltaArray(bin, 1000));

    assertEq(_getPositionBinShares(caller, DEFAULT_SALT, bin), 8000, "10000-2000=8000");
  }

  /// @dev Sequenced add/remove on the same bin reaches the same net as the old single-call mixed deltas
  function test_modifyLiquidity_duplicateBins_netZero() public {
    address caller = _getCallerAddress(USER_INDEX);
    int8 bin = 4;

    _doAddLiquidity(USER_INDEX, DEFAULT_SALT, _createDeltaArray(bin, 10000));
    assertEq(_getPositionBinShares(caller, DEFAULT_SALT, bin), 10000);

    _doAddLiquidity(USER_INDEX, DEFAULT_SALT, _createDeltaArray(bin, 3000));
    _doRemoveLiquidity(USER_INDEX, DEFAULT_SALT, _createDeltaArray(bin, 5000));
    _doAddLiquidity(USER_INDEX, DEFAULT_SALT, _createDeltaArray(bin, 2000));

    assertEq(_getPositionBinShares(caller, DEFAULT_SALT, bin), 10000, "Should remain unchanged");
  }

  /// @dev Reverts when bin index is outside valid range
  function test_modifyLiquidity_invalidBinIndex_reverts() public {
    vm.expectRevert(abi.encodeWithSelector(IMetricOmmPoolActions.InvalidBinIndex.selector, int8(20)));
    _callAddLiquidity(USER_INDEX, DEFAULT_SALT, _createDeltaArray(20, 10000));
  }

  /// @dev Reverts when trying to remove more shares than owned
  function test_modifyLiquidity_insufficientShares_reverts() public {
    int8 bin = 4;

    _doAddLiquidity(USER_INDEX, DEFAULT_SALT, _createDeltaArray(bin, 5000));

    vm.expectRevert(
      abi.encodeWithSelector(IMetricOmmPoolActions.InsufficientLiquidity.selector, uint104(10000), uint104(5000))
    );
    _callRemoveLiquidity(USER_INDEX, DEFAULT_SALT, _createDeltaArray(bin, 10000));
  }

  /// @dev Multiple users can use same salt - positions are keyed by (owner, salt, bin)
  function test_modifyLiquidity_multipleUsers_sameSalt() public {
    uint256 user1Index = 0;
    uint256 user2Index = 1;
    address caller1 = _getCallerAddress(user1Index);
    address caller2 = _getCallerAddress(user2Index);
    int8 bin = 4;
    uint104 shares = 10000;

    _doAddLiquidity(user1Index, DEFAULT_SALT, _createDeltaArray(bin, shares));

    _doAddLiquidity(user2Index, DEFAULT_SALT, _createDeltaArray(bin, shares));

    assertEq(_getPositionBinShares(caller1, DEFAULT_SALT, bin), uint104(shares), "User1 shares");
    assertEq(_getPositionBinShares(caller2, DEFAULT_SALT, bin), uint104(shares), "User2 shares");

    assertEq(_getBinTotalShares(bin), uint104(shares) * 2, "Bin total shares");
  }

  /// @dev Same user can have multiple positions using different salts
  function test_modifyLiquidity_sameUser_differentSalts() public {
    address caller = _getCallerAddress(USER_INDEX);
    int8 bin = 4;
    uint80 salt1 = 111;
    uint80 salt2 = 222;

    _doAddLiquidity(USER_INDEX, salt1, _createDeltaArray(bin, 5000));

    _doAddLiquidity(USER_INDEX, salt2, _createDeltaArray(bin, 10000));

    assertEq(_getPositionBinShares(caller, salt1, bin), 5000, "Salt1 shares");
    assertEq(_getPositionBinShares(caller, salt2, bin), 10000, "Salt2 shares");

    assertEq(_getBinTotalShares(bin), 15000, "Bin total shares");
  }

  /// @dev Adding to existing bin uses proportional token amounts
  function test_modifyLiquidity_proportionalAdd() public {
    uint256 user1Index = 0;
    uint256 user2Index = 1;
    int8 bin = 4;

    (uint256 user1Amount0,) = _doAddLiquidity(user1Index, DEFAULT_SALT, _createDeltaArray(bin, 10000));

    (uint256 user2Amount0,) = _doAddLiquidity(user2Index, DEFAULT_SALT, _createDeltaArray(bin, 10000));

    assertApproxEqAbs(user2Amount0, user1Amount0, 1, "Proportional amounts should be equal");
  }

  /// @dev LiquidityAdded event is emitted with correct values
  function test_modifyLiquidity_emitsEvent() public {
    address caller = _getCallerAddress(USER_INDEX);
    int8 bin = 4;
    uint104 shares = 10000;

    vm.recordLogs();

    _doAddLiquidity(USER_INDEX, DEFAULT_SALT, _createDeltaArray(bin, shares));

    Vm.Log[] memory logs = vm.getRecordedLogs();
    bool eventFound = false;
    for (uint256 i = 0; i < logs.length; i++) {
      if (logs[i].topics[0] == keccak256("LiquidityAdded(address,uint80,int256[],(int256,int256)[],uint256[])")) {
        eventFound = true;
        assertEq(address(uint160(uint256(logs[i].topics[1]))), caller, "Event provider mismatch");
        assertEq(uint80(uint256(logs[i].topics[2])), DEFAULT_SALT, "Event salt mismatch");
        (int256[] memory binIdxsEmitted, BinBalanceDelta[] memory binDeltas, uint256[] memory sharesEmitted) =
          abi.decode(logs[i].data, (int256[], BinBalanceDelta[], uint256[]));
        assertEq(binIdxsEmitted.length, 1, "Event binIdxs length mismatch");
        assertEq(binIdxsEmitted[0], bin, "Event bin mismatch");
        assertEq(binDeltas.length, 1, "Event binDeltas length mismatch");
        assertEq(sharesEmitted.length, 1, "Event shares length mismatch");
        assertEq(sharesEmitted[0], shares, "Event shares mismatch");
        break;
      }
    }
    assertTrue(eventFound, "LiquidityAdded event not emitted");
  }

  /// @dev LiquidityRemoved event encodes negative scaled deltas and correct bin index
  function test_modifyLiquidity_remove_emitsLiquidityRemovedWithNegativeDeltas() public {
    address caller = _getCallerAddress(USER_INDEX);
    int8 bin = 4;
    uint104 shares = 10_000;

    _doAddLiquidity(USER_INDEX, DEFAULT_SALT, _createDeltaArray(bin, shares));

    vm.recordLogs();
    _doRemoveLiquidity(USER_INDEX, DEFAULT_SALT, _createDeltaArray(bin, 3000));

    Vm.Log[] memory logs = vm.getRecordedLogs();
    bytes32 topic0 = keccak256("LiquidityRemoved(address,uint80,int256[],(int256,int256)[],uint256[])");
    bool eventFound = false;
    for (uint256 i = 0; i < logs.length; i++) {
      if (logs[i].topics[0] == topic0) {
        eventFound = true;
        assertEq(address(uint160(uint256(logs[i].topics[1]))), caller, "Event provider mismatch");
        assertEq(uint80(uint256(logs[i].topics[2])), DEFAULT_SALT, "Event salt mismatch");
        (int256[] memory binIdxsEmitted, BinBalanceDelta[] memory binDeltas, uint256[] memory sharesEmitted) =
          abi.decode(logs[i].data, (int256[], BinBalanceDelta[], uint256[]));
        assertEq(binIdxsEmitted.length, 1, "Event binIdxs length mismatch");
        assertEq(binIdxsEmitted[0], bin, "Event bin mismatch");
        assertEq(binDeltas.length, 1, "Event binDeltas length mismatch");
        assertLt(binDeltas[0].delta0Scaled, 0, "Remove should emit negative token0 scaled delta");
        assertEq(binDeltas[0].delta1Scaled, 0, "Above-current bin has no token1 in bin balance");
        assertEq(sharesEmitted.length, 1, "Event shares length mismatch");
        assertEq(sharesEmitted[0], 3000, "Event shares mismatch");
        break;
      }
    }
    assertTrue(eventFound, "LiquidityRemoved event not emitted");
  }

  /// @dev Swap works correctly after adding liquidity via modifyLiquidity
  function test_modifyLiquidity_thenSwap() public {
    uint256 lpIndex = 0;
    uint256 swapperIndex = 1;
    address swapperCaller = _getCallerAddress(swapperIndex);

    int256[] memory bins = new int256[](5);
    bins[0] = -2;
    bins[1] = -1;
    bins[2] = 0;
    bins[3] = 1;
    bins[4] = 2;
    uint104[] memory sharesByBin = new uint104[](5);
    sharesByBin[0] = 50000;
    sharesByBin[1] = 50000;
    sharesByBin[2] = 50000;
    sharesByBin[3] = 50000;
    sharesByBin[4] = 50000;
    LiquidityDelta memory deltas = _createDeltas(bins, sharesByBin);

    _doAddLiquidity(lpIndex, DEFAULT_SALT, deltas);

    uint128 amountIn = 1000;
    address swapper = users[swapperIndex];
    uint256 token0Before = token0.balanceOf(swapper);
    uint256 token1Before = token1.balanceOf(swapperCaller); // Input from caller

    (int256 amount0Delta, int256 amount1Delta) =
      _swap(
        swapperIndex,
        swapper,
        false, // token1 -> token0
        _i128ExactIn(amountIn),
        type(uint128).max
      );

    assertLt(amount0Delta, 0, "Should receive token0");
    assertGt(amount1Delta, 0, "Should spend token1");

    assertGt(token0.balanceOf(swapper), token0Before, "Token0 balance should increase");
    assertLt(token1.balanceOf(swapperCaller), token1Before, "Token1 balance should decrease");
  }

  function _createRangeDeltas(int8 lowestBin, int8 highestBin, uint104 sharesPerBin)
    internal
    pure
    returns (LiquidityDelta memory)
  {
    return _rangeDeltas(lowestBin, highestBin, sharesPerBin);
  }

  /// @dev 5 users add/remove liquidity - rounding error should be at most 1 per bin
  function test_modifyLiquidity_multipleUsers_roundingError() public {
    int8[5] memory lowestBins = [int8(-3), int8(2), int8(-5), int8(0), int8(-5)];
    int8[5] memory highestBins = [int8(4), int8(4), int8(-2), int8(4), int8(3)];

    uint104[5] memory sharesAmounts = [uint104(50000), uint104(30000), uint104(70000), uint104(40000), uint104(60000)];

    uint256[5] memory initialToken0Balances;
    uint256[5] memory initialToken1Balances;

    for (uint256 i = 0; i < 5; i++) {
      initialToken0Balances[i] = token0.balanceOf(address(callers[i]));
      initialToken1Balances[i] = token1.balanceOf(address(callers[i]));
    }

    for (uint256 i = 0; i < 5; i++) {
      _doAddLiquidity(i, i.toUint72(), _createRangeDeltas(lowestBins[i], highestBins[i], sharesAmounts[i]));
    }

    uint256[5] memory withdrawOrder = [uint256(3), uint256(0), uint256(4), uint256(1), uint256(2)];

    for (uint256 i = 0; i < 5; i++) {
      uint256 userIndex = withdrawOrder[i];
      _doRemoveLiquidity(
        userIndex,
        userIndex.toUint72(),
        _createRangeDeltas(lowestBins[userIndex], highestBins[userIndex], sharesAmounts[userIndex])
      );
    }
  }

  // ============ modifyLiquidity callback payment tests ============

  /// @dev Deposit reverts when the callback pays less token0 than owed (InsufficientTokenBalance)
  function test_modifyLiquidity_deposit_revertsWhenCallbackUnderpaysToken0() public {
    int8 bin = 4;
    uint104 shares = 10000;

    UnderpayingModifyLiquidityCaller bad = new UnderpayingModifyLiquidityCaller();
    bad.setUnderpay(UnderpayingModifyLiquidityCaller.Underpay.Token0);
    token0.mint(address(bad), 1_000_000e18);
    token1.mint(address(bad), 1_000_000e18);

    vm.expectRevert(IMetricOmmPoolActions.InsufficientTokenBalance.selector);
    bad.addLiquidity(address(pool), DEFAULT_SALT + 1, _createDeltaArray(bin, shares));
  }

  /// @dev Deposit reverts when the callback pays less token1 than owed
  function test_modifyLiquidity_deposit_revertsWhenCallbackUnderpaysToken1() public {
    int8 bin = -5;
    uint104 shares = 10000;

    UnderpayingModifyLiquidityCaller bad = new UnderpayingModifyLiquidityCaller();
    bad.setUnderpay(UnderpayingModifyLiquidityCaller.Underpay.Token1);
    token0.mint(address(bad), 1_000_000e18);
    token1.mint(address(bad), 1_000_000e18);

    vm.expectRevert(IMetricOmmPoolActions.InsufficientTokenBalance.selector);
    bad.addLiquidity(address(pool), DEFAULT_SALT + 1, _createDeltaArray(bin, shares));
  }

  function test_modifyLiquidity_revertsWhenMintBelowMinimalLiquidity() public {
    int8 bin = 4;
    uint104 shares = 999;

    vm.expectRevert(
      abi.encodeWithSelector(
        IMetricOmmPoolActions.MinimalLiquidity.selector, uint256(uint104(shares)), uint256(MINIMAL_MINTABLE_LIQUIDITY)
      )
    );
    _callAddLiquidity(USER_INDEX, DEFAULT_SALT, _createDeltaArray(bin, shares));
  }

  function test_modifyLiquidity_revertsWhenWithdrawalLeavesDust() public {
    int8 bin = 4;
    _doAddLiquidity(USER_INDEX, DEFAULT_SALT, _createDeltaArray(bin, 1500));

    vm.expectRevert(
      abi.encodeWithSelector(
        IMetricOmmPoolActions.MinimalLiquidity.selector, uint256(800), uint256(MINIMAL_MINTABLE_LIQUIDITY)
      )
    );
    _callRemoveLiquidity(USER_INDEX, DEFAULT_SALT, _createDeltaArray(bin, 700));
  }

  function test_gateExtension_depositFailsWhenClosed() public {
    GateExtension extension = _deployPoolWithDepositGate();
    extension.setAllowDeposit(false);

    vm.expectRevert(IMetricOmmPoolActions.NotAllowedToDeposit.selector);
    _callAddLiquidity(USER_INDEX, DEFAULT_SALT, _createDeltaArray(4, 10_000));
  }

  function test_gateExtension_depositSucceedsWhenOpen() public {
    GateExtension extension = _deployPoolWithDepositGate();
    extension.setAllowDeposit(true);

    (uint256 amount0Added, uint256 amount1Added) =
      _doAddLiquidity(USER_INDEX, DEFAULT_SALT, _createDeltaArray(4, 10_000));
    assertGt(amount0Added, 0, "Should require token0 deposit");
    assertEq(amount1Added, 0, "Should not require token1 for bin above current");
  }

  function test_gateExtension_closedDepositGateStillAllowsWithdraw() public {
    GateExtension extension = _deployPoolWithDepositGate();
    int8 bin = 4;
    uint104 shares = 10_000;

    extension.setAllowDeposit(true);
    _doAddLiquidity(USER_INDEX, DEFAULT_SALT, _createDeltaArray(bin, shares));

    extension.setAllowDeposit(false);

    (uint256 amount0Removed, uint256 amount1Removed) =
      _doRemoveLiquidity(USER_INDEX, DEFAULT_SALT, _createDeltaArray(bin, shares));
    assertGt(amount0Removed, 0, "Withdraw should still return token0");
    assertEq(amount1Removed, 0, "Withdraw from bin above current should not affect token1");
  }

  /// @dev Default pool has no extensions; adds are open to any `owner`
  function test_addLiquidity_succeedsWhenExtensionsUnset() public {
    address extensionsAddr = IMetricOmmPool(address(pool)).getImmutables().extension1;
    assertEq(extensionsAddr, address(0), "Base fixture pool should omit extensions");

    (uint256 amount0Added, uint256 amount1Added) =
      _doAddLiquidity(USER_INDEX, DEFAULT_SALT, _createDeltaArray(4, 10_000));
    assertGt(amount0Added, 0, "Deposit should succeed without allowlist");
    assertEq(amount1Added, 0, "Bin above current uses token0 only");
  }
}
