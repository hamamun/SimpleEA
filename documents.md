# SimpleEA — Complete Documentation & Process Specification

SimpleEA is a professional multi-timeframe Expert Advisor for MetaTrader 5 (MT5). It is engineered for **M5 (scalp)**, **M15 (short-term)**, and **M30 (intraday)** on any symbol (FX, Gold, Indices, Crypto). It operates on finished, closed bars only to guarantee strictly **non-repainting** analysis.

This document serves as the **single source of truth** for SimpleEA's architecture, indicator maths, trade scoring, order execution, position lifecycle management, calibration-health diary, and parameter configurations.

---

## 1. System Overview & Core Workflow

SimpleEA runs simultaneously as:
1. **An Analytical On-Chart Dashboard (Main Panel & Trade Plan)**: Evaluates trend, timing, market structure, and statistical memory (Hurst regime) independently across M5, M15, and M30.
2. **An Automated Execution Engine (`InpAutoTrading`)**: Places, manages, trails, scales out (partials), and protects orders on each timeframe independently via unique magic numbers (`InpMagicBase + TF_INDEX`).
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
┌──────────────────────────────────────────────────────────────────────────┐
│  SimpleEA  | Autotrading : On   | Day: S 14 W 6 L 4   XAUUSD  |  M5      │
│  Timer: Off | Choppy Trade: On | M15/M30 Same Trend: Off                 │
├──────────────────────────────────────────────────────────────────────────┤
│  M5   Scalp       Trend: Going up     Regime: Steady                     │
│  Health: OK       Signal: BUY         Score: +3 / 3                      │
│  M15  Short-term  Trend: Sideways     Regime: Mixed                      │
│  TP1: Watch       Signal: HOLD        Score: +1 / 3                      │
│  M30  Intraday    Trend: Going down   Regime: Choppy                     │
│  Health: Learning Signal: SELL        Score: -2 / 3                      │
└──────────────────────────────────────────────────────────────────────────┘
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
   - Lot sized from planned ATR stop
   - Deliberate SL: SL=0.0 (breathing room) or Hard SL if InpUseStopLoss=true
   - Target TP3, TP2, TP1 locked at entry (no ATR drift mid-trade)
                    │
                    ▼
      [ Active Position Lifecycle ]
   - Pre-TP1 Stepped Trailstop (arms at +40%/+55% to TP1)
   - TP1 Hit: 70% partial close, SL -> Break-Even, Score Watcher armed
   - TP2 Hit: Close down to broker minLot, SL locked to TP1
   - TP3 Hit: Full exit
   - Diary row keeps updating peak-to-TP1, observed trail activation/lock, and partial exits until final W/L/BE
   - Reversal / Box-kill: protection exit — closes immediately only while in profit (default); `InpImmediateFlipClose = true` restores the immediate exit whatever the P&L
```

The panel's top band is two lines: the master status, then the modes behind it.

### Header Line 1 — Autotrading State, Resume Countdown & Day Diary Counts

`SimpleEA | Autotrading : <state>` `[Resume <countdown>]` `| Day: S <n> W <n> L <n>` `| SYMBOL | TF`

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
┌──────────────────────────────────────────────────────────────────────────┐
│  SimpleEA  | Autotrading : Timer Pause  Resume 2h14m  | Day: S 3 W 1 L 0  XAUUSD  |  M5  │
│  Timer: Paused 08:00-17:00 | Choppy Trade: On | M15/M30 Same Trend: Off  │
└──────────────────────────────────────────────────────────────────────────┘
```

…followed by the usual timeframe rows and Trade Plan. The header shrinks back to its normal width the moment the timer re-opens.


---

## 2. Signal Engine & 3-Vote Scoring Architecture

SimpleEA rejects classic lagging filters (e.g., standard moving averages, RSI, MACD). Instead, it isolates actionable cycle frequencies using modern bandpass, self-adapting wavelength analysis, and institutional market structure.

