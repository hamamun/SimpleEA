# SimpleEA Compared with Predict_X, Emtt and Autotrader

**Date:** 25 October 2026
**Type:** Study only — no code was changed for this document.
**Scope:** Static review of the public repositories `hamamun/Predict_X`, `hamamun/Emtt`, `hamamun/Autotrader` and `hamamun/SimpleEA`.

> A repository named **AutoExpert** or **Mt5-expert-adviser** was not present on the GitHub account when this study was made. It may be an earlier name for one of the surviving projects. The comparison therefore covers the three earlier EAs that can still be inspected.

---

## 1. One-line verdict

**SimpleEA is not the most feature-rich EA in the family; it is the most disciplined one.**

Predict_X, Emtt and Autotrader each try to become better by adding more measurements, more context, more adaptation or more learning. SimpleEA takes the opposite path: three votes, two guards, one regime label, a visible reason for every action or refusal, and no external dependencies. Its innovation is mainly architectural — separating *whether* to trade from *how* to enter — rather than the invention of a new indicator.

That makes SimpleEA, in this reviewer's judgement, the easiest of the four to install, understand, audit and keep behaviourally stable. It is not automatically the most profitable. None of the four projects, by source inspection alone, proves live profitability.

---

## 2. The family in plain language

| EA | Plain-language character | Main idea |
|---|---|---|
| **Predict_X** | The student with six teachers and a diary | Six scoring layers — smart-money structure, trend, value, higher timeframe, Markov probability and a neural layer — plus the Aladin database that remembers similar past situations and their outcomes. |
| **Emtt** | The self-tuning laboratory | Symbol-class and volatility-bucket parameter matrix, K-Means-adaptive Supertrend, market structure, volume flow, higher-timeframe context, a bounded logistic learning filter and a small, guarded confidence-threshold optimiser. |
| **Autotrader** | The modern clinic with many scanners and a strict guard | A broad, modern evidence stack — kernel regression, Ehlers filters, Kalman trend, smart-money and volume-flow evidence — scored separately for BUY and SELL, with the family's strongest account-safety layer. |
| **SimpleEA** | Three judges and a weather check | Precision Trend direction, Precision Trend ROC timing and 20-bar Dow structure vote independently. Hurst describes the weather (Steady/Mixed/Choppy) but does not grant or deny permission. Kaufman ER blocks a dead market. |

### Shared family DNA

All four projects show the same design lineage:

- MT5/MQL5 expert advisors aimed mainly at M5, M15 and M30;
- a plain-words on-chart panel;
- analysis based primarily on closed bars;
- ATR-based distances;
- staged exits around TP1/TP2/TP3;
- break-even and/or trailing protection after favourable progress;
- an optional initial broker stop-loss that is off by default;
- a preference for self-contained operation over asking the user to optimise dozens of strategy constants.

---

## 3. Functional comparison

