# SimpleEA — multi-timeframe direction panel (MT5)

A very simple, read-only Expert Advisor that shows, in plain words, what price is doing on
**M5 (scalping)**, **M15 (short-term)** and **M30 (intraday)** on **any symbol**. Each
timeframe gets two lines — the plain words first, then the original trading read underneath,
so nothing from the first panel is lost:

```
 ┌─────────────────────────────────────────────────────────────┐
 │  SimpleEA                                       XAUUSD  M5  │
 ├─────────────────────────────────────────────────────────────┤
 │  M5   Scalp       Trend: Going up     Regime: Steady        │
 │                   Signal: BUY         Score: +3 / 3         │
 │  M15  Short-term  Trend: Sideways     Regime: Mixed         │
 │                   Signal: HOLD        Score: +1 / 3         │
 │  M30  Intraday    Trend: Going down   Regime: Choppy        │
 │                   Signal: SELL        Score: -2 / 3         │
 └─────────────────────────────────────────────────────────────┘
```

- **Trend** (which way it is going) can only be: **Going up**, **Going down**, or **Sideways**.
- **Regime** (how it is moving) can only be: **Steady** (keeps going the same way),
  **Mixed** (no clear habit), or **Choppy** (keeps turning back on itself).
- **Signal / Score** are the original read, unchanged: Going up = **BUY**, Going down =
  **SELL**, Sideways = **HOLD**, with the score that produced it beside it. When the regime
  blocks a row, the Signal still shows the trade the score *would* have fired — **greyed out**
  — so a gate is never a silent blank.
- Each regime decides its own row's game (**Part 2**): a **Steady** row trades the trend as
  before; a **Choppy** row trades the box (band entry, midpoint target — see *Range mode*);
  a **Mixed** row, a dead market or a failed gate stands aside and the trade plan below says
  exactly why. Rows never look at each other — M5's chop never holds M15 or M30 back.
- Below the three rows, a **second group** gives one trade plan per timeframe — entry, lot, stop,
  target and validity — in the same style. See *Trade plan* below.
- On any chart timeframe other than M5 / M15 / M30 the panel shows **no data at all** — just the
  header line and a notice, and no trade plan. See *Chart timeframe rule* below.

The two are independent, so all nine pairings can appear — e.g. *Going up + Choppy* means
"rising overall, but messily."

### Chart timeframe rule

This engine is calibrated for **M5, M15 and M30 only**, so the panel is only shown on those
charts. Put the EA on **any other timeframe** (M1, M2, M4, H1, H4, D1, …) and it shows no data
at all — just the header line, with the notice where the timeframe rows would have started:

```
 ┌─────────────────────────────────────────────────────────────┐
 │  SimpleEA                                       XAUUSD  H1  │
 ├─────────────────────────────────────────────────────────────┤
 │  Incompatible chart. Switch to M5/M15/M30.                  │
 └─────────────────────────────────────────────────────────────┘
```

Read as one line: **SimpleEA | Incompatible chart. Switch to M5/M15/M30.**

While the chart is on a wrong timeframe **nothing is calculated**: no history is pulled, no
indicator runs, and the M5/M15/M30 rows are not drawn at all — so there is no stale or
out-of-context number on the screen that could be mistaken for a live read. The chart's own
timeframe is named in the header, and the same line goes to the *Experts* journal:

```
SimpleEA: the H1 chart is not supported. This panel is calibrated for M5/M15/M30 only
- switch the chart timeframe to see it.
```

Switch the chart back to M5, M15 or M30 and the full panel returns immediately, recalculated
from current data — whether or not MetaTrader restarts the EA for the change.

To see the whole thing without opening MetaTrader, `research/walk_timeframes.py` attaches the EA,
changes the chart timeframe through H1 → M15 → M1 → D1 → H4 → M30 and prints what is on the chart
at every step. The rule itself is verified state by state in
`research/verify_timeframe_gate.py`.

**It contains no order-sending code.** It cannot place, modify or close a trade, so it is safe to
leave on a live chart.

> **Algo Trading:** because the EA never trades, it also works with the *Algo Trading* button off.
> If the panel does **not** appear, that button is the usual cause — turn it on, or right-click the
> chart → *Expert Advisors* → *Properties* → *Common* → tick **Allow Algo Trading**. Turning it on
> is harmless here: there is no trade code for it to enable.

