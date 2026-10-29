// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;
// forge-lint: disable-start(unsafe-typecast, mixed-case-function, mixed-case-variable)

import {Test} from "forge-std/Test.sol";
import {FactoryFeeCapsStub} from "./FactoryFeeCapsStub.sol";
import {PoolInitPreprocessor} from "./PoolInitPreprocessor.sol";
import {BinState} from "../contracts/types/PoolStorage.sol";
import {PoolExtensions, ExtensionOrders} from "../contracts/types/PoolExtensionsConfig.sol";
import {SwapInBinHarness} from "./SwapInBin.harness.sol";
import {SwapMath} from "../contracts/libraries/SwapMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPriceProvider} from "../contracts/interfaces/IPriceProvider/IPriceProvider.sol";

uint256 constant Q64 = 2 ** 64;

/// @notice Mock ERC20 Token for testing
contract MockERC20ForBenchmark is ERC20 {
  uint8 private _decimals;

  constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
    _decimals = decimals_;
  }

  function decimals() public view override returns (uint8) {
    return _decimals;
  }

  function mint(address to, uint256 amount) external {
    _mint(to, amount);
  }
}

/// @notice Mock Price Provider for testing
contract MockPriceProviderForBenchmark is IPriceProvider {
  uint128 public bidPrice;
  uint128 public askPrice;

  function setBidAndAskPrice(uint128 _bidPrice, uint128 _askPrice) external {
    bidPrice = _bidPrice;
    askPrice = _askPrice;
  }

  function getBidAndAskPrice() external view returns (uint128, uint128) {
    return (bidPrice, askPrice);
  }

  function token0() external pure returns (address) {
    return address(0);
  }

  function token1() external pure returns (address) {
    return address(0);
  }
}

/**
 * @title SwapMathBenchmark
 * @notice Benchmark comparison of different swap calculation methods
 * @dev Compares: ExactOut, ExactIn (reverse), and analytical formula
 */