| Question | Predict_X | Emtt | Autotrader | SimpleEA |
|---|---|---|---|---|
| How is direction decided? | Six layers produce a score; online AI and Aladin memory can modify the decision. | Four views are blended into a confidence number; learning may adjust it by at most 15% without changing its side. | Eight evidence groups are scored two-sidedly: BUY evidence and SELL evidence are evaluated separately. | Three independent votes produce a score from −3 to +3. |
| What does strength control? | Trade qualification, sizing and some memory-based actions. | Whether the confidence clears the applicable bar; later the bar itself can move one approved step. | Qualification, trade plan and adaptive trailing behaviour. | Very explicitly: 3/3 = market now; 2/3 = wait for a better price; below gate = no trade. At 3/3, risk is doubled. |
| Can M5, M15 and M30 trade independently from one EA instance? | No: primarily one chart lane with higher-timeframe context. | No: one principal lane; a mapped higher timeframe supplies context. | No: M30→M15→M5 hierarchy; the chart timeframe selects the lane and lower lanes may not fight M30. | **Yes.** M5, M15 and M30 are three independent traders, each with its own magic number and at most one active trade/order. M15/M30 can optionally be tied together. |
| What is the regime used for? | One part of the overall context and scoring. | A central mood/gate that influences thresholds and parameters. | A gate and weighting mechanism; volatile/quiet/transition/range-middle can stand aside. | **Entry style, plus one explicit operator permission for Choppy rows.** The score publishes direction/order type; `InpAllowChoppyTrade=false` vetoes a new Choppy entry, while an allowed Choppy 2/3 uses the box band or the half-ATR pullback according to Range Mode/box usability. |
| Does it learn from outcomes? | Yes: online model plus rehearsal/live memory bank and k-NN lookups. | Yes, but bounded: logistic filter after 30 labelled plans; threshold optimiser after enough samples and only among 60/70/75. | Mostly no outcome learning. It self-configures from current symbol behaviour and keeps an audit/scoreboard. | **No outcome learning.** As of v2.22 it does keep a per-symbol outcome diary and health monitor, but results only warn and suggest what to test; they never rewrite the strategy. |
| Symbol adaptation | Presets plus memory separated by symbol/timeframe. | Strongest parameter adaptation: asset class × volatility bucket matrix, timeframe-scaled lookbacks, per-symbol learning files. | Symbol Intelligence derives dials from asset class, current-vs-baseline ATR, ATR percentage and sampled spread. | One standard engine for every symbol; distances are ATR-relative and the trend cycle is measured live. |
| External pieces needed | Include files plus custom SuperTrend, Keltner and TTM Squeeze indicators; Aladin uses a database. | Include files plus learning/parameter files. | Include files; no custom indicator dependency found in the reviewed source. | **One `.mq5` file.** No include files, custom indicators, DLL, database or web service. |
| Safety philosophy | Optional daily loss, sessions, alerts and trade protection. | Margin check option, detailed lifecycle and journal rules. | News freeze, gap-shock freeze, daily-loss stand-down, equity high-water protection, quote/spread checks. | Supervised, price-state philosophy: visible panel, score/regime gates, trading timer/pause, market-closed detection and manual tightening controls. See the owner's notes below. |

---

## 4. How "latest" are the items?

Almost every trading tool is older mathematics in a newer package. The relevant question is therefore not simply *what year was it invented?* but *how is it assembled, bounded and used?*

### SimpleEA

- **Ehlers Precision Trend — September 2024.** This is the newest individually dated signal component found in the four projects.
- **Adaptive dominant-cycle measurement.** Ehlers-style cycle adaptation is an older digital-signal-processing tradition, but SimpleEA applies it directly to the 2024 Precision Trend periods: the short period is measured from recent zero crossings and clamped to 14–36 bars; the long period follows it.
- **Hurst exponent — 1951 in origin.** Old mathematics, but still uncommon in retail MT5 EAs. SimpleEA uses it modestly as a regime label, not as a direction forecast.
- **Kaufman Efficiency Ratio — 1990s.** Used as a dead-market gate.
- **ATR and Dow swing structure — classics.** They are the ruler and common-sense structure check, not fashion items.

### Predict_X

Uses RSI/ADX, Keltner, SuperTrend, TTM Squeeze, VWAP/value logic, Smart Money Concepts, Markov chains, a small neural model and a k-NN/SQLite memory bank. The *memory-bank and rehearsal concept* is its most modern architectural feature; most of the underlying mathematics is decades old.

### Emtt

Uses adaptive Supertrend, K-Means, Kaufman/KAMA-style measurements, Smart Money Concepts, VWAP/volume profile/CVD estimates, a logistic online learner and guarded threshold optimisation. Its modernity lies less in any single formula than in the scale and discipline of the parameter-state machinery surrounding it.

### Autotrader

Has the broadest "current catalogue" feel: non-repainting Nadaraya–Watson kernel regression, Ehlers Super Smoother/Decycler/Laguerre RSI, a Kalman trend line, Smart Money Concepts and volume-flow/profile evidence. Kalman filtering and kernel regression are themselves 1960s mathematics, repopularised in modern trading interfaces.

**Conclusion:** Autotrader looks the most modern by catalogue size. SimpleEA contains the newest headline filter and then deliberately stops adding fashionable components.

---

## 5. Engineering scorecard

Scores are qualitative source-review judgements, not profitability ratings.