---

## 1. Install

1. Open MetaTrader 5 → **File → Open Data Folder** → `MQL5\Experts\`
2. Copy `SimpleAdvisor.mq5` into that folder (a subfolder such as `Experts\SimpleEA\` is fine).
3. Open **MetaEditor** (F4), open the file, press **F7** to compile. Expect `0 errors`.
4. Back in the terminal, press **Ctrl+N** → Navigator → Expert Advisors → drag `SimpleAdvisor`
   onto an **M5, M15 or M30 chart** (any symbol works; those three timeframes are the ones the
   engine is calibrated for). On any other timeframe the panel deliberately shows only its header
   and the *Incompatible chart* notice — drop it on an H1 chart and that is exactly what you will
   see.
5. Colours, position, and font are all inputs under *Panel appearance*.

> If a row shows `waiting ...`, the terminal has not finished downloading history for that
> timeframe yet. Leave the chart open and it will fill in.

---

## 2. What the engine actually does

The brief was: *not* textbook RSI/EMA — use something current. So the three components are
model-free, low-lag methods from the recent literature rather than 1970s smoothing.

### Component 1 — Trend: Ehlers Precision Trend (TASC, September 2024)

`Trend = HighPass3(price, L1) − HighPass3(price, L2)`

An SMA/EMA is a **lowpass** filter: it keeps the slow components of price, and that is
precisely what makes it lag. Ehlers' 2024 method instead **subtracts one highpass filter from
another**, which produces a **bandpass** tuned to the timeframe's cycle band. Highpass filters
have almost no lag, so the resulting trend line turns close to the same time price does.

The coefficients are transcribed from Ehlers' own TradeStation listing published in the TASC
Traders' Tips for that article:

```
a1 = Exp(-1.414 * 3.14159 / Period)
b1 = 2 * a1 * Cosine(1.414 * 180 / Period)     ' Cosine() takes DEGREES
c2 = b1 ;  c3 = -a1*a1 ;  c1 = (1 + c2 - c3) / 4
HP = c1*(P - 2*P[1] + P[2]) + c2*HP[1] + c3*HP[2]
```

`1.414 * 180 / Period` degrees equals `1.414 * π / Period` radians, so the conversion is
already accounted for. **Several popular public ports convert it a second time and end up with
the filter centred on the wrong frequency** — worth knowing if you compare implementations.

**Vote 1 = sign(Trend).**

### Component 2 — Momentum: rate of change of the Precision Trend

The ROC of the trend line is exactly zero at every peak and trough of that line, so its sign
marks the onset or continuation of a push rather than its level.

**Vote 2 = sign(ROC).**

### Component 3 — Regime: rolling Hurst exponent

The Hurst exponent measures long-range memory in the price series:

| H | Meaning | Action |
|---|---|---|
| **> 0.55** | persistent — trends extend | the trend is real, **play the trend game** (vote with it) |
| 0.45 – 0.55 | random walk — no memory | **stand aside** — no edge either way (the plan block says why) |
| **< 0.45** | anti-persistent — moves revert | **play the range game** — the box trade, see *Range mode* |

**The regime decides the game, per row (Part 2).** It is no longer just a vote that can go
quiet: each timeframe's regime picks between the trend game (Steady), the range game
(Choppy) and standing aside (Mixed), and every refusal is written on that row's plan line —
`mixed — no edge either way`, `dead market — nothing moves`, `chop — range mode is off`,
`chop — no valid box yet`, `chop — nothing clears the spread`. The decision is strictly
per-timeframe: no row's regime can veto another.

This is the component that stops the panel from issuing a confident call in a market that has
no directional memory. It is the difference between a signal panel and a coin-flip generator.

The estimator is a **variance-scaling (2-N point)** calculation: log returns are aggregated into
non-overlapping blocks, and the slope of `log(std)` against `log(block size)` is H. It was
cross-checked against detrended fluctuation analysis (DFA) on real EURUSD data — see §4 — which
is why the cheap version is used inside the terminal.

### Score

```
score = vote1 + vote2 + vote3          range -3 .. +3
BUY   if score >= +2
SELL  if score <= -2
HOLD  otherwise (and the plan block says WHY)
```

A **Choppy** row never reaches ±3 — the regime adds no trend vote in the range game; it
trades through the box gates instead (entry, stop and target come from the box geometry, not
from the score). A **Mixed** row stands aside whatever the score says.

Kaufman's **Efficiency Ratio** is a dead-market gate: if ER is below `InpERDead` (default 0.10)
the instrument is not travelling anywhere, so the row is forced to `HOLD` regardless of score —
and now says so: `dead market — nothing moves`.

On the chart those three outcomes are spelled out as **Going up** / **Going down** /
**Sideways**, and the Hurst read above is spelled out as **Steady** / **Mixed** / **Choppy**.
Only the words changed — the calculation behind them is untouched. (The panel does not show a
"volatile" word: the engine judges *how* moves behave, not *how big* they are, so it would be
dishonest to label one.)

**Every calculation uses closed bars only**, so the panel never repaints and a historical
reading never changes after the fact.

---

## 3. Parameters

| Group | Input | Default | Meaning |
|---|---|---|---|
| Panel | `InpPanelX/Y` | 12 / 24 | position in pixels |
| | `InpFontSize` | 9 | font size |
| Thresholds | `InpBuyScore` | 2 | score ≥ this ⇒ BUY |
| | `InpSellScore` | −2 | score ≤ this ⇒ SELL |
| | `InpBarsToLoad` | 700 | closed bars pulled per timeframe |
| Shared | `InpHurstWindow` | 256 | Hurst estimate window in bars |
| | `InpERPeriod` | 20 | efficiency-ratio period |
| | `InpERDead` | 0.10 | below this ⇒ dead market, force HOLD (with reason) |
| Range | `InpRangeMode` | **true** | range game on (false ⇒ every chop row says `chop — range mode is off`) |
| | `InpRangeBars` | 20 | range box = the last N closed bars' highs/lows |
| | `InpRangeMinATR` | 2.0 | box must be at least this many ATR tall |
| | `InpRangeSpreadX` | 3.0 | half-box target must clear at least this many spreads |
| | `InpRangeERMax` | 0.40 | efficiency above this ⇒ a walk, not a box |
| | `InpRangeSLATR` | 1.0 | range stop = opposite band + this many ATR |
| Per TF | `InpL1_*` / `InpL2_*` | 150 / 24 | Precision Trend filter periods |
| | `InpHurstTrend*` | 0.55 | persistent threshold |
| | `InpHurstRevert*` | 0.45 | anti-persistent threshold |

Raising `InpHurstTrend` makes the panel more selective (more HOLD, fewer calls). Raising
`InpBuyScore` to 3 requires all three components to agree.

---

### Trade plan — the second group (advice only, the EA still never sends an order)

Below the three timeframe rows, separated by a single line, comes a **second group with one block
per timeframe**. Same two-column style as the group above it, and no heading line — the `M5` /
`M15` / `M30` at the start of each block says what it is. The point of the per-timeframe shape is
this: when autotrading arrives, the executor reads one row and acts on that timeframe.

```
 ┌────────────────────────────────────────────────────────────────────────────────────┐
 │  SimpleEA  | Autotrading : On                                     |  XAUUSD  |  M5 │
 ├────────────────────────────────────────────────────────────────────────────────────┤
 │  M5   Scalp         Trend: Going down      Regime: Steady                          │
 │                     Signal: SELL           Score: -3 / 3                           │
 │  M15  Short-term    Trend: Sideways        Regime: Mixed                           │
 │                     Signal: BUY            Score: +2 / 3                           │
 │  M30  Intraday      Trend: Going down      Regime: Steady                          │
 │                     Signal: SELL           Score: -2 / 3                           │
 ├────────────────────────────────────────────────────────────────────────────────────┤
 │  M5   market -3/3   Entry:  4285.70        Lot:     0.28                           │
 │                     Stop:   4285.98 28pts  Target:  4285.45 25pts   Reach: ~1 bar  │
 │                     Risk:   7.84 USD       Reward:  7.00 USD        Valid: 3 bars  │
 │  M15  HOLD          mixed — no edge either way                                     │
 │  M30  pending -2/3  Entry:  4286.55        Lot:     0.01                           │
 │                     Stop:   4289.10 255pts Target:  4281.45 510pts  Reach: ~9 bars │
 │                     Risk:   2.55 USD       Reward:  5.10 USD        Valid: 3 bars  │
 └────────────────────────────────────────────────────────────────────────────────────┘