### Component 1 — Direction (Vote 1): Ehlers Precision Trend with Adaptive Cycle Periods
*Transcribed directly from John F. Ehlers (Technical Analysis of Stocks & Commodities, September 2024), enhanced with self-adaptive cycle wavelength detection.*

Unlike laggy low-pass moving averages, Precision Trend subtracts two 3-pole high-pass filters (`L1`, `L2`), creating a zero-lag bandpass filter tuned to the tradable frequency band:

$$\text{Trend} = \text{HighPass3}(\text{Price}, L_1) - \text{HighPass3}(\text{Price}, L_2)$$

- **Self-Adaptive Cycle Detection**: The engine automatically measures the live dominant cycle period ($T$) across the last 120 closed bars via zero-crossing wavelength analysis, clamped to $[14, 36]$ bars (baseline $24$). It automatically tunes:
  $$L_2 = T, \quad L_1 = \operatorname{round}(T \times 6.25) \in [90, 225]$$
  This allows the filter to turn faster during fast London/NY momentum breakouts and smooth out false turns during quiet consolidation.

High-pass filter formula for period $P$:
$$f = \frac{1.414 \times \pi}{P}, \quad a_1 = e^{-f}, \quad c_2 = 2 a_1 \cos(f), \quad c_3 = -a_1^2, \quad c_1 = \frac{1 + c_2 - c_3}{4}$$
$$\text{HP}[i] = c_1 (P_i - 2P_{i-1} + P_{i-2}) + c_2 \text{HP}[i-1] + c_3 \text{HP}[i-2]$$

$$\mathbf{Vote\ 1} = \operatorname{sign}(\text{Trend}) \in \{+1, -1, 0\}$$

### Component 2 — Timing (Vote 2): Rate of Change (ROC) with Noise Dead-Band
The rate of change of the Precision Trend line is zero at its exact turning peaks and troughs. Its sign indicates the acceleration/onset of a momentum push:
$$\text{ROC}[i] = \frac{L_2}{2\pi} (\text{Trend}[i] - \text{Trend}[i-1])$$

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
- Compares the finished bar's tick volume against its 20-bar moving average.
- If market volume has dried up ($< 50\%$ of average), an aggressive `3/3` Market Order is automatically stepped down to a **Pending Limit Order**, protecting against illiquid rollover spread spikes.
- Gracefully permits trading if the broker feed does not provide tick volume.

### Regime Classification: Rolling Hurst Exponent (H)
Calculated via variance-scaling over a 256-bar window:
- **Steady ($H > 0.55$)**: Persistent trending behavior. Trends extend.
- **Mixed ($0.45 \le H \le 0.55$)**: Random walk / balanced market.
- **Choppy ($H < 0.45$)**: Anti-persistent / mean-reverting. Moves pull back.

> **CRITICAL RULE:** Hurst never creates a direction or permission by itself. The score publishes the would-be direction and order type; **`InpAllowChoppyTrade` is the operator's separate new-entry permission for a row currently classified Choppy**. When that permission is on, Hurst/Range Mode choose the entry style. When it is off, the Choppy row places nothing at either 2/3 or 3/3.

---

## 3. Order Placement & Scoring Rules

$$\mathbf{Total\ Score} = \text{Vote 1} + \text{Vote 2} + \text{Vote 3} \quad \in [-3, +3]$$

The table below is the score's would-be action after the ER dead-market gate and the per-row Choppy permission have passed:

| Score / row state | Qualification | Action Taken |
|---|---|---|
| **+3 / 3** or **-3 / 3** | All 3 votes agree | **Market Order** immediately at live Ask/Bid in Steady/Mixed, and in Choppy only when `InpAllowChoppyTrade = true` (subject to the existing low-volume safeguard in §2). |
| **+2 / 3** or **-2 / 3** | 2 of 3 votes agree | **Pending Limit Order** waiting for a favorable price (see the entry-style rules below). |
| Qualifying score, row is **Choppy**, `InpAllowChoppyTrade = false` | Score direction exists but the operator has vetoed new Choppy entries | **No order** — no 2/3 limit and no 3/3 market order. The Trade Plan shows `HOLD — choppy — Choppy Trade is Off`. |
| **-1, 0, +1** | Score below threshold | **HOLD (Stand aside)**. The panel states the exact refusal reason. |

