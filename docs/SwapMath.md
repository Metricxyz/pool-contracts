# Swap Logic Within a Single Bin (Specified In / Specified Out)

This document explains the swap logic inside a single bin, with a focus on **specified out** and **specified in** swaps, and derives the analytic approximation used for specified‑in.

The formulas here match the current implementation assumptions:

- Prices are **Q64.64** fixed‑point.
- Bin position $c$ is in $[0, M]$ where $M$ is `type(uint104).max`.
- The bin price curve is **linear in position**.
- Fee $f$ is applied multiplicatively as a **(1+f)** factor.

---

## 1. Notation

| Symbol     | Meaning                                            |
| ---------- | -------------------------------------------------- |
| $T_0$      | token0 balance in the bin                          |
| $T_1$      | token1 balance in the bin                          |
| $M$        | max bin position = `type(uint104).max`             |
| $c$        | current position in bin (0..M)                     |
| $d$        | position delta during swap (positive to the right) |
| $P_L$      | lower price bound (Q64.64)                         |
| $P_U$      | upper price bound (Q64.64)                         |
| $\Delta P$ | $P_U - P_L$                                        |
| $P(x)$     | price at position $x$                              |
| $P_c$      | price at position $c$                              |
| $f$        | fee rate, so multiplier is $(1+f)$                 |

Price curve inside the bin:

$$
P(x) = P_L + \frac{\Delta P \cdot x}{M}
$$

---

## 2. Output vs Position Relationship

These are the exact geometric relationships implied by the bin accounting:

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
\boxed{\text{in}_1 = \text{out}_0 \cdot P_{\text{avg}} \cdot (1+f)}
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
\boxed{\text{in}_0 = \text{out}_1 \cdot \tilde{P}_{\text{avg}} \cdot (1+f)}
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
\text{in}_1 = \text{out}_0 \cdot P_{\text{avg}} \cdot (1+f)
$$

Substitute:

$$
\text{in}_1 = \frac{T_0 d}{M-c} \cdot \left(P_c + \frac{\Delta P}{2M} d\right) \cdot (1+f)
$$

This is quadratic in $d$:

$$
A d + B d^2 = \text{in}_1
$$

where

$$
A = \frac{T_0 P_c (1+f)}{(M-c)}
\quad
B = \frac{T_0 \Delta P (1+f)}{2M(M-c)}
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
\text{in}_0 = \text{out}_1 \cdot \tilde{P}_{\text{avg}} \cdot (1+f)
$$

This yields the same quadratic structure as section 4.1 after mirroring position, swapping inverted bounds, and mapping token1 balance into the buy-token0 form:

$$
c' = M - c
$$

$$
\tilde{P}_L = \frac{1}{P_U}, \qquad \tilde{P}_U = \frac{1}{P_L}
$$

Implementation (`computeAnalyticalTargetPosForSellToken0`) mirrors section 4.1 with the mirrored position and inverted bounds above.

$$
\boxed{d = M - c'_{\text{target}}}
$$

$$
\boxed{c'_{\text{target}} = h(M - c,\; M - c_{\min},\; \text{in}_0,\; T_1,\; \tilde{P}_U,\; \tilde{P}_L,\; f)}
$$

where $h$ is `computeAnalyticalTargetPosForBuyToken0` in code.

The inner call uses the closed form from section 4.1. Iterative refinement in `buyToken1InBinSpecifiedIn` recomputes the endpoint-average inverted price at each step.

Output:

$$
\boxed{\text{out}_1 = T_1 \cdot \frac{d}{c}}
$$

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

## Type-width and Overflow Safety

Implementation policy in pool/swap math is:

- Use packed/short integers only in storage (for example `uint104` balances in `BinState`, `uint24` fee slots).
- Use `uint256`/`int256` for in-memory arithmetic paths (`SwapState`, fee/price intermediates, loop math).
- Use `SafeCast` (`.toUint104()`) at storage boundaries — i.e., bin balance writes — to revert on violation.
- Direct `uint104(...)` casts are used for in-memory bin-position arithmetic where the result is provably bounded by surrounding checks or mathematical invariants (e.g., price interpolation within `[lower, upper]`, averages of two `uint104` values, ternary guards against `maxFinalBinPos`).

Why this is safe and helps avoid overflow-driven DoS:

- Fee setters bound inputs before downcasting (`new*FeeE6 <= 2e5`), so casts to `uint24` are provably safe.
- Swap accounting uses 256-bit arithmetic for intermediate products (`mulDiv`, `ceilDiv`, Q64.64 math), which gives wide headroom and avoids silent truncation in mid-calculation.
- Storage-boundary downcasts use `SafeCast` to revert on violation. In-memory position downcasts use direct casts only where preceding logic guarantees the value fits (e.g., `scaledTarget ≤ maxFinalBinPos ≤ type(uint104).max`).
- Checked arithmetic (default in Solidity 0.8+) is retained unless an `unchecked` block is used with surrounding bounds logic.