```

Two Part 2 readings are visible at once: M15's Mixed regime **blocks** its `+2 / 3` score —
the `BUY` above is drawn *greyed out* on the chart (the trade that was refused), and its plan
collapses to the single line `HOLD  mixed — no edge either way`. And when a Choppy regime
takes the range game instead, the block carries the box's own numbers — entry at the opposite
band, stop = band + 1 ATR, target = half the box (the midpoint):

```
 ┌────────────────────────────────────────────────────────────────────────────────────┐
 │  M5   range fade    Entry:  4286.60        Lot:     0.14                           │
 │                     Stop:   4286.88 28pts  Target:  4285.60 100pts  Reach: ~13 bars│
 │                     Risk:   3.92 USD       Reward:  14.00 USD       Valid: 3 bars  │
 └────────────────────────────────────────────────────────────────────────────────────┘
```

**A HOLD or waiting timeframe takes a single line**, so the group is only as tall as it has
content for — and the panel is only as wide as its widest line, measured before it is drawn.
With no signals anywhere the group is three short lines and the box shrinks back to the width the
header and the "Incompatible chart" notice need; with `InpShowPlan=false` the group is not drawn
at all.

The width budget is one character = 0.55 em at the terminal's own screen DPI, which is exactly
what the default font (`InpFont = "Consolas"`) occupies — so the panel is neither clipped nor
padded. A wider monospaced face (Courier New, Lucida Console, ~0.60 em) on a big font can make a
long line touch the border: `research/walk_trade_plan.py` measures that across DPI 72–192 and
sizes 6–16 and prints the answer at the end of its run.

| Your question | How the panel answers it |
|---|---|
| **1. Entry point** | `Entry:` is the price to use — the current ask/bid for that direction (market) or the pending price one `InpPendATR` step better. **The EA decides which, per timeframe, from the score**: `market -3/3` = all three components agree, go now; `pending +2/3` = only two agree, so the entry waits for a better price. In the **range game** the box decides instead: `range fade` = a limit at the **opposite band** of the box, no matter what the score says. |
| **2. Lot size** | `Lot:` — from balance, score and that timeframe's own stop distance, snapped to your broker's lot step and clamped to its minimum and maximum. |
| **3. Take profit** | `Target:` — price **and points**, with the same amount in account currency on the `Reward:` cell. |
| **4. Stop loss** | `Stop:` — price **and points**, with the money on the `Risk:` cell. Widened automatically (and marked `(min)`) if your broker demands a minimum stop distance. |
| **5. Reach** | `Reach:` — a rough bar count for how long the target may take (the target's own distance in ATR units, squared — a typical random walk, not a forecast). This is what makes scalp / short-term / intraday visibly different in **time**, not only in points. |
| **6. Validity** | `Valid:` — `InpValidBars` bars from the close of that timeframe's signal bar (default 3 = the measured median, see below). |

**Three sizing modes** (`InpUseRisk` / `InpUseMinLot`):

| Mode | What it does |
|---|---|
| Risk (**default**, `InpUseRisk=true`) | Risks `InpRiskScore2` % of balance at score 2 and `InpRiskScore3` % at score 3 (defaults 0.5 / 1.0). The lot is whatever risks that much at that timeframe's stop — a wider stop automatically means a smaller lot. |
| Risk-off (`InpUseRisk=false`) | Ignores the stop distance entirely: a balance ladder — one 0.01 lot per `InpBalPer001` of balance (default 1,000), multiplied by `InpScore3Factor` (1.5) when all three components agree. |
| Min lot (`InpUseMinLot=true`) | Always advises your symbol's smallest allowed lot, whatever the risk says. This overrides the other two. |

Two honest touches: if the smallest lot risks **more** than your target percentage, the `Lot:` cell
says so (`0.01 (min, 3.36 USD)`) instead of quietly over-risking; and every level is snapped onto
the broker's point grid first, so the printed points, prices and money are three views of exactly
the same level.

**No order is ever sent.** The EA contains no `OrderSend`, no `CTrade`, no trade calls of any
kind — this group only prints numbers for you to type in yourself.

New inputs, all under *Trade plan*:

| Input | Default | Meaning |
|---|---|---|
| `InpShowPlan` | true | Draw the second group at all |
| `InpUseRisk` | true | Size by risk % of balance (false = balance ladder) |
| `InpUseMinLot` | false | Always advise the symbol's minimum lot |
| `InpRiskScore2` / `InpRiskScore3` | 0.5 / 1.0 | Risk % at score 2 and score 3 |
| `InpBalPer001` | 1000 | Risk-off mode: balance per 0.01 lot |
| `InpScore3Factor` | 1.5 | Risk-off mode: multiplier at score 3 |
| `InpATRPeriod` | 14 | ATR period, closed bars, each timeframe's own |
| `InpSLATR_M5` / `InpTPATR_M5` | 1.0 / 0.9 | **M5 scalp:** stop and target in ATR — aims near and quick (R:R ≈ 1:0.9) |
| `InpSLATR_M15` / `InpTPATR_M15` | 1.2 / 1.8 | **M15 short-term:** stop and target in ATR (R:R 1:1.5) |
| `InpSLATR_M30` / `InpTPATR_M30` | 1.5 / 3.0 | **M30 intraday:** stop and target in ATR — aims far and lets the move run (R:R 1:2) |
| `InpPendATR` | 0.5 | How far the pending entry sits from the market |
| `InpValidBars` | 3 | How many bars the reading is worth acting on |

Everything is read from your broker's own contract data (tick value, tick size, lot step,
minimum/maximum lot, minimum stop distance, account balance and currency), so the block is correct
on 2- and 3-digit gold, FX, indices, cent accounts and non-USD accounts alike.

The arithmetic is checked symbol by symbol in `research/verify_plan_math.py`, and
`research/walk_trade_plan.py` renders the whole panel for ten states — all timeframes active,
one active, none, a loading timeframe, a small account, a very large balance, min-lot mode,
the plan switched off, blocked rows stating their reasons, and range fades on the box —
failing if any line would overflow.

---

### Autotrading & Second Panel (`Autotrading`)

Controlled by `InpAutoTrading` (**default `true`**, hands-free Full Auto mode; set `false` for
read-only mode):

| Input | Default | Meaning |
|---|---|---|
| `InpAutoTrading` | **true** | Full-auto execution on (`true`) or read-only (`false`) |
| `InpUseStopLoss` | **true** | Place initial Stop Loss on order (`true` default); when `false`, no SL is placed initially, and when `TP1` hits a Stop Loss is placed at the entry point (Break-Even) |
| `InpAutoPanelPos` | **Right** (`AUTO_POS_RIGHT`) | Second panel placement: **Right** (beside Main Panel) or **Bottom** (below Main Panel) |
| `InpMagicBase` | 202610 | Base magic number (`+0` M5, `+1` M15, `+2` M30) |
| `InpSlippagePts` | 20 | Maximum slippage in points for market orders |

#### Execution & Trade Management Rules

1. **One Order per Timeframe at a Time:** Strictly 1 active trade or pending order per timeframe
   (`M5`, `M15`, `M30`) at a time. When all three timeframes qualify, up to 3 independent trades
   can run simultaneously.
2. **M5 vs M15/M30 Trend Alignment:**
   - **M5** trades its own signal and score directly.
   - **M15** and **M30** only place a new order when **both M15 and M30 trends match** (`Both Going up`
     or `Both Going down`).
3. **Market vs Pending Limit Placement:**
   - Score `3/3` (`+3` or `-3`) $\rightarrow$ opens a **Market order** immediately.
   - Score `2/3` (`+2` or `-2`) $\rightarrow$ places a **Pending Limit order** (`BUY LIMIT` or `SELL LIMIT`)
     at the advised pullback entry.
4. **Three Take-Profit Levels (`TP1`, `TP2`, `TP3`):**
   - **TP3** = 100% of SimpleEA's advised target points.
   - **TP2** = 25% less than TP3 (`75%` of TP3).
   - **TP1** = 25% less than TP2 (`75%` of TP2 = `56.25%` of TP3).
5. **Partial Closes, Break-Even Trailstop & Score Watcher:** *(trend trades — range fades are
   exempt; see rule 7)*
   - **At TP1 Hit:**
     - Moves Stop Loss to **Entry (Break-Even)** and activates `Trailstop : On` in the top row (for both
       minimum lot and `> minLot`).
     - If current lot > minimum lot, closes **70%** of the lot.
     - Activates the **Score & Direction Watcher** (for both minimum lot and `> minLot`): if the
       timeframe's score weakens or changes direction, closes the remaining position immediately;
       if the score stays strong in the same direction, continues holding for TP2 and TP3.
   - **At TP2 Hit:**
     - If current lot > minimum lot, closes partial volume to **reduce remaining lot size to the
       broker's minimum lot** and locks Stop Loss to `TP1`; continues watching score for TP3.
   - **At TP3 Hit:** Closes the remaining order in full.
6. **Candle-by-Candle Smart Updates:**
   - **Open Market Trade:** On each new closed candle in the same direction, updates `TP1 / TP2 / TP3`
     from the new plan and **only tightens `SL` (never widens risk)**. If the timeframe drops to
     `HOLD` *before* TP1 is hit, closes immediately if the trade is in profit. If the timeframe
     flips to the opposite direction, closes immediately.
   - **Pending Limit Order:** On each new closed candle in the same direction (`2/3`), updates
     `Entry`, `SL`, and `TP1 / TP2 / TP3` to the new plan. If the score upgrades from `2/3` to
     `3/3` in the same direction, deletes the waiting pending order and opens the **Market order**
     immediately. Cancels if the direction changes, drops to `HOLD`, or reaches `InpValidBars` expiry.
7. **Range fades (Part 2 — Choppy rows):**
   - The order is **always a Pending Limit at the opposite band** of the box (never a market
     order — the score has no say in the entry), with `Stop = band + InpRangeSLATR × ATR` and
     `TP3 = half the box` (the midpoint). The plan block shows it as `range fade`.
   - **Box-kill:** if a closed bar closes **outside the trade's box**, the pending is cancelled
     or the open trade closed immediately — the broken box is the thesis being invalidated.
   - The **score watcher does not apply** to range fades (after TP1/TP2): the box midpoint, the
     stop and the box-kill govern their exits. The flip-to-opposite-direction and
     HOLD-in-profit rules still apply, exactly as for trend trades.
   - M5 range fades follow **rule 2 as usual**: M5 places its own box trade entirely on its own;
     M15/M30 still require their mutual trend match.

#### Second Panel Layout (Right or Bottom of Main Panel)

When any market or pending order is active, the **Main Panel** tags that timeframe's plan block
with `[OPEN]` or `[PLACED]`, and a **Second Panel (`Autotrading`)** opens automatically to the
right (or below, when `InpAutoPanelPos = Bottom`) of the Main Panel, and closes completely when no
trade or pending order is open:

```
 ┌─────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
 │  Autotrading   | Trailstop : On  | Stoploss : On                                                 |  XAUUSD  │
 ├─────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
 │  M5  | OPEN SELL      Lot @    0.09                        Entry:     4285.70                  Ask: 4285.56 │
 │                       TP1:     4285.56 (1.26 USD) [HIT]    TP2:       4285.51 (1.71 USD)                    │
 │                       TP3:     4285.45 (2.25 USD)          SL:        4285.70 (0.00 USD) [BE]               │
 │                       Status:  P/L +1.26 USD               Distance:  to TP2 19 pts                         │
 ├─────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
 │  M30 | BUY LIMIT      Lot @    0.01                        Entry:     4284.85                  Ask: 4285.56 │
 │                       TP1:     4287.72 (2.87 USD)          TP2:       4288.68 (3.83 USD)                    │
 │                       TP3:     4289.95 (5.10 USD)          SL:        4282.30 (2.55 USD)                    │
 │                       Waiting: distance 71 pts             Distance:  to TP1 287 pts                        │
 └─────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

