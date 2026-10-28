# SimpleEA 2.0 — Complete Documentation & Process Specification

**Version:** `2.0` (`#property version "2.0"`, Panel Header `SimpleEA2.0`)

SimpleEA 2.0 (`SimpleAdvisor.mq5`) is a single-file, multi-timeframe Expert Advisor for MetaTrader 5 (MT5). It is engineered for **M5 (scalp)**, **M15 (short-term)**, and **M30 (intraday)** on any symbol (FX, Gold, Indices, Crypto). It operates on finished, closed bars only to guarantee strictly **non-repainting** analysis.

This document serves as the **single source of truth** for SimpleEA 2.0's architecture, indicator maths, trade scoring, order execution, position lifecycle management, on-chart panels, calibration-health diary, and parameter configurations.

---

## 1. System Overview & Core Workflow

SimpleEA runs simultaneously as:
1. **An Analytical On-Chart Dashboard (Main Panel & Trade Plan)**: Evaluates trend, timing, market structure, and statistical memory (Hurst regime) independently across M5, M15, and M30.
2. **An Automated Execution Engine (`InpAutoTrading`)**: Places orders, applies fixed TP1/TP2/TP3 exits, and keeps the entry SL unchanged on each timeframe independently via unique magic numbers (`InpMagicBase + TF_INDEX`).
3. **A Calibration-Health Diary**: Records one small row for every original order idea SimpleEA actually places, keeps Day and lifetime totals per symbol, and warns when a timeframe lane's recent follow-through, entry cost, score behaviour, or entry style deteriorates. It suggests a first fix; it never retunes the EA by itself (see §9).

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
  - **When a qualifying row is Choppy but `InpAllowChoppyTrade = false`**: the would-be `BUY`/`SELL` and its score remain visible but are greyed out, and the Trade Plan shows `HOLD — choppy — Choppy Trade is Off`. Grey means the reading exists but no new order may use it.

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

```
                [ Closed Bar Event on M5 / M15 / M30 ]
                                  │
                                  ▼
                ┌───────────────────────────────────┐
                │        Indicator Pipeline         │
                │  - Vote 1: Precision Trend (Dir)  │
                │  - Vote 2: Precision Trend ROC    │
                │  - Vote 3: 20-Bar Structure Move  │
                │  - Regime: Hurst Exponent (H)     │
                │  - Gate: Kaufman Efficiency Ratio │
                └───────────────────────────────────┘
                                  │
                                  ▼
                ┌───────────────────────────────────┐
                │          Score Assessment         │
                │    Score = Vote1 + Vote2 + Vote3   │
                │    Score in range [-3 .. +3]      │
                └───────────────────────────────────┘
                                  │
                 ┌────────────────┴────────────────┐
                 ▼                                 ▼
         Score >= +2 or <= -2            Score between -1 and +1
       ER >= 0.10; if Choppy,              (or ER Gate / Choppy
       Choppy permission is On              Trade permission Off)
                 │                                 │
                 ▼                                 ▼
       ┌──────────────────┐               ┌──────────────────┐
       │ Trade Permitted  │               │ Stand Aside HOLD │
       └──────────────────┘               │  (Show Reason)   │
                 │                        └──────────────────┘
        ┌────────┴────────┐
        ▼                 ▼
   Score = ±3         Score = ±2
 (All 3 agree)      (2 of 3 agree)
        │                 │
        ▼                 ▼
  [Market Order]    [Pending Limit]
        │                 │
        │           ┌─────┴──────────────────────┐
        │           ▼                            ▼
        │     Steady / Mixed                 Choppy (H < 0.45), allowed
        │    0.5 ATR Pullback              Box Band Fade if Range Mode On;
        │                                  otherwise / unusable box: pullback
        │           │                            │
        └───────────┼────────────────────────────┘
                    ▼
          [ Order Sent to Broker ]
   - Diary S is born here: one row for this original order idea
   - Lot sized from planned ATR/box stop
   - Planned broker SL and TP3 attached to every new order
   - TP3, TP2 and TP1 frozen at entry (no ATR drift mid-trade)
                    │
                    ▼
      [ Active Position Lifecycle — fixed exits only ]
   - SL remains exactly where entry put it; no trailing or profit locks
   - TP1 Hit: 70% partial close when a valid remainder can stay open
   - TP2 Hit: reduce the remainder to broker minLot when possible
   - TP3 Hit: full exit; broker SL is the only other automatic exit
   - Flip, HOLD, score weakening and box breaks never close an open trade
   - Diary row keeps updating peak progress and partial exits until W/L/BE
```

