# Fixed Calibration vs Adaptation in SimpleEA

**Date:** 25 October 2026
**Status:** Research note only. No EA code or shipped default is changed by this document.
**Question from the owner:** SimpleEA's calibration is fixed. If a symbol's character changes permanently, Emtt and Autotrader would slowly re-tune, while SimpleEA would keep using today's settings. How serious is that lack, and what should be done about it?

Related study: [`../COMPARISON_STUDY.md`](../COMPARISON_STUDY.md)

> **Historical strategy snapshot:** unless explicitly marked as an update, the analysis below describes the former ATR-based entry/stop/target and old exit policies. Those formulas, ratios, reach claims and fixed-geometry conclusions are not the current EA. New plan levels now use confirmed structure and completed historical bar analogs; ATR remains only in the retained signal engine. The new implementation is uncompiled and unvalidated; see [`../documents.md`](../documents.md) and its MT5 checklist. Historical studies do not establish current profitability.

> **Fixed-exit implementation amendment (28 October 2026):** the current EA now always attaches the planned SL/TP3 and permits only TP1/TP2 partials, TP3 final close and the unchanged SL after entry. Trailstop, profit-floor, score/flip/HOLD and open-trade box-exit discussions below are historical research context, not the current lifecycle.

> **Implementation update after this research (25 October 2026):** Choppy permission and Range Mode are now separate inputs. `InpAllowChoppyTrade` (shipped default `true`) decides whether a row currently labelled Choppy may open a new trade; `InpRangeMode` only decides whether an allowed Choppy 2/3 uses box-band pricing or a confirmed-swing limit (the older half-ATR pullback below is historical). With the shipped default, the calibration analysis below stands unchanged. If the operator sets permission to `false`, the Hurst Choppy label intentionally becomes a new-entry veto as well, so a false Choppy label can suppress entries; waiting pendings are cancelled when their row turns Choppy, while already-open trades remain under normal management.

> **Diary implementation update (26 October 2026, EA v2.22):** the calibration-awareness step recommended below is now implemented as a per-symbol diary and health monitor. Confirmed order ideas normally leave one persistent record (score, regime, entry style, spread as a share of TP1, peak progress to TP1, TP1/TP2/TP3 price reach, final stop-exit and peak-to-final-leg giveback evidence, settings in force and final result in planned-risk `R`). The Main Panel adds Day `S/W/L` counts and one compact health label per timeframe; only a persistently Poor lane adds a problem + safest-first-fix note. `InpShowHealth=false` hides the optional History panel but does not stop recording. This makes follow-through, cost and score decay visible per lane while preserving the research conclusion: outcomes still do **not** rewrite the strategy, and any recalibration remains a human decision. See `documents.md` §9.

---

## Executive answer

The owner's concern is justified, but the original criticism - **"fixed calibration never adapts"** - is too broad and should be corrected.

SimpleEA is better described as:

> **State-adaptive, dimensionless and standardised - but deliberately not outcome-learning.**

Its measurements and distances move continuously with the market: dominant cycle, ATR, Hurst regime, efficiency ratio, 20-bar box, relative tick volume, live spread and broker constraints. What remains fixed is a small set of windows, thresholds and ATR ratios. No win/loss result ever rewrites those constants.

That is a maintenance and monitoring issue, not proof that the current calibration is already wrong. The largest permanent-change risk is **not** that EURUSD or gold suddenly needs a different Hurst label. It is that the economics around an otherwise similar signal can change:

- price may travel less (or more) after entry per ATR, making the fixed TP/SL geometry stale;
- spread and slippage may consume a permanently larger fraction of TP1, especially on M5;
- the measured cycle may live against the 14- or 36-bar clamp;
- a symbol/session may become more jump- and wick-driven than close-to-close measurements describe well;
- score buckets may stop behaving monotonically even while the indicator readings still look plausible.

**Recommendation:** do not import Emtt's self-learning machinery into SimpleEA. First add *calibration awareness* as a research discipline: journal the state and outcomes, measure whether today's constants sit on broad plateaus or narrow cliffs, and use drift alarms to trigger a human-reviewed, versioned recalibration. Automated adaptation, if it is ever justified, should be limited to a few bounded economic ratios and should change slowly, outside open trades, after shadow evidence.

In short: **fix the calibration governance before fixing the calibration.**

---

## 1. Four different things people call "adaptation"

Much confusion disappears once adaptation is separated into levels.

| Level | Meaning | SimpleEA | Emtt | Autotrader | Predict_X |
|---|---|---|---|---|---|
| **1. Measurement adaptation** | Current readings are recalculated from recent data. | Yes: cycle, ATR, Hurst, ER, box, volume, spread. | Yes. | Yes. | Yes. |
| **2. State-conditional behaviour** | The same rules branch differently according to the current state. | Yes: regime-priced limits, ER HOLD, volume downgrade, regime-dependent trailing, score-dependent order type/risk. | Yes, extensively. | Yes, extensively. | Yes. |
| **3. Parameter adaptation from market state** | Windows, multipliers or thresholds are derived from symbol/market measurements rather than being one universal number. | **Partly:** Precision Trend periods are cycle-derived; most other constants are standard. | **Yes:** asset-class x volatility-bucket matrix and K-Means Supertrend multipliers. | **Yes:** Symbol Intelligence derives SL/TP multipliers, proof threshold and spread limit. | Partly, through presets and indicator state. |
| **4. Outcome learning** | Realised wins/losses or paper-plan results rewrite future decisions. | **No.** | **Yes, bounded:** logistic filter and confidence-bar optimiser. | Mostly no; it audits outcomes but does not appear to learn its core rule from them. | **Yes:** online model and Aladin memory. |