| Quality | Predict_X | Emtt | Autotrader | SimpleEA |
|---|---:|---:|---:|---:|
| Simplicity / fewest failure points | 4/10 | 3/10 | 7/10 | **9/10** |
| Transparency of each decision | 5/10 | 5/10 | 8/10 | **9/10** |
| Feature richness | 9/10 | **10/10** | 9/10 | 6/10 |
| Automated account-level guards | 7/10 | 6/10 | **9/10** | 6/10* |
| Outcome learning | 9/10 | 9/10 | 3/10 | 0/10 by design |
| Market-state adaptation | 7/10 | 9/10 | 8/10 | 7/10 |
| Ease of installation | 3/10 | 4/10 | 6/10 | **10/10** |
| Research and verification material in repo | 5/10 | 8/10 | 8/10 | **9/10** |
| Overall technical soundness, as an engineered artefact | 6/10 | 7/10 | 8/10 | **8.5/10** |

\* The owner does not regard the absence of a calendar-news module or an automatic daily-loss module as a missing function. His design position is recorded in §7. The score above measures only how many *automated* account guards exist, not whether adding them would make SimpleEA a better implementation of its intended philosophy.

### Why SimpleEA scores highly on soundness

1. **Closed bars only.** Historical readings do not repaint once the bar has closed.
2. **Three genuinely different votes.** Direction, timing and raw 20-bar structure are not the same indicator wearing three names. This makes 2/3 a meaningful intermediate state.
3. **Permission, direction/order type and pricing are separated.** The score publishes the would-be direction and chooses market versus limit; the operator may separately forbid new entries on a Choppy row; if allowed, Hurst/Range Mode decide how a limit is priced. A failed box falls back to the pullback rather than silently cancelling an allowed trade.
4. **No external dependency chain.** One file computes its own ATR and filters; there is no custom-indicator path, database, file schema, DLL or network service to fail.
5. **Frozen trade geometry.** TP1/TP2/TP3 are locked at entry, so a later ATR change does not move the target during the trade.
6. **Refusals are visible.** Unsupported chart timeframe, closed market, dead ER and below-gate score all become explicit panel states rather than silent inactivity.
7. **Research is unusually candid.** `research/HORIZON.md` reports where the raw direction reading is weak as readily as where it is less weak, and the Python files mirror or test the MQL logic.

---

## 6. What is innovative about SimpleEA?

SimpleEA does not invent Precision Trend, Hurst, ER or ATR. Its innovation is in the contracts between the parts:

1. **"Score decides direction and order type; the operator controls Choppy permission; regime/Range Mode decide entry style."** This keeps three different questions from being collapsed into one ambiguous switch.
2. **Confidence chooses the order style.** Unanimity acts immediately; a majority demands a price concession; a weak reading does nothing.
3. **Three independent timeframe traders in one file.** Other family members use one lane with context or hierarchy. SimpleEA can hold an M5, M15 and M30 trade simultaneously, each isolated by magic number.
4. **Calibration as a standard, not a user toy.** Engine constants were moved out of the input list so a user cannot unknowingly create a different, untested strategy while thinking they are only changing a preference.
5. **Innovation by refusal.** No outcome learner rewrites the rule after a small, noisy sample; no calendar, database or external indicator is allowed to become a hidden dependency.

---

## 7. Owner/designer notes — 25 October 2026

The owner reviewed the first version of this study and asked for four points of disagreement to be recorded. They are not accidental omissions; they are the operating philosophy of SimpleEA.

### 7.1 No initial stop-loss is intentional

SimpleEA's default `InpUseStopLoss = false` is a deliberate "breathing room" design. The EA still calculates a planned ATR stop and uses that distance for position sizing. Its stepped trailstop or universal break-even can attach the first broker-side stop after favourable progress. For a prop-firm rule or a user who wants a hard broker stop from the first tick, the function already exists as `InpUseStopLoss = true`.

**Reviewer note:** This should be judged as a chosen risk philosophy with a known trade-off, not as a missing stop-loss feature.

### 7.2 No separate news-impact module

The owner's position is that news is useful to a price EA only insofar as it changes price behaviour. That effect appears in the very things SimpleEA already measures — trend, ROC, structure, ATR, ER, Hurst regime, spread-sensitive order placement and subsequent closed-bar state. A calendar module would therefore add a second, overlapping representation of largely the same event, plus calendar availability, currency mapping and timezone complexity.

**Reviewer note:** A calendar's only genuinely distinct information is advance timing: it knows *before* the release, whereas a closed-bar price engine reacts after price has moved. But SimpleEA is explicitly a self-contained price-state EA. Within that philosophy, refusing a duplicate calendar layer is coherent and keeps the one-file design intact.

### 7.3 No automatic daily-loss guard; the operator is part of the system