### Where Pending Limit Orders Wait
- **Choppy permission first (`InpAllowChoppyTrade = false`)**: if the row currently reads Choppy, there is **no pending order at all**, regardless of `InpRangeMode`.
- **Steady / Mixed Regimes**: The limit order is placed at a **$0.5 \times \text{ATR}$ pullback** beyond market price (clamped to respect broker stops level and spread).
- **Choppy Regime, allowed, `InpRangeMode = true`**: The order is priced at the **20-bar box band** (`range fade`), aiming for the box midpoint (target = 50% of the box, stop = band $+ 1.0 \times \text{ATR}$).
  - *Box Validation Gates*: Spread clearance ($\text{half-box} \ge 3 \times \text{spread}$), box height ($\ge 2.0 \times \text{ATR}$), efficiency ($\text{ER} < 0.40$), and current price inside the box.
  - *Fallback*: If any box gate fails, the limit automatically falls back to the standard $0.5 \times \text{ATR}$ pullback limit. The box gates never cancel a Choppy trade that permission allowed.
- **Choppy Regime, allowed, `InpRangeMode = false`**: The standard $0.5 \times \text{ATR}$ pullback limit is used. Turning Range Mode off changes only the entry style; it is not another way to forbid Choppy trading.

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

### Deliberate Stop Loss Architecture (`InpUseStopLoss = false` vs `true`)
SimpleEA features an intentional, two-phase stop loss design:
- **Default `InpUseStopLoss = false` (Deliberate Breathing Room)**:
  - Orders are submitted to the broker with **`SL = 0.0`**.
  - *Why:* Prevents immediate entry spread spikes, broker slippage, or 1-bar random noise from knocking trades out prematurely upon fill.
  - *Risk Containment:* Position size is still strictly calculated using the planned ATR stop distance. The **stepped trailstop** attaches the first physical SL dynamically at the broker once the position makes favorable progress (+40% or +55% towards TP1).
- **Option `InpUseStopLoss = true` (Immediate Hard SL)**:
  - For prop firms or accounts strictly requiring an initial broker stop loss, setting this to `true` attaches the full ATR Stop Loss directly on the initial order at fill.

### Take Profit Target Stability (TP Walk Prevention)
- **TP3** = 100% of target points (M5: $0.9 \times \text{ATR}$, M15: $1.8 \times \text{ATR}$, M30: $3.0 \times \text{ATR}$).
- **TP2** = 75% of TP3.
- **TP1** = 56.25% of TP3 (25% less than TP2).
- **Frozen at Entry**: Once an order fills, **TP1, TP2, and TP3 are locked in**. They do not walk or float when ATR changes on subsequent bars. The trade preserves its exact initial risk/reward ratio.

---

## 5. Active Position Lifecycle & Trade Management

Each active position is managed candle-by-candle and tick-by-tick through a structured four-stage process:

```
  Entry ──► Universal Break-Even (50% TP1) / Pre-TP1 Trailstop ──► TP1 Hit (70% Exit & BE) ──► TP2 Hit (MinLot) ──► TP3 Hit (Full Exit)
```

### 1. Universal Zero-Risk Break-Even & Pre-TP1 Trailstop
- **Universal Break-Even Protection Gate (`BE_TRIGGER_RATIO = 0.50`)**:
  - Operates automatically **whether Trailstop is ON or OFF**.
  - The instant favorable trade progress reaches $50\%$ of the distance to TP1, the Stop Loss is locked to **Break-Even** ($\text{Entry Price} + \text{dir} \times 1\text{ point}$).
  - Guarantees that any trade covering half the distance to TP1 can **never reverse into an open-ended loss**, solving the vulnerability of running with Trailstop OFF.