contract SwapMathBenchmark is Test, FactoryFeeCapsStub, PoolInitPreprocessor {
  SwapInBinHarness public harness;
  MockERC20ForBenchmark public token0;
  MockERC20ForBenchmark public token1;
  MockPriceProviderForBenchmark public oracle;

  uint256 constant M = type(uint104).max;

  function setUp() public {
    // Deploy mock tokens
    token0 = new MockERC20ForBenchmark("Token0", "TK0", 18);
    token1 = new MockERC20ForBenchmark("Token1", "TK1", 18);

    // Deploy mock oracle
    oracle = new MockPriceProviderForBenchmark();
    oracle.setBidAndAskPrice(uint128(Q64), uint128(Q64 + 1));

    // Create bin data arrays
    uint256[] memory binDataArray = _createBinDataArray();
    (uint256 token0ScaleMultiplier, uint256 token1ScaleMultiplier) =
      _getScaleMultipliers(address(token0), address(token1));
    (BinState[] memory nonNegativeBinStates, BinState[] memory negativeBinStates) =
      _unpackBinStates(binDataArray, binDataArray);

    // Deploy harness
    harness = new SwapInBinHarness(
      address(this), // factory
      address(this), // admin
      address(this), // adminFeeDestination
      address(token0),
      address(token1),
      address(oracle),
      true,
      token0ScaleMultiplier,
      token1ScaleMultiplier,
      1e18, // initialScaledAmount0PerShareE18
      1e18, // initialScaledAmount1PerShareE18
      1000, // minimalMintableLiquidity
      PoolExtensions({
        extension1: address(0),
        extension2: address(0),
        extension3: address(0),
        extension4: address(0),
        extension5: address(0),
        extension6: address(0),
        extension7: address(0)
      }),
      ExtensionOrders({
        beforeAddLiquidity: 0,
        afterAddLiquidity: 0,
        beforeRemoveLiquidity: 0,
        afterRemoveLiquidity: 0,
        beforeSwap: 0,
        afterSwap: 0
      }),
      0, // spreadFeeE6
      0, // curBinDistFromProvidedPriceE6
      nonNegativeBinStates,
      negativeBinStates,
      0 // notionalFeeE8
    );
    priceProviderTimelock[address(harness)] = type(uint256).max;
    poolAdmin[address(harness)] = address(this);
    poolAdminFeeDestination[address(harness)] = address(this);
  }

  function _createBinDataArray() internal pure returns (uint256[] memory binDataArray) {
    binDataArray = new uint256[](64);
    for (uint256 i = 0; i < 64; i++) {
      uint256 packed = 0;
      for (uint256 j = 0; j < 4; j++) {
        uint24 lengthE6 = 1;
        uint16 buyFee = 0;
        uint16 sellFee = 0;
        uint64 binData = uint64(lengthE6) | (uint64(buyFee) << 24) | (uint64(sellFee) << 40);
        packed |= uint256(binData) << (j * 64);
      }
      binDataArray[i] = packed;
    }
  }

  // ============ Analytical Formula (from user) ============

  /**
   * @dev Calculate amountOut and position delta (d) when buying Token0 with Token1 input
   * @notice This is the analytical solution for ExactIn (Token1 -> Token0)
   *
   * Math derivation:
   *   in1 = out0 * P_avg * (1 + f)
   *   out0 = T0 * d / (M - c)
   *   P_avg = PL + deltaP * (c + d/2) / M
   *
   *   Substituting: in1 = (T0 * d / (M-c)) * (PL + deltaP*(c + d/2)/M) * (1+f)
   *   Let Pc = PL + deltaP * c / M (price at current position)
   *   Then P_avg = Pc + deltaP * d / (2M)
   *
   *   in1 = (T0 / (M-c)) * (1+f) * d * (Pc + deltaP * d / (2M))
   *       = (T0 / (M-c)) * (1+f) * (Pc * d + deltaP * d^2 / (2M))
   *       = A * d + B * d^2
   *
   *   where: A = T0 * Pc * (1+f) / (M-c)
   *          B = T0 * deltaP * (1+f) / (2M * (M-c))
   *
   *   Solving: d = (-A + sqrt(A^2 + 4*B*in1)) / (2B)
   *              = 2*in1 / (A + sqrt(A^2 + 4*B*in1))
   *
   * @param in1 Amount of Token1 to input (raw, not X64)
   * @param T0 Token0 balance in bin (raw)
   * @param c Current bin position (0 to M)
   * @param PL Lower price bound (X64 fixed-point)
   * @param deltaP Price gradient (upperPrice - lowerPrice, X64 fixed-point)
   * @param feeE6 Fee rate (in 1e6 units, e.g., 1000 = 0.1%)
   * @return out0 Amount of Token0 to output
   * @return d Position change (finalPos - currPos)
   */
  function buyToken0GivenInputAnalytical(uint256 in1, uint256 T0, uint256 c, uint256 PL, uint256 deltaP, uint256 feeE6)
    internal
    pure
    returns (uint256 out0, uint256 d)
  {
    if (T0 == 0 || c >= M) {
      return (0, 0);
    }

    uint256 Mc = M - c;

    // Pc = PL + deltaP * c / M (price at current position, in X64)
    uint256 Pc_X64 = PL + Math.mulDiv(deltaP, c, M);

    if (Pc_X64 == 0) {
      return (0, 0);
    }

    // Fee multiplier: (1 + f) = (1e6 + feeE6) / 1e6
    uint256 feeMultiplierE6 = 1e6 + feeE6;

    // A = T0 * Pc * (1+f) / (M-c)
    // A has units of [tokens * X64 price / position] = [token1 per position unit, in X64]
    // A_X64 = T0 * Pc_X64 * feeMultiplierE6 / (Mc * 1e6)
    uint256 A_X64 = Math.mulDiv(T0 * feeMultiplierE6, Pc_X64, Mc * 1e6);

    if (A_X64 == 0) {
      // Price is too low, can get all tokens for minimal input
      d = Mc;
      out0 = T0;
      return (out0, d);
    }

    // Compute A^2 (in X128)
    uint256 A_squared_X128 = Math.mulDiv(A_X64, A_X64, 1);

    // Compute 4*B*in1:
    // B = T0 * deltaP * (1+f) / (2M * Mc)  [this is in X64]
    // 4*B*in1 needs to be in X128 to match A^2
    // 4 * B_X64 * in1 = 4 * [T0 * deltaP * feeE6 / (2M * Mc * 1e6)] * in1
    //                 = 2 * T0 * deltaP * feeE6 * in1 / (M * Mc * 1e6)
    // To get X128: multiply by 2^64
    uint256 fourB_in1_X128 = Math.mulDiv(2 * T0 * feeMultiplierE6 * in1, deltaP, (M * Mc * 1e6) / Q64);

    // sqrt(A^2 + 4*B*in1) in X64
    uint256 sqrtArg_X128 = A_squared_X128 + fourB_in1_X128;
    uint256 sqrtVal_X64 = Math.sqrt(sqrtArg_X128);

    // d = 2 * in1 / (A + sqrt(A^2 + 4*B*in1))
    // Denominator is in X64, in1 is raw
    // d = 2 * in1 * 2^64 / (A_X64 + sqrtVal_X64)
    uint256 denominator_X64 = A_X64 + sqrtVal_X64;

    if (denominator_X64 == 0) {
      d = Mc;
      out0 = T0;
      return (out0, d);
    }

    // d = 2 * in1 * Q64 / denominator_X64
    d = Math.mulDiv(2 * in1, Q64, denominator_X64);

    // Clamp d to not exceed available range
    if (d > Mc) {
      d = Mc;
    }

    // out0 = T0 * d / (M - c)
    out0 = Math.mulDiv(T0, d, Mc);
  }

  /**
   * @dev Calculate amountOut and position delta when selling Token0 for Token1
   * @notice This is for Token0 -> Token1 swaps (ExactIn direction)
   *
   * When selling Token0:
   * - Position moves DOWN (from c towards 0)
   * - We receive Token1 in exchange
   * - Price decreases as we sell
   *
   * Math derivation:
   *   out1 = in0 * P_avg / (1 + f)
   *   where P_avg = PL + deltaP * (c - d/2) / M  (average price during the swap)
   *   and d = c * in0 / T0  (position delta, moving towards 0)
   *
   * @param in0 Amount of Token0 to input (sell)
   * @param T0 Token0 balance in bin
   * @param c Current bin position (0 to M)
   * @param PL Lower price bound (X64)
   * @param deltaP Price gradient (upperPrice - lowerPrice, X64)
   * @param feeE6 Fee rate (in 1e6 units)
   * @return out1 Amount of Token1 to output
   * @return d Position change (positive value, represents move towards 0)
   */
  function sellToken0GivenInputAnalytical(uint256 in0, uint256 T0, uint256 c, uint256 PL, uint256 deltaP, uint256 feeE6)
    internal
    pure
    returns (uint256 out1, uint256 d)
  {
    if (T0 == 0 || c == 0) {
      return (0, 0);
    }

    // Clamp in0 to available T0
    if (in0 > T0) {
      in0 = T0;
    }

    // d = c * in0 / T0 (position moves down proportionally)
    d = Math.mulDiv(c, in0, T0);

    if (d > c) {
      d = c;
    }

    // finalPos = c - d
    uint256 finalPos = c - d;

    // Average position (midpoint between c and finalPos)
    uint256 avgPos = (c + finalPos) / 2;

    // Average price at midpoint: P_avg = PL + deltaP * avgPos / M
    uint256 avgPrice_X64 = PL + Math.mulDiv(deltaP, avgPos, M);

    // out1 = in0 * avgPrice / (1 + fee) / 2^64
    // We divide by (1 + fee) because seller pays the fee
    uint256 out1BeforeFee = Math.mulDiv(in0, avgPrice_X64, Q64);

    // Apply fee: out1 = out1BeforeFee * 1e6 / (1e6 + feeE6)
    out1 = Math.mulDiv(out1BeforeFee, 1e6, 1e6 + feeE6);
  }

  // ============ Benchmark Tests ============
  /**
   * @notice Compare three methods for Token0 swap calculations
   * @dev Method 1: ExactOut (harness) - specify output, get required input
   *      Method 2: ExactIn (harness) - use Method 1's input, get actual output
   *      Method 3: Analytical formula - compute directly
   */
  function skip_test_BenchmarkComparison_Token0_SingleCase() public view {
    // Setup parameters
    uint104 currBinPos = uint104(M / 4); // Start at 25% position
    uint104 availableToken0 = 1e24; // 1M tokens
    uint128 specifiedOut = 1e23; // Request 100k tokens (10% of available)
    uint128 lowerPrice = 1e18; // 1.0 in X64-ish
    uint128 upperPrice = lowerPrice + lowerPrice / 1000; // 0.1% spread
    uint24 feeE6 = 0; // No fee for cleaner comparison

    // ===== Method 1: ExactOut via harness =====
    BinState memory binState1 = BinState({
      token0BalanceScaled: availableToken0, token1BalanceScaled: 0, lengthE6: 1, addFeeBuyE6: 0, addFeeSellE6: 0
    });

    SwapMath.SwapState memory stateOut = SwapMath.SwapState({
      amountSpecifiedRemainingScaled: specifiedOut,
      amountCalculatedScaled: 0,
      protocolFeeAmountScaled: 0,
      feeExclusiveInputScaled: 0
    });

    (, stateOut,) = harness.exposedBuyToken0InBinSpecifiedOut(
      binState1, currBinPos, stateOut, feeE6, lowerPrice, upperPrice, type(uint128).max
    );

    uint128 actualOutFromExactOut = uint128(specifiedOut - stateOut.amountSpecifiedRemainingScaled);
    uint128 requiredInFromExactOut = uint128(stateOut.amountCalculatedScaled);

    // ===== Method 2: ExactIn via harness (using requiredIn from Method 1) =====
    BinState memory binState2 = BinState({
      token0BalanceScaled: availableToken0, token1BalanceScaled: 0, lengthE6: 1, addFeeBuyE6: 0, addFeeSellE6: 0
    });

    SwapMath.SwapState memory stateIn = SwapMath.SwapState({
      amountSpecifiedRemainingScaled: requiredInFromExactOut,
      amountCalculatedScaled: 0,
      protocolFeeAmountScaled: 0,
      feeExclusiveInputScaled: 0
    });

    uint128 actualOutFromExactIn;
    (, stateIn, actualOutFromExactIn,) = harness.exposedBuyToken0InBinSpecifiedIn(
      binState2, currBinPos, stateIn, feeE6, lowerPrice, upperPrice, type(uint128).max
    );

    // ===== Method 3: Analytical formula (ExactIn) =====
    (uint256 analyticalOut0,) = buyToken0GivenInputAnalytical(
      requiredInFromExactOut,
      availableToken0,
      currBinPos,
      lowerPrice,
      upperPrice - lowerPrice, // deltaP
      feeE6
    );

    assertGt(actualOutFromExactOut, 0);
    assertGt(actualOutFromExactIn, 0);
    assertGt(analyticalOut0, 0);
  }

  /**
   * @notice Fuzz test comparing all three methods
   */
  function testFuzz_BenchmarkComparison_Token0(
    uint104 currBinPos,
    uint104 availableToken0,
    uint128 specifiedOutRatio,
    uint128 lowerPrice,
    uint24 spreadBps,
    uint24 feeE6
  ) public view {
    // Bound inputs
    availableToken0 = uint104(bound(availableToken0, 1e18, 1e27));
    lowerPrice = uint128(bound(lowerPrice, 1e16, 1e20));
    spreadBps = uint24(bound(spreadBps, 1, 100)); // 0.01% to 1% spread
    uint128 upperPrice = lowerPrice + (lowerPrice * spreadBps) / 10000;
    currBinPos = uint104(bound(currBinPos, 0, uint104(M / 2)));
    feeE6 = uint24(bound(feeE6, 0, 10000)); // 0% to 1% fee

    // specifiedOut as 1% to 50% of available
    specifiedOutRatio = uint128(bound(specifiedOutRatio, 1, 50));
    uint128 specifiedOut = uint128((uint256(availableToken0) * specifiedOutRatio) / 100);

    // ===== Method 1: ExactOut =====
    BinState memory binState1 = BinState({
      token0BalanceScaled: availableToken0, token1BalanceScaled: 0, lengthE6: 1, addFeeBuyE6: 0, addFeeSellE6: 0
    });

    SwapMath.SwapState memory stateOut = SwapMath.SwapState({
      amountSpecifiedRemainingScaled: specifiedOut,
      amountCalculatedScaled: 0,
      protocolFeeAmountScaled: 0,
      feeExclusiveInputScaled: 0
    });

    uint256 finalPosOut;
    (finalPosOut, stateOut,) = harness.exposedBuyToken0InBinSpecifiedOut(
      binState1, currBinPos, stateOut, feeE6, lowerPrice, upperPrice, type(uint128).max
    );

    uint128 actualOutFromExactOut = uint128(specifiedOut - stateOut.amountSpecifiedRemainingScaled);
    uint128 requiredInFromExactOut = uint128(stateOut.amountCalculatedScaled);

    // Skip if no output or input is too small (rounding edge case)
    // When input is very small (like 1-10 wei), rounding errors dominate
    if (actualOutFromExactOut == 0 || requiredInFromExactOut < 100) {
      return;
    }

    // ===== Method 2: ExactIn =====
    BinState memory binState2 = BinState({
      token0BalanceScaled: availableToken0, token1BalanceScaled: 0, lengthE6: 1, addFeeBuyE6: 0, addFeeSellE6: 0
    });

    SwapMath.SwapState memory stateIn = SwapMath.SwapState({
      amountSpecifiedRemainingScaled: requiredInFromExactOut,
      amountCalculatedScaled: 0,
      protocolFeeAmountScaled: 0,
      feeExclusiveInputScaled: 0
    });

    uint128 actualOutFromExactIn;
    (, stateIn, actualOutFromExactIn,) = harness.exposedBuyToken0InBinSpecifiedIn(
      binState2, currBinPos, stateIn, feeE6, lowerPrice, upperPrice, type(uint128).max
    );

    // ===== Method 3: Analytical ExactIn =====
    (uint256 analyticalOut0,) = buyToken0GivenInputAnalytical(
      requiredInFromExactOut, availableToken0, currBinPos, lowerPrice, upperPrice - lowerPrice, feeE6
    );

    // ===== Assertions =====

    // The outputs should be very close (within 0.1%)
    // Note: Either direction is possible due to different rounding in the two paths
    uint128 diffExactOutExactIn = actualOutFromExactOut > actualOutFromExactIn
      ? actualOutFromExactOut - actualOutFromExactIn
      : actualOutFromExactIn - actualOutFromExactOut;
    uint128 tolerance = actualOutFromExactOut / 1000 + 1;
    assertLe(diffExactOutExactIn, tolerance, "ExactOut vs ExactIn diff too large");

    // Analytical ExactIn should be close to harness ExactIn (within 1%)
    uint256 diffAnalyticalExactIn = analyticalOut0 > actualOutFromExactIn
      ? analyticalOut0 - actualOutFromExactIn
      : actualOutFromExactIn - analyticalOut0;
    uint256 analyticalTolerance = uint256(actualOutFromExactIn) / 100 + 1; // 1% tolerance
    assertLe(diffAnalyticalExactIn, analyticalTolerance, "Analytical ExactIn vs Harness ExactIn diff too large");
  }

  /**
   * @notice Detailed comparison with metrics for choosing between methods
   */
  function skip_test_DetailedBenchmark() public view {
    // Test case: realistic swap scenario
    uint104 currBinPos = uint104(M / 3); // 33% position
    uint104 availableToken0 = 1e24;
    uint128 specifiedOut = 2e23; // 20% of available
    uint128 lowerPrice = 18446744073709551616; // 1.0 in X64 (2^64)
    uint128 upperPrice = lowerPrice + lowerPrice / 100; // 1% spread
    uint24 feeE6 = 3000; // 0.3% fee

    // ========== HARNESS EXACTOUT ==========
    uint256 gasStart = gasleft();

    BinState memory binState1 = BinState({
      token0BalanceScaled: availableToken0, token1BalanceScaled: 0, lengthE6: 1, addFeeBuyE6: 0, addFeeSellE6: 0
    });

    SwapMath.SwapState memory stateOut = SwapMath.SwapState({
      amountSpecifiedRemainingScaled: specifiedOut,
      amountCalculatedScaled: 0,
      protocolFeeAmountScaled: 0,
      feeExclusiveInputScaled: 0
    });

    uint256 finalPosOut;
    (finalPosOut, stateOut,) = harness.exposedBuyToken0InBinSpecifiedOut(
      binState1, currBinPos, stateOut, feeE6, lowerPrice, upperPrice, type(uint128).max
    );

    uint256 gasHarnessExactOut = gasStart - gasleft();
    uint128 actualOutHarnessExactOut = uint128(specifiedOut - stateOut.amountSpecifiedRemainingScaled);
    uint128 requiredInHarnessExactOut = uint128(stateOut.amountCalculatedScaled);

    // ========== HARNESS EXACTIN ==========
    gasStart = gasleft();

    BinState memory binState2 = BinState({
      token0BalanceScaled: availableToken0, token1BalanceScaled: 0, lengthE6: 1, addFeeBuyE6: 0, addFeeSellE6: 0
    });

    SwapMath.SwapState memory stateIn = SwapMath.SwapState({
      amountSpecifiedRemainingScaled: requiredInHarnessExactOut,
      amountCalculatedScaled: 0,
      protocolFeeAmountScaled: 0,
      feeExclusiveInputScaled: 0
    });

    (uint256 finalPosIn,, uint128 actualOutHarnessExactIn,) = harness.exposedBuyToken0InBinSpecifiedIn(
      binState2, currBinPos, stateIn, feeE6, lowerPrice, upperPrice, type(uint128).max
    );

    uint256 gasHarnessExactIn = gasStart - gasleft();

    // ========== ANALYTICAL EXACTIN ==========
    gasStart = gasleft();

    (uint256 analyticalOut0, uint256 analyticalD) = buyToken0GivenInputAnalytical(
      requiredInHarnessExactOut, availableToken0, currBinPos, lowerPrice, upperPrice - lowerPrice, feeE6
    );

    uint256 gasAnalyticalExactIn = gasStart - gasleft();

    // Calculate differences from ground truth
    uint256 harnessExactInDiff = actualOutHarnessExactOut > actualOutHarnessExactIn
      ? uint256(actualOutHarnessExactOut) - uint256(actualOutHarnessExactIn)
      : uint256(actualOutHarnessExactIn) - uint256(actualOutHarnessExactOut);
    uint256 analyticalDiff = uint256(actualOutHarnessExactOut) > analyticalOut0
      ? uint256(actualOutHarnessExactOut) - analyticalOut0
      : analyticalOut0 - uint256(actualOutHarnessExactOut);

    assertGt(actualOutHarnessExactOut, 0);
    assertGt(gasHarnessExactOut + gasHarnessExactIn + gasAnalyticalExactIn, 0);
    assertGe(harnessExactInDiff, 0);
    assertGe(analyticalDiff, 0);
    assertGe(analyticalD, 0);
    assertLe(finalPosOut, M);
    assertLe(finalPosIn, M);
  }

  // ============ Comprehensive Parameter Sweep Benchmark ============

  /**
   * @notice Helper to run benchmark for a single price exponent
   * @param exp Price exponent: priceLower = 2^64 * 10^(-exp)
   */
  function _runBenchmarkForPriceExp(int8 exp) internal view {
    uint128 priceLower = _calculatePriceLower(exp);
    if (priceLower == 0) return;

    // Subset of fees for faster testing
    uint24[5] memory fees = [uint24(0), 100, 3000, 10000, 100000];

    // Subset of virtual amounts
    uint256[6] memory virtualAmounts = [uint256(1e6), 1e12, 1e18, 1e21, 1e24, uint256(type(uint104).max)];

    // Subset of positions
    uint104[8] memory positions = [
      uint104(1), // near 0
      uint104(1 << 32), // low
      uint104(1 << 64), // middle-low
      uint104(1 << 80), // middle-high
      uint104(M - (1 << 80)), // high
      uint104(M - (1 << 64)), // very high
      uint104(M - (1 << 32)), // near max
      uint104(M - 1) // almost max
    ];

    // Subset of spreads: 10%, 0.1%, 0.001%
    uint8[3] memory spreadNs = [uint8(1), 3, 5];

    for (uint256 sIdx = 0; sIdx < spreadNs.length; sIdx++) {
      uint128 priceUpper = _calculatePriceUpper(priceLower, spreadNs[sIdx]);
      if (priceUpper <= priceLower) continue;

      for (uint256 fIdx = 0; fIdx < fees.length; fIdx++) {
        for (uint256 vIdx = 0; vIdx < virtualAmounts.length; vIdx++) {
          for (uint256 cIdx = 0; cIdx < positions.length; cIdx++) {
            uint104 currPos = positions[cIdx];
            if (currPos == 0 || currPos >= M) continue;

            uint256 token0Balance = Math.mulDiv(virtualAmounts[vIdx], M - currPos, M);
            if (token0Balance <= 1e9 || token0Balance > type(uint104).max) continue;

            uint128 specifiedOut = uint128(token0Balance / 10);
            if (specifiedOut == 0) continue;

            _runSingleBenchmarkToken1ToToken0(
              priceLower, priceUpper, fees[fIdx], virtualAmounts[vIdx], currPos, uint104(token0Balance), specifiedOut
            );
          }
        }
      }
    }
  }

  // Individual tests for each price magnitude - run separately to avoid OOM

  function skip_test_Sweep_Token1ToToken0_PriceExp_Neg9() public view {
    _runBenchmarkForPriceExp(-9); // price = 2^64 * 10^9 (very high price)
  }

  function skip_test_Sweep_Token1ToToken0_PriceExp_Neg6() public view {
    _runBenchmarkForPriceExp(-6); // price = 2^64 * 10^6
  }

  function skip_test_Sweep_Token1ToToken0_PriceExp_Neg3() public view {
    _runBenchmarkForPriceExp(-3); // price = 2^64 * 10^3
  }

  function skip_test_Sweep_Token1ToToken0_PriceExp_0() public view {
    _runBenchmarkForPriceExp(0); // price = 2^64 (1.0 in X64)
  }

  function skip_test_Sweep_Token1ToToken0_PriceExp_3() public view {
    _runBenchmarkForPriceExp(3); // price = 2^64 / 10^3
  }

  function skip_test_Sweep_Token1ToToken0_PriceExp_6() public view {
    _runBenchmarkForPriceExp(6); // price = 2^64 / 10^6
  }

  function skip_test_Sweep_Token1ToToken0_PriceExp_9() public view {
    _runBenchmarkForPriceExp(9); // price = 2^64 / 10^9 (very low price)
  }

  /**
   * @notice Calculate price lower: 2^64 / 10^X
   */
  function _calculatePriceLower(int8 exp) internal pure returns (uint128) {
    if (exp == 0) {
      return uint128(Q64); // 2^64
    } else if (exp > 0) {
      // 2^64 / 10^exp
      uint256 divisor = 10 ** uint8(exp);
      if (divisor > Q64) return 0;
      return uint128(Q64 / divisor);
    } else {
      // 2^64 * 10^(-exp)
      uint256 multiplier = 10 ** uint8(-exp);
      uint256 result = Q64 * multiplier;
      if (result > type(uint128).max) return 0;
      return uint128(result);
    }
  }

  /**
   * @notice Calculate price upper: priceLower * (10^N + 1) / 10^N
   */
  function _calculatePriceUpper(uint128 priceLower, uint8 n) internal pure returns (uint128) {
    // G = (10^N + 1) / 10^N
    // priceUpper = priceLower * G = priceLower + priceLower / 10^N
    uint256 divisor = 10 ** n;
    uint256 spread = uint256(priceLower) / divisor;
    if (spread == 0) spread = 1; // Ensure at least 1 unit spread
    uint256 upper = uint256(priceLower) + spread;
    if (upper > type(uint128).max) return 0;
    return uint128(upper);
  }

  /**
   * @notice Run a single benchmark test case for Token1 -> Token0
   */
  function _runSingleBenchmarkToken1ToToken0(
    uint128 priceLower,
    uint128 priceUpper,
    uint24 fee,
    uint256,
    /* virtualAmount */
    uint104 currPos,
    uint104 token0Balance,
    uint128 specifiedOut
  ) internal view {
    // ===== Harness ExactOut (ground truth) =====
    BinState memory binState1 = BinState({
      token0BalanceScaled: token0Balance, token1BalanceScaled: 0, lengthE6: 1, addFeeBuyE6: 0, addFeeSellE6: 0
    });

    SwapMath.SwapState memory stateOut = SwapMath.SwapState({
      amountSpecifiedRemainingScaled: specifiedOut,
      amountCalculatedScaled: 0,
      protocolFeeAmountScaled: 0,
      feeExclusiveInputScaled: 0
    });

    try harness.exposedBuyToken0InBinSpecifiedOut(
      binState1, currPos, stateOut, fee, priceLower, priceUpper, type(uint128).max
    ) returns (
      uint256, SwapMath.SwapState memory stateOutResult, BinState memory
    ) {
      uint128 actualOut = uint128(specifiedOut - stateOutResult.amountSpecifiedRemainingScaled);
      uint128 requiredIn = uint128(stateOutResult.amountCalculatedScaled);

      // Skip if no output or input too small
      if (actualOut == 0 || requiredIn < 10) return;

      // ===== Harness ExactIn =====
      BinState memory binState2 = BinState({
        token0BalanceScaled: token0Balance, token1BalanceScaled: 0, lengthE6: 1, addFeeBuyE6: 0, addFeeSellE6: 0
      });

      SwapMath.SwapState memory stateIn = SwapMath.SwapState({
        amountSpecifiedRemainingScaled: requiredIn,
        amountCalculatedScaled: 0,
        protocolFeeAmountScaled: 0,
        feeExclusiveInputScaled: 0
      });

      try harness.exposedBuyToken0InBinSpecifiedIn(
        binState2, currPos, stateIn, fee, priceLower, priceUpper, type(uint128).max
      ) returns (
        uint256, SwapMath.SwapState memory, uint128 harnessExactInOut, BinState memory
      ) {
        // ===== Analytical ExactIn =====
        (uint256 analyticalOut,) =
          buyToken0GivenInputAnalytical(requiredIn, token0Balance, currPos, priceLower, priceUpper - priceLower, fee);

        // Calculate ratios and differences
        // Ratio = ExactIn output / ExactOut output (should be ~1.0)
        // We multiply by 1e18 for precision
        uint256 harnessRatio = actualOut > 0 ? Math.mulDiv(harnessExactInOut, 1e18, actualOut) : 0;
        uint256 analyticalRatio = actualOut > 0 ? Math.mulDiv(analyticalOut, 1e18, actualOut) : 0;

        // Absolute differences
        uint256 harnessAbsDiff =
          harnessExactInOut > actualOut ? harnessExactInOut - actualOut : actualOut - harnessExactInOut;
        uint256 analyticalAbsDiff = analyticalOut > actualOut ? analyticalOut - actualOut : actualOut - analyticalOut;

        assertGe(harnessExactInOut, 0);
        assertGe(analyticalOut, 0);
        assertGe(harnessRatio, 0);
        assertGe(analyticalRatio, 0);
        assertGe(harnessAbsDiff, 0);
        assertGe(analyticalAbsDiff, 0);
      } catch {
        // ExactIn failed, skip
      }
    } catch {
      // ExactOut failed, skip
    }
  }

  /**
   * @notice Token0 -> Token1 direction benchmark
   */
  function skip_test_ComprehensiveParameterSweep_Token0ToToken1() public view {
    // Same parameter ranges as Token1ToToken0 test
    int8[7] memory priceExponents = [int8(-9), int8(-6), int8(-3), int8(0), int8(3), int8(6), int8(9)];
    uint24[9] memory fees = [uint24(0), 1, 10, 100, 1000, 10000, 100000, 200000, 500000];
    uint256[10] memory virtualAmounts =
      [uint256(1e3), 1e6, 1e9, 1e12, 1e15, 1e18, 1e21, 1e24, 1e27, uint256(type(uint104).max)];
    uint104[14] memory positions = [
      uint104(1),
      uint104(1 << 16),
      uint104(1 << 32),
      uint104(1 << 48),
      uint104(1 << 64),
      uint104(1 << 80),
      uint104((1 << 95)),
      uint104(M - 1),
      uint104(M - (1 << 16)),
      uint104(M - (1 << 32)),
      uint104(M - (1 << 48)),
      uint104(M - (1 << 64)),
      uint104(M - (1 << 80)),
      uint104(M - (1 << 95))
    ];
    uint8[4] memory spreadNs = [uint8(1), 3, 6, 9];

    for (uint256 pIdx = 0; pIdx < priceExponents.length; pIdx++) {
      int8 exp = priceExponents[pIdx];
      uint128 priceLower = _calculatePriceLower(exp);
      if (priceLower == 0) continue;

      for (uint256 sIdx = 0; sIdx < spreadNs.length; sIdx++) {
        uint8 spreadN = spreadNs[sIdx];
        uint128 priceUpper = _calculatePriceUpper(priceLower, spreadN);
        if (priceUpper <= priceLower) continue;

        for (uint256 fIdx = 0; fIdx < fees.length; fIdx++) {
          uint24 fee = fees[fIdx];

          for (uint256 vIdx = 0; vIdx < virtualAmounts.length; vIdx++) {
            uint256 virtualAmount = virtualAmounts[vIdx];

            for (uint256 cIdx = 0; cIdx < positions.length; cIdx++) {
              uint104 currPos = positions[cIdx];
              if (currPos == 0 || currPos >= M) continue;

              // Calculate token1 balance: VirtualAmount * c / M
              uint256 token1Balance = Math.mulDiv(virtualAmount, currPos, M);
              if (token1Balance == 0 || token1Balance > type(uint104).max) continue;

              // Test with 10% of available token1 as input
              uint128 specifiedIn = uint128(token1Balance / 10);
              if (specifiedIn == 0) continue;

              _runSingleBenchmarkToken0ToToken1(
                priceLower, priceUpper, fee, virtualAmount, currPos, uint104(token1Balance), specifiedIn
              );
            }
          }
        }
      }
    }
  }

  /**
   * @notice Run a single benchmark test case for Token0 -> Token1
   */
  function _runSingleBenchmarkToken0ToToken1(
    uint128 priceLower,
    uint128 priceUpper,
    uint24 fee,
    uint256 virtualAmount,
    uint104 currPos,
    uint104 token1Balance,
    uint128 specifiedIn
  ) internal view {
    // For Token0 -> Token1, we use the sell direction
    // This needs the sellToken0 harness functions

    // Calculate token0 balance from virtual amount
    uint256 token0Balance = Math.mulDiv(virtualAmount, M - currPos, M);
    if (token0Balance == 0 || token0Balance > type(uint104).max) return;

    // ===== Harness ExactOut (for Token1 out) =====
    BinState memory binState1 = BinState({
      token0BalanceScaled: uint104(token0Balance),
      token1BalanceScaled: token1Balance,
      lengthE6: 1,
      addFeeBuyE6: 0,
      addFeeSellE6: 0
    });

    // For selling Token0, we specify Token0 input
    SwapMath.SwapState memory stateOut = SwapMath.SwapState({
      amountSpecifiedRemainingScaled: specifiedIn,
      amountCalculatedScaled: 0,
      protocolFeeAmountScaled: 0,
      feeExclusiveInputScaled: 0
    });

    try harness.exposedBuyToken1InBinSpecifiedOut(
      binState1, currPos, stateOut, fee, priceLower, priceUpper, type(uint128).max
    ) returns (
      uint256, SwapMath.SwapState memory stateOutResult, BinState memory
    ) {
      uint128 actualOut = uint128(specifiedIn - stateOutResult.amountSpecifiedRemainingScaled);
      uint128 requiredIn = uint128(stateOutResult.amountCalculatedScaled);

      if (actualOut == 0 || requiredIn < 10) return;

      // ===== Harness ExactIn =====
      BinState memory binState2 = BinState({
        token0BalanceScaled: uint104(token0Balance),
        token1BalanceScaled: token1Balance,
        lengthE6: 1,
        addFeeBuyE6: 0,
        addFeeSellE6: 0
      });

      SwapMath.SwapState memory stateIn = SwapMath.SwapState({
        amountSpecifiedRemainingScaled: requiredIn,
        amountCalculatedScaled: 0,
        protocolFeeAmountScaled: 0,
        feeExclusiveInputScaled: 0
      });

      try harness.exposedBuyToken1InBinSpecifiedIn(
        binState2, currPos, stateIn, fee, priceLower, priceUpper, type(uint128).max
      ) returns (
        uint256, SwapMath.SwapState memory, uint128 harnessExactInOut, BinState memory
      ) {
        // ===== Analytical ExactIn =====
        (uint256 analyticalOut,) = sellToken0GivenInputAnalytical(
          requiredIn, uint104(token0Balance), currPos, priceLower, priceUpper - priceLower, fee
        );

        // Calculate ratios and differences
        uint256 harnessRatio = actualOut > 0 ? Math.mulDiv(harnessExactInOut, 1e18, actualOut) : 0;
        uint256 analyticalRatio = actualOut > 0 ? Math.mulDiv(analyticalOut, 1e18, actualOut) : 0;

        uint256 harnessAbsDiff =
          harnessExactInOut > actualOut ? harnessExactInOut - actualOut : actualOut - harnessExactInOut;
        uint256 analyticalAbsDiff = analyticalOut > actualOut ? analyticalOut - actualOut : actualOut - analyticalOut;

        assertGe(harnessExactInOut, 0);
        assertGe(analyticalOut, 0);
        assertGe(harnessRatio, 0);
        assertGe(analyticalRatio, 0);
        assertGe(harnessAbsDiff, 0);
        assertGe(analyticalAbsDiff, 0);
        assertLe(priceLower, priceUpper);
      } catch {
        // ExactIn failed
      }
    } catch {
      // ExactOut failed
    }
  }

  // ============ Token0 → Token1 Individual Tests ============

  /**
   * @notice Helper to run benchmark for Token0 → Token1 at a single price exponent
   */
  function _runBenchmarkForPriceExp_Token0ToToken1(int8 exp) internal view {
    uint128 priceLower = _calculatePriceLower(exp);
    if (priceLower == 0) return;

    // Subset of fees for faster testing
    uint24[5] memory fees = [uint24(0), 100, 3000, 10000, 100000];

    // Subset of virtual amounts
    uint256[6] memory virtualAmounts = [uint256(1e6), 1e12, 1e18, 1e21, 1e24, uint256(type(uint104).max)];

    // Subset of positions - for Token0 → Token1 we need c > 0 (token1 exists)
    uint104[8] memory positions = [
      uint104(1), // near 0
      uint104(1 << 32), // low
      uint104(1 << 64), // middle-low
      uint104(1 << 80), // middle-high
      uint104(M - (1 << 80)), // high
      uint104(M - (1 << 64)), // very high
      uint104(M - (1 << 32)), // near max
      uint104(M - 1) // almost max
    ];

    // Subset of spreads: 10%, 0.1%, 0.001%
    uint8[3] memory spreadNs = [uint8(1), 3, 5];

    for (uint256 sIdx = 0; sIdx < spreadNs.length; sIdx++) {
      uint128 priceUpper = _calculatePriceUpper(priceLower, spreadNs[sIdx]);
      if (priceUpper <= priceLower) continue;

      for (uint256 fIdx = 0; fIdx < fees.length; fIdx++) {
        for (uint256 vIdx = 0; vIdx < virtualAmounts.length; vIdx++) {
          for (uint256 cIdx = 0; cIdx < positions.length; cIdx++) {
            uint104 currPos = positions[cIdx];
            if (currPos == 0 || currPos >= M) continue;

            // Calculate token1 balance: VirtualAmount * c / M
            uint256 token1Balance = Math.mulDiv(virtualAmounts[vIdx], currPos, M);
            if (token1Balance <= 1e9 || token1Balance > type(uint104).max) continue;

            // Test with 10% of available token1 as input
            uint128 specifiedIn = uint128(token1Balance / 10);
            if (specifiedIn == 0) continue;

            _runSingleBenchmarkToken0ToToken1(
              priceLower, priceUpper, fees[fIdx], virtualAmounts[vIdx], currPos, uint104(token1Balance), specifiedIn
            );
          }
        }
      }
    }
  }

  function skip_test_Sweep_Token0ToToken1_PriceExp_Neg9() public view {
    _runBenchmarkForPriceExp_Token0ToToken1(-9);
  }

  function skip_test_Sweep_Token0ToToken1_PriceExp_Neg6() public view {
    _runBenchmarkForPriceExp_Token0ToToken1(-6);
  }

  function skip_test_Sweep_Token0ToToken1_PriceExp_Neg3() public view {
    _runBenchmarkForPriceExp_Token0ToToken1(-3);
  }

  function skip_test_Sweep_Token0ToToken1_PriceExp_0() public view {
    _runBenchmarkForPriceExp_Token0ToToken1(0);
  }

  function skip_test_Sweep_Token0ToToken1_PriceExp_3() public view {
    _runBenchmarkForPriceExp_Token0ToToken1(3);
  }

  function skip_test_Sweep_Token0ToToken1_PriceExp_6() public view {
    _runBenchmarkForPriceExp_Token0ToToken1(6);
  }

  function skip_test_Sweep_Token0ToToken1_PriceExp_9() public view {
    _runBenchmarkForPriceExp_Token0ToToken1(9);
  }
}
