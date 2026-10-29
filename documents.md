# SimpleEA 2.0 — Complete Documentation & Process Specification

**Version:** `2.0` (`#property version "2.0"`, Panel Header `SimpleEA2.0`)

SimpleEA 2.0 (`SimpleAdvisor.mq5`) is a single-file, multi-timeframe Expert Advisor for MetaTrader 5 (MT5), designed for **M5 (scalp)**, **M15 (short-term)** and **M30 (intraday)**. Signals and historical observations use closed bars; entry checks, fill management and exits use live quotes and broker state.

> **Default activation and validation:** `InpAutoTrading=true` enables eligible new entries by default when the terminal, account and remaining gates permit them. The structure/history replacement has not been compiled in MetaEditor or validated with a broker. Policy constants and historical proxies are unvalidated; stop fills and cancellations are not guaranteed.

This document describes the intended current implementation; actual MQL compilation and MT5/broker behavior must still be verified.

---

## 1. System Overview & Core Workflow

SimpleEA runs simultaneously as:
1. **An Analytical On-Chart Dashboard (Main Panel & Trade Plan)**: Evaluates trend, timing, market structure, and statistical memory (Hurst regime) independently across M5, M15, and M30.
2. **An Automated Execution Engine (`InpAutoTrading`)**: Places orders, applies fixed TP1/TP2/TP3 exits, and keeps the entry SL unchanged on each timeframe independently via unique magic numbers (`InpMagicBase + TF_INDEX`).
3. **A Calibration-Health Diary**: Normally records one small row for each confirmed order idea, keeps Day and lifetime totals per symbol, and warns when a timeframe lane's recent follow-through, entry cost, score behaviour, or entry style deteriorates. It suggests a first fix; it never retunes the EA by itself (see §9).

### Main Panel Display Format
Each of the three timeframes (**M5 Scalp**, **M15 Short-term**, **M30 Intraday**) displays a two-line block:
- **Line 1: Trend & Regime**
  - **Trend (3 types)**: **`Going up`** (Green), **`Going down`** (Red), or **`Sideways`** (Grey).
  - **Regime (3 types)**: **`Steady`** (Blue), **`Mixed`** (Grey), or **`Choppy`** (Orange).
  - All 9 combinations ($3 \times 3$) can appear independently on each timeframe.
- **Line 2: Health, Signal & Score**
  - **Health**: One compact diary verdict in the blank left-hand strip (`Health: Learning`, `Health: OK`, `Cost: Poor`, `TP1: Watch`, ...), explained in §9.
  - **Signal**: **`BUY`** (Green, when score $\ge +2$), **`SELL`** (Red, when score $\le -2$), or **`HOLD`** (Grey, when score is between $-1$ and $+1$).
  - **Score**: Always printed explicitly beside the signal as `+3 / 3`, `+2 / 3`, `+1 / 3`, `+0 / 3`, `-1 / 3`, `-2 / 3`, or `-3 / 3`.
  - **When score is `+1 / 3` or `-1 / 3`**: The signal clearly shows **`HOLD`** (in grey) with the score beside it, and the Trade Plan row underneath displays: `score +1/3 — under the +2/-2 gate` (stating exactly why no trade is placed). No regime hides the score.
  - **When a qualifying row is Choppy but `InpAllowChoppyTrade = false`**: the would-be `BUY`/`SELL` and its score remain visible but are greyed out, and the Trade Plan remains `HOLD`. When an otherwise valid plan is available it shows `Block: regime blocks entry`; a data or structure HOLD may appear first.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  SimpleEA2.0  | Autotrading : On   | Day: S 14 W 6 L 4   |  XAUUSD  |  M5   │
│  Timer: Off | Choppy Trade: On | M15/M30 Same Trend: Off                    │
├─────────────────────────────────────────────────────────────────────────────┤
│  M5   Scalp       Trend: Going up     Regime: Steady                        │
│  Health: OK       Signal: BUY         Score: +3 / 3                         │
│  M15  Short-term  Trend: Sideways     Regime: Mixed                         │
│  TP1: Watch       Signal: HOLD        Score: +1 / 3                         │
│  M30  Intraday    Trend: Going down   Regime: Choppy                        │
│  Health: Learning Signal: SELL        Score: -2 / 3                         │
└─────────────────────────────────────────────────────────────────────────────┘
```

```text
Closed bar -> retained trend / ROC / structure votes, ER and Hurst regime
           -> displayed BUY / SELL / signal HOLD (independent of plan HOLD)
           -> permission + confirmed price structure + completed bar analogs
           -> broker distances + per-lane spread/risk checks
                 | insufficient/unsafe -> trading HOLD; cancel waiting entries
                 | valid               -> market or structural limit plan
           -> broker SL + TP3; frozen software TP1/TP2
           -> manage actual position without signal-driven close or stop moves
```

A BUY/SELL direction can coexist with **trading HOLD**: the reading remains visible while new entries are unsafe or disabled. Signal HOLD is a neutral/unqualified reading. Neither kind is an instruction to abandon an already-open position. With trade permissions and the master on, the EA requests cancellation of waiting entries, but broker rejection, disconnection, or a fill race means cancellation is not guaranteed.

The panel's top band is two lines: the master status, then the modes behind it.

### Header Line 1 — Autotrading State, Resume Countdown & Day Diary Counts

`SimpleEA2.0 | Autotrading : <state>` `[Resume <countdown>]` `| Day: S <n> W <n> L <n>` `|  SYMBOL  |  TF`

The word after *Autotrading* reflects the master and effective timer state, not all execution permissions. MQL5 inputs are read-only at run time, so the header can show `Timer Pause` without rewriting `InpAutoTrading`. `On` does not establish that the terminal, account, broker or individual plan gates allow an order.

| Effective state | Colour | Meaning | New orders | Waiting pendings | Open trades |
|---|---|---|---|---|---|
| **`Off`** | Red | `InpAutoTrading = false` (read-only mode) | none | untouched | no EA trade requests |
| **`Timer Pause`** | Orange | Switch is on, but the daily window is closed and/or a one-shot pause is running | **blocked** | **cancellation requested** | **still managed** |
| **`On`** | Green | master on; timer permits placement | only when terminal, account and plan/entry gates pass | kept unless a gate invalidates them | managed when trading is available |

`Timer Pause` is deliberately not called `Timer Off`: `Off` already means *the feature is switched off*, and the two must never read as the same thing. When the timer re-opens, the header can return to `On` if the master is enabled.

**`Resume ...` countdown** — shown beside the state word, but only while something is actually blocking placement:

- It targets the **later** of two doors: the daily window re-opening, or the one-shot pause ending — because placement needs both open. Example: a 48-hour pause with the window opening in 1 hour reads `Resume 2d 0h`.
- Formats: `Resume 2d 0h` ($\ge 24$ h), `Resume 23h59m`, `Resume 25m` (under an hour). Maximum 13 characters.
- Refreshed once a minute (never per second), so the flip back to `On` is never late and the chart is not redrawn needlessly.
- Absent entirely when nothing blocks — i.e. whenever the timer is not in use, or the window is open.
- The countdown slot is reserved only while it is on screen. The Day diary counts after it have their own measured slot (below), so neither the countdown nor the counts can collide with the right-hand symbol block.

**`Day: S ... W ... L ...` diary counts** — always shown on a supported, open-market panel after the state/countdown:

- `S` = order ideas SimpleEA placed today; `W`/`L` = original trades finally closed in profit/loss today. Break-even, open, waiting, and expired categories live in the History panel so the header stays compact.
- `Day` is the PC/VPS local day. `S` uses placement day while `W`/`L` use final-close day, so a trade placed yesterday and closed today can add to today's `W` without adding to today's `S` (see §9.1).
- The counts come from the per-symbol calibration diary and continue to update whether the optional History panel is shown or hidden.

### Header Line 2 — Modes

`Timer: <status> | Choppy Trade: On/Off | M15/M30 Same Trend: On/Off`

- **Timer** — `Off` (no schedule, no pause), `On 08:00-17:00` (window open), `Paused 08:00-17:00` (outside the window), or `Paused by request` (one-shot pause running; the exact remaining time lives on line 1).
- **Choppy Trade** — mirrors **`InpAllowChoppyTrade`** (the new-entry permission). `Off` means no new market or limit order on a row currently reading Choppy. It does **not** mirror `InpRangeMode`: that separate input only chooses box-band versus pullback pricing after Choppy trading has been allowed (see §3).
- **M15/M30 Same Trend** — mirrors `InpRequireM15M30SameTrend`.
- Grey = the mode is switched off (a choice, not an error); orange is reserved for a timer that is blocking trades.

While the timer blocks, the header grows by the wider state word and the countdown:

```
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│  SimpleEA2.0  | Autotrading : Timer Pause  Resume 2h14m  | Day: S 3 W 1 L 0  | XAUUSD | M5 │
│  Timer: Paused 08:00-17:00 | Choppy Trade: On | M15/M30 Same Trend: Off                  │
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

