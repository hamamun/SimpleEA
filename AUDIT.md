# SimpleEA — Independent Audit

**What was audited:** `SimpleAdvisor.mq5` (version 2.16), commit `ca7a4c4`, plus the four
verification scripts in `research/`.
**How:** full line-by-line read of the EA, cross-checked against `README.md` / `SIGNAL_LOGIC.md`
and against the Python emulations (`verify_autotrading.py`, `verify_plan_math.py`,
`verify_timeframe_gate.py`, `verify_mql.py`). All four Python checks pass.
**Limits:** no MetaTrader/MetaEditor in this environment, so this is a source audit — nothing was
compiled or back-tested, and no live order was sent. The one finding that depends on MetaTrader
runtime behaviour rather than on the source alone is marked as such.

## Status after v2.17 (fixes applied)

| Finding | Status |
|---|---|
| §0 / §1.1 — the score gate did not cover the range game | **FIXED.** New `ScoreAllowsTrade()` gates the direction in `EvaluateRow()` *and* again in `PlacePlanOrder()`. A box trade in a direction the score does not support now stands aside with `chop — score +0/3 under the -2 gate` on the plan line. README, SIGNAL_LOGIC and the code comments updated; a regression test reproduces the report (`verify_autotrading.py`, block 8f). |
| §1.3 — an open trade's stop could widen | **FIXED.** Before TP1 the new plan's stop is now taken only if it is *tighter* than the one in place. The old test that asserted the widening was rewritten to assert the documented rule. |
| §1.1 — score ±2 unreachable in trend mode | **OPEN** (needs a decision, see below). |
| §1.2, 1.4, 1.5, §2, §3 | **OPEN** — unchanged, details below. |

**Decision needed for §1.1:** in a Steady regime the third vote is a copy of the first
(`v3 = v1`), so a trend score of ±2 cannot occur — every trend entry is a market order at "3/3"
and always takes the doubled risk. Two honest options: make the regime vote a genuinely
independent value, or accept a two-vote engine and remove the score-2 / pending / risk-tier
machinery (from code, panel and README) so nothing promises a state that cannot happen. I have
not changed this, because it changes what the EA trades and that is your call.

---

## 0. Your observation, explained first

> "Autotrade should place an order only at ±2, but while the score showed 0 autotrading placed an order."

**You are seeing a real thing, and it is not a coin-flip or a glitch — it is the range mode
(`InpRangeMode`, default ON) working as its author designed it.** But the screen is written in a
way that makes it look like a rule is being broken.

SimpleEA has two games, chosen per timeframe by the regime column:

| Regime | Game | Does the score decide the trade? |
|---|---|---|
| **Steady** | trend game | **Yes** — ±2 rule applies exactly as you expect |
| **Choppy** | range game (a 20-bar box trade) | **No — the score is ignored entirely** |
| **Mixed** | stand aside | nothing is placed |

In the range game the direction comes from *where price sits inside the box*: if price is in the
upper half the EA sells at the top band, if it is in the lower half it buys at the bottom band.
That happens whatever the score says — including 0.

Three things make it look like a bug:

1. The **"Trend:"** line on the main panel is not the trend at all — it prints the *trade
   direction*. A range **sell** is labelled **"Going down"** even when the trend is up and the
   score is +2.
2. The **Score** column keeps showing the trend score (e.g. `+0 / 3`) right next to that trade
   direction.
3. The **Autotrading panel** never says *why* the order exists. The only clue is the small
   `range fade` word in the plan block above it.

**How to confirm it in one minute:** when it happens, look at the row's **Regime**. If it says
**Choppy**, this is the mechanism (and the plan block for that timeframe will read `range fade`).
If you ever see a **Steady** row placing an order at score 0 or ±1, *that* would be a genuine
malfunction — from the code, it cannot happen.

**Your options:**
- `InpRangeMode = false` → every Choppy row stands aside and the ±2 rule becomes absolute.
- Or keep it and have the panel tell the truth (see fix list, item 1).

Severity: **medium** (it is a design choice, but it is presented misleadingly and it trades real
money with no score support).