SimpleEA is designed to be watched. The two panels show the effective autotrading state, timeframe readings, trade plan, open-trade progress and protection state. If the operator wants a tighter day, existing controls can immediately reduce or stop new exposure:

- set `InpAutoTrading = false` for advice-only mode;
- use the daily window or `InpAutoOffHours` one-shot pause to block new entries while open trades continue to be managed;
- raise `InpBuyScore` / lower `InpSellScore` so only 3/3 readings can trade;
- enable `InpRequireM15M30SameTrend`;
- reduce `InpRiskPct` or force `InpUseMinLot`;
- switch `InpRangeMode` off to stop using the choppy-market box-fade entry style;
- set `InpAllowChoppyTrade = false` to stop **new** Choppy entries altogether while already-open trades continue under normal management.

**Precision note (current code):** `InpRangeMode = false` stops *box-band pricing* on an allowed Choppy row but does not by itself veto Choppy trading; a qualifying 2/3 then falls back to the standard half-ATR pullback. The direct Choppy-row veto is `InpAllowChoppyTrade = false`. The timer/pause, score gate and master autotrading switch remain the broader new-entry stops.

### 7.4 M5 is retained deliberately

The owner does not claim that an OHLC indicator can be universally "proved" on M5. His position is the opposite: no ordinary bar indicator can carry that kind of proof in a non-stationary, cost-dominated five-minute market. SimpleEA's M5 lane is nevertheless retained because the complete live system — score classification, market versus pullback entry, frozen geometry, partial exits, break-even and trailing — is not the same object as the raw forward-return measurement in `research/HORIZON.md`, and the owner reports that the lane works in his use.

**Reviewer research result:** no universally proven M5 OHLC indicator was found. The only materially different information class would be tick/order-flow/execution-quality data rather than another candle indicator. That data is itself broker- and symbol-dependent in retail MT5 and is not a proof. Adding it would change SimpleEA's nature; it is not recommended merely to chase an M5 claim. The correct treatment is to journal and evaluate the M5 lane separately from M15/M30. SimpleEA v2.22 now does exactly that for every placed order idea, with separate M5/M15/M30 health verdicts and no automatic recalibration (see `documents.md` §9).

---

## 8. The one open concern: fixed calibration

The owner accepts one item from the original "where SimpleEA is behind" list as worth further research:

> **Fixed calibration never adapts.** If a symbol's character changes permanently, Emtt/Autotrader would slowly re-tune; SimpleEA will keep applying today's settings forever.

A follow-up code and literature review found that this sentence is too broad. SimpleEA is **state-adaptive but outcome-non-learning**:

- its Precision Trend cycle, ATR distances, Hurst regime, ER gate, 20-bar box, relative-volume check, spread/broker clamps and regime-dependent trailing all move with current market state;
- what does not move are the standard windows, thresholds and ATR ratios, and no realised trade outcome rewrites them.

The full analysis, risk ranking and a recommended research programme are in [`research/FIXED_CALIBRATION_RESEARCH.md`](research/FIXED_CALIBRATION_RESEARCH.md). Its short conclusion is:

> Do not copy Emtt's learner into SimpleEA. First make calibration drift *visible*, test whether the current constants sit on broad plateaus or narrow cliffs, and only then consider slow, bounded, human-approved recalibration of the few economic ratios that prove fragile.

---

## 9. Method and limits

- Repositories were inspected as source and documentation; no MetaEditor compilation, Strategy Tester run or live account result was available to this study.
- Line counts at review time were approximately: Predict_X 7,210 MQL lines across 22 files; Emtt 16,813 across 20; Autotrader 7,969 across 15; SimpleEA 5,147 in one file.
- A larger feature catalogue was not treated as evidence of a larger trading edge.
- "Technically sound" in this document means deterministic, inspectable, dependency-light, internally consistent and honest about its own limits. It does not mean profitable.

---

## 10. Final judgement

Predict_X is the family's most ambitious memory experiment. Emtt is its most extensively engineered adaptive laboratory. Autotrader is its broadest modern evidence and safety system. **SimpleEA is the mature distillation:** fewer claims, fewer dependencies, a clearer contract for every number, and enough market-state adaptation to avoid being a frozen ruler — while refusing to let a small sample of outcomes silently rewrite the strategy.

Its remaining calibration question is real, but it is a governance and measurement question before it is a coding question.