…followed by the usual timeframe rows and Trade Plan. The header shrinks back to its normal width the moment the timer re-opens.

### Main Panel Group 2 — Per-Timeframe Trade Plan

Each lane shows either `HOLD` with a reason, `waiting` while history loads, or a four-line plan:

1. `Entry`, `Lot`, and `Data: <filled>/<eligible> analogs`.
2. `Stop`, `TP1`, and `TP2` as absolute prices and point distances.
3. `TP3`, estimated `Risk`, and estimated staged `Reward`.
4. `Valid` in bars, historical observation `Window`, and `Fees: not included`.

`Data` counts hypothetical touches/fills, not broker executions. There is no invented `Reach` estimate. A permission veto can preserve the visible four-line plan while showing `HOLD` and a `Block` reason. With insufficient observations the EA can show a four-line held preview: `Entry`, `Stop`, `TP1~`/`TP2~`/`TP3~`, `Basis: swing-only`, `Action: NO ORDER`, and a reason. The tilde levels are indicative opposing swings or observed candidates, not orders; unavailable levels are `--`. `TP1~` includes its directional distance from entry in points. If no useful data are available, a one-line HOLD or waiting message may be shown instead. A currently open position produces a plan HOLD and retains its frozen levels in the second panel. For a read-only preview set `InpAutoTrading=false`; master-off also stops software exit management.

For a held preview with available quote data, `Spread` shows the evaluation spread, and `Broker` shows `SYMBOL_TRADE_STOPS_LEVEL` and trade tick size, in points. `RawTP1` is the historical TP1 distance before the swing cap and tick rounding; `Basis: observed + swing` means that cap reduced TP1, while `Basis: observed` does not rule out caps on TP2/TP3. When an opposing swing is inside the spread, `Swing` shows its estimated executable-side price instead of `RawTP1`. Values are rounded for display and can be stale by the time an order is attempted.

`Reason` identifies the first applicable stage: earlier data, structure and observation problems come first; after observations, `swing in spread` takes priority, then the first `SL/TP order/tick`, broker-distance, pending-entry or `TP1 <= spread` check. The tick/order checks require the correct ordering and at least one tick between levels. Risk and permission vetoes can remain after a price problem is resolved. `TP1 <= spread` compares the rounded candidate's directional distance with the snapshot spread; it is a conservative extra gate, not a second spread charge. A Steady regime does not waive these checks. The MT5 Experts log records a fresh placement preflight failure or an unconfirmed broker request, including its return code/comment; it does not mean an uncertain request is definitely rejected.

### Second Panel — Autotrading Live Monitor (`SA2_`)

The **Autotrading** panel opens automatically (`Right` or `Bottom` of the Main Panel via `InpAutoPanelPos`) whenever at least one market position or pending limit order is active, and deletes all of its chart objects (`0` objects) the instant all lanes are flat.

- **Header**: `Autotrading | Exits : TP/SL | Stoploss : Fixed / Missing |  SYMBOL`
  - `Exits: TP/SL` states the complete open-position exit policy.
  - `Stoploss: Fixed` appears when every active order/position has a physical broker `SL > 0.0`; `Missing` warns that at least one does not. SimpleEA does not alter an existing position to clear that warning.
- **4-Line Active Order Card** (`M5  | OPEN BUY`, `OPEN SELL`, `BUY LIMIT`, `SELL LIMIT`):
  - **Line 0**: `Lot @ <curLot>` | `Entry: <entryPrice>` | `Bid:` / `Ask: <livePrice>`
  - **Line 1**: frozen `TP1` and `TP2` prices, with `[HIT]`, `[SKIP]`, `[PART]`, or `[REVIEW]` status when applicable; `-- (unavailable)` means they could not be safely recovered.
  - **Line 2**: `TP3: <price>` | `SL: <price> (<CCY> est)`; the SL money figure is an estimate excluding fees and slippage. A missing legacy/external stop displays `-- (missing)` in red.
  - **Line 3**: `Status: P/L +/-X.XX <CCY>` *(or `Waiting: distance N pts` for pending limits)* | `Distance: to TP1/TP2/TP3 N pts` | `Exit: TP/SL; fees excluded`. An open position with a remaining broker entry order also displays `ENTRY REMAINDER` while cancellation is attempted.


---

## 2. Signal Engine & 3-Vote Scoring Architecture

SimpleEA rejects classic lagging filters (e.g., standard moving averages, RSI, MACD). Instead, it isolates actionable cycle frequencies using modern bandpass, self-adapting wavelength analysis, and institutional market structure.

### Component 1 — Direction (Vote 1): Ehlers Precision Trend with Adaptive Cycle Periods
*Transcribed directly from John F. Ehlers (Technical Analysis of Stocks & Commodities, September 2024), enhanced with self-adaptive cycle wavelength detection.*

Unlike laggy low-pass moving averages, Precision Trend subtracts two 3-pole high-pass filters (`L1`, `L2`), creating a bandpass filter whose effective periods adapt to the measured cycle:

$$\text{Trend} = \text{HighPass3}(\text{Price}, L_1) - \text{HighPass3}(\text{Price}, L_2)$$

- **Self-Adaptive Cycle Detection (`AdaptiveCyclePeriod`)**: The engine feeds closed prices through a 40-bar 3-pole high-pass filter (`HighPass3(close, 40)`) and measures median half-wavelength zero crossings across the last 120 closed bars (requiring $\ge 3$ crossings, otherwise falling back to baseline `TREND_L2 = 24`, `TREND_L1 = 150`). The detected dominant cycle $T$ is clamped to $[14, 36]$ bars and tunes:
  $$L_2 = T \in [14, 36], \quad L_1 = \operatorname{clamp}(\operatorname{round}(T \times 6.25),\, 90,\, 225)$$
  This allows the filter to turn faster during fast London/NY momentum breakouts and smooth out false turns during quiet consolidation.

High-pass filter formula for period $P$:
$$f = \frac{1.414 \times \pi}{P}, \quad a_1 = e^{-f}, \quad c_2 = 2 a_1 \cos(f), \quad c_3 = -a_1^2, \quad c_1 = \frac{1 + c_2 - c_3}{4}$$
$$\text{HP}[i] = c_1 (P_i - 2P_{i-1} + P_{i-2}) + c_2 \text{HP}[i-1] + c_3 \text{HP}[i-2]$$