The panel's top band is two lines: the master status, then the modes behind it.

### Header Line 1 — Autotrading State, Resume Countdown & Day Diary Counts

`SimpleEA2.0 | Autotrading : <state>` `[Resume <countdown>]` `| Day: S <n> W <n> L <n>` `|  SYMBOL  |  TF`

The word after *Autotrading* states the **effective** state right now, not the value sitting in the `InpAutoTrading` input box. MQL5 inputs are read-only at run time, so an EA can never rewrite its own input when its timer closes the door — the panel is therefore the only honest place to report it. The input is left untouched.

| Effective state | Colour | Meaning | New orders | Waiting pendings | Open trades |
|---|---|---|---|---|---|
| **`Off`** | Red | `InpAutoTrading = false` (read-only advice mode) | none | cancelled | managed |
| **`Timer Pause`** | Orange | Switch is on, but the daily window is closed and/or a one-shot pause is running | **blocked** | **cancelled** | **still managed** |
| **`On`** | Green | Switch is on and nothing blocks placement | placed when the rules allow | kept | managed |

`Timer Pause` is deliberately not called `Timer Off`: `Off` already means *the feature is switched off*, and the two must never read as the same thing. When the timer re-opens, the word flips back to `On` by itself within one 2-second tick.

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

Below the three timeframe rows (separated by a hairline), SimpleEA 2.0 renders one Trade Plan block per timeframe (`M5`, `M15`, `M30`):

- **Inactive / Refused Row (1 line)**: Prints `M5   HOLD   <reason>` (`quiet — nothing worth trading`, `score +1/3 — under the +2/-2 gate`, or `choppy — Choppy Trade is Off`) or `waiting — history still loading`.
- **Active Plan or Live Order (3 lines)**, tagged `[OPEN]` (open market trade) or `[PLACED]` (waiting limit order) when active at the broker:
  - **Line 1**: `M5   market +3/3` / `pending +2/3` / `range fade` / `buy +3/3` | `Entry: <price>` | `Lot: <lots>` *(adds `(min)` in min-lot mode, or `(min, X.XX USD)` when broker minLot exceeds `1.05x` target risk)*
  - **Line 2**: `Stop: <price> <pts>pts` *(adds `(min)` if widened to broker `Stops Level`)* | `Target: <price> <pts>pts` | `Reach: ~<N> bar(s)` *(rough random-walk horizon $\operatorname{round}((\text{target}/\text{ATR})^2)$)*
  - **Line 3**: `Risk: <amount> <CCY>` | `Reward: <amount> <CCY>` | **Time cell**:
    - Advice or waiting pending: `Valid: <left>/<total> bars` (`3` bars for trend plans, `8` bars for box range fades; `0/<total>` is the rethink bar).
    - Live open position: `Hold: <N> bar(s) (est ~<M>)` comparing elapsed bars since fill against `Reach`.

### Second Panel — Autotrading Live Monitor (`SA2_`)

The **Autotrading** panel opens automatically (`Right` or `Bottom` of the Main Panel via `InpAutoPanelPos`) whenever at least one market position or pending limit order is active, and deletes all of its chart objects (`0` objects) the instant all lanes are flat.

