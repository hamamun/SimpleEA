# v1 Signal Logic — Research Briefing

**The question:** which signal logic should v1 use? *Trend, momentum, RSI, EMA are all conventional —
find the latest cutting-edge items now available.*

**The answer:** a three-layer engine where each layer is a different *class* of method, none of
which is RSI, MACD or an EMA crossover:

| Layer | Method | Year published | Replaces |
|---|---|---|---|
| **Direction** | Ehlers **Precision Trend Analysis** — difference of two highpass filters (bandpass) | **TASC, Sept 2024** | EMA / SMA cross |
| **Timing** | **ROC of the Precision Trend line** | TASC, Sept 2024 | RSI / MACD / Stochastic |
| **Regime** | **Hurst exponent** (long-memory) as a regime switch | 2024–2026 literature | ADX / ATR filters |
| **Gate** | **Kaufman Efficiency Ratio** | 1995, revived 2025–26 | volume filters |

This is what `SimpleAdvisor.mq5` v1 ships. §5 explains why, and §6 covers the frontier that
comes *after* v1.

---

## 1. Why RSI / MACD / EMA are the wrong building blocks

Not because they are old — because of **what kind of filter they are.**

A moving average is a **lowpass filter**: it passes slow components of price and removes fast
ones. To reject noise it must retain long cycles, and *that retention is exactly what produces
lag.* Lag is not a tuning problem you can optimise away; it is the maths of the filter. RSI and
MACD are both built on this same smoothing, so they inherit it.

The RSI family is also **bounded and non-directional in the way people use it** ("overbought").
In a trending market RSI sits above 70 for weeks — a well-known failure that regime layers exist
to patch.

So the modern approach inverts the design: instead of *smoothing price*, isolate the **frequency
band** that corresponds to the timeframe you are trading, and let everything else cancel.

---

## 2. Layer 1 — Direction: Ehlers Precision Trend (TASC, September 2024)

**The newest published method in this space.** Ehlers' article "Precision Trend Analysis"
appeared in *Technical Analysis of Stocks & Commodities*, September 2024, and was the focus of
that month's Traders' Tips (implementations for TradeStation, Wealth-Lab, RealTest, TradingView,
Zorro, NeuroShell, Excel).

**The idea:** rather than one lowpass filter (laggy), **subtract two highpass filters** with
different critical periods. Highpass filters have almost **zero lag** — they reject *low*
frequencies, which do not need long lookbacks to detect. Their difference is a **bandpass**
covering the cycle band between the two periods:

```
Trend = HighPass3(price, L1) - HighPass3(price, L2)      # L1 = 150, L2 = 24
```

Everything slower than `L1` and faster than `L2` is attenuated and cancels. What survives is the
tradeable middle band. The result turns close to the same time price does, with no noticeable lag
on the reference charts.

Ehlers also shows the trend line's **ROC crosses zero exactly at its own peaks and troughs**,
which is what makes it usable for timing.

**Implementation trap worth knowing.** TradeStation's `Cosine()` takes **degrees**, so Ehlers'
listing is `b1 = 2*a1*Cosine(1.414*180/Period)`. That equals `1.414*π/Period` **radians** already.
Several popular public ports convert it a second time — putting the filter on the wrong
frequency. The v1 code uses Ehlers' own listing and documents this at the function.

**Vote: `sign(Trend)`.**

---

## 3. Layer 2 — Timing: ROC of the trend line

The rate of change of the Precision Trend is zero at every peak and trough *of that line*.
Its sign therefore marks the **onset or continuation of a push**, not its level — which is what
you actually want for entry timing, and what RSI's overbought/oversold framing gets wrong.

**Vote: `sign(ROC)`.**

---

## 4. Layer 3 — Regime: the Hurst exponent (this is the genuinely new part)

**Why a regime layer at all:** every direction signal has regimes where it works and regimes
where it is a coin flip. Measured on real data, *direction alone on liquid FX is ~50/50*
(see `README.md` §4). So the marginal value of a directional indicator is small, while the value
of knowing **when not to act** is large.

**Hurst exponent** measures long-range memory — whether moves tend to continue or revert:

| H | Market character | Action |
|---|---|---|
| **H > 0.55** | persistent, trends extend | back the trend |
| 0.45 – 0.55 | random walk, no memory | **abstain** |
| **H < 0.45** | anti-persistent, moves revert | fade (off by default; see §5) |

> **Part 2 changed the Action column** (the H reads did not change): **Steady** plays the
> trend game, **Choppy** plays the **range game** — the box trade (limit at the opposite band,
> target = half the box, stop = band + 1 ATR, all gates must pass) — and **Mixed** stands aside
> with `mixed — no edge either way` on the plan line. The fade row above is historical; see §6.

