# How far ahead is a SimpleEA reading good for?

> **Historical research, not current-plan validation:** this study used an older signal/horizon model and different regime windows; it does not model the new structure/analog planner, staged trade lifecycle, broker fills or costs. Raw source data are not committed. Its numbers are not TP reach rates, performance evidence, or forecasts for the current EA. See [`../documents.md`](../documents.md) for the current implementation and validation requirements.

Short answer: **there is no fixed horizon, and the panel never claimed one.** A SimpleEA
reading is a *statement about the state of the market at the close of one bar*, and it stays
on the panel only as long as that state persists — a **median of 2–3 bars** (10–15 min on M5,
30–45 min on M15, 60–90 min on M30). Judged as a timed forecast of the next N bars, the
measurable edge only appears much further out (6–16 bars where it appears at all), which is
2–5× longer than the reading survives. Both facts are measured below on real bars.

The historical model was causal and approximated the then-studied signal arithmetic: trend vote, ROC vote, Hurst vote
(EA estimator, window 256, thresholds 0.55 / 0.45), score ±2 gates, ER dead-market gate at
0.10. Signals are evaluated on the **last closed bar** and the forward return is measured from
that same close — so "h = 1" means the move of the bar that opens right after the reading
appears.

Data: XAUUSD / EURUSD / GBPUSD / USDJPY, Mar–Sep 2026, third-party feed, plus **EURUSD 2015
and 2016** (independent era, different feed). Raw CSVs are not committed.

Reproduction requires the uncommitted source datasets and Python dependencies:

```bash
pip install numpy pandas
cd research
python horizon_study.py        # life, edge per horizon, MFE/MAE  -> results/horizon_*.csv
python first_passage.py        # target-vs-stop first passage      -> results/horizon_*.csv
```

---

## 1. From which bar does a reading apply?

The EA scores the **most recently closed bar** (MT5 series index 1 — the bar that just
finished) and paints the panel during the bar that is currently forming. So:

* the reading describes the bar that just closed, and
* it is actionable from the close of that bar onward — i.e. "h = 0" is that close; h = 1 is
  the next bar's move.

The historical model used closed bars; real terminal history corrections and different initialization/data pulls can change a reconstructed reading.

## 2. How long is a reading "valid"?

Measured as: from a fresh flip, how many bars until the panel changes direction again.

| Symbol | TF | fresh flips | median bars on screen | IQR | re-flip ≤3 bars | re-flip ≤10 bars | median life (time) |
|---|---|---|---|---|---|---|---|
| XAUUSD | M5 | 3883 | 3 | 1-5 | 62% | 97% | 15.0 min |
| XAUUSD | M15 | 1234 | 3 | 1-5 | 60% | 96% | 45.0 min |
| XAUUSD | M30 | 620 | 3 | 1-5 | 58% | 97% | 90.0 min |
| EURUSD | M5 | 4129 | 2 | 1-5 | 65% | 97% | 10.0 min |
| EURUSD | M15 | 1354 | 2 | 1-5 | 64% | 97% | 30.0 min |
| EURUSD | M30 | 679 | 2 | 1-5 | 62% | 97% | 60.0 min |

Read that as: half of all readings are gone within 2–3 bars; ~62% within 3 bars; **~97% within
10 bars**. The panel is not saying "price will move up for the next 20 bars" — it is saying
"this is the state right now", and states here are short-lived on every timeframe.

## 3. How far ahead does the direction actually pay?

Mean signed move per signal (pips, costs NOT deducted), by horizon in bars, fresh flips only:

| Symbol | TF | h=1 | h=2 | h=4 | h=8 | h=16 | h=24 |
|---|---|---|---|---|---|---|---|
| XAUUSD | M5 | +0.08 | -0.23 | +1.29 | +0.33 | +3.20 | +4.36 |
| XAUUSD | M15 | +0.50 | +0.87 | -0.30 | +0.84 | +1.40 | +3.46 |
| XAUUSD | M30 | +4.91 | +7.71 | +5.93 | +9.23 | +1.77 | +5.72 |
| EURUSD | M5 | -0.06 | -0.10 | -0.13 | -0.16 | -0.26 | -0.27 |
| EURUSD | M15 | -0.09 | +0.25 | +0.26 | +0.40 | +1.05 | +1.50 |
| EURUSD | M30 | +0.19 | +0.46 | +0.64 | +1.11 | +1.33 | +1.81 |

Hit rate for the same population (a coin flip is 0.500):

| Symbol | TF | h=1 | h=2 | h=4 | h=8 | h=16 |
|---|---|---|---|---|---|---|
| XAUUSD | M5 | 0.498 | 0.490 | 0.498 | 0.486 | 0.490 |
| XAUUSD | M15 | 0.521 | 0.509 | 0.488 | 0.494 | 0.485 |
| XAUUSD | M30 | 0.524 | 0.504 | 0.494 | 0.474 | 0.478 |
| EURUSD | M5 | 0.485 | 0.494 | 0.489 | 0.484 | 0.488 |
| EURUSD | M15 | 0.490 | 0.502 | 0.491 | 0.476 | 0.478 |
| EURUSD | M30 | 0.476 | 0.465 | 0.463 | 0.451 | 0.469 |