All autotrading rules and the 2nd panel layout are verified end-to-end in
`research/verify_autotrading.py`.

### How far ahead is a reading good for?

See **[research/HORIZON.md](research/HORIZON.md)** for the measured answer, with the harness
(`research/horizon_study.py`, `research/first_passage.py`) included. In one line: a reading
applies from the close of the bar it is computed on, stays on the panel a median of **2–3 bars**
(M5 ~10 min, M15 ~45 min, M30 ~90 min), and where a forward edge exists at all it only appears
at **6–16+ bars** — longer than the reading survives. On M5 the median net move while the
reading is on screen (0.0–0.7 pips) does not even cover a retail spread.

---

## 4. Validation — read this before trusting the panel

Everything below was measured on real bar data, and the harness that produced it is included in
`research/` so you can re-run it.

**Data:** EURUSD M5/M15/M30, GBPUSD M5, USDJPY M5, XAUUSD M15 (Mar–Sep 2026) and EURUSD M1 for
all of 2015 as a fully independent era. Sample split in half: **IS** = first half, **OOS** =
second half.

**Method:** each signal was tested with a Monte-Carlo null that shuffles the directions while
keeping the identical long/short mix — this preserves the return distribution (and therefore any
sample drift) and asks only whether the *timing* of the directions carries information.

