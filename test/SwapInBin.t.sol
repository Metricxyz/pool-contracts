// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;
// forge-lint: disable-start(unsafe-typecast)

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
contract MockERC20ForSwapInBin is ERC20 {
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
contract MockPriceProviderForSwapInBin is IPriceProvider {
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
 * @title SwapInBinTest
 * @notice Fuzz tests for internal swapInBin functions
 * @dev Tests inspired by the removed SwapMath.binarySearch.t.sol
 */
contract SwapInBinTest is Test, FactoryFeeCapsStub, PoolInitPreprocessor {
  SwapInBinHarness public harness;
  MockERC20ForSwapInBin public token0;
  MockERC20ForSwapInBin public token1;
  MockPriceProviderForSwapInBin public oracle;

  uint256 constant TOKEN_0_DECIMAL_MULTIPLIER = 1e18;
  uint256 constant TOKEN_1_DECIMAL_MULTIPLIER = 1e18;

  function setUp() public {
    // Deploy mock tokens
    token0 = new MockERC20ForSwapInBin("Token0", "TK0", 18);
    token1 = new MockERC20ForSwapInBin("Token1", "TK1", 18);

    // Deploy mock oracle
    oracle = new MockPriceProviderForSwapInBin();
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

  // ============ Token0 Exact In Tests (buying token0 with token1) ============

  /**
   * @notice Test that output amount never exceeds available amount
   */
  function testFuzz_Token0ExactIn_OutputNotExceedsAvailable(
    uint104 currBinPos,
    uint104 availableToken0,
    uint128 remainingIn,
    uint128 lowerPriceX64,
    uint128 upperPriceX64,
    uint128 priceLimitX64
  ) public view {
    availableToken0 = uint104(bound(availableToken0, 1e18, 1e27)); // Max 1B tokens
    remainingIn = uint128(bound(remainingIn, 1e6, 1e28));
    lowerPriceX64 = uint128(bound(lowerPriceX64, 1e14, 1e22)); // Reasonable price range
    upperPriceX64 = uint128(bound(upperPriceX64, lowerPriceX64 + 2, lowerPriceX64 * 100));
    currBinPos = uint104(bound(currBinPos, 0, type(uint104).max - 1));
    priceLimitX64 = uint128(bound(priceLimitX64, lowerPriceX64, upperPriceX64));

    BinState memory binState = BinState({
      token0BalanceScaled: availableToken0, token1BalanceScaled: 0, lengthE6: 1, addFeeBuyE6: 0, addFeeSellE6: 0
    });

    SwapMath.SwapState memory state = SwapMath.SwapState({
      amountSpecifiedRemainingScaled: remainingIn,
      amountCalculatedScaled: 0,
      protocolFeeAmountScaled: 0,
      feeExclusiveInputScaled: 0
    });

    (,, uint128 outToken0,) = harness.exposedBuyToken0InBinSpecifiedIn(
      binState,
      currBinPos,
      state,
      0, // currBinBuyFeeX64
      lowerPriceX64,
      upperPriceX64,
      priceLimitX64
    );

    assertLe(outToken0, availableToken0, "Output should not exceed available token0");
  }

  /**
   * @notice Test that consumed input never exceeds remainingIn
   */
  function testFuzz_Token0ExactIn_InputNotExceedsRemaining(
    uint104 currBinPos,
    uint104 availableToken0,
    uint128 remainingIn,
    uint128 lowerPriceX64,
    uint128 upperPriceX64,
    uint128 priceLimitX64
  ) public view {
    availableToken0 = uint104(bound(availableToken0, 1e18, 1e27));
    remainingIn = uint128(bound(remainingIn, 1e6, 1e28));
    lowerPriceX64 = uint128(bound(lowerPriceX64, 1e14, 1e22));
    upperPriceX64 = uint128(bound(upperPriceX64, lowerPriceX64 + 2, lowerPriceX64 * 100));
    currBinPos = uint104(bound(currBinPos, 0, type(uint104).max - 1));
    priceLimitX64 = uint128(bound(priceLimitX64, lowerPriceX64, upperPriceX64));

    BinState memory binState = BinState({
      token0BalanceScaled: availableToken0, token1BalanceScaled: 0, lengthE6: 1, addFeeBuyE6: 0, addFeeSellE6: 0
    });

    SwapMath.SwapState memory state = SwapMath.SwapState({
      amountSpecifiedRemainingScaled: remainingIn,
      amountCalculatedScaled: 0,
      protocolFeeAmountScaled: 0,
      feeExclusiveInputScaled: 0
    });

    (, SwapMath.SwapState memory newState,,) = harness.exposedBuyToken0InBinSpecifiedIn(
      binState, currBinPos, state, 0, lowerPriceX64, upperPriceX64, priceLimitX64
    );

    // Consumed input is the delta in token1Balance (what was added to the bin)
    uint128 consumedInput = uint128(remainingIn - newState.amountSpecifiedRemainingScaled);
    assertLe(consumedInput, remainingIn, "Consumed input should not exceed remainingIn");
  }

  /**
   * @notice Test that if price limit is hit, the final position respects the limit
   */
  function testFuzz_Token0ExactIn_PriceLimitRespect(
    uint104 currBinPos,
    uint104 availableToken0,
    uint128 remainingIn,
    uint128 lowerPriceX64,
    uint128 upperPriceX64,
    uint128 priceLimitX64
  ) public view {
    availableToken0 = uint104(bound(availableToken0, 1e18, 1e27));
    remainingIn = uint128(bound(remainingIn, 1e18, 1e28));
    lowerPriceX64 = uint128(bound(lowerPriceX64, 1e14, 1e22));
    upperPriceX64 = uint128(bound(upperPriceX64, lowerPriceX64 + 2, lowerPriceX64 * 100));
    currBinPos = uint104(bound(currBinPos, 0, type(uint104).max - 1));
    priceLimitX64 = uint128(bound(priceLimitX64, lowerPriceX64 + 1, upperPriceX64 - 1));

    BinState memory binState = BinState({
      token0BalanceScaled: availableToken0, token1BalanceScaled: 0, lengthE6: 1, addFeeBuyE6: 0, addFeeSellE6: 0
    });

    SwapMath.SwapState memory state = SwapMath.SwapState({
      amountSpecifiedRemainingScaled: remainingIn,
      amountCalculatedScaled: 0,
      protocolFeeAmountScaled: 0,
      feeExclusiveInputScaled: 0
    });

    (uint256 finalBinPos,, uint128 outToken0,) = harness.exposedBuyToken0InBinSpecifiedIn(
      binState, currBinPos, state, 0, lowerPriceX64, upperPriceX64, priceLimitX64
    );

    // Only check price limit if we actually moved (finalBinPos > currBinPos)
    if (finalBinPos != type(uint104).max && finalBinPos > uint256(currBinPos) && outToken0 > 0) {
      uint256 finalPrice =
        SwapMath.calculatePriceAtBinPosition(lowerPriceX64, upperPriceX64, finalBinPos, Math.Rounding.Floor);
      // Allow small tolerance for rounding
      assertLe(finalPrice, priceLimitX64 + 100, "Final price should be <= limit");
    }
  }

  // ============ Token1 Exact In Tests (selling token0 for token1) ============

  /**
   * @notice Test that output amount never exceeds available amount
   */
  function testFuzz_Token1ExactIn_OutputNotExceedsAvailable(
    uint104 currBinPos,
    uint104 availableToken1,
    uint128 remainingIn,
    uint128 lowerPriceX64,
    uint128 upperPriceX64,
    uint128 priceLimitX64
  ) public view {
    availableToken1 = uint104(bound(availableToken1, 1e18, 1e27));
    remainingIn = uint128(bound(remainingIn, 1e6, 1e28));
    lowerPriceX64 = uint128(bound(lowerPriceX64, 1e14, 1e22));
    upperPriceX64 = uint128(bound(upperPriceX64, lowerPriceX64 + 2, lowerPriceX64 * 100));
    currBinPos = uint104(bound(currBinPos, 1, type(uint104).max));

    BinState memory binState = BinState({
      token0BalanceScaled: 0, token1BalanceScaled: availableToken1, lengthE6: 1, addFeeBuyE6: 0, addFeeSellE6: 0
    });

    SwapMath.SwapState memory state = SwapMath.SwapState({
      amountSpecifiedRemainingScaled: remainingIn,
      amountCalculatedScaled: 0,
      protocolFeeAmountScaled: 0,
      feeExclusiveInputScaled: 0
    });

    (,, uint128 outToken1,) = harness.exposedBuyToken1InBinSpecifiedIn(
      binState, currBinPos, state, 0, lowerPriceX64, upperPriceX64, priceLimitX64
    );

    assertLe(outToken1, availableToken1, "Output should not exceed available token1");
  }

  /**
   * @notice Test that consumed input never exceeds remainingIn
   */
  function testFuzz_Token1ExactIn_InputNotExceedsRemaining(
    uint104 currBinPos,
    uint104 availableToken1,
    uint128 remainingIn,
    uint128 lowerPriceX64,
    uint128 upperPriceX64,
    uint128 priceLimitX64
  ) public view {
    availableToken1 = uint104(bound(availableToken1, 1e18, 1e27));
    remainingIn = uint128(bound(remainingIn, 1e6, 1e28));
    lowerPriceX64 = uint128(bound(lowerPriceX64, 1e14, 1e22));
    upperPriceX64 = uint128(bound(upperPriceX64, lowerPriceX64 + 2, lowerPriceX64 * 100));
    currBinPos = uint104(bound(currBinPos, 1, type(uint104).max));

    BinState memory binState = BinState({
      token0BalanceScaled: 0, token1BalanceScaled: availableToken1, lengthE6: 1, addFeeBuyE6: 0, addFeeSellE6: 0
    });

    SwapMath.SwapState memory state = SwapMath.SwapState({
      amountSpecifiedRemainingScaled: remainingIn,
      amountCalculatedScaled: 0,
      protocolFeeAmountScaled: 0,
      feeExclusiveInputScaled: 0
    });

    (, SwapMath.SwapState memory newState,,) = harness.exposedBuyToken1InBinSpecifiedIn(
      binState, currBinPos, state, 0, lowerPriceX64, upperPriceX64, priceLimitX64
    );

    uint128 consumedInput = uint128(remainingIn - newState.amountSpecifiedRemainingScaled);
    assertLe(consumedInput, remainingIn, "Consumed input should not exceed remainingIn");
  }

  /**
   * @notice Test that if price limit is hit, the final position respects the limit
   */
  function testFuzz_Token1ExactIn_PriceLimitRespect(
    uint104 currBinPos,
    uint104 availableToken1,
    uint128 remainingIn,
    uint128 lowerPriceX64,
    uint128 upperPriceX64,
    uint128 priceLimitX64
  ) public view {
    availableToken1 = uint104(bound(availableToken1, 1e18, 1e27));
    remainingIn = uint128(bound(remainingIn, 1e18, 1e28));
    lowerPriceX64 = uint128(bound(lowerPriceX64, 1e14, 1e22));
    upperPriceX64 = uint128(bound(upperPriceX64, lowerPriceX64 + 2, lowerPriceX64 * 100));
    currBinPos = uint104(bound(currBinPos, 1, type(uint104).max));
    priceLimitX64 = uint128(bound(priceLimitX64, lowerPriceX64 + 1, upperPriceX64 - 1));

    BinState memory binState = BinState({
      token0BalanceScaled: 0, token1BalanceScaled: availableToken1, lengthE6: 1, addFeeBuyE6: 0, addFeeSellE6: 0
    });

    SwapMath.SwapState memory state = SwapMath.SwapState({
      amountSpecifiedRemainingScaled: remainingIn,
      amountCalculatedScaled: 0,
      protocolFeeAmountScaled: 0,
      feeExclusiveInputScaled: 0
    });

    (uint256 finalBinPos,, uint128 outToken1,) = harness.exposedBuyToken1InBinSpecifiedIn(
      binState, currBinPos, state, 0, lowerPriceX64, upperPriceX64, priceLimitX64
    );

    // Only check price limit if we actually moved (finalBinPos < currBinPos for selling)
    if (finalBinPos != 0 && finalBinPos < uint256(currBinPos) && outToken1 > 0) {
      uint256 finalPrice =
        SwapMath.calculatePriceAtBinPosition(lowerPriceX64, upperPriceX64, finalBinPos, Math.Rounding.Ceil);
      // Allow small tolerance for rounding
      assertGe(finalPrice, priceLimitX64 - 100, "Final price should be >= limit");
    }
  }

  // ============ Token0 Exact Out Tests ============

  /**
   * @notice Test that output amount never exceeds available or requested amount
   */
  function testFuzz_Token0ExactOut_OutputNotExceedsAvailableOrRequested(
    uint104 currBinPos,
    uint104 availableToken0,
    uint128 remainingOut,
    uint128 lowerPriceX64,
    uint128 upperPriceX64,
    uint128 priceLimitX64
  ) public view {
    availableToken0 = uint104(bound(availableToken0, 1e18, 1e27));
    remainingOut = uint128(bound(remainingOut, 1e6, 1e28));
    lowerPriceX64 = uint128(bound(lowerPriceX64, 1e14, 1e22));
    upperPriceX64 = uint128(bound(upperPriceX64, lowerPriceX64 + 2, lowerPriceX64 * 100));
    currBinPos = uint104(bound(currBinPos, 0, type(uint104).max - 1));
    priceLimitX64 = uint128(bound(priceLimitX64, upperPriceX64, type(uint128).max)); // No price limit restriction

    // Bound to prevent uint104 overflow in token1 balance calculation
    // amountIn = amountOut * price, must fit in uint104
    vm.assume((uint256(remainingOut) * uint256(upperPriceX64)) / Q64 < type(uint104).max);

    BinState memory binState = BinState({
      token0BalanceScaled: availableToken0, token1BalanceScaled: 0, lengthE6: 1, addFeeBuyE6: 0, addFeeSellE6: 0
    });

    SwapMath.SwapState memory state = SwapMath.SwapState({
      amountSpecifiedRemainingScaled: remainingOut,
      amountCalculatedScaled: 0,
      protocolFeeAmountScaled: 0,
      feeExclusiveInputScaled: 0
    });

    (, SwapMath.SwapState memory newState,) = harness.exposedBuyToken0InBinSpecifiedOut(
      binState, currBinPos, state, 0, lowerPriceX64, upperPriceX64, priceLimitX64
    );

    // Output is what was consumed from amountSpecifiedRemainingScaled
    uint128 actualOutput = uint128(remainingOut - newState.amountSpecifiedRemainingScaled);
    assertLe(actualOutput, availableToken0, "Output should not exceed available token0");
    assertLe(actualOutput, remainingOut, "Output should not exceed requested amount");
  }

  // ============ Token1 Exact Out Tests ============

  /**
   * @notice Test that output amount never exceeds available or requested amount
   */
  function testFuzz_Token1ExactOut_OutputNotExceedsAvailableOrRequested(
    uint104 currBinPos,
    uint104 availableToken1,
    uint128 remainingOut,
    uint128 lowerPriceX64,
    uint128 upperPriceX64,
    uint128 priceLimitX64
  ) public view {
    availableToken1 = uint104(bound(availableToken1, 1e18, 1e27));
    remainingOut = uint128(bound(remainingOut, 1e6, 1e28));
    lowerPriceX64 = uint128(bound(lowerPriceX64, 1e14, 1e22));
    upperPriceX64 = uint128(bound(upperPriceX64, lowerPriceX64 + 2, lowerPriceX64 * 100));
    currBinPos = uint104(bound(currBinPos, 1, type(uint104).max));
    priceLimitX64 = uint128(bound(priceLimitX64, 0, lowerPriceX64)); // No price limit restriction

    // Bound to prevent uint104 overflow in token0 balance calculation
    // amountIn = amountOut / price, must fit in uint104
    vm.assume((uint256(remainingOut) * Q64) / uint256(lowerPriceX64) < type(uint104).max);

    BinState memory binState = BinState({
      token0BalanceScaled: 0, token1BalanceScaled: availableToken1, lengthE6: 1, addFeeBuyE6: 0, addFeeSellE6: 0
    });

    SwapMath.SwapState memory state = SwapMath.SwapState({
      amountSpecifiedRemainingScaled: remainingOut,
      amountCalculatedScaled: 0,
      protocolFeeAmountScaled: 0,
      feeExclusiveInputScaled: 0
    });

    (, SwapMath.SwapState memory newState,) = harness.exposedBuyToken1InBinSpecifiedOut(
      binState, currBinPos, state, 0, lowerPriceX64, upperPriceX64, priceLimitX64
    );

    uint128 actualOutput = uint128(remainingOut - newState.amountSpecifiedRemainingScaled);
    assertLe(actualOutput, availableToken1, "Output should not exceed available token1");
    assertLe(actualOutput, remainingOut, "Output should not exceed requested amount");
  }

  // ============ No Movement Tests ============

  /**
   * @notice Test that no movement means zero amounts
   */
  function testFuzz_Token0ExactIn_NoMovementMeansZeroAmounts(
    uint104 currBinPos,
    uint104 availableToken0,
    uint128 remainingIn,
    uint128 lowerPriceX64,
    uint128 upperPriceX64,
    uint128 priceLimitX64
  ) public view {
    availableToken0 = uint104(bound(availableToken0, 1e18, 1e27));
    remainingIn = uint128(bound(remainingIn, 1e6, 1e28));
    lowerPriceX64 = uint128(bound(lowerPriceX64, 1e14, 1e22));
    upperPriceX64 = uint128(bound(upperPriceX64, lowerPriceX64 + 2, lowerPriceX64 * 100));
    currBinPos = uint104(bound(currBinPos, 0, type(uint104).max - 1));
    priceLimitX64 = uint128(bound(priceLimitX64, lowerPriceX64, upperPriceX64));

    BinState memory binState = BinState({
      token0BalanceScaled: availableToken0, token1BalanceScaled: 0, lengthE6: 1, addFeeBuyE6: 0, addFeeSellE6: 0
    });

    SwapMath.SwapState memory state = SwapMath.SwapState({
      amountSpecifiedRemainingScaled: remainingIn,
      amountCalculatedScaled: 0,
      protocolFeeAmountScaled: 0,
      feeExclusiveInputScaled: 0
    });

    (uint256 finalBinPos, SwapMath.SwapState memory newState, uint128 outToken0,) = harness.exposedBuyToken0InBinSpecifiedIn(
      binState, currBinPos, state, 0, lowerPriceX64, upperPriceX64, priceLimitX64
    );

    if (finalBinPos == uint256(currBinPos)) {
      assertEq(outToken0, 0, "No movement should mean zero output");
      assertEq(newState.amountCalculatedScaled, 0, "No movement should mean zero calculated amount");
    }
  }

  /**
   * @notice Test that no movement means zero amounts for token1 exact in
   */
  function testFuzz_Token1ExactIn_NoMovementMeansZeroAmounts(
    uint104 currBinPos,
    uint104 availableToken1,
    uint128 remainingIn,
    uint128 lowerPriceX64,
    uint128 upperPriceX64,
    uint128 priceLimitX64
  ) public view {
    availableToken1 = uint104(bound(availableToken1, 1e18, 1e27));
    remainingIn = uint128(bound(remainingIn, 1e6, 1e28));
    lowerPriceX64 = uint128(bound(lowerPriceX64, 1e14, 1e22));
    upperPriceX64 = uint128(bound(upperPriceX64, lowerPriceX64 + 2, lowerPriceX64 * 100));
    currBinPos = uint104(bound(currBinPos, 1, type(uint104).max));

    BinState memory binState = BinState({
      token0BalanceScaled: 0, token1BalanceScaled: availableToken1, lengthE6: 1, addFeeBuyE6: 0, addFeeSellE6: 0
    });

    SwapMath.SwapState memory state = SwapMath.SwapState({
      amountSpecifiedRemainingScaled: remainingIn,
      amountCalculatedScaled: 0,
      protocolFeeAmountScaled: 0,
      feeExclusiveInputScaled: 0
    });

    (uint256 finalBinPos, SwapMath.SwapState memory newState, uint128 outToken1,) = harness.exposedBuyToken1InBinSpecifiedIn(
      binState, currBinPos, state, 0, lowerPriceX64, upperPriceX64, priceLimitX64
    );

    if (finalBinPos == uint256(currBinPos)) {
      assertEq(outToken1, 0, "No movement should mean zero output");
      assertEq(newState.amountCalculatedScaled, 0, "No movement should mean zero calculated amount");
    }
  }

  // ============ ExactIn/ExactOut Consistency Tests (reverse direction) ============
  uint256 constant TOLERANCE = 1e14; // 1bps tolerance

  /**
   * @notice Test consistency between ExactIn and ExactOut for Token0 (buying token0 with token1)
   * @dev Steps:
   *   1. State A with token0 available
   *   2. ExactIn swap: specify token1 input → get actual token0 output
   *   3. ExactOut swap on fresh State A: use that output as desired → get required token1 input
   *   4. Verify: difference between inputs is within 0.001% tolerance
   */
  function testFuzz_Token0_ExactInExactOut_Consistency(
    uint104 currBinPos,
    uint104 virtualAvailableToken0,
    uint128 virtualSpecifiedIn,
    uint128 lowerPriceX64,
    uint24 spreadE6,
    uint24 feeE6
  ) public view {
    currBinPos = uint104(bound(currBinPos, 0, type(uint104).max - 1));
    virtualAvailableToken0 = uint104(bound(virtualAvailableToken0, 1e6, 1e28));
    lowerPriceX64 = uint128(bound(lowerPriceX64, 1e10, 2e28)); // prices from 1e-9 to ~1e9 in X64 fromat
    spreadE6 = uint24(bound(spreadE6, 1, 1e6 / 100)); // spread from 0.01bps to 1%
    uint128 upperPriceX64 = (lowerPriceX64 * (1e6 + spreadE6)) / 1e6;
    feeE6 = uint24(bound(feeE6, 0, 1e6 / 10)); // fee from 0 to 10%
    uint256 feeX64 = Math.mulDiv(feeE6, Q64, 1e6);

    uint104 availableToken0 =
      uint104((uint256(virtualAvailableToken0) * (type(uint104).max - currBinPos)) / type(uint104).max);

    vm.assume(availableToken0 > 0);

    virtualSpecifiedIn = uint128(bound(virtualSpecifiedIn, 1, 1e18));
    uint256 specifiedInHelp = Math.mulDiv(virtualSpecifiedIn, uint256(availableToken0) * upperPriceX64, 1e18 << 64);

    uint104 specifiedIn = uint104(bound(specifiedInHelp, 1, type(uint104).max));
    // === Step 1: Create State A ===
    BinState memory binStateA = BinState({
      token0BalanceScaled: availableToken0,
      token1BalanceScaled: 0, // N/A
      lengthE6: 0, //N/A
      addFeeBuyE6: 0, // N/A
      addFeeSellE6: 0 // N/A
    });

    // === Step 2: ExactIn swap ===
    SwapMath.SwapState memory stateIn = SwapMath.SwapState({
      amountSpecifiedRemainingScaled: specifiedIn,
      amountCalculatedScaled: 0,
      protocolFeeAmountScaled: 0,
      feeExclusiveInputScaled: 0
    });

    // Copy binState for ExactIn
    BinState memory binStateForIn = BinState({
      token0BalanceScaled: binStateA.token0BalanceScaled,
      token1BalanceScaled: binStateA.token1BalanceScaled,
      lengthE6: binStateA.lengthE6,
      addFeeBuyE6: binStateA.addFeeBuyE6,
      addFeeSellE6: binStateA.addFeeSellE6
    });

    uint256 finalPosIn;
    uint128 outputFromExactIn;
    (finalPosIn, stateIn, outputFromExactIn, binStateForIn) = harness.exposedBuyToken0InBinSpecifiedIn(
      binStateForIn,
      currBinPos,
      stateIn,
      feeX64,
      lowerPriceX64,
      upperPriceX64,
      type(uint128).max // no price limit
    );

    uint128 consumedInputFromExactIn = uint128(specifiedIn - stateIn.amountSpecifiedRemainingScaled);

    // These should be non-zero given our bounds - use assume to filter bad cases
    vm.assume(outputFromExactIn > 0);
    assertGt(consumedInputFromExactIn, 0, "Consumed input for SpecifiedIn should be > 0");

    // === Step 3: ExactOut swap on fresh State A ===
    SwapMath.SwapState memory stateOut = SwapMath.SwapState({
      amountSpecifiedRemainingScaled: outputFromExactIn,
      amountCalculatedScaled: 0,
      protocolFeeAmountScaled: 0,
      feeExclusiveInputScaled: 0
    });

    // Fresh copy of State A
    BinState memory binStateForOut = BinState({
      token0BalanceScaled: binStateA.token0BalanceScaled,
      token1BalanceScaled: binStateA.token1BalanceScaled,
      lengthE6: binStateA.lengthE6,
      addFeeBuyE6: binStateA.addFeeBuyE6,
      addFeeSellE6: binStateA.addFeeSellE6
    });

    uint256 finalPosOut;
    (finalPosOut, stateOut, binStateForOut) = harness.exposedBuyToken0InBinSpecifiedOut(
      binStateForOut,
      currBinPos,
      stateOut,
      feeX64,
      lowerPriceX64,
      upperPriceX64,
      type(uint128).max // no price limit
    );

    uint128 requiredInputFromExactOut = uint128(stateOut.amountCalculatedScaled);

    assertGt(requiredInputFromExactOut, 0, "Required input exactOut should be > 0");

    // === Step 4: Verify consistency ===
    assertLe(requiredInputFromExactOut, consumedInputFromExactIn + 2, "ExactOut input should be <= ExactIn input");

    assertApproxEqRel(
      requiredInputFromExactOut,
      consumedInputFromExactIn,
      2e18 / outputFromExactIn + 2e18 / requiredInputFromExactOut + TOLERANCE,
      "Inputs should be approximately equal"
    );
  }

  /**
   * @notice Test consistency between ExactIn and ExactOut for Token1 (selling token0 for token1)
   * @dev Steps:
   *   1. State A with token1 available
   *   2. ExactIn swap: specify token0 input → get actual token1 output
   *   3. ExactOut swap on fresh State A: use that output as desired → get required token0 input
   *   4. Verify: difference between inputs is within 0.001% tolerance
   */
  function testFuzz_Token1_ExactInExactOut_Consistency(
    uint104 currBinPos,
    uint104 virtualAvailableToken1,
    uint128 virtualSpecifiedIn,
    uint128 lowerPriceX64,
    uint24 spreadE6,
    uint24 feeE6
  ) public view {
    currBinPos = uint104(bound(currBinPos, 1, type(uint104).max));
    virtualAvailableToken1 = uint104(bound(virtualAvailableToken1, 1e6, 1e28));
    lowerPriceX64 = uint128(bound(lowerPriceX64, 1e10, 2e28)); // prices from 1e-9 to ~1e9 in X64 fromat
    spreadE6 = uint24(bound(spreadE6, 1, 1e6 / 100)); // spread from 0.01bps to 1%
    uint128 upperPriceX64 = (lowerPriceX64 * (1e6 + spreadE6)) / 1e6;
    feeE6 = uint24(bound(feeE6, 0, 1e6 / 10)); // fee from 0 to 10%
    uint256 feeX64 = Math.mulDiv(feeE6, Q64, 1e6);

    // Bound to prevent uint104 overflow in token0 balance calculation
    // amountOut / price must fit in uint104
    vm.assume((uint256(virtualAvailableToken1) * Q64) / uint256(lowerPriceX64) < type(uint104).max / 2);

    uint104 availableToken1 = uint104((uint256(virtualAvailableToken1) * currBinPos) / type(uint104).max);

    vm.assume(availableToken1 > 0);

    virtualSpecifiedIn = uint128(bound(virtualSpecifiedIn, 1, 1e18));
    uint256 specifiedInHelp =
      Math.mulDiv(virtualSpecifiedIn, uint256(availableToken1) << 64, uint256(1e18) * uint256(lowerPriceX64));

    uint104 specifiedIn = uint104(bound(specifiedInHelp, 1, type(uint104).max));
    // === Step 1: Create State A ===
    BinState memory binStateA = BinState({
      token0BalanceScaled: 0, // N/A
      token1BalanceScaled: availableToken1,
      lengthE6: 0, //N/A
      addFeeBuyE6: 0, // N/A
      addFeeSellE6: 0 // N/A
    });

    // === Step 2: ExactIn swap ===
    SwapMath.SwapState memory stateIn = SwapMath.SwapState({
      amountSpecifiedRemainingScaled: specifiedIn,
      amountCalculatedScaled: 0,
      protocolFeeAmountScaled: 0,
      feeExclusiveInputScaled: 0
    });

    // Copy binState for ExactIn
    BinState memory binStateForIn = BinState({
      token0BalanceScaled: binStateA.token0BalanceScaled,
      token1BalanceScaled: binStateA.token1BalanceScaled,
      lengthE6: binStateA.lengthE6,
      addFeeBuyE6: binStateA.addFeeBuyE6,
      addFeeSellE6: binStateA.addFeeSellE6
    });

    uint256 finalPosIn;
    uint128 outputFromExactIn;
    (finalPosIn, stateIn, outputFromExactIn, binStateForIn) = harness.exposedBuyToken1InBinSpecifiedIn(
      binStateForIn,
      currBinPos,
      stateIn,
      feeX64,
      lowerPriceX64,
      upperPriceX64,
      0 // no price limit
    );

    uint128 consumedInputFromExactIn = uint128(specifiedIn - stateIn.amountSpecifiedRemainingScaled);

    // These should be non-zero given our bounds - use assume to filter bad cases
    vm.assume(outputFromExactIn > 0);
    assertGt(consumedInputFromExactIn, 0, "Consumed input for SpecifiedIn should be > 0");

    // === Step 3: ExactOut swap on fresh State A ===
    SwapMath.SwapState memory stateOut = SwapMath.SwapState({
      amountSpecifiedRemainingScaled: outputFromExactIn,
      amountCalculatedScaled: 0,
      protocolFeeAmountScaled: 0,
      feeExclusiveInputScaled: 0
    });

    // Fresh copy of State A
    BinState memory binStateForOut = BinState({
      token0BalanceScaled: binStateA.token0BalanceScaled,
      token1BalanceScaled: binStateA.token1BalanceScaled,
      lengthE6: binStateA.lengthE6,
      addFeeBuyE6: binStateA.addFeeBuyE6,
      addFeeSellE6: binStateA.addFeeSellE6
    });

    uint256 finalPosOut;
    (finalPosOut, stateOut, binStateForOut) = harness.exposedBuyToken1InBinSpecifiedOut(
      binStateForOut,
      currBinPos,
      stateOut,
      feeX64,
      lowerPriceX64,
      upperPriceX64,
      0 // no price limit
    );

    uint128 requiredInputFromExactOut = uint128(stateOut.amountCalculatedScaled);

    assertGt(requiredInputFromExactOut, 0, "Required input exactOut should be > 0");

    // === Step 4: Verify consistency ===
    assertLe(requiredInputFromExactOut, consumedInputFromExactIn + 2, "ExactOut input should be <= ExactIn input");

    uint256 diff = requiredInputFromExactOut > consumedInputFromExactIn
      ? requiredInputFromExactOut - consumedInputFromExactIn
      : consumedInputFromExactIn - requiredInputFromExactOut;

    if (diff > 1e14) {
      assertApproxEqRel(
        requiredInputFromExactOut,
        consumedInputFromExactIn,
        1e18 / outputFromExactIn + 2e18 / requiredInputFromExactOut + 5e15, // 0.5% tolerance for X64 fee precision
        "Inputs should be approximately equal"
      );
    }
  }

  // ============ Round-Trip Tests ============
  /// @notice Round trip: token0 only → buy (exactOut) → buy (exactOut) → sell (exactOut) → sell (exactOut)
  function test_roundTrip_token0Only_buyExactOut_sellExactOut() public view {
    BinState memory binState =
      BinState({token0BalanceScaled: 1e18, token1BalanceScaled: 0, lengthE6: 100, addFeeBuyE6: 0, addFeeSellE6: 0});

    uint104 currBinPos = 0;
    uint128 lowerPriceX64 = uint128(Q64);
    uint128 upperPriceX64 = uint128((Q64 * (1e6 + binState.lengthE6)) / 1e6);

    SwapMath.SwapState memory state1 = SwapMath.SwapState({
      amountSpecifiedRemainingScaled: 4e17,
      amountCalculatedScaled: 0,
      protocolFeeAmountScaled: 0,
      feeExclusiveInputScaled: 0
    });

    uint256 nextPos;
    (nextPos,, binState) = harness.exposedBuyToken0InBinSpecifiedOut(
      binState, currBinPos, state1, 0, lowerPriceX64, upperPriceX64, type(uint128).max
    );
    currBinPos = uint104(nextPos);
    SwapMath.SwapState memory state2 = SwapMath.SwapState({
      amountSpecifiedRemainingScaled: 4e17,
      amountCalculatedScaled: 0,
      protocolFeeAmountScaled: 0,
      feeExclusiveInputScaled: 0
    });

    (nextPos,, binState) = harness.exposedBuyToken0InBinSpecifiedOut(
      binState, currBinPos, state2, 0, lowerPriceX64, upperPriceX64, type(uint128).max
    );
    currBinPos = uint104(nextPos);

    SwapMath.SwapState memory state3 = SwapMath.SwapState({
      amountSpecifiedRemainingScaled: binState.token1BalanceScaled / 2,
      amountCalculatedScaled: 0,
      protocolFeeAmountScaled: 0,
      feeExclusiveInputScaled: 0
    });

    (nextPos,, binState) =
      harness.exposedBuyToken1InBinSpecifiedOut(binState, currBinPos, state3, 0, lowerPriceX64, upperPriceX64, 0);
    currBinPos = uint104(nextPos);

    SwapMath.SwapState memory state4 = SwapMath.SwapState({
      amountSpecifiedRemainingScaled: binState.token1BalanceScaled,
      amountCalculatedScaled: 0,
      protocolFeeAmountScaled: 0,
      feeExclusiveInputScaled: 0
    });

    (nextPos,, binState) =
      harness.exposedBuyToken1InBinSpecifiedOut(binState, currBinPos, state4, 0, lowerPriceX64, upperPriceX64, 0);
    currBinPos = uint104(nextPos);
    assertEq(binState.token1BalanceScaled, 0, "Token1 should be zero");
    assertApproxEqAbs(binState.token0BalanceScaled, 1e18, 1e10, "Token0 should return to original");
  }

  /// @notice Round trip: token0 only → buy (exactIn) → sell back
  function test_roundTrip_token0Only_buyExactIn_sellExactOut() public view {
    BinState memory binState =
      BinState({token0BalanceScaled: 1e18, token1BalanceScaled: 0, lengthE6: 100, addFeeBuyE6: 0, addFeeSellE6: 0});

    uint104 currBinPos = 0;
    uint256 nextPos;
    uint128 lowerPriceX64 = uint128(Q64);
    uint128 upperPriceX64 = uint128((Q64 * (1e6 + binState.lengthE6)) / 1e6);

    SwapMath.SwapState memory state1 = SwapMath.SwapState({
      amountSpecifiedRemainingScaled: 4e17,
      amountCalculatedScaled: 0,
      protocolFeeAmountScaled: 0,
      feeExclusiveInputScaled: 0
    });

    (nextPos,,, binState) = harness.exposedBuyToken0InBinSpecifiedIn(
      binState, currBinPos, state1, 0, lowerPriceX64, upperPriceX64, type(uint128).max
    );
    currBinPos = uint104(nextPos);

    SwapMath.SwapState memory state2 = SwapMath.SwapState({
      amountSpecifiedRemainingScaled: 4e17,
      amountCalculatedScaled: 0,
      protocolFeeAmountScaled: 0,
      feeExclusiveInputScaled: 0
    });

    (nextPos,,, binState) = harness.exposedBuyToken0InBinSpecifiedIn(
      binState, currBinPos, state2, 0, lowerPriceX64, upperPriceX64, type(uint128).max
    );
    currBinPos = uint104(nextPos);

    SwapMath.SwapState memory state3 = SwapMath.SwapState({
      amountSpecifiedRemainingScaled: binState.token1BalanceScaled / 2,
      amountCalculatedScaled: 0,
      protocolFeeAmountScaled: 0,
      feeExclusiveInputScaled: 0
    });

    (nextPos,, binState) =
      harness.exposedBuyToken1InBinSpecifiedOut(binState, currBinPos, state3, 0, lowerPriceX64, upperPriceX64, 0);
    currBinPos = uint104(nextPos);

    SwapMath.SwapState memory state4 = SwapMath.SwapState({
      amountSpecifiedRemainingScaled: binState.token1BalanceScaled,
      amountCalculatedScaled: 0,
      protocolFeeAmountScaled: 0,
      feeExclusiveInputScaled: 0
    });

    (nextPos,, binState) =
      harness.exposedBuyToken1InBinSpecifiedOut(binState, currBinPos, state4, 0, lowerPriceX64, upperPriceX64, 0);
    currBinPos = uint104(nextPos);

    assertEq(binState.token1BalanceScaled, 0, "Token1 should be zero");
    assertApproxEqAbs(binState.token0BalanceScaled, 1e18, 1e10, "Token0 should return to original");
  }

  /// @notice Round trip: token1 only → sell (exactOut) sell (exactOut) → buy (exactOut) → buy (exactOut)
  function test_roundTrip_token1Only_sellExactOut_buyExactOut() public view {
    BinState memory binState =
      BinState({token0BalanceScaled: 0, token1BalanceScaled: 1e18, lengthE6: 100, addFeeBuyE6: 0, addFeeSellE6: 0});

    uint104 currBinPos = type(uint104).max;
    uint256 nextPos;
    uint128 lowerPriceX64 = uint128(Q64);
    uint128 upperPriceX64 = uint128((Q64 * (1e6 + binState.lengthE6)) / 1e6);

    SwapMath.SwapState memory state1 = SwapMath.SwapState({
      amountSpecifiedRemainingScaled: 4e17,
      amountCalculatedScaled: 0,
      protocolFeeAmountScaled: 0,
      feeExclusiveInputScaled: 0
    });

    (nextPos,, binState) =
      harness.exposedBuyToken1InBinSpecifiedOut(binState, currBinPos, state1, 0, lowerPriceX64, upperPriceX64, 0);
    currBinPos = uint104(nextPos);

    SwapMath.SwapState memory state2 = SwapMath.SwapState({
      amountSpecifiedRemainingScaled: 4e17,
      amountCalculatedScaled: 0,
      protocolFeeAmountScaled: 0,
      feeExclusiveInputScaled: 0
    });

    (nextPos,, binState) =
      harness.exposedBuyToken1InBinSpecifiedOut(binState, currBinPos, state2, 0, lowerPriceX64, upperPriceX64, 0);
    currBinPos = uint104(nextPos);

    SwapMath.SwapState memory state3 = SwapMath.SwapState({
      amountSpecifiedRemainingScaled: binState.token0BalanceScaled / 2,
      amountCalculatedScaled: 0,
      protocolFeeAmountScaled: 0,
      feeExclusiveInputScaled: 0
    });

    (nextPos,, binState) = harness.exposedBuyToken0InBinSpecifiedOut(
      binState, currBinPos, state3, 0, lowerPriceX64, upperPriceX64, type(uint128).max
    );
    currBinPos = uint104(nextPos);

    SwapMath.SwapState memory state4 = SwapMath.SwapState({
      amountSpecifiedRemainingScaled: binState.token0BalanceScaled,
      amountCalculatedScaled: 0,
      protocolFeeAmountScaled: 0,
      feeExclusiveInputScaled: 0
    });

    (nextPos,, binState) = harness.exposedBuyToken0InBinSpecifiedOut(
      binState, currBinPos, state4, 0, lowerPriceX64, upperPriceX64, type(uint128).max
    );
    currBinPos = uint104(nextPos);

    assertEq(binState.token0BalanceScaled, 0, "Token0 should be zero");
    assertApproxEqAbs(binState.token1BalanceScaled, 1e18, 1e10, "Token1 should return to original");
  }

  /// @notice Round trip: token1 only → sell (exactIn) → buy back
  function test_roundTrip_token1Only_sellExactIn_buyExactOut() public view {
    BinState memory binState =
      BinState({token0BalanceScaled: 0, token1BalanceScaled: 1e18, lengthE6: 100, addFeeBuyE6: 0, addFeeSellE6: 0});

    uint104 currBinPos = type(uint104).max;
    uint256 nextPos;
    uint128 lowerPriceX64 = uint128(Q64);
    uint128 upperPriceX64 = uint128((Q64 * (1e6 + binState.lengthE6)) / 1e6);

    SwapMath.SwapState memory state1 = SwapMath.SwapState({
      amountSpecifiedRemainingScaled: 4e17,
      amountCalculatedScaled: 0,
      protocolFeeAmountScaled: 0,
      feeExclusiveInputScaled: 0
    });

    (nextPos,,, binState) =
      harness.exposedBuyToken1InBinSpecifiedIn(binState, currBinPos, state1, 0, lowerPriceX64, upperPriceX64, 0);
    currBinPos = uint104(nextPos);

    SwapMath.SwapState memory state2 = SwapMath.SwapState({
      amountSpecifiedRemainingScaled: 4e17,
      amountCalculatedScaled: 0,
      protocolFeeAmountScaled: 0,
      feeExclusiveInputScaled: 0
    });

    (nextPos,,, binState) =
      harness.exposedBuyToken1InBinSpecifiedIn(binState, currBinPos, state2, 0, lowerPriceX64, upperPriceX64, 0);
    currBinPos = uint104(nextPos);

    SwapMath.SwapState memory state3 = SwapMath.SwapState({
      amountSpecifiedRemainingScaled: binState.token0BalanceScaled / 2,
      amountCalculatedScaled: 0,
      protocolFeeAmountScaled: 0,
      feeExclusiveInputScaled: 0
    });

    (nextPos,, binState) = harness.exposedBuyToken0InBinSpecifiedOut(
      binState, currBinPos, state3, 0, lowerPriceX64, upperPriceX64, type(uint128).max
    );
    currBinPos = uint104(nextPos);

    SwapMath.SwapState memory state4 = SwapMath.SwapState({
      amountSpecifiedRemainingScaled: binState.token0BalanceScaled,
      amountCalculatedScaled: 0,
      protocolFeeAmountScaled: 0,
      feeExclusiveInputScaled: 0
    });

    (nextPos,, binState) = harness.exposedBuyToken0InBinSpecifiedOut(
      binState, currBinPos, state4, 0, lowerPriceX64, upperPriceX64, type(uint128).max
    );
    currBinPos = uint104(nextPos);

    assertEq(binState.token0BalanceScaled, 0, "Token0 should be zero");
    assertApproxEqAbs(binState.token1BalanceScaled, 1e18, 6e15, "Token1 should return to original");
  }
}
