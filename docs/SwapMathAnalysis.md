# **Analysis of Oracle-Dependent AMM Bin Vulnerabilities and Fee-Based Mitigation**

## **1. Introduction**

We investigate a single-bin Automated Market Maker (AMM) with an oracle-dependent price discovery mechanism. The bin's liquidity is bounded between $P_L$ and $P_H$. This paper identifies a fundamental path-dependency in such systems and derives the necessary swap fee to ensure the pool remains secure against drainage.

## **2. System Definition**

The state of a single bin is described by $(T_0, T_1, P_L, P_H, c)$:

- $T_0, T_1 \in \mathbb{R}_{\ge 0}$: Token reserves.
- $P_H > P_L$: Price boundaries, where $\Delta P = P_H - P_L$ and $S = P_H / P_L$.
- $c \in [0, 1]$: Current position within the bin.
- $P(c) = P_L + c \Delta P$: Current spot price.

### **2.1 Swap Mechanics (Arithmetic Mean)**

The bin supports specifiedOut swaps. The change in position $d$ is determined by the output amount relative to current reserves, and the input is calculated via the average price over that interval.

**Buy Token 0 (Pool buys Token 1):**

- $d = \frac{out_0}{T_0}(1-c)$
- $in_1 = out_0 \cdot P(c + \frac{d}{2})$

**Buy Token 1 (Pool buys Token 0):**

- $d = \frac{out_1}{T_1}c$
- $in_0 = \frac{out_1}{P(c - \frac{d}{2})}$

---

## **3. Derivation of Drainage Inequalities**

To prevent an attacker from draining the pool through round-trip arbitrage, the input of the second leg must be greater than or equal to the output of the first leg ($in_{final} \ge out_{initial}$).

### **3.1 Sequence A: Buy 0, then Buy 1**

An attacker buys $out_0$, then uses the proceeds ($in_1$) to buy back Token 1.

1. **Initial Swap:** Position shifts from $c$ to $c + d_0$.
2. **Buy-back Swap:** Position shifts from $c+d_0$ to $(c+d_0) - d_1$.
3. **Condition:** $in_0 \ge out_0 \implies \frac{in_1}{P(c + d_0 - d_1/2)} \ge out_0$.
4. Substituting $in_1$ and simplifying via monotonicity: $d_1 \ge d_0$.
5. Expanding $d_1$: $\frac{in_1}{T_1 + in_1}(c + d_0) \ge d_0$.

**Resulting Requirement for Sequence A:**

$$T_0 \cdot c \cdot P\left(c + \frac{d_0}{2}\right) \ge T_1(1-c)$$

### **3.2 Sequence B: Buy 1, then Buy 0**

An attacker buys $out_1$, then uses the proceeds ($in_0$) to buy back Token 0.

1. **Initial Swap:** Position shifts from $c$ to $c - d_0$.
2. **Buy-back Swap:** Position shifts from $c-d_0$ to $(c-d_0) + d_1$.
3. **Condition:** $in_1 \ge out_1 \implies in_0 P(c - d_0 + d_1/2) \ge out_1$.
4. Similarly simplifies to $d_1 \ge d_0$.

**Resulting Requirement for Sequence B:**

$$T_1(1-c) \ge T_0 \cdot c \cdot P\left(c - \frac{d_0}{2}\right)$$

---

## **4. The Continuous Invariant**

As trade sizes $out_i \to 0$, the two inequalities above converge. For a state to be non-drainable in _both_ directions for infinitesimal trades, the following equality must hold:

$$T_0 \cdot c \cdot P(c) = T_1(1-c)$$

This defines the "equilibrium curve" of the AMM.

### **4.1 Proof of Invariant Invalidation**

We test if a discrete swap starting at $I=0$ preserves the invariant. For an upward swap ($c \to c+d$):

$$I(c+d) = \frac{T_0 (1-c-d)}{1-c} \left[ (c+d) P(c+d) - c P(c) - d P(c+\frac{d}{2}) \right]$$

Expanding the polynomial $V(c) = cP(c)$:

$$V(c+d) - V(c) - d V'(c+\frac{d}{2}) = d \Delta P \left(c + \frac{d}{2}\right)$$

Since $d, \Delta P, c > 0$, then $I(c+d) > 0$. **Every swap strictly breaks the invariant.**

---

## **5. Minimal Fee Derivation ($f_{min}$)**

We introduce a fee multiplier $\gamma = 1 - f$. The security requirement is $\gamma^2 \le \frac{P_{avg}^{(in)}}{P_{avg}^{(out)}}$. We analyze the absolute worst-case price movements for the pool.

### **5.1 Case 1: Draining to $P_H$ (Forward Attack)**

Attacker drains $T_0$ entirely ($d=1-c$) starting from $c=0$:

$$\gamma_A^2 \le \frac{P_L + P_H}{2 P_H} = \frac{1+S}{2S}$$

### **5.2 Case 2: Draining to $P_L$ (Reverse Attack)**

Attacker drains $T_1$ entirely ($d=c$) starting from $c=1$:

$$\gamma_B^2 \le \frac{2 P_L}{P_L + P_H} = \frac{2}{1+S}$$

### **5.3 Global Fee Formula**

Since $(S-1)^2 \ge 0$, then $\frac{2}{1+S} \le \frac{1+S}{2S}$ for all $S \ge 1$. The reverse attack is the stricter bound.

$$f_{min}(S) = 1 - \sqrt{\frac{2}{S+1}}$$

### **5.4 Taylor Expansion**

Expanding around $S=1$ (small bin widths):

$$f_{min}(S) = \frac{1}{4}(S-1) - \frac{3}{32}(S-1)^2 + \frac{5}{128}(S-1)^3 + \dots$$

**Rule of Thumb:** For narrow bins, the minimum fee is approximately **25% of the bin width**.