The real gap in SimpleEA is therefore mainly **Level 4**, plus a narrower Level 3 than Emtt/Autotrader. It is not a frozen-price system.

There is also a paradox that applies to every adaptive EA:

> Adaptation does not eliminate fixed calibration. It moves the fixed choices one level upward.

Emtt still fixes its 200-bar volatility ranking window, 30/70 percentile boundaries, 3 clusters, multiplier candidates, 30-plan warm-up, +/-15% learning cap, learning-rate schedule and 60/70/75 threshold candidates. Autotrader still fixes the formulas, asset-class baselines, lookbacks and clamps that derive its dials. Those meta-choices can become stale too. Adaptation is useful only when it makes the complete system less sensitive to change than the fixed alternative; it is not virtuous by itself.

Adaptive-parameter literature makes the same trade-off explicit: a fixed setting's error is exchanged for the error of the live measurement driving it, and an unstable driver can make the indicator inherit every jump in that estimate [3](https://www.luxalgo.com/library/concept/adaptive-parameter-technique/).

---

## 2. What SimpleEA already adapts today

The following is from `SimpleAdvisor.mq5` as reviewed on 25 October 2026.

### 2.1 The trend filter tunes itself to the measured cycle

`AdaptiveCyclePeriod()`:

- runs a 40-period high-pass filter over the closed prices;
- examines zero crossings over the latest 120 bars;
- takes the median crossing interval, doubles it to estimate the dominant cycle;
- clamps the result to **[14, 36] bars**;
- falls back to 24 when there is too little data or too few crossings.

`EvaluateRow()` then sets:

- `L2 = measured cycle`;
- `L1 = round(6.25 x L2)`, clamped to **[90, 225]**;
- recomputes Precision Trend and ROC with those periods.

