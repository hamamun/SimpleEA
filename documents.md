# SimpleEA — Complete Documentation & Process Specification

SimpleEA is a professional multi-timeframe Expert Advisor for MetaTrader 5 (MT5). It is engineered for **M5 (scalp)**, **M15 (short-term)**, and **M30 (intraday)** on any symbol (FX, Gold, Indices, Crypto). It operates on finished, closed bars only to guarantee strictly **non-repainting** analysis.

This document serves as the **single source of truth** for SimpleEA's architecture, indicator maths, trade scoring, order execution, position lifecycle management, and parameter configurations.

---

## 1. System Overview & Core Workflow

SimpleEA runs simultaneously as:
1. **An Analytical On-Chart Dashboard (Main Panel & Trade Plan)**: Evaluates trend, timing, market structure, and statistical memory (Hurst regime) independently across M5, M15, and M30.
2. **An Automated Execution Engine (`InpAutoTrading`)**: Places, manages, trails, scales out (partials), and protects orders on each timeframe independently via unique magic numbers (`InpMagicBase + TF_INDEX`).

### Main Panel Display Format
Each of the three timeframes (**M5 Scalp**, **M15 Short-term**, **M30 Intraday**) displays a two-line block:
- **Line 1: Trend & Regime**
  - **Trend (3 types)**: **`Going up`** (Green), **`Going down`** (Red), or **`Sideways`** (Grey).
  - **Regime (3 types)**: **`Steady`** (Blue), **`Mixed`** (Grey), or **`Choppy`** (Orange).
  - All 9 combinations ($3 \times 3$) can appear independently on each timeframe.
- **Line 2: Signal & Score**
  - **Signal**: **`BUY`** (Green, when score $\ge +2$), **`SELL`** (Red, when score $\le -2$), or **`HOLD`** (Grey, when score is between $-1$ and $+1$).
  - **Score**: Always printed explicitly beside the signal as `+3 / 3`, `+2 / 3`, `+1 / 3`, `+0 / 3`, `-1 / 3`, `-2 / 3`, or `-3 / 3`.
  - **When score is `+1 / 3` or `-1 / 3`**: The signal clearly shows **`HOLD`** (in grey) with the score beside it, and the Trade Plan row underneath displays: `score +1/3 — under the +2/-2 gate` (stating exactly why no trade is placed). No regime hides the score.

```
┌──────────────────────────────────────────────────────────────────────────┐
│  SimpleEA  | Autotrading : On                      XAUUSD  |  M5         │
│  Timer: Off | Choppy Trade: On | M15/M30 Same Trend: Off                 │
├──────────────────────────────────────────────────────────────────────────┤
│  M5   Scalp       Trend: Going up     Regime: Steady                     │
│                   Signal: BUY         Score: +3 / 3                      │
│  M15  Short-term  Trend: Sideways     Regime: Mixed                      │
│                   Signal: HOLD        Score: +1 / 3                      │
│  M30  Intraday    Trend: Going down   Regime: Choppy                     │
│                   Signal: SELL        Score: -2 / 3                      │
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
       (or ER < 0.10 Dead Gate)                 (or ER Gate)
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
        │     Steady / Mixed                 Choppy (H < 0.45)
        │    0.5 ATR Pullback              Box Band Fade (or fallback)
        │           │                            │
        └───────────┼────────────────────────────┘
                    ▼
          [ Order Sent to Broker ]
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
   - Reversal / Box-kill: protection exit — closes immediately only while in profit (default); `InpImmediateFlipClose = true` restores the immediate exit whatever the P&L
```

The panel's top band is two lines: the master status, then the modes behind it.

### Header Line 1 — Autotrading State & Resume Countdown

`SimpleEA | Autotrading : <state>` `[Resume <countdown>]` `| SYMBOL | TF`

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
- Panel width is reserved only while the countdown is on screen, floored at the old 6-character value slot, so a chart that never uses the timer measures exactly as it did before.

### Header Line 2 — Modes

`Timer: <status> | Choppy Trade: On/Off | M15/M30 Same Trend: On/Off`

- **Timer** — `Off` (no schedule, no pause), `On 08:00-17:00` (window open), `Paused 08:00-17:00` (outside the window), or `Paused by request` (one-shot pause running; the exact remaining time lives on line 1).
- **Choppy Trade** — mirrors `InpRangeMode`.
- **M15/M30 Same Trend** — mirrors `InpRequireM15M30SameTrend`.
- Grey = the mode is switched off (a choice, not an error); orange is reserved for a timer that is blocking trades.

While the timer blocks, the header grows by the wider state word and the countdown:

```
┌──────────────────────────────────────────────────────────────────────────┐
│  SimpleEA  | Autotrading : Timer Pause  Resume 2h14m   XAUUSD  |  M5     │
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

> **CRITICAL RULE:** The Hurst Regime sets the **entry style** (where limits sit), **never the trade permission**. The score alone dictates *whether* a row trades.

---

## 3. Order Placement & Scoring Rules

$$\mathbf{Total\ Score} = \text{Vote 1} + \text{Vote 2} + \text{Vote 3} \quad \in [-3, +3]$$

| Score | Qualification | Action Taken |
|---|---|---|
| **+3 / 3** or **-3 / 3** | All 3 votes agree | **Market Order** immediately at live Ask/Bid across all regimes. |
| **+2 / 3** or **-2 / 3** | 2 of 3 votes agree | **Pending Limit Order** waiting for a favorable pullback. |
| **-1, 0, +1** | Score below threshold | **HOLD (Stand aside)**. The panel states the exact refusal reason. |

### Where Pending Limit Orders Wait
- **Steady / Mixed Regimes**: The limit order is placed at a **$0.5 \times \text{ATR}$ pullback** beyond market price (clamped to respect broker stops level and spread).
- **Choppy Regime (`InpRangeMode = true`)**: The order is priced at the **20-bar box band** (`range fade`), aiming for the box midpoint (target = 50% of the box, stop = band $+ 1.0 \times \text{ATR}$).
  - *Box Validation Gates*: Spread clearance ($\text{half-box} \ge 3 \times \text{spread}$), box height ($\ge 2.0 \times \text{ATR}$), efficiency ($\text{ER} < 0.40$), and current price inside the box.
  - *Fallback*: If any box gate fails, the limit automatically falls back to the standard $0.5 \times \text{ATR}$ pullback limit. The box never cancels a trade that the score approved.

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
- **Pending Order Leash Expiry**: Waiting limit orders expire and cancel after 3 closed bars (trend) or 8 closed bars (range fade) from signal birth (`sigBirth`), matching the on-screen `Valid: left/total bars` countdown.
- **Manual Closes**: SimpleEA executes automatically on closed bars. If a trader manually closes a trade in MT5, the EA does not treat this as a permanent block. If the signal remains qualified on the next bar close, the EA will enter again. (To stop trading, use `InpAutoOffHours` or set `InpAutoTrading = false`).
- **Restart Resilience**: Active range states (`isRange`, `rngTop`, `rngBot`, `entryScore`, `placedBar`) are persisted in terminal GlobalVariables so that terminal restarts or recompiles never strip a range trade of its box-kill rules.

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
| **Signal & Range** | `InpBuyScore` | `2` | Score $\ge$ this triggers BUY. |
| | `InpSellScore` | `-2` | Score $\le$ this triggers SELL. |
| | `InpRangeMode` | `true` | Trade the 20-bar box band on Choppy rows (`false` = standard half-ATR pullback). |
| **Trade Plan & Sizing**| `InpUseRisk` | `true` | Risk % sizing mode (`false` = fixed lot ladder per 1,000 balance). |
| | `InpRiskPct` | `0.5` | Risk % per trade at score $\pm 2$; score $\pm 3$ risks double (1.0%). |
| | `InpUseMinLot` | `false` | Override sizing to force symbol's minimum lot. |
| **Market Closed** | `InpDetectClosed` | `true` | Collapse panel to `Market Closed` when market is shut. |
| | `InpClosedStaleMin` | `30` | Quote age in minutes that counts as market closed (0 = off). |
| **Panels & Display** | `InpPanelX` / `InpPanelY` | `12` / `24` | Main panel coordinates in pixels. |
| | `InpAutoPanelPos` | `Bottom` | 2nd (Autotrading) panel position: `Right` or `Bottom`. |
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

Both are layered **on top of** the existing permission checks: master switch, supported chart (M5/M15/M30), market open, and the terminal/account "algo trading allowed" flags must all still pass.

### 8.1 What "timer OFF" does — and deliberately does not do

| Action | While the timer is OFF (outside the window, or during a pause) |
|---|---|
| Open a new market order | **Blocked** |
| Place / refresh a waiting pending limit order | **Blocked**, and any existing waiting pending is **cancelled** so it cannot fill while you believe autotrading is off (retried every 2 s if the broker refuses) |
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
- **Notice panels replace both header lines.** When the market is closed or the chart timeframe is unsupported, the panel collapses to a one-line notice, so no countdown is shown there even though the timer keeps counting.
- Long pauses also print a one-line confirmation to the Experts log when set, when continuing after a restart, and when completed.

### 8.5 Notes and caveats

- The daily window follows the **PC/VPS clock**. Moving the EA to a VPS in another timezone moves `08:00` with it, and a clock left wrong shifts the window.
- "Timer allows placement" is not the same as "an order will be sent": the signal, score gate, trend gate and broker conditions must also agree. The header can legitimately read `On` while nothing is placed.
- Loading the EA during an OFF period cancels this EA's waiting pendings within a couple of seconds — by design.
- The timer never closes positions. It is a schedule and a snooze button for *entering* trades, not a "close everything at 17:00" switch.
