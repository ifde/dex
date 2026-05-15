# Hook Algorithms

## 1. Block-Adaptive Hook (BAHook)

**Idea:** If token A becomes less desirable (CEX price ratio $P_A / P_B$ decreases), traders prefer to swap A → B. We respond by increasing the fee in that direction.

**Fee update rule (after each swap A → B):**

$$F_{AB} \leftarrow F_{AB} + F_{\text{step}}$$

**Parameters:**

| Parameter | Value |
|---|---|
| $F_{\text{initial}}$ | 30 bps |
| $F_{\text{step}}$ | 5 bps |

---

## 2. MEV Charge Hook

**Source:** https://github.com/MrLightspeed/MEVChargeHook

**MEV** (Maximal Extractable Value) — maximum profit extractable by block producers from pending transactions.

**Anti-JIT penalty** (on `ModifyLiquidity` — liquidity removed too soon):

$$\text{penalty} = \text{fee} \cdot \frac{B_{\text{offset}} - B_{\text{elapsed}}}{B_{\text{offset}}}$$

donated back to the pool.

**Swap fee** — protects against sandwiching and large-impact trades:

$$F_{\text{time}} = \frac{t_{\text{current}} - t_{\text{last}}}{T_{\text{cooldown}}}$$

$$F_{\text{impact}} = \frac{\text{tradeAmount}}{\text{totalLiquidity}}$$

$$F_{\text{total}} = \max(F_{\text{time}},\ F_{\text{impact}})$$

---

## 3. Peg Stability Hook

**Source:** https://github.com/Renzo-Protocol/foundational-hooks

**Idea:** Keep the DEX price of token B above (or equal to) the CEX price of token B.

- If token B is being bought (DEX price B rising) **or** DEX price B $\geq$ CEX price B → apply minimum fee to stimulate swaps:

$$F = F_{\min}$$

- Otherwise, fee is the percentage difference between Pool Price and CEX Price

$$F = \frac{|P_{\text{DEX}}^B - P_{\text{CEX}}^B|}{P_{\text{CEX}}^B}$$

$$F \in [F_{\min},\ F_{\max}]$$

---

## 4. Deal-Adaptive Hook (DAHook)

**Idea:** React to the direction of the last swap — raise the fee in that direction, lower it in the opposite.

**After a swap A → B:**

$$F_{AB} \leftarrow F_{AB} + \delta$$

$$F_{BA} \leftarrow F_{BA} - \delta$$

**After a swap B → A:**

$$F_{BA} \leftarrow F_{BA} + \delta$$

$$F_{AB} \leftarrow F_{AB} - \delta$$

where $\delta = F_{\text{step}}$ is a fixed step size in bps.

---

## 5. AMM-Based Hook (ABHook)

**Idea:** If the last swap A → B shifted the AMM price by $\Delta$, increase the A → B fee proportionally, and maintain a **constant fee sum** $K$.

In Uniswap V4, price is the $\frac{\text{token B}}{\text{token A}}$     
Which is the price of token A relative to token B
So in our case, becase the swap is A → B, price of A **decreased**.     
And we want to **increase** $F_{AB}$

**Fee update after A → B:**

$$F_{AB} \leftarrow F_{AB} - A \cdot \Delta, \quad A > 0$$

**Constant sum constraint:**

$$F_{AB} + F_{BA} = K$$

$$F_{BA} = K - F_{AB}$$

So raising one fee automatically lowers the other, always preserving the total at $K$.