### 4.1 The honest headline: direction alone is close to a coin flip

Across every symbol, timeframe and era tested, hit rate sat between **48% and 52%**:

| Rule | TF | Horizon | IS hit | OOS hit | IS pips | OOS pips |
|---|---|---|---|---|---|---|
| Trend | M5 | 6 bars | 0.481 | 0.476 | −0.196 | −0.079 |
| Trend | M15 | 16 bars | 0.509 | 0.519 | +0.669 | +0.892 |
| Trend | M30 | 16 bars | 0.541 | 0.506 | +0.784 | +1.088 |

Note the trend rule was **significantly negative at short horizons** (M5, p = 0.003 IS). At M5
the measured edge is ~0.2–0.5 pip while a typical retail spread is ~0.8–1.0 pip — the signal
edge is *smaller than the transaction cost*. **M5 scalping is structurally unprofitable on a
standard account regardless of signal quality.** That is a cost problem, not a signal problem,
and no indicator fixes it.

### 4.2 The edges that looked real did not survive

These were the best-looking rules in the 2026 sample. Re-tested on 2015 EURUSD, every one
**flipped sign**:

| Rule | TF | 2026 IS | 2026 OOS | 2015 IS | 2015 OOS |
|---|---|---|---|---|---|
| Fade when ER < 0.25 | M5 | +0.214 (p=0.007) | +0.192 (p=0.001) | **−0.312 (p=0.006)** | −0.062 |
| Trend when H > 0.52 | M15 | +0.384 | +1.790 (p=0.000) | **−1.416 (p=0.004)** | **−0.892 (p=0.034)** |
| Trend when H > 0.52 | M30 | +1.554 | +2.473 (p=0.009) | **−3.376 (p=0.000)** | −0.779 |