- **Pre-TP1 Stepped Trailstop** (when `InpUseTrailStop = true`):
  - Operates between Entry and TP1.
  - Activation threshold $P$:
    - **40% (Tight)** in Choppy or Mixed regimes.
    - **55% (Steady)** in Steady regimes with matching trend.
    - Gap widened by $\times 1.25$ on M15 and $\times 1.50$ on M30 for breathing room.
  - Ratchets forward in +5% increments as price progresses, locking in gains.
  - With `InpUseStopLoss = false`, this trailstop places the **first physical SL** at the broker upon activation.

### 2. At TP1 Hit & Stage-2 Runner Trailing
- **Multi-Condition TP1 Triggering**:
  - Triggers on net favorable tick points (`favPts >= TP1`) OR gross market travel clearing spread (`grossPts >= TP1 && favPts > 0`), ensuring broker bid-ask spread friction does not deny valid target touches.
  - **Closed-Bar Wick Extreme Verification**: On bar close, if the finished candle's high/low wick spiked through the TP1 price level, TP1 is formally confirmed and locked.
- Closes **70%** of the position volume (if remaining lot $>$ broker minLot).
- Moves SL to **Break-Even** (or keeps the tighter trailed SL).
- **Stage-2 Runner Trailing (Post-TP1 to TP3)**:
  - While holding the remaining 30% runner volume towards TP2 and TP3, SimpleEA continues trailing the stop behind recent 2-bar market swing extrema ($\text{Low}[2] - 0.1\times\text{ATR}$ for BUY, $\text{High}[2] + 0.1\times\text{ATR}$ for SELL).
  - Automatically locks in higher swing lows / lower swing highs, preventing runner gains from evaporating back to Break-Even.
- **Score & Direction Watcher**:
  - For trend trades, holds remaining volume for TP2/TP3 only as long as the timeframe's score stays strong in the trade direction. If the score weakens below entry/peak score or changes direction, the trade exits immediately.
  - *Range fades are exempt from the score watcher*: their exits are strictly governed by the box midpoint, stop, and box-kill.

### 3. At TP2 Hit
- Closes partial volume to reduce remaining lot to **broker minimum lot**.
- Locks Stop Loss to **TP1 price level**.

### 4. At TP3 Hit
- Closes remaining position volume in full.

### 5. Invalidation & Protective Exits
- **Opposite Signal Reversal**: If a qualified signal fires in the opposite direction, the position closes **only while it is in profit** by default; if the trade is under water it is held and the flip is re-checked on every later closed bar, so a reversal never banks a loss (and no reverse order is placed while the old trade is kept). Set `InpImmediateFlipClose = true` to restore the old immediate-close behaviour at any P&L.
- **HOLD-in-Profit**: If a timeframe drops to HOLD before TP1 while the trade is in net profit, it closes immediately to bank gains.
- **Box-Kill (Range Fades)**: If a bar closes outside the 20-bar box, the trade is invalidated and closed **only while it is in profit** by default; under water the position is held (with normal SL/TP management continuing) and re-tested each closed bar until it returns to profit. `InpImmediateFlipClose = true` closes immediately regardless of P&L. Waiting pending limits carry no P&L, so they are still deleted on a box-break.
- **Choppy Permission Veto**: With `InpAllowChoppyTrade = false`, if a lane with a still-waiting pending turns Choppy, that pending is cancelled on the next closed-bar management pass instead of being refreshed or upgraded. This is a new-entry veto only: a position already open is **not** closed merely because its row turned Choppy; its normal SL/TP/trailing and genuine score/reversal/box rules continue.
- **Pending Order Leash Expiry**: Waiting limit orders expire and cancel after 3 closed bars (trend) or 8 closed bars (range fade) from signal birth (`sigBirth`), matching the on-screen `Valid: left/total bars` countdown.
- **Manual Closes**: SimpleEA executes automatically on closed bars. If a trader manually closes a trade in MT5, the EA does not treat this as a permanent block. If the signal remains qualified on the next bar close, the EA will enter again. (To stop trading, use `InpAutoOffHours` or set `InpAutoTrading = false`).
- **Restart Resilience**: Active range states (`isRange`, `rngTop`, `rngBot`, `entryScore`, `placedBar`) are persisted in terminal GlobalVariables so that terminal restarts or recompiles never strip a range trade of its box-kill rules. The calibration diary link for a live order idea is likewise recoverable from its diary row/deal history; a tracked broker-side close that happened while the EA was away is reconciled on return (see §9.2).

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
| | `InpImmediateFlipClose` | `false` | Direction-flip / range box-kill exit mode: `false` = close on the flip only while the open trade is in profit (wait for profit when under water); `true` = close immediately whatever the P&L, as before. |
| | `InpUseStopLoss` | `false` | Initial Stop Loss switch: `false` = deliberate breathing room (`SL = 0.0`), first SL placed by trailstop; `true` = initial hard ATR stop attached at fill. |
| | `InpUseTrailStop` | `true` | Pre-TP1 stepped trailstop enabled. |
| | `InpTrailPctTight` | `40` | Trailstop activation % for Mixed and Choppy regimes (10–70%). |
| | `InpTrailPctSteady` | `55` | Trailstop activation % for Steady regime with clear trend (10–70%). |
| | `InpMagicBase` | `202610` | Base magic number (`+0` M5, `+1` M15, `+2` M30). |
| **Signal, Choppy & Range** | `InpBuyScore` | `2` | Score $\ge$ this triggers BUY. |
| | `InpSellScore` | `-2` | Score $\le$ this triggers SELL. |
| | `InpAllowChoppyTrade` | `true` | **New-entry permission** for a row currently reading Choppy. `false` = no new 2/3 limit or 3/3 market order on that row; a waiting pending is cancelled when the row turns Choppy; already-open trades keep normal management. Header Line 2's `Choppy Trade` mirrors this input. |
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

