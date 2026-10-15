# Swap Logic Within a Single Bin (Specified In / Specified Out)

This document explains the swap logic inside a single bin, with a focus on **specified out** and **specified in** swaps, and derives the analytic approximation used for specified‑in. It closes with fee-sizing guidance and bin balance limits relevant to pool deployers.

The formulas here match the current implementation assumptions:

- Prices are **Q64.64** fixed‑point whole-token ratios; balances and token amounts use internal scaled units.
- Bin position $c$ is in $[0, M]$ where $M$ is `type(uint104).max`.
- The bin price curve is **linear in position**.
- Bin bounds $P_L$, $P_U$ are **effective (fee-inclusive) prices**: the base spread, per-bin add fee and notional fee are already folded into them (`FeeMath.effectivePriceX64`), so the in-bin formulas below carry no fee factor.

---

## 1. Notation

| Symbol     | Meaning                                                                                     |
| ---------- | ------------------------------------------------------------------------------------------- |
| $T_0$      | token0 balance in the bin                                                                   |
| $T_1$      | token1 balance in the bin                                                                   |
| $M$        | max bin position = `type(uint104).max`                                                      |
| $c$        | current position in bin (0..M)                                                              |
| $d$        | position move during swap (to the right when buying token0, to the left when buying token1) |
| $P_L$      | lower effective price bound of the bin (Q64.64)                                             |
| $P_U$      | upper effective price bound of the bin (Q64.64)                                             |
| $\Delta P$ | $P_U - P_L$                                                                                 |
| $P(x)$     | price at position $x$                                                                       |
| $P_c$      | price at position $c$                                                                       |
| $f$        | total fee rate of the swap direction                                                        |

Price curve inside the bin:

$$
P(x) = P_L + \frac{\Delta P \cdot x}{M}
$$

---

## 2. Output vs Position Relationship

These are the continuous geometric relationships implied by the bin accounting, before integer rounding:

### Buy token0 (move right)

If we move from $c$ to $c+d$ by **buying token0**, the fraction of token0 removed from the bin is linear in $d$:

$$
\text{out}_0 = T_0 \cdot \frac{d}{M-c}
$$

### Buy token1 (move left)

If we move from $c$ to $c-d$ by **buying token1**, the fraction of token1 removed is:

$$
\text{out}_1 = T_1 \cdot \frac{d}{c}
$$

---

## 3. Specified Out Swaps

For specified out, $\text{out}$ is known and we solve for $d$ directly. Then input is computed using average price.

### 3.1 Buy token0 (specified out)

Given $\text{out}_0$:

$$
\boxed{d = \frac{\text{out}_0 (M-c)}{T_0}}
$$

Average price is the arithmetic mean of endpoint prices (for linear $P$, equal to the midpoint price):

$$
P_{\text{avg}} = \frac{P_c + P_{c+d}}{2} = P_L + \frac{\Delta P (c + d/2)}{M}
$$

Input token1 required:

$$
\boxed{\text{in}_1 = \text{out}_0 \cdot P_{\text{avg}}}
$$

### 3.2 Buy token1 (specified out)

Given $\text{out}_1$:

$$
\boxed{d = \frac{\text{out}_1 \cdot c}{T_1}}
$$

Average price uses the arithmetic mean of inverted endpoint prices (token0 per token1). Define $\tilde{P}_x = 1/P_x$ at each endpoint:

$$
\tilde{P}_c = \frac{1}{P_c}, \qquad \tilde{P}_{c-d} = \frac{1}{P_{c-d}}
$$

$$
\tilde{P}_{\text{avg}} = \frac{\tilde{P}_c + \tilde{P}_{c-d}}{2}
$$

Input token0 required:

$$
\boxed{\text{in}_0 = \text{out}_1 \cdot \tilde{P}_{\text{avg}}}
$$

---

## 4. Specified In Swaps

Specified‑in is harder because input determines the position delta $d$ implicitly through the average price.

### 4.1 Buy token0 (specified in)

We want to solve for $d$ given $\text{in}_1$.

From section 2 and the endpoint average price:

- $\text{out}_0 = T_0 \cdot \frac{d}{M-c}$
- $P_{\text{avg}} = \frac{P_c + P_{c+d}}{2} = P_c + \frac{\Delta P}{2M} d$