Two statistically significant, out-of-sample-confirmed results in one period became
significantly **negative** in another. This is the classic failure mode of fixed-horizon
directional testing, and exactly why the panel ships with a regime warning rather than a
performance claim.

### 4.3 What *is* robust

1. **The regime read.** DFA and the cheap variance-scaling estimator agree at **r = 0.63 / 0.74 /
   0.64** across M5/M15/M30. H centres on ~0.46–0.51 with p10–p90 spanning ~0.35–0.62, so the
   0.45/0.55 thresholds sit close to the 30th/70th percentiles of the real distribution rather
   than being invented. Knowing *when not to act* is the durable information here.
2. **Cost asymmetry across timeframes.** Median efficiency ratio rises with the timeframe
   (M5 0.186 → M15 0.192 → M30 0.206) and the share of bars with ER > 0.40 rises too
   (14% → 15% → 17%). Higher timeframes genuinely trend more, which is why M30 intraday has a
   better chance than M5 scalping.
3. **Short-horizon mean reversion is real** — 1-bar return autocorrelation is negative
   (M5 −0.0115, M15 −0.0300), consistent with bid–ask bounce. Not exploitable after costs, but
   it explains why trend signals underperform at very short horizons.

### 4.4 Things I discarded after testing

- **FRAMA-derived Hurst.** A cheap `H = 2 − D` from Ehlers' fractal dimension looked attractive
  (highs/lows only, no returns loop). Measured on real data it was **uncorrelated with DFA**
  (r = 0.01–0.07) with a standard deviation of 3.3–5.7 — it is not a usable regime estimate.
  Discarded rather than shipped.