---

## 7. Chart Timeframe Rule & Market Closed Handling

1. **Strict Chart Timeframe Policy**:
   - Calibrated exclusively for **M5, M15, and M30 charts**.
   - Dropping the EA on any unsupported timeframe (e.g., M1, H1, H4, D1) triggers an immediate collapse:
     - The panel shrinks to: `SimpleEA | Incompatible chart. Switch to M5/M15/M30.`
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
| Trailstop, break-even, TP1/TP2/TP3 partials, score-based exits, box-kill | **Fully active** — open trades keep being managed exactly as normal |
| Panel analysis and Trade Plan | **Fully active** — advice is still computed and shown, it is simply not acted on |

The split is deliberate. Pending orders are *unfilled entries resting at the broker*, so they must not survive an OFF transition. Open trades are the opposite case: with `InpUseStopLoss = false` a hard freeze could leave a position with no stop at all, so management must never stop.

When the timer turns back ON, nothing is replayed or "caught up": placement is simply allowed again from that moment, using the freshest plan. Each transition is written to the Experts log.

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
- The **2nd (Autotrading) panel** appears only when an order exists and keeps its own header (`Autotrading | Trailstop | Stoploss | SYMBOL`); it is not gated by the timer, because it reports trades that are still being managed.
- Header line 1 also carries the diary's `Day: S/W/L` counts; the timer does not stop those counts from reflecting closes of trades that remain under management.
- **Notice panels replace both header lines.** When the market is closed or the chart timeframe is unsupported, the panel collapses to a one-line notice, so no countdown is shown there even though the timer keeps counting.
- Long pauses also print a one-line confirmation to the Experts log when set, when continuing after a restart, and when completed.

### 8.5 Notes and caveats

- The daily window follows the **PC/VPS clock**. Moving the EA to a VPS in another timezone moves `08:00` with it, and a clock left wrong shifts the window.
- "Timer allows placement" is not the same as "an order will be sent": the signal, score gate, trend gate, Choppy permission and broker conditions must also agree. The header can legitimately read `On` while nothing is placed.
- Loading the EA during an OFF period cancels this EA's waiting pendings within a couple of seconds — by design.
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
- observed trailstop performance: the activation percentage and Tight/Steady choice frozen at fill; whether the pre-TP1 stepped trail actually applied; whether any protective stage became active; the best pre-TP1 trailed stop and best broker stop as percentages of the Entry→TP1 distance; the final closing deal's progress toward TP1; and whether that final deal's broker reason was a stop-loss exit;
- final status/outcome, result in `R`, a compact exit reason, and whether the result is still provisional;
- the relevant settings then in force: base risk %, risk/min-lot mode, stop-loss switch, trailstop switch, Choppy permission, and Range Mode.