Notes on what is and is not significant. Two tests are run: a circular block bootstrap
(block = h, so overlapping forward windows are handled honestly) and a greedy non-overlapping
sample with a plain t-test. The results agree:

* **EURUSD M15, h = 14–22**: block CI above zero, mean **+0.9 to +1.4 pips**; the non-overlapping
  test also clears zero at h = 12–19 with means of +1.2 to +2.0 pips. This is the one cell that
  looks real.
* **XAUUSD M5 at h = 41** (non-overlapping test only): one horizon out of ~48 tested. That is
  what multiple comparisons look like, not an edge.
* **Everything else — every M5 dataset, all of XAUUSD, and both independent 2015/2016 eras —
  has intervals that include zero.**

Two cautions on the one positive cell. First, its hit rate is still **below 50%** (0.478 at
h = 16): the mean is positive because the wins are *bigger* than the losses, not because the
direction is right more often. Second, the identical rule on the independent 2015 and 2016
EURUSD data shows nothing, so even that single cell may be sample-specific. This matches §4 of
the README, which reached the same conclusion with a different harness.

## 4. The specific example: XAUUSD M5, "SELL, score 3/3"

* A 3/3 reading is **rarer** (617 fresh 3/3 flips vs 3883 for any signal on XAUUSD M5) and not a
  stronger or longer forecast:

| Symbol | TF | n (3/3) | 3/3 h=1 | 3/3 h=4 | 3/3 h=16 | n (any) | any h=1 | any h=4 | any h=16 |
|---|---|---|---|---|---|---|---|---|---|
| XAUUSD | M5 | 617 | -3.88 | -3.86 | -2.04 | 3883 | +0.08 | +1.29 | +3.20 |
| XAUUSD | M15 | 204 | +0.47 | -15.10 | -27.96 | 1234 | +0.50 | -0.30 | +1.40 |
| XAUUSD | M30 | 110 | +0.00 | +8.59 | +14.27 | 620 | +4.91 | +5.93 | +1.77 |
| EURUSD | M5 | 571 | -0.11 | -0.17 | +0.32 | 4129 | -0.06 | -0.13 | -0.26 |
| EURUSD | M15 | 209 | +0.34 | +0.94 | +2.77 | 1353 | -0.09 | +0.26 | +1.05 |
| EURUSD | M30 | 119 | -0.38 | +0.19 | -1.93 | 679 | +0.19 | +0.64 | +1.33 |

* The typical 3/3 reading flips back within **2 bars (10 min)** on M5. Meanwhile the *mean*
  16-bar move after a 3/3 SELL on XAUUSD M5 was **−2.0 pips**, and at h = 3 it was −4.1 pips —
  i.e. on this sample the highest-conviction-looking reading was, if anything, worse at short
  horizons than the average signal. Treat score magnitude as *how many components agreed*, not
  as *how far the move will run*.
* Net movement while the reading is on screen (median, close-to-close): **+0.70 pips** on
  XAUUSD M5, **0.00 pips** on EURUSD M5. Spread for reference: 1.8 / 0.8 pips. On M5 the
  typical reading does not even cover the spread before it flips.

## 5. Why big intrabar numbers can mislead on M5

Per fresh flip, over that reading's own lifetime:

| Symbol | TF | flips | life (bars) | net best point (closes) | net at flip | intrabar MFE | intrabar MAE | intrabar MFE > spread | spread |
|---|---|---|---|---|---|---|---|---|---|
| XAUUSD | M5 | 3883 | 3 | +0.70 | +0.00 | 22.9 | 16.2 | 67% | 1.8 |
| XAUUSD | M15 | 1234 | 3 | +4.55 | +0.00 | 46.3 | 32.9 | 70% | 1.8 |
| XAUUSD | M30 | 620 | 3 | +8.35 | +0.00 | 70.2 | 51.6 | 72% | 1.8 |
| EURUSD | M5 | 4129 | 2 | +0.00 | +0.00 | 1.0 | 0.8 | 53% | 0.8 |
| EURUSD | M15 | 1354 | 2 | +0.00 | +0.00 | 1.9 | 1.4 | 59% | 0.8 |
| EURUSD | M30 | 679 | 2 | +0.20 | +0.00 | 3.5 | 2.5 | 65% | 0.8 |

The intrabar excursion on XAUUSD M5 (median +22.9 pips, −16.2 pips against) is enormous next to
a median net move of **+0.70 pips** — the bars wick far, but close almost where they started.
That is the M5 problem in one line: the path moves, the *net* does not. On M15/M30 the net MFE
does exceed the spread for most readings (70–72% and 65% respectively), which is why the higher
timeframes behave better.

## 6. If you need N pips, does price get there before the stop?

Target = stop = T pips from the close of the flip bar, checked on bar highs/lows. Because a
single wide bar often contains *both* levels, the honest answer is a bracket: every ambiguous
bar counted as a loss (worst case) or as a win (best case).