$$\mathbf{Vote\ 1} = \operatorname{sign}(\text{Trend}) \in \{+1, -1, 0\}$$
*(Note: The Main Panel's `Trend:` label — `Going up`, `Going down`, `Sideways` — reflects `Vote 1` directly.)*

### Component 2 — Timing (Vote 2): Rate of Change (ROC) with Noise Dead-Band
The rate of change of the Precision Trend line is zero at its exact turning peaks and troughs. Its sign indicates the acceleration/onset of a momentum push (`6.28` $\approx 2\pi$):
$$\text{ROC}[i] = \frac{L_2}{6.28} (\text{Trend}[i] - \text{Trend}[i-1])$$

- **Adaptive Noise Dead-Band (`ROC_DEAD_ATR = 0.02`)**: To eliminate single-candle sub-pip micro-flickering, Vote 2 requires ROC momentum to exceed a volatility threshold of $0.02 \times \text{ATR}_{14}$ before awarding a vote:

$$\mathbf{Vote\ 2} = \begin{cases} +1 & \text{if } \text{ROC}[last] > +0.02 \times \text{ATR} \\ -1 & \text{if } \text{ROC}[last] < -0.02 \times \text{ATR} \\ 0 & \text{otherwise (neutral/noise)} \end{cases}$$

### Component 3 — Structure (Vote 3): Dow Theory Swing Structure & Displacement
Vote 3 ensures that a score of $\pm 2$ is an independent structural measurement, combining 20-bar net displacement with Dow Theory swing high/low validation:
$$\text{Move} = \text{Close}[i] - \text{Close}[i - 20]$$
$$\text{DeadBand} = 0.25 \times \text{ATR}_{14}$$

- **Swing Structure Validation**:
  - Across the 20-bar window, local swing highs and swing lows are tracked.
  - **Bullish (+1)**: Requires $\text{Move} > +\text{DeadBand}$ AND confirms no Lower Low structure break has occurred.
  - **Bearish (-1)**: Requires $\text{Move} < -\text{DeadBand}$ AND confirms no Higher High structure break has occurred.
  - If market structure has broken in the opposing direction despite the net displacement, Vote 3 votes 0.

$$\mathbf{Vote\ 3} = \begin{cases} +1 & \text{if Bullish Move \& Valid Structure} \\ -1 & \text{if Bearish Move \& Valid Structure} \\ 0 & \text{otherwise} \end{cases}$$

### Market Filter Gate: Kaufman Efficiency Ratio (ER)
Measures net directional progress divided by total market travel:
$$\text{ER} = \frac{|\text{Close}[i] - \text{Close}[i-20]|}{\sum_{k=0}^{19} |\text{Close}[i-k] - \text{Close}[i-k-1]|}$$
- If $\text{ER} < 0.10$ (`ER_DEAD`): Market is flat noise. Trade is blocked with the reason: `quiet — nothing worth trading`.

### Tick Volume Confirmation Gate (`VOL_RATIO_MIN = 0.50`)
- Compares the finished bar's tick volume against the **20 closed bars that preceded it**. The bar under test is deliberately excluded from its own baseline.
- If market volume has dried up ($< 50\%$ of average), an aggressive `3/3` Market Order is automatically stepped down to a **Pending Limit Order**, protecting against illiquid rollover spread spikes.
- Gracefully permits trading if the broker feed does not provide tick volume.

> **Why the bar excludes itself:** the baseline used to be a moving average that *included* the bar being judged, so a thin bar dragged down the very number it was measured against and could pass a test it should have failed — a bar sitting at 49% of the surrounding volume cleared a 50% gate. `research/verify_regime_fixes.py` pins this behaviour.

### Regime Classification: Rolling Hurst Exponent (H)
Calculated via variance-scaling over a **per-timeframe window sized to a fixed span** (`HURST_SPAN_HOURS = 128 h`), not one bar count shared by all three rows:

| Row | Window | Real history behind the label |
|---|---|---|
| M5 | 1536 bars | 128 h (5.3 days) |
| M15 | 512 bars | 128 h (5.3 days) |
| M30 | 256 bars | 128 h (5.3 days) |

- **Steady ($H > 0.55$)**: The estimator labels the observed series persistent; it does not guarantee trend continuation.
- **Mixed ($0.45 \le H \le 0.55$)**: Random walk / balanced market.
- **Choppy ($H < 0.45$)**: The estimator labels the observed series anti-persistent; it does not guarantee a reversal.

> **Why a span and not a bar count:** 256 bars was 21 hours on M5 but 128 hours on M30, so the noisiest row was judged on one sixth of the evidence. All three rows now see the same stretch of market. M30 lands on 256 bars — exactly where it always was.

#### Where the M5 label comes from (`InpM5RegimeFrom`)
M5's own Hurst is still measured, but it is computed from 5-minute returns, and every quote bouncing between bid and ask makes short-horizon returns look mean-reverting. That drags the estimate down. M5 may therefore read its label from a slower row:

| Setting | Meaning |
|---|---|
| `Own` (0) | M5 keeps its own label — the original behaviour |
| `M15` (1) | **Shipped default.** M5 borrows M15's label (15-minute sampling) |
| `M30` (2) | M5 borrows M30's label (30-minute sampling) |

This **borrows** a label; it does not require the two rows to **agree**. Requiring agreement would be actively harmful: an M5 row that reads Choppy most of the time would only be permitted to trade when the higher row was Choppy too — blocking every trend and allowing only chop. `research/verify_regime_fixes.py` demonstrates this explicitly.

When M5 borrows, the panel names the source (`Choppy<-M15`) so a borrowed label can never be mistaken for M5's own reading. M5's direction, score, trend line, entry, stop and target remain entirely its own — only the regime label moves.

> **CRITICAL RULE:** Hurst never creates a direction or permission by itself. The score publishes the would-be direction and order type; **`InpAllowChoppyTrade` is the operator's separate new-entry permission for a row currently classified Choppy, and `InpAllowMixedTrade` the same for a row classified Mixed.** When a permission is on, the regime chooses the entry style. When it is off, that row places nothing at either 2/3 or 3/3. Neither permission ever closes or abandons a trade that is already open.

---

## 3. Order Placement, Structure & Historical Observations

The total score is the sum of the three votes. With default score thresholds and volume confirmed, ±3 can request a market entry and ±2 a limit. Low volume turns an otherwise 3/3 market request into a limit. Score thresholds are configurable; signal, trend alignment, regime permission, per-lane enablement, master, timer, risk, and broker gates all still apply. In particular, a qualifying BUY/SELL does not imply an executable plan.

### Placement Timing — New Orders Only on That Timeframe's Own Bar Close

Every **new** order (market or limit, including a later replacement after cancellation) is placed **only on the close of that row's own timeframe bar** — an M30 entry, for example, can only be sent on an M30 close. This is enforced, not just intended: `CheckNewBars()` marks each row whose own timeframe printed a new closed bar (`g_freshBar[]`), and `PlacePlanOrder()` — the single funnel through which every new order leaves the terminal — refuses any row without that mark. The mark is spent (cleared) by the bar-close pass itself, so nothing later in the same tick can re-use it.

Consequences:

- **Attaching, restarting, or recompiling the EA** never places an order mid-bar; the first entry waits for that row's next closed bar.
- **Returning to a supported chart** (M5/M15/M30) after an unsupported timeframe, or the **market reopening**, rebuilds the panel but places nothing until the row's next close.
- **A timer/schedule resume** (§8) is not a placement trigger: after it turns ON, each row's first entry still waits for its own next bar close (up to ~5/15/30 minutes per row). The signal used is the one recomputed at that close, never a stale mid-bar reading.
- **Another timeframe's bar closing** (say an M5 close while an M30 row is mid-bar) cannot place or re-place that row's order — not even a retry after a broker rejection, or a re-entry after a tick-level TP close freed the slot.
- This governs **placement only**. Mid-bar ticks continue to apply TP1/TP2/TP3 exits (§5); pending cancellations and pending Entry/SL/TP modifications are never delayed by this rule. An open position’s SL is never modified. A waiting limit order can also still **fill** mid-bar at the broker — that is a fill of an order placed at a bar boundary, not a new placement.

### 3.1 Current structure and entry

The planner uses completed bars and confirmed local swing highs/lows: a pivot has a confirming bar on its right. Current closed-bar structure windows are **36 / 48 / 72** bars for M5 / M15 / M30. A market entry uses the current Ask for BUY or Bid for SELL. A normal limit is placed at the nearest confirmed support below a BUY or resistance above a SELL, on the valid side of the current quote. An allowed Choppy range fade may use the 20-bar box band when ER < 0.40, Bid is inside the box, and its half-height exceeds the spread; otherwise the normal confirmed-swing limit is attempted.

The stop is outside a separate confirmed swing beyond the entry, buffered by at least a tick or the current spread and rounded to the broker tick grid. Opposing confirmed three-bar swings can cap the three targets; no weaker swing is discarded merely to produce a more distant target. For a BUY, the Bid-bar resistance is already on the exit side. For a SELL, each Bid-bar support is converted to an estimated Ask by adding the evaluation spread and rounding up to the tick. Future spread is unknown. If such an opposing swing falls inside the spread at entry, the plan holds rather than discarding it. Structure is refreshed before a new request and before a pending-order refresh, while ordinary price/spread checks are repeated; the quote can still change immediately afterwards. The EA does not widen an invalid price simply to pass broker limits: unavailable or unsuitable structure yields HOLD. Pending orders may refresh on a qualifying new bar, but new levels become authoritative only when the broker confirms modification and the resulting order values are visible. If the broker SL and TP3 would both be unchanged, the EA keeps the old plan, because a later fill could not otherwise distinguish a software-only target change. A 3/3 upgrade requests deletion of the old limit but does not immediately replace it: after broker reconciliation, a later fresh bar may place a new idea.

### 3.2 Completed historical analogs

`ObserveLane` examines up to **12,000 closed Bid bars** on the same symbol and lane, approximately reconstructing past signal score, direction, Hurst regime and market/limit/box style. When M5 borrows M15 or M30's regime, only a slower bar that had completed by the historical decision is used. The reconstruction is approximate, not an exact historical recording of every live signal, spread, broker condition, or trend-filter initial state.

| Lane | Structure lookback | Observation horizon | Intended use |
|---|---:|---:|---|
| M5 | 36 closed bars | 4 bars (~20 minutes) | shorter scalp window |
| M15 | 48 closed bars | 6 bars (~90 minutes) | longer short-term window |
| M30 | 72 closed bars | 8 bars (~4 hours) | longer intraday window |

The replay uses a hypothetical next-bar market probe, or a pending touch **in the first subsequent bar**. For setup geometry it uses the next bar's opening Bid with the **last completed bar's recorded spread** as a proxy; if missing, it falls back to the current spread. The fallback is not historical information and neither proxy reconstructs the true opening tick. Setups whose confirmed opposing swing is inside this estimated entry spread are excluded before `eligible` is incremented, matching the live near-barrier veto. This sample-policy change can alter analog counts and quantiles compared with earlier versions. It counts eligible setups and touched/filled cases separately; only complete windows are used, and filled/probed observation windows do not overlap. On a pending touch, favorable movement in that same bar is ignored because it may have happened before the touch. A stop wins any within-bar ambiguity; after a stop no later favorable movement is included. BUY exits use historical Bid bars and SELL exits approximate Ask using each outcome bar's recorded spread or the current-spread fallback.

For each qualifying case, the maximum favorable travel **before stop** is expressed in multiples of that case's structural risk. At least **30** such completed probes/touches are required. The 50th, 70th and 85th percentiles of that distribution are multiplied by the current structure's risk distance to form TP1/TP2/TP3, then independently capped by up to three nearest opposing swings and rounded to the tick grid. If the targets collapse, fail ordering, do not clear the spread screen, or conflict with broker rules, the plan holds. No ATR multiplier sets entry, SL or TP for a new plan; ATR still supplies the unchanged signal-vote deadbands.

These constants are initial policy choices, **not** proven optimal. The quantiles are not forecast confidence, hit probabilities, or expected returns. Bar spread, a touch, and same-bar ordering are proxies; fills, true Ask, spread spikes, slippage, latency, commissions and broker constraints can differ. The observation window ends even if a real position would remain open. M5 is assessed within its own cost/risk context, not rejected because another lane's target is larger; longer timeframes do not guarantee larger price moves.

---

## 4. Execution, Sizing & Risk Management

### Position sizing and costs

New entries require `ACCOUNT_MARGIN_MODE_RETAIL_HEDGING`; netting/exchange accounts are held because they aggregate positions by symbol and cannot isolate these timeframe lanes. Multiple same-magic positions in one lane suspend software exits and show `MULTIPLE: REVIEW`; manually inspect all broker positions.

With `InpUseRisk=true` and no minimum-lot override, the risk budget is `InpRiskPct` percent of balance at ±2 and twice that at ±3. Lot size uses the planned entry-to-structural-stop distance and point value. If the broker minimum lot would exceed the budget, the plan holds. The fixed-balance ladder and minimum-lot override remain available but do not enforce that budget. TP1 must clear the lane's current spread, and estimated staged reward must be positive. There is no commission input or universal reliable future broker commission quote here: **commission, swap and slippage are excluded** from the screen, lot sizing, and risk/reward estimates. `Fees: not included` is shown in a valid plan. Actual costs and losses may be higher; neither the risk budget nor reward estimate guarantees fill price, maximum loss or net profitability.

Every new order includes planned broker-side SL and TP3. Pending Entry/SL/TP may be modified together before fill; after fill the EA does not intentionally modify SL or TP3. TP1/TP2 are absolute levels recorded at placement or confirmed modification, not percentages of TP3. The actual fill does not move them, so slippage can change actual risk and reward. Stops can gap or slip.

---

## 5. Active Position Lifecycle & Fixed-Exit Contract

### 5.1 Target and trigger rules

- TP1 and TP2 are monitored by the EA on the executable close side: **Bid** for BUY, **Ask** for SELL. TP1 aims to close 70% when volume/step/minimum constraints allow; TP2 aims to leave the broker minimum. At minimum volume there may be no valid partial to send.
- A target at or behind the actual fill is `[SKIP]`; it is not moved to manufacture profit. A successful milestone is `[HIT]`. A partial that leaves a sub-minimum amount to complete a goal is `[PART]`; ambiguous execution is `[REVIEW]`. Rejected close requests remain retryable, while uncertain in-flight requests are reconciled against broker volume or held for human review to avoid a duplicate close.
- TP3 and SL are broker-side. Once the executable quote crosses TP3, the EA waits for the broker-side exit rather than manufacturing lower partials; a broker failure must be checked manually. These protections are not guaranteed fills.
- A partial entry can leave a broker order outstanding. The EA attempts to cancel any same-lane remainder and defers software TP1/TP2 while the remainder remains visible. Broker SL/TP3 remain the only attached exits; partial-fill/remainder behavior requires broker testing.
- TP1/TP2 require the EA and allowed trade requests. The master switch off, unsupported chart, market/terminal restrictions or disconnection can suspend EA management; broker-side SL/TP3 remain subject to broker rules.

### 5.2 New-entry HOLD versus open positions

A direction flip, signal HOLD, cost/data/structure HOLD, risk veto, regime change, timer pause or timeframe disable does not itself close an open position or move its stop. A waiting entry is instead cancelled when its plan/permission becomes invalid. Rejected cancellations are retried and remembered across restart when terminal persistence succeeds; they are not silently refreshed or upgraded. A live order can still fill before cancellation is confirmed. If persistence or broker communication fails, verify/cancel manually.

### 5.3 Placement, modification and uncertainty

The EA writes a target intent before a new order and an update journal before pending modification. It saves 64-bit order/position identities in split fields and freezes independent absolute TP1/TP2. Confirmed broker levels select the appropriate saved/journaled target set on restart. A rejected modification does not silently replace the original levels.

The EA does not erase a cancelled pending's slot until broker history proves it ended; this preserves target state if it partially filled during cancellation. A timeout, connection error, generic processing error or asynchronous order submission can leave the outcome unknown. The placement intent is retained and the affected lane is held rather than sending a duplicate. If the order/position later appears, recovery checks its broker state. If nothing appears, an operator must verify broker orders, positions and history before clearing the intent; see §11. Never assume a missing terminal update means no broker fill.

### 5.4 Restart, manual action and diary recovery

- New-format orders carry `SEA3_` comments. An unresolved saved identity is retained and blocks new entries until broker history proves the order/position ended; an empty terminal list during reconnect is not proof of closure. A matching saved identity/journal and broker SL/TP3 allow independent targets and milestone state to be recovered; a different or externally modified position does not get guessed targets. Missing TP1/TP2 are shown as unavailable, while existing broker SL/TP3 are left untouched for manual review.
- A positively identified pre-upgrade `SimpleEA_` **open position** attempts exact target recovery from its diary, then the old TP3-ratio reconstruction only as a one-time legacy fallback. An unversioned old pending order is cancelled rather than assigned guessed targets. Broker comment stripping, missing files, manual SL/TP changes and upgrade races may prevent safe recovery.
- Execution milestone state is stored separately from diary price-reach observations; reaching a price does not by itself prove a partial close. Existing legacy flags are migrated when identifiable. If the journal reports `[REVIEW]`, inspect actual positions and deal history before any manual action.
- Back up terminal global variables and the diary before upgrading. Broker-side closure while offline is reconciled through deal history where available. A manually closed position can be followed by a later eligible new entry unless entry is disabled.

---

## 6. Parameters Reference Table

| Group | Parameter | Shipped Default | Meaning & Function |
|---|---|---|---|
| **Autotrading** | `InpAutoTrading` | `true` | Master for trade requests and open-position management; `false` is read-only and does not cancel or manage positions. |
| | `InpUseAutoSchedule` | `false` | Enable daily placement schedule window (PC local time). |
| | `InpAutoStartTime` | `"08:00"` | Daily trading start time (`HH:MM`, PC local time). |
| | `InpAutoEndTime` | `"17:00"` | Daily trading stop time (`HH:MM`, PC local). At the stop minute, cancellation of waiting pendings is requested and no new orders are placed; open trades keep being managed (see §8). |
| | `InpAutoOffHours` | `0` | One-shot pause in hours from when applied (`48` = 2-day pause; `0` = off/re-arm). Persisted across restarts; same rules as the daily window (see §8). |
| | `InpRequireM15M30SameTrend` | `false` | Timeframe alignment: `false` = untied; `true` = both M15 and M30 must have matching trade directions (`BUY` or `SELL`) to place. |
| | `InpMagicBase` | `202610` | Base magic number (`+0` M5, `+1` M15, `+2` M30). |
| | `InpAutoTradeM5` | `true` | **Master switch for M5.** `false` = no new M5 order of any kind; a waiting M5 pending is cancelled; an open M5 trade keeps full management. M15 and M30 are unaffected. The row keeps reading, while its plan shows the entry HOLD. |
| | `InpAutoTradeM15` | `true` | As above, for M15. |
| | `InpAutoTradeM30` | `true` | As above, for M30. |
| **Signal, Regime & Range** | `InpBuyScore` | `2` | Score $\ge$ this triggers BUY. |
| | `InpSellScore` | `-2` | Score $\le$ this triggers SELL. |
| | `InpAllowChoppyTrade` | `true` | **New-entry permission** for a row currently reading Choppy. `false` = no new 2/3 limit or 3/3 market order on that row; a waiting pending is cancelled when the row turns Choppy; already-open trades keep normal management. Header Line 2's `Choppy Trade` mirrors this input. |
| | `InpAllowMixedTrade` | `true` | **New-entry permission** for a row currently reading Mixed — the same shape as the Choppy permission. `false` = no new order on a Mixed row; a waiting pending is cancelled when the row turns Mixed; already-open trades keep normal management. Mixed is the largest bucket, so switching this off removes well over half of all entries. |
| | `InpM5RegimeFrom` | `M15` | Where the **M5 row's regime label** comes from: `Own` / `M15` / `M30`. This borrows the label — it never requires the two rows to agree. M5's direction, score, trend line, entry, stop and target stay its own. When borrowing, the panel names the source (`Choppy<-M15`). |
| | `InpM5RequireHigher` | `false` | `true` = M5 may only place when M15's trade direction matches. Ships off. The direction tie can delay or filter entries; its impact depends on the feed and requires testing. |
| | `InpRangeMode` | `true` | **Entry style only**, after Choppy permission is on: use the 20-bar box band for an allowed Choppy 2/3 when the box is usable; `false` (or an unusable box) = confirmed-swing limit. |
| **Trade Plan & Sizing**| `InpUseRisk` | `true` | Risk % sizing mode (`false` = fixed lot ladder per 1,000 balance). |
| | `InpRiskPct` | `0.5` | Risk % per trade at score $\pm 2$; score $\pm 3$ risks double (1.0%). |
| | `InpUseMinLot` | `false` | Override sizing to force symbol's minimum lot. |
| **Market Closed** | `InpDetectClosed` | `true` | Collapse panel to `Market Closed` when market is shut. |
| | `InpClosedStaleMin` | `30` | Quote age in minutes that counts as market closed (0 = off). |
| **Panels & Display** | `InpPanelX` / `InpPanelY` | `12` / `24` | Main panel coordinates in pixels. |
| | `InpAutoPanelPos` | `Bottom` | 2nd (Autotrading) panel position: `Right` or `Bottom`. The optional History panel takes the opposite side. |
| | `InpShowHealth` | `false` | Show the large 3rd (**History**) panel. This controls display only: the calibration diary records whether the panel is shown or not (see §9). |
| | `InpFontSize` | `10` | Font size (all panel dimensions scale with font size). |
| | `InpFont` | `"Consolas"` | Monospaced font name. |
| | `InpBgColor` | `C'48,48,48'` | Panel background colour. |
| | `InpTitleColor` | `clrWhite` | Header title and primary highlight colour. |
| | `InpBuyColor` | `clrLime` | Bullish (`Going up` / `BUY`), active state, and profit-locked `SL` colour. |
| | `InpSellColor` | `clrTomato` | Bearish (`Going down` / `SELL`), risk-side `SL`, and `Off` alert colour. |
| | `InpHoldColor` | `clrSilver` | Neutral (`Sideways`) colour. |

### Baked-In Calibration Profile (`INTERNALS`)

These code constants are policy choices, not verified optimal parameters; validate them on the intended broker and symbol:

| Category | Constant(s) | Value | Role |
|---|---|---|---|
| **Signal & Filters** | `TREND_L1` / `TREND_L2` | `150` / `24` | Baseline Precision Trend periods (self-adaptive $L_2 \in [14,36]$, $L_1 \in [90,225]$) |
| | `ROC_DEAD_ATR` | `0.02` | Vote 2 ROC noise dead-band ($\times \text{ATR}_{14}$) |
| | `STRUCT_PERIOD` / `STRUCT_DEAD_ATR` | `20` / `0.25` | Vote 3 displacement & swing-structure window and ATR floor |
| | `ER_PERIOD` / `ER_DEAD` | `20` / `0.10` | Kaufman Efficiency Ratio window and flat-market `HOLD` gate |
| | `VOL_RATIO_MIN` | `0.50` | Minimum 20-bar tick-volume ratio required for `3/3` Market execution |
| | `HURST_SPAN_HOURS` | `128.0` | Real history behind a regime label. Each row's bar count is derived from this, so all three judge the same stretch of market. |
| | `HURST_WINDOW_M5` / `_M15` / `_M30` | `1536` / `512` / `256` | Per-row Hurst windows in bars — each equals 128 h. M30 lands on 256, exactly where it always was. |
| | `HURST_TREND` / `HURST_REVERT` | `0.55` / `0.45` | Steady / Mixed / Choppy boundaries (identical on every row) |
| | `BARS_BASE` / `BARS_WARMUP_X` / `BARS_MAX` | `700` / `4` / `50000` | Closed-bar history depth pulled per timeframe. The pull sizes itself to the longest Hurst window (1586 bars); if a broker's history is too shallow it falls back to `BARS_BASE` and the long window reads `Mixed`, rather than the row being lost. |
| **Signal ATR** | `ATR_PERIOD` | `14` | Closed-bar ATR for signal deadbands only; it does not set new plan prices. |
| **Structure** | `STRUCTURE_M5` / `_M15` / `_M30` | `36` / `48` / `72` | Closed-bar confirmed-swing windows. |
| **Historical analogs** | `OBS_HORIZON_M5` / `_M15` / `_M30` | `4` / `6` / `8` | Complete observation horizons in bars. |
| | `OBS_HISTORY_BARS` / `OBS_MIN_CASES` | `12000` / `30` | Maximum history and minimum completed hypothetical probes/touches. |
| | `OBS_Q1` / `OBS_Q2` / `OBS_Q3` | `0.50` / `0.70` / `0.85` | Percentiles of pre-stop favorable travel in historical risk units, not confidence. |
| **Sizing** | `RISK_SCORE3_X` / `BAL_PER_001` / `SCORE3_FACTOR` | `2.0` / `1000.0` / `1.5` | Score-3 risk multiplier and fixed-ladder constants. |
| **Range Box** | `RANGE_BARS` / `RANGE_ER_MAX` / `RANGE_VALID_BARS` | `20` / `0.40` / `8` | Box lookback, maximum ER and pending validity. |
| **Pending** | `VALID_BARS` | `3` | Normal pending validity in bars. |
| **Diary & Health** | `DIARY_VERSION` / `HEALTH_MIN_CLOSED` / `HEALTH_BE_EPS_R` | `1` / `30` / `0.05` | CSV schema version, 30-trade learning floor, and $\pm 0.05\text{R}$ scratch band |

---

## 7. Chart Timeframe Rule & Market Closed Handling

1. **Strict Chart Timeframe Policy**:
   - Calibrated exclusively for **M5, M15, and M30 charts**.
   - Dropping the EA on any unsupported timeframe (e.g., M1, H1, H4, D1) triggers an immediate collapse:
     - The panel shrinks to: `SimpleEA2.0 | Incompatible chart. Switch to M5/M15/M30.`
     - **Zero background calculation occurs**: no price data is pulled, no indicators are evaluated, and no orders are executed.
2. **Market Closed Detection**:
   - Detects market closures through: broker trade mode (`SYMBOL_TRADE_MODE_DISABLED`), symbol trade session hours vs. server time, quote staleness $\ge 30$ minutes, or broker return code 10018 (`MARKET_CLOSED`).
   - Collapses to a red `Market Closed` notice and stands down completely until trading resumes.

---

## 8. Autotrading Timer & One-Shot Pause

SimpleEA has two independent gates on **entering** trades. Both are optional, and **both are placement gates only** — neither freezes the management of a position that is already open.

1. **Daily window** (`InpUseAutoSchedule`, `InpAutoStartTime`, `InpAutoEndTime`) — a repeating `HH:MM`–`HH:MM` window read from the **PC/VPS local clock** (`TimeLocal`), *not* broker server time.
2. **One-shot pause** (`InpAutoOffHours`) — "stop taking new trades for N hours, then resume automatically" (`48` = 2 days). The deadline is stored in **GMT**, so the duration is real elapsed time even across a daylight-saving change.

Both are layered **on top of** the existing permission checks: master switch, supported chart (M5/M15/M30), market open, terminal/account "algo trading allowed" flags, the score/ER gates, and the per-row `InpAllowChoppyTrade` Choppy permission must all still pass.

### 8.1 What "timer OFF" does — and deliberately does not do

| Action | While the timer is OFF (outside the window, or during a pause) |
|---|---|
| Open a new market order | **Blocked** |
| Place / refresh a waiting pending limit order | **Blocked**; cancellation is requested and retried if rejected. The broker may fill before cancellation succeeds; confirm its state. |
| TP1/TP2/TP3 exits | **Fully active** — the fixed broker SL remains unchanged; no trailing or signal-based exit runs |
| Panel analysis and Trade Plan | Analysis continues; the timer blocks placement regardless of displayed advice. |

The split is deliberate. Pending orders are *unfilled entries resting at the broker*, so cancellation is requested on an OFF transition. Open trades keep their broker-side fixed SL and EA-managed TP exits; the timer never moves their stop.

When the timer turns back ON, nothing is replayed or "caught up": placement is allowed again, but — like every new order — the first entry still waits for the close of that timeframe's own next bar (attaching/restarting the EA follows the same rule; only TP exits, pending cancellations and pending modifications act mid-bar). Each transition is written to the Experts log.

### 8.2 One-shot pause persistence

- The deadline and the requested hours are saved in terminal GlobalVariables keyed per **account + symbol + magic base**, so a restart neither extends the pause nor restarts a finished one, and other charts never share it.
- When it expires, the input still *shows* the number (inputs cannot be rewritten by code), but the **effective** pause is `0` and the panel says so.
- To run another pause: set `InpAutoOffHours = 0` (clears the record), then the hours again. `0` also re-arms after a completed request.

### 8.3 Time-window rules and validation

- Times are `HH:MM` (or `H:MM`) between `00:00` and `23:59`; anything else makes the EA refuse to initialise with an explicit log message, so a typo cannot silently create a 24-hour window.
- Start **must differ** from stop. For 24-hour autotrading, switch the schedule off — do not set `08:00`–`08:00`.
- **Overnight windows are supported**: `22:00`–`06:00` means 22:00–23:59 plus 00:00–05:59, and the countdown targets tonight's 22:00.
- The stop minute is exclusive: at exactly `17:00` the window already reads `Paused`.

### 8.4 On-screen reporting

- **Header line 1** reports the effective state (`Off` / `On` / `Timer Pause`) plus the `Resume …` countdown to the moment placement is allowed again — see §1.
- **Header line 2** names the setting responsible (`Timer: Paused 08:00-17:00`, `Timer: Paused by request`, …) — see §1.
- The **2nd (Autotrading) panel** appears only when an order exists and keeps its own header (`Autotrading | Exits : TP/SL | Stoploss : Fixed/Missing | SYMBOL`); it is not gated by the timer, because it reports trades that are still being managed.
- Header line 1 also carries the diary's `Day: S/W/L` counts; the timer does not stop those counts from reflecting closes of trades that remain under management.
- **Notice panels replace both header lines.** When the market is closed or the chart timeframe is unsupported, the panel collapses to a one-line notice, so no countdown is shown there even though the timer keeps counting.
- Long pauses also print a one-line confirmation to the Experts log when set, when continuing after a restart, and when completed.

### 8.5 Notes and caveats

- The daily window follows the **PC/VPS clock**. Moving the EA to a VPS in another timezone moves `08:00` with it, and a clock left wrong shifts the window.
- "Timer allows placement" is not the same as "an order will be sent": the signal, score gate, trend gate, Choppy permission and broker conditions must also agree. The header can legitimately read `On` while nothing is placed.
- With the master and broker trading available, loading during an OFF period requests cancellation of this EA's pending entries; broker rejection or disconnection can prevent or delay it.
- A **resume is not a placement trigger**: after the timer turns back ON, the first new order still waits for that row's own next bar close (§3, *Placement Timing*). The same applies right after the EA is attached or restarted.
- The timer never closes positions. It is a schedule and a snooze button for *entering* trades, not a "close everything at 17:00" switch.

---

## 9. Calibration-Health Diary, Day Counts & History Panel

SimpleEA's calibration is deliberately fixed. The diary gives that fixed calibration a **memory, not a second brain**: it can warn that a symbol/timeframe lane looks less healthy than it used to and suggest what to test first, but it **never changes** a target, stop, score gate, risk setting, or on/off switch by itself.

### 9.1 Counting rules

The diary's letters have exact meanings:

| Count | Meaning |
|---|---|
| **`S`** | Signals SimpleEA acted on: the broker accepted one new market or pending order idea. Advice that was never placed is not an `S`. Repricing a waiting pending is still the same `S`; after a cancelled pending, a later fresh-bar placement is a separate idea. |
| **`W`** | An original trade that is now fully closed with a final net result greater than `+0.05R`, including every TP1/TP2 partial exit. |
| **`L`** | An original trade that is now fully closed with a final net result less than `-0.05R`. |
| **`BE`** | A fully closed scratch: final result between `-0.05R` and `+0.05R`. |
| **`Open`** | A diary idea currently known as a filled/open position. |
| **`Wait`** | A diary idea currently known as an unfilled pending order. |
| **`Exp`** | A pending idea that ended unfilled (cancelled, vetoed, expired, rejected, flipped before fill, or cancelled by the timer/Choppy permission). |

Lifetime totals reconcile:

`All S = W + L + BE + Open + Wait + Exp`

`Day` is the **PC/VPS local day**, matching the autotrading timer's clock. A subtle but important point: **daily `S` is counted by placement day**, while daily `W`, `L`, `BE`, and `Exp` are counted by the day the original idea finally closed or expired. A winner that closes today can therefore belong to an `S` placed yesterday; the lifetime `All` totals are the place where the identity above reconciles exactly.

`R` is the final net money result divided by the original planned risk:

`R = net result / (point value at placement × original lot × planned stop points)`

The point value and planned stop are frozen in the diary row at placement (a still-unfilled pending that is legitimately repriced can update its planned stop before fill). Net result uses MT5 deal profit, swap, and commission. If a position closes a tick before its final deal is visible in history, SimpleEA first records a provisional estimate from the live P/L and then corrects that row from deal history on a later sync.

### 9.2 What one diary row records — and where it lives

Normally there is **one row per confirmed placed order idea**, not one row per tick or partial exit. An asynchronous or uncertain placement may remain untracked until broker/diary reconciliation; do not treat the diary as the broker ledger. Each row stores:

- symbol identity through the diary file itself, plus timeframe, direction, and the score frozen at placement;
- regime at placement (`Steady` / `Mixed` / `Choppy`) and entry style (market, pullback, box, Choppy pullback, or Choppy market);
- placement and final close/expiry times in broker-server and PC-local form, plus their PC-local day keys;
- original lot, entry price, planned stop points, TP1/TP2/TP3 points, and the point value at placement;
- entry spread as a percentage of the TP1 distance (for a pending, measured when the fill is noticed);
- furthest favourable progress toward TP1, capped at 300% so one extraordinary runner cannot dominate a median forever;
- whether TP1, TP2, and TP3 were reached;
- TP1/TP2/TP3 progress, the final closing deal's progress toward TP1, and whether that final deal's broker reason was a stop-loss exit;
- final status/outcome, result in `R`, a compact exit reason, and whether the result is still provisional;
- the relevant settings then in force: base risk %, risk/min-lot mode, fixed SL, Choppy permission, and Range Mode.

The file is named for **account + symbol + magic base** (for example, `SimpleEA_Diary_<login>_<symbol>_<magic>.csv`) and is kept in MT5's Common Files area on a live terminal (the tester uses its own file area). Its first line records the local date on which this symbol's diary began. The original 40-field rows and later 50-field rows remain readable. Eight obsolete CSV columns are now reserved: they are ignored when old rows are loaded and written as neutral defaults when rows are saved. No obsolete trailing value is stored in diary state or included in health statistics. Saves are written through a temporary file and moved into place so an interrupted save does not leave half-written rows. If an existing diary cannot be read (or declares a diary format this EA build does not understand), SimpleEA logs that fact and refuses to overwrite it blind; that run's new rows are kept in memory until the file problem is fixed and the EA is restarted. A year of placed ideas is still a small file because ticks are not stored.

History begins when the diary feature first runs for that account/symbol/magic. A position or pending that already existed before that moment has no diary row and is deliberately left **untracked** rather than reconstructed from guesses. Orders placed manually or by another EA/magic are likewise not diary signals. If SimpleEA later finds that one of its tracked positions closed at the broker while the EA was away, it reconciles that row from deal history; a tracked pending that ended at the broker is reconciled from order history. In particular, if a pending filled and the resulting position closed while ticks were interrupted, the position identifier in order history makes that row a closed `W`/`L`/`BE` trade — it is not misreported as an unfilled `Exp`.

> Do not run two SimpleEA instances with the same account, symbol, and magic base against the same diary file. `OnInit()` acquires an exclusive `.lock` file (`SimpleEA_Diary_<login>_<symbol>_<magic>.csv.lock`) for the entire run and refuses initialization (`INIT_FAILED`) if another instance already holds it.

### 9.3 What changes on the Main Panel

The packed Main Panel gains only three compact things:

1. **Header Day counts.** After the Autotrading state (and after `Resume ...` when present), line 1 shows `| Day: S 14  W 6  L 4`. That text is measured in the same header-width calculation as the word, the countdown, and the right-hand symbol block, so it uses existing blank space when there is enough and widens the header only when there is not; it cannot collide with the symbol.
2. **One health label per timeframe row.** In the blank left-hand strip of the Signal line, the row shows one short verdict:
   - `Health: Learning` — fewer than 30 fully closed diary trades on that lane;
   - `Health: OK` — at least 30 closed trades and no current warning;
   - `Cost: Watch`, `TP1: Watch`, `Score: Watch`, `Box: Watch`, or `Chop: Watch`;
   - the same names with `Poor` instead of `Watch`.
   A trailing `+` means another health issue is also present; the label names the primary one.
3. **One temporary bottom note, only for Poor.** Watch, OK, and Learning never add a line. When any lane is Poor, one line appears below the trade plans naming both the problem and the safest first step. If the chart-timeframe lane is Poor it owns that line; otherwise the first Poor lane is shown and any others are counted as `(+N more)`. The line disappears when no lane is Poor.

The row labels and Day counts are visible whether `InpShowHealth` is on or off. The diary also continues recording while the big History panel is hidden, so switching the panel on later does not start from zero.

### 9.4 The optional History panel (`InpShowHealth`)

`InpShowHealth = false` is the shipped default. It controls the **large third panel only**; it does not start or stop diary recording.

When switched on, the `History` panel is for the chart's current symbol and states the date its diary began. It sits **opposite** the Autotrading panel:

| `InpAutoPanelPos` | Autotrading panel | History panel |
|---|---|---|
| `Right` | Right of Main Panel | **Below** the Main Panel |
| `Bottom` | Below the Main Panel | **Right** of the Main Panel |

Its content is:

```text
History                                      |  XAUUSD  |  Since 2026.10.26
Day: S 14  W 6  L 4  BE 1  Exp 2
All: S 212  W 91  L 84  BE 12  Open 1  Wait 1  Exp 24  Net +12.4R
M5  Health: Cost: Poor+
  All: S 80 W 30 L 35 BE 3 Open 1 Wait 0 Exp 11 | Win 44% | Net -4.2R
  Score 2/3: W 20 L 22 TP1 48% (45 closed) | 3/3: W 15 L 10 TP1 57% (28 closed)
  Last 30: W 11 L 16 BE 3 | TP1 37% Peak 54% Cost 14% | Net -3.1R
  Exits: TP1 partial | TP2 partial | TP3 full | fixed broker SL
  First step: Use minimum lot or avoid expensive hours first.
...
Diary suggests first steps; it never changes settings.
```

For each timeframe, the panel deliberately shows **both lifetime and recent health**. Lifetime totals say what the lane has done overall; the newest closed trades say whether it is decaying now. A lane can therefore have a respectable lifetime record and still correctly read `Poor` because its latest block has deteriorated.

The `Exits` line is a fixed policy reminder, not a performance statistic: TP1 and TP2 take their valid partials, TP3 closes the remainder, and the broker SL stays at its entry level. It does not affect the lane's health label or suggested first step.

Older diary rows may contain trailing-era fields. They remain parseable for compatibility, but the current History panel does not present those fields as a live feature and new rows are written with trailing disabled.

### 9.5 How a lane is judged

Health is judged separately for each symbol/timeframe lane.

- **Learning floor:** fewer than **30 fully closed** diary trades means `Health: Learning`, whatever those first trades did.
- **Recent block:** once available, the newest **30 closed** trades are judged. The preceding block (up to **30 closed** trades) forms the baseline; a fall/rise comparison is only used once at least 15 baseline trades (or 15 baseline cost readings) exist.
- **Persistence:** a Poor verdict needs the weakness in both chronological 15-trade halves of the recent 30 (score and entry-style splits apply the same idea across their recent evidence). A one-sided bad run is normally Watch, not Poor.

#### Follow-through — are trades still reaching TP1?

The recent median peak is the typical furthest progress toward TP1.

- **Watch** when TP1 reach is under 45%, the typical peak is under 65% of TP1, or TP1 reach has fallen at least 15 percentage points from the previous 30.
- **Poor** when TP1 reach is under 30%, the typical peak is under 45%, or TP1 reach has fallen at least 25 percentage points while now sitting under 45% — **and** both recent halves are weak (TP1 reach under 45% or typical peak under 65%).
- A Poor follow-through lane is described as **near-TP1 reversal** when the typical peak is at least 50%, or at least 35% of trades reach 70–99% of TP1 without taking it; otherwise it is described as **barely moving**.

#### Cost — what share of TP1 does the spread eat?

Cost is the median entry spread divided by the TP1 distance for the recent closed trades with a recorded cost (at least 20 are required).

- **Watch** when the median Cost is above 8% of TP1, or it has risen at least 4 percentage points from the previous block.
- **Poor** when the median Cost is at least 12%, or it has risen at least 7 percentage points to at least 10% — **and** both recent halves have a median Cost of at least 10%.

#### Score — does 3/3 still earn its stronger treatment?

The score check uses up to the newest 60 closed trades and requires at least 10 closed trades at each of 2/3 and 3/3.

- **Watch** when 3/3 trails 2/3 by at least 10 percentage points of TP1 reach or by at least `0.15R` average result.
- **Poor** when 3/3 trails by at least 20 percentage points of TP1 reach **and** at least `0.20R` average result, and in each chronological half it fails to lead on at least one of TP1 reach/average `R` (at least five of each score per half).

#### Entry style / regime — is one identifiable part weak?

Box trades are compared with non-box trades, and all Choppy-regime trades with non-Choppy trades, over up to the newest 60 closed trades. At least 15 closed trades are required on each side of a split.

- **Watch** when the subset trails by at least 12 percentage points of TP1 reach or `0.15R` average result.
- **Poor** when it trails by at least 20 percentage points **and** `0.20R`, its own average is not above zero, and the weakness is present in both chronological halves.
- If the box subset is the weak part, the label is `Box`; if Choppy entries in general are weak, it is `Chop`.

When several checks warn at once, the row label names the primary issue in this order: Cost, entry style/regime, general TP1 follow-through, then Score. That order starts with the most immediate/specific explanation and ends with the broadest score question.

### 9.6 Suggested first fixes — suggestions only

| Verdict | First step SimpleEA suggests |
|---|---|
| `Cost: Poor` | Use the minimum lot or avoid the expensive hours first. |
| `TP1: Poor` — trades near TP1 then reverse | Test a nearer TP1 first; do not change the live target yet. |
| `TP1: Poor` — trades barely move | Lower risk; consider 3/3-only while reviewing that lane. |
| `Score: Poor` | Keep risk low and review that lane before changing score rules. |
| `Box: Poor` | Test Range Mode Off first (a global switch on that EA instance). |
| `Chop: Poor` | Consider Choppy Trade Off first (a global switch on that EA instance). |
| Any `Watch` | No change yet; keep watching the named measure. |
| `Health: OK` | No change suggested. |
| `Health: Learning` | Keep collecting; health starts at 30 closed trades. |

These are deliberately *first steps to test or consider*, not instructions the EA executes. In particular, a nearer TP1, a score-rule change, or any recalibration should be tested outside the live lane first. The diary's job is to make decay visible early enough for a human decision; the fixed thresholds and windows remain fixed until the operator changes the code; the historical plan levels themselves adapt with new bars.

---

## 10. Maintenance Log — Corrected Defects & Added Controls

This section records a review of `SimpleAdvisor.mq5` against the purpose stated in its own header, and the changes that came out of it. Items 1–3 are unambiguous defects; 4–5 are structural gaps between what the EA claims to be (a *multi-timeframe* tool) and what the code did.

| # | Item | Nature | Effect of the fix |
|---|---|---|---|
| 1 | **Volume gate included the bar it judged** | Defect | `IsVolumeConfirmed()` compared the bar under test against a 20-bar average that *contained* that same bar, so a thin bar dragged down the number it was measured against. A bar at 49% of the surrounding volume passed a 50% gate. The baseline now starts at the preceding closed bar. |
| 2 | **`HasTradedOnBar()` failed open and mutated state** | Defect | Named as a question, it wrote `g_auto[].lastSignalBar`; and when `HistorySelect()` failed it returned *"not traded"* — the one answer that authorises a **duplicate order on a bar that already has one**. Every doubt now blocks, and the function is a pure query. `PlacePlanOrder()` stamps the bar itself. |
| 3 | **`HurstExponent()` could read `close[-1]`** | Latent defect | The guard `i + 1 < window` admitted `i == window - 1`, making `start == 0` and the innermost read `close[start - 1]`. Never fired with the shipped numbers, but it made the window unsafe to change — which item 5 then does. Guard is now `i < window`, so the smallest index touched is 0. |
| 4 | **The rows never informed each other** | Structural gap | `EvaluateRow()` reads only its own bars, and `TrendMatchForTF()` exempted M5 *by name* (`if(i == 0 ...)`), so no setting anywhere could give M5 higher-timeframe context. `EvaluateAll()` now runs slowest-first, M5 may borrow a slower row's regime label (`InpM5RegimeFrom`), and the M5 direction tie is a switch (`InpM5RequireHigher`) rather than a hard-coded exclusion. |
| 5 | **Regime window counted bars, not time** | Calibration gap | One window (256 bars) meant 21 h of history on M5 and 128 h on M30 — the noisiest row judged on a sixth of the evidence. Now `HURST_SPAN_HOURS = 128 h` with each row's bar count derived from it: M5 1536, M15 512, M30 256 (unchanged). |

### Fixed-exit simplification (current)

The former trailing/profit-floor/score/flip/box open-position management was removed as one contract change. New orders now always carry the planned SL and TP3; after fill only TP1/TP2 partials, TP3 full close and the unchanged broker SL remain. The signal core was retained; the later structure/history change replaced pending-entry and plan pricing. The obsolete exit inputs were removed, and the diary parser still accepts older records.

### New operator controls

| Input | Default | Purpose |
|---|---|---|
| `InpAutoTradeM5` / `M15` / `M30` | `true` / `true` / `true` | Master per-timeframe switch. Off = no new orders and pending cancelled on that row; open trades keep full management. |
| `InpAllowMixedTrade` | `true` | New-entry permission for Mixed rows, mirroring `InpAllowChoppyTrade`. |
| `InpM5RegimeFrom` | `M15` | Where M5's regime label comes from (Own / M15 / M30). |
| `InpM5RequireHigher` | `false` | Optional M5↔M15 direction tie. |

Eligible new entries are enabled by default under the `InpAutoTrading=true` master and the remaining lane, timer, account and plan gates.

### Why borrowing and not matching

A "M5 and M15 must have the same regime" rule was considered and rejected. Because M5 reads Choppy most of the time, such a gate would only permit a trade when the higher row was *also* Choppy — blocking every trend and allowing only chop. `research/verify_regime_fixes.py` demonstrates this. Borrowing the label is implemented; requiring agreement is not, and should not be.

### Measurement behind items 4 and 5

Two research scripts were added, both runnable with numpy alone and needing no market data:

- `research/hurst_noise_bias.py` — generates series with a *known* Hurst and measures how far SimpleEA's estimator drifts under bid/ask bounce, at M5, M15 and M30 sampling.
- `research/hurst_noise_fixes.py` — compares candidate fixes against that known ground truth.

Their finding, which shaped the design: **lengthening M5's window does not fix the M5 regime problem.** It lowers variance (sd 0.067 → 0.027) but leaves the bias essentially untouched (62.5% → 57.4% mislabelling of a true trend). The bias comes from the *sampling frequency*, not the sample count — bounce noise does not average away when bars are summed, because the added increments telescope. Only sampling less often removes it:

| Regime label source | Mislabels a true trend (H = 0.65) at realistic spread |
|---|---|
| M5, as shipped | 62.5% |
| M5, 1536-bar window | 57.4% |
| M5, skipping the shortest scales | 31.8% |
| **M15 (shipped default)** | **7.7%** |
| M30 | 2.6% |

So item 5 supplies evidence and comparability; item 4 is what makes M5's label trustworthy. They are complementary, not alternatives.

Caveat worth repeating: those figures come from simulated series with a known Hurst. The mechanism is proven; the magnitude on any real symbol depends on that symbol's spread-to-bar-size ratio, which has not been measured on live data.

### Verification

`research/verify_regime_fixes.py` and `research/verify_timeframe_gate.py` remain simplified models. The plan and execution wrappers now run current source contracts and C++ harnesses that extract selected production functions with synthetic data and MT5 stubs. None is an MQL compiler or an execution/market backtest; see §11.


---

## 11. Manual MT5 and Broker Validation Checklist

**This is a release gate, not a claim that these checks have already passed.** Perform on the intended symbol, account type and broker feed; use a demo account, never money at risk.

1. **Backup and compile:** save the EA, diary CSVs and terminal Global Variables. Compile in MetaEditor (`F7`); review every compiler error and warning. Confirm account mode (hedging/netting), symbol magic-number isolation, supported chart, and that no other EA or manual trade shares this EA's magic numbers. The design assumes one managed position/idea per lane; do not deploy if the broker/account aggregates lanes or returns multiple same-magic positions in a way the EA cannot distinguish.
2. **Read-only plans:** set `InpAutoTrading=false` and disable MT5 Algo Trading as a second safeguard. Supply the intended symbol's M5/M15/M30 history. Check BUY/SELL still appears during trading HOLD, shallow history shows an analog-count HOLD and indicative swing candidates where available, and missing structure never invents a fallback. Verify the displayed TP1 distance, snapshot spread, raw pre-cap distance, broker minimum/tick and exact reason for both BUY and SELL, including near-spread swings. A Steady label must not force an order. Read-only mode does **not** manage existing positions.
3. **Compare levels:** inspect long and short swings, entries, stops and three targets against closed bars, the current tick grid, Stops/Freeze levels and spreads. Separately account for actual broker commissions, swap and slippage, which the plan omits. Validate M5, M15 and M30 independently. Confirm no new-plan ATR-multiple distances and no cross-timeframe minimum target. Observe latency with full history on the actual terminal/VPS; synthetic C++ timings are not MT5 timings.
4. **Real-tick strategy tests:** run broker-provided real ticks with representative spread, commission, slippage and simulated request delays; test multiple symbols, regimes and historical periods. Compare hypothetical bar touches with actual pending fills, verify which of TP/SL happened first, and examine MAE/MFE, costs, rejections and net results. Keep a subsequent non-optimized forward period; report insufficient samples rather than inventing confidence. Backtests do not guarantee live performance.
5. **Demo entries and pending races:** with `InpAutoTrading=true` on demo, check each lane's own-bar placement, timer/pause transitions, lane/regime vetoes, expiry, spread/risk HOLD, and cancellation after a rejected deletion. Check actual broker orders after every change—cancellation can fail or race a fill. Exercise accepted, rejected and uncertain modification; verify old/new TP1/TP2 match the broker's actual SL/TP3 and never upgrade while cancellation remains pending.
6. **Exit and volume handling:** test BUY/Bid and SELL/Ask triggers, minimum and non-decimal lot steps, 70% and remaining-to-minimum stages, partial/rejected/uncertain closes, restart between request and response, gaps beyond TP3 and fills at/beyond TP1/TP2. Confirm no duplicate close and inspect `[HIT]`, `[SKIP]`, `[PART]`, `[REVIEW]`. Test partially filled entries with a remaining order: verify cancellation, actual volume, and deferred TP1/TP2. Inspect server SL/TP3 if the EA is offline or trading disabled.
7. **Restart/upgrade and manual interventions:** demo-test a pending filling while offline, an accepted/rejected modification during restart, a legacy open trade with and without its diary, broker-stripped comments, manually changed SL/TP, deleted persistence, and broker-side closure while offline. Missing levels must be shown as unavailable, not guessed for new trades; an unknown or changed position needs manual review. Confirm account history reconciliation after reconnect.
8. **Uncertain placement recovery:** if a lane stays on `order response uncertain or pending`, stop the EA and inspect broker orders, open positions and deal history—including delayed responses. Only after establishing that no related request can still fill, an experienced operator may back up and remove that lane's terminal Global Variable ending `_iv` (F3; key includes account, symbol and lane magic), then restart and recheck. A retained `_lv` identity may instead be waiting for complete closure history: do not delete it while any matching position/order could exist. Do not clear an in-flight close journal blindly; `[REVIEW]` requires broker/deal reconciliation or manual position management.
9. **Forward demo:** run without optimization over a separate live demo period, monitor rejected requests, connection outages, costs, statistics, actual risk and one-position-per-lane assumptions. If any safety gate, persistence, performance or broker behavior differs from the specification, block new entries using the lane switches or timer and fix/retest before considering live use. The master-off setting also stops EA management of open positions.