The file is named for **account + symbol + magic base** (for example, `SimpleEA_Diary_<login>_<symbol>_<magic>.csv`) and is kept in MT5's Common Files area on a live terminal (the tester uses its own file area). Its first line records the local date on which this symbol's diary began. The ten trailstop-performance fields are appended after the original row fields, so a diary written before they existed remains readable; those older rows load with trail activation/lock/final-exit facts marked unknown rather than reconstructed. Saves are written through a temporary file and moved into place so an interrupted save does not leave half-written rows. If an existing diary cannot be read (or declares a diary format this EA build does not understand), SimpleEA logs that fact and refuses to overwrite it blind; that run's new rows are kept in memory until the file problem is fixed and the EA is restarted. A year of placed ideas is still a small file because ticks are not stored.

History begins when the diary feature first runs for that account/symbol/magic. A position or pending that already existed before that moment has no diary row and is deliberately left **untracked** rather than reconstructed from guesses. Orders placed manually or by another EA/magic are likewise not diary signals. If SimpleEA later finds that one of its tracked positions closed at the broker while the EA was away, it reconciles that row from deal history; a tracked pending that ended at the broker is reconciled from order history. In particular, if a pending filled and the resulting position closed while ticks were interrupted, the position identifier in order history makes that row a closed `W`/`L`/`BE` trade — it is not misreported as an unfilled `Exp`.

> Do not run two SimpleEA instances with the same account, symbol, and magic base against the same diary file. They would already be fighting over the same autotrading slots; the diary follows the same one-owner rule.

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
  Trail 30: Armed 67% | Lock 38% | Stop exits 8 | Giveback 29%
  First step: Use minimum lot or avoid expensive hours first.
...
Diary suggests first steps; it never changes settings.
```

For each timeframe, the panel deliberately shows **both lifetime and recent health**. Lifetime totals say what the lane has done overall; the newest closed trades say whether it is decaying now. A lane can therefore have a respectable lifetime record and still correctly read `Poor` because its latest block has deteriorated.

The `Trail` line uses that same newest-30 closed-trade window (or fewer while the lane is still learning), but it is **descriptive evidence, not a fifth health check** and never changes the lane's label or suggested first step:

- **`Armed`** is the share of eligible trades whose **pre-TP1 stepped trailstop applied at least once**. Eligible means the trade was placed with `InpUseTrailStop` on and SimpleEA actually observed the filled slot's trail state. Older diary rows without trail fields, and trades placed with the trailstop off, are excluded from this denominator rather than counted as failures to arm. Break-even or TP-stage protection by itself does not count as `Armed`.
- **`Lock`** is the median best pre-TP1 trailed stop among the Armed trades, expressed on the Entry→TP1 scale (`0%` = entry, `100%` = TP1). It answers “when the trail did take over, how much progress had it typically locked?”
- **`Stop exits`** is a count, among Armed trades whose final closing-deal reason is known, of those whose final deal was triggered by a broker stop-loss. The wording stays at “stop exits” because the broker reason proves a stop-order exit; by itself it does not prove whether that particular stop level came from the pre-TP1 trail, break-even, a TP-stage lock, or an initial hard stop.
- **`Giveback`** is the median `peak progress − final closing-deal progress`, again as percentage points of Entry→TP1 and never below zero, among Armed trades with a known final deal price. Because TP1/TP2 may already have banked partial volume, this is peak-to-**final-leg** giveback, not a volume-weighted giveback for the whole original position; read it beside final `R`, not instead of it.

A field shows `--` when its own eligible/known sample is empty. Existing closed rows cannot recover activation or lock history retrospectively, so after this feature first runs the Trail line fills in as newly observed trades close and replace the recent window.

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