- **Header**: `Autotrading | Exits : TP/SL | Stoploss : Fixed / Missing |  SYMBOL`
  - `Exits: TP/SL` states the complete open-position exit policy.
  - `Stoploss: Fixed` appears when every active order/position has a physical broker `SL > 0.0`; `Missing` warns that at least one does not. SimpleEA does not alter an existing position to clear that warning.
- **4-Line Active Order Card** (`M5  | OPEN BUY`, `OPEN SELL`, `BUY LIMIT`, `SELL LIMIT`):
  - **Line 0**: `Lot @ <curLot>` | `Entry: <entryPrice>` | `Bid:` / `Ask: <livePrice>`
  - **Line 1**: `TP1: <price> (<CCY>) [HIT]` | `TP2: <price> (<CCY>) [HIT]`
  - **Line 2**: `TP3: <price> (<CCY>)` | `SL: <price> (<CCY>)`; a missing legacy/external stop displays `-- (missing)` in red.
  - **Line 3**: `Status: P/L +/-X.XX <CCY>` *(or `Waiting: distance N pts` for pending limits)* | `Distance: to TP1/TP2/TP3 N pts` | `Exit: TP/SL`.


---

## 2. Signal Engine & 3-Vote Scoring Architecture

SimpleEA rejects classic lagging filters (e.g., standard moving averages, RSI, MACD). Instead, it isolates actionable cycle frequencies using modern bandpass, self-adapting wavelength analysis, and institutional market structure.

### Component 1 — Direction (Vote 1): Ehlers Precision Trend with Adaptive Cycle Periods
*Transcribed directly from John F. Ehlers (Technical Analysis of Stocks & Commodities, September 2024), enhanced with self-adaptive cycle wavelength detection.*

Unlike laggy low-pass moving averages, Precision Trend subtracts two 3-pole high-pass filters (`L1`, `L2`), creating a zero-lag bandpass filter tuned to the tradable frequency band:

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

- **Steady ($H > 0.55$)**: Persistent trending behavior. Trends extend.
- **Mixed ($0.45 \le H \le 0.55$)**: Random walk / balanced market.
- **Choppy ($H < 0.45$)**: Anti-persistent / mean-reverting. Moves pull back.

> **Why a span and not a bar count:** 256 bars was 21 hours on M5 but 128 hours on M30, so the noisiest row was judged on one sixth of the evidence. All three rows now see the same stretch of market. M30 lands on 256 bars — exactly where it always was.

#### Where the M5 label comes from (`InpM5RegimeFrom`)
M5's own label is still measured and still shown, but it is computed from 5-minute returns, and every quote bouncing between bid and ask makes short-horizon returns look mean-reverting. That drags the estimate down. M5 may therefore read its label from a slower row:

| Setting | Meaning |
|---|---|
| `Own` (0) | M5 keeps its own label — the original behaviour |
| `M15` (1) | **Shipped default.** M5 borrows M15's label (15-minute sampling) |
| `M30` (2) | M5 borrows M30's label (30-minute sampling) |

This **borrows** a label; it does not require the two rows to **agree**. Requiring agreement would be actively harmful: an M5 row that reads Choppy most of the time would only be permitted to trade when the higher row was Choppy too — blocking every trend and allowing only chop. `research/verify_regime_fixes.py` demonstrates this explicitly.

When M5 borrows, the panel names the source (`Choppy<-M15`) so a borrowed label can never be mistaken for M5's own reading. M5's direction, score, trend line, entry, stop and target remain entirely its own — only the regime label moves.

> **CRITICAL RULE:** Hurst never creates a direction or permission by itself. The score publishes the would-be direction and order type; **`InpAllowChoppyTrade` is the operator's separate new-entry permission for a row currently classified Choppy, and `InpAllowMixedTrade` the same for a row classified Mixed.** When a permission is on, the regime chooses the entry style. When it is off, that row places nothing at either 2/3 or 3/3. Neither permission ever closes or abandons a trade that is already open.

---

## 3. Order Placement & Scoring Rules