> **FIXED in v2.17.** The range game now obeys `InpBuyScore` / `InpSellScore`: the box still
> decides the *price*, but no box order is placed in a direction the score does not support.
> A refused row says `chop — score +0/3 under the -2 gate` on its plan line. Existing open
> positions are untouched; new entries from a Choppy row now require the same ±2 you expected.

---

## 1. Serious findings (money risk)

### 1.1 The third "vote" is a copy of the first — so a score of 2 can never happen
The score is built from three votes. In a Steady regime, vote 3 is simply *set equal to vote 1*
(`v3 = v1`, line 1033). So in practice the score is `2 × trend + momentum`, which can only ever
be **−3, −1, +1 or +3** (a score of ±2 would need the momentum line to be *exactly* flat — a
measure-zero event on real data).

What that silently breaks:

| Documented behaviour | What actually happens |
|---|---|
| "Score 2/3 → places a **Pending Limit** order" (README rule 3, line 481) | **Never happens.** Every trend trade is score 3 → **market order**. The `pending +2/3` plan line shown in the README's own screenshot cannot be produced by the code. |
| "Score 2 risks 0.5 %, score 3 risks double (1.0 %)" | **Every** trend trade is score 3 → **always the double**. `InpRiskPct = 0.5` behaves as 1.0 %. |
| Ladder mode "0.01 per 1,000, ×1.5 when all three agree" | **Always ×1.5.** |

Because it trades three timeframes independently, a normal fully-aligned day can put **3 trades
× 1.0 % = 3 % of the balance** on one symbol in one direction, not the 0.5 % the settings imply.

Severity: **high**. (Design intent vs. reality gap, and double the advertised risk.)

### 1.2 By default the EA opens trades with **no stop loss at all**
`InpUseStopLoss = false` is the shipped default. The stop is not attached at entry; the stepped
trail places the *first* stop only after price has travelled 40–55 % of the way to TP1. Between
entry and that moment the position has **no protective stop** — while the panel still prints a
"Risk: 7.84 USD" figure computed as if a stop were in place (the lot size is derived from that
imaginary stop).

Consequence: if price runs against the entry immediately, there is nothing to stop it. The only
exits before TP1 are "signal flips to the opposite direction" or "signal drops to HOLD *while in
profit*". A losing trade with no stop can therefore sit open indefinitely.

Severity: **high**.

### 1.3 The stop can be moved **further away** on a new bar
README rule 6 promises the open-trade stop "only tightens (never widens risk)". The code does not
honour that before TP1: on every new closed bar the stop is *rebuilt from the current ATR*
(`candSL`, line 3101) and applied without the "tighter only" test (line 3107). So when volatility
rises, the stop is pushed further from entry — the trade's risk grows *after* it was opened.

(Once TP1 is hit or the trail is active, the tightening check is applied correctly.)

Severity: **high** (contradicts a written promise, and increases risk mid-trade).

> **FIXED in v2.17.** Before TP1 the new plan's stop is applied only when it is tighter than the
> stop already in place, so a rising ATR can no longer widen an open trade's risk.

### 1.4 The target moves during the trade
TP1/TP2/TP3 are recomputed from the current ATR (trend) or box (range) on every closed bar
(lines 3094–3097). So the take-profit walks while the trade is live: it can move further away
after the trade is already deep in profit, or the TP1/TP2 split can change after TP1 was already
banked. The pre-TP1 trail's percentages are *frozen* at fill while TP1 itself keeps moving, so the
trail can finish its last step short of the new TP1.

A trade no longer has the risk/reward it had when it was opened.

Severity: **medium-high**.

### 1.5 Minimum lot can exceed the configured risk, and it still trades
If the risk-based lot comes out below the broker's minimum, the EA rounds **up** to the minimum and
places the order anyway. The panel admits it (`0.01 (min, 12.40 USD)`), but nothing stops the
trade. On a small account with a wide stop this can risk several times the chosen percentage.

Severity: **medium**.

---

## 2. Behaviour bugs (wrong state, wrong exits)

### 2.1 A restart forgets that a trade was a range fade
After a terminal restart (or recompile), open positions are recovered from the broker — but the
`isRange` flag and the box are **not** recovered (`ResetAutoSlot` sets them to false/0). A live
range fade then becomes a "trend trade": the **box-kill is lost** (a breakout no longer closes it)
and the **score watcher switches on** (a score that was irrelevant at entry can now close it).
Same trade, different rules before and after a restart.

