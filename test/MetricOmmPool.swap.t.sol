// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {GateExtension} from "./mocks/extensions/GateExtension.sol";
import {MetricOmmPoolBaseTest, Q64} from "./MetricOmmPool.base.t.sol";
import {IMetricOmmPoolActions} from "../contracts/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {BinState} from "../contracts/types/PoolStorage.sol";

contract MetricOmmPoolSwapTest is MetricOmmPoolBaseTest {
  uint256 public constant SWAPPER_INDEX = 0;
  address public swapper;

  function setUp() public override {
    super.setUp();
    swapper = users[SWAPPER_INDEX];

    // Add initial liquidity across a range of ticks
    // Range [-5, 4] matches default pool bin indices (LOWEST..HIGHEST)
    uint256 liquidityProviderIndex = 1;
    _addLiquidity(liquidityProviderIndex, -5, 4, 100000, 0);
  }

  function _deployPoolWithSwapGate() internal returns (GateExtension extension) {
    (BinState[] memory nonNegativeBinStates, BinState[] memory negativeBinStates) = _defaultBinStateArrays();
    extension = new GateExtension();
    pool = _deployPoolAndRegister(
      PoolDeployParams({
        priceProvider: address(oracle),
        extensions: _singleExtensionPoolExtensions(address(extension)),
        extensionOrders: _extensionOrdersWithBeforeSwap(),
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

  function test_swap_gateExtension_revertsWhenSwapClosed() public {
    GateExtension extension = _deployPoolWithSwapGate();
    _addLiquidity(1, -5, 4, 100000, 0);
    extension.setAllowSwap(false);
    vm.expectRevert(IMetricOmmPoolActions.NotAllowedToSwap.selector);
    _swap(SWAPPER_INDEX, swapper, false, int128(1000), type(uint128).max);
  }

  function test_swap_gateExtension_allowsSwapWhenOpen() public {
    GateExtension extension = _deployPoolWithSwapGate();
    _addLiquidity(1, -5, 4, 100000, 0);
    extension.setAllowSwap(true);

    (int256 amount0, int256 amount1) = _swap(SWAPPER_INDEX, swapper, false, int128(1000), type(uint128).max);
    assertLt(amount0, 0, "amount0 should be negative (output)");
    assertGt(amount1, 0, "amount1 should be positive (input)");
  }

  // ============ Swap Token1 for Token0 (Exact Input) Tests ============

  /// @notice Test basic exact input swap: token1 -> token0
  function test_swapExactInput_token1ForToken0_basic() public {
    uint128 amountIn = 1000;
    uint128 priceLimitX64 = type(uint128).max; // No price limit

    address caller = _getCallerAddress(SWAPPER_INDEX);
    uint256 token0Before = token0.balanceOf(swapper);
    uint256 token1Before = token1.balanceOf(caller); // Input comes from caller

    (int256 amount0, int256 amount1) = _swap(
      SWAPPER_INDEX,
      swapper, // recipient
      false, // zeroForOne = false means token1 -> token0
      _i128ExactIn(amountIn), // positive = exact input
      priceLimitX64
    );

    uint256 token0After = token0.balanceOf(swapper);
    uint256 token1After = token1.balanceOf(caller); // Input comes from caller

    // amount0 should be negative (output)
    assertLt(amount0, 0, "amount0 should be negative (output)");
    // amount1 should be positive (input)
    assertGt(amount1, 0, "amount1 should be positive (input)");
    assertEq(amount1, _i128ExactIn(amountIn), "amount1 should equal input amount");

    // Check actual token transfers
    assertEq(token0After - token0Before, _u128FromNegDelta(amount0), "Token0 received mismatch");
    assertEq(token1Before - token1After, _u128FromNonNegDelta(amount1), "Token1 spent mismatch");
  }

  /// @notice Test exact input swap with multiple amounts
  function test_swapExactInput_token1ForToken0_multipleAmounts() public {
    uint128[4] memory amounts = [uint128(100), uint128(1000), uint128(10000), uint128(50000)];

    for (uint256 i = 0; i < amounts.length; i++) {
      // Reset state by redeploying for each test
      setUp();

      uint128 amountIn = amounts[i];
      uint256 token0Before = token0.balanceOf(swapper);

      (int256 amount0, int256 amount1) =
        _swap(
          SWAPPER_INDEX,
          swapper,
          false, // token1 -> token0
          _i128ExactIn(amountIn),
          type(uint128).max
        );

      uint256 token0After = token0.balanceOf(swapper);

      assertLt(amount0, 0, "amount0 should be negative");
      assertEq(amount1, _i128ExactIn(amountIn), "amount1 should equal input");
      assertEq(token0After - token0Before, _u128FromNegDelta(amount0), "Token0 received mismatch");
    }
  }

  // ============ Swap Token1 for Token0 (Exact Output) Tests ============

  /// @notice Test basic exact output swap: token1 -> token0
  function test_swapExactOutput_token1ForToken0_basic() public {
    uint128 amountOut = 1000;
    uint128 priceLimitX64 = type(uint128).max; // No price limit

    address caller = _getCallerAddress(SWAPPER_INDEX);
    uint256 token0Before = token0.balanceOf(swapper);
    uint256 token1Before = token1.balanceOf(caller); // Input from caller

    (int256 amount0, int256 amount1) = _swap(
      SWAPPER_INDEX,
      swapper, // recipient
      false, // zeroForOne = false means token1 -> token0
      _i128ExactOut(amountOut), // negative = exact output
      priceLimitX64
    );

    uint256 token0After = token0.balanceOf(swapper);
    uint256 token1After = token1.balanceOf(caller); // Input from caller

    // amount0 should be negative (output)
    assertEq(amount0, _i128ExactOut(amountOut), "amount0 should equal negative of requested output");
    // amount1 should be positive (input)
    assertGt(amount1, 0, "amount1 should be positive (input)");

    // Check actual token transfers
    assertEq(token0After - token0Before, amountOut, "Token0 received mismatch");
    assertEq(token1Before - token1After, _u128FromNonNegDelta(amount1), "Token1 spent mismatch");
  }

  /// @notice Test exact output swap with multiple amounts
  function test_swapExactOutput_token1ForToken0_multipleAmounts() public {
    uint128[4] memory amounts = [uint128(100), uint128(1000), uint128(10000), uint128(50000)];

    for (uint256 i = 0; i < amounts.length; i++) {
      // Reset state by redeploying for each test
      setUp();

      uint128 amountOut = amounts[i];
      address caller = _getCallerAddress(SWAPPER_INDEX);
      uint256 token1Before = token1.balanceOf(caller); // Input from caller

      (int256 amount0, int256 amount1) =
        _swap(
          SWAPPER_INDEX,
          swapper,
          false, // token1 -> token0
          _i128ExactOut(amountOut),
          type(uint128).max
        );

      uint256 token1After = token1.balanceOf(caller); // Input from caller

      assertEq(amount0, _i128ExactOut(amountOut), "amount0 should equal requested output");
      assertGt(amount1, 0, "amount1 should be positive");
      assertEq(token1Before - token1After, _u128FromNonNegDelta(amount1), "Token1 spent mismatch");
    }
  }

  // ============ State Change Tests ============

  /// @notice Test that currentTick advances as we swap through bins
  function test_swap_advancesThroughBins() public {
    int16 initialTick = _getCurBinIdx();
    assertEq(initialTick, 0, "Initial tick should be 0");

    // Large swap to move through multiple bins
    uint128 largeAmountIn = 500000;

    _swap(SWAPPER_INDEX, swapper, false, _i128ExactIn(largeAmountIn), type(uint128).max);

    int16 finalTick = _getCurBinIdx();
    assertGt(finalTick, initialTick, "Tick should advance after large swap");
  }

  /// @notice Test that bin balances update correctly after swap
  function test_swap_updatesBinBalances() public {
    // Get initial bin state at tick 0
    uint104 sharesBefore = _getBinTotalShares(0);
    (uint104 token0Before, uint104 token1Before,,,) = _getBinState(0);

    uint128 amountIn = 5000;

    _swap(SWAPPER_INDEX, swapper, false, _i128ExactIn(amountIn), type(uint128).max);

    // Get final bin state
    uint104 sharesAfter = _getBinTotalShares(0);
    (uint104 token0After, uint104 token1After,,,) = _getBinState(0);

    // Shares should not change during swap
    assertEq(sharesAfter, sharesBefore, "Shares should not change during swap");

    // Token0 should decrease (sold to swapper)
    assertLe(token0After, token0Before, "Token0 should decrease or stay same");

    // Token1 should increase (received from swapper)
    assertGe(token1After, token1Before, "Token1 should increase or stay same");
  }

  // ============ Price Limit Tests ============

  /// @notice Test swap with price limit that stops execution
  function test_swap_respectsPriceLimit() public {
    // Set a price limit just slightly above current price
    // Current price is around Q64 (1:1), set limit to 1.01x
    uint128 priceLimitX64 = uint128((uint256(Q64) * 10001) / 10000);

    // Use exact output with a large requested amount
    // This way we can see if price limit stops us before getting all we want
    uint128 largeAmountOut = 500000;

    (int256 amount0,) =
      _swap(
        SWAPPER_INDEX,
        swapper,
        false,
        _i128ExactOut(largeAmountOut), // negative = exact output
        priceLimitX64
      );

    // Should receive less output due to price limit
    // The swap should stop before getting all requested output
    assertLt(_u128FromNegDelta(amount0), largeAmountOut, "Should not get all output due to price limit");
  }

  // ============ Fuzz Tests ============

  /// @notice Fuzz test for exact input swaps
  function testFuzz_swapExactInput_token1ForToken0(uint128 amountIn) public {
    // Bound amount to reasonable range
    amountIn = uint128(bound(amountIn, 100, 100000));

    address caller = _getCallerAddress(SWAPPER_INDEX);
    uint256 token0Before = token0.balanceOf(swapper);
    uint256 token1Before = token1.balanceOf(caller); // Input from caller

    (int256 amount0, int256 amount1) = _swap(SWAPPER_INDEX, swapper, false, _i128ExactIn(amountIn), type(uint128).max);

    uint256 token0After = token0.balanceOf(swapper);
    uint256 token1After = token1.balanceOf(caller); // Input from caller

    // Basic invariants
    assertLt(amount0, 0, "amount0 should be negative");
    assertGt(amount1, 0, "amount1 should be positive");
    // Note: amount1 may be less than amountIn if drift limit or price limit is hit
    assertLe(_u128FromNonNegDelta(amount1), amountIn, "amount1 should not exceed input");
    assertEq(token0After - token0Before, _u128FromNegDelta(amount0), "Token0 balance mismatch");
    assertEq(token1Before - token1After, _u128FromNonNegDelta(amount1), "Token1 balance mismatch");
  }

  /// @notice Fuzz test for exact output swaps
  function testFuzz_swapExactOutput_token1ForToken0(uint128 amountOut) public {
    // Bound amount to reasonable range (must be less than available liquidity)
    amountOut = uint128(bound(amountOut, 100, 50000));

    address caller = _getCallerAddress(SWAPPER_INDEX);
    uint256 token0Before = token0.balanceOf(swapper);
    uint256 token1Before = token1.balanceOf(caller); // Input from caller

    (int256 amount0, int256 amount1) = _swap(SWAPPER_INDEX, swapper, false, _i128ExactOut(amountOut), type(uint128).max);

    uint256 token0After = token0.balanceOf(swapper);
    uint256 token1After = token1.balanceOf(caller); // Input from caller

    // Basic invariants
    assertEq(amount0, _i128ExactOut(amountOut), "amount0 should equal negative output");
    assertGt(amount1, 0, "amount1 should be positive");
    assertEq(token0After - token0Before, amountOut, "Token0 balance mismatch");
    assertEq(token1Before - token1After, _u128FromNonNegDelta(amount1), "Token1 balance mismatch");
  }

  // ============ Edge Cases ============

  /// @notice Test swap when there's insufficient liquidity
  function test_swap_insufficientLiquidity() public {
    // Try to swap more than available using exact input
    // This should cap the output at what's available
    uint128 hugeAmountIn = 10000000; // Much more than needed for all liquidity

    uint256 token0PoolBalance = token0.balanceOf(address(pool));

    (int256 amount0, int256 amount1) =
      _swap(
        SWAPPER_INDEX,
        swapper,
        false,
        _i128ExactIn(hugeAmountIn), // exact input - positive
        type(uint128).max
      );

    // Should receive at most what's available (will hit drift limit before exhausting liquidity)
    assertLe(_u128FromNegDelta(amount0), token0PoolBalance, "Cannot receive more than pool balance");
    // Should use less input than specified since we hit limits
    assertLt(_u128FromNonNegDelta(amount1), hugeAmountIn, "Should not use all input due to drift limit");
  }

  /// @notice Test swap with zero amount should revert with InvalidAmount
  function test_swap_zeroAmount() public {
    vm.expectRevert(IMetricOmmPoolActions.InvalidAmount.selector);
    _swap(SWAPPER_INDEX, swapper, false, 0, type(uint128).max);
  }

  function test_swap_revertsWhenPaused() public {
    pool.setPause(1);

    vm.expectRevert(IMetricOmmPoolActions.PoolPaused.selector);
    _swap(SWAPPER_INDEX, swapper, false, 1000, type(uint128).max);
  }

  function test_modifyLiquidity_allowedWhenPaused() public {
    pool.setPause(1);
    _addLiquidity(2, -2, 2, 1_000, 123);
  }

  // ============ Pool Balance Delta Tests ============

  function test_swap_poolBalanceMatchesDelta_token1ForToken0_exactInput() public {
    uint128 amountIn = 5000;

    uint256 poolToken0Before = token0.balanceOf(address(pool));
    uint256 poolToken1Before = token1.balanceOf(address(pool));

    (int256 amount0Delta, int256 amount1Delta) =
      _swap(SWAPPER_INDEX, swapper, false, _i128ExactIn(amountIn), type(uint128).max);

    uint256 poolToken0After = token0.balanceOf(address(pool));
    uint256 poolToken1After = token1.balanceOf(address(pool));

    int256 actualToken0Change = _i256FromBalance(poolToken0After) - _i256FromBalance(poolToken0Before);
    int256 actualToken1Change = _i256FromBalance(poolToken1After) - _i256FromBalance(poolToken1Before);

    assertEq(actualToken0Change, amount0Delta, "Pool token0 balance change should match amount0Delta");
    assertEq(actualToken1Change, amount1Delta, "Pool token1 balance change should match amount1Delta");
    assertLt(amount0Delta, 1, "amount0Delta should be non-positive (pool sends token0)");
    assertGt(amount1Delta, -1, "amount1Delta should be non-negative (pool receives token1)");
  }

  function test_swap_poolBalanceMatchesDelta_token1ForToken0_exactOutput() public {
    uint128 amountOut = 5000;

    uint256 poolToken0Before = token0.balanceOf(address(pool));
    uint256 poolToken1Before = token1.balanceOf(address(pool));

    (int256 amount0Delta, int256 amount1Delta) =
      _swap(SWAPPER_INDEX, swapper, false, _i128ExactOut(amountOut), type(uint128).max);

    uint256 poolToken0After = token0.balanceOf(address(pool));
    uint256 poolToken1After = token1.balanceOf(address(pool));

    int256 actualToken0Change = _i256FromBalance(poolToken0After) - _i256FromBalance(poolToken0Before);
    int256 actualToken1Change = _i256FromBalance(poolToken1After) - _i256FromBalance(poolToken1Before);

    assertEq(actualToken0Change, amount0Delta, "Pool token0 balance change should match amount0Delta");
    assertEq(actualToken1Change, amount1Delta, "Pool token1 balance change should match amount1Delta");
  }

  function test_swap_poolBalanceMatchesDelta_token0ForToken1_exactInput() public {
    uint128 amountIn = 5000;

    uint256 poolToken0Before = token0.balanceOf(address(pool));
    uint256 poolToken1Before = token1.balanceOf(address(pool));

    (int256 amount0Delta, int256 amount1Delta) = _swap(SWAPPER_INDEX, swapper, true, _i128ExactIn(amountIn), 0);

    uint256 poolToken0After = token0.balanceOf(address(pool));
    uint256 poolToken1After = token1.balanceOf(address(pool));

    int256 actualToken0Change = _i256FromBalance(poolToken0After) - _i256FromBalance(poolToken0Before);
    int256 actualToken1Change = _i256FromBalance(poolToken1After) - _i256FromBalance(poolToken1Before);

    assertEq(actualToken0Change, amount0Delta, "Pool token0 balance change should match amount0Delta");
    assertEq(actualToken1Change, amount1Delta, "Pool token1 balance change should match amount1Delta");
    assertGt(amount0Delta, -1, "amount0Delta should be non-neagtive (pool receives token0)");
    assertLt(amount1Delta, 1, "amount1Delta should be non-positive (pool sends token1)");
  }

  function test_swap_poolBalanceMatchesDelta_token0ForToken1_exactOutput() public {
    uint128 amountOut = 5000;

    uint256 poolToken0Before = token0.balanceOf(address(pool));
    uint256 poolToken1Before = token1.balanceOf(address(pool));

    (int256 amount0Delta, int256 amount1Delta) = _swap(SWAPPER_INDEX, swapper, true, _i128ExactOut(amountOut), 0);

    uint256 poolToken0After = token0.balanceOf(address(pool));
    uint256 poolToken1After = token1.balanceOf(address(pool));

    int256 actualToken0Change = _i256FromBalance(poolToken0After) - _i256FromBalance(poolToken0Before);
    int256 actualToken1Change = _i256FromBalance(poolToken1After) - _i256FromBalance(poolToken1Before);

    assertEq(actualToken0Change, amount0Delta, "Pool token0 balance change should match amount0Delta");
    assertEq(actualToken1Change, amount1Delta, "Pool token1 balance change should match amount1Delta");
  }

  function testFuzz_swap_poolBalanceMatchesDelta(uint128 amount, bool zeroForOne, bool exactInput) public {
    amount = uint128(bound(amount, 100, 50000));

    uint256 poolToken0Before = token0.balanceOf(address(pool));
    uint256 poolToken1Before = token1.balanceOf(address(pool));

    int128 amountSpecified = exactInput ? _i128ExactIn(amount) : _i128ExactOut(amount);
    uint128 priceLimit = zeroForOne ? 0 : type(uint128).max;

    (int256 amount0Delta, int256 amount1Delta) = _swap(SWAPPER_INDEX, swapper, zeroForOne, amountSpecified, priceLimit);

    uint256 poolToken0After = token0.balanceOf(address(pool));
    uint256 poolToken1After = token1.balanceOf(address(pool));

    int256 actualToken0Change = _i256FromBalance(poolToken0After) - _i256FromBalance(poolToken0Before);
    int256 actualToken1Change = _i256FromBalance(poolToken1After) - _i256FromBalance(poolToken1Before);

    assertEq(actualToken0Change, amount0Delta, "Pool token0 balance change should match amount0Delta");
    assertEq(actualToken1Change, amount1Delta, "Pool token1 balance change should match amount1Delta");
  }

  // ============ Bin State Update Tests ============

  /// @notice Test that bin state (token balances in bins) is updated after swap token1 -> token0
  /// @dev This test ensures the critical bug where binState was not written back to storage is caught
  function test_swap_binStateUpdated_token1ForToken0() public {
    // Get bin state before swap
    (uint104 token0BalanceBefore, uint104 token1BalanceBefore,,,) = _getBinState(0);

    uint128 amountIn = 10000;

    (int256 amount0Delta, int256 amount1Delta) = _swap(
      SWAPPER_INDEX,
      swapper,
      false, // zeroForOne = false means token1 -> token0
      _i128ExactIn(amountIn),
      type(uint128).max
    );

    // Get bin state after swap
    (uint104 token0BalanceAfter, uint104 token1BalanceAfter,,,) = _getBinState(0);

    // When swapping token1 for token0:
    // - token0 in bin should DECREASE (we're buying token0)
    // - token1 in bin should INCREASE (we're adding token1)
    if (amount0Delta < 0) {
      // We received token0, so bin should have less token0
      assertLt(token0BalanceAfter, token0BalanceBefore, "Bin token0 balance should decrease after token1->token0 swap");
    }
    if (amount1Delta > 0) {
      // We spent token1, so bin should have more token1
      assertGt(token1BalanceAfter, token1BalanceBefore, "Bin token1 balance should increase after token1->token0 swap");
    }
  }

  /// @notice Test that bin state (token balances in bins) is updated after swap token0 -> token1
  /// @dev This test ensures the critical bug where binState was not written back to storage is caught
  function test_swap_binStateUpdated_token0ForToken1() public {
    // For token0 -> token1 swap (zeroForOne=true), we go DOWN in price (negative bin direction)
    // Bin 0 starts with token0 but no token1, so the swap goes to bin -1 which has token1
    // We check bin -1 since that's where the swap actually happens
    (uint104 token0BalanceBefore, uint104 token1BalanceBefore,,,) = _getBinState(-1);

    uint128 amountIn = 10000;

    (int256 amount0Delta, int256 amount1Delta) = _swap(
      SWAPPER_INDEX,
      swapper,
      true, // zeroForOne = true means token0 -> token1
      _i128ExactIn(amountIn),
      0 // price limit (0 means no limit for this direction)
    );

    // Get bin state after swap
    (uint104 token0BalanceAfter, uint104 token1BalanceAfter,,,) = _getBinState(-1);

    // When swapping token0 for token1:
    // - token0 in bin should INCREASE (we're adding token0)
    // - token1 in bin should DECREASE (we're buying token1)
    if (amount0Delta > 0) {
      // We spent token0, so bin should have more token0
      assertGt(token0BalanceAfter, token0BalanceBefore, "Bin token0 balance should increase after token0->token1 swap");
    }
    if (amount1Delta < 0) {
      // We received token1, so bin should have less token1
      assertLt(token1BalanceAfter, token1BalanceBefore, "Bin token1 balance should decrease after token0->token1 swap");
    }
  }

  /// @notice Test that bin state changes are consistent with actual token transfers
  /// @dev Verifies the sum of all bin changes equals the swap amounts
  function test_swap_binStateChanges_matchSwapAmounts() public {
    // Record all bin states before swap (for bins in our liquidity range)
    uint256 totalToken0InBinsBefore = 0;
    uint256 totalToken1InBinsBefore = 0;

    for (int8 binIdx = -5; binIdx <= 4; binIdx++) {
      (uint104 t0, uint104 t1,,,) = _getBinState(binIdx);
      totalToken0InBinsBefore += t0;
      totalToken1InBinsBefore += t1;
    }

    uint128 amountIn = 50000;

    (int256 amount0Delta, int256 amount1Delta) =
      _swap(
        SWAPPER_INDEX,
        swapper,
        false, // token1 -> token0
        _i128ExactIn(amountIn),
        type(uint128).max
      );

    // Record all bin states after swap
    uint256 totalToken0InBinsAfter = 0;
    uint256 totalToken1InBinsAfter = 0;

    for (int8 binIdx = -5; binIdx <= 4; binIdx++) {
      (uint104 t0, uint104 t1,,,) = _getBinState(binIdx);
      totalToken0InBinsAfter += t0;
      totalToken1InBinsAfter += t1;
    }

    // Calculate changes
    int256 token0BinChange = _i256FromBalance(totalToken0InBinsAfter) - _i256FromBalance(totalToken0InBinsBefore);
    int256 token1BinChange = _i256FromBalance(totalToken1InBinsAfter) - _i256FromBalance(totalToken1InBinsBefore);

    // The bin changes should match the swap amounts (accounting for protocol fees)
    // amount0Delta is negative (output) -> bins should have less token0 -> negative change
    // amount1Delta is positive (input) -> bins should have more token1 -> positive change (minus protocol fee)

    assertEq(token0BinChange, amount0Delta, "Total token0 change in bins should match amount0Delta");

    // token1 change should be approximately amount1Delta minus protocol fees
    // Since protocol fees are taken from token1, the bin gets less than amount1Delta
    assertLe(
      token1BinChange,
      amount1Delta,
      "Total token1 change in bins should be <= amount1Delta (some goes to protocol fees)"
    );
    assertGt(token1BinChange, 0, "Total token1 in bins should increase");
  }

  // ============================================================================
  // Exact Input Consumption Tests
  // Verify that specifiedInput swaps consume exactly amountSpecified when:
  // 1. Price limit is not reached
  // 2. Available liquidity is not exhausted
  // 3. Drift limit is not reached
  //
  // NOTE: There appears to be an asymmetry between directions:
  // - token1->token0: consumes exactly specified amount
  // - token0->token1: may consume slightly less than specified (rounding?)
  // ============================================================================

  /// @notice Exact input token1->token0: when liquidity is sufficient and no price limit,
  /// the consumed amount should equal amountSpecified
  function test_exactInput_consumesExactAmount_token1ForToken0() public {
    uint128 amountIn = 5000;

    (int256 amount0Delta, int256 amount1Delta) = _swap(
      SWAPPER_INDEX,
      swapper,
      false, // token1 -> token0
      _i128ExactIn(amountIn),
      type(uint128).max // no price limit
    );

    assertEq(
      _u128FromNonNegDelta(amount1Delta),
      amountIn,
      "Consumed amount should equal specified input when liquidity sufficient and no price limit"
    );
    assertLt(amount0Delta, 0, "Should receive some token0");
  }

  /// @notice Exact input token0->token1: should consume exactly the specified amount
  /// when there's sufficient liquidity and no price limit is hit
  function test_exactInput_consumesExactAmount_token0ForToken1() public {
    uint128 amountIn = 5000;

    (int256 amount0Delta, int256 amount1Delta) = _swap(
      SWAPPER_INDEX,
      swapper,
      true, // token0 -> token1
      _i128ExactIn(amountIn),
      0 // no price limit (0 for zeroForOne=true direction)
    );

    assertEq(
      _u128FromNonNegDelta(amount0Delta),
      amountIn,
      "Consumed amount should equal specified input when liquidity sufficient and no price limit"
    );
    assertLt(amount1Delta, 0, "Should receive some token1");
  }

  /// @notice Fuzz: Exact input should consume exact amount when within liquidity bounds
  function testFuzz_exactInput_consumesExactAmount_token1ForToken0(uint128 amountIn) public {
    // Bound to amounts that won't hit drift limit (small relative to liquidity)
    amountIn = uint128(bound(amountIn, 100, 3000));

    (int256 amount0Delta, int256 amount1Delta) =
      _swap(SWAPPER_INDEX, swapper, false, _i128ExactIn(amountIn), type(uint128).max);

    assertEq(_u128FromNonNegDelta(amount1Delta), amountIn, "Should consume exactly amountSpecified for small swaps");
    assertLt(amount0Delta, 0, "Should receive token0");
  }

  /// @notice Fuzz: Exact input token0->token1 should consume exact amount when within bounds
  function testFuzz_exactInput_consumesExactAmount_token0ForToken1(uint128 amountIn) public {
    // Bound to amounts that won't hit drift limit (small relative to liquidity)
    amountIn = uint128(bound(amountIn, 100, 3000));

    (int256 amount0Delta, int256 amount1Delta) = _swap(SWAPPER_INDEX, swapper, true, _i128ExactIn(amountIn), 0);

    assertEq(_u128FromNonNegDelta(amount0Delta), amountIn, "Should consume exactly amountSpecified for small swaps");
    assertLt(amount1Delta, 0, "Should receive token1");
  }

  /// @notice When exact input hits drift limit, consumed amount should be less than specified
  function test_exactInput_consumesLess_whenDriftLimitHit_token1ForToken0() public {
    // Large swap that will hit drift limit (MAX_DRIFT is 5%)
    // Need a VERY large amount to hit drift on token1->token0 direction
    uint128 hugeAmountIn = 10000000;

    (int256 amount0Delta, int256 amount1Delta) =
      _swap(SWAPPER_INDEX, swapper, false, _i128ExactIn(hugeAmountIn), type(uint128).max);

    assertLt(
      _u128FromNonNegDelta(amount1Delta), hugeAmountIn, "Should consume less than specified when drift limit hit"
    );
    assertGt(amount1Delta, 0, "Should have consumed some input");
    assertLt(amount0Delta, 0, "Should have received some output");
  }

  /// @notice When exact input hits drift limit, consumed amount should be less than specified
  function test_exactInput_consumesLess_whenDriftLimitHit_token0ForToken1() public {
    // Large swap that will hit drift limit
    uint128 hugeAmountIn = 10000000;

    (int256 amount0Delta, int256 amount1Delta) = _swap(SWAPPER_INDEX, swapper, true, _i128ExactIn(hugeAmountIn), 0);

    assertLt(
      _u128FromNonNegDelta(amount0Delta), hugeAmountIn, "Should consume less than specified when drift limit hit"
    );
    assertGt(amount0Delta, 0, "Should have consumed some input");
    assertLt(amount1Delta, 0, "Should have received some output");
  }

  /// @notice Verify invariant: consumed <= specified for exact input swaps
  function testFuzz_exactInput_consumedNeverExceedsSpecified(uint128 amountIn, bool zeroForOne, uint128 priceLimit)
    public
  {
    amountIn = uint128(bound(amountIn, 100, 100000));

    // Set reasonable price limits
    if (zeroForOne) {
      priceLimit = uint128(bound(priceLimit, 0, _q64Uint128()));
    } else {
      priceLimit = uint128(bound(priceLimit, _q64Uint128(), type(uint128).max));
    }

    (int256 amount0Delta, int256 amount1Delta) =
      _swap(SWAPPER_INDEX, swapper, zeroForOne, _i128ExactIn(amountIn), priceLimit);

    if (zeroForOne) {
      assertLe(_u128FromNonNegDelta(amount0Delta), amountIn, "Token0 consumed should never exceed specified input");
    } else {
      assertLe(_u128FromNonNegDelta(amount1Delta), amountIn, "Token1 consumed should never exceed specified input");
    }
  }

  // ============ Bin Boundary Guard Tests ============
  //
  // When excess tokens sit in the pool (e.g. accidental direct transfer),
  // balance0()/balance1() exceeds the sum tracked in bins.  Without
  // HIGHEST_BIN / LOWEST_BIN guards the swap loop would traverse beyond
  // valid bins indefinitely and revert with OutOfGas (or int16 overflow).
  //
  // Each test donates token0 or token1 directly, then swaps with the
  // price limit wide open (drift allows 5 %, bins only span 2.6 %).

  /// @notice Going UP (token1→token0) exact-output with donated token0
  function test_swap_terminatesAtHighestBin_specifiedOutput() public {
    // Donate token0 so balance0() > bin totals → amountOutScaled overshoot
    token0.mint(address(pool), 10_000_000);

    (int256 amount0, int256 amount1) =
      _swap(SWAPPER_INDEX, swapper, false, _i128ExactOut(uint128(10_000_000)), type(uint128).max);

    // Should still terminate; partial fill is fine
    assertLt(amount0, 0, "Should receive some token0");
    assertGt(amount1, 0, "Should pay some token1");
  }

  /// @notice Going UP (token1→token0) exact-input with donated token0
  function test_swap_terminatesAtHighestBin_specifiedInput() public {
    // Donate token0 so totalAvailableToken0Scaled > 0 past all bins
    token0.mint(address(pool), 10_000_000);

    (int256 amount0, int256 amount1) =
      _swap(SWAPPER_INDEX, swapper, false, _i128ExactIn(uint128(10_000_000)), type(uint128).max);

    assertLt(amount0, 0, "Should receive some token0");
    assertGt(amount1, 0, "Should pay some token1");
  }

  /// @notice Going DOWN (token0→token1) exact-output with donated token1
  function test_swap_terminatesAtLowestBin_specifiedOutput() public {
    // Donate token1 so balance1() > bin totals → amountOutScaled overshoot
    token1.mint(address(pool), 10_000_000);

    (int256 amount0, int256 amount1) = _swap(SWAPPER_INDEX, swapper, true, _i128ExactOut(uint128(10_000_000)), 0);

    assertGt(amount0, 0, "Should pay some token0");
    assertLt(amount1, 0, "Should receive some token1");
  }

  /// @notice Going DOWN (token0→token1) exact-input with donated token1
  function test_swap_terminatesAtLowestBin_specifiedInput() public {
    // Donate token1 so totalAvailableToken1Scaled > 0 past all bins
    token1.mint(address(pool), 10_000_000);

    (int256 amount0, int256 amount1) = _swap(SWAPPER_INDEX, swapper, true, _i128ExactIn(uint128(10_000_000)), 0);

    assertGt(amount0, 0, "Should pay some token0");
    assertLt(amount1, 0, "Should receive some token1");
  }
}