| Symbol | TF | target = stop (pips) | flips | win% (worst case) | win% (best case) | bars with both levels touched |
|---|---|---|---|---|---|---|
| XAUUSD | M5 | 1.8 | 3883 | 6% | 93% | 87% |
| XAUUSD | M5 | 3.6 | 3883 | 11% | 89% | 78% |
| XAUUSD | M5 | 7.2 | 3883 | 21% | 79% | 58% |
| XAUUSD | M15 | 1.8 | 1234 | 5% | 97% | 92% |
| XAUUSD | M15 | 3.6 | 1234 | 7% | 94% | 87% |
| XAUUSD | M15 | 7.2 | 1234 | 12% | 88% | 76% |
| XAUUSD | M30 | 1.8 | 620 | 3% | 98% | 95% |
| XAUUSD | M30 | 3.6 | 620 | 5% | 96% | 91% |
| XAUUSD | M30 | 7.2 | 620 | 9% | 92% | 83% |
| EURUSD | M5 | 0.8 | 4129 | 36% | 62% | 25% |
| EURUSD | M5 | 1.6 | 4129 | 45% | 52% | 7% |
| EURUSD | M5 | 3.2 | 4120 | 48% | 49% | 1% |
| EURUSD | M15 | 0.8 | 1353 | 24% | 73% | 49% |
| EURUSD | M15 | 1.6 | 1353 | 38% | 59% | 21% |
| EURUSD | M15 | 3.2 | 1353 | 46% | 51% | 4% |
| EURUSD | M30 | 0.8 | 679 | 17% | 82% | 65% |
| EURUSD | M30 | 1.6 | 679 | 30% | 73% | 43% |
| EURUSD | M30 | 3.2 | 679 | 42% | 57% | 15% |

The bracket is that wide on M5/M15 precisely because intrabar noise dominates the target: for
XAUUSD M5 with a 1.8-pip target, **87% of bars touched both levels**. Without tick data you
cannot resolve that from OHLC bars, and pretending to would be a lie — so both bounds are
reported. It also means a 1–2 pip target on gold M5/M15 is not a strategy, it is a coin flip on
intrabar sequencing.

## 7. Practical horizon, per timeframe

Where the mean move first exceeds a retail-typical spread, versus where the edge peaks:

| Symbol | TF | spread (pips) | first h with mean > spread | peak horizon | peak mean pips |
|---|---|---|---|---|---|
| XAUUSD | M5 | 1.8 | 10 | 45 bars (225 min) | +9.20 |
| XAUUSD | M15 | 1.8 | 7 | 31 bars (465 min) | +4.89 |
| XAUUSD | M30 | 1.8 | 1 | 6 bars (180 min) | +13.94 |
| EURUSD | M5 | 0.8 | never in 24-48 bars | 47 bars (235 min) | +0.07 |
| EURUSD | M15 | 0.8 | 14 | 24 bars (360 min) | +1.50 |
| EURUSD | M30 | 0.8 | 6 | 20 bars (600 min) | +2.34 |

(The "peak horizon" column is the maximum of a noisy mean curve over 24–48 horizons — read it
as the region where the average trade is largest, not as a forecast target. The "first h" column
is the more useful number.)

* **M5** — reading life ~2 bars (10 min). Mean move never beats the spread on EURUSD in 24–48
  bars; on XAUUSD M5 it needs ~10 bars (50 min), five times the reading's life. **Net: nothing
  tradeable here. M5 is a watch-only timeframe.**
* **M15** — reading life ~3 bars (45 min). XAUUSD M15 reaches the spread at h ≈ 7 (105 min),
  EURUSD M15 at h ≈ 14 (3.5 h). The horizon where the edge exists is 2–5× the life of the
  reading, so acting on the flip alone does not capture it; you would be holding against the
  panel's own subsequent flips.
* **M30** — reading life ~3 bars (90 min) but the largest moves: XAUUSD M30 mean exceeds the
  spread from h = 1, peak ~14 pips at h = 6 (3 h); EURUSD M30 from h = 6 (3 h). **This is the
  only timeframe where the reading's life and the paying horizon overlap at all**, matching what
  §4 of the README and Phase 4 of the roadmap already said.

## 8. So, technically…

* **Entry point:** the close of the last closed bar — the bar the reading is computed on.
* **How many bars ahead is it valid:** median 2–3 bars (M5 ~10 min, M15 ~45 min, M30 ~90 min);
  97% gone within 10 bars.
* **How far ahead does it pay:** measurably, only at 6–16+ bars, and only on M15 (weakly,
  EURUSD) and M30 (XAUUSD, EURUSD) — i.e. **the paying horizon is longer than the reading's
  life**, which is exactly why the roadmap says journal first, trade M30/H1+, and leave M5
  alone.
* **What it is good at:** telling you the current state and when *not* to act. Across all 13
  datasets only ~37% of bars carry any signal at all; the panel is silent or HOLD the rest of
  the time, and that silence is the feature.
