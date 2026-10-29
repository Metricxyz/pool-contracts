// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {FactoryFeeCapsStub} from "./FactoryFeeCapsStub.sol";
import {PoolInitPreprocessor} from "./PoolInitPreprocessor.sol";
import {MetricOmmPool} from "../contracts/MetricOmmPool.sol";
import {MetricOmmPoolDeployer} from "../contracts/MetricOmmPoolDeployer.sol";
import {PoolExtensions, ExtensionOrders} from "../contracts/types/PoolExtensionsConfig.sol";
import {ExtensionOrderTestLib} from "./ExtensionOrderTestLib.sol";
import {PoolStateTestLib} from "./PoolStateTestLib.sol";
import {BinState} from "../contracts/types/PoolStorage.sol";
import {LiquidityDelta} from "../contracts/types/PoolOperation.sol";
import {IMetricOmmPoolActions} from "../contracts/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {IMetricOmmPoolFactory} from "../contracts/interfaces/IMetricOmmPoolFactory/IMetricOmmPoolFactory.sol";
import {PoolFeeConfig} from "../contracts/types/FactoryStorage.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPriceProvider} from "../contracts/interfaces/IPriceProvider/IPriceProvider.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {TestCaller} from "./mocks/TestCaller.sol";

uint256 constant Q64 = 2 ** 64;

/// @notice Mock Price Provider for testing
contract MockPriceProvider is IPriceProvider {
  uint128 public bidPrice;
  uint128 public askPrice;
  address public baseToken;
  address public quoteToken;

  function setBidPrice(uint128 _bidPrice) external {
    bidPrice = _bidPrice;
  }

  function setAskPrice(uint128 _askPrice) external {
    askPrice = _askPrice;
  }

  function setBidAndAskPrice(uint128 _bidPrice, uint128 _askPrice) external {
    bidPrice = _bidPrice;
    askPrice = _askPrice;
  }

  function setTokens(address _baseToken, address _quoteToken) external {
    baseToken = _baseToken;
    quoteToken = _quoteToken;
  }

  function getBidAndAskPrice() external view returns (uint128, uint128) {
    return (bidPrice, askPrice);
  }

  function token0() external view returns (address) {
    return baseToken;
  }

  function token1() external view returns (address) {
    return quoteToken;
  }
}