Severity: **medium**.

### 2.2 The manager stops in several everyday situations
Position management (trail, TP1/TP2 partials, score exit, box-kill) only runs when *all* of these
hold: autotrading input is ON, the chart is M5/M15/M30, the market is not "closed", and the panel
was drawn successfully. So:

- switching the chart to H1 (or any other timeframe) while a trade is open → **no management**;
- `InpAutoTrading = false` → **no management** of trades already open (documented, but with
  default no-stop-loss that leaves them completely unprotected);
- a 30-minute quiet quote (`InpClosedStaleMin`) counts as "market closed" → **no management**;
- if the chart object panel failed to build (`g_panelOK` false), tick management is skipped.

Severity: **medium** (presentation/robustness, but it can leave a position unattended).

### 2.3 The EA re-opens what you close by hand
If you close a position or delete a pending manually, nothing records "the human said no". On the
next closed bar, if the signal is still valid, the EA places a new order. The only guard
(`HasTradedOnBar`) looks at *entries made by the EA in the current bar*, not at your manual action.

Severity: **medium** (surprising, and it can undo a deliberate decision).

### 2.4 No account-type or margin checks
- The design assumes a **hedging** account (one position per magic number). On a **netting**
  account, an M5 BUY and an M30 SELL on the same symbol merge into one net position — the
  per-timeframe tickets, stops and partial closes then refer to the wrong thing.
- There is no free-margin check before opening: the order is simply sent and can be rejected.
- Position size uses **balance**, not equity, so after a drawdown it keeps sizing as if nothing
  happened.

Severity: **medium** (conditional on the account).

### 2.5 No maximum-spread filter on market entries
The range game has a spread gate; the trend game has none. A market order is allowed with a
slippage allowance of up to 50 points (5 pips on a 5-digit FX pair), so during news the EA can fill
at a materially worse price than the one that produced the signal.

Severity: **medium**.

---

## 3. Smaller or cosmetic issues

| # | Finding | Impact |
|---|---|---|
| 3.1 | The panel's **"Trend:"** line prints the *trade* direction, not the trend — so a range BUY reads "Going up" even with a negative score. | Makes finding 1.1 look like a malfunction. |
| 3.2 | The **Score** colour follows the trade direction, and the 2nd-panel card shows no score / no reason at all. | Hard to audit a trade after the fact. |
| 3.3 | **"Valid: N/3 bars"** counts from when the *idea* was born, but a pending order's real expiry counts from when it was *placed*. A pending can outlive the countdown shown on screen. | Trust in the panel. |
| 3.4 | `LastClosedBarTime()` returns the **current (still-forming)** bar's start time, not the last closed one — the "newest first" array flag is missing on that one call. It happens to still fire the once-per-bar update, but every "bars since" number (and the order expiry) is one bar late. *(The only finding that depends on MetaTrader's copy-order semantics rather than on the source alone.)* | Low. |
| 3.5 | `IsScoreStrongForTrade` compares against the **strongest score the trade ever had**, not the entry score, so a post-TP1 close can fire earlier than the documented rule. | Low. |
| 3.6 | After a restart the EA **invents** an entry score of ±2 or ±3 when it cannot know the real one. | Low. |
| 3.7 | The range box uses the **live bid** (not a closed bar) for the upper/lower-half decision, inside an otherwise "closed bars only" design. | Low (a spike at the open of a bar can flip the side). |
| 3.8 | `HurstExponent` has an **off-by-one at the window edge** (`close[-1]` if the history were ever exactly the window length). Unreachable today because 700 bars are always demanded, but fragile. | Low / latent. |
| 3.9 | The README shows readings the code cannot produce (the `pending +2/3` plan line; a `-2/3` trend sell that is really a range sell). | Documentation. |

---

## 4. Why the existing tests did not catch this

The four `research/verify_*.py` scripts are **line-by-line transcriptions** of the MQL5 code. They
confirm that the Python copy and the MQL5 copy behave identically — they cannot confirm that either
one is right. Specifically:

