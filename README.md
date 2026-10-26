# SimpleEA 2.0

**SimpleEA 2.0** (`SimpleAdvisor.mq5`) is a single-file, zero-dependency, strictly **non-repainting** multi-timeframe Expert Advisor for **MetaTrader 5 (MT5)** calibrated for **M5 (Scalp)**, **M15 (Short-term)**, and **M30 (Intraday)** on any liquid symbol (FX, Gold, Indices, Crypto).

Every indicator reading is computed exclusively on **closed bars**. Depending on `InpAutoTrading`, SimpleEA 2.0 runs either as a **hands-free multi-timeframe autotrader** (`true`, default) or as a **read-only direction & trade-plan dashboard** (`false` — zero trade calls).

---

## Key Highlights

- **3-Vote Non-Repainting Signal Engine (Per Timeframe: M5, M15, M30)**
  1. **Direction (`Vote 1`)** — John Ehlers' *Precision Trend* bandpass filter (`HP3(L1) - HP3(L2)`), driven by self-adaptive zero-crossing cycle wavelength detection ($L_2 \in [14, 36]$, $L_1 = \operatorname{round}(6.25 \times L_2) \in [90, 225]$).
  2. **Timing (`Vote 2`)** — Rate of change of the Precision Trend line with a $0.02 \times \text{ATR}_{14}$ noise dead-band to filter micro-flicker.
  3. **Structure (`Vote 3`)** — Independent 20-bar net displacement ($> 0.25 \times \text{ATR}_{14}$) validated against Dow Theory swing highs/lows.
  - **Noise & Liquidity Guards**: Kaufman Efficiency Ratio dead-market filter ($\text{ER}_{20} < 0.10 \rightarrow \text{HOLD}$) and 20-bar tick-volume confirmation (steps `3/3` market entries down to limit orders if volume drops below $50\%$ of average).
  - **Statistical Regime (`Hurst Exponent`, 256 bars)**: Classifies each timeframe as **Steady** ($H > 0.55$), **Mixed** ($0.45 \le H \le 0.55$), or **Choppy** ($H < 0.45$).

- **Clear Score-to-Order Execution**
  - **`+3/3` or `-3/3`** $\rightarrow$ **Market Order** immediately at Ask/Bid ($2\times$ base risk in risk mode).
  - **`+2/3` or `-2/3`** $\rightarrow$ **Pending Limit Order**: $0.5 \times \text{ATR}$ pullback in Steady/Mixed, or **20-bar Box Band Fade** in Choppy when `InpRangeMode = true` and box gates pass (automatic fallback to $0.5 \times \text{ATR}$ pullback otherwise). Automatically upgrades to Market if score strengthens to `3/3`.
  - **`-1/3`, `0/3`, `+1/3`** $\rightarrow$ **`HOLD`** with the exact refusal reason printed on the panel.
  - **Separate Choppy Permission (`InpAllowChoppyTrade`)**: Cleanly separates *whether* new orders are allowed in Choppy markets (`InpAllowChoppyTrade`) from *how* `2/3` limits are priced (`InpRangeMode`).

- **Universal 3-Step Profit-Protection SL Ladder & Multi-Stage Scaling**
  - Targets are frozen at fill from the timeframe's advised `TP3` ($0.9\times$ ATR on M5, $1.8\times$ ATR on M15, $3.0\times$ ATR on M30): **`TP2` = 75% of `TP3`**, **`TP1` = 75% of `TP2` (56.25% of `TP3`)**.
  - **Automatic Profit-Protection SL Floor (active whether `Trailstop` is ON or OFF)**:
    | Progress Reached | Automatic Broker SL Floor | Volume / Action |
    |---|---|---|
    | **`50%` of `TP1`** | **`+25%` of `TP1`** ahead of Entry | Keeps `100%` lot |
    | **`100%` of `TP1` (`TP1` Hit)** | **`+50%` of `TP1`** ahead of Entry *(or tighter trailed SL)* | Closes **`70%`** lot; arms Score Watcher |
    | **`TP2` (`75%` of `TP3`)** | **`TP1` price (`100%` of `TP1`)** *(or tighter trailed SL)* | Trims remaining lot to `minLot` |
    | **`TP3` (`100%` of `TP3`)** | — | Closes **`100%`** in full |
  - **Optional Stepped & Swing Trailing (`InpUseTrailStop = true`)**: Pre-`TP1` stepped trailstop (`40%` Tight in Mixed/Choppy, `55%` Steady in Steady trends, $+5\%$ steps with $\times 1.25$ M15 / $\times 1.50$ M30 breathing room) plus Post-`TP1` 2-bar swing-high/low runner trailing ($\pm 0.10 \times \text{ATR}$). Stops only ever tighten — never widen.