Then:

$$
\text{in}_1 = \text{out}_0 \cdot P_{\text{avg}}
$$

Substitute:

$$
\text{in}_1 = \frac{T_0 d}{M-c} \cdot \left(P_c + \frac{\Delta P}{2M} d\right)
$$

This is quadratic in $d$:

$$
A d + B d^2 = \text{in}_1
$$

where

$$
A = \frac{T_0 P_c}{(M-c)}
\quad
B = \frac{T_0 \Delta P}{2M(M-c)}
$$

Define:

$$
Q = \frac{\text{in}_1}{A}
\quad
r = \frac{B}{A} = \frac{\Delta P}{2M P_c}
$$

Then the positive root is:

$$
\boxed{d = \frac{2Q}{1 + \sqrt{1 + 4 r Q}}}
$$

Finally:

$$
\boxed{\text{out}_0 = T_0 \cdot \frac{d}{M-c}}
$$

This closed form is a first estimate. `buyToken0InBinSpecifiedIn` skips it when the whole path to the bin edge or price limit is affordable, forces at least one position of progress when it rounds to zero, and applies the same correction as section 4.2.

### 4.2 Buy token1 (specified in)

We solve for $d$ given $\text{in}_0$, using the same endpoint-average model as section 3.2 in inverted-price space:

$$
\text{out}_1 = T_1 \cdot \frac{d}{c}
$$

$$
\tilde{P}_c = \frac{1}{P_c}, \qquad \tilde{P}_{c-d} = \frac{1}{P_{c-d}}
$$

$$
\tilde{P}_{\text{avg}} = \frac{\tilde{P}_c + \tilde{P}_{c-d}}{2}
$$

$$
\text{in}_0 = \text{out}_1 \cdot \tilde{P}_{\text{avg}}
$$

Clearing the $1/P_{c-d}$ denominator turns the exact relation into a different quadratic in $d$, which the implementation does not solve. It approximates it instead with the section 4.1 closed form after mirroring position, swapping inverted bounds (treating $1/P$ as linear between them), and mapping token1 balance into the buy-token0 form:

$$
c' = M - c
$$

$$
\tilde{P}_L = \frac{1}{P_U}, \qquad \tilde{P}_U = \frac{1}{P_L}
$$

Implementation (`computeAnalyticalTargetPosForSellToken0`) mirrors section 4.1 with the mirrored position and inverted bounds above.