- The autotrading test **feeds the score in by hand** (`set_bar(..., score=3)`,
  `set_bar(..., score=2)`, `verify_autotrading.py:1337`). So it happily verifies "score 2 places a
  pending order" — a state the real engine can never reach (finding 1.2).
- The open-trade stop test only exercises the **tightening** direction
  (`verify_autotrading.py:1652`), never a wider stop (finding 1.3).

All four scripts pass, and that is expected: they are consistent with the code, not with the
documentation.

## 5. What I checked and found healthy

For balance, these are the parts that hold up:

- **No repainting / no look-ahead** in the signal engine: all three rows read closed bars only
  (`LoadClosed` deliberately skips the forming bar), and the filter/E-R/Hurst/ATR all agree.
- **One order per timeframe** is genuinely enforced (one slot per magic number), and a duplicate
  placement on the same bar is blocked.
- **Input validation** at load is real: crossed score gates, reversed Hurst thresholds, reversed
  trend periods, bad risk %, bad clock strings are all refused.
- **The daily timer / one-shot pause** behaves as documented: it blocks *new* placements, cancels
  waiting pendings, keeps managing open trades, and the pause survives a restart without being
  re-armed.
- **Chart-timeframe rule and Market-Closed collapse** work as described (no numbers drawn, nothing
  calculated, nothing traded).
- **Broker arithmetic** (point value, lot step, stops level, slippage, filling mode) is derived
  from the terminal rather than hard-coded, and is handled correctly.

---

## 6. Suggested fix order

1. **Make the panel honest about range trades** (finding 1 + 3.1 + 3.2): label the row
   `Range: BUY at band`, mute or hide the trend score in range mode, and put `range fade` on the
   2nd-panel card. **Half done in v2.17** — the score gate now makes a range trade impossible
   below ±2, so the "score 0 but an order" sight is gone; the labelling (3.1/3.2) is still open.
2. **Make the third vote independent** (1.1) — e.g. let the regime vote be a real, separate value,
   or accept a 2-vote engine and remove the score-2/pending/risk-tier machinery from the code,
   the panel and the README. Either way they must agree.
3. **Never open without a stop** (1.2): either ship `InpUseStopLoss = true`, or place the
   ATR stop at entry and let the trail only tighten it.
4. ~~**Enforce "stop tightens only"** (1.3)~~ — **done in v2.17** — and **freeze TP1/2/3 at entry**
   (1.4) — or, if targets must float, re-freeze the trail reference whenever TP1 changes.
5. **Persist `isRange` + the box per magic** so a restart cannot change a trade's rules (2.1), and
   decide whether "autotrading off / wrong chart / market closed" should really stop *management*
   of positions that were opened with no stop (2.2).
6. Then the smaller items: manual-close memory (2.3), a spread cap (2.5), a netting/free-margin
   guard (2.4), and the "Valid" countdown (3.3, 3.4).

---

### Evidence index (for the developer)

| Finding | Where |
|---|---|
| Range mode ignores the score | `SimpleAdvisor.mq5:1099` (`dir = (bid > mid) ? -1 : +1;`), guards `2889–2898`, `3236–3242` |
| Score 2 unreachable | `1033` (`v3 = v1`), `1043`, `1054`, `1369`, `1446`, `1454` |
| No stop by default / risk shown anyway | `186`, `2911`, `2380–2395` (trail arms at 40–55 %), `1433–1450` |
| Stop can widen | `3101–3114` (`useSL = candSL` before TP1) vs README:517 |
| Targets recomputed | `3090–3097` |
| Range state lost on restart | `1740`, `2860–2870`, `2935` vs `2985` |
| Management gates | `636–648`, `1759–1770`, `3004–3010`, `692–695` |
| Manual close not remembered | `2466–2486`, `3236–3242` |
| No margin-mode / free-margin / spread cap | no reference to `ACCOUNT_MARGIN_MODE`, `ACCOUNT_MARGIN_FREE`, `SYMBOL_SPREAD` in the entry path |
| "Trend:" shows trade direction | `4018–4019` |
| Valid countdown vs expiry | `1540–1580` vs `3162–3165` |
| `LastClosedBarTime` order | `738–744` |
| Hurst edge | `866–870` |
| Tests feed the score in | `verify_autotrading.py:1337`, `1652` |
