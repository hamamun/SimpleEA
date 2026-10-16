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
  **SELL**, Sideways = **HOLD**, with the score that produced it beside it.

The two are independent, so all nine pairings can appear — e.g. *Going up + Choppy* means
"rising overall, but messily."

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
   onto **any chart** (the chart's own timeframe does not matter — the panel always reads
   M5, M15 and M30).
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
| **> 0.55** | persistent — trends extend | the trend is real, **vote with it** |
| 0.45 – 0.55 | random walk — no memory | **abstain** (vote 0) |
| **< 0.45** | anti-persistent — moves revert | abstain by default; optional fade (`InpFadeInRange`) |

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
HOLD  otherwise
```

Kaufman's **Efficiency Ratio** is a dead-market gate: if ER is below `InpERDead` (default 0.10)
the instrument is not travelling anywhere, so the row is forced to `HOLD` regardless of score.

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
| | `InpERDead` | 0.10 | below this ⇒ dead market, force HOLD |
| | `InpFadeInRange` | **false** | when H < 0.45, vote *against* the trend |
| Per TF | `InpL1_*` / `InpL2_*` | 150 / 24 | Precision Trend filter periods |
| | `InpHurstTrend*` | 0.55 | persistent threshold |
| | `InpHurstRevert*` | 0.45 | anti-persistent threshold |

Raising `InpHurstTrend` makes the panel more selective (more HOLD, fewer calls). Raising
`InpBuyScore` to 3 requires all three components to agree.

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
  regime, or abstains.

### 4.5 Reproducing

```bash
pip install numpy pandas
cd research
python verify_mql.py     # proves the MQL5 math == the validated reference engine
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

**Phase 3 — risk layer, still manual.** ATR-based SL/TP and position sizing so each trade risks a
fixed fraction of the account. Keep approve-by-hand.

**Phase 4 — automation, on higher timeframes.** Only after Phase 2 shows a genuine edge. Prefer
M30/H1+ where the efficiency ratio and cost-to-edge ratio are more favourable, and reconsider
M5 entirely unless you are on a raw-spread account where the cost can drop to ~0.1–0.3 pip.

**A realistic expectation to hold on to:** this panel is a structured, low-lag reading of the
market that is honest about when the market has no memory. It is a decision aid, not a
money-printing machine. The most valuable thing it does is tell you when to **do nothing** —
in my sampling it reads HOLD roughly 55–60% of the time, and that is a feature.