$$
\boxed{c_{\text{target}} = M - c'_{\text{target}}, \qquad d = c - c_{\text{target}}}
$$

$$
\boxed{c'_{\text{target}} = h(M - c,\; M - c_{\min},\; \text{in}_0,\; T_1,\; \tilde{P}_L,\; \tilde{P}_U)}
$$

where $h$ is `computeAnalyticalTargetPosForBuyToken0` in code and $c_{\min}$ is the lowest allowed final position (`minFinalBinPos`: 0, or the price-limit position when a limit applies). The bounds passed are effective (fee-inclusive), so there is no fee argument.

There is no iterative refinement. `buyToken1InBinSpecifiedIn` recomputes the exact required input (section 3.2) up to three times: it rescales the delta proportionally and clamps it to the bin edge or price limit, and if the input then exceeds what remains, it scales the output down and recomputes the position. If the position stops inside the bin with required input below the remaining input, the trader is charged the full remaining input, in the pool's favour; at the bin edge only the required input is charged and the rest carries to the next bin; at the price limit only the required input is charged and the swap stops, leaving the rest unspent (partial fill).

Output:

$$
\boxed{\text{out}_1 = T_1 \cdot \frac{d}{c}}
$$

---

## Integer execution and price limits

The pool first folds the total fee into each bin price bound: buys multiply by `1 + f` and round up; sells divide by `1 + f` and round down. `SwapMath` then interpolates those effective bounds, so its input-cost helpers do not apply the fee again.

- Exact-output position moves round toward the starting position: final position rounds down for buying token0 and up for buying token1. Price-limit positions use the same rounding directions, and any output recalculated from position movement rounds down.
- Required input is the rounded-up arithmetic mean of two separately rounded-up endpoint costs. For buying token1, the code divides the output by each endpoint price directly; it does not first round two reciprocals and multiply them by output.
- Native input amounts round up and native output amounts round down after the bin walk. The pool rejects a swap if either final native delta is zero. Small amounts can therefore breach the continuous price-limit ratio through rounding.

`priceLimitX64` is a fee-inclusive token1-per-token0 floor when selling token0 and a cap when buying token0. Zero is not a universal "no limit" sentinel: it is a permissive sell floor, but a zero buy cap prevents output. Both exact-input and exact-output swaps can partially fill; use the returned deltas to determine actual execution.

## Fee allocation

The directional fee is the oracle base fee plus the bin's additional E6 fee plus the pool's notional E8 fee. Pool `spreadFeeE6` is the platform's share of the spread portion, not another price markup.

The platform receives its configured share of the spread fee and the entire notional fee; the remaining fee stays in the bin for LPs. Only the platform take is withheld from the trader's gross input before crediting the bin. The rates come from `FeeMath.totalFeeOfGrossX64` and `FeeMath.platformPartOfTotalFeeX64`; the in-bin swap functions round the total fee and then the platform take down, and the LP leg is the remainder. `FeeMath.notionalPartOfPlatformTake` then splits the platform take into its notional and spread legs.

---

## Appendix: Closed-form derivations

### A. Buy token0 (specified in)

For buy-token0 specified-in, endpoint-average substitution gives a quadratic:

$$
B d^2 + A d - I = 0
$$

with $I$ as specified input.

Using the standard quadratic formula with coefficients $a=B$, $b=A$, $c=-I$:

$$
d = \frac{-b + \sqrt{b^2 - 4ac}}{2a} = \frac{-A + \sqrt{A^2 + 4BI}}{2B}
$$

Define:

$$
Q = \frac{I}{A}
\quad
r = \frac{B}{A}
$$

Then:

$$
d = \frac{-A + A\sqrt{1 + 4rQ}}{2B}
$$

$$
d = \frac{\sqrt{1 + 4rQ} - 1}{2r}
$$

Multiply numerator and denominator by $1 + \sqrt{1 + 4rQ}$ to remove subtraction:

$$
d = \frac{2Q}{1 + \sqrt{1 + 4rQ}}
$$

---

## Fee Sizing

Because the bin price depends on position, the price a trader realizes depends on where in the bin they enter and exit. Let $S = P_U / P_L$ be the bin width ratio, with $S - 1 = \texttt{lengthE6} / (10^6 + \texttt{distE6})$ (`distE6` is the bin's lower-edge cumulative distance from the reference price, `curBinDistFromProvidedPriceE6`), and let $f_{\text{buy}}$, $f_{\text{sell}}$ be the total fee per direction (oracle spread + per-bin add fee + notional fee). A buy-then-sell round trip along the same path inside one bin is unprofitable even without fees: it pays the arithmetic mean of the endpoint prices and receives their harmonic mean. The sizing rule below is a conservative margin for entries and exits at different points of the bin: it makes the fees cover the gap between the bin's average price $(P_L + P_U)/2$ and its edge price $P_U$, for a single bin at a fixed oracle price:

$$
(1+f_{\text{buy}})(1+f_{\text{sell}}) \ge \frac{P_U}{(P_L + P_U)/2} = \frac{2S}{S + 1}
$$

With equal fees in both directions: $f \ge \sqrt{2S/(S+1)} - 1 \approx (S - 1)/4$.

Rule of thumb: for narrow bins, configure each direction's total fee to at least **~25% of $S - 1$**.

---

## Bin Balance Limits

- Bin balances are stored as `uint104` per side; all intermediate swap math runs in 256-bit arithmetic (`mulDiv`, `ceilDiv`, Q64.64).
- If a swap would grow the incoming side of a bin past `type(uint104).max`, it reverts with `OverflowedOnFittingBinBalances`. This can happen for pools holding a very large amount of a low-unit-value token in one bin; swaps in that direction through the bin stay blocked until liquidity is removed or a swap in the opposite direction drains that side. Choose token pairs and bin layouts accordingly.
- `addLiquidity` hitting the same limit reverts with `SharesAmountTooLarge` or a `SafeCast` overflow.