- **The fade leg as a default.** It was the strongest rule in 2026 and inverted in 2015, so
  `InpFadeInRange` ships **off**. The default only ever *confirms* a trend in a persistent
  regime, or abstains. **Superseded by Part 2:** the input is gone — an anti-persistent market
  is no longer faded against; it is traded as a **box** (limit at the band, target at the
  midpoint) when every gate clears, and refused with a reason when they do not. The 2015
  inversion is exactly why the box trade should be validated in the journal (does price reach
  the midpoint before breaking the band?) before real money goes on it.

### 4.5 Reproducing

```bash
pip install numpy pandas
cd research
python verify_mql.py            # proves the MQL5 math == the validated reference engine
python verify_timeframe_gate.py # proves the M5/M15/M30-only chart rule, switch by switch
python walk_timeframes.py       # prints what the chart shows at each timeframe switch
python horizon_study.py         # measured signal horizon -> research/HORIZON.md
python verify_plan_math.py      # lot / points / money arithmetic, symbol by symbol
                                # (trend profiles AND range-fade box geometry)
python walk_trade_plan.py       # renders the panel (Group 1 + Group 2) for 10 states
                                # (its output is saved as research/panel_layout.txt)
python verify_autotrading.py    # verifies all autotrading rules and renders the 2nd panel
python run3.py           # IS/OOS + Monte-Carlo null, 2026 sample
python run2015.py        # same, independent 2015 era
```