**Evidence base:** a 2025 study across five major East Asian indices found strategy performance is
*strongly conditional on the Hurst regime* — trend-following thrived in high-persistence periods
and failed in anti-persistent ones. It also found **DFA a more robust estimator than R/S**
(4.35% vs 2.69% in the high-Hurst regime), because DFA is designed to ignore long-term trends that
distort R/S. Practical regime frameworks use ~H 0.55 / 0.45 boundaries; US crude oil work
(2025/26) used the Hurst exponent as the core feature for classifying volatility regimes, reaching
88–89% accuracy with LightGBM.

**Why not ADX.** ADX is a smoothed directional-movement average — it is *another lowpass filter*,
and it tells you trend strength without telling you whether the series has memory. Hurst is a
statement about the data-generating process, not about recent price displacement.

**Estimator used in v1:** variance-scaling (2-N point). Log returns are aggregated into
non-overlapping blocks; for a self-similar series block dispersion grows as `s^H`, so the slope of
`log(std)` on `log(s)` is H directly. Cross-checked against DFA on real EURUSD M5/M15/M30 data at a
256-bar window: **r = 0.63 / 0.74 / 0.64.** It is accurate enough for a regime label and a fraction
of the CPU inside the terminal.

---

## 5. The gate: Kaufman Efficiency Ratio

```
ER = |close[i] - close[i-n]| / SUM |close[k] - close[k-1]|
```

Net distance travelled divided by total path walked. `1.0` = straight line, `0.0` = pure noise.
Used as a **dead-market gate**: below `InpERDead` (0.10) the row is forced to HOLD no matter what
the score says.

ER has become the standard regime input in the current MQL5 generation — it appears as the
adaptive driver in the *Adaptive Kalman Trend Filter with Regime Bands* (2026), as a component of
the *Trend Regime Inspector* score (`direction × 100 × efficiency × min(1, ADX/50)`), and as the
band-width controller in the *Self-Aware Trend System* SuperTrend.

**Note on ER thresholds:** measured medians on real data are only **M5 0.186 / M15 0.192 /
M30 0.206**. Many published indicators default ER filters to 0.30–0.40, which on liquid FX
discards ~70% of bars. v1 defaults to a *dead-market* gate (0.10), not an *elite-trend* gate.

---

## 6. The score

```
score = sign(Trend) + sign(Trend ROC) + regime_vote        # -3 .. +3
BUY  if score >= +2        SELL if score <= -2        else HOLD
```

Closed bars only → non-repainting.

**Deliberate design choice:** `InpFadeInRange` ships **off**. Fading an anti-persistent regime was
the single best-looking rule in the 2026 sample (+0.21/+0.19 pips, p<0.01) and **inverted to
−0.31/−0.06** on 2015 data. It is exposed as an input, not enabled as a default. The default
engine only ever *confirms* a trend in a persistent regime, or **abstains**.

**Superseded by Part 2** (the v1 paragraph above stays for the record): the `InpFadeInRange`
input has been **removed**. An anti-persistent row is never faded against anymore — it plays the
**range game** (the box trade: entry at the opposite band, target = the midpoint, stop =
band + `RANGE_SL_ATR` ATR, with the half-box ≥ `RANGE_SPREAD_X` spreads / box ≥
`RANGE_MIN_ATR` ATR / ER < `RANGE_ER_MAX` / bid-inside-box gates all-must-pass), or it stands
aside and says why (`chop — nothing clears the spread`, etc.). The 2015 inversion above is
exactly why the box trade should be journalled and pre-validated (band touch → midpoint hit
before band break) before real money goes on it.

---

## 7. What comes after v1 — the actual frontier

Ranked by how much they add versus what they cost to build. All are real, shipped facilities in
MT5 today.

### Tier A — native, no external toolchain

| Method | Source | What it adds |
|---|---|---|
| **Shannon-entropy regime classifier** | MQL5 article *Developing Market Entropy Indicator* (2026) | Discretises bars into up/down/flat and maps normalised entropy to **TREND / TRANSITION / CHAOTIC** with fixed thresholds (<0.35 / 0.35–0.65 / >0.65). A second, independent opinion on regime — and it also detects "information shocks" (25%+ entropy spikes). |
| **Adaptive Kalman trend filter** | MQL5 CodeBase 76149 (2026) | Single-state Kalman whose process noise `Q` is rescaled every bar by ER — tight in trends, smooth in chop. Strictly better trend estimate than any fixed-parameter MA. |
| **MESA / MAMA-FAMA** | Ehlers, Hilbert-transform dominant-cycle family | Auto-detects the **dominant cycle period** instead of using fixed ones. Directly addresses the weakest part of v1: `L1`/`L2` are still hand-set constants. |