The compile-time `TREND_L2 = 24` and `TREND_L1 = 150` now act mainly as fallback/seed/history references, not as the live periods (the row's `l1/l2` are overwritten on each evaluation). This is genuine Level 3 adaptation, although its bounds, 120-bar measurement window, 40-period pre-filter and 6.25 ratio are fixed meta-calibration.

The approach is philosophically in the Ehlers/Kaufman tradition: measure a current driver - cycle, volatility or efficiency - and derive the indicator setting from it rather than assuming the design-time rhythm forever [3](https://www.luxalgo.com/library/concept/adaptive-parameter-technique/).

### 2.2 Volatility is the common ruler

SimpleEA computes its own 14-bar average true range from closed bars. Note that the MQL implementation is an arithmetic mean of the last 14 true ranges, not Wilder's recursive smoothing. Any future recalibration must therefore preserve this definition or re-measure every ratio that depends on it.

That ATR then scales:

- Vote 2 ROC dead-band: `0.02 x ATR`;
- Vote 3 structure dead-band: `0.25 x ATR`;
- planned stop and TP3 by timeframe;
- the normal 2/3 pending offset: `0.5 x ATR`, pushed out if spread/stops level require;
- range-box minimum height and range stop;
- risk-based lot size, through the planned stop distance;
- post-TP1 runner cushion: `0.10 x ATR`.

Consequently, a symbol becoming twice as volatile does not leave SimpleEA using yesterday's point distances. Its point distances roughly double with ATR, and risk-sized lots roughly halve. This is strong protection against the most common kind of permanent change: a change in volatility scale.

### 2.3 Regime and travel quality are rolling measurements

- Hurst is recalculated over a rolling **256-bar** variance-scaling window on every row.
- Kaufman ER is recalculated over **20 bars**.
- The 20-bar box is rebuilt from the latest highs/lows.
- Tick-volume confirmation compares the last finished bar with its own recent 20-bar average.
- Live spread and broker stops/freeze levels clamp entries and modifications.

If a symbol gradually becomes more persistent, Hurst can move it from Choppy toward Steady and the entry style follows. If its ranges become cleaner or more overlapping, ER follows. If volatility dries up in relative tick-volume terms, a 3/3 market order is downgraded to a limit. These are not parameter changes, but they are meaningful behavioural adaptation.

### 2.4 Trade management branches by state

- Score 3 risks twice score 2 in risk mode.
- A Choppy 2/3 uses box geometry; other 2/3 trades use the half-ATR pullback.
- Pre-TP1 trailing arms at the Tight percentage outside a clear Steady state and at the Steady percentage inside one.
- The trailing gap is widened by x1.25 on M15 and x1.50 on M30.
- Universal break-even arms at 50% of the frozen Entry->TP1 distance whether trailing is on or off.
- Broker contract size, tick value, point, digits, lot step/min/max, stops and freeze levels are read from the actual symbol/account rather than hard-coded.

This is why "one standard profile" must not be confused with "one fixed point distance for all symbols and all future volatility".

---

## 3. What really is fixed?

The shipped standard is concentrated in four code profiles.

| Fixed item | Current standard | Why it exists | Permanent-change sensitivity |
|---|---|---|---|
| Cycle meta-calibration | 120-bar lookback, 40-period pre-filter, clamp 14-36, `L1 = 6.25 x L2` clamp 90-225 | Keeps the band-pass in the intended tradable band and prevents absurd cycle estimates. | **Medium-high.** A market whose useful rhythm permanently leaves 14-36 can only be followed to the clamp. |
| ATR definition/period | Arithmetic true-range mean, 14 closed bars | One volatility ruler for every distance and dead-band. | **Medium.** Fast to normalise after a volatility change, but a jump/wick-dominated character can move this ATR differently from close-to-close risk. |
| Structure and ER window | 20 bars for both; ER also matches the box | A common yardstick and an independently measured third vote. | **Medium.** Vote 1 follows the measured cycle, while Votes/ER/box remain on a 20-bar yardstick. That independence may be a benefit, not automatically a defect. |
| Vote dead-bands | ROC `0.02 ATR`; structure `0.25 ATR` | Suppresses sub-noise flicker and no-travel votes. | **Medium.** If close noise per ATR changes, abstention rates can drift. |
| ER gates | Dead below `0.10`; box requires ER below `0.40` | Separates no-travel noise and a box from a directional walk. | **Medium.** ER is dimensionless and comparable across symbols, but its distribution can shift with sampling/session character. |
| Hurst window and labels | 256 bars; Steady above `0.55`, Choppy below `0.45` | The conventional neutral band around the 0.5 random-walk boundary. | **Medium, but mitigated.** A wrong label changes limit pricing/trailing choice, not trade permission. |
| Trade geometry | SL/TP ATR: M5 1.0/0.9; M15 1.2/1.8; M30 1.5/3.0 | Gives each timeframe a different aim and intended R multiple. | **High.** Follow-through per ATR and time-to-target are empirical, symbol/session/cost dependent. |
| Pending geometry | `0.5 ATR` pullback; 3-bar trend leash; 8-bar range leash | Demands a concession at 2/3 and expires stale ideas. | **High-medium.** Fill rate versus missed-runner trade-off can change with market rhythm and spread. |
| Box geometry | 20 bars; stop band + `1.0 ATR`; target midpoint; half-box at least 3 spreads; minimum RR 1 | Ensures the fade target can clear its stop and cost. | **Medium.** The spread gate adapts, but box duration/shape do not. |
| Exit proportions | TP2 75% of TP3; TP1 75% of TP2; 70% close at TP1; BE at 50% to TP1; trail steps 5% | A stable, comprehensible lifecycle. | **Low-medium.** This is mainly payoff-shaping policy. It can become suboptimal, but is less likely to make the signal itself meaningless. |
| Score gates/risk | User inputs: +2/-2, 0.5% risk, score-3 x2; trail percentages are user inputs | Operator preferences. | **Low as a code concern.** The operator can tighten them without changing strategy calibration. |

Two fixed choices deserve special mention:

1. **Hurst 0.45/0.55 is not purely a symbol calibration.** The conceptual boundary is 0.5: above it persistence, below it anti-persistence. The +/-0.05 neutral band is conventional protection against estimator noise. However, Hurst estimates from a few hundred observations have wide uncertainty, and different estimators have different finite-sample bias; a reading just beyond 0.55 is not statistical proof of persistence [9](https://fractalcycles.com/guides/hurst-exponent-interpretation). SimpleEA's decision to use Hurst only for entry style is therefore an important damage limiter. If Hurst gated permission, fixed-threshold risk would be much more serious.

2. **A fixed 20-bar structure/ER window beside an adaptive trend cycle is a deliberate tension.** Making Vote 3 use the same measured cycle as Vote 1 might align the horizons, but it could also make the votes less independent - and independence is exactly what makes 2/3 meaningful. This should be tested, not assumed to be an improvement.

---

## 4. Which permanent changes can SimpleEA absorb?

| Permanent change in the symbol or market | How SimpleEA responds now | Residual risk |
|---|---|---|
| **Volatility doubles or halves** | ATR distances, dead-bands, box height and lot denominator rescale within roughly the ATR/box windows. | Low for scale alone. Spread as a fraction of ATR/TP may still deteriorate. |
| **Market becomes more trending** | Rolling Hurst can re-label it Steady; ER rises; limits use pullback; trailing can use the later Steady arm. | Low-medium. Hurst takes up to its 256-bar window to forget the old character, so there is transition lag. |
| **Market becomes more mean-reverting** | Hurst can re-label it Choppy; 2/3 limits move to the box band if the box passes its gates. | Low-medium. The score can still trade directionally; the owner can disable box pricing, but that is not a complete Choppy veto. |
| **Dominant cycle shortens/lengthens inside 14-36 bars** | Precision Trend periods follow it. | Low. Estimate jumps may add vote flicker because there is no explicit cycle hysteresis/holding rule. |
| **Dominant cycle moves permanently outside 14-36 bars** | The estimate saturates at the clamp. | **Medium-high.** The filter remains usable but is systematically mistuned; nobody is alerted merely by looking at the present panel. |
| **Follow-through per ATR shrinks** | No direct response. Signals and entries may remain similar, but TP1/TP3 are reached less often and holding patterns change. | **High.** This is invisible to the signal engine without a trade/outcome journal. |
| **Follow-through per ATR expands** | No direct response; targets may become too conservative and runners may be cut by score/exit rules. | Medium. Usually an opportunity cost rather than a ruin mechanism. |
| **Broker spread/commission/slippage permanently worsens** | Box gate requires half-box >= 3 spreads; limits respect spread/stops level; slippage allowance is spread-based. | **High on M5, medium elsewhere.** A normal trend trade has no explicit "spread must be below X% of TP1/ATR" economic gate. A plan can remain technically valid while becoming poor value. |
| **Price becomes gap- and wick-dominated** | ATR sees high-low range; wick TP1 confirmation exists; stops respect broker distance. | Medium-high. Hurst, ER and cycle are close-based, while the user's realised path is wick-based. The gap between close state and tradable path can widen. |
| **Liquidity moves to another session** | Relative tick volume can downgrade thin 3/3 entries; the operator can set a timer. | Medium. There is no session-specific calibration, and rolling 256/20-bar windows mix sessions. |
| **A new symbol class behaves unlike the tested FX/gold set** | Dimensionless ATR/Hurst/ER measures transfer mechanically. | Medium-high until evidenced. Mechanical transfer is not the same as demonstrated transfer to, say, a gappy equity index, energy contract or weekend crypto symbol. |
| **The signal edge decays while distributions look normal** | No response; input readings can look healthy while score buckets stop paying. | **High as a detection issue.** Only outcome monitoring can see this. |
| **An abrupt structural break** - peg removal, contract change, trading-hour change, broker feed change | Rolling windows eventually flush old data; broker facts are re-read. | Medium-high during the transition. This is a case for pausing and human review, not for letting a learner immediately fit the break. |

The pattern is clear: SimpleEA absorbs **scale and regime changes** much better than it absorbs **economic-geometry and edge changes**.

---

## 5. What Emtt and Autotrader actually do differently

### 5.1 Emtt: bounded parameter adaptation plus bounded outcome learning

Emtt's adaptation is not free-form machine learning. Its guardrails are a large part of its design:

- Asset class is classified from the symbol.
- Current ATR(14) is ranked against a 200-bar reference and placed into Low/Normal/High volatility buckets with hysteresis around the 30/70 percentiles.
- A pre-designed asset-class x bucket matrix supplies measurement periods, in small integer steps. Only one bucket column can be crossed at a time, and a changed parameter must then stay quiet for two closed bars.
- Supertrend ATR values are clustered into Calm/Normal/Wild; each cluster can learn only from the approved multipliers 2.0, 2.5, 3.0, 3.5 and 4.0, with sparse-cluster safeguards.
- The logistic learner uses 16 features, becomes live after 30 labelled plans, decays its learning rate as `0.30/sqrt(k)`, clamps weights, can adjust the combined number by at most 15%, and cannot change its side.
- Phase 9 parameter optimisation changes only the confidence bar, only among **60/70/75**, only after at least 20 accepted and 20 near-miss samples in the relevant cell, and freezes the entry bar while a position is open.

**Strength:** if a symbol's volatility character changes within the world anticipated by the matrix/candidate sets, Emtt can select a better pre-approved neighbourhood without a code release.

**Limit:** it does not discover a wholly new calibration outside those sets. It also introduces state-replay, persistence, sample-labelling and feedback questions. Thirty or forty outcomes are enough to move a bounded dial; they are not enough to establish that the move generalises, especially when samples are serially dependent and collected only from plans the prior rule chose to expose.

### 5.2 Autotrader: formulaic symbol adaptation, not outcome learning

Autotrader's Symbol Intelligence:

- classifies the symbol from its name/contract mode;
- compares a recent 14-bar true-range average with a longer baseline;
- measures ATR as a percentage of price and maintains a sampled typical spread;
- derives bounded SL and TP ATR multipliers;
- derives a score threshold in a bounded band;
- sets the expensive-spread line at 2.5 times the symbol's typical spread.

Its indicators and trailing stop also contain state-adaptive elements: kernel bandwidth/envelope, Laguerre gamma, Kalman noise and a trailing policy driven by lane, volatility, regime, score change and structure.

**Strength:** the same EA can demand more room and more proof from a jumpier symbol and less from a calm one, relative to that symbol's own normal.

**Limit:** the deriving formulas and baselines are fixed. Once a permanently higher-volatility state has filled the baseline window, "current versus normal" can normalise it. A ticker-string class can also be wrong for an unusual broker symbol. Most importantly for this question, Autotrader's audit log can reveal decay to a human, but its core evidence rule does not re-estimate itself from realised edge.

### 5.3 Predict_X: the strongest outcome adaptation, and the largest small-sample warning

Predict_X's online model and Aladin memory are the only family mechanisms that directly ask, "what happened in situations like this?" at scale. That is conceptually attractive when a symbol changes. It is also where stale memories, rehearsal/live mixing, selection bias and catastrophic forgetting become first-order design problems. A memory is only an adaptation advantage if its recency, labelling and execution costs remain comparable to the live market.

### 5.4 The useful lesson for SimpleEA

The lesson is not "copy Emtt" or "copy Autotrader". It is to borrow their safest principles in SimpleEA's own language:

- **bounded candidates**, never an unbounded optimiser;
- **hysteresis and quiet periods**, never a parameter that can twitch every bar;
- **freeze everything relevant while a trade is open** - SimpleEA already does this for TP geometry;
- **journal the reason for every change**;
- **adapt from market/economic state first**, and from noisy win/loss labels last.

---

## 6. What the evidence says - and does not say

### 6.1 Markets are non-stationary; refitting is not automatically the cure

Financial series change their volatility, correlations and relationship between signal and future return. A parameter set fitted in one regime may therefore fail in another; that is the owner's concern in formal language [1](https://www.quantbeckman.com/p/with-code-walk-forward-cvcl-optimization). At the same time, re-optimisation can fit the noise and outliers of the latest window and destroy generalisation [1](https://www.quantbeckman.com/p/with-code-walk-forward-cvcl-optimization). Walk-forward evaluation - fit on one period, test on the next unseen period, then roll forward - is the standard way to judge whether periodic refitting helps out of sample rather than merely looks responsive in hindsight [2](https://mathandmarkets.com/p/can-a-strategy-evolve-the-math-of).

There is an unavoidable window trade-off: short estimation windows react quickly but are noisy; long windows are stable but lag real drift [2](https://mathandmarkets.com/p/can-a-strategy-evolve-the-math-of). Walk-forward methods themselves remain reactive - performance often deteriorates before the next refit can identify the new regime [7](https://blog.quantinsti.com/walk-forward-optimization-introduction/). Large parameter jumps between adjacent windows are themselves a warning of overfitting rather than proof of intelligent adaptation [12](https://grokipedia.com/page/Walk_forward_optimization).

For SimpleEA this implies a high bar for Level 4 learning. A handful of recalibrated constants might be defensible. A frequent multi-parameter optimiser would create a different EA and a much harder validation problem.

### 6.2 Drift detection should trigger investigation before retraining

Modern model-monitoring practice distinguishes a change in input distribution from a change in the relationship between input and outcome. A detector firing says something changed; it does not prove that retraining will help, and the cause may be a data/broker/session change rather than a strategy failure [1](https://mlmonitoring.report/posts/concept-drift-detection-methods/). Sequential tools such as ADWIN and Page-Hinkley/CUSUM are useful because they formalise "recent errors or outcomes no longer look like the reference period", but the correct response still depends on diagnosis and on having enough fresh, trustworthy labels [1](https://mlmonitoring.report/posts/concept-drift-detection-methods/).

That distinction maps cleanly onto SimpleEA:

- **Input drift:** Hurst/ER/ATR/cycle/spread distributions move. Action: inspect; the existing state-adaptive rules may already be handling it.
- **Geometry drift:** TP1 reach rate, MFE/MAE and fill rates move. Action: candidate TP/pending profile should be shadow-tested.
- **Edge drift:** net expectancy by score bucket turns persistently poor while inputs look ordinary. Action: reduce/stop that lane and investigate; do not immediately search for a new indicator setting.
- **Execution drift:** spread, slippage, rejection and gap behaviour change. Action: fix broker/session/cost gates before touching signal calibration.

### 6.3 SimpleEA's own cross-era evidence is useful but limited

`research/HORIZON.md` evaluates the causal direction rule on XAUUSD, EURUSD, GBPUSD and USDJPY in a 2026 sample and on independent EURUSD 2015/2016 data from a different feed. That is a better-than-nothing transfer check for the measurement definitions: the same standard produces broadly similar reading life and no magical M5 effect in either era.

But three limits matter for the calibration question:

1. The horizon study is mainly a raw direction/forward-return study. It is not a complete live-system simulation with actual limit fills, spreads over time, swaps/fees, partials, break-even, score exits and broker constraints.
2. It does not estimate how sensitive the *complete trade lifecycle* is to each fixed constant.
3. It does not cover every symbol class SimpleEA can be attached to, nor multiple brokers and cost models.

Therefore the repo can support the statement "these definitions are not obviously a one-month curve fit". It cannot yet support "this TP/SL and pending geometry will remain right for any symbol indefinitely".

### 6.4 Parameter sensitivity is the missing measurement

A fixed number is not automatically fragile. It may sit in the middle of a broad plateau where values 20% either side behave almost the same. Conversely, a number can be dangerous because the chosen value sits at the edge of a cliff.

No such plateau/cliff map for the complete current EA was found in the repository. Until that map exists, both statements below are unsupported:

- "The fixed calibration will fail when the symbol changes."
- "The fixed calibration is robust because it is fixed."

The research task is to find which constants are plateaus and which are cliffs.

---

## 7. Risk ranking for SimpleEA

### Highest priority

1. **Cost relative to target (especially M5).** Fixed TP geometry in ATR does not by itself guarantee that spread + slippage + fees remain an acceptable fraction of TP1. Genuine microstructure and execution costs are tick-level phenomena; bar measures are proxies and can misstate the cost actually paid [1](https://www.mql5.com/en/articles/22938).
2. **TP/SL follow-through geometry.** This is the most empirical and least universal calibration in the EA.
3. **Invisible edge decay.** Without a symbol x timeframe x score x regime outcome journal, a permanent change can only be noticed anecdotally through account P&L.
4. **Cycle-clamp saturation.** Adaptation exists until it reaches 14 or 36. Saturation should be observable.

### Medium priority

5. **Pending offset and leash.** A changed pullback rhythm can turn "better price" into either adverse selection or systematic missed entries.
6. **ATR character change.** Average true range over 14 bars is a good scale ruler, but wick/gap composition can change faster than close-based votes.
7. **Hurst/ER distribution shift.** Their labels are useful but estimator- and session-sensitive; thankfully Hurst does not grant permission.
8. **Session migration.** A single rolling calibration treats all hours as one population unless the user sets a timer.

### Lower priority

9. **Exact 0.55/0.45 Hurst boundary.** Important to entry style, but conceptually anchored at 0.5 and not a trade veto.
10. **TP split proportions and 5% trail steps.** These shape the payoff; they are policy choices rather than estimates of a symbol property.
11. **Score threshold as code calibration.** It is already an operator input and can be tightened to 3/3 without redesigning the strategy.

---

## 8. Recommended research programme

This section proposes studies. It does **not** authorise changing defaults from intuition.

### Study A - Plateau and cliff map for the complete EA

Build or extend a causal simulator that reproduces the current executor, not only the direction reading:

- actual market/limit decision;
- pending refresh/expiry;
- spread and, where data permit, variable spread/slippage/fees/swap;
- frozen TP1/TP2/TP3;
- partials, universal BE and pre-TP1 trailing;
- signal-flip, HOLD-in-profit, score-watcher and box-kill rules;
- one trade per timeframe and independent M5/M15/M30 lanes.

Then vary one constant at a time, followed by a small number of pre-declared pairs:

- cycle clamp and measurement lookback;
- Hurst window and neutral band;
- ER period/dead gate;
- ROC and structure dead-bands;
- ATR period/definition only as a sensitivity check;
- SL/TP ATR ratios by timeframe;
- pending ATR offset and valid bars;
- box bars/height/spread multiple;
- trail arms and BE ratio.

Report results by **symbol x timeframe x era/regime**, net of costs, including:

- expectancy in planned-R units;
- profit factor and drawdown, but not as the only measures;
- number of trades and pending fill rate;
- TP1/TP2/TP3 reach rates;
- MFE/MAE relative to planned stop and TP1;
- bars in trade;
- score-bucket monotonicity: does 3/3 actually behave differently from 2/3 after costs?
- regime-bucket behaviour: does box pricing beat pullback fallback in Choppy?

A constant is acceptable as a permanent standard if nearby values form a broad, cross-symbol plateau. A constant that only works in one narrow cell is a candidate for a class profile, a formulaic state rule or periodic human recalibration.

### Study B - Walk-forward, not one long backtest

Use rolling or anchored walk-forward blocks across old and recent eras. Any candidate adaptation must be allowed to learn only from data before the block it trades. Compare at minimum:

1. today's fixed standard;
2. fixed standard + cycle hysteresis;
3. fixed standard + explicit cost-relative entry downgrade/gate;
4. broad symbol-class profiles for trade geometry only;
5. slow bounded outcome recalibration, if earlier studies justify it.

The question is not which one has the best final equity curve on the full sample. It is which one degrades least on the next unseen block and keeps its chosen parameters stable. Adjacent-window parameter instability should count against an adaptive candidate [12](https://grokipedia.com/page/Walk_forward_optimization).

### Study C - Calibration-health journal

Before adapting anything, make change observable. For each evaluated signal and each completed trade, the research record should contain:

- symbol, timeframe, broker/server and session bucket;
- votes, score, ER, Hurst, ATR and ATR percentile against a longer baseline;
- measured cycle and whether it hit the 14/36 clamp;
- spread in points, spread/ATR and spread/TP1;
- tick-volume ratio;
- entry mode: market, pullback limit or box limit;
- box height/to-ATR and ER when applicable;
- planned stop/TP distances in points and ATR;
- fill delay and whether a pending expired unfilled;
- realised MFE/MAE in R, exit reason, bars held and net R after all costs.

From this, produce rolling reference comparisons rather than raw daily impressions:

- input-distribution drift (for example percentile/PSI-style summaries);
- outcome drift by lane and bucket;
- a CUSUM/Page-Hinkley style alarm on daily or per-trade R, interpreted cautiously because trades are not independent;
- cycle-clamp saturation rate;
- pending fill and TP1 reach-rate drift.

The first version should be **read-only**. An alarm should create a research task, not silently move a trading constant.

### Study D - Champion/challenger shadow test

If a candidate profile emerges:

- keep the shipped profile as champion;
- run the candidate as a read-only shadow or on a separate demo magic;
- freeze both profiles for the test period;
- pre-register the promotion criteria and minimum sample before looking at the result;
- demand improvement after costs across more than one symbol/session condition, not one fortunate week;
- reject the candidate if it improves average return by worsening tail loss, trade count explainability or one whole timeframe lane.

Only after that should a new profile be shipped as a named, dated version. This preserves SimpleEA's central virtue: a user can always answer, "which standard produced this trade?"

---

## 9. Candidate adaptation designs, from safest to riskiest

### Option 0 - Keep the fixed standard and add only visibility

**Recommendation now.** Add research journaling/health summaries outside the trading path, or maintain them from exported trade history. This does not make the EA adaptive, but it converts "we would never know" into "we can see drift early".

### Option 1 - Stabilise the existing cycle adaptation

Test whether the measured cycle needs hysteresis or a minimum hold:

- for example, change the working period only when the new estimate differs by more than a small amount or persists for several evaluations;
- log how many score changes are caused by price movement versus period movement;
- log time spent at the clamps.

This is not new learning; it is measurement hygiene. Emtt's hysteresis/quiet-bar principle is relevant here, without importing Emtt's parameter matrix.

### Option 2 - Make trading costs a first-class state variable

Test a formulaic rule based on current cost, not past wins:

- express spread as a percentage of ATR and of TP1;
- if cost crosses a pre-researched threshold, downgrade a 3/3 market order to a limit, require a wider box, or stand aside that lane;
- keep the rule dimensionless so it follows the broker/symbol automatically.

This directly addresses the largest M5 permanent-change risk and is fully compatible with the owner's no-news, price/execution-state philosophy. It should nevertheless be plateau-tested; another gate can also remove the best fast moves.

### Option 3 - Broad symbol-class geometry profiles

Only if Study A shows that one geometry cannot serve all classes:

- keep signal votes, thresholds and Hurst interpretation universal;
- consider two or three broad profiles for TP/SL/pending geometry - for example FX/metals, indices/energy, crypto - selected by measurable contract/cost properties rather than fragile ticker text alone;
- ship them as fixed, documented profiles, not as live learning.

This borrows Autotrader's useful insight while retaining SimpleEA's auditability.

### Option 4 - Slow, bounded, human-approved recalibration

If outcome drift is real and repeated:

- recalibrate only TP multipliers and pending offset initially;
- use a tiny candidate ladder around the standard, chosen from Study A's plateau map;
- require a minimum number of completed, net-cost trades per symbol/timeframe cell;
- change at most one step;
- apply only at a session/day boundary and never to an open trade or waiting order's frozen thesis;
- record the prior value, evidence window, candidate, approver and rollback value;
- automatically revert or stop for review if the next out-of-sample block worsens beyond a pre-set boundary.

This is the closest SimpleEA should come to Emtt-style adaptation. It is a governed release process, not an intraday optimiser.

### Option 5 - Full online learning

**Not recommended for SimpleEA.** A logistic filter, k-NN memory or continuous optimiser would duplicate the purposes of Emtt/Predict_X, add persistence and labelling machinery, weaken the one-file/no-dependency identity, and require a much larger validation burden. The owner already has EAs exploring that branch of the design space. SimpleEA's value is that it occupies the other branch credibly.

---

## 10. Answers to the owner's four related positions

These positions affect the calibration conclusion and are therefore recorded here in research form. The fuller owner notes are in `../COMPARISON_STUDY.md` §7.

### 10.1 Stop-loss

The absence of an initial broker stop is the shipped philosophy, not missing code. `InpUseStopLoss` exists. This research therefore does not recommend redesigning SimpleEA around a mandatory initial SL. Calibration work should evaluate the chosen lifecycle as designed, while remembering that planned-R sizing is not the same as a guaranteed maximum loss when no broker stop is in place.

### 10.2 News

A calendar would be a second information channel whose only unique contribution is timing foresight. Once news reaches price, SimpleEA's ATR, ER, votes, spread checks and rolling Hurst can react on later closed bars. Given the owner's self-contained price-state objective, no calendar module is proposed. The cost-state rule in Option 2 would respond to the tradable consequence of news without importing an economic calendar.

### 10.3 Daily-loss guard

SimpleEA substitutes operator visibility and manual tightening for an automatic daily-loss switch. That is a coherent supervised-EA philosophy. For calibration research, however, manual interventions must be timestamped in any journal; otherwise a lane's apparent improvement may actually be the operator pausing it after losses.

### 10.4 M5

No universally proven five-minute OHLC indicator was found in this review. At M1/M5, bid/ask bounce, spread variation, tick arrival and intrabar sequencing are first-order effects, while many bar-level microstructure measures are only proxies for tick-level quantities [1](https://www.mql5.com/en/articles/22938). SimpleEA's own OHLC study also shows why an M5 forward-close result cannot settle the performance of a pullback/partial/BE execution system.

The proper scientific status of the M5 lane is therefore:

- **not proved** by a universal indicator theorem - no such theorem exists for a non-stationary traded market;
- **not disproved** by `HORIZON.md`, because that study does not reproduce the complete live execution economics;
- **to be judged only by a separately journalled, net-cost M5 record.**

If any future M5-specific work is done, it should be about execution/cost state, not about adding RSI/MACD/SMC/AI in search of a mythical proven candle indicator.

---

## 11. Practical roadmap

### Immediate (no behaviour change)

1. Keep the shipped standard unchanged.
2. Begin a symbol x timeframe journal for live/demo trades and manual interventions.
3. Track, at minimum: cycle value/clamp hits, Hurst, ER, ATR, spread/TP1, score, fill/no-fill, TP reach, MFE/MAE and net R.

### Next research milestone

4. Produce the plateau/cliff sensitivity map for the complete executor.
5. Test cycle-estimate stability and clamp saturation.
6. Test cost-relative geometry, especially for M5, before testing any outcome learner.

### Only if evidence demands it

7. Introduce broad fixed class profiles for geometry, or a slow bounded recalibration process.
8. Promote a profile only through champion/challenger shadow evidence.
9. Version and date every shipped profile so old trades remain reproducible.

### Explicitly not recommended

- exposing the baked constants again as optimisation inputs;
- changing constants after a losing week;
- learning from raw win/loss without spread, swap, fees, slippage and partial-close accounting;
- allowing Hurst, ER or a learner to become a second hidden permission system;
- changing a parameter while a position's frozen geometry depends on it;
- copying Emtt's learning stack into the one-file EA.

---

## 12. Bottom line for the owner

Your unhappiness is aimed at the right place, but the conclusion should not yet be "SimpleEA must learn".

SimpleEA already adapts to the market's *scale, rhythm, regime, travel quality, volume and broker*. Its fixed constants are mostly dimensionless standards, not frozen point values. That is why it can move between symbols at all. The unresolved question is whether a small number of those standards - chiefly **target/stop geometry, pending distance and cost tolerance** - remain on broad robust plateaus as symbols and brokers change.

Emtt and Autotrader do not eliminate that question. They answer part of it with more machinery and new meta-constants. SimpleEA can answer it in character:

> **Measure first. Alarm second. Recalibrate rarely, visibly and by version. Learn automatically only if every simpler explanation has failed.**

That would preserve what makes SimpleEA innovative while removing the only part of the fixed-calibration criticism that is fully justified today: at present, permanent drift would be hard to *see* early.

---

## 13. Limitations of this research

- This is a static source and literature review, not a MetaEditor compile, Strategy Tester run or live-forward audit.
- Repositories for Emtt, Autotrader and Predict_X were inspected at their public state on 25 October 2026; later branches or private builds may differ.
- Raw market CSVs used by SimpleEA's earlier research are not committed, so the plateau study proposed above could not be executed from this checkout alone.
- No owner live-trade export was supplied, so the reported working M5 experience could not be quantified here.
- External trading literature and vendor educational pages are useful for method and failure modes, not as evidence that any parameter value will be profitable on a particular MT5 broker.

---

## References and source map

### SimpleEA source

- `SimpleAdvisor.mq5` - engine/trade/regime/range profiles; `AdaptiveCyclePeriod()`, `PrecisionTrend()`, `EfficiencyRatio()`, `StructureVote()`, `HurstExponent()`, `EvaluateRow()`, `ATRClosed()`, `UpdatePlanRow()`, trailing and lifecycle code.
- `documents.md` - shipped behaviour, deliberate stop-loss architecture, timer and panel contracts.
- `research/engine.py`, `research/validate.py`, `research/horizon_study.py`, `research/first_passage.py` - causal reference engine and horizon studies.
- `research/HORIZON.md` - reading life, forward-return and first-passage findings.

### Family source

- Emtt: `Emtt_DynamicParams.mqh`, `Emtt_Supertrend.mqh`, `Emtt_Learning.mqh`, `Emtt_ParamOpt.mqh`, `Emtt_ParamFile.mqh`, `README.md`.
- Autotrader: `SymbolIntelligence.mqh`, `DirectionEngine.mqh`, `ModernIndicators.mqh`, `TradeEngine.mqh`, `README.md`.
- Predict_X: `PX_OnlineAI.mqh`, `PX_Layer6_Neural.mqh`, `PXM_Book.mqh`, `PXM_Rehearse.mqh`.

### External method references

- Walk-forward optimisation, non-stationarity and overfitting: [1](https://www.quantbeckman.com/p/with-code-walk-forward-cvcl-optimization), [2](https://mathandmarkets.com/p/can-a-strategy-evolve-the-math-of), [7](https://blog.quantinsti.com/walk-forward-optimization-introduction/), [12](https://grokipedia.com/page/Walk_forward_optimization).
- Adaptive parameters and measurement-error trade-off: [3](https://www.luxalgo.com/library/concept/adaptive-parameter-technique/).
- Concept-drift detection and response discipline: [1](https://mlmonitoring.report/posts/concept-drift-detection-methods/).
- Hurst interpretation and finite-sample caution: [9](https://fractalcycles.com/guides/hurst-exponent-interpretation).
- Tick-level microstructure versus bar proxies: [1](https://www.mql5.com/en/articles/22938).