`verify_mql.py` is a line-by-line transcription of the MQL5 functions back into Python; it
reproduces `HighPass3` exactly (0.0 error) and `EfficiencyRatio` / `Hurst` to floating-point
noise (2e-13 / 2e-18). The engine in the EA is the engine that was tested.

Data sources (free, not committed — the raw CSVs are ~17 MB):
`github.com/getdata-finance` (`eurusd-5m|15m|30m`, `gbpusd-5m`, `usdjpy-5m`, `xauusd-15m`) and
`github.com/vdtdg/EURUSD-market-data` (`EURUSD_2015.csv`).

---

## 5. How to proceed

**Phase 1 — done.** Panel with trend + momentum + regime, non-repainting, read-only.

> **Cancelled / out of scope:** popup and push alerts will not be added to this project. Do not
> implement or propose them; the remaining work below is the roadmap.

**Phase 2 — journal (do this before anything else).** Log every flip to CSV with the timestamp,
timeframe, direction, score, regime, entry price and the outcome after 1R. **The critical point:
every number in §4 came from a third-party data feed.** Your broker's spread, swap, session
hours and execution differ. Until you have your own journal showing a real edge *after spread on
your account and your symbol*, you do not have evidence — you have someone else's backtest.

> **Before risking money on the range fade**, journal its key claim: after entry at the band,
> does price reach the midpoint **before** breaking the band? The spread gate is already
> calculative (half-box ≥ 3 spreads, all gates visible in §3), but the claim itself is a market
> claim, and the 2015 fade inversion (§4.4) is the reason to measure it first. Extending the
> pre-validation harness with a band-touch → midpoint-hit sequence and journaling real fills are
> both recommended — neither blocks the code, which ships with `InpRangeMode = true`.

**Phase 3 — risk layer, still manual.** ATR-based SL/TP and position sizing so each trade risks a
fixed fraction of the account. Keep approve-by-hand.

**Phase 4 — automation, on higher timeframes.** Only after Phase 2 shows a genuine edge. Prefer
M30/H1+ where the efficiency ratio and cost-to-edge ratio are more favourable, and reconsider
M5 entirely unless you are on a raw-spread account where the cost can drop to ~0.1–0.3 pip.

**A realistic expectation to hold on to:** this panel is a structured, low-lag reading of the
market that is honest about when the market has no memory. It no longer sits back in chop —
when the box gates clear it trades the range with calculative numbers, and when they do not it
tells you *why* (`mixed — no edge either way`, `chop — nothing clears the spread`,
`dead market — nothing moves`) instead of a blank HOLD. That refusal, roughly 55–60% of
readings in my sampling, is still a feature — it just comes with receipts now.