/// @title Base test contract for MetricOmmPool tests
/// @notice Provides shared setup for all MetricOmmPool tests
abstract contract MetricOmmPoolBaseTest is Test, FactoryFeeCapsStub, PoolInitPreprocessor {
  using SafeCast for int256;
  using SafeCast for uint256;

  MetricOmmPool public pool;

  MockPriceProvider public oracle;
  MockERC20 public token0;
  MockERC20 public token1;

  address public factory;
  address public admin;
  address public adminFeeDestination;

  MetricOmmPoolDeployer internal poolDeployer;
  uint256 internal poolDeploySaltNonce;

  // Default constructor parameters
  uint104 constant INITIAL_SCALED_AMOUNT_0_PER_SHARE_E18 = 1e18;
  uint104 constant INITIAL_SCALED_AMOUNT_1_PER_SHARE_E18 = 1e18;
  uint104 constant MINIMAL_MINTABLE_LIQUIDITY = 1000;
  int32 constant TICK_DISTANCE_MULTIPLIER = 1e6; // 1% per tick (1e6 = 1% in 1e8 units)
  uint24 constant PROTOCOL_FEE = 1e4; // 1%
  uint24 constant ADMIN_FEE = 5e3; // 0.5%

  // Test users (EOA addresses for tracking balances)
  address[] public users;
  // Test callers (contracts that implement callbacks, one per user)
  TestCaller[] public callers;

  struct PoolDeployParams {
    address priceProvider;
    PoolExtensions extensions;
    ExtensionOrders extensionOrders;
    bool immutablePriceProvider;
    uint24 protocolSpreadFeeE6;
    uint24 adminSpreadFeeE6;
    int24 curBinDistFromProvidedPriceE6;
    BinState[] nonNegativeBinStates;
    BinState[] negativeBinStates;
    uint24 protocolNotionalFeeE8;
    uint24 adminNotionalFeeE8;
    address immutablePriceProviderForRegistry;
    int8 lowestBin;
    int8 highestBin;
  }

  function setUp() public virtual {
    factory = address(this);
    admin = address(this);
    adminFeeDestination = makeAddr("adminFeeDestination");
    poolDeployer = new MetricOmmPoolDeployer(factory);

    // Reset arrays in case setUp is called multiple times (e.g., in loop tests)
    delete users;
    delete callers;

    // Deploy mock ERC20 tokens
    token0 = new MockERC20("Token0", "TK0", 18);
    token1 = new MockERC20("Token1", "TK1", 18);

    // Deploy mock oracle
    oracle = new MockPriceProvider();
    // Set default price at 1:1 in Q64 format
    oracle.setBidAndAskPrice(SafeCast.toUint128(Q64), SafeCast.toUint128(Q64 + 1));

    // Create bin state arrays and deploy default test pool.
    (BinState[] memory nonNegativeBinStates, BinState[] memory negativeBinStates) = _defaultBinStateArrays();
    pool = _deployPoolAndRegister(
      PoolDeployParams({
        priceProvider: address(oracle),
        extensions: _emptyExtensions(),
        extensionOrders: _emptyExtensionOrders(),
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

    // Deploy StateView for reading pool state

    // Setup test users with their caller contracts
    for (uint256 i = 0; i < 5; i++) {
      address user = makeAddr(string(abi.encodePacked("user", vm.toString(i))));
      users.push(user);
      TestCaller caller = new TestCaller(user, factory);
      callers.push(caller);
      _setupUser(user, caller, address(pool));
    }
  }

  /// @notice Get the caller contract for a user index
  function _getCaller(uint256 userIndex) internal view returns (TestCaller) {
    return callers[userIndex];
  }

  /// @notice Get caller address for a user (for position lookups)
  function _getCallerAddress(uint256 userIndex) internal view returns (address) {
    return address(callers[userIndex]);
  }

  /// @notice Create bin data array with constant length of 1 per bin
  /// BinData format: 24 bits lengthE6 | 16 bits buyFee | 16 bits sellFee = 56 bits (aligned to 64 bits)
  /// Each bin has length = 1 distance unit, with zero fees
  function _singleBinDataArrayWithLength(uint16 lengthE6) internal pure returns (uint256[] memory binDataArray) {
    binDataArray = new uint256[](1);
    uint256 packed = 0;
    for (uint256 j = 0; j < 5; j++) {
      uint16 buyFee = 0;
      uint16 sellFee = 0;
      uint48 binData = uint48(lengthE6) | (uint48(buyFee) << 16) | (uint48(sellFee) << 32);
      packed |= uint256(binData) << (j * 48);
    }
    binDataArray[0] = packed;
  }

  function _createBinDataArray() internal pure returns (uint256[] memory binDataArray) {
    return _singleBinDataArrayWithLength(100);
  }

  function _defaultBinStateArrays()
    internal
    pure
    returns (BinState[] memory nonNegativeBinStates, BinState[] memory negativeBinStates)
  {
    uint256[] memory nonNegativeBinData = _createBinDataArray();
    uint256[] memory negativeBinData = _createBinDataArray();
    return _unpackBinStates(nonNegativeBinData, negativeBinData);
  }

  /// @notice Setup a user with tokens and approvals
  /// @dev Mints tokens to the caller contract and approves the pool
  function _setupUser(address user, TestCaller caller, address poolAddr) internal {
    // Mint tokens to the caller contract (not the user EOA)
    token0.mint(address(caller), 1000000e18);
    token1.mint(address(caller), 1000000e18);

    // Also mint to user EOA for balance tracking in tests
    token0.mint(user, 1000000e18);
    token1.mint(user, 1000000e18);

    // Approve pool from caller
    vm.startPrank(address(caller));
    token0.approve(poolAddr, type(uint256).max);
    token1.approve(poolAddr, type(uint256).max);
    vm.stopPrank();

    // Approve pool from user EOA as well (for direct tests)
    vm.startPrank(user);
    token0.approve(poolAddr, type(uint256).max);
    token1.approve(poolAddr, type(uint256).max);
    vm.stopPrank();
  }

  function _approveUsersForPool(address poolAddr) internal {
    for (uint256 i = 0; i < users.length; i++) {
      vm.startPrank(address(callers[i]));
      token0.approve(poolAddr, type(uint256).max);
      token1.approve(poolAddr, type(uint256).max);
      vm.stopPrank();
      vm.startPrank(users[i]);
      token0.approve(poolAddr, type(uint256).max);
      token1.approve(poolAddr, type(uint256).max);
      vm.stopPrank();
    }
  }

  function _deployPoolAndRegister(PoolDeployParams memory params) internal returns (MetricOmmPool deployedPool) {
    (uint256 token0ScaleMultiplier, uint256 token1ScaleMultiplier) =
      _getScaleMultipliers(address(token0), address(token1));
    deployedPool = _deployPool(params, token0ScaleMultiplier, token1ScaleMultiplier);
    _registerDeployedPool(deployedPool, params);
  }

  function _deployPool(PoolDeployParams memory params, uint256 token0ScaleMultiplier, uint256 token1ScaleMultiplier)
    private
    returns (MetricOmmPool deployedPool)
  {
    if (address(poolDeployer) == address(0)) {
      poolDeployer = new MetricOmmPoolDeployer(factory);
    }

    deployedPool = MetricOmmPool(
      poolDeployer.deploy(
        MetricOmmPoolDeployer.DeployParams({
          salt: keccak256(abi.encodePacked("MetricOmmPoolBaseTest", poolDeploySaltNonce++)),
          factory: factory,
          admin: admin,
          adminFeeDestination: adminFeeDestination,
          token0: address(token0),
          token1: address(token1),
          priceProvider: params.priceProvider,
          extensions: params.extensions,
          extensionOrders: params.extensionOrders,
          immutablePriceProvider: params.immutablePriceProvider,
          token0ScaleMultiplier: token0ScaleMultiplier,
          token1ScaleMultiplier: token1ScaleMultiplier,
          initialScaledAmount0PerShareE18: INITIAL_SCALED_AMOUNT_0_PER_SHARE_E18,
          initialScaledAmount1PerShareE18: INITIAL_SCALED_AMOUNT_1_PER_SHARE_E18,
          minimalMintableLiquidity: MINIMAL_MINTABLE_LIQUIDITY,
          spreadFeeE6: params.protocolSpreadFeeE6 + params.adminSpreadFeeE6,
          curBinDistFromProvidedPriceE6: params.curBinDistFromProvidedPriceE6,
          nonNegativeBinStates: params.nonNegativeBinStates,
          negativeBinStates: params.negativeBinStates,
          notionalFeeE8: params.protocolNotionalFeeE8 + params.adminNotionalFeeE8
        })
      )
    );
  }

  function _registerDeployedPool(MetricOmmPool deployedPool, PoolDeployParams memory params) private {
    priceProviderTimelock[address(deployedPool)] = type(uint256).max;
    poolAdmin[address(deployedPool)] = admin;
    poolFeeConfig[address(deployedPool)] = PoolFeeConfig({
      protocolSpreadFeeE6: params.protocolSpreadFeeE6,
      adminSpreadFeeE6: params.adminSpreadFeeE6,
      protocolNotionalFeeE8: params.protocolNotionalFeeE8,
      adminNotionalFeeE8: params.adminNotionalFeeE8
    });
    poolAdminFeeDestination[address(deployedPool)] = adminFeeDestination;
  }

  function _rangeDeltas(int8 lowerBin, int8 upperBin, uint256 sharesPerBin)
    internal
    pure
    returns (LiquidityDelta memory deltas)
  {
    int256 span = int256(upperBin) - int256(lowerBin) + 1;
    uint256 numBins = SafeCast.toUint256(span);
    int256[] memory binIdxs = new int256[](numBins);
    uint256[] memory shares = new uint256[](numBins);
    for (uint256 i = 0; i < numBins; i++) {
      binIdxs[i] = int256(lowerBin) + SafeCast.toInt256(i);
      shares[i] = sharesPerBin;
    }
    return LiquidityDelta({binIdxs: binIdxs, shares: shares});
  }

  /// @notice Helper to add liquidity via caller contract
  /// @dev Creates batched LiquidityDelta payload for each bin in range
  function _addLiquidity(uint256 userIndex, int8 tickLower, int8 tickUpper, uint104 shares, uint80 salt)
    internal
    returns (uint256 amount0Added, uint256 amount1Added)
  {
    LiquidityDelta memory deltas = _rangeDeltas(tickLower, tickUpper, shares);
    vm.prank(users[userIndex]);
    return callers[userIndex].addLiquidity(address(pool), salt, deltas);
  }

  /// @notice Helper to remove liquidity using removeLiquidity via caller contract
  /// @dev Creates batched LiquidityDelta payload with shares to remove for each bin in range
  function _removeLiquidity(uint256 userIndex, int8 tickLower, int8 tickUpper, uint104 shares, uint80 salt)
    internal
    returns (uint256 amount0Removed, uint256 amount1Removed)
  {
    LiquidityDelta memory deltas = _rangeDeltas(tickLower, tickUpper, shares);
    vm.prank(users[userIndex]);
    return callers[userIndex].removeLiquidity(address(pool), salt, deltas);
  }

  function _swapOnPool(
    address poolAddr,
    uint256 userIndex,
    address recipient,
    bool zeroForOne,
    int128 amountSpecified,
    uint128 priceLimitX64
  ) internal returns (int256 amount0Delta, int256 amount1Delta) {
    vm.prank(users[userIndex]);
    return callers[userIndex].swap(poolAddr, recipient, zeroForOne, amountSpecified, priceLimitX64);
  }

  /// @notice Helper to swap via caller contract
  function _swap(uint256 userIndex, address recipient, bool zeroForOne, int128 amountSpecified, uint128 priceLimitX64)
    internal
    returns (int256 amount0Delta, int256 amount1Delta)
  {
    return _swapOnPool(address(pool), userIndex, recipient, zeroForOne, amountSpecified, priceLimitX64);
  }

  function _i256FromBalance(uint256 x) internal pure returns (int256) {
    return SafeCast.toInt256(x);
  }

  function _i128ExactIn(uint128 x) internal pure returns (int128) {
    return SafeCast.toInt128(SafeCast.toInt256(uint256(x)));
  }

  function _i128ExactOut(uint128 x) internal pure returns (int128) {
    int128 mag = SafeCast.toInt128(SafeCast.toInt256(uint256(x)));
    unchecked {
      return -mag;
    }
  }

  function _u128FromNonNegDelta(int256 x) internal pure returns (uint128) {
    return SafeCast.toUint128(SafeCast.toUint256(x));
  }

  function _u128FromNegDelta(int256 x) internal pure returns (uint128) {
    return SafeCast.toUint128(SafeCast.toUint256(-x));
  }

  function _q64Uint128() internal pure returns (uint128) {
    return SafeCast.toUint128(Q64);
  }

  function _poolAddr() internal view returns (address) {
    return address(pool);
  }

  // ============ Pool state read helpers (PoolStateTestLib) ============

  function _emptyExtensions() internal pure returns (PoolExtensions memory extensions) {}

  function _singleExtensionPoolExtensions(address extension) internal pure returns (PoolExtensions memory extensions) {
    extensions.extension1 = extension;
  }

  function _emptyExtensionOrders() internal pure returns (ExtensionOrders memory orders) {}

  function _extensionOrdersWithBeforeSwap() internal pure returns (ExtensionOrders memory orders) {
    orders.beforeSwap = ExtensionOrderTestLib.encodeExtensionOrder(1, 0, 0, 0, 0, 0, 0);
  }

  function _extensionOrdersWithAfterSwap() internal pure returns (ExtensionOrders memory orders) {
    orders.afterSwap = ExtensionOrderTestLib.encodeExtensionOrder(1, 0, 0, 0, 0, 0, 0);
  }

  function _extensionOrdersWithBeforeAndAfterSwap() internal pure returns (ExtensionOrders memory orders) {
    orders.beforeSwap = ExtensionOrderTestLib.encodeExtensionOrder(1, 0, 0, 0, 0, 0, 0);
    orders.afterSwap = ExtensionOrderTestLib.encodeExtensionOrder(1, 0, 0, 0, 0, 0, 0);
  }

  function _extensionOrdersWithBeforeAddLiquidity() internal pure returns (ExtensionOrders memory orders) {
    orders.beforeAddLiquidity = ExtensionOrderTestLib.encodeExtensionOrder(1, 0, 0, 0, 0, 0, 0);
  }

  function _emptyExtensionArrays()
    internal
    pure
    returns (address[] memory extensions, bytes[] memory extensionInitData)
  {
    extensions = new address[](0);
    extensionInitData = new bytes[](0);
  }

  function _singleExtensionArrays(address extension)
    internal
    pure
    returns (address[] memory extensions, bytes[] memory extensionInitData)
  {
    extensions = new address[](1);
    extensions[0] = extension;
    extensionInitData = new bytes[](1);
  }

  /// @notice Get bin total shares via StateView
  function _getBinTotalShares(int8 binIdx) internal view returns (uint104) {
    return PoolStateTestLib.binTotalShares(address(pool), binIdx);
  }

  /// @notice Get position bin shares via StateView
  function _getPositionBinShares(address owner, uint80 salt, int8 bin) internal view returns (uint104) {
    return PoolStateTestLib.positionBinShares(address(pool), owner, salt, bin);
  }

  /// @notice Get bin state via StateView
  function _getBinState(int8 binIdx)
    internal
    view
    returns (uint104 token0Balance, uint104 token1Balance, uint24 lengthE6, uint16 addFeeBuyE6, uint16 addFeeSellE6)
  {
    return PoolStateTestLib.binState(address(pool), binIdx);
  }

  /// @notice Get current bin index via StateView
  function _getCurBinIdx() internal view returns (int8) {
    return PoolStateTestLib.curBinIdx(address(pool));
  }

  /// @notice Get current position in bin via StateView
  function _getCurPosInBin() internal view returns (uint104) {
    return PoolStateTestLib.curPosInBin(address(pool));
  }

  /// @notice Get bin total shares for multiple bins in batch
  function _getMultipleBinTotalShares(int8[] memory binIdxs) internal view returns (bytes32[] memory) {
    return PoolStateTestLib.multipleBinTotalShares(address(pool), binIdxs);
  }

  /// @notice Get position bin shares for multiple bins in batch
  function _getMultiplePositionBinShares(address owner, uint80 salt, int8[] memory binIdxs)
    internal
    view
    returns (bytes32[] memory)
  {
    return PoolStateTestLib.multiplePositionBinShares(address(pool), owner, salt, binIdxs);
  }

  /// @notice Decode bin total shares from raw bytes32
  function _decodeBinTotalShares(bytes32 data) internal pure returns (uint256) {
    return PoolStateTestLib.decodeBinTotalShares(data);
  }

  /// @notice Decode position bin shares from raw bytes32
  function _decodePositionBinShares(bytes32 data) internal pure returns (uint256) {
    return PoolStateTestLib.decodePositionBinShares(data);
  }
}