### Tier B — needs a Python pipeline

| Method | Source | What it adds |
|---|---|---|
| **Hidden Semi-Markov Model regime detection** | MQL5 article *Hidden Semi-Markov Models for Duration-Aware Regime Detection in MQL5* (2026) | Adds **duration awareness** — a plain HMM assumes constant regime-switching probability, which is wrong; regimes have characteristic lifetimes. Ships `train_hsmm.py` (EM: forward–backward + negative-binomial duration) exporting a JSON manifest the EA reads. Features include realised-vol deviation, ER, and return skew. |
| **ONNX models inside MQL5** | MT5 **build 3980** added MQL5 ONNX support; **build 5572** added ONNX improvements and **CUDA GPU** acceleration; resource limit raised to 1 GB | Train an LSTM / gradient-boosted model in Python (PyTorch, sklearn, LightGBM), export to `.onnx`, and run it **natively in the EA** via `OnnxCreate` / `OnnxRun`. This is the real roof of MT5 AI trading. The proven architecture is **not** "model predicts price" but **"model scores the quality of a signal the rules already generated"** — e.g. MACD fires, the model receives a feature vector and returns the probability the setup is good. |
| **Python research loop** | `MetaTrader5` Python package | Pull your own broker's history, build features, train, backtest, export. |

### Tier C — process, not indicator

The HSMM article's own warning applies to everything above: *too short a window reacts faster to a
genuine regime break but produces noisier estimates, which widens the emission distributions and
makes every state look alike to the filter.* Same trade-off, everywhere.

---

## 8. Recommendation

**v1 = Layers 1–3 + ER gate. Ship it, run it, journal it.**

The reason to stop there is not that the Tier-A methods are hard — they are not. It is that
`README.md` §4 shows **every direction rule I tested inverted out of sample.** Adding a fourth and
fifth indicator to a 50/50 signal does not make it 60/40; it makes it overfitted. The next thing
that genuinely raises the odds is not another filter — it is **your own broker's data**, which is
the only dataset where your spread, swap, sessions and execution are the real ones.

**Sequence:**

1. **v1 now** — run it on your symbol, watch it, no money.
2. **Journal every flip** with timestamp, timeframe, direction, score, regime, entry, outcome after
   1R. This is the single highest-value next step.
3. **When the journal has enough trades to show a genuine edge after spread**, add Tier A: first the
   entropy classifier (independent regime confirmation), then MESA adaptive cycles (removes the
   hand-set `L1`/`L2`).
4. **Only then Tier B** — train an ONNX model *as a signal-quality filter* on your own journal, not
   as a price predictor.
5. **M5 last, or never.** The measured edge there (~0.2–0.5 pip) is below a retail spread
   (~0.8–1.0 pip). That is a cost wall, not a signal problem. M30/H1+ has the better economics.

---

## Sources

- **John F. Ehlers**, "Precision Trend Analysis", *TASC* September 2024 — plus the September 2024
  Traders' Tips page, which carries Ehlers' own TradeStation, Wealth-Lab, RealTest and Zorro
  listings. (Primary source used for the code.)
- **Noppakaew, Prinyasart, Chaiya & Chaiya**, "Hurst Exponent as a Regime-Switching Indicator for
  Trend-Following Strategies in East Asian Stock Markets", *Asia Pacific Journal of Mathematics*
  12:109, 2025.
- **MQL5 CodeBase 76149**, "Adaptive Kalman Trend Filter with Regime Bands", 2026.
- **MQL5 CodeBase 75868**, "Trend Regime Inspector for MetaTrader 5", 2026.
- **MQL5 CodeBase 72247**, "Self-Aware Trend System", 2026.
- **MQL5 Article 21743**, "Developing Market Entropy Indicator: Trading System Based on Information
  Theory", 2026.
- **MQL5 Article 24460**, "Hidden Semi-Markov Models for Duration-Aware Regime Detection in MQL5",
  2026.
- **MQL5 Article 22718**, "AI Trading Platform: Why MetaTrader 5 Is the Best Choice for Algorithmic
  Trading with Python, ONNX, and AI Assistant", 2026.
- **MetaTrader 5 release notes** — build 3980 (MQL5 ONNX support) and the ONNX/CUDA updates that
  followed.
- **Perry J. Kaufman**, *Smarter Trading* (1995) — origin of the Efficiency Ratio.