$$\mathbf{Total\ Score} = \text{Vote 1} + \text{Vote 2} + \text{Vote 3} \quad \in [-3, +3]$$

The table below is the score's would-be action after the ER dead-market gate and the per-row Choppy permission have passed:

| Score / row state | Qualification | Action Taken |
|---|---|---|
| **+3 / 3** or **-3 / 3** | All 3 votes agree | **Market Order** at live Ask/Bid (sent at that row's bar close — see *Placement Timing* below) in Steady/Mixed, and in Choppy only when `InpAllowChoppyTrade = true` (subject to the existing low-volume safeguard in §2). |
| **+2 / 3** or **-2 / 3** | 2 of 3 votes agree | **Pending Limit Order** waiting for a favorable price (see the entry-style rules below). |
| Qualifying score, row is **Choppy**, `InpAllowChoppyTrade = false` | Score direction exists but the operator has vetoed new Choppy entries | **No order** — no 2/3 limit and no 3/3 market order. The Trade Plan shows `HOLD — choppy — Choppy Trade is Off`. |
| Qualifying score, row is **Mixed**, `InpAllowMixedTrade = false` | Score direction exists but the operator has vetoed new Mixed entries | **No order**. The Trade Plan shows `HOLD — mixed — Mixed Trade is Off`. Mixed is the largest of the three buckets (roughly 56% of bars), so this removes well over half of all entries. |
| Qualifying score, `InpAutoTradeM5` / `M15` / `M30 = false` for that row | The operator has switched that timeframe out of the game | **No order of any kind**, whatever the score or regime. The Trade Plan shows `HOLD — autotrading off — M5 is switched off`. A waiting pending on that row is cancelled; **an already-open trade keeps its fixed SL and TP1/TP2/TP3 exits**. |
| **-1, 0, +1** | Score below threshold | **HOLD (Stand aside)**. The panel states the exact refusal reason. |

### Placement Timing — New Orders Only on That Timeframe's Own Bar Close

Every **new** order (market, limit, reversal entry, and the market replacement of a deleted pending) is placed **only on the close of that row's own timeframe bar** — an M30 entry, for example, can only be sent on an M30 close. This is enforced, not just intended: `CheckNewBars()` marks each row whose own timeframe printed a new closed bar (`g_freshBar[]`), and `PlacePlanOrder()` — the single funnel through which every new order leaves the terminal — refuses any row without that mark. The mark is spent (cleared) by the bar-close pass itself, so nothing later in the same tick can re-use it.

Consequences:

- **Attaching, restarting, or recompiling the EA** never places an order mid-bar; the first entry waits for that row's next closed bar.
- **Returning to a supported chart** (M5/M15/M30) after an unsupported timeframe, or the **market reopening**, rebuilds the panel but places nothing until the row's next close.
- **A timer/schedule resume** (§8) is not a placement trigger: after it turns ON, each row's first entry still waits for its own next bar close (up to ~5/15/30 minutes per row). The signal used is the one recomputed at that close, never a stale mid-bar reading.
- **Another timeframe's bar closing** (say an M5 close while an M30 row is mid-bar) cannot place or re-place that row's order — not even a retry after a broker rejection, or a re-entry after a tick-level TP close freed the slot.
- This governs **placement only**. Mid-bar ticks continue to apply TP1/TP2/TP3 exits (§5); pending cancellations and pending Entry/SL/TP modifications are never delayed by this rule. An open position’s SL is never modified. A waiting limit order can also still **fill** mid-bar at the broker — that is a fill of an order placed at a bar boundary, not a new placement.

### Where Pending Limit Orders Wait & Refresh
- **Choppy permission first (`InpAllowChoppyTrade = false`)**: if the row currently reads Choppy, there is **no pending order at all**, regardless of `InpRangeMode`.
- **Steady / Mixed Regimes**: The limit order is placed at a **$0.5 \times \text{ATR}$ pullback** (`PEND_ATR = 0.5`) beyond live Ask/Bid, widened automatically if needed so $\text{offset} \ge \max(0.5 \times \text{ATR},\, 2 \times \text{spread},\, \text{stopsLevel} \times \text{point})$.
- **Choppy Regime, allowed, `InpRangeMode = true`**: The order is priced at the **20-bar box band** (`range fade`), aiming for the box midpoint (target = 50% of the box, stop = band $+ 1.0 \times \text{ATR}$).
  - *Box Validation Gates*: Spread clearance ($\text{half-box} \ge 3 \times \text{spread}$), box height ($\ge 2.0 \times \text{ATR}$), efficiency ($\text{ER} < 0.40$), and current Bid inside the box (`bot <= bid <= top`).
  - *Fallback*: If any box gate fails, the limit automatically falls back to the standard $0.5 \times \text{ATR}$ pullback limit. The box gates never cancel a Choppy trade that permission allowed.
- **Choppy Regime, allowed, `InpRangeMode = false`**: The standard $0.5 \times \text{ATR}$ pullback limit is used. Turning Range Mode off changes only the entry style; it is not another way to forbid Choppy trading.
- **Closed-Bar Pending Refresh & `2/3 -> 3/3` Market Upgrade**:
  - On each new closed bar in the same direction while the reading remains `2/3`, SimpleEA updates the waiting limit's `Entry`, planned fixed `SL`, and `TP1/TP2/TP3` to the freshest plan before fill.
  - If the row upgrades from `2/3` to `3/3` (with volume confirmed) in the same direction, SimpleEA deletes the waiting limit order and opens a **Market Order** at that same bar-close pass, merging both into the **same single `S` diary record** and original placement date.

---

## 4. Execution, Sizing & Risk Management

### Position Sizing Modes
1. **Allow Risk (`InpUseRisk = true`, Default)**:
   - Score $\pm 2$: Risks `InpRiskPct`% of balance (default **0.5%**).
   - Score $\pm 3$: Risks **double** the percentage (default **1.0%**), rewarding unanimous agreement.
   - Lot is mathematically derived from the reference ATR stop distance.
2. **Fixed Ladder (`InpUseRisk = false`)**:
   - $0.01$ lots per 1,000 balance ($\times 1.5$ at score 3).
3. **Minimum Lot (`InpUseMinLot = true`)**:
   - Always forces broker minimum lot (e.g., 0.01).

### Fixed Stop Loss Architecture

- Every new market and pending order is submitted with its planned ATR/box **SL** and **TP3** already attached. There is no optional-SL switch.
- The planned stop still defines position size and the diary's `1R` denominator.
- Pending orders may be repriced before fill, so their Entry/SL/TP move together with the refreshed entry plan.
- **After a fill, SimpleEA never modifies the position's SL or broker TP.** It does not trail, move to breakeven, lock profit at TP1/TP2, or tighten on later same-direction candles.
- A legacy or externally altered position found without an SL is shown as `Missing`; the EA does not invent a post-entry stop for it.

### Take Profit Target Stability (TP Walk Prevention)
- **TP3** = 100% of target points (M5: $0.9 \times \text{ATR}$, M15: $1.8 \times \text{ATR}$, M30: $3.0 \times \text{ATR}$).
- **TP2** = 75% of TP3.
- **TP1** = 56.25% of TP3 (25% less than TP2).
- **Frozen at Entry**: Once an order fills, **TP1, TP2, and TP3 are locked in**. They do not walk or float when ATR changes on subsequent bars. The trade preserves its exact initial risk/reward ratio.

---

## 5. Active Position Lifecycle & Fixed-Exit Contract

An open position has exactly four automatic exit routes: **TP1 partial**, **TP2 partial**, **TP3 final**, and the **original broker SL**. There are no signal-based or trailing exits.

```text
Entry + fixed broker SL/TP3
   ├── TP1: close 70% when a valid remainder can remain; SL unchanged
   ├── TP2: reduce remainder to broker minLot when possible; SL unchanged
   ├── TP3: close all remaining volume
   └── SL: broker closes at the unchanged entry stop
```

### 5.1 Target and trigger rules

- **TP3** = 100% of target points; **TP2** = 75% of TP3; **TP1** = 75% of TP2 (56.25% of TP3), rounded with the existing `ComputeTPLevels()` rules.
- All three distances and the initial SL are frozen from the entry plan. Later ATR, direction, score or regime readings do not move them.
- **TP1 (`ManageAutoTick`)** triggers on net favorable points (`favPts >= TP1`) or the established gross-travel/spread fallback (`grossPts >= TP1 && favPts > 0`). It marks TP1 once and closes 70% rounded down to the broker lot step, adjusting the request if necessary to leave at least `minLot`. At minimum lot, no invalid partial is sent.
- **TP2** requires TP1 to have been marked and `favPts >= TP2`. It closes only the volume needed to leave broker `minLot`; if the position is already at `minLot`, no partial is sent.
- **TP3** closes the full remainder. A tick that jumps directly to TP3 takes the full-close path rather than manufacturing earlier partial closes.
- TP1/TP2 milestone flags persist so repeated ticks cannot repeat a partial. TP1/TP2 are EA-managed and therefore need SimpleEA running with trading permitted. The initial SL and TP3 are also attached at the broker; MT5 may execute those broker-side exits while the EA is away.

### 5.2 What never closes or modifies an open position

- No pre-TP1 stepped trail, post-TP1 swing trail, universal profit floor, breakeven move, TP1/TP2 SL lock, or same-direction SL tightening exists.
- An opposite direction signal, `HOLD`, weakening score, a Choppy/Mixed permission change, or a range-box break **never closes an open position**.
- `ManageAutoBar()` only updates diary observations for an open position. It sends no close or SL/TP modification request. The source has no open-position `TRADE_ACTION_SLTP` wrapper.
- Disabling a timeframe or the timer blocks new entries and cancels waiting pendings; it does not create an open-position exit.

### 5.3 Pending orders are entry management, not open-position exits

The existing pending lifecycle is intentionally preserved:

- Same-direction `2/3` closed bars may refresh pending Entry/SL/TP before fill.
- A same-direction `3/3` upgrade may delete the limit and place a market order.
- Direction/HOLD/trend-gate failure, expiry, regime/per-row permission veto, timer pause, or range-box break may cancel a waiting pending.
- Those cancellation rules stop applying once the order fills. From that moment only §5.1's TP/SL contract applies.

### 5.4 Restart, manual action and diary recovery

- Slot persistence retains range-entry data, placement timestamps, `tp1Hit`, `tp2Hit`, and the diary link. No trailing-progress state is read or written.
- TP1/TP2 state is recovered from persisted flags/diary evidence, **never inferred from the current SL price**. A fixed SL cannot be mistaken for a milestone lock.
- If a trader manually closes a position, the next qualified closed-bar signal may enter again under the existing one-trade-per-timeframe and one-entry-per-bar rules. Use the timer or `InpAutoTrading = false` to stop new entries.
- A broker-side SL/TP close that occurs while the EA is away is reconciled through the existing diary/deal-history recovery (§9.2).

---

## 6. Parameters Reference Table

| Group | Parameter | Shipped Default | Meaning & Function |
|---|---|---|---|
| **Autotrading** | `InpAutoTrading` | `true` | Full automation on (`true`) or read-only analytical mode (`false`). |
| | `InpUseAutoSchedule` | `false` | Enable daily placement schedule window (PC local time). |
| | `InpAutoStartTime` | `"08:00"` | Daily trading start time (`HH:MM`, PC local time). |
| | `InpAutoEndTime` | `"17:00"` | Daily trading stop time (`HH:MM`, PC local). At the stop minute, waiting pendings are cancelled and no new orders are placed; open trades keep being managed (see §8). |
| | `InpAutoOffHours` | `0` | One-shot pause in hours from when applied (`48` = 2-day pause; `0` = off/re-arm). Persisted across restarts; same rules as the daily window (see §8). |
| | `InpRequireM15M30SameTrend` | `false` | Timeframe alignment: `false` = untied; `true` = both M15 and M30 must have matching trade directions (`BUY` or `SELL`) to place. |
| | `InpMagicBase` | `202610` | Base magic number (`+0` M5, `+1` M15, `+2` M30). |
| | `InpAutoTradeM5` | `true` | **Master switch for M5.** `false` = no new M5 order of any kind; a waiting M5 pending is cancelled; an open M5 trade keeps full management. M15 and M30 are unaffected. The row keeps reading and still draws its plan. |
| | `InpAutoTradeM15` | `true` | As above, for M15. |
| | `InpAutoTradeM30` | `true` | As above, for M30. |
| **Signal, Regime & Range** | `InpBuyScore` | `2` | Score $\ge$ this triggers BUY. |
| | `InpSellScore` | `-2` | Score $\le$ this triggers SELL. |
| | `InpAllowChoppyTrade` | `true` | **New-entry permission** for a row currently reading Choppy. `false` = no new 2/3 limit or 3/3 market order on that row; a waiting pending is cancelled when the row turns Choppy; already-open trades keep normal management. Header Line 2's `Choppy Trade` mirrors this input. |
| | `InpAllowMixedTrade` | `true` | **New-entry permission** for a row currently reading Mixed — the same shape as the Choppy permission. `false` = no new order on a Mixed row; a waiting pending is cancelled when the row turns Mixed; already-open trades keep normal management. Mixed is the largest bucket, so switching this off removes well over half of all entries. |
| | `InpM5RegimeFrom` | `M15` | Where the **M5 row's regime label** comes from: `Own` / `M15` / `M30`. This borrows the label — it never requires the two rows to agree. M5's direction, score, trend line, entry, stop and target stay its own. When borrowing, the panel names the source (`Choppy<-M15`). |
| | `InpM5RequireHigher` | `false` | `true` = M5 may only place when M15's trade direction matches. **Ships off:** a direction veto costs 15–30 minutes and an M5 reading only lives 10–15, so this stops most of the trades it would allow. Provided as a switch, not a hard-coded exclusion. |
| | `InpRangeMode` | `true` | **Entry style only**, after Choppy permission is on: use the 20-bar box band for an allowed Choppy 2/3 when the box is usable; `false` (or an unusable box) = standard half-ATR pullback. |
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

These constants represent SimpleEA 2.0's measured standard calibration (intentionally kept in code rather than exposed as fragile user knobs):

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
| **Stops, Targets & Sizing** | `ATR_PERIOD` | `14` | Closed-bar ATR period per timeframe |
| | `SL_ATR_M5` / `TP_ATR_M5` | `1.0` / `0.9` | M5 Scalp stop & TP3 multiples ($\text{R:R } 1:0.9$) |
| | `SL_ATR_M15` / `TP_ATR_M15` | `1.2` / `1.8` | M15 Short-term stop & TP3 multiples ($\text{R:R } 1:1.5$) |
| | `SL_ATR_M30` / `TP_ATR_M30` | `1.5` / `3.0` | M30 Intraday stop & TP3 multiples ($\text{R:R } 1:2.0$) |
| | `PEND_ATR` / `VALID_BARS` | `0.5` / `3` | Pullback limit offset ($\times \text{ATR}$) and trend signal leash (bars) |
| | `RISK_SCORE3_X` / `BAL_PER_001` / `SCORE3_FACTOR` | `2.0` / `1000.0` / `1.5` | Score-3 risk multiplier and fixed-ladder fallback constants |
| **Range Box** | `RANGE_BARS` / `RANGE_SL_ATR` / `RANGE_MIN_ATR` | `20` / `1.0` / `2.0` | 20-bar box lookback, stop cushion, and minimum box height ($\times \text{ATR}$) |
| | `RANGE_SPREAD_X` / `RANGE_ER_MAX` / `RANGE_VALID_BARS` | `3.0` / `0.40` / `8` | Minimum half-box spread multiple, max box ER, and 8-bar fade leash |
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
| Place / refresh a waiting pending limit order | **Blocked**, and any existing waiting pending is **cancelled** so it cannot fill while you believe autotrading is off (retried every 2 s if the broker refuses); its diary row becomes `Exp` |
| TP1/TP2/TP3 exits | **Fully active** — the fixed broker SL remains unchanged; no trailing or signal-based exit runs |
| Panel analysis and Trade Plan | **Fully active** — advice is still computed and shown, it is simply not acted on |

The split is deliberate. Pending orders are *unfilled entries resting at the broker*, so they must not survive an OFF transition. Open trades keep their broker-side fixed SL and EA-managed TP exits; the timer never moves their stop.

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
- Loading the EA during an OFF period cancels this EA's waiting pendings within a couple of seconds — by design.
- A **resume is not a placement trigger**: after the timer turns back ON, the first new order still waits for that row's own next bar close (§3, *Placement Timing*). The same applies right after the EA is attached or restarted.
- The timer never closes positions. It is a schedule and a snooze button for *entering* trades, not a "close everything at 17:00" switch.

---

## 9. Calibration-Health Diary, Day Counts & History Panel

SimpleEA's calibration is deliberately fixed. The diary gives that fixed calibration a **memory, not a second brain**: it can warn that a symbol/timeframe lane looks less healthy than it used to and suggest what to test first, but it **never changes** a target, stop, score gate, risk setting, or on/off switch by itself.

### 9.1 Counting rules

The diary's letters have exact meanings:

| Count | Meaning |
|---|---|
| **`S`** | Signals SimpleEA acted on: the broker accepted one new market or pending order idea. Advice that was never placed is not an `S`. Repricing a waiting pending is still the same `S`; upgrading that pending from 2/3 to a 3/3 market order is also still the same `S` (and keeps the original placement day). |
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

There is **one row per original placed order idea**, not one row per tick and not one row per partial exit. Each row stores:

- symbol identity through the diary file itself, plus timeframe, direction, and the score frozen at placement (a pending upgraded to market becomes a 3/3 row);
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

These are deliberately *first steps to test or consider*, not instructions the EA executes. In particular, a nearer TP1, a score-rule change, or any recalibration should be tested outside the live lane first. The diary's job is to make decay visible early enough for a human decision; the fixed calibration remains fixed until the operator changes it.

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

The former trailing/profit-floor/score/flip/box open-position management was removed as one contract change. New orders now always carry the planned SL and TP3; after fill only TP1/TP2 partials, TP3 full close and the unchanged broker SL remain. Pending-order entry management and the signal core were not redesigned. The obsolete exit inputs were removed, and the diary parser still accepts older records.

### New operator controls

| Input | Default | Purpose |
|---|---|---|
| `InpAutoTradeM5` / `M15` / `M30` | `true` / `true` / `true` | Master per-timeframe switch. Off = no new orders and pending cancelled on that row; open trades keep full management. |
| `InpAllowMixedTrade` | `true` | New-entry permission for Mixed rows, mirroring `InpAllowChoppyTrade`. |
| `InpM5RegimeFrom` | `M15` | Where M5's regime label comes from (Own / M15 / M30). |
| `InpM5RequireHigher` | `false` | Optional M5↔M15 direction tie. |

All four ship at values that preserve the previous behaviour, so nothing changes until the operator changes it.

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

`research/verify_regime_fixes.py` (41 checks) covers all of the above. The pre-existing suites — `verify_autotrading.py`, `verify_plan_math.py`, `verify_timeframe_gate.py` and the `tests/` unit tests — all still pass. Note that every verifier in `research/` *transcribes* the EA's logic into Python rather than parsing `SimpleAdvisor.mq5`, so a green run proves no regression in modelled behaviour; it does not prove the MQL5 compiles.
