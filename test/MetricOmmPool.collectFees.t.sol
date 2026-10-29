// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMetricOmmPoolCollectFees} from "../contracts/interfaces/IMetricOmmPool/IMetricOmmPoolCollectFees.sol";
import {MetricOmmPoolHarness} from "./MetricOmmPoolStateView.harness.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {PoolStateLibrary} from "../contracts/libraries/PoolStateLibrary.sol";
import {BinState} from "../contracts/types/PoolStorage.sol";
import {PoolExtensions, ExtensionOrders} from "../contracts/types/PoolExtensionsConfig.sol";

contract MetricOmmPoolCollectFeesTest is Test {
  MetricOmmPoolHarness internal pool;
  MockERC20 internal token0;
  MockERC20 internal token1;
  address internal adminDestination;
  address internal protocolDestination;

  function setUp() public {
    token0 = new MockERC20("Token0", "TK0", 6);
    token1 = new MockERC20("Token1", "TK1", 18);
    adminDestination = makeAddr("adminDestination");
    protocolDestination = makeAddr("protocolDestination");
    PoolExtensions memory extensions;
    ExtensionOrders memory orders;
    BinState[] memory bins = new BinState[](1);
    bins[0].lengthE6 = 100;
    pool = new MetricOmmPoolHarness(
      address(this),
      address(token0),
      address(token1),
      address(0),
      true,
      1e12,
      1,
      1e18,
      1e18,
      1e6,
      extensions,
      orders,
      0,
      0,
      bins,
      bins,
      0
    );
  }

  function test_pendingFees_collectWhenRatesAreZero() public {
    bytes32[] memory pending = new bytes32[](4);
    pending[0] = bytes32(uint256(50e12));
    pending[1] = bytes32(uint256(75));
    pending[2] = bytes32(uint256(100e12));
    pending[3] = bytes32(uint256(200));
    pool.extsstore(bytes32(uint256(7)), pending);
    token0.mint(address(pool), 150);
    token1.mint(address(pool), 275);

    pool.collectFees(0, 0, 0, 0, adminDestination, protocolDestination);
    pool.collectFees(0, 0, 0, 0, adminDestination, protocolDestination);

    assertEq(token0.balanceOf(adminDestination), 50);
    assertEq(token1.balanceOf(adminDestination), 75);
    assertEq(token0.balanceOf(protocolDestination), 100);
    assertEq(token1.balanceOf(protocolDestination), 200);
    _assertNoPendingFees();
  }

  function test_collectFees_splitsSeededSpreadAndNotionalFees() public {
    pool.setPoolFees(15_000, 2_000_000);
    pool.extsstore(bytes32(uint256(2)), bytes32(uint256(90e12) | (uint256(180) << 128)));
    token0.mint(address(pool), 150);
    token1.mint(address(pool), 300);

    pool.collectFees(10_000, 5_000, 1_000_000, 1_000_000, adminDestination, protocolDestination);

    assertEq(token0.balanceOf(adminDestination), 65);
    assertEq(token1.balanceOf(adminDestination), 130);
    assertEq(token0.balanceOf(protocolDestination), 85);
    assertEq(token1.balanceOf(protocolDestination), 170);
    assertEq(token0.balanceOf(address(pool)), 0);
    assertEq(token1.balanceOf(address(pool)), 0);
    (uint128 notional0, uint128 notional1) = PoolStateLibrary._slot2(address(pool));
    assertEq(notional0, 0);
    assertEq(notional1, 0);
    _assertNoPendingFees();
  }

  function test_collectFees_routesNotionalFeesToProtocolAndClearsAccrual() public {
    pool.setPoolFees(0, 1_000_000);
    pool.extsstore(bytes32(uint256(2)), bytes32(uint256(90e12) | (uint256(180) << 128)));
    token0.mint(address(pool), 90);
    token1.mint(address(pool), 180);

    pool.collectFees(0, 0, 1_000_000, 0, adminDestination, protocolDestination);

    assertEq(token0.balanceOf(protocolDestination), 90);
    assertEq(token1.balanceOf(protocolDestination), 180);
    assertEq(token0.balanceOf(adminDestination), 0);
    assertEq(token1.balanceOf(adminDestination), 0);
    assertEq(token0.balanceOf(address(this)), 0);
    assertEq(token1.balanceOf(address(this)), 0);
    (uint128 notional0, uint128 notional1) = PoolStateLibrary._slot2(address(pool));
    assertEq(notional0, 0);
    assertEq(notional1, 0);
    _assertNoPendingFees();
  }

  function test_collectFees_preservesNotionalSharesAcrossFailedPayouts() public {
    pool.setPoolFees(0, 1_500_000);
    pool.extsstore(bytes32(uint256(2)), bytes32(uint256(300e12) | (uint256(600) << 128)));
    token0.mint(address(pool), 300);
    token1.mint(address(pool), 600);

    uint256 accruedState = vm.snapshotState();
    for (uint8 failureMask = 0; failureMask < 16; ++failureMask) {
      assertTrue(vm.revertToState(accruedState));
      bool admin0Blocked = failureMask & 1 != 0;
      bool admin1Blocked = failureMask & 2 != 0;
      bool protocol0Blocked = failureMask & 4 != 0;
      bool protocol1Blocked = failureMask & 8 != 0;
      if (admin0Blocked) {
        vm.mockCallRevert(
          address(token0), abi.encodeWithSelector(IERC20.transfer.selector, adminDestination), "blocked"
        );
      }
      if (admin1Blocked) {
        vm.mockCallRevert(
          address(token1), abi.encodeWithSelector(IERC20.transfer.selector, adminDestination), "blocked"
        );
      }
      if (protocol0Blocked) {
        vm.mockCallRevert(
          address(token0), abi.encodeWithSelector(IERC20.transfer.selector, protocolDestination), "blocked"
        );
      }
      if (protocol1Blocked) {
        vm.mockCallRevert(
          address(token1), abi.encodeWithSelector(IERC20.transfer.selector, protocolDestination), "blocked"
        );
      }

      vm.expectEmit(false, false, false, true, address(pool));
      emit IMetricOmmPoolCollectFees.ProtocolFeesCollected(
        protocol0Blocked ? 0 : 200, protocol1Blocked ? 0 : 400, admin0Blocked ? 0 : 100, admin1Blocked ? 0 : 200
      );
      pool.collectFees(0, 0, 1_000_000, 500_000, adminDestination, protocolDestination);
      (uint128 unallocated0, uint128 unallocated1) = PoolStateLibrary._slot2(address(pool));
      assertEq(unallocated0, 0);
      assertEq(unallocated1, 0);
      (uint256 pendingAdmin0, uint256 pendingAdmin1, uint256 pendingProtocol0, uint256 pendingProtocol1) =
        PoolStateLibrary._pendingFeesScaled(address(pool));
      assertEq(pendingAdmin0, admin0Blocked ? 100e12 : 0);
      assertEq(pendingAdmin1, admin1Blocked ? 200 : 0);
      assertEq(pendingProtocol0, protocol0Blocked ? 200e12 : 0);
      assertEq(pendingProtocol1, protocol1Blocked ? 400 : 0);
      assertEq(token0.balanceOf(adminDestination), admin0Blocked ? 0 : 100);
      assertEq(token1.balanceOf(adminDestination), admin1Blocked ? 0 : 200);
      assertEq(token0.balanceOf(protocolDestination), protocol0Blocked ? 0 : 200);
      assertEq(token1.balanceOf(protocolDestination), protocol1Blocked ? 0 : 400);

      pool.collectFees(0, 0, 1_000_000, 500_000, adminDestination, protocolDestination);
      pool.setPoolFees(0, 0);
      vm.clearMockedCalls();
      pool.collectFees(0, 0, 0, 0, adminDestination, protocolDestination);
      pool.collectFees(0, 0, 0, 0, adminDestination, protocolDestination);
      assertEq(token0.balanceOf(adminDestination), 100);
      assertEq(token1.balanceOf(adminDestination), 200);
      assertEq(token0.balanceOf(protocolDestination), 200);
      assertEq(token1.balanceOf(protocolDestination), 400);
      _assertNoPendingFees();
    }
    vm.deleteStateSnapshot(accruedState);
  }

  function _assertNoPendingFees() private view {
    (uint256 admin0, uint256 admin1, uint256 protocol0, uint256 protocol1) =
      PoolStateLibrary._pendingFeesScaled(address(pool));
    assertEq(admin0, 0);
    assertEq(admin1, 0);
    assertEq(protocol0, 0);
    assertEq(protocol1, 0);
  }
}