- **Three DPI-Aware On-Chart Panels + Calibration-Health Diary**
  1. **Main Panel (`SimpleEA2.0`)**: Live status, PC-local timer/pause countdown, daily `S/W/L` counts, M5/M15/M30 readings, per-lane health badges, and complete Trade Plans (`Entry`, `Lot`, `Stop`, `Target`, `Reach`, `Risk`, `Reward`, `Valid`/`Hold`).
  2. **Autotrading Panel (2nd Panel)**: Opens automatically when orders exist (`Right` or `Bottom`), showing live `TP1/TP2/TP3`, profit-colored `SL`, floating `P/L` or `Waiting` distance, real-time `Distance` to next TP, and active trail mode (`40% Tight` / `55% Steady`). Closes completely (`0` objects) when flat.
  3. **History Panel (3rd Panel, `InpShowHealth`)**: Persistent per-symbol CSV diary tracking `S / W / L / BE / Open / Wait / Exp`, net `R`, `2/3` vs `3/3` split, `Last 30` follow-through/cost/score/style health, and trail performance. Warns early on strategy decay without ever silently mutating your settings.

---

## Quick Start

1. Copy **`SimpleAdvisor.mq5`** into your MetaTrader 5 `MQL5/Experts/` folder.
2. Open **MetaEditor** and compile `SimpleAdvisor.mq5` (`F7` — zero external `.mqh` or DLL dependencies).
3. Attach to an **M5**, **M15**, or **M30** chart on any symbol and enable **Algo Trading** in MT5 if running with `InpAutoTrading = true`.
   *(On unsupported timeframes such as M1, H1, or D1, SimpleEA 2.0 intentionally collapses to `SimpleEA2.0 | Incompatible chart. Switch to M5/M15/M30.` and performs zero background calculations.)*

---

## Core Inputs Overview

| Input | Default | Purpose |
|---|---|---|
| `InpAutoTrading` | `true` | `true` = hands-free execution; `false` = read-only dashboard & trade plan |
| `InpUseAutoSchedule` / `InpAutoStartTime` / `InpAutoEndTime` | `false` / `"08:00"` / `"17:00"` | Optional PC-local daily placement window (cancels pendings when paused; keeps managing open trades) |
| `InpAutoOffHours` | `0` | One-shot placement pause in hours (`48` = 2 days; `0` = off/re-arm), persisted across restarts |
| `InpRequireM15M30SameTrend` | `false` | Require M15 and M30 trade directions to match before placing on M15/M30 |
| `InpImmediateFlipClose` | `false` | `false` = close on signal flip / box-break only when in profit; `true` = close immediately at any P&L |
| `InpUseStopLoss` | `false` | `false` = open with `SL = 0.0` (trailstop / `+25%` floor places first SL); `true` = attach hard ATR SL at fill |
| `InpUseTrailStop` / `InpTrailPctTight` / `InpTrailPctSteady` | `true` / `40` / `55` | Pre-`TP1` stepped trailstop & Post-`TP1` 2-bar swing trail |
| `InpBuyScore` / `InpSellScore` | `2` / `-2` | Minimum score gates on `[-3 .. +3]` |
| `InpAllowChoppyTrade` / `InpRangeMode` | `true` / `true` | Choppy new-entry permission vs 20-bar box-band limit pricing |
| `InpUseRisk` / `InpRiskPct` / `InpUseMinLot` | `true` / `0.5` / `false` | Position sizing (`0.5%` at `2/3`, `1.0%` at `3/3`; or fixed balance ladder; or minimum lot) |
| `InpAutoPanelPos` / `InpShowHealth` | `Bottom` / `false` | 2nd panel placement (`Right` / `Bottom`) and optional 3rd `History` panel toggle |

---

## Documentation & Verification

- **Full Specification**: See **[`documents.md`](documents.md)** for the complete mathematical, execution, lifecycle, panel, timer, and calibration-health diary specification.
- **Verification Suite** (pure Python 3 standard library):
  ```bash
  python3 research/verify_autotrading.py
  python3 research/verify_plan_math.py
  python3 research/verify_timeframe_gate.py
  python3 -m unittest discover -s tests
  ```

---

## Honest Note on Expectation

SimpleEA 2.0 provides a disciplined, low-lag reading of trend, momentum, market structure, and statistical regime paired with structured trade execution and profit protection. It is **not** a magic money machine: on short timeframes such as M5, retail spreads and execution costs can exceed raw directional edge during noisy hours. Use the regime readout (`Choppy`), the daily timer, the Cost/Health diagnostics, and demo/small-risk validation on your specific broker feed before scaling live risk.
