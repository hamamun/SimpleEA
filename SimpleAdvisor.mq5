//+------------------------------------------------------------------+
//|                                              SimpleAdvisor.mq5   |
//|                     A very simple multi-timeframe direction panel |
//|                                                                  |
//|  Shows in plain words, for M5 (scalping), M15 (short-term) and    |
//|  M30 (intraday) on ANY symbol:                                   |
//|     Trend  = which way it is going (Going up / Going down /      |
//|              Sideways), and                                      |
//|     Regime = how it is moving (Steady / Mixed / Choppy),         |
//|  plus the original Signal (BUY / SELL / HOLD) and Score.         |
//|                                                                  |
//|  READ-ONLY OR LIVE?  The PANEL itself only reads price history    |
//|  and draws text.  The EXECUTOR that ships with it DOES send       |
//|  orders when InpAutoTrading = true - the shipped default.  Set    |
//|  it to false for advice only, and nothing is ever sent.           |
//|                                                                   |
//|  With InpAutoTrading = false this program contains no trade       |
//|  calls at all: it cannot place, modify or close an order.         |
//|                                                                  |
//|  -----------------------------------------------------------------|
//|  SIGNAL ENGINE                                                    |
//|  -----------------------------------------------------------------|
//|  Three low-lag components are scored per timeframe.  Each one     |
//|  contributes +1 (bullish), -1 (bearish) or 0 (abstain):           |
//|                                                                  |
//|   1. TREND      Ehlers Precision Trend (TASC, September 2024)     |
//|                 Trend = HP3(price,L1) - HP3(price,L2)             |
//|                 The difference of two highpass filters is a       |
//|                 bandpass covering the timeframe's cycle band.     |
//|                 Highpass filters have almost no lag, so this      |
//|                 tracks turns far sooner than an EMA/SMA of equal  |
//|                 reach.  Vote = sign(Trend).                       |
//|                                                                  |
//|   2. MOMENTUM   Rate of change of the Precision Trend line.       |
//|                 The ROC is zero at every peak and trough of the   |
//|                 trend line, so its sign marks the onset or        |
//|                 continuation of a push.  Vote = sign(ROC).        |
//|                                                                  |
//|  3. STRUCTURE  Net move over the last STRUCT_PERIOD closed bars,  |
//|                silent unless it beats STRUCT_DEAD_ATR of ATR.     |
//|                Vote = sign(move).  It is deliberately its OWN     |
//|                measurement: three different measurements are      |
//|                what make 2/3 a real state - and 2/3 is the        |
//|                LIMIT order.                                       |
//|                                                                  |
//|  4. REGIME     Rolling Hurst exponent (long-memory estimate).     |
//|                Shown as Steady / Mixed / Choppy.  The score still |
//|                decides the would-be direction and order type; a   |
//|                separate operator switch may veto NEW entries      |
//|                while a row is Choppy:                             |
//|                  Steady / Mixed : a limit waits half an ATR back  |
//|                  Choppy, allowed: a limit waits at the box band   |
//|                                  or, with Range Mode off / a box  |
//|                                  that is unusable, half an ATR    |
//|                                  back                             |
//|                  Choppy, Off    : no new market or limit order    |
//|                A Choppy veto never closes a trade by itself: an   |
//|                already-open trade keeps its normal management.    |
//|                                                                  |
//|  Score = vote1 + vote2 + vote3      (range -3 .. +3)              |
//|      BUY  if score >= InpBuyScore     (+2 default)                |
//|      SELL if score <= InpSellScore    (-2 default)                |
//|      HOLD otherwise (the plan block says WHY - dead market,      |
//|                      score under the gate, or Choppy Trade Off)   |
//|  ORDER TYPE, once the Choppy permission allows the row:           |
//|      3/3 (all three agree) -> MARKET order, taken now             |
//|      2/3 (two agree)       -> LIMIT order, waiting for a price    |
//|      under the gate        -> nothing                             |
//|      Choppy + permission Off -> nothing, at 2/3 or 3/3            |
//|                                                                  |
//|  Kaufman's Efficiency Ratio acts as a dead-market gate: below     |
//|  ER_DEAD   the market is not travelling anywhere, so any          |
//|  directional read is meaningless and the row is forced to HOLD    |
//|  with "quiet - nothing worth trading" on the plan block.          |
//|                                                                  |
//|  Every calculation uses CLOSED bars only.  Nothing repaints and   |
//|  a historical direction never changes after the fact.             |
//|                                                                  |
//|  -----------------------------------------------------------------|
//|  CHART-TIMEFRAME RULE                                             |
//|  -----------------------------------------------------------------|
//|  The engine is calibrated for M5, M15 and M30 ONLY.  If the chart |
//|  is put on any other timeframe, no data is shown: the panel       |
//|  collapses to a single header line that says so -                 |
//|                                                                  |
//|     SimpleEA2.0 | Incompatible chart. Switch to M5/M15/M30.       |
//|                                                                   |
//|  -----------------------------------------------------------------|
//|  TRADE PLAN (advice only - NO ORDER IS EVER SENT)                 |
//|  -----------------------------------------------------------------|
//|  Under the three timeframe rows, separated by one line, comes a     |
//|  SECOND GROUP with one block per timeframe - M5, M15, M30 - in the  |
//|  same two-column style as the first: where to enter (market or      |
//|  pending, decided by the score), the lot size, the stop and the     |
//|  target (price, points, money and a rough bar count), and how many  |
//|  bars the reading is worth acting on - or, once a trade is open,    |
//|  how long it has run against that Reach estimate. A HOLD or         |
//|  waiting timeframe takes a single line, so the group is only as     |
//|  tall as its content.                                               |
//|                                                                  |
//|  Nothing is calculated at all while the chart is on a wrong       |
//|  timeframe, so no stale or out-of-context number can be read off  |
//|  the screen.  Switching the chart back to M5, M15 or M30 brings   |
//|  the full panel straight back.                                    |
//|  -----------------------------------------------------------------|
//|  AUTOTRADING & SECOND PANEL                                       |
//|  -----------------------------------------------------------------|
//|  Controlled by InpAutoTrading (default true, hands-free Full Auto |
//|  mode; set false for read-only advice).                           |
//|                                                                   |
//|   - Strictly 1 active trade/order per timeframe (M5, M15, M30)    |
//|     at a time, tracked by per-timeframe magic numbers.            |
//|   - Market order at score 3/3; Pending Limit order at score 2/3 -  |
//|     subject to InpAllowChoppyTrade.  Off vetoes every NEW order    |
//|     on a Choppy row; On lets InpRangeMode choose the 2/3 entry    |
//|     style (box band, or half an ATR back when Range Mode is off   |
//|     or the box is unusable).                                      |
//|   - M5 trades its own signal directly. M15/M30 are untied by      |
//|     default; tie them with InpRequireM15M30SameTrend = true.      |
//|   - New orders are placed ONLY on the close of that timeframe's  |
//|     own bar: attaching/restarting the EA, returning to a          |
//|     supported chart, a timer resume, or another timeframe's bar   |
//|     closing never places mid-bar - the next entry waits for the   |
//|     row's next closed bar.  Mid-bar ticks only manage open trades |
//|     (TP partial closes, SL/trailing modifies); they never enter.  |
//|   - Optional PC-local timer/pause: while OFF, no new orders are   |
//|     placed and pendings are cancelled; open trades stay managed.  |
//|     The header states the EFFECTIVE state ("Timer Pause", never   |
//|     the untouched input) plus a "Resume 2h14m" countdown to when  |
//|     placement is allowed again.  The input is never rewritten.    |
//|   - A second Main Panel header line shows Timer, Choppy Trade     |
//|     and M15/M30 Same Trend mode/status at a glance.               |
//|   - Three take-profit levels per order:                           |
//|        TP3 = 100% of SimpleEA's advised target points             |
//|        TP2 = 25% less than TP3 (75% of TP3)                       |
//|        TP1 = 25% less than TP2 (75% of TP2 = 56.25% of TP3)       |
//|   - Market order management:                                      |
//|        Automatic profit-protection SL floor (Trailstop On or Off):|
//|                   50% of TP1 -> locks SL +25% of TP1 ahead of     |
//|                   Entry; 100% of TP1 -> moves SL to +50% of TP1   |
//|                   ahead of Entry; TP2 -> locks SL at TP1 (100%).  |
//|        Before TP1 -> stepped trailstop (when Trailstop On): once  |
//|                   price covers the selected % of Entry->TP1, SL   |
//|                   steps +5% for every +5% of progress (Tight %    |
//|                   when not Steady, Steady % in a Steady trend;    |
//|                   gap widened x1.25 on M15, x1.50 on M30), always |
//|                   keeping whichever SL is tighter.                |
//|        TP1 hit -> moves SL to +50% of TP1 ahead of Entry (if      |
//|                   tighter than any trailed SL) and closes 70% of  |
//|                   lot (if lot > min lot).                         |
//|                   Watches score/direction: if score weakens or    |
//|                   flips, closes immediately; if strong, holds.    |
//|        TP2 hit -> reduces remaining lot to min lot (if > min lot) |
//|                   and locks SL to TP1; continues watching score.  |
//|        TP3 hit -> closes order in full.                           |
//|        Before TP1 -> if timeframe drops to HOLD while in profit,  |
//|                   closes immediately; an opposite signal or a     |
//|                   range box-break closes only while in profit     |
//|                   unless InpImmediateFlipClose = true (default    |
//|                   false: wait for profit, never bank the loss).   |
//|        New candle (same direction) -> updates TP1/TP2/TP3 and     |
//|                   tightens SL (never widens past initial risk).   |
//|   - Pending order management:                                     |
//|        New candle (same direction, score 2/3) -> updates Entry,   |
//|                   SL and TP1/TP2/TP3 to the new plan.             |
//|        Score upgrades to 3/3 (same direction) -> deletes pending  |
//|                   limit order and opens Market order immediately. |
//|        Direction changes / HOLD / Choppy veto / expiry -> cancels |
//|                   pending.  The veto never closes an open trade.  |
//|   - Second Panel ("Autotrading", right or bottom of Main Panel):  |
//|        Controlled by InpAutoPanelPos (Bottom default, or Right).  |
//|        Opens automatically when any market/pending order exists   |
//|        and closes completely when flat.                           |
//|        Header shows: Autotrading | Trailstop Off/On/Active        |
//|        | Stoploss On/Off | Symbol.                                |
//|        Each card shows TP1/TP2/TP3/SL prices (with USD) and       |
//|        the live gap to TP1 -> TP2 -> TP3 in points.               |
//|   - Calibration-health diary: every order SimpleEA places leaves  |
//|        one small record (score, regime, entry style, spread as a  |
//|        share of TP1, furthest progress to TP1, TP1/TP2/TP3,       |
//|        trailstop activation/lock/stop-exit/giveback and the final|
//|        result in planned-risk units).  The header adds             |
//|        today's S/W/L, each row gets one compact health label, and |
//|        only a Poor lane adds one problem + first-fix line.  The   |
//|        optional History panel (InpShowHealth, off by default)    |
//|        opens the diary up per timeframe.  The diary never changes |
//|        a setting by itself - it warns, and suggests what to test. |
//|  -----------------------------------------------------------------|
//|  HONEST NOTE ON EXPECTATION                                       |
//|  -----------------------------------------------------------------|
//|  This panel is a structured, low-lag reading of trend, momentum   |
//|  and regime.  It is NOT a proven profitable system.  Independent  |
//|  testing of direction signals on liquid FX shows hit rates close  |
//|  to 50%, and on M5 the typical edge is smaller than a retail      |
//|  spread.  The regime column is the part that carries real         |
//|  information: it tells you when NOT to act.  See README.md.       |
//+------------------------------------------------------------------+
#property copyright "SimpleEA"
#property version   "2.0"
#property description "SimpleEA 2.0: Multi-timeframe BUY/SELL/HOLD direction panel, trade plan, full-auto executor and calibration-health diary. M5 / M15 / M30 charts only."

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

enum ENUM_AUTO_PANEL_POS
{
   AUTO_POS_RIGHT  = 0, // Right
   AUTO_POS_BOTTOM = 1  // Bottom
};

//==================================================================
//  INPUTS
//==================================================================
input group "=== Autotrading & order management ==="
input bool                InpAutoTrading  = true;            // Autotrading (true = full auto, false = read-only)
//  Daily timer + one-shot pause, both on PC LOCAL time.  These gate
//  NEW placements only: while OFF, waiting pendings are cancelled and
//  already-open trades keep being managed (trail / TP / exits).
input bool                InpUseAutoSchedule = false;        // Use daily autotrading timer (PC local time)
input string              InpAutoStartTime   = "08:00";      // Autotrading start time (PC local HH:MM)
input string              InpAutoEndTime     = "17:00";      // Autotrading stop time (PC local HH:MM)
input int                 InpAutoOffHours    = 0;            // One-shot pause hours from when set (0=off, 48=2 days)
input bool                InpRequireM15M30SameTrend = false; // M15/M30 same trend required to place (false = untied)
input bool                InpImmediateFlipClose = false;     // Immediate close on direction/range flip (false = wait until the trade is in profit)
input bool                InpUseStopLoss  = false;           // Stoploss (true = place initial SL, false = only when trailstop / TP1 places it)
input bool                InpUseTrailStop = true;            // Pre-TP1 stepped trailstop (true = on, Entry->TP1 only)
input int                 InpTrailPctTight  = 40;            // Trailstop % when regime is NOT Steady (10-70)
input int                 InpTrailPctSteady = 55;            // Trailstop % in a Steady, clear trend (10-70)
input long                InpMagicBase    = 202610;          // Base magic number (+0 M5, +1 M15, +2 M30)

input group "=== Signal, Choppy permission & range mode ==="
input int      InpBuyScore    = 2;           // Score >= this  => BUY
input int      InpSellScore   = -2;          // Score <= this  => SELL

//  TWO DIFFERENT CHOPPY QUESTIONS, TWO DIFFERENT SWITCHES.
//  1) InpAllowChoppyTrade is PERMISSION: "may a row that currently reads
//     Choppy open a new trade at all?"  False vetoes both a 2/3 limit and
//     a 3/3 market order on that row and cancels a still-waiting pending
//     when its row turns Choppy.  It never closes an already-open trade.
//  2) InpRangeMode is ENTRY STYLE, consulted only after permission is
//     given: on a Choppy 2/3, true lets a usable box price the limit;
//     false (or an unusable box) uses the normal half-ATR pullback.
//  InpBuyScore / InpSellScore still gate every order in every regime
//  (ScoreAllowsTrade()), and the score still picks the order type:
//  3/3 -> market, 2/3 -> limit.  The Main Panel's "Choppy Trade" value
//  mirrors the PERMISSION switch, because that is what its words mean.
input bool     InpAllowChoppyTrade = true;   // Allow Choppy trade (false = no NEW orders while a row is Choppy)
//  What the regime adds, once permission is given, is where a LIMIT
//  waits: on a Choppy row (H below the revert threshold - moves genuinely
//  come back) Range Mode lets the box band price the limit (entry at the
//  band, target = the midpoint, stop = band + 1 ATR); on a Steady or
//  Mixed row it waits half an ATR back from the market.  Every box
//  number is a gate, not a guess; a box that fails one simply hands the
//  limit back to the half-ATR pullback.
//  The six numbers that define the box were inputs too until they stopped
//  earning a decision - they are calibration, so they now live in THE
//  RANGE PROFILE below, one value for all three timeframes, exactly like
//  the trade profile.
input bool     InpRangeMode    = true;       // Range mode: box-band entry for an ALLOWED Choppy 2/3 (default ON)

//  (No engine-settings group: the Precision Trend periods, the Hurst
//  window and the efficiency-ratio numbers are STANDARD - they are the
//  tested calibration, not user preferences, so since v2.12 they live
//  in THE ENGINE PROFILE in INTERNALS below and SimpleEA applies them
//  automatically to all three rows.  See that block to recalibrate.)

input group "=== Trade plan & sizing ==="
//  Sizing is one switch and one number:
//     InpUseRisk  = true   -> risk InpRiskPct % of balance (score 3: double)
//     InpUseRisk  = false  -> no risk % is applied: a fixed lot ladder,
//                             0.01 lot per 1,000 of balance (score 3: x1.5)
//     InpUseMinLot = true  -> overrides both: always the symbol's min lot
//  The ladder's two numbers and the score-3 multiplier are baked in -
//  they define the fallback, they are not a dial to tune.
input bool     InpUseRisk      = true;       // Allow risk (false = no risk %, fixed lot ladder)
input double   InpRiskPct      = 0.5;        // Risk % per trade (score 3 risks double)
input bool     InpUseMinLot    = false;      // Always advise the symbol's minimum lot

input group "=== Market closed detection ==="
//  While the symbol cannot be traded (weekend, daily break, symbol halt)
//  the panel collapses to the same two-line widget the unsupported chart
//  uses - header plus a red "Market Closed" notice - and the auto-trader
//  stands down until the market opens again.
input bool     InpDetectClosed   = true;     // Detect a closed market, collapse the panel to "Market Closed"
input int      InpClosedStaleMin = 30;       // Also closed: no quote for this many minutes (0 = off)

input group "=== Panels & appearance ==="
input int      InpPanelX      = 12;          // Panel X offset (px)
input int      InpPanelY      = 24;          // Panel Y offset (px)
input ENUM_AUTO_PANEL_POS InpAutoPanelPos = AUTO_POS_BOTTOM; // Right panel placement (Right or Bottom)
//  The calibration diary below records whether the big History panel is
//  shown or not.  This switch only opens that third panel; turning it
//  on later therefore shows history that was already being collected.
input bool     InpShowHealth   = false;    // Show History panel (diary always records)
input int      InpFontSize    = 10;          // Font size
input string   InpFont        = "Consolas";  // Font (monospaced aligns best)
input color    InpBgColor     = C'48,48,48'; // Panel background
input color    InpTitleColor  = clrWhite;    // Title colour
input color    InpBuyColor    = clrLime;     // "Going up" colour
input color    InpSellColor   = clrTomato;   // "Going down" colour
input color    InpHoldColor   = clrSilver;   // "Sideways" colour

//==================================================================
//  INTERNALS
//==================================================================
#define OBJ_PREFIX  "SA_"
#define AUTO_PREFIX "SA2_"
#define HIST_PREFIX "SA3_"
#define PANEL_TITLE "SimpleEA2.0"
#define TF_COUNT    3
#define TF_TEXT     "M5/M15/M30"
#define TRAIL_STEP_PCT 5.0   // pre-TP1 trailstop: SL jumps this many % per step of progress

//  ---- THE ENGINE PROFILE (baked in: the standard engine) -----------
//  These five were the "Shared engine settings" inputs until v2.11.
//  They are standard now, for the same reason as the three profiles
//  below: none of them is a user preference - they are the calibration
//  the signal engine was measured with, and a wrong value silently
//  changes the strategy instead of a convenience.  So SimpleEA simply
//  applies them itself: one filter for all three rows, M5, M15 and M30
//  each running the same periods on its own timeframe's bars.
//  ConfigureRow() in OnInit() hands each row its own copy, so a
//  timeframe that genuinely needs its own eyes can still get them in
//  code - passing a different period for one row costs one line and
//  touches nothing else.  The history pull (BarsNeeded) grows itself
//  if a value here is ever raised.  The two trend periods are the one
//  genuinely symbol-sensitive pair: if a symbol class is ever measured
//  to need its own, the fix is a per-row value at ConfigureRow() time,
//  decided by the EA - not a return to user knobs.  ER_PERIOD matches
//  RANGE_BARS on purpose (the E/R reads the box's own bars), and
//  ER_DEAD is an absolute dead-market gate, never a relative one.
#define TREND_L1        150       // Precision Trend long period  (all timeframes)
#define TREND_L2        24        // Precision Trend short period (all timeframes)
#define HURST_WINDOW    256       // Hurst estimate window (bars, each timeframe's own)
#define ER_PERIOD       20        // Kaufman efficiency-ratio period (= RANGE_BARS)
#define ER_DEAD         0.10      // efficiency below this => dead market, force HOLD
//  ---- THE THIRD VOTE (structure) ----------------------------------
//  The score is three votes, and they must be three DIFFERENT
//  measurements, or a "2 of 3" reading can never happen.  Vote 3 is the
//  net move over the last STRUCT_PERIOD closed bars - the same window
//  the efficiency ratio and the range box use - and it stays silent
//  unless that move is worth more than STRUCT_DEAD_ATR ATR, so a market
//  that has not actually travelled votes 0 instead of +1/-1 on noise.
#define STRUCT_PERIOD   20        // structure vote: net move over this many closed bars
#define STRUCT_DEAD_ATR 0.25      // ...and it must beat this many ATR to vote at all
#define ROC_DEAD_ATR    0.02      // Vote 2 (ROC) dead-band: must beat 0.02 x ATR to avoid sub-pip flickering
#define VOL_RATIO_MIN   0.50      // minimum tick volume vs 20-bar avg to permit aggressive 3/3 market orders

//  ---- THE TRADE PROFILE (baked in: this is the tested set) ----------
//  These were inputs until they stopped earning a decision.  None of
//  them is a user preference - they are the calibration the engine was
//  measured with, and a wrong value here silently changes the strategy
//  rather than a convenience.  Stop and target are still PER TIMEFRAME,
//  so the three styles keep their aim: a scalp aims near and quick, an
//  intraday trade aims far and lets the move run.
#define ATR_PERIOD      14        // ATR period, closed bars, each timeframe's own
#define SL_ATR_M5       1.0       // M5  scalp:       stop   = this many ATR
#define TP_ATR_M5       0.9       // M5  scalp:       target = this many ATR (R:R 1:0.9)
#define SL_ATR_M15      1.2       // M15 short-term:  stop   = this many ATR
#define TP_ATR_M15      1.8       // M15 short-term:  target = this many ATR (R:R 1:1.5)
#define SL_ATR_M30      1.5       // M30 intraday:    stop   = this many ATR
#define TP_ATR_M30      3.0       // M30 intraday:    target = this many ATR (R:R 1:2.0)
//  ---- THE REGIME PROFILE (baked in: the tested boundaries) -----------
//  Same reasoning as the block above, and for once the numbers are not
//  even a calibration: H is a property of the series, not of the symbol.
//  H > 0.5 means moves remember each other, H < 0.5 means they undo each
//  other, and 0.55 / 0.45 is the band the literature uses either side of
//  the 0.5 coin-flip before it will call a regime at all (SIGNAL_LOGIC.md
//  section 4).  Nothing about gold, or about M5, moves those numbers -
//  only a different estimator would - so they are not a dial.  The window
//  the estimate is taken over (HURST_WINDOW in THE ENGINE PROFILE above)
//  is standard for the same reason: 256 bars is five days on M30 and two
//  days on M5, and the estimator needs that many bars to be stable on
//  every row.  Widen the band here and the panel goes quieter; narrow it
//  and it trades more - which is exactly why it is not a user input.
#define HURST_TREND     0.55      // H above this = persistent: Steady
#define HURST_REVERT    0.45      // H below this = anti-persistent: Choppy (box-priced limits)

//  ---- THE RANGE PROFILE (baked in: the tested box geometry) ----------
//  Same reasoning as the two blocks above: these are the calibration the
//  box trade was measured with, one set for all three timeframes, and
//  none of them is a preference.  They used to be six inputs; only the
//  on/off switch is still one.  If your broker's spread is genuinely
//  not the one this was measured on, the single number worth
//  re-exposing is RANGE_SPREAD_X - the cost gate is the only one that
//  is account-specific rather than a property of the price series.
#define RANGE_BARS      20        // range box = the last N closed bars' highs/lows
#define RANGE_SL_ATR    1.0       // range stop = opposite band + this many ATR
#define RANGE_MIN_RR    1.0       // box must be tall enough that half-box >= stop risk
//  The height gate is DERIVED, never typed twice: half the box is the
//  target (box/2 ATR) and the stop is RANGE_SL_ATR, so requiring
//  half-box >= RANGE_MIN_RR x stop is the same as box >= 2 x 1.0 x 1.0
//  ATR.  Change RANGE_SL_ATR and the height floor follows it; the RR
//  cannot silently drop because two numbers drifted apart.
#define RANGE_MIN_ATR   (2.0 * RANGE_SL_ATR * RANGE_MIN_RR)
#define RANGE_SPREAD_X  3.0       // half-box target must clear at least this many spreads
#define RANGE_ER_MAX    0.40      // efficiency above this = a walk, not a box
//  NOT HURST_REVERT on purpose: H reads ~256 bars of memory, the E/R
//  reads the box's own 20.  Reusing 0.45 here would let 0.40-0.45 walks
//  in as boxes - a different question, a different window.
#define RANGE_VALID_BARS 8        // range fade leash in bars (the box-kill is the real guard)

#define PEND_ATR        0.5       // pending entry sits this many ATR from the market
#define VALID_BARS      3         // trend reading's leash in bars (research/HORIZON.md)
#define RISK_SCORE3_X   2.0       // score 3 risks this multiple of the score-2 percentage
#define BAL_PER_001     1000.0    // risk-off mode: balance per 0.01 lot
#define SCORE3_FACTOR   1.5       // risk-off mode: lot multiplier at score 3
#define HEAD_H      34     // height of a ONE-LINE header band (notice + 2nd Panel)
#define STATUS_LINE_C 71   // widest Main Panel mode-status line, in characters
#define PLAN_W_MIN  406    // panel width with no plan showing
#define PLAN_LINES  3      // lines an ACTIVE timeframe uses (1 for HOLD)
//  The three column anchors are the FONT-9 design, not raw pixels: ColX()
//  scales them by em / em(9), so they are the same columns at every font
//  size and the two groups keep lining up.  PLAN_LBL_C is what guarantees
//  the gap - a value starts 8 characters (widest caption + a space) after
//  its label.
#define PLAN_COL_A  150    // first cell column: aligns with "Trend:" above
#define PLAN_COL_B  282    // second cell column: aligns with "Regime:" above
#define PLAN_COL_C  414    // third cell column: used by the "Valid" cell
#define PLAN_LBL_C  8      // widest label in a column, in characters
#define PLAN_SEP_H  14     // gap between the last timeframe row and the plan

#define AUTO_GAP_X  10     // horizontal gap when 2nd Panel is on the Right
#define AUTO_GAP_Y  10     // vertical gap when 2nd Panel is at the Bottom
#define AUTO_W_MIN  420    // minimum width for the 2nd Panel
#define AUTO_LINES  4      // lines per active trade/order card in the 2nd Panel
#define AUTO_SEP_H  10     // gap between cards in the 2nd Panel
#define AUTO_COL_A  150    // first cell column in the 2nd Panel (font-9 anchors,
#define AUTO_COL_B  320    // second cell column - scaled by ColX() like the
#define AUTO_COL_C  480    // third cell column - main panel's columns)
#define AUTO_LBL_A  9      // label width in chars for Col A ("Waiting: ")
#define AUTO_LBL_B  11     // label width in chars for Col B ("Distance: ")
#define AUTO_LBL_C  5      // label width in chars for Col C ("Ask: " / "Bid: ")

#define HIST_W_MIN  620    // minimum width for the optional History panel

//  ---- THE CALIBRATION-HEALTH PROFILE (baked in, like the engine) ---
//  Health is a judgement about evidence, not a user preference, so
//  none of these is an input.  A lane is "Learning" until it owns 30
//  fully closed diary trades; those 30 are then compared with the 30
//  before them when they exist.  Subset verdicts (2/3 vs 3/3, box vs
//  the rest) have their own floors so a handful of trades can never
//  be promoted into a warning.  A result inside +/-0.05R is a scratch.
#define DIARY_VERSION        1
#define HEALTH_MIN_CLOSED    30
#define HEALTH_RECENT_N      30
#define HEALTH_BASE_N        30
#define HEALTH_SCORE_MIN_EACH 10
#define HEALTH_STYLE_MIN_EACH 15
#define HEALTH_BE_EPS_R      0.05

//  HISTORY DEPTH (no input - the engine sizes its own pull)
//  BARS_BASE is the smallest pull and is enough for the default
//  calibration.  BarsNeeded() raises it automatically whenever the
//  user's own periods ask for more history than the base provides.
#define BARS_BASE      700   // lowest number of closed bars pulled per timeframe
#define BARS_WARMUP_X  4     // recursive filter warm-up: multiples of the longest period
#define BARS_MAX       50000 // hard ceiling so a typo cannot ask for absurd history

//  The only chart timeframes this engine is calibrated for.  Anything else
//  is refused outright - see the CHART-TIMEFRAME RULE block in the header
//  and the "Incompatible chart" notice below.
#define TIMEFRAME_OK(tf) ((tf) == PERIOD_M5 || (tf) == PERIOD_M15 || (tf) == PERIOD_M30)

struct SRow
{
   ENUM_TIMEFRAMES tf;        // timeframe
   string         tag;        // "M5"
   string         style;      // "Scalp"
   int            l1;         // trend filter long period
   int            l2;         // trend filter short period
   double         hTrend;     // Hurst persistent threshold
   double         hRevert;    // Hurst anti-persistent threshold
   double         slAtr;      // stop loss   = this many ATR (per timeframe)
   double         tpAtr;      // take profit = this many ATR (per timeframe)
   // ---- the entry style and the reason, per row -----------------------
   int            mode;       // 0 plain limit/market entry, 2 the box prices the limit
   bool           choppyBlocked;// score direction exists, but InpAllowChoppyTrade=false
                                // on a Choppy row forbids a NEW entry (open trades stay managed)
   string         blockReason;// why this row is not trading ("" = quiet or no reason)
   double         rngTop;     // range box: upper band (valid while mode == 2)
   double         rngBot;     // range box: lower band (valid while mode == 2)
   double         lastClose;  // close of the last closed bar (box-kill checks)
   // ---- refreshed every evaluation ----
   int            score;      // -3 .. +3
   int            direction;  // +1 buy, -1 sell, 0 hold  (what the row TRADES)
   int            trendDir;   // +1 up, -1 down, 0 flat    (what the TREND line reads)
   double         hurst;      // regime estimate
   double         er;         // efficiency ratio
   bool           ok;         // data available?
   datetime       lastBar;    // last closed bar we have seen
   datetime       sigBirth;   // closed bar where the current idea/leash was born
};

SRow g_rows[TF_COUNT];

int  g_panelW  = 406;   // wide enough for the header + the notice line
int  g_panelH  = 130;   // height of the full panel (recomputed in OnInit)
int  g_rowH    = 20;
bool g_panelOK = false; // what is currently drawn: false = notice only
//  Rows whose OWN timeframe printed a new closed bar in the current
//  CheckNewBars() pass.  This is the one permission slip for placing a
//  NEW order: PlacePlanOrder() refuses every row not marked here, so
//  ManageAutoBar() calls that did not come from a fresh bar of that
//  row (OnInit, the !g_panelOK rebuild, a timer resume, or another
//  timeframe's close) can manage, close and cancel but can never open.
//  In-memory only on purpose: a restart must re-earn the slip.
bool g_freshBar[TF_COUNT];
datetime g_srvSaidClosedUntil = 0;  // server said "market closed": trust it for a while

//  Autotrading timer (PC local) + one-shot pause state.  The pause
//  deadline itself is kept in GMT (an elapsed duration), while the
//  daily start/stop are read against the PC/VPS local clock.
int      g_schedStartMin    = -1;   // daily start, minutes since local midnight
int      g_schedEndMin      = -1;   // daily stop,  minutes since local midnight
datetime g_pauseUntilGMT    = 0;    // one-shot pause deadline (GMT), 0 = none
string   g_pauseGVUntil     = "";   // GlobalVariable holding the deadline
string   g_pauseGVReq       = "";   // GlobalVariable holding the requested hours
bool     g_timerStateInit   = false;
bool     g_timerWasAllowed  = false; // last observed timer placement state
ulong    g_lastPendCancelTryMs = 0;  // throttled pending-cancel retries while OFF
int      g_resumeMinsShown  = -1;    // "Resume ..." minute currently on the panel

ENUM_TIMEFRAMES g_drawnTf = (ENUM_TIMEFRAMES)0;  // timeframe the header was drawn for

//+------------------------------------------------------------------+
//  HOW MANY CLOSED BARS THIS BUILD ACTUALLY NEEDS
//
//  Every consumer of history has a minimum:
//     - Hurst          : its window, walked with block averages
//     - PrecisionTrend : a recursive high-pass filter - it converges
//                        over several multiples of the LONGEST period
//     - E/R, ATR, range box : a handful of bars each
//
//  The pull is the largest of those, never below BARS_BASE.  So the
//  standard profile keeps pulling 700, but raising the Hurst window to
//  900 or a trend period to 400 in THE ENGINE PROFILE raises the pull
//  automatically - there is nothing to remember to change alongside it.
//+------------------------------------------------------------------+
int BarsNeeded()
{
   int need = BARS_BASE;

   //  The trend filter's long period (shared by all three timeframes).
   //  Clamped BEFORE the multiply, so a typo (L1 = 900,000,000) cannot
   //  overflow the int and hand the loader a negative count.
   int l1max = TREND_L1;
   if(l1max < 1)          l1max = 1;
   if(l1max > BARS_MAX)   l1max = BARS_MAX;
   int l1need = MathMin(BARS_MAX, BARS_WARMUP_X * l1max);
   if(l1need > need) need = l1need;

   //  Hurst window plus margin for the block averaging (same guard).
   int hneed = HURST_WINDOW;
   if(hneed < 32)         hneed = 32;
   if(hneed > BARS_MAX)   hneed = BARS_MAX;
   if(hneed + 50 > need)  need = hneed + 50;

   //  Short lookbacks: only matter if someone sets them very large.
   if(RANGE_BARS    + 5 > need) need = RANGE_BARS    + 5;
   if(ATR_PERIOD    + 5 > need) need = ATR_PERIOD    + 5;
   if(ER_PERIOD     + 5 > need) need = ER_PERIOD     + 5;

   if(need > BARS_MAX) need = BARS_MAX;
   return(need);
}

//==================================================================
//  SETUP
//==================================================================
void ConfigureRow(int i, ENUM_TIMEFRAMES tf, string tag, string style,
                  int l1, int l2, double hTrend, double hRevert,
                  double slAtr, double tpAtr)
{
   g_rows[i].tf      = tf;
   g_rows[i].tag     = tag;
   g_rows[i].style   = style;
   g_rows[i].l1      = l1;
   g_rows[i].l2      = l2;
   g_rows[i].hTrend  = hTrend;
   g_rows[i].hRevert = hRevert;
   g_rows[i].slAtr   = slAtr;
   g_rows[i].tpAtr   = tpAtr;
   g_rows[i].score      = 0;
   g_rows[i].direction  = 0;
   g_rows[i].trendDir   = 0;
   g_rows[i].hurst      = 0.5;
   g_rows[i].er         = 0.0;
   g_rows[i].mode       = 0;
   g_rows[i].choppyBlocked = false;
   g_rows[i].blockReason = "";
   g_rows[i].rngTop     = 0.0;
   g_rows[i].rngBot     = 0.0;
   g_rows[i].lastClose  = 0.0;
   g_rows[i].ok         = false;
   g_rows[i].lastBar    = 0;
   g_rows[i].sigBirth   = 0;
}

//+------------------------------------------------------------------+
int OnInit()
{
   //  One filter, one regime test, three timeframes: each row gets the
   //  shared numbers and applies them to its own closed bars.  (Give a
   //  row different numbers here and only that row changes.)
   ConfigureRow(0, PERIOD_M5,  "M5",  "Scalp",      TREND_L1, TREND_L2,
                HURST_TREND,    HURST_REVERT,    SL_ATR_M5,  TP_ATR_M5);
   ConfigureRow(1, PERIOD_M15, "M15", "Short-term", TREND_L1, TREND_L2,
                HURST_TREND,    HURST_REVERT,    SL_ATR_M15, TP_ATR_M15);
   ConfigureRow(2, PERIOD_M30, "M30", "Intraday",   TREND_L1, TREND_L2,
                HURST_TREND,    HURST_REVERT,    SL_ATR_M30, TP_ATR_M30);

   //  The trend periods are baked in (THE ENGINE PROFILE), so this can
   //  only trip for someone who has just edited them the wrong way round.
   if(TREND_L1 < TREND_L2)
   {
      Print("SimpleEA: the long trend period must be greater than the short one. ",
            "Set TREND_L1 > TREND_L2 in THE ENGINE PROFILE.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   //  The regime boundaries are baked in, so this can only trip for
   //  someone who has just edited HURST_TREND / HURST_REVERT above - which
   //  is exactly when a plain sentence beats a panel that labels every
   //  market as both Steady and Choppy at once.
   if(HURST_REVERT > HURST_TREND)
   {
      Print("SimpleEA: the anti-persistent threshold must sit below the persistent one. ",
            "Set HURST_REVERT < HURST_TREND.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   //  The two score gates must not overlap.  With BUY <= SELL a score
   //  that is both "high enough to buy" and "low enough to sell" would
   //  take the BUY branch first and the panel would call BUY forever,
   //  so the wrong pair is refused at load instead of traded.
   if(InpBuyScore <= InpSellScore)
   {
      PrintFormat("SimpleEA: InpBuyScore (%d) must be greater than InpSellScore (%d). "
                  "The score runs -3..+3, so a BUY gate of 2 and a SELL gate of -2 "
                  "is the default; the two must never cross.",
                  InpBuyScore, InpSellScore);
      return(INIT_PARAMETERS_INCORRECT);
   }

   //  Gates outside the reachable range are legal but can never fire;
   //  say so once instead of leaving a silently dead panel.
   if(InpBuyScore > 3 || InpSellScore < -3)
      PrintFormat("SimpleEA: note - the score only reaches -3..+3, so a gate of %d / %d "
                  "will never trigger.", InpBuyScore, InpSellScore);

   //  The risk percentage only matters while risk mode is on.  Zero or
   //  negative there would silently fall back to the minimum lot on every
   //  trade, so refuse it; anything above 5% is legal but worth a warning.
   //  With InpUseRisk=false the ladder ignores the number entirely, so it
   //  is not validated - an unused value must not stop the EA loading.
   if(InpUseRisk && InpRiskPct <= 0.0)
   {
      Print("SimpleEA: InpRiskPct must be greater than 0 - it is the percentage "
            "of balance risked per trade (0.5 is the default, score 3 risks double).");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(InpUseRisk && InpRiskPct > 5.0)
      PrintFormat("SimpleEA: note - risking %.2f%% per trade (%.2f%% at score 3) is "
                  "far above the shipped 0.5%% / 1.0%%.", InpRiskPct,
                  InpRiskPct * RISK_SCORE3_X);

   if(!InitAutoTimer())
      return(INIT_PARAMETERS_INCORRECT);

   //  The standard engine, stated once so the log always records which
   //  calibration produced the reads (these are not inputs any more).
   PrintFormat("SimpleEA: standard engine - Precision Trend %d/%d, Hurst window %d bars, "
               "E/R %d with dead-market gate %.2f (all three timeframes).",
               TREND_L1, TREND_L2, HURST_WINDOW, ER_PERIOD, ER_DEAD);

   g_rowH   = InpFontSize + 11;
   // Each timeframe takes TWO lines: Trend/Regime on the first,
   // Signal (BUY/SELL/HOLD)/Score on the second.
   //  height is only provisional here: DrawSupportedPanel() recomputes it
   //  because the second group's height depends on how many timeframes
   //  actually have a signal.
   g_panelH = MainHeaderHeight() + TF_COUNT * 2 * g_rowH + 8;

   //  The notice is the one line that must always be readable in full, so
   //  the width that line needs is a floor for BOTH panels - the normal one
   //  and the notice one - whatever the font size.
   g_panelW = NoticeWidth();

   // Keep exclusive ownership for the entire run, not just during saves.
   // A second writer would have a stale in-memory copy of the diary.
   g_diaryLockHandle = FileOpen(DiaryFileName() + ".lock",
                               FILE_READ | FILE_WRITE | FILE_BIN |
                               (MQLInfoInteger(MQL_TESTER) ? 0 : FILE_COMMON));
   if(g_diaryLockHandle == INVALID_HANDLE)
   {
      Print("SimpleEA: diary is already in use or its lock cannot be opened. "
            "Stop the other EA using this account/symbol/magic, then retry.");
      return(INIT_FAILED);
   }
   DiaryInit();
   BuildPanel();
   InitAutoState();

   if(!ChartSupported())
   {
      //  Wrong chart timeframe: the panel is the header + notice and
      //  nothing else.  No history is pulled, no indicator is computed and
      //  no timeframe row is drawn, so there is nothing on screen that
      //  could be mistaken for a live read on this chart.
      PrintFormat("SimpleEA: the %s chart is not supported. This panel is calibrated "
                  "for %s only - switch the chart timeframe to see it.",
                  ChartTimeframeText(), TF_TEXT);
   }
   else if(MarketClosed())
   {
      PrintFormat("SimpleEA: %s is not trading at the moment - the panel shows "
                  "Market Closed and the auto-trader stands down until it reopens.",
                  _Symbol);
   }
   else
   {
      EvaluateAll();
      UpdatePlan();
      ManageAutoBar();
      DiaryReconcileOpenRecords();
      //  Cells BEFORE the panel: DrawSupportedPanel() ends with DrawAutoPanel(),
      //  and DrawAutoPanel() positions itself from g_panelW - which is only
      //  final once DrawPanel() has run.  So the cell text is formatted here
      //  and the drawing (with the header's real width) happens below.
      UpdateAutoPanel();
   }

   //  DrawPanel() is the only place that chooses a layout, so the correct
   //  one is shown from the first moment, whichever chart this is.
   DrawPanel();

   //  The 2-second timer runs in both states.  On M5/M15/M30 the heavy work
   //  only runs when a new bar actually closes; on any other chart it does
   //  nothing at all except notice that the chart came back to M5/M15/M30.
   EventSetTimer(2);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   DiaryFlushOpenSlots();
   if(g_diaryLockHandle != INVALID_HANDLE)
   {
      FileClose(g_diaryLockHandle);
      g_diaryLockHandle = INVALID_HANDLE;
   }
   DeletePanel();
}

//+------------------------------------------------------------------+
void OnTick()
{
   //  Goes through CheckNewBars() even on an unsupported chart, so that a
   //  live timeframe change is caught whether or not MetaTrader re-started
   //  the EA for it.  On a wrong chart that call costs one comparison.
   CheckNewBars();
   CheckAutoTimerTransition();
   CheckDiaryDayTransition();

   //  Real-time tick checks for TP1/TP2/TP3 partial closes, break-even SL,
   //  and live Ask/Bid/P&L updates on the 2nd Panel.
   if(ChartSupported() && g_panelOK)
      ManageAutoTick();
}

//+------------------------------------------------------------------+
void OnTimer()
{
   CheckNewBars();
   CheckAutoTimerTransition();
   CheckDiaryDayTransition();
   if(ChartSupported() && g_panelOK)
      ManageAutoTick();
}

//==================================================================
//  REFRESH
//==================================================================
//  Recompute only when a tracked timeframe prints a new closed bar.
//+------------------------------------------------------------------+
void CheckNewBars()
{
   //  The safety net for a live timeframe change (MetaTrader normally
   //  re-initialises the EA, but this makes the rule airtight): the moment
   //  the chart leaves M5/M15/M30 the panel is replaced by the notice, and
   //  the moment it comes back the full panel returns.
   if(!ChartSupported())
   {
      //  Wrong chart timeframe.  Redraw only when there is something to
      //  correct: the data panel has to be replaced by the notice, or the
      //  notice is showing the wrong timeframe name because the chart moved
      //  between two unsupported timeframes.  Otherwise this is one
      //  comparison and nothing else - no history, no indicators.
      if(g_panelOK || g_drawnTf != (ENUM_TIMEFRAMES)Period())
      {
         DrawPanel();
         ChartRedraw(0);
      }
      return;
   }

   //  The market itself is shut (weekend, daily break, symbol halt):
   //  collapse to the "Market Closed" notice exactly like an unsupported
   //  chart, and stand down until it reopens.  The flip is drawn once;
   //  while closed this branch is one cheap check per timer tick - no
   //  history, no indicators, no orders.
   if(MarketClosed())
   {
      if(g_panelOK)
      {
         DrawPanel();
         ChartRedraw(0);
         Print("SimpleEA: ", _Symbol, " is closed - the panel shows Market Closed until it reopens.");
      }
      return;
   }

   bool need = false;

   //  Work out, for EVERY row, whether its own timeframe just printed a
   //  new closed bar - before EvaluateAll() overwrites g_rows[].lastBar.
   //  A row only counts as fresh when it was already being tracked
   //  (panel live, a real baseline bar): a bar that closed while the
   //  chart sat on an unsupported timeframe, or the first bar ever seen
   //  after (re)attach, is a catch-up sighting, not a fresh close, so
   //  it earns no placement slip.
   for(int i = 0; i < TF_COUNT; i++)
   {
      datetime closedBar = LastClosedBarTime(_Symbol, g_rows[i].tf);
      if(closedBar != g_rows[i].lastBar)
         need = true;
      g_freshBar[i] = (g_panelOK && g_rows[i].lastBar > 0 &&
                       closedBar > 0 && closedBar != g_rows[i].lastBar);
   }

   //  Coming back onto M5/M15/M30 after an unsupported timeframe: rebuild
   //  from the current data instead of showing whatever was last computed.
   //  g_freshBar[] is all false here (the panel was the notice), so this
   //  pass manages what exists but places nothing mid-bar.
   if(!g_panelOK)
   {
      EvaluateAll();
      UpdatePlan();
      ManageAutoBar();
      UpdateAutoPanel();
      DrawPanel();
      ChartRedraw(0);
      return;
   }

   if(need)
   {
      EvaluateAll();
      UpdatePlan();
      ManageAutoBar();
      //  The slip is spent: any ManageAutoBar() call later in this same
      //  tick (e.g. a timer resume) must not re-use it.
      ArrayInitialize(g_freshBar, false);
      UpdateAutoPanel();
      DrawPanel();
      ChartRedraw(0);
   }
}

//+------------------------------------------------------------------+
//  Time of the most recently CLOSED bar on a timeframe, or 0 if unknown.
//  Uses shift 1 so it always retrieves the finished candle, never the
//  currently forming live bar.
//+------------------------------------------------------------------+
datetime LastClosedBarTime(string sym, ENUM_TIMEFRAMES tf)
{
   datetime times[];
   if(CopyTime(sym, tf, 1, 1, times) == 1)
      return(times[0]);
   return(0);
}

//==================================================================
//  DATA ACCESS
//==================================================================
//  Copies `count` CLOSED bars into chronological arrays:
//      index 0          = oldest closed bar
//      index count - 1  = most recently closed bar
//  The still-forming bar (series index 0) is deliberately excluded, which
//  is what makes the whole panel non-repainting.
//
//  MQL5 series arrays are indexed newest-first, so the closed bars sit at
//  series indices 1 .. count.  Reversing them into chronological order is
//  simply c[i] = series[count - i]:
//      i = 0          -> series[count] = oldest closed   OK
//      i = count - 1  -> series[1]     = newest closed   OK
//+------------------------------------------------------------------+
bool LoadClosed(string sym, ENUM_TIMEFRAMES tf, int count,
                double &close[], double &high[], double &low[])
{
   double sc[], sh[], sl[];
   ArraySetAsSeries(sc, true);
   ArraySetAsSeries(sh, true);
   ArraySetAsSeries(sl, true);

   if(CopyClose(sym, tf, 0, count + 1, sc) < count + 1) return(false);
   if(CopyHigh (sym, tf, 0, count + 1, sh) < count + 1) return(false);
   if(CopyLow  (sym, tf, 0, count + 1, sl) < count + 1) return(false);

   ArrayResize(close, count);
   ArrayResize(high,  count);
   ArrayResize(low,   count);
   ArraySetAsSeries(close, false);
   ArraySetAsSeries(high,  false);
   ArraySetAsSeries(low,   false);

   for(int i = 0; i < count; i++)
   {
      close[i] = sc[count - i];
      high[i]  = sh[count - i];
      low[i]   = sl[count - i];
   }
   return(true);
}

//==================================================================
//  COMPONENT 1 + 2 : EHLERS PRECISION TREND AND ITS ROC
//==================================================================
//  HighPass3, transcribed from John Ehlers' own TradeStation listing in
//  TASC September 2024, "Precision Trend Analysis":
//
//     a1 = ExpValue(-1.414 * 3.14159 / Period)
//     b1 = 2 * a1 * Cosine(1.414 * 180 / Period)   ' Cosine() takes DEGREES
//     c2 = b1 ; c3 = -a1*a1 ; c1 = (1 + c2 - c3) / 4
//     HP = c1*(P - 2*P[1] + P[2]) + c2*HP[1] + c3*HP[2]
//
//  1.414 * 180 / Period degrees is exactly 1.414 * pi / Period radians,
//  which is what MathCos() expects, so the degree-to-radian conversion is
//  already accounted for.  (Some published ports convert it twice and end
//  up with the filter centred on the wrong frequency.)
//+------------------------------------------------------------------+
void HighPass3(const double &price[], int period, double &hp[])
{
   int n = ArraySize(price);
   ArrayResize(hp, n);
   ArrayInitialize(hp, 0.0);
   if(n < 3 || period < 2) return;

   double f  = 1.414 * M_PI / (double)period;
   double a1 = MathExp(-f);
   double c2 = 2.0 * a1 * MathCos(f);
   double c3 = -a1 * a1;
   double c1 = (1.0 + c2 - c3) / 4.0;

   for(int i = 2; i < n; i++)
      hp[i] = c1 * (price[i] - 2.0 * price[i - 1] + price[i - 2])
            + c2 * hp[i - 1]
            + c3 * hp[i - 2];
}

//+------------------------------------------------------------------+
//  Measure the dominant market cycle period from closed bars using a
//  3-pole HighPass filter and zero-crossing wavelength analysis.
//  Clamped to a realistic cycle band [14, 36], centered around 24.
//+------------------------------------------------------------------+
int AdaptiveCyclePeriod(const double &close[], int count, int lookback = 120)
{
   if(count < 40) return(TREND_L2);

   double hp[];
   HighPass3(close, 40, hp);

   int start = MathMax(2, count - lookback);
   int crossIdx[];
   int numCross = 0;

   for(int k = start + 1; k < count; k++)
   {
      if((hp[k - 1] <= 0.0 && hp[k] > 0.0) || (hp[k - 1] >= 0.0 && hp[k] < 0.0))
      {
         ArrayResize(crossIdx, numCross + 1);
         crossIdx[numCross] = k;
         numCross++;
      }
   }

   if(numCross >= 3)
   {
      int diffs[];
      int numDiffs = numCross - 1;
      ArrayResize(diffs, numDiffs);
      for(int j = 0; j < numDiffs; j++)
         diffs[j] = crossIdx[j + 1] - crossIdx[j];

      ArraySort(diffs);
      int medianHalf = diffs[numDiffs / 2];
      int cycle = (int)MathRound((double)medianHalf * 2.0);
      return((int)MathMax(14, MathMin(36, cycle)));
   }

   return(TREND_L2);
}

//+------------------------------------------------------------------+
void PrecisionTrend(const double &close[], int l1, int l2,
                    double &trend[], double &roc[])
{
   int n = ArraySize(close);

   double hp1[], hp2[];
   HighPass3(close, l1, hp1);
   HighPass3(close, l2, hp2);

   ArrayResize(trend, n);
   ArrayResize(roc,   n);
   for(int i = 0; i < n; i++)
   {
      trend[i] = hp1[i] - hp2[i];
      roc[i]   = (i > 0) ? (l2 / 6.28) * (trend[i] - trend[i - 1]) : 0.0;
   }
}

//==================================================================
//  KAUFMAN EFFICIENCY RATIO
//==================================================================
//   ER = |close[i] - close[i-n]| / SUM |close[k] - close[k-1]|
//   1.0 = straight directional travel, 0.0 = pure noise.
//+------------------------------------------------------------------+
double EfficiencyRatio(const double &close[], int i, int n)
{
   if(i < n || n < 1) return(0.0);

   double path = 0.0;
   for(int k = i - n + 1; k <= i; k++)
      path += MathAbs(close[k] - close[k - 1]);

   if(path <= 0.0) return(0.0);
   return(MathAbs(close[i] - close[i - n]) / path);
}

//==================================================================
//  COMPONENT 3 : STRUCTURE VOTE  (the independent third opinion)
//==================================================================
//     move = close[i] - close[i - STRUCT_PERIOD]
//     move >  +dead  -> +1      (the window travelled up)
//     move <  -dead  -> -1      (the window travelled down)
//     otherwise      ->  0      (no travel worth voting on)
//  where dead = STRUCT_DEAD_ATR x ATR.
//
//  This is the vote that used to be a COPY of vote 1 in a Steady regime
//  and absent everywhere else, which is why a trend score of +/-2 could
//  never occur and every trend order was a market order at 3/3.  Being
//  its own measurement is what makes 2/3 (two of three agree) a real,
//  recurring state - and 2/3 is the state that places the LIMIT order.
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//  Structure Vote: Dow Theory Swing High/Low Structure + Net Move
//  Inspects swing points across the period window.
//  A Bullish vote (+1) requires positive displacement beating the deadband
//  AND no Lower Low structure break.
//  A Bearish vote (-1) requires negative displacement beating the deadband
//  AND no Higher High structure break.
//+------------------------------------------------------------------+
int StructureVote(const double &close[], const double &high[], const double &low[], int i, int period, double atr)
{
   if(period < 1 || i < period) return(0);

   double move = close[i] - close[i - period];
   double dead = (atr > 0.0) ? STRUCT_DEAD_ATR * atr : 0.0;

   if(MathAbs(move) <= dead) return(0);

   int start = MathMax(1, i - period + 1);
   double lastSwLow = 0.0, prevSwLow = 0.0;
   double lastSwHigh = 0.0, prevSwHigh = 0.0;
   int numSwLows = 0, numSwHighs = 0;

   for(int k = start; k < i; k++)
   {
      if(high[k] >= high[k - 1] && high[k] >= high[k + 1])
      {
         prevSwHigh = lastSwHigh;
         lastSwHigh = high[k];
         numSwHighs++;
      }
      if(low[k] <= low[k - 1] && low[k] <= low[k + 1])
      {
         prevSwLow = lastSwLow;
         lastSwLow = low[k];
         numSwLows++;
      }
   }

   if(move > dead)
   {
      if(numSwLows >= 2 && lastSwLow < prevSwLow)
         return(0); // Lower low invalidates bullish structure
      return(1);
   }
   else if(move < -dead)
   {
      if(numSwHighs >= 2 && lastSwHigh > prevSwHigh)
         return(0); // Higher high invalidates bearish structure
      return(-1);
   }

   return(0);
}

// Backward-compatible overload
int StructureVote(const double &close[], int i, int period, double atr)
{
   return(StructureVote(close, close, close, i, period, atr));
}

//==================================================================
//  COMPONENT 4 : ROLLING HURST EXPONENT  (the regime LABEL)
//==================================================================
//  Variance-scaling estimator.  Log returns are aggregated over
//  non-overlapping blocks of size s.  For a self-similar series the block
//  dispersion grows like s^H, so the slope of log(std) against log(s) is H:
//
//     H ~ 0.5  random walk, no memory         -> no directional edge
//     H > 0.5  persistent, trends extend      -> the trend is real
//     H < 0.5  anti-persistent, moves revert  -> expect a fade
//
//  Cross-checked against detrended fluctuation analysis on real EURUSD
//  M5/M15/M30 data (256-bar window): correlation 0.63 - 0.74.  The cheap
//  estimator is used because it is accurate enough for a regime label and
//  costs a fraction of the CPU inside the terminal.
//+------------------------------------------------------------------+
double HurstExponent(const double &close[], int i, int window)
{
   if(i + 1 < window || window < 32) return(0.5);

   int    scales[5] = {1, 2, 4, 8, 16};
   double lx[5], ly[5];
   int    m = 0;
   int    start = i - window + 1;

   for(int s = 0; s < 5; s++)
   {
      int scale = scales[s];
      int k     = window / scale;          // non-overlapping blocks
      if(k < 4) continue;

      double sums[];
      ArrayResize(sums, k);

      for(int b = 0; b < k; b++)
      {
         double sum = 0.0;
         for(int j = 0; j < scale; j++)
         {
            int    idx = start + b * scale + j;
            double p1  = close[idx];
            double p0  = close[idx - 1];
            if(p0 > 0.0 && p1 > 0.0)
               sum += MathLog(p1 / p0);
         }
         sums[b] = sum;
      }

      double mean = 0.0;
      for(int b = 0; b < k; b++) mean += sums[b];
      mean /= (double)k;

      double var = 0.0;
      for(int b = 0; b < k; b++) var += (sums[b] - mean) * (sums[b] - mean);
      var /= (double)(k - 1);

      double sd = MathSqrt(var);
      if(sd <= 0.0) continue;

      lx[m] = MathLog((double)scale);
      ly[m] = MathLog(sd);
      m++;
   }

   if(m < 3) return(0.5);

   double mx = 0.0, my = 0.0;
   for(int j = 0; j < m; j++) { mx += lx[j]; my += ly[j]; }
   mx /= (double)m;
   my /= (double)m;

   double sxy = 0.0, sxx = 0.0;
   for(int j = 0; j < m; j++)
   {
      sxy += (lx[j] - mx) * (ly[j] - my);
      sxx += (lx[j] - mx) * (lx[j] - mx);
   }
   if(sxx <= 0.0) return(0.5);

   return(sxy / sxx);
}

//+------------------------------------------------------------------+
//  Volume confirmation: check whether finished bar has healthy volume
//  compared to its 20-period moving average. Returns true if volume
//  is confirmed, or if tick volume is unsupported by the broker feed.
//+------------------------------------------------------------------+
bool IsVolumeConfirmed(ENUM_TIMEFRAMES tf, int period = 20)
{
   long vol[];
   ArraySetAsSeries(vol, true);
   if(CopyTickVolume(_Symbol, tf, 0, period + 2, vol) < period + 2)
      return(true); // Insufficient data, do not block

   long lastVol = vol[1]; // Most recently finished closed bar
   long sumVol  = 0;
   int  valid   = 0;
   for(int k = 1; k <= period; k++)
   {
      if(vol[k] > 0)
      {
         sumVol += vol[k];
         valid++;
      }
   }
   if(valid < period / 2 || sumVol == 0)
      return(true); // Broker does not supply tick volume (flat/zero)

   double avgVol = (double)sumVol / (double)valid;
   return((double)lastVol >= VOL_RATIO_MIN * avgVol);
}

//==================================================================
//  THE SCORE GATE
//==================================================================
//  One rule, used by every place that can produce or send an order:
//      BUY  only at score >= InpBuyScore
//      SELL only at score <= InpSellScore
//  It applies to the TREND game and to the RANGE game alike.  The range
//  game still takes its entry price, stop and target from the box - the
//  box decides WHERE the trade is - but it may only trade in a direction
//  the score actually supports.  Before this gate existed a Choppy row
//  could send a box order at a score of 0, which reads on screen as
//  "autotrading traded while the score said 0".
//+------------------------------------------------------------------+
bool ScoreAllowsTrade(int dir, int score)
{
   if(dir == 0)                          return(false);
   if(dir > 0)                           return(score >= InpBuyScore);
   return(score <= InpSellScore);
}

//==================================================================
//  EVALUATION
//==================================================================
void EvaluateAll()
{
   //  Hard rule: on anything other than M5/M15/M30 there is nothing to
   //  compute.  Every row is left untouched and marked "no data", so even
   //  a bug elsewhere in the drawing code could not put a number on screen.
   if(!ChartSupported())
   {
      for(int r = 0; r < TF_COUNT; r++)
      {
         g_rows[r].ok           = false;
         g_rows[r].score        = 0;
         g_rows[r].direction    = 0;
         g_rows[r].trendDir     = 0;
         g_rows[r].mode         = 0;
         g_rows[r].choppyBlocked = false;
         g_rows[r].blockReason  = "";
         g_rows[r].rngTop       = 0.0;
         g_rows[r].rngBot       = 0.0;
         g_rows[r].lastClose    = 0.0;
         g_rows[r].lastBar      = 0;
         g_rows[r].sigBirth     = 0;
      }
      return;
   }

   for(int r = 0; r < TF_COUNT; r++)
      EvaluateRow(r);
}

//+------------------------------------------------------------------+
void EvaluateRow(int idx)
{
   double c[], h[], l[];

   int want = BarsNeeded();   // 700 minimum, raised automatically by the periods above
   if(!LoadClosed(_Symbol, g_rows[idx].tf, want, c, h, l))
   {
      g_rows[idx].ok           = false;
      g_rows[idx].score        = 0;
      g_rows[idx].direction    = 0;
      g_rows[idx].trendDir     = 0;
      g_rows[idx].mode         = 0;
      g_rows[idx].choppyBlocked = false;
      g_rows[idx].blockReason  = "";
      g_rows[idx].rngTop       = 0.0;
      g_rows[idx].rngBot       = 0.0;
      g_rows[idx].lastClose    = 0.0;
      g_rows[idx].sigBirth     = 0;
      return;
   }

   int n    = ArraySize(c);
   int last = n - 1;                               // most recently CLOSED bar

   //  The idea's leash clock (the Valid cell): what the row said before
   int prevDir  = g_rows[idx].direction;
   int prevMode = g_rows[idx].mode;

   // ---- fresh state: nothing may leak from the previous bar --------
   g_rows[idx].mode          = 0;
   g_rows[idx].choppyBlocked = false;
   g_rows[idx].blockReason   = "";
   g_rows[idx].rngTop      = 0.0;
   g_rows[idx].rngBot      = 0.0;
   g_rows[idx].lastClose   = c[last];

   // ---- adaptive dominant cycle periods ---------------------------
   int dynL2 = AdaptiveCyclePeriod(c, n, 120);
   int dynL1 = (int)MathRound((double)dynL2 * 6.25);
   dynL1 = (int)MathMax(90, MathMin(225, dynL1));

   g_rows[idx].l1 = dynL1;
   g_rows[idx].l2 = dynL2;

   // ---- components 1 and 2 : trend and momentum -------------------
   double trend[], roc[];
   PrecisionTrend(c, dynL1, dynL2, trend, roc);

   double atrNow  = ATRClosed(g_rows[idx].tf, ATR_PERIOD);
   double rocDead = (atrNow > 0.0) ? ROC_DEAD_ATR * atrNow : 0.0;

   int v1 = (trend[last] > 0.0) ? 1 : ((trend[last] < 0.0) ? -1 : 0);
   int v2 = (roc[last] > rocDead) ? 1 : ((roc[last] < -rocDead) ? -1 : 0);

   // ---- component 3 : structure (the independent third vote) --------
   //  Three votes, three DIFFERENT measurements:
   //     1. direction : sign of the Precision Trend line
   //     2. timing    : sign of that line's ROC (dead-banded by 0.02 ATR)
   //     3. structure : Dow Theory swing structure + net move over 20 bars
   //  Because they are independent, 2/3 and 1/3 are real recurring states
   //  - and 2/3 is the state that places a LIMIT order.
   int v3    = StructureVote(c, h, l, last, STRUCT_PERIOD, atrNow);
   int score = v1 + v2 + v3;

   //  The regime is a LABEL and an ENTRY STYLE.  The score publishes the
   //  would-be direction exactly as InpBuyScore / InpSellScore say; the
   //  operator's separate InpAllowChoppyTrade switch may then veto a
   //  NEW entry on a Choppy row without erasing that direction, so a
   //  trade already open keeps its normal score-based management.
   //     Steady (H > hTrend) : a limit entry waits half an ATR back
   //     Choppy (H < hRevert): an allowed limit waits at the box band,
   //                           or half an ATR back when Range Mode is
   //                           off / the box is unusable; permission
   //                           Off places nothing at 2/3 or 3/3
   //     Mixed  (in between) : a limit entry waits half an ATR back
   double H    = HurstExponent(c, last, HURST_WINDOW);
   double ER   = EfficiencyRatio(c, last, ER_PERIOD);
   int    game = 0;                       // 0 mixed | 1 steady | 2 choppy
   if(H > g_rows[idx].hTrend)       game = 1;
   else if(H < g_rows[idx].hRevert) game = 2;

   string emDash = ShortToString((ushort)0x2014); // U+2014 em dash without non-ASCII source bytes

   // ---- the decision: score 3 = market, score 2 = limit, else nothing -
   int dir = 0;
   if(ER < ER_DEAD)
      g_rows[idx].blockReason = "quiet " + emDash + " nothing worth trading";
   else
   {
      if(ScoreAllowsTrade( 1, score))      dir =  1;
      else if(ScoreAllowsTrade(-1, score)) dir = -1;
      if(dir == 0)
         g_rows[idx].blockReason = StringFormat("score %+d/3 %s under the %+d/%+d gate",
                                                score, emDash, InpBuyScore, InpSellScore);
   }

   // ---- the Choppy permission gate --------------------------------
   //  Keep dir/score intact: the panel can show the would-be signal
   //  greyed out, and an already-open same-direction trade must not be
   //  mistaken for a HOLD/flip merely because NEW Choppy entries are
   //  off.  UpdatePlanRow() publishes no executable plan for a flat or
   //  pending lane while this flag is set, ManageAutoBar() cancels a
   //  waiting pending, and PlacePlanOrder() checks it again.
   bool choppyBlocked = (!InpAllowChoppyTrade && game == 2 && dir != 0);
   if(choppyBlocked)
      g_rows[idx].blockReason = "choppy " + emDash + " Choppy Trade is Off";

   // ---- the entry style: an allowed Choppy 2/3 may use the box ----
   //  mode 2 means "this limit's price comes from the box".  A 3/3 order
   //  is a market order (the box has no say in a market fill), and if
   //  the box is not usable an allowed limit falls back to the half-ATR
   //  pullback.  A blocked row never enters box mode: there is no new
   //  entry to price.
   int mode = 0;
   if(dir != 0 && game == 2 && !choppyBlocked && InpRangeMode && MathAbs(score) < 3)
   {
      int    nb   = MathMax(5, RANGE_BARS);
      int    from = MathMax(0, n - nb);
      double top  = -DBL_MAX;
      double bot  =  DBL_MAX;
      for(int k = from; k <= last; k++)
      {
         if(h[k] > top) top = h[k];
         if(l[k] < bot) bot = l[k];
      }
      double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double spread = ask - bid;
      double half   = 0.5 * (top - bot);          // band -> midpoint = the target

      bool usable = (atrNow > 0.0 && spread >= 0.0 && n >= nb && top > bot &&
                     top - bot >= RANGE_MIN_ATR * atrNow &&        // tall enough for the stop
                     ER < RANGE_ER_MAX &&                          // a box, not a walk
                     bid <= top && bid >= bot &&                   // price inside the box
                     half >= RANGE_SPREAD_X * spread);             // the cost gate
      if(usable)
      {
         g_rows[idx].rngTop = top;
         g_rows[idx].rngBot = bot;
         mode = 2;
      }
   }

   g_rows[idx].ok        = true;
   g_rows[idx].score     = score;
   g_rows[idx].direction = dir;
   g_rows[idx].trendDir  = v1;            // the TREND line: vote 1, not the trade
   g_rows[idx].choppyBlocked = choppyBlocked;
   g_rows[idx].mode      = (dir != 0) ? mode : 0;
   g_rows[idx].hurst     = H;
   g_rows[idx].er        = ER;

   //  Remember the bar this reading came from, so CheckNewBars() can tell
   //  a genuinely new closed bar from a tick on the bar it already scored
   //  (without this the panel re-read all three timeframes on every tick).
   g_rows[idx].lastBar   = LastClosedBarTime(_Symbol, g_rows[idx].tf);

   // ---- signal leash birth (the Valid cell counts this) -------------
   //  The idea is re-born when the direction changes, the entry style
   //  switches (box limit <-> plain limit/market), or the old leash has
   //  run out - the very bars the auto-trader expires and re-places a
   //  waiting order on.  A row that stands aside carries no leash.
   int  leash = (mode == 2) ? MathMax(1, RANGE_VALID_BARS)
                            : VALID_BARS;
   int  tfSec = (int)PeriodSeconds(g_rows[idx].tf);
   long age   = leash + 1;                        // unknown age: treat the leash as spent
   if(g_rows[idx].sigBirth > 0 && tfSec > 0 &&
      g_rows[idx].lastBar > g_rows[idx].sigBirth)
      age = (long)((g_rows[idx].lastBar - g_rows[idx].sigBirth) / tfSec);

   if(dir == 0)
      g_rows[idx].sigBirth = 0;
   else if(dir != prevDir || age > leash ||
           (prevDir != 0 && (prevMode == 2) != (mode == 2)))
      g_rows[idx].sigBirth = g_rows[idx].lastBar;
}

//==================================================================
//  TRADE PLAN  (ADVICE ONLY - NO ORDER IS EVER SENT)
//==================================================================
//  Everything below is arithmetic that the terminal itself supplies:
//  the broker's contract size, tick value, lot step and stop level, plus
//  the account balance.  Nothing here is a prediction, and nothing here
//  sends, modifies or closes an order - the panel only writes the numbers
//  on the chart so they can be typed into the trade dialog by hand.
//
//  The five questions it answers, per signal:
//     1. WHERE  - market entry, a pending order if the score is only 2,
//                 or in range mode the OPPOSITE band of the box
//     2. HOW MUCH - lot size, from balance and score
//     3. TARGET - take profit in points and money, plus a rough bar
//                  count for how long reaching it may take
//     4. STOP   - stop loss   in points and in account currency
//     5. UNTIL  - how long the reading is worth acting on
//
//  Entry type is decided by the score, once the operator's Choppy
//  permission allows the row:
//     score 3/3  -> all three components agree -> MARKET entry
//     score 2/3  -> two of three agree        -> PENDING (wait for a better price)
//  WHERE an allowed pending waits is what the regime/Range Mode pair
//  changes: on a Choppy row with Range Mode on and a usable box it sits
//  at the box band (target = half the box, band -> midpoint, stop =
//  band + 1 ATR); otherwise it sits half an ATR back from the market
//  with the timeframe's ATR stop and target.  With Choppy permission
//  off, a Choppy row has no executable plan at either score.
//  (Measured behaviour of both is in research/HORIZON.md; the pending price
//   is PEND_ATR (half an ATR) beyond the market, pushed out further only
//   when the spread or the broker's stops level demands it.)
//+------------------------------------------------------------------+
//  ONE PLAN PER TIMEFRAME.  The second group is three blocks, one for M5,
//  one for M15, one for M30 - because the executor acts per row and the
//  panel has to be able to say "buy M5, sell M30".
struct SPlanRow
{
   int      state;                // 0 HOLD, 1 waiting for data, 2 active
   int      dir;                  // +1 buy, -1 sell
   int      score;
   bool     market;               // true = market entry, false = pending
   int      lines;                // lines this block occupies: 1 or PLAN_LINES
   string   head;                 // "M5" / "M15" / "M30"
   string   kind;                 // "market -3/3" / "pending +2/3" / "HOLD" / "waiting"
   string   note;                 // one-liners for the inactive states
   double   entryPrice;           // advised entry price (ask/bid for market, pend for limit)
   double   lot;                  // normalized lot size
   int      slPts;                // stop distance in points
   int      tpPts;                // target (TP3) distance in points
   int      tp1Pts;               // TP1 distance in points (25% less than TP2)
   int      tp2Pts;               // TP2 distance in points (25% less than TP3)
   int      tp3Pts;               // TP3 distance in points (100% of advised target)
   datetime validUntil;           // expiration timestamp
   // ---- ready to draw: label + value per cell -------------------------
   string   lbl[PLAN_LINES][3];
   string   val[PLAN_LINES][3];
   color    clr[PLAN_LINES][3];
};

SPlanRow g_plans[TF_COUNT];

//+------------------------------------------------------------------+
//  Compute the three take-profit levels in points from SimpleEA's
//  advised target (TP3):
//     TP3 = 100% of advised target points
//     TP2 = 25% less than TP3 (75% of TP3)
//     TP1 = 25% less than TP2 (75% of TP2 = 56.25% of TP3)
//+------------------------------------------------------------------+
void ComputeTPLevels(int tp3, int &tp1, int &tp2)
{
   if(tp3 < 1) tp3 = 1;
   tp2 = (int)MathMax(1.0, MathRound((double)tp3 * 0.75));
   tp1 = (int)MathMax(1.0, MathRound((double)tp2 * 0.75));
}

//+------------------------------------------------------------------+
//  Value of ONE POINT of one lot, in the account currency.  Taken from
//  the contract the broker actually offers, so this is correct for gold,
//  FX, indices, anything - and it self-adjusts when a broker uses 3-digit
//  gold, 5-digit EURUSD, cent lots, or a non-USD account.
//+------------------------------------------------------------------+
double PointValuePerLot()
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double tick  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tval  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(point <= 0.0 || tick <= 0.0 || tval <= 0.0) return(0.0);
   return(tval * (point / tick));
}

//+------------------------------------------------------------------+
double SymbolMinLot()
{
   double mn = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   return(mn > 0.0 ? mn : 0.01);
}

//+------------------------------------------------------------------+
//  Snap a lot size onto the broker's grid: never below the minimum,
//  never above the maximum, always a whole number of lot steps.
//+------------------------------------------------------------------+
double NormalizeLots(double lots)
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double mn   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double mx   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0.0) step = 0.01;
   if(mn   <= 0.0) mn   = step;
   if(mx   <= 0.0) mx   = 100.0;

   double n = MathFloor(lots / step + 1e-8) * step;
   if(n < mn) n = mn;
   if(n > mx) n = mx;

   int digits = 0;
   double probe = step;
   while(probe < 1.0 && digits < 8) { probe *= 10.0; digits++; }
   return(NormalizeDouble(n, digits));
}

//+------------------------------------------------------------------+
//  Average true range over CLOSED bars of a timeframe.
//+------------------------------------------------------------------+
double ATRClosed(ENUM_TIMEFRAMES tf, int period)
{
   if(period < 1) return(0.0);

   double h[], l[], c[];
   ArraySetAsSeries(h, true);
   ArraySetAsSeries(l, true);
   ArraySetAsSeries(c, true);

   int need = period + 1;                       // +1 for the previous close
   if(CopyHigh (_Symbol, tf, 1, need, h) < need) return(0.0);
   if(CopyLow  (_Symbol, tf, 1, need, l) < need) return(0.0);
   if(CopyClose(_Symbol, tf, 1, need, c) < need) return(0.0);

   double sum = 0.0;
   for(int k = 0; k < period; k++)
   {
      double tr = h[k] - l[k];
      double a  = MathAbs(h[k] - c[k + 1]);
      double b  = MathAbs(l[k] - c[k + 1]);
      if(a > tr) tr = a;
      if(b > tr) tr = b;
      sum += tr;
   }
   return(sum / (double)period);
}

//+------------------------------------------------------------------+
//  Which of the three rows is the chart's own timeframe?
//+------------------------------------------------------------------+
int RowForChartTF()
{
   ENUM_TIMEFRAMES tf = (ENUM_TIMEFRAMES)Period();
   for(int i = 0; i < TF_COUNT; i++)
      if(g_rows[i].tf == tf) return(i);
   return(-1);
}

//+------------------------------------------------------------------+
//  Clear one timeframe's plan block.
//+------------------------------------------------------------------+
void ClearPlanRow(int i)
{
   g_plans[i].state      = 0;
   g_plans[i].dir        = 0;
   g_plans[i].score      = 0;
   g_plans[i].market     = false;
   g_plans[i].lines      = 1;
   g_plans[i].head       = g_rows[i].tag;
   g_plans[i].kind       = "";
   g_plans[i].note       = "";
   g_plans[i].entryPrice = 0.0;
   g_plans[i].lot        = 0.0;
   g_plans[i].slPts      = 0;
   g_plans[i].tpPts      = 0;
   g_plans[i].tp1Pts     = 0;
   g_plans[i].tp2Pts     = 0;
   g_plans[i].tp3Pts     = 0;
   g_plans[i].validUntil = 0;

   for(int l = 0; l < PLAN_LINES; l++)
      for(int c = 0; c < 3; c++)
      {
         g_plans[i].lbl[l][c] = "";
         g_plans[i].val[l][c] = "";
         g_plans[i].clr[l][c] = clrGray;
      }
}

//+------------------------------------------------------------------+
//  Build the plan for ONE timeframe: M5, M15 or M30.  Everything is
//  read from the terminal (price, contract value, account balance) and
//  from that timeframe's own ATR, so each block stands alone - which is
//  what the future executor will need.
//+------------------------------------------------------------------+
void UpdatePlanRow(int i)
{
   ClearPlanRow(i);

   if(!g_rows[i].ok)
   {
      g_plans[i].state = 1;
      g_plans[i].kind  = "waiting";
      g_plans[i].note  = "history still loading";
      return;
   }
   if(g_rows[i].direction == 0)
   {
      g_plans[i].state = 0;
      g_plans[i].kind  = "HOLD";
      //  The row says WHY it stands aside (dead market, or score under the gate);
      //  the classic "nothing to place".
      g_plans[i].note  = (g_rows[i].blockReason != "") ? g_rows[i].blockReason
                                                       : "nothing to place";
      return;
   }

   //  Choppy Trade Off: publish no executable plan for a flat lane or a
   //  lane whose order is still only a waiting pending.  The executor
   //  will cancel that pending below.  The one exception is a position
   //  ALREADY OPEN in this same direction: this switch is a new-entry
   //  veto, not an exit rule, so its plan must stay alive for the same
   //  closed-bar TP/SL management it had before the row turned Choppy.
   //  PlacePlanOrder() still refuses outright while the flag is set, so
   //  this management-only plan can never become a second/reverse order.
   bool openSameDirForPlan = (g_auto[i].active && g_auto[i].isOpen &&
                              g_auto[i].dir == g_rows[i].direction &&
                              g_auto[i].entryPrice > 0.0);
   if(g_rows[i].choppyBlocked && !openSameDirForPlan)
   {
      g_plans[i].state = 0;
      g_plans[i].kind  = "HOLD";
      string emDash = ShortToString((ushort)0x2014); // U+2014 em dash
      g_plans[i].note  = (g_rows[i].blockReason != "")
                         ? g_rows[i].blockReason
                         : ("choppy " + emDash + " Choppy Trade is Off");
      return;
   }

   double atr   = ATRClosed(g_rows[i].tf, ATR_PERIOD);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double pv    = PointValuePerLot();
   if(atr <= 0.0 || point <= 0.0 || bid <= 0.0 || ask <= 0.0)
   {
      g_plans[i].state = 1;
      g_plans[i].kind  = "waiting";
      g_plans[i].note  = "no price data yet";
      return;
   }

   int    dir        = g_rows[i].direction;
   int    score      = g_rows[i].score;
   //  THE ORDER TYPE IS THE SCORE'S CALL, everywhere:
   //      3/3 -> MARKET (all three votes agree, take it now)
   //      2/3 -> LIMIT  (two agree, wait for a better price)
   //  Volume Confirmation: if score is 3/3 but tick volume has dried up,
   //  it safely places a Limit order to protect against illiquid slippage.
   bool   volOK      = IsVolumeConfirmed(g_rows[i].tf, 20);
   bool   market     = (MathAbs(score) >= 3 && volOK);
   bool   isRange    = (g_rows[i].mode == 2 && !market);
   bool   isOpenNow  = (g_auto[i].active && g_auto[i].isOpen && g_auto[i].dir == dir &&
                        g_auto[i].entryPrice > 0.0);
   bool   isPendNow  = (g_auto[i].active && !g_auto[i].isOpen && g_auto[i].dir == dir &&
                        g_auto[i].entryPrice > 0.0);
   double entry      = (dir > 0) ? ask : bid;
   //  Pending offset: half an ATR, but never inside the spread and never
   //  inside the broker's minimum stop distance - on a wide-spread or a
   //  thin symbol a bare half-ATR would sit where no limit order can
   //  rest.  On a normal feed this is exactly PEND_ATR * ATR.
   double offset     = PEND_ATR * atr;
   double minOff     = MathMax(2.0 * (ask - bid),
                               (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point);
   if(offset < minOff) offset = minOff;
   double pend       = ValidLimitPrice(dir, (dir > 0) ? (entry - offset) : (entry + offset),
                                       bid, ask, point);
   double planEntry  = market ? entry : pend;

   // ---- stop and target ---------------------------------------------
   //  A plain (market or pullback) entry keeps the per-timeframe ATR
   //  profiles (scalp aims near, intraday aims far).  A BOX entry is pure
   //  geometry: entry at the band, stop = band + RANGE_SL_ATR ATR,
   //  target = half the box (band -> midpoint).  Neither is shrunk by hand.
   int slPts, tpPts;
   if(isRange)
   {
      planEntry = ValidLimitPrice(dir, (dir > 0) ? g_rows[i].rngBot : g_rows[i].rngTop,
                                  bid, ask, point);
      slPts = (int)MathMax(1.0, MathRound(RANGE_SL_ATR * atr / point));
      tpPts = (int)MathMax(1.0, MathRound(0.5 * (g_rows[i].rngTop - g_rows[i].rngBot) / point));
   }
   else
   {
      slPts = (int)MathMax(1.0, MathRound(g_rows[i].slAtr * atr / point));
      tpPts = (int)MathMax(1.0, MathRound(g_rows[i].tpAtr * atr / point));
   }

   double minStop = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
   bool   widened = false;
   if(minStop > 0.0 && (double)slPts * point < minStop)
   {
      slPts   = (int)MathCeil(minStop / point);
      widened = true;
   }
   if(minStop > 0.0 && (double)tpPts * point < minStop)
      tpPts = (int)MathCeil(minStop / point);

   double dispEntry = isOpenNow ? g_auto[i].entryPrice
                                : (isPendNow ? g_auto[i].entryPrice : planEntry);
   int    dispSlPts = ((isOpenNow || isPendNow) && g_auto[i].slPrice > 0.0) ? g_auto[i].slPts : slPts;
   int    dispTpPts = (isOpenNow && g_auto[i].tp3Pts > 0)  ? g_auto[i].tp3Pts
                    : ((isPendNow && g_auto[i].tp3Pts > 0) ? g_auto[i].tp3Pts : tpPts);

   double slPrice = (dir > 0) ? (dispEntry - (double)dispSlPts * point)
                              : (dispEntry + (double)dispSlPts * point);
   if((isOpenNow || isPendNow) && g_auto[i].slPrice > 0.0)
      slPrice = g_auto[i].slPrice;

   double tpPrice = (dir > 0) ? (dispEntry + (double)dispTpPts * point)
                              : (dispEntry - (double)dispTpPts * point);
   if((isOpenNow || isPendNow) && g_auto[i].tpPrice > 0.0)
      tpPrice = g_auto[i].tpPrice;

   // ---- lot size ---------------------------------------------------
   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double lots     = SymbolMinLot();
   double wantRisk = 0.0;
   bool   minLot   = false;

   if(InpUseMinLot)
   {
      minLot = true;
      lots   = SymbolMinLot();
   }
   else if(InpUseRisk)
   {
      double pct = InpRiskPct;
      if(MathAbs(score) >= 3) pct *= RISK_SCORE3_X;   // all three agree: double
      wantRisk   = balance * pct / 100.0;
      if(pv > 0.0 && slPts > 0)
         lots = wantRisk / ((double)slPts * pv);
   }
   else
   {
      lots = (balance / BAL_PER_001) * 0.01;
      if(MathAbs(score) >= 3) lots *= SCORE3_FACTOR;
   }

   double lot       = NormalizeLots(lots);
   double dispLot   = ((isOpenNow || isPendNow) && g_auto[i].curLot > 0.0) ? g_auto[i].curLot : lot;
   double riskUSD   = (pv > 0.0) ? dispLot * (double)dispSlPts * pv : 0.0;
   double rewardUSD = (pv > 0.0) ? dispLot * (double)dispTpPts * pv : 0.0;
   bool   riskOver  = (!InpUseMinLot && InpUseRisk && wantRisk > 0.0 &&
                       riskUSD > wantRisk * 1.05);

   // ---- how long this reading is worth acting on -------------------
   //  Trend readings live VALID_BARS closed bars (the measured median
   //  life, research/HORIZON.md).  Range fades get RANGE_VALID_BARS:
   //  the box is re-measured every bar and a close outside it already
   //  kills both the pending and the position, so a longer leash costs
   //  nothing - it only stops the cancel / re-place churn every 3 bars
   //  and the one-bar gap at the band that churn leaves behind.
   int vBars = (g_rows[i].mode == 2) ? MathMax(1, RANGE_VALID_BARS)
                                     : VALID_BARS;
   datetime until  = 0;
   datetime sigBar = LastClosedBarTime(_Symbol, g_rows[i].tf);
   if(sigBar > 0)
      until = sigBar + (datetime)((vBars + 1) * PeriodSeconds(g_rows[i].tf));

   // ---- fill the cells ---------------------------------------------
   string cur  = AccountInfoString(ACCOUNT_CURRENCY);
   int    dg   = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   color  dirC = (dir > 0) ? InpBuyColor : InpSellColor;

   int tp1Pts = 1, tp2Pts = 1;
   ComputeTPLevels(tpPts, tp1Pts, tp2Pts);

   string kindWord = isOpenNow ? ((dir > 0) ? "buy" : "sell")
                               : (market ? "market" : "pending");

   g_plans[i].state      = 2;
   g_plans[i].dir        = dir;
   g_plans[i].score      = score;
   g_plans[i].market     = market;
   g_plans[i].lines      = PLAN_LINES;
   g_plans[i].kind       = isRange ? "range fade"
                                   : StringFormat("%s %+d/%d", kindWord, score, 3);
   g_plans[i].entryPrice = planEntry;
   g_plans[i].lot        = lot;
   g_plans[i].slPts      = slPts;
   g_plans[i].tpPts      = tpPts;
   g_plans[i].tp1Pts     = tp1Pts;
   g_plans[i].tp2Pts     = tp2Pts;
   g_plans[i].tp3Pts     = tpPts;
   g_plans[i].validUntil = until;

   g_plans[i].lbl[0][0] = "Entry:";
   g_plans[i].val[0][0] = DoubleToString(dispEntry, dg);
   g_plans[i].clr[0][0] = dirC;

   string lotTxt = DoubleToString(dispLot, 2);
   if(minLot)        lotTxt += " (min)";
   else if(riskOver) lotTxt += StringFormat(" (min, %s %s)",
                                            DoubleToString(riskUSD, 2), cur);
   g_plans[i].lbl[0][1] = "Lot:";
   g_plans[i].val[0][1] = lotTxt;
   g_plans[i].clr[0][1] = InpTitleColor;

   g_plans[i].lbl[1][0] = "Stop:";
   g_plans[i].val[1][0] = StringFormat("%s %dpts%s", DoubleToString(slPrice, dg), dispSlPts,
                                       widened ? " (min)" : "");
   g_plans[i].clr[1][0] = InpSellColor;

   g_plans[i].lbl[1][1] = "Target:";
   g_plans[i].val[1][1] = StringFormat("%s %dpts", DoubleToString(tpPrice, dg), dispTpPts);
   g_plans[i].clr[1][1] = InpBuyColor;

   // ---- roughly how long the target may take -----------------------
   //  A driftless walk covers ~1 ATR per sqrt(bar) of bars, so the
   //  target's own distance says how many bars it typically needs:
   //  bars ~ (target / ATR)^2.  A rough guide printed with a "~", not
   //  a forecast - it is what makes scalp / short-term / intraday
   //  visibly different in TIME, not only in points.
   int etaBars = (int)MathMax(1.0, MathRound(MathPow((double)dispTpPts * point / atr, 2.0)));
   g_plans[i].lbl[1][2] = "Reach:";
   g_plans[i].val[1][2] = StringFormat("~%d bar%s", etaBars, (etaBars == 1) ? "" : "s");
   g_plans[i].clr[1][2] = clrSilver;

   g_plans[i].lbl[2][0] = "Risk:";
   g_plans[i].val[2][0] = StringFormat("%s %s", DoubleToString(riskUSD, 2), cur);
   g_plans[i].clr[2][0] = InpSellColor;

   g_plans[i].lbl[2][1] = "Reward:";
   g_plans[i].val[2][1] = StringFormat("%s %s", DoubleToString(rewardUSD, 2), cur);
   g_plans[i].clr[2][1] = InpBuyColor;

   // ---- the time cell: idea leash (Valid) or hold time (Hold) --------
   //  A live position has no signal leash - its exits are SL, TP or the
   //  box - so the time question flips to "how long has it run against
   //  the Reach estimate above": Hold: N bars (est ~M).  Everything else
   //  (advice plan, waiting pending) shows the idea's own leash counting
   //  down: Valid: left/total bars, from the bar the idea was born - the
   //  same bars the auto-trader expires and re-places a waiting order
   //  on.  0/total is the rethink bar and shows for exactly one bar.
   int  tfSec = (int)PeriodSeconds(g_rows[i].tf);
   long age   = 0;
   if(g_rows[i].sigBirth > 0 && tfSec > 0 && g_rows[i].lastBar > g_rows[i].sigBirth)
      age = (long)((g_rows[i].lastBar - g_rows[i].sigBirth) / tfSec);

   if(isOpenNow)
   {
      long held = 0;
      datetime fillBar = (g_auto[i].fillBar > 0) ? g_auto[i].fillBar : g_auto[i].placedBar;
      if(fillBar > 0 && tfSec > 0 && g_rows[i].lastBar > fillBar)
         held = (long)((g_rows[i].lastBar - fillBar) / tfSec);
      g_plans[i].lbl[2][2] = "Hold:";
      g_plans[i].val[2][2] = StringFormat("%d bar%s (est ~%d)", (int)held,
                                          (held == 1) ? "" : "s", etaBars);
      g_plans[i].clr[2][2] = clrSilver;
   }
   else
   {
      int left = (int)MathMax(0, MathMin(vBars, vBars - (int)age));
      g_plans[i].lbl[2][2] = "Valid:";
      g_plans[i].val[2][2] = StringFormat("%d/%d bars", left, vBars);
      g_plans[i].clr[2][2] = clrSilver;
   }
}

//+------------------------------------------------------------------+
//  Rebuild all three plan blocks.  Called whenever the panel is
//  redrawn, right after the timeframe rows have been evaluated.  On an
//  unsupported chart timeframe there are no plans at all.
//+------------------------------------------------------------------+
void UpdatePlan()
{
   for(int i = 0; i < TF_COUNT; i++)
   {
      ClearPlanRow(i);
      if(!ChartSupported()) continue;
      UpdatePlanRow(i);
   }
}

//==================================================================
//  AUTOTRADING ENGINE & SECOND PANEL
//==================================================================
//  One slot per timeframe (M5 = 0, M15 = 1, M30 = 2), isolated on the
//  broker server by MagicForTF(i) = InpMagicBase + i.
//+------------------------------------------------------------------+
struct SAutoState
{
   bool     active;        // true if an open position or pending order exists
   bool     isOpen;        // true = open market position, false = pending limit order
   ulong    ticket;        // position or order ticket
   int      dir;           // +1 buy, -1 sell
   int      entryScore;    // score when placed/opened (or strongest score reached)
   double   initLot;       // initial lot size when placed/opened
   double   curLot;        // current remaining lot size
   double   entryPrice;    // position open price or pending limit price
   double   slPrice;       // current broker SL price (0.0 if none)
   double   tpPrice;       // current broker TP price (TP3)
   double   profitUSD;     // live position profit in account currency
   int      slPts;         // current SL distance from entry in points
   int      tp1Pts;        // TP1 distance in points (25% less than TP2)
   int      tp2Pts;        // TP2 distance in points (25% less than TP3)
   int      tp3Pts;        // TP3 distance in points (100% of advised target)
   bool     tp1Hit;        // true once TP1 has been reached
   bool     tp2Hit;        // true once TP2 has been reached
   bool     trailActive;   // true once break-even / trailstop is active
   // ---- pre-TP1 stepped trailstop (Entry -> TP1 only) -----------------
   bool     trailSteady;   // true when the Steady % was picked at fill
   bool     trailStarted;  // true once the activation % has been reached
   int      trailPct;      // selected activation % of Entry->TP1 (10-70)
   double   trailGapPct;   // gap behind the stepped peak, in % of Entry->TP1
   int      trailRefTp1Pts;// Entry->TP1 distance in points, frozen at fill
   double   trailPeakPts;  // best favourable progress in points since fill
   double   trailAppliedPct; // highest stepped progress % whose SL is in place
   double   trailTriedPct;   // last stepped progress % a modify was tried for
   datetime trailLastTry;    // time of the last trailstop modify attempt
   datetime floorLastTry;    // time of the last failed profit-floor modify attempt
   bool     isRange;       // true when this order is a range fade (box trade)
   double   rngTop;        // range box upper band captured at placement (box-kill)
   double   rngBot;        // range box lower band captured at placement (box-kill)
   datetime placedBar;     // closed-bar timestamp when pending order was placed
   datetime fillBar;       // closed-bar timestamp when the position filled/opened
   datetime lastEvalBar;   // last closed bar on which SL/TP update was evaluated
   datetime lastSignalBar; // closed-bar timestamp on which a trade was opened
   // ---- calibration-health diary link for this order idea -------------
   long     diaryRecordId;    // SDiaryRecord.id (0 = untracked/pre-diary)
   ulong    diaryPositionId;  // MT5 position identifier once filled
   long     diaryPlacedDayKey;// PC-local YYYYMMDD at original placement
   int      diaryPlanSlPts;   // planned stop distance: the 1R denominator
   int      diaryRegime;      // 0 Mixed, 1 Steady, 2 Choppy at placement
   int      diaryStyle;       // market / pullback / box / Choppy variant
   datetime diaryPlacedAt;    // broker-server placement time
   datetime diaryLocalPlaced; // PC-local placement time
   double   diaryCostTp1Pct;  // entry spread as % of TP1 distance
   double   diaryPeakTp1Pct;  // furthest favourable progress as % of TP1
   double   diaryDealNet;     // deal-history net found so far
   double   diaryDealVolume;  // original volume already closed in deals
   ulong    diaryLastDeal;    // last deal time found (diagnostic only)
   double   diaryLastExitPrice; // last closing-deal price found in history
   long     diaryLastExitReason; // DEAL_REASON of that deal (-1 = unknown)
   // ---- formatted cells for the 2nd Panel (Autotrading) ---------------
   string   head;          // "M5  | OPEN SELL" / "M30 | BUY LIMIT"
   color    headClr;
   string   lbl[AUTO_LINES][3];
   string   val[AUTO_LINES][3];
   color    clr[AUTO_LINES][3];
};

SAutoState g_auto[TF_COUNT];
int        g_autoW     = AUTO_W_MIN;
int        g_autoH     = 100;
bool       g_autoShown = false;

//+------------------------------------------------------------------+
long MagicForTF(int i)
{
   return(InpMagicBase + (long)i);
}

//+------------------------------------------------------------------+
//  GlobalVariable persistence for slot state (range box, score, placed bar)
//  so a terminal restart or EA recompile preserves range trades & rules.
//+------------------------------------------------------------------+
string AutoGVKey(int i, string field)
{
   return(StringFormat("SEA_%d_%s_%d_%s", (int)AccountInfoInteger(ACCOUNT_LOGIN), _Symbol, MagicForTF(i), field));
}

void SaveAutoSlotState(int i)
{
   if(g_auto[i].isRange)
   {
      GlobalVariableSet(AutoGVKey(i, "rng"), 1.0);
      GlobalVariableSet(AutoGVKey(i, "top"), g_auto[i].rngTop);
      GlobalVariableSet(AutoGVKey(i, "bot"), g_auto[i].rngBot);
   }
   else
   {
      GlobalVariableDel(AutoGVKey(i, "rng"));
      GlobalVariableDel(AutoGVKey(i, "top"));
      GlobalVariableDel(AutoGVKey(i, "bot"));
   }
   if(g_auto[i].entryScore != 0)
      GlobalVariableSet(AutoGVKey(i, "score"), (double)g_auto[i].entryScore);
   if(g_auto[i].placedBar > 0)
      GlobalVariableSet(AutoGVKey(i, "placed"), (double)g_auto[i].placedBar);
   if(g_auto[i].tp1Hit)
      GlobalVariableSet(AutoGVKey(i, "tp1"), 1.0);
   else
      GlobalVariableDel(AutoGVKey(i, "tp1"));
   if(g_auto[i].tp2Hit)
      GlobalVariableSet(AutoGVKey(i, "tp2"), 1.0);
   else
      GlobalVariableDel(AutoGVKey(i, "tp2"));
   if(g_auto[i].trailAppliedPct > 0.0)
      GlobalVariableSet(AutoGVKey(i, "tapp"), g_auto[i].trailAppliedPct);
   else
      GlobalVariableDel(AutoGVKey(i, "tapp"));
   if(g_auto[i].diaryRecordId > 0)
   {
      GlobalVariableSet(AutoGVKey(i, "drec"),   (double)g_auto[i].diaryRecordId);
      GlobalVariableSet(AutoGVKey(i, "dday"),   (double)g_auto[i].diaryPlacedDayKey);
      GlobalVariableSet(AutoGVKey(i, "dsl"),    (double)g_auto[i].diaryPlanSlPts);
      GlobalVariableSet(AutoGVKey(i, "dreg"),   (double)g_auto[i].diaryRegime);
      GlobalVariableSet(AutoGVKey(i, "dsty"),   (double)g_auto[i].diaryStyle);
      GlobalVariableSet(AutoGVKey(i, "dat"),    (double)g_auto[i].diaryPlacedAt);
      GlobalVariableSet(AutoGVKey(i, "dlocal"), (double)g_auto[i].diaryLocalPlaced);
      GlobalVariableSet(AutoGVKey(i, "dcost"),  g_auto[i].diaryCostTp1Pct);
      GlobalVariableSet(AutoGVKey(i, "dpeak"),  g_auto[i].diaryPeakTp1Pct);
   }
   else
   {
      GlobalVariableDel(AutoGVKey(i, "drec"));
      GlobalVariableDel(AutoGVKey(i, "dday"));
      GlobalVariableDel(AutoGVKey(i, "dsl"));
      GlobalVariableDel(AutoGVKey(i, "dreg"));
      GlobalVariableDel(AutoGVKey(i, "dsty"));
      GlobalVariableDel(AutoGVKey(i, "dat"));
      GlobalVariableDel(AutoGVKey(i, "dlocal"));
      GlobalVariableDel(AutoGVKey(i, "dcost"));
      GlobalVariableDel(AutoGVKey(i, "dpeak"));
   }
   GlobalVariablesFlush();
}

void ClearAutoSlotState(int i)
{
   GlobalVariableDel(AutoGVKey(i, "rng"));
   GlobalVariableDel(AutoGVKey(i, "top"));
   GlobalVariableDel(AutoGVKey(i, "bot"));
   GlobalVariableDel(AutoGVKey(i, "score"));
   GlobalVariableDel(AutoGVKey(i, "placed"));
   GlobalVariableDel(AutoGVKey(i, "tp1"));
   GlobalVariableDel(AutoGVKey(i, "tp2"));
   GlobalVariableDel(AutoGVKey(i, "tapp"));
   GlobalVariableDel(AutoGVKey(i, "drec"));
   GlobalVariableDel(AutoGVKey(i, "dday"));
   GlobalVariableDel(AutoGVKey(i, "dsl"));
   GlobalVariableDel(AutoGVKey(i, "dreg"));
   GlobalVariableDel(AutoGVKey(i, "dsty"));
   GlobalVariableDel(AutoGVKey(i, "dat"));
   GlobalVariableDel(AutoGVKey(i, "dlocal"));
   GlobalVariableDel(AutoGVKey(i, "dcost"));
   GlobalVariableDel(AutoGVKey(i, "dpeak"));
   GlobalVariablesFlush();
}

void RestoreAutoSlotState(int i)
{
   if(GlobalVariableCheck(AutoGVKey(i, "rng")))
   {
      g_auto[i].isRange = (GlobalVariableGet(AutoGVKey(i, "rng")) > 0.5);
      if(GlobalVariableCheck(AutoGVKey(i, "top")))
         g_auto[i].rngTop = GlobalVariableGet(AutoGVKey(i, "top"));
      if(GlobalVariableCheck(AutoGVKey(i, "bot")))
         g_auto[i].rngBot = GlobalVariableGet(AutoGVKey(i, "bot"));
   }
   if(GlobalVariableCheck(AutoGVKey(i, "score")))
      g_auto[i].entryScore = (int)MathRound(GlobalVariableGet(AutoGVKey(i, "score")));
   if(GlobalVariableCheck(AutoGVKey(i, "placed")))
      g_auto[i].placedBar = (datetime)GlobalVariableGet(AutoGVKey(i, "placed"));
   if(GlobalVariableCheck(AutoGVKey(i, "tp1")))
      g_auto[i].tp1Hit = (GlobalVariableGet(AutoGVKey(i, "tp1")) > 0.5);
   if(GlobalVariableCheck(AutoGVKey(i, "tp2")))
      g_auto[i].tp2Hit = (GlobalVariableGet(AutoGVKey(i, "tp2")) > 0.5);
   if(GlobalVariableCheck(AutoGVKey(i, "tapp")))
      g_auto[i].trailAppliedPct = GlobalVariableGet(AutoGVKey(i, "tapp"));
   if(GlobalVariableCheck(AutoGVKey(i, "drec")))
      g_auto[i].diaryRecordId = (long)MathRound(GlobalVariableGet(AutoGVKey(i, "drec")));
   if(GlobalVariableCheck(AutoGVKey(i, "dday")))
      g_auto[i].diaryPlacedDayKey = (long)MathRound(GlobalVariableGet(AutoGVKey(i, "dday")));
   if(GlobalVariableCheck(AutoGVKey(i, "dsl")))
      g_auto[i].diaryPlanSlPts = (int)MathRound(GlobalVariableGet(AutoGVKey(i, "dsl")));
   if(GlobalVariableCheck(AutoGVKey(i, "dreg")))
      g_auto[i].diaryRegime = (int)MathRound(GlobalVariableGet(AutoGVKey(i, "dreg")));
   if(GlobalVariableCheck(AutoGVKey(i, "dsty")))
      g_auto[i].diaryStyle = (int)MathRound(GlobalVariableGet(AutoGVKey(i, "dsty")));
   if(GlobalVariableCheck(AutoGVKey(i, "dat")))
      g_auto[i].diaryPlacedAt = (datetime)GlobalVariableGet(AutoGVKey(i, "dat"));
   if(GlobalVariableCheck(AutoGVKey(i, "dlocal")))
      g_auto[i].diaryLocalPlaced = (datetime)GlobalVariableGet(AutoGVKey(i, "dlocal"));
   if(GlobalVariableCheck(AutoGVKey(i, "dcost")))
      g_auto[i].diaryCostTp1Pct = GlobalVariableGet(AutoGVKey(i, "dcost"));
   if(GlobalVariableCheck(AutoGVKey(i, "dpeak")))
      g_auto[i].diaryPeakTp1Pct = GlobalVariableGet(AutoGVKey(i, "dpeak"));
}

//==================================================================
//  CALIBRATION-HEALTH DIARY
//==================================================================
//  The diary gives the fixed calibration a memory, not a second
//  brain.  It records one small row for each original order idea
//  that SimpleEA actually acted on, then derives Day totals and
//  per-timeframe health warnings from those rows.  It never changes
//  a target, a stop, a score rule, a risk setting or a switch.
//
//  One row means one original idea:
//     - a pending that is merely repriced stays the same row;
//     - a 2/3 pending upgraded to a 3/3 market order stays one row;
//     - TP1/TP2 partial exits stay inside the original row;
//     - S is written only after the broker accepted an order.
//
//  The file is per account + symbol + magic base.  Recording runs
//  whether InpShowHealth shows the History panel or not, so turning
//  that panel on later does not start the evidence from zero.  A
//  position that already existed before this diary first ran has no
//  row and is deliberately left untracked rather than reconstructed
//  from guesses.
//+------------------------------------------------------------------+
struct SDiaryRecord
{
   long     id;
   int      tf;              // 0 M5, 1 M15, 2 M30
   int      dir;             // +1 buy, -1 sell
   int      score;           // signed score frozen at placement / upgrade
   int      regime;          // 0 Mixed, 1 Steady, 2 Choppy
   int      style;           // 0 market, 1 pullback, 2 box, 3 Choppy pullback, 4 Choppy market
   int      status;          // 0 open/waiting, 1 closed, 2 expired/cancelled unfilled
   int      outcome;         // 0 none, 1 win, 2 loss, 3 break-even/scratch
   long     placedDay;       // PC-local YYYYMMDD when the idea was placed
   long     closedDay;       // PC-local YYYYMMDD when it closed/expired
   datetime placedAt;        // broker-server placement time
   datetime closedAt;        // broker-server close/expiry time
   datetime localPlaced;     // PC-local placement time
   datetime localClosed;     // PC-local close/expiry time
   ulong    orderTicket;     // pending order ticket, or market order ticket
   ulong    positionId;      // MT5 position identifier once filled
   double   lot;             // original lot, before partial exits
   double   entryPrice;      // actual/planned entry carried by the slot
   int      planSlPts;       // planned stop distance that defines 1R
   int      tp1Pts;
   int      tp2Pts;
   int      tp3Pts;
   double   costTp1Pct;      // entry spread as % of the TP1 distance
   double   peakTp1Pct;      // furthest favourable progress as % of TP1
   double   resultR;         // final net result in planned-risk units
   bool     filled;
   bool     tp1Hit;
   bool     tp2Hit;
   bool     tp3Hit;
   double   riskPct;         // base InpRiskPct in force at placement
   bool     useRisk;
   bool     useMinLot;
   bool     useStopLoss;
   bool     useTrailStop;
   bool     allowChoppy;
   bool     rangeMode;
   double   pointValue;      // account-currency value of 1 point x 1 lot at placement
   string   exitReason;      // compact token, never contains ';'
   bool     provisional;     // closed before the final deal reached history
   int      trailPct;        // activation % chosen at fill (0 = off/unknown)
   bool     trailSteady;     // true when the Steady trail % was chosen
   bool     trailKnown;      // live filled slot was observed by the diary
   bool     trailArmed;      // pre-TP1 stepped trailstop applied at least once
   bool     protectionArmed; // BE / TP lock / trail protection became active
   double   trailLockTp1Pct; // best pre-TP1 trailed SL as % of TP1 (-1 = none)
   double   bestLockTp1Pct;  // best broker SL as % of TP1 (-9999 = none seen)
   double   finalTp1Pct;     // final exit progress as % of TP1 (-9999 = unknown)
   bool     stopExit;        // final closing deal was triggered by broker SL
   bool     stopKnown;       // final closing-deal reason was found in history
};

struct SDiaryTotals
{
   int    signals;
   int    wins;
   int    losses;
   int    be;
   int    openCount;
   int    waitCount;
   int    expired;
   double netR;
};

struct SDiaryClosed
{
   int    scoreAbs;
   int    regime;
   int    style;
   int    outcome;
   double peakTp1Pct;
   double costTp1Pct;
   double resultR;
   bool   tp1Hit;
   bool   tp2Hit;
   bool   tp3Hit;
   bool   useTrailStop;
   bool   trailKnown;
   bool   trailArmed;
   bool   protectionArmed;
   double trailLockTp1Pct;
   double bestLockTp1Pct;
   double finalTp1Pct;
   bool   stopExit;
   bool   stopKnown;
};

struct SDiarySegment
{
   int    n;
   int    wins;
   int    losses;
   int    be;
   int    tp1;
   int    tp2;
   int    tp3;
   int    nearCount;       // reached 70%..99% of TP1 without taking it
   int    costN;
   double netR;
   double tp1Rate;
   double medianPeak;
   double medianCost;
   int    trailEligible;   // closed, trailstop on, and trail state observed
   int    trailArmed;
   int    trailLockN;
   int    trailStopKnown;
   int    trailStopExits;
   int    trailGivebackN;
   double trailArmRate;
   double medianTrailLock;
   double medianTrailGiveback;
};

struct SHealthLane
{
   int    signals;
   int    wins;
   int    losses;
   int    be;
   int    openCount;
   int    waitCount;
   int    expired;
   int    closedCount;
   double netR;

   int    score2Signals;
   int    score2Closed;
   int    score2Wins;
   int    score2Losses;
   int    score2Tp1;
   int    score3Signals;
   int    score3Closed;
   int    score3Wins;
   int    score3Losses;
   int    score3Tp1;

   SDiaryClosed recent[HEALTH_RECENT_N + HEALTH_BASE_N];
   int    recentCount;
   int    recN;
   int    recWins;
   int    recLosses;
   int    recBe;
   int    recTp1;
   int    recTp2;
   int    recTp3;
   int    recCostN;
   double recNetR;
   double recTp1Rate;
   double recMedianPeak;
   double recMedianCost;
   int    baseN;
   double baseTp1Rate;
   double baseMedianCost;
   int    recTrailEligible;
   int    recTrailArmed;
   int    recTrailLockN;
   int    recTrailStopKnown;
   int    recTrailStopExits;
   int    recTrailGivebackN;
   double recTrailArmRate;
   double recTrailMedianLock;
   double recTrailMedianGiveback;

   int    status;          // -1 Learning, 0 OK, 1 Watch, 2 Poor
   int    primaryIssue;    // 0 none, 1 follow-near, 2 follow-weak, 3 cost, 4 score, 5 box, 6 choppy
   int    issueCount;
   int    followLevel;     // 0 ok, 1 watch, 2 poor
   int    costLevel;
   int    scoreLevel;
   int    styleLevel;
   string label;
   string action;
   string note;
};

struct SDiaryUpgrade
{
   bool     active;
   long     recordId;
   long     placedDay;
   datetime placedAt;
   datetime localPlaced;
   int      regime;
};

SDiaryRecord  g_diary[];
SDiaryTotals  g_dayTotals;
SDiaryTotals  g_allTotals;
SHealthLane   g_health[TF_COUNT];
SDiaryUpgrade g_diaryUpgrade[TF_COUNT];

int      g_diaryLockHandle     = INVALID_HANDLE;
bool     g_diaryReady          = false;
bool     g_diaryWarned         = false;
bool     g_diaryLoadFailed     = false;   // existing file unreadable: never overwrite it blind
bool     g_diarySuppress[TF_COUNT];
string   g_diaryFile           = "";
int      g_diaryCommonFlag     = 0;
long     g_diaryNextId         = 1;
datetime g_diaryStarted        = 0;
long     g_diaryStartedDay     = 0;
long     g_healthTodayKey      = 0;

//+------------------------------------------------------------------+
datetime DiaryNowLocal()
{
   datetime t = TimeLocal();
   if(t <= 0) t = TimeCurrent();
   return(t);
}

//+------------------------------------------------------------------+
long DiaryDayKey(datetime t)
{
   if(t <= 0) return(0);
   MqlDateTime dt;
   TimeToStruct(t, dt);
   return((long)dt.year * 10000 + (long)dt.mon * 100 + (long)dt.day);
}

//+------------------------------------------------------------------+
//  Convert a broker-server event time to the PC-local clock by the
//  offset in force now.  Used only when a broker-side close is found
//  in deal history after the EA was away; live closes use TimeLocal()
//  at the moment they happen.
//+------------------------------------------------------------------+
datetime DiaryLocalFromServer(datetime serverTime)
{
   if(serverTime <= 0) return(DiaryNowLocal());
   long delta = (long)serverTime - (long)TimeCurrent();
   return((datetime)((long)DiaryNowLocal() + delta));
}

//+------------------------------------------------------------------+
string DiaryFileName()
{
   string safe = "";
   int len = StringLen(_Symbol);
   for(int k = 0; k < len; k++)
   {
      ushort ch = StringGetCharacter(_Symbol, k);
      bool ok = ((ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') ||
                 (ch >= '0' && ch <= '9') || ch == '.' || ch == '-' || ch == '_');
      safe += ok ? ShortToString(ch) : "_";
   }
   if(safe == "") safe = "SYMBOL";
   return(StringFormat("SimpleEA_Diary_%I64d_%s_%I64d.csv",
                       AccountInfoInteger(ACCOUNT_LOGIN), safe, InpMagicBase));
}

//+------------------------------------------------------------------+
int DiaryRecordIndexById(long id)
{
   if(id <= 0) return(-1);
   int n = ArraySize(g_diary);
   for(int k = 0; k < n; k++)
      if(g_diary[k].id == id)
         return(k);
   return(-1);
}

//+------------------------------------------------------------------+
string DiaryRecordLine(SDiaryRecord &r)
{
   string s = IntegerToString(DIARY_VERSION) + ";";
   s += IntegerToString(r.id) + ";";
   s += IntegerToString(r.tf) + ";";
   s += IntegerToString(r.dir) + ";";
   s += IntegerToString(r.score) + ";";
   s += IntegerToString(r.regime) + ";";
   s += IntegerToString(r.style) + ";";
   s += IntegerToString(r.status) + ";";
   s += IntegerToString(r.outcome) + ";";
   s += IntegerToString(r.placedDay) + ";";
   s += IntegerToString(r.closedDay) + ";";
   s += IntegerToString((long)r.placedAt) + ";";
   s += IntegerToString((long)r.closedAt) + ";";
   s += IntegerToString((long)r.localPlaced) + ";";
   s += IntegerToString((long)r.localClosed) + ";";
   s += IntegerToString((long)r.orderTicket) + ";";
   s += IntegerToString((long)r.positionId) + ";";
   s += DoubleToString(r.lot, 8) + ";";
   s += DoubleToString(r.entryPrice, 8) + ";";
   s += IntegerToString(r.planSlPts) + ";";
   s += IntegerToString(r.tp1Pts) + ";";
   s += IntegerToString(r.tp2Pts) + ";";
   s += IntegerToString(r.tp3Pts) + ";";
   s += DoubleToString(r.costTp1Pct, 4) + ";";
   s += DoubleToString(r.peakTp1Pct, 4) + ";";
   s += DoubleToString(r.resultR, 6) + ";";
   s += IntegerToString(r.filled ? 1 : 0) + ";";
   s += IntegerToString(r.tp1Hit ? 1 : 0) + ";";
   s += IntegerToString(r.tp2Hit ? 1 : 0) + ";";
   s += IntegerToString(r.tp3Hit ? 1 : 0) + ";";
   s += DoubleToString(r.riskPct, 6) + ";";
   s += IntegerToString(r.useRisk ? 1 : 0) + ";";
   s += IntegerToString(r.useMinLot ? 1 : 0) + ";";
   s += IntegerToString(r.useStopLoss ? 1 : 0) + ";";
   s += IntegerToString(r.useTrailStop ? 1 : 0) + ";";
   s += IntegerToString(r.allowChoppy ? 1 : 0) + ";";
   s += IntegerToString(r.rangeMode ? 1 : 0) + ";";
   s += r.exitReason + ";";
   s += IntegerToString(r.provisional ? 1 : 0) + ";";
   s += DoubleToString(r.pointValue, 10) + ";";
   s += IntegerToString(r.trailPct) + ";";
   s += IntegerToString(r.trailSteady ? 1 : 0) + ";";
   s += IntegerToString(r.trailKnown ? 1 : 0) + ";";
   s += IntegerToString(r.trailArmed ? 1 : 0) + ";";
   s += IntegerToString(r.protectionArmed ? 1 : 0) + ";";
   s += DoubleToString(r.trailLockTp1Pct, 4) + ";";
   s += DoubleToString(r.bestLockTp1Pct, 4) + ";";
   s += DoubleToString(r.finalTp1Pct, 4) + ";";
   s += IntegerToString(r.stopExit ? 1 : 0) + ";";
   s += IntegerToString(r.stopKnown ? 1 : 0);
   return(s);
}

//+------------------------------------------------------------------+
bool DiaryParseRecordLine(string line, SDiaryRecord &r)
{
   string p[];
   int n = StringSplit(line, ';', p);
   if(n < 40 || n > 50) return(false);
   // Numeric conversion alone accepts damaged text as zero. Reject it
   // before conversion so an unreadable row cannot be silently rewritten.
   for(int field = 0; field < n; field++)
   {
      if(field == 37) continue; // exit reason is the only text field
      if(StringLen(p[field]) == 0) return(false);
      bool digitSeen = false;
      int dots = 0;
      for(int c = 0; c < StringLen(p[field]); c++)
      {
         ushort ch = StringGetCharacter(p[field], c);
         if(ch >= '0' && ch <= '9') { digitSeen = true; continue; }
         if(ch == '-' && c == 0) continue;
         bool decimalField = (field == 17 || field == 18 || field == 23 ||
                              field == 24 || field == 25 || field == 30 ||
                              field == 39 || field == 45 || field == 46 || field == 47);
         if(ch == '.' && decimalField && ++dots == 1) continue;
         return(false);
      }
      if(!digitSeen) return(false);
   }
   if(StringToInteger(p[0]) != DIARY_VERSION) return(false);

   r.id            = StringToInteger(p[1]);
   r.tf            = (int)StringToInteger(p[2]);
   r.dir           = (int)StringToInteger(p[3]);
   r.score         = (int)StringToInteger(p[4]);
   r.regime        = (int)StringToInteger(p[5]);
   r.style         = (int)StringToInteger(p[6]);
   r.status        = (int)StringToInteger(p[7]);
   r.outcome       = (int)StringToInteger(p[8]);
   r.placedDay     = StringToInteger(p[9]);
   r.closedDay     = StringToInteger(p[10]);
   r.placedAt      = (datetime)StringToInteger(p[11]);
   r.closedAt      = (datetime)StringToInteger(p[12]);
   r.localPlaced   = (datetime)StringToInteger(p[13]);
   r.localClosed   = (datetime)StringToInteger(p[14]);
   r.orderTicket   = (ulong)StringToInteger(p[15]);
   r.positionId    = (ulong)StringToInteger(p[16]);
   r.lot           = StringToDouble(p[17]);
   r.entryPrice    = StringToDouble(p[18]);
   r.planSlPts     = (int)StringToInteger(p[19]);
   r.tp1Pts        = (int)StringToInteger(p[20]);
   r.tp2Pts        = (int)StringToInteger(p[21]);
   r.tp3Pts        = (int)StringToInteger(p[22]);
   r.costTp1Pct    = StringToDouble(p[23]);
   r.peakTp1Pct    = StringToDouble(p[24]);
   r.resultR       = StringToDouble(p[25]);
   r.filled        = (StringToInteger(p[26]) != 0);
   r.tp1Hit        = (StringToInteger(p[27]) != 0);
   r.tp2Hit        = (StringToInteger(p[28]) != 0);
   r.tp3Hit        = (StringToInteger(p[29]) != 0);
   r.riskPct       = StringToDouble(p[30]);
   r.useRisk       = (StringToInteger(p[31]) != 0);
   r.useMinLot     = (StringToInteger(p[32]) != 0);
   r.useStopLoss   = (StringToInteger(p[33]) != 0);
   r.useTrailStop  = (StringToInteger(p[34]) != 0);
   r.allowChoppy   = (StringToInteger(p[35]) != 0);
   r.rangeMode     = (StringToInteger(p[36]) != 0);
   r.exitReason    = p[37];
   r.provisional   = (StringToInteger(p[38]) != 0);
   r.pointValue    = StringToDouble(p[39]);

   //  Rows written before trailstop performance was recorded end at
   //  p[39].  They load with the trail state unknown, never invented.
   r.trailPct        = 0;
   r.trailSteady     = false;
   r.trailKnown      = false;
   r.trailArmed      = false;
   r.protectionArmed = false;
   r.trailLockTp1Pct = -1.0;
   r.bestLockTp1Pct  = -9999.0;
   r.finalTp1Pct     = -9999.0;
   r.stopExit        = false;
   r.stopKnown       = false;
   if(n > 40) r.trailPct        = (int)StringToInteger(p[40]);
   if(n > 41) r.trailSteady     = (StringToInteger(p[41]) != 0);
   if(n > 42) r.trailKnown      = (StringToInteger(p[42]) != 0);
   if(n > 43) r.trailArmed      = (StringToInteger(p[43]) != 0);
   if(n > 44) r.protectionArmed = (StringToInteger(p[44]) != 0);
   if(n > 45) r.trailLockTp1Pct = StringToDouble(p[45]);
   if(n > 46) r.bestLockTp1Pct  = StringToDouble(p[46]);
   if(n > 47) r.finalTp1Pct     = StringToDouble(p[47]);
   if(n > 48) r.stopExit        = (StringToInteger(p[48]) != 0);
   if(n > 49) r.stopKnown       = (StringToInteger(p[49]) != 0);
   return(r.id > 0 && r.tf >= 0 && r.tf < TF_COUNT &&
          (r.dir == 1 || r.dir == -1) && r.status >= 0 && r.status <= 2 &&
          r.outcome >= 0 && r.outcome <= 3);
}

//+------------------------------------------------------------------+
//  Rewrite through a temporary file, then move it over the diary, so
//  a terminal stopped halfway through a save leaves either the old
//  diary or the new one - never half a line of each.
//+------------------------------------------------------------------+
bool DiarySave()
{
   if(g_diaryFile == "" || g_diaryLoadFailed) return(false);
   string tmp = g_diaryFile + ".tmp";
   int h = FileOpen(tmp, FILE_WRITE | FILE_TXT | FILE_ANSI | g_diaryCommonFlag);
   if(h == INVALID_HANDLE)
   {
      if(!g_diaryWarned)
      {
         g_diaryWarned = true;
         PrintFormat("SimpleEA: calibration diary could not be written (%s, error %d). "
                     "Trading is unaffected; health history is being kept in memory only.",
                     g_diaryFile, GetLastError());
      }
      return(false);
   }

   string meta = "#;" + IntegerToString(DIARY_VERSION) + ";" +
                 IntegerToString((long)g_diaryStarted) + ";" +
                 IntegerToString(g_diaryStartedDay) + ";" + _Symbol;
   bool writeOk = (FileWriteString(h, meta + "\r\n") > 0);
   int n = ArraySize(g_diary);
   for(int k = 0; k < n && writeOk; k++)
      writeOk = (FileWriteString(h, DiaryRecordLine(g_diary[k]) + "\r\n") > 0);
   int writeErr = writeOk ? 0 : GetLastError();
   FileClose(h);
   if(!writeOk)
   {
      FileDelete(tmp, g_diaryCommonFlag);
      if(!g_diaryWarned)
      {
         g_diaryWarned = true;
         PrintFormat("SimpleEA: calibration diary write was incomplete (%s, error %d); "
                     "the previous diary file was left untouched.",
                     g_diaryFile, writeErr);
      }
      return(false);
   }

   //  FILE_REWRITE replaces the destination as part of the move; do
   //  not delete the only good diary first and open a crash window in
   //  which neither the old file nor the new one has its real name.
   if(!FileMove(tmp, g_diaryCommonFlag, g_diaryFile,
                FILE_REWRITE | g_diaryCommonFlag))
   {
      if(!g_diaryWarned)
      {
         g_diaryWarned = true;
         PrintFormat("SimpleEA: calibration diary save could not be completed (%s, error %d).",
                     g_diaryFile, GetLastError());
      }
      return(false);
   }
   return(true);
}

//+------------------------------------------------------------------+
void DiaryResetTotals(SDiaryTotals &t)
{
   t.signals   = 0;
   t.wins      = 0;
   t.losses    = 0;
   t.be        = 0;
   t.openCount = 0;
   t.waitCount = 0;
   t.expired   = 0;
   t.netR      = 0.0;
}

//+------------------------------------------------------------------+
void DiaryResetLane(int i)
{
   g_health[i].signals       = 0;
   g_health[i].wins          = 0;
   g_health[i].losses        = 0;
   g_health[i].be            = 0;
   g_health[i].openCount     = 0;
   g_health[i].waitCount     = 0;
   g_health[i].expired       = 0;
   g_health[i].closedCount   = 0;
   g_health[i].netR          = 0.0;
   g_health[i].score2Signals = 0;
   g_health[i].score2Closed  = 0;
   g_health[i].score2Wins    = 0;
   g_health[i].score2Losses  = 0;
   g_health[i].score2Tp1     = 0;
   g_health[i].score3Signals = 0;
   g_health[i].score3Closed  = 0;
   g_health[i].score3Wins    = 0;
   g_health[i].score3Losses  = 0;
   g_health[i].score3Tp1     = 0;
   g_health[i].recentCount   = 0;
   g_health[i].recN          = 0;
   g_health[i].recWins       = 0;
   g_health[i].recLosses     = 0;
   g_health[i].recBe         = 0;
   g_health[i].recTp1        = 0;
   g_health[i].recTp2        = 0;
   g_health[i].recTp3        = 0;
   g_health[i].recCostN      = 0;
   g_health[i].recNetR       = 0.0;
   g_health[i].recTp1Rate    = -1.0;
   g_health[i].recMedianPeak = -1.0;
   g_health[i].recMedianCost = -1.0;
   g_health[i].baseN         = 0;
   g_health[i].baseTp1Rate   = -1.0;
   g_health[i].baseMedianCost = -1.0;
   g_health[i].recTrailEligible = 0;
   g_health[i].recTrailArmed = 0;
   g_health[i].recTrailLockN = 0;
   g_health[i].recTrailStopKnown = 0;
   g_health[i].recTrailStopExits = 0;
   g_health[i].recTrailGivebackN = 0;
   g_health[i].recTrailArmRate = -1.0;
   g_health[i].recTrailMedianLock = -1.0;
   g_health[i].recTrailMedianGiveback = -1.0;
   g_health[i].status        = -1;
   g_health[i].primaryIssue  = 0;
   g_health[i].issueCount    = 0;
   g_health[i].followLevel   = 0;
   g_health[i].costLevel     = 0;
   g_health[i].scoreLevel    = 0;
   g_health[i].styleLevel    = 0;
   g_health[i].label         = "Health: Learning";
   g_health[i].action        = "Keep collecting; health starts at 30 observed closed trades.";
   g_health[i].note          = "";
}

//+------------------------------------------------------------------+
void DiaryComputeSegment(int lane, int start, int count, SDiarySegment &seg)
{
   seg.n         = 0;
   seg.wins      = 0;
   seg.losses    = 0;
   seg.be        = 0;
   seg.tp1       = 0;
   seg.tp2       = 0;
   seg.tp3       = 0;
   seg.nearCount = 0;
   seg.costN     = 0;
   seg.netR      = 0.0;
   seg.tp1Rate   = -1.0;
   seg.medianPeak = -1.0;
   seg.medianCost = -1.0;
   seg.trailEligible = 0;
   seg.trailArmed = 0;
   seg.trailLockN = 0;
   seg.trailStopKnown = 0;
   seg.trailStopExits = 0;
   seg.trailGivebackN = 0;
   seg.trailArmRate = -1.0;
   seg.medianTrailLock = -1.0;
   seg.medianTrailGiveback = -1.0;
   if(count <= 0 || start < 0 || start >= g_health[lane].recentCount)
      return;
   if(start + count > g_health[lane].recentCount)
      count = g_health[lane].recentCount - start;

   double peaks[];
   double costs[];
   double trailLocks[];
   double trailGivebacks[];
   ArrayResize(peaks, count);
   ArrayResize(costs, count);
   ArrayResize(trailLocks, count);
   ArrayResize(trailGivebacks, count);
   int peakN = 0;
   int costN = 0;
   int trailLockN = 0;
   int trailGivebackN = 0;

   for(int k = 0; k < count; k++)
   {
      SDiaryClosed c = g_health[lane].recent[start + k];
      seg.n++;
      if(c.outcome == 1) seg.wins++;
      else if(c.outcome == 2) seg.losses++;
      else if(c.outcome == 3) seg.be++;
      if(c.tp1Hit) seg.tp1++;
      if(c.tp2Hit) seg.tp2++;
      if(c.tp3Hit) seg.tp3++;
      if(!c.tp1Hit && c.peakTp1Pct >= 70.0 && c.peakTp1Pct < 100.0)
         seg.nearCount++;
      seg.netR += c.resultR;
      if(c.peakTp1Pct >= 0.0)
         peaks[peakN++] = c.peakTp1Pct;
      if(c.costTp1Pct > 0.0)
         costs[costN++] = c.costTp1Pct;

      //  Trailstop performance is descriptive evidence, not a fifth
      //  health verdict.  Its denominator is only the closed trades
      //  placed with the trailstop on whose live trail state the
      //  diary actually observed; old rows stay out instead of
      //  silently pretending the trail never armed.
      if(c.useTrailStop && c.trailKnown)
      {
         seg.trailEligible++;
         if(c.trailArmed)
         {
            seg.trailArmed++;
            if(c.trailLockTp1Pct >= 0.0)
               trailLocks[trailLockN++] = c.trailLockTp1Pct;
            if(c.stopKnown)
            {
               seg.trailStopKnown++;
               if(c.stopExit)
                  seg.trailStopExits++;
            }
            if(c.finalTp1Pct > -9000.0)
               trailGivebacks[trailGivebackN++] =
                  MathMax(0.0, c.peakTp1Pct - c.finalTp1Pct);
         }
      }
   }

   seg.costN = costN;
   seg.trailLockN = trailLockN;
   seg.trailGivebackN = trailGivebackN;
   if(seg.trailEligible > 0)
      seg.trailArmRate = (double)seg.trailArmed / (double)seg.trailEligible;
   if(seg.n > 0)
      seg.tp1Rate = (double)seg.tp1 / (double)seg.n;
   if(peakN > 0)
   {
      ArrayResize(peaks, peakN);
      ArraySort(peaks);
      seg.medianPeak = (peakN % 2 == 1)
                       ? peaks[peakN / 2]
                       : 0.5 * (peaks[peakN / 2 - 1] + peaks[peakN / 2]);
   }
   if(costN > 0)
   {
      ArrayResize(costs, costN);
      ArraySort(costs);
      seg.medianCost = (costN % 2 == 1)
                       ? costs[costN / 2]
                       : 0.5 * (costs[costN / 2 - 1] + costs[costN / 2]);
   }
   if(trailLockN > 0)
   {
      ArrayResize(trailLocks, trailLockN);
      ArraySort(trailLocks);
      seg.medianTrailLock = (trailLockN % 2 == 1)
                            ? trailLocks[trailLockN / 2]
                            : 0.5 * (trailLocks[trailLockN / 2 - 1] +
                                     trailLocks[trailLockN / 2]);
   }
   if(trailGivebackN > 0)
   {
      ArrayResize(trailGivebacks, trailGivebackN);
      ArraySort(trailGivebacks);
      seg.medianTrailGiveback = (trailGivebackN % 2 == 1)
                                ? trailGivebacks[trailGivebackN / 2]
                                : 0.5 * (trailGivebacks[trailGivebackN / 2 - 1] +
                                         trailGivebacks[trailGivebackN / 2]);
   }
}

//+------------------------------------------------------------------+
//  A subset (box trades, or all Choppy trades) against everything
//  else in the same recent window.  Fifteen closed trades on each
//  side is the floor: below that the split is anecdote, not evidence.
//+------------------------------------------------------------------+
int DiarySubsetLevel(int subN, int subTp1, double subR,
                     int otherN, int otherTp1, double otherR)
{
   if(subN < HEALTH_STYLE_MIN_EACH || otherN < HEALTH_STYLE_MIN_EACH)
      return(0);
   double subRate   = (double)subTp1 / (double)subN;
   double otherRate = (double)otherTp1 / (double)otherN;
   double subAvg    = subR / (double)subN;
   double otherAvg  = otherR / (double)otherN;
   double rateDiff  = subRate - otherRate;
   double avgDiff   = subAvg - otherAvg;
   if(rateDiff <= -0.20 && avgDiff <= -0.20 && subAvg <= 0.0)
      return(2);
   if(rateDiff <= -0.12 || avgDiff <= -0.15)
      return(1);
   return(0);
}

//+------------------------------------------------------------------+
//  A Poor subset verdict must also show in both chronological halves
//  of the recent window (with at least five trades on each side of
//  the split in each half).  Otherwise it stays Watch.
//+------------------------------------------------------------------+
bool DiarySubsetPersists(int lane, bool boxSplit)
{
   int startAt = (int)MathMax(0, g_health[lane].recentCount - HEALTH_RECENT_N);
   int splitAt = startAt + (g_health[lane].recentCount - startAt) / 2;
   for(int half = 0; half < 2; half++)
   {
      int start = (half == 0) ? startAt : splitAt;
      int stop  = (half == 0) ? splitAt : g_health[lane].recentCount;
      int subN = 0, subTp1 = 0, otherN = 0, otherTp1 = 0;
      double subR = 0.0, otherR = 0.0;
      for(int k = start; k < stop; k++)
      {
         SDiaryClosed c = g_health[lane].recent[k];
         bool isSub = boxSplit ? (c.style == 2) : (c.regime == 2);
         if(isSub)
         {
            subN++; subR += c.resultR; if(c.tp1Hit) subTp1++;
         }
         else
         {
            otherN++; otherR += c.resultR; if(c.tp1Hit) otherTp1++;
         }
      }
      if(subN < 5 || otherN < 5)
         return(false);
      double rateDiff = (double)subTp1 / (double)subN -
                        (double)otherTp1 / (double)otherN;
      double avgDiff  = subR / (double)subN - otherR / (double)otherN;
      if(rateDiff > 0.0 && avgDiff > 0.0)
         return(false);
   }
   return(true);
}

//+------------------------------------------------------------------+
//  THE THREE HEALTH QUESTIONS, per timeframe lane.
//
//  Follow-through: are trades still reaching TP1, and how far do they
//  typically get?  Cost: what share of TP1 does the spread now eat?
//  Score: does 3/3 still beat 2/3?  A fourth, narrower split asks
//  whether the weakness is specifically the box, or Choppy entries
//  in general, because those two have different first fixes.
//
//  Thirty closed trades is the floor before any lane is judged.  A
//  Poor verdict also has to persist: the bad pattern must appear in
//  BOTH 15-trade halves of the recent 30, not merely in one noisy
//  run.  Where an earlier 30 exists, the recent block is also
//  compared with it, so a slow decay is visible even when lifetime
//  totals still look respectable.
//+------------------------------------------------------------------+
void DiaryComputeLaneHealth(int i)
{
   SHealthLane lane = g_health[i];
   lane.status       = -1;
   lane.primaryIssue = 0;
   lane.issueCount   = 0;
   lane.followLevel  = 0;
   lane.costLevel    = 0;
   lane.scoreLevel   = 0;
   lane.styleLevel   = 0;
   lane.label        = "Health: Learning";
   lane.action       = "Keep collecting; health starts at 30 observed closed trades.";
   lane.note         = "";

   int recN    = (int)MathMin(HEALTH_RECENT_N, lane.recentCount);
   int recStart = lane.recentCount - recN;
   int baseN   = (int)MathMin(HEALTH_BASE_N, recStart);
   int baseStart = recStart - baseN;

   SDiarySegment rec, base;
   DiaryComputeSegment(i, recStart, recN, rec);
   DiaryComputeSegment(i, baseStart, baseN, base);
   lane.recN          = rec.n;
   lane.recWins       = rec.wins;
   lane.recLosses     = rec.losses;
   lane.recBe         = rec.be;
   lane.recTp1        = rec.tp1;
   lane.recTp2        = rec.tp2;
   lane.recTp3        = rec.tp3;
   lane.recCostN      = rec.costN;
   lane.recNetR       = rec.netR;
   lane.recTp1Rate    = rec.tp1Rate;
   lane.recMedianPeak = rec.medianPeak;
   lane.recMedianCost = rec.medianCost;
   lane.baseN         = base.n;
   lane.baseTp1Rate   = base.tp1Rate;
   lane.baseMedianCost = base.medianCost;
   lane.recTrailEligible = rec.trailEligible;
   lane.recTrailArmed = rec.trailArmed;
   lane.recTrailLockN = rec.trailLockN;
   lane.recTrailStopKnown = rec.trailStopKnown;
   lane.recTrailStopExits = rec.trailStopExits;
   lane.recTrailGivebackN = rec.trailGivebackN;
   lane.recTrailArmRate = rec.trailArmRate;
   lane.recTrailMedianLock = rec.medianTrailLock;
   lane.recTrailMedianGiveback = rec.medianTrailGiveback;

   if(lane.closedCount < HEALTH_MIN_CLOSED || rec.n < HEALTH_MIN_CLOSED)
   {
      g_health[i] = lane;
      return;
   }

   SDiarySegment halfOld, halfNew;
   DiaryComputeSegment(i, recStart, rec.n / 2, halfOld);
   DiaryComputeSegment(i, recStart + rec.n / 2, rec.n - rec.n / 2, halfNew);

   // ---- follow-through ---------------------------------------------
   double followDrop = (base.n >= 15 && base.tp1Rate >= 0.0 && rec.tp1Rate >= 0.0)
                       ? (base.tp1Rate - rec.tp1Rate) : 0.0;
   bool halfOldWeak = (halfOld.tp1Rate >= 0.0 &&
                       (halfOld.tp1Rate < 0.45 || (halfOld.medianPeak >= 0.0 && halfOld.medianPeak < 65.0)));
   bool halfNewWeak = (halfNew.tp1Rate >= 0.0 &&
                       (halfNew.tp1Rate < 0.45 || (halfNew.medianPeak >= 0.0 && halfNew.medianPeak < 65.0)));
   bool followPoorCandidate = (rec.tp1Rate < 0.30 || (rec.medianPeak >= 0.0 && rec.medianPeak < 45.0) ||
                               (followDrop >= 0.25 && rec.tp1Rate < 0.45));
   if(followPoorCandidate && halfOldWeak && halfNewWeak)
      lane.followLevel = 2;
   else if(rec.tp1Rate < 0.45 || (rec.medianPeak >= 0.0 && rec.medianPeak < 65.0) || followDrop >= 0.15)
      lane.followLevel = 1;

   int followIssue = (rec.medianPeak >= 50.0 ||
                      (rec.n > 0 && (double)rec.nearCount / (double)rec.n >= 0.35))
                     ? 1 : 2;   // near TP1 then reverse, versus barely moves

   // ---- cost ---------------------------------------------------------
   if(rec.costN >= 20 && rec.medianCost >= 0.0)
   {
      double costRise = (base.costN >= 15 && base.medianCost >= 0.0)
                        ? (rec.medianCost - base.medianCost) : 0.0;
      bool costPoorCandidate = (rec.medianCost >= 12.0 ||
                                (costRise >= 7.0 && rec.medianCost >= 10.0));
      bool halvesDear = (halfOld.medianCost >= 10.0 && halfNew.medianCost >= 10.0);
      if(costPoorCandidate && halvesDear)
         lane.costLevel = 2;
      else if(rec.medianCost > 8.0 || costRise >= 4.0)
         lane.costLevel = 1;
   }

   // ---- score: recent evidence, not lifetime habit -------------------
   int    s2N = 0, s3N = 0, s2Tp1 = 0, s3Tp1 = 0;
   double s2R = 0.0, s3R = 0.0;
   int    o2N = 0, o3N = 0, o2Tp1 = 0, o3Tp1 = 0;
   double o2R = 0.0, o3R = 0.0;
   int    n2N = 0, n3N = 0, n2Tp1 = 0, n3Tp1 = 0;
   double n2R = 0.0, n3R = 0.0;
   int splitAt = recStart + recN / 2;
   for(int k = recStart; k < lane.recentCount; k++)
   {
      SDiaryClosed c = lane.recent[k];
      bool newer = (k >= splitAt);
      if(c.scoreAbs >= 3)
      {
         s3N++; s3R += c.resultR; if(c.tp1Hit) s3Tp1++;
         if(newer) { n3N++; n3R += c.resultR; if(c.tp1Hit) n3Tp1++; }
         else      { o3N++; o3R += c.resultR; if(c.tp1Hit) o3Tp1++; }
      }
      else
      {
         s2N++; s2R += c.resultR; if(c.tp1Hit) s2Tp1++;
         if(newer) { n2N++; n2R += c.resultR; if(c.tp1Hit) n2Tp1++; }
         else      { o2N++; o2R += c.resultR; if(c.tp1Hit) o2Tp1++; }
      }
   }
   if(s2N >= HEALTH_SCORE_MIN_EACH && s3N >= HEALTH_SCORE_MIN_EACH)
   {
      double rateDiff = (double)s3Tp1 / (double)s3N - (double)s2Tp1 / (double)s2N;
      double avgDiff  = s3R / (double)s3N - s2R / (double)s2N;
      bool scorePoorCandidate = (rateDiff <= -0.20 && avgDiff <= -0.20);
      bool halvesKnown = (o2N >= 5 && o3N >= 5 && n2N >= 5 && n3N >= 5);
      bool halvesNotBetter = false;
      if(halvesKnown)
      {
         double oldRateDiff = (double)o3Tp1 / (double)o3N - (double)o2Tp1 / (double)o2N;
         double oldAvgDiff  = o3R / (double)o3N - o2R / (double)o2N;
         double newRateDiff = (double)n3Tp1 / (double)n3N - (double)n2Tp1 / (double)n2N;
         double newAvgDiff  = n3R / (double)n3N - n2R / (double)n2N;
         halvesNotBetter = ((oldRateDiff <= 0.0 || oldAvgDiff <= 0.0) &&
                            (newRateDiff <= 0.0 || newAvgDiff <= 0.0));
      }
      if(scorePoorCandidate && halvesKnown && halvesNotBetter)
         lane.scoreLevel = 2;
      else if(rateDiff <= -0.10 || avgDiff <= -0.15)
         lane.scoreLevel = 1;
   }

   // ---- entry style / regime split -----------------------------------
   int    boxN = 0, boxTp1 = 0, nonBoxN = 0, nonBoxTp1 = 0;
   double boxR = 0.0, nonBoxR = 0.0;
   int    chopN = 0, chopTp1 = 0, nonChopN = 0, nonChopTp1 = 0;
   double chopR = 0.0, nonChopR = 0.0;
   for(int k = recStart; k < lane.recentCount; k++)
   {
      SDiaryClosed c = lane.recent[k];
      if(c.style == 2)
      {
         boxN++; boxR += c.resultR; if(c.tp1Hit) boxTp1++;
      }
      else
      {
         nonBoxN++; nonBoxR += c.resultR; if(c.tp1Hit) nonBoxTp1++;
      }
      if(c.regime == 2)
      {
         chopN++; chopR += c.resultR; if(c.tp1Hit) chopTp1++;
      }
      else
      {
         nonChopN++; nonChopR += c.resultR; if(c.tp1Hit) nonChopTp1++;
      }
   }
   int boxLevel  = DiarySubsetLevel(boxN, boxTp1, boxR,
                                    nonBoxN, nonBoxTp1, nonBoxR);
   int chopLevel = DiarySubsetLevel(chopN, chopTp1, chopR,
                                    nonChopN, nonChopTp1, nonChopR);
   if(boxLevel == 2 && !DiarySubsetPersists(i, true))
      boxLevel = 1;
   if(chopLevel == 2 && !DiarySubsetPersists(i, false))
      chopLevel = 1;
   int styleIssue = 0;
   lane.styleLevel = (int)MathMax(boxLevel, chopLevel);
   if(boxLevel > 0 && boxLevel >= chopLevel)
      styleIssue = 5;
   else if(chopLevel > 0)
      styleIssue = 6;

   if(lane.followLevel > 0) lane.issueCount++;
   if(lane.costLevel > 0)   lane.issueCount++;
   if(lane.scoreLevel > 0)  lane.issueCount++;
   if(lane.styleLevel > 0)  lane.issueCount++;

   int worst = lane.followLevel;
   worst = (int)MathMax(worst, lane.costLevel);
   worst = (int)MathMax(worst, lane.scoreLevel);
   worst = (int)MathMax(worst, lane.styleLevel);
   lane.status = worst;

   if(worst == 0)
   {
      lane.label  = "Health: OK";
      lane.action = "No change suggested.";
      g_health[i] = lane;
      return;
   }

   //  One label and one first fix, safest and most specific first:
   //  cost before style, style before general follow-through, then score.
   if(lane.costLevel == worst)
      lane.primaryIssue = 3;
   else if(lane.styleLevel == worst)
      lane.primaryIssue = styleIssue;
   else if(lane.followLevel == worst)
      lane.primaryIssue = followIssue;
   else
      lane.primaryIssue = 4;

   string issueName = "Health";
   if(lane.primaryIssue == 1 || lane.primaryIssue == 2) issueName = "TP1";
   else if(lane.primaryIssue == 3) issueName = "Cost";
   else if(lane.primaryIssue == 4) issueName = "Score";
   else if(lane.primaryIssue == 5) issueName = "Box";
   else if(lane.primaryIssue == 6) issueName = "Chop";

   lane.label = issueName + ": " + (worst == 2 ? "Poor" : "Watch") +
                (lane.issueCount > 1 ? "+" : "");

   if(worst == 1)
   {
      if(lane.primaryIssue == 3)
         lane.action = "No change yet; watch spread as a share of TP1.";
      else if(lane.primaryIssue == 5)
         lane.action = "No change yet; keep watching the box trades.";
      else if(lane.primaryIssue == 6)
         lane.action = "No change yet; keep watching the Choppy trades.";
      else if(lane.primaryIssue == 4)
         lane.action = "No change yet; keep watching 3/3 against 2/3.";
      else
         lane.action = "No change yet; keep watching progress to TP1.";
      g_health[i] = lane;
      return;
   }

   string tag = g_rows[i].tag;
   if(lane.primaryIssue == 3)
   {
      lane.action = "Use minimum lot or avoid expensive hours first.";
      lane.note = StringFormat("Health %s: Spread is %.0f%% of TP1. %s",
                               tag, MathMax(0.0, rec.medianCost), lane.action);
   }
   else if(lane.primaryIssue == 1)
   {
      lane.action = "Test a nearer TP1 first; do not change live yet.";
      lane.note = StringFormat("Health %s: Trades reach %.0f%% of TP1 then reverse. %s",
                               tag, MathMax(0.0, rec.medianPeak), lane.action);
   }
   else if(lane.primaryIssue == 2)
   {
      lane.action = "Lower risk; consider 3/3-only while reviewing.";
      lane.note = StringFormat("Health %s: Trades only reach %.0f%% of TP1. %s",
                               tag, MathMax(0.0, rec.medianPeak), lane.action);
   }
   else if(lane.primaryIssue == 4)
   {
      lane.action = "Keep risk low and review this lane first.";
      lane.note = StringFormat("Health %s: 3/3 is not beating 2/3. %s",
                               tag, lane.action);
   }
   else if(lane.primaryIssue == 5)
   {
      lane.action = "Test Range Mode Off first (it is a global switch).";
      lane.note = StringFormat("Health %s: Box trades are the weak part. %s",
                               tag, lane.action);
   }
   else if(lane.primaryIssue == 6)
   {
      lane.action = "Consider Choppy Trade Off first (it is a global switch).";
      lane.note = StringFormat("Health %s: Choppy trades are the weak part. %s",
                               tag, lane.action);
   }
   g_health[i] = lane;
}

//+------------------------------------------------------------------+
//  Rebuild Day / All totals and every lane from the diary rows.  The
//  Day clock is the PC/VPS local day, matching the autotrading timer.
//+------------------------------------------------------------------+
void DiaryRefreshSummaries()
{
   DiaryResetTotals(g_dayTotals);
   DiaryResetTotals(g_allTotals);
   for(int i = 0; i < TF_COUNT; i++)
      DiaryResetLane(i);

   long today = DiaryDayKey(DiaryNowLocal());
   g_healthTodayKey = today;
   int total = ArraySize(g_diary);

   for(int k = 0; k < total; k++)
   {
      SDiaryRecord r = g_diary[k];
      if(r.tf < 0 || r.tf >= TF_COUNT) continue;

      g_health[r.tf].signals++;
      g_allTotals.signals++;
      if(r.placedDay == today)
         g_dayTotals.signals++;

      if(MathAbs(r.score) >= 3) g_health[r.tf].score3Signals++;
      else                      g_health[r.tf].score2Signals++;

      if(r.status == 0)
      {
         if(r.filled) { g_health[r.tf].openCount++; g_allTotals.openCount++; }
         else         { g_health[r.tf].waitCount++; g_allTotals.waitCount++; }
      }
      else if(r.status == 2)
      {
         g_health[r.tf].expired++;
         g_allTotals.expired++;
         if(r.closedDay == today)
            g_dayTotals.expired++;
      }
      else if(r.status == 1)
      {
         g_health[r.tf].closedCount++;
         g_health[r.tf].netR += r.resultR;
         g_allTotals.netR += r.resultR;
         if(r.closedDay == today)
            g_dayTotals.netR += r.resultR;

         if(r.outcome == 1)
         {
            g_health[r.tf].wins++; g_allTotals.wins++;
            if(r.closedDay == today) g_dayTotals.wins++;
         }
         else if(r.outcome == 2)
         {
            g_health[r.tf].losses++; g_allTotals.losses++;
            if(r.closedDay == today) g_dayTotals.losses++;
         }
         else if(r.outcome == 3)
         {
            g_health[r.tf].be++; g_allTotals.be++;
            if(r.closedDay == today) g_dayTotals.be++;
         }

         if(MathAbs(r.score) >= 3)
         {
            g_health[r.tf].score3Closed++;
            if(r.outcome == 1) g_health[r.tf].score3Wins++;
            else if(r.outcome == 2) g_health[r.tf].score3Losses++;
            if(r.tp1Hit) g_health[r.tf].score3Tp1++;
         }
         else
         {
            g_health[r.tf].score2Closed++;
            if(r.outcome == 1) g_health[r.tf].score2Wins++;
            else if(r.outcome == 2) g_health[r.tf].score2Losses++;
            if(r.tp1Hit) g_health[r.tf].score2Tp1++;
         }
      }
   }

   //  The health window is the newest 60 observed CLOSED trades in close-time
   //  order: the last 30 are judged, the 30 before them are the
   //  baseline they are compared with.
   bool picked[];
   ArrayResize(picked, total);
   for(int k = 0; k < total; k++)
      picked[k] = false;

   for(int i = 0; i < TF_COUNT; i++)
   {
      int want = (int)MathMin(HEALTH_RECENT_N + HEALTH_BASE_N,
                              g_health[i].closedCount);
      SDiaryClosed desc[HEALTH_RECENT_N + HEALTH_BASE_N];
      int got = 0;
      for(int pos = 0; pos < want; pos++)
      {
         int best = -1;
         long bestTime = -1;
         long bestId = -1;
         for(int k = 0; k < total; k++)
         {
            if(picked[k]) continue;
            SDiaryRecord r = g_diary[k];
            if(r.tf != i || r.status != 1) continue;
            // Offline-close rows retain their real P/L in totals, but cannot
            // prove target hits or excursions. Do not judge health from them.
            if(r.peakTp1Pct < 0.0) continue;
            long when = (long)r.closedAt;
            if(when > bestTime || (when == bestTime && r.id > bestId))
            {
               best = k;
               bestTime = when;
               bestId = r.id;
            }
         }
         if(best < 0) break;
         picked[best] = true;
         desc[got].scoreAbs    = (int)MathAbs(g_diary[best].score);
         desc[got].regime      = g_diary[best].regime;
         desc[got].style       = g_diary[best].style;
         desc[got].outcome     = g_diary[best].outcome;
         desc[got].peakTp1Pct  = g_diary[best].peakTp1Pct;
         desc[got].costTp1Pct  = g_diary[best].costTp1Pct;
         desc[got].resultR     = g_diary[best].resultR;
         desc[got].tp1Hit      = g_diary[best].tp1Hit;
         desc[got].tp2Hit      = g_diary[best].tp2Hit;
         desc[got].tp3Hit      = g_diary[best].tp3Hit;
         desc[got].useTrailStop = g_diary[best].useTrailStop;
         desc[got].trailKnown  = g_diary[best].trailKnown;
         desc[got].trailArmed  = g_diary[best].trailArmed;
         desc[got].protectionArmed = g_diary[best].protectionArmed;
         desc[got].trailLockTp1Pct = g_diary[best].trailLockTp1Pct;
         desc[got].bestLockTp1Pct = g_diary[best].bestLockTp1Pct;
         desc[got].finalTp1Pct = g_diary[best].finalTp1Pct;
         desc[got].stopExit    = g_diary[best].stopExit;
         desc[got].stopKnown   = g_diary[best].stopKnown;
         got++;
      }
      g_health[i].recentCount = got;
      for(int k = 0; k < got; k++)
         g_health[i].recent[k] = desc[got - 1 - k];
      DiaryComputeLaneHealth(i);
   }
}

//+------------------------------------------------------------------+
void DiaryAfterChange()
{
   DiarySave();
   DiaryRefreshSummaries();
}

//+------------------------------------------------------------------+
string HealthLabelText(int i)
{
   if(i < 0 || i >= TF_COUNT) return("Health: Learning");
   return(g_health[i].label);
}

//+------------------------------------------------------------------+
color HealthLabelColor(int i)
{
   if(i < 0 || i >= TF_COUNT) return(clrGray);
   if(g_health[i].status == 2) return(InpSellColor);
   if(g_health[i].status == 1) return(clrOrange);
   if(g_health[i].status == 0) return(InpBuyColor);
   return(clrGray);
}

//+------------------------------------------------------------------+
//  Exactly one temporary line, and only for a Poor lane.  The chart
//  timeframe's own warning wins; otherwise the first Poor lane is
//  shown and any others are counted rather than stacked.
//+------------------------------------------------------------------+
string HealthNoteText()
{
   int poorCount = 0;
   int firstPoor = -1;
   for(int i = 0; i < TF_COUNT; i++)
   {
      if(g_health[i].status == 2)
      {
         poorCount++;
         if(firstPoor < 0) firstPoor = i;
      }
   }
   if(firstPoor < 0) return("");

   int chosen = firstPoor;
   int chartRow = RowForChartTF();
   if(chartRow >= 0 && chartRow < TF_COUNT && g_health[chartRow].status == 2)
      chosen = chartRow;

   string note = g_health[chosen].note;
   if(poorCount > 1)
      note += StringFormat(" (+%d more)", poorCount - 1);
   return(note);
}

//+------------------------------------------------------------------+
int DiaryRegimeCode(int i)
{
   if(g_rows[i].hurst > g_rows[i].hTrend)  return(1);
   if(g_rows[i].hurst < g_rows[i].hRevert) return(2);
   return(0);
}

//+------------------------------------------------------------------+
double DiaryCostPct(double spreadPrice, int tp1Pts)
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0.0 || tp1Pts <= 0 || spreadPrice < 0.0)
      return(0.0);
   return((spreadPrice / point) / (double)tp1Pts * 100.0);
}

//+------------------------------------------------------------------+
bool DiaryDealsForPosition(ulong positionId, double &net, double &outVol,
                           ulong &entryOrder, datetime &lastDealTime,
                           double &lastExitPrice, long &lastExitReason)
{
   net = 0.0;
   outVol = 0.0;
   entryOrder = 0;
   lastDealTime = 0;
   lastExitPrice = 0.0;
   lastExitReason = -1;
   if(positionId == 0 || !HistorySelectByPosition(positionId))
      return(false);

   datetime lastExitTime = 0;
   int total = HistoryDealsTotal();
   for(int d = 0; d < total; d++)
   {
      ulong deal = HistoryDealGetTicket(d);
      if(deal == 0) continue;
      net += HistoryDealGetDouble(deal, DEAL_PROFIT);
      net += HistoryDealGetDouble(deal, DEAL_SWAP);
      net += HistoryDealGetDouble(deal, DEAL_COMMISSION);

      datetime when = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
      long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_IN)
         entryOrder = (ulong)HistoryDealGetInteger(deal, DEAL_ORDER);
      if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_INOUT)
      {
         outVol += HistoryDealGetDouble(deal, DEAL_VOLUME);
         if(when >= lastExitTime)
         {
            lastExitTime = when;
            lastExitPrice = HistoryDealGetDouble(deal, DEAL_PRICE);
            lastExitReason = HistoryDealGetInteger(deal, DEAL_REASON);
         }
      }

      if(when > lastDealTime)
         lastDealTime = when;
   }
   return(total > 0);
}

//+------------------------------------------------------------------+
bool DiaryRefreshSlotDeals(int i)
{
   ulong pos = (g_auto[i].diaryPositionId > 0)
               ? g_auto[i].diaryPositionId : g_auto[i].ticket;
   double net = 0.0, outVol = 0.0;
   ulong entryOrder = 0;
   datetime lastDeal = 0;
   double lastExitPrice = 0.0;
   long lastExitReason = -1;
   bool found = DiaryDealsForPosition(pos, net, outVol, entryOrder, lastDeal,
                                      lastExitPrice, lastExitReason);
   if(found)
   {
      g_auto[i].diaryDealNet    = net;
      g_auto[i].diaryDealVolume = outVol;
      g_auto[i].diaryLastDeal   = (ulong)lastDeal;
      g_auto[i].diaryLastExitPrice = lastExitPrice;
      g_auto[i].diaryLastExitReason = lastExitReason;
   }
   return(found);
}

//+------------------------------------------------------------------+
void DiaryApplyClosedResult(int idx, double netMoney, bool provisional,
                            datetime closeServer, datetime closeLocal,
                            string reason, double lastExitPrice,
                            long lastExitReason)
{
   if(idx < 0 || idx >= ArraySize(g_diary)) return;
   double pv = (g_diary[idx].pointValue > 0.0) ? g_diary[idx].pointValue
                                               : PointValuePerLot();
   double denom = pv * MathMax(0.0, g_diary[idx].lot) * (double)MathMax(0, g_diary[idx].planSlPts);
   g_diary[idx].resultR = (denom > 0.0) ? (netMoney / denom) : 0.0;
   if(denom > 0.0)
      g_diary[idx].outcome = (MathAbs(g_diary[idx].resultR) <= HEALTH_BE_EPS_R) ? 3
                  : ((g_diary[idx].resultR > 0.0) ? 1 : 2);
   else
      g_diary[idx].outcome = (MathAbs(netMoney) <= 0.005) ? 3
                  : ((netMoney > 0.0) ? 1 : 2);
   //  The final exit price/reason are facts only once the closing
   //  deal is complete in history.  A provisional row leaves them
   //  unknown until DiaryReconcileProvisionalRecords() corrects it,
   //  rather than mistaking a TP1 partial for the final exit.
   if(!provisional)
   {
      if(lastExitPrice > 0.0 && g_diary[idx].entryPrice > 0.0 &&
         g_diary[idx].tp1Pts > 0 && g_diary[idx].dir != 0)
      {
         double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
         if(point > 0.0)
         {
            double finalPct = (double)g_diary[idx].dir *
                              (lastExitPrice - g_diary[idx].entryPrice) /
                              point / (double)g_diary[idx].tp1Pts * 100.0;
            g_diary[idx].finalTp1Pct = MathMax(-1000.0,
                                               MathMin(1000.0, finalPct));
         }
      }
      if(lastExitReason >= 0)
      {
         g_diary[idx].stopKnown = true;
         g_diary[idx].stopExit = (lastExitReason == DEAL_REASON_SL);
      }
   }
   g_diary[idx].status      = 1;
   g_diary[idx].filled      = true;
   g_diary[idx].closedAt    = (closeServer > 0) ? closeServer : TimeCurrent();
   g_diary[idx].localClosed = (closeLocal > 0) ? closeLocal
                                    : DiaryLocalFromServer(g_diary[idx].closedAt);
   g_diary[idx].closedDay   = DiaryDayKey(g_diary[idx].localClosed);
   g_diary[idx].exitReason  = reason;
   g_diary[idx].provisional = provisional;
}

//+------------------------------------------------------------------+
//  Find the still-open diary row that belongs to a live slot: by the
//  saved row id, by position identifier, by the original order, and
//  finally - only when it is unambiguous - as the one open row for
//  this timeframe and direction.  No match means the trade predates
//  the diary; it stays untracked.
//+------------------------------------------------------------------+
int DiaryFindOpenRecordForSlot(int i)
{
   int byId = DiaryRecordIndexById(g_auto[i].diaryRecordId);
   if(byId >= 0 && g_diary[byId].status == 0 && g_diary[byId].tf == i)
      return(byId);

   ulong entryOrder = 0;
   if(g_auto[i].isOpen)
   {
      double net = 0.0, outVol = 0.0;
      datetime lastDeal = 0;
      double lastExitPrice = 0.0;
      long lastExitReason = -1;
      ulong pos = (g_auto[i].diaryPositionId > 0)
                  ? g_auto[i].diaryPositionId : g_auto[i].ticket;
      DiaryDealsForPosition(pos, net, outVol, entryOrder, lastDeal,
                            lastExitPrice, lastExitReason);
   }

   int n = ArraySize(g_diary);
   for(int k = 0; k < n; k++)
   {
      SDiaryRecord r = g_diary[k];
      if(r.tf != i || r.status != 0) continue;
      if(g_auto[i].diaryPositionId > 0 && r.positionId == g_auto[i].diaryPositionId)
         return(k);
      if(entryOrder > 0 && r.orderTicket == entryOrder)
         return(k);
      if(!g_auto[i].isOpen && g_auto[i].ticket > 0 && r.orderTicket == g_auto[i].ticket)
         return(k);
   }

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0.0) point = 0.00001;
   int candidate = -1;
   int candidates = 0;
   for(int k = 0; k < n; k++)
   {
      SDiaryRecord r = g_diary[k];
      if(r.tf != i || r.status != 0 || r.dir != g_auto[i].dir) continue;
      if(g_auto[i].isOpen && !r.filled) continue;
      if(MathAbs(r.entryPrice - g_auto[i].entryPrice) > 2.5 * point) continue;
      if(MathAbs(r.lot - MathMax(g_auto[i].initLot, g_auto[i].curLot)) > 1e-8) continue;
      candidate = k;
      candidates++;
   }
   return(candidates == 1 ? candidate : -1);
}

//+------------------------------------------------------------------+
bool DiarySyncSlotRecord(int i, bool saveNow)
{
   if(!g_diaryReady || !g_auto[i].active)
      return(false);
   int idx = DiaryRecordIndexById(g_auto[i].diaryRecordId);
   if(idx < 0 || g_diary[idx].status != 0)
      return(false);

   bool changed = false;
   if(g_auto[i].isOpen && !g_diary[idx].filled) { g_diary[idx].filled = true; changed = true; }
   if(g_auto[i].isOpen && g_auto[i].diaryPositionId > 0 &&
      g_diary[idx].positionId != g_auto[i].diaryPositionId)
   {
      g_diary[idx].positionId = g_auto[i].diaryPositionId;
      changed = true;
   }
   if(!g_auto[i].isOpen && g_auto[i].ticket > 0 && g_diary[idx].orderTicket != g_auto[i].ticket)
   {
      g_diary[idx].orderTicket = g_auto[i].ticket;
      changed = true;
   }
   if(MathAbs(g_diary[idx].entryPrice - g_auto[i].entryPrice) > 1e-12)
   {
      g_diary[idx].entryPrice = g_auto[i].entryPrice;
      changed = true;
   }
   if(!g_diary[idx].filled && g_auto[i].diaryPlanSlPts > 0 &&
      g_diary[idx].planSlPts != g_auto[i].diaryPlanSlPts)
   {
      g_diary[idx].planSlPts = g_auto[i].diaryPlanSlPts;
      changed = true;
   }
   if(g_auto[i].tp1Pts > 0 && g_diary[idx].tp1Pts != g_auto[i].tp1Pts)
   {
      g_diary[idx].tp1Pts = g_auto[i].tp1Pts;
      changed = true;
   }
   if(g_auto[i].tp2Pts > 0 && g_diary[idx].tp2Pts != g_auto[i].tp2Pts)
   {
      g_diary[idx].tp2Pts = g_auto[i].tp2Pts;
      changed = true;
   }
   if(g_auto[i].tp3Pts > 0 && g_diary[idx].tp3Pts != g_auto[i].tp3Pts)
   {
      g_diary[idx].tp3Pts = g_auto[i].tp3Pts;
      changed = true;
   }
   if(g_auto[i].diaryCostTp1Pct > 0.0 &&
      MathAbs(g_diary[idx].costTp1Pct - g_auto[i].diaryCostTp1Pct) > 0.001)
   {
      g_diary[idx].costTp1Pct = g_auto[i].diaryCostTp1Pct;
      changed = true;
   }
   if(g_auto[i].diaryPeakTp1Pct > g_diary[idx].peakTp1Pct + 0.001)
   {
      g_diary[idx].peakTp1Pct = g_auto[i].diaryPeakTp1Pct;
      changed = true;
   }

   if(g_auto[i].isOpen)
   {
      if(!g_diary[idx].trailKnown)
      {
         g_diary[idx].trailKnown = true;
         changed = true;
      }
      if(g_auto[i].trailPct > 0 && g_diary[idx].trailPct != g_auto[i].trailPct)
      {
         g_diary[idx].trailPct = g_auto[i].trailPct;
         changed = true;
      }
      if(g_auto[i].trailPct > 0 &&
         g_diary[idx].trailSteady != g_auto[i].trailSteady)
      {
         g_diary[idx].trailSteady = g_auto[i].trailSteady;
         changed = true;
      }
      //  Diary "Armed" means a pre-TP1 trail step was actually
      //  applied.  Requiring the applied level, not trailStarted
      //  alone, keeps a restart that merely finds the universal
      //  break-even SL from being misread as a trail activation.
      bool trailApplied = (g_auto[i].trailStarted && g_auto[i].trailPct > 0 &&
                           g_auto[i].trailAppliedPct + 1e-9 >=
                           (double)g_auto[i].trailPct);
      if(trailApplied && !g_diary[idx].trailArmed)
      {
         g_diary[idx].trailArmed = true;
         changed = true;
      }
      if(g_auto[i].trailActive && !g_diary[idx].protectionArmed)
      {
         g_diary[idx].protectionArmed = true;
         changed = true;
      }
      if(trailApplied && g_auto[i].trailAppliedPct > 0.0)
      {
         double trailLock = MathMax(0.0, g_auto[i].trailAppliedPct -
                                         g_auto[i].trailGapPct);
         if(trailLock > g_diary[idx].trailLockTp1Pct + 0.001)
         {
            g_diary[idx].trailLockTp1Pct = trailLock;
            changed = true;
         }
      }
      double diaryPoint = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      if(g_auto[i].slPrice > 0.0 && diaryPoint > 0.0 &&
         g_diary[idx].tp1Pts > 0 && g_diary[idx].entryPrice > 0.0 &&
         g_diary[idx].dir != 0)
      {
         double bestLock = (double)g_diary[idx].dir *
                           (g_auto[i].slPrice - g_diary[idx].entryPrice) /
                           diaryPoint / (double)g_diary[idx].tp1Pts * 100.0;
         if(bestLock > g_diary[idx].bestLockTp1Pct + 0.001)
         {
            g_diary[idx].bestLockTp1Pct = bestLock;
            changed = true;
         }
      }
   }

   bool hit1 = (g_auto[i].tp1Hit || g_diary[idx].peakTp1Pct >= 100.0 - 1e-9);
   bool hit2 = g_auto[i].tp2Hit;
   bool hit3 = false;
   if(g_diary[idx].tp1Pts > 0 && g_diary[idx].tp2Pts > 0 &&
      g_diary[idx].peakTp1Pct >= (double)g_diary[idx].tp2Pts / (double)g_diary[idx].tp1Pts * 100.0 - 1e-9)
      hit2 = true;
   if(g_diary[idx].tp1Pts > 0 && g_diary[idx].tp3Pts > 0 &&
      g_diary[idx].peakTp1Pct >= (double)g_diary[idx].tp3Pts / (double)g_diary[idx].tp1Pts * 100.0 - 1e-9)
      hit3 = true;
   if(hit1 && !g_diary[idx].tp1Hit) { g_diary[idx].tp1Hit = true; changed = true; }
   if(hit2 && !g_diary[idx].tp2Hit) { g_diary[idx].tp2Hit = true; changed = true; }
   if(hit3 && !g_diary[idx].tp3Hit) { g_diary[idx].tp3Hit = true; changed = true; }

   if(saveNow && changed)
      DiarySave();
   return(changed);
}

//+------------------------------------------------------------------+
void DiaryAttachSlotRecord(int i)
{
   if(!g_diaryReady || !g_auto[i].active)
      return;
   int idx = DiaryFindOpenRecordForSlot(i);
   if(idx < 0)
   {
      g_auto[i].diaryRecordId = 0;
      return;
   }

   SDiaryRecord r = g_diary[idx];
   bool wasFilled = r.filled;
   g_auto[i].diaryRecordId    = r.id;
   g_auto[i].diaryPlacedDayKey = r.placedDay;
   g_auto[i].diaryPlanSlPts   = r.planSlPts;
   g_auto[i].diaryRegime      = r.regime;
   g_auto[i].diaryStyle       = r.style;
   g_auto[i].diaryPlacedAt    = r.placedAt;
   g_auto[i].diaryLocalPlaced = r.localPlaced;
   g_auto[i].diaryCostTp1Pct  = r.costTp1Pct;
   g_auto[i].diaryPeakTp1Pct  = r.peakTp1Pct;
   if(r.tp1Hit) g_auto[i].tp1Hit = true;
   if(r.tp2Hit) g_auto[i].tp2Hit = true;
   if(r.protectionArmed) g_auto[i].trailActive = true;
   if(r.lot > 0.0 && g_auto[i].initLot <= 0.0)
      g_auto[i].initLot = r.lot;
   if(r.positionId > 0 && g_auto[i].diaryPositionId == 0)
      g_auto[i].diaryPositionId = r.positionId;

   //  The entry spread that matters is the one at the fill, so a
   //  pending records it when it becomes a position.
   if(g_auto[i].isOpen && !wasFilled)
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      int tp1 = (g_auto[i].tp1Pts > 0) ? g_auto[i].tp1Pts : r.tp1Pts;
      if(bid > 0.0 && ask >= bid)
         g_auto[i].diaryCostTp1Pct = DiaryCostPct(ask - bid, tp1);
   }

   DiarySyncSlotRecord(i, false);
   SaveAutoSlotState(i);
   DiaryAfterChange();
}

//+------------------------------------------------------------------+
void DiaryUpdateOpenSlot(int i, double favPts, bool saveNow)
{
   if(!g_diaryReady || !g_auto[i].active || !g_auto[i].isOpen)
      return;
   if(g_auto[i].tp1Pts > 0)
   {
      double pct = favPts / (double)g_auto[i].tp1Pts * 100.0;
      if(pct < 0.0) pct = 0.0;
      if(pct > 300.0) pct = 300.0;
      if(pct > g_auto[i].diaryPeakTp1Pct)
         g_auto[i].diaryPeakTp1Pct = pct;
   }
   DiarySyncSlotRecord(i, saveNow);
}

//+------------------------------------------------------------------+
bool DiaryPositionStillOpen(ulong positionId)
{
   if(positionId == 0) return(false);
   int total = PositionsTotal();
   for(int p = 0; p < total; p++)
   {
      ulong ticket = PositionGetTicket(p);
      if(ticket == 0) continue;
      if((ulong)PositionGetInteger(POSITION_IDENTIFIER) == positionId)
         return(true);
   }
   return(false);
}

//+------------------------------------------------------------------+
//  The one place an open slot becomes diary history.  ResetAutoSlot()
//  calls this before it wipes the slot, so every terminal path -
//  TP3, broker SL/TP, signal close, manual close noticed by sync, or
//  a pending cancelled for any reason - lands in exactly one row.
//+------------------------------------------------------------------+
void DiaryFinalizeSlot(int i)
{
   if(!g_diaryReady || g_diarySuppress[i] || !g_auto[i].active)
      return;

   int idx = DiaryRecordIndexById(g_auto[i].diaryRecordId);
   if(idx < 0)
   {
      idx = DiaryFindOpenRecordForSlot(i);
      if(idx >= 0)
         g_auto[i].diaryRecordId = g_diary[idx].id;
   }
   if(idx < 0 || g_diary[idx].status != 0)
      return;   // a pre-diary trade: deliberately untracked

   DiarySyncSlotRecord(i, false);

   if(!g_auto[i].isOpen)
   {
      //  A waiting slot can disappear from the terminal because its
      //  pending filled AND the resulting position closed while ticks
      //  were interrupted.  Ask order history which story is true
      //  before calling it Expired: a position identifier means the
      //  idea really traded.  If that position is somehow still live
      //  (a partial-fill race), leave the row open for the next sync
      //  to re-attach rather than finalising a live trade.
      ulong brokerPos = g_diary[idx].positionId;
      if(brokerPos == 0 && g_diary[idx].orderTicket > 0 &&
         HistoryOrderSelect(g_diary[idx].orderTicket))
         brokerPos = (ulong)HistoryOrderGetInteger(g_diary[idx].orderTicket,
                                                   ORDER_POSITION_ID);
      if(brokerPos > 0)
      {
         g_diary[idx].positionId = brokerPos;
         g_diary[idx].filled     = true;
         if(DiaryPositionStillOpen(brokerPos))
         {
            DiaryAfterChange();
            return;
         }

         double histNet = 0.0, histOutVol = 0.0;
         ulong entryOrder = 0;
         datetime lastDeal = 0;
         double lastExitPrice = 0.0;
         long lastExitReason = -1;
         bool dealsFound = DiaryDealsForPosition(brokerPos, histNet,
                                                 histOutVol, entryOrder,
                                                 lastDeal, lastExitPrice,
                                                 lastExitReason);
         bool complete = (dealsFound &&
                          histOutVol >= g_diary[idx].lot - 1e-8);
         DiaryApplyClosedResult(idx, histNet, !complete, lastDeal,
                                (lastDeal > 0)
                                   ? DiaryLocalFromServer(lastDeal)
                                   : DiaryNowLocal(),
                                "broker-history", lastExitPrice,
                                lastExitReason);
         DiaryAfterChange();
         return;
      }

      g_diary[idx].status      = 2;
      g_diary[idx].outcome     = 0;
      g_diary[idx].resultR     = 0.0;
      g_diary[idx].closedAt    = TimeCurrent();
      g_diary[idx].localClosed = DiaryNowLocal();
      g_diary[idx].closedDay   = DiaryDayKey(g_diary[idx].localClosed);
      g_diary[idx].exitReason  = "pending-cancelled";
      g_diary[idx].provisional = false;
      DiaryAfterChange();
      return;
   }

   bool dealsFound = DiaryRefreshSlotDeals(i);
   double originalLot = (g_diary[idx].lot > 0.0) ? g_diary[idx].lot
                                      : MathMax(g_auto[i].initLot, g_auto[i].curLot);
   bool complete = (dealsFound &&
                    g_auto[i].diaryDealVolume >= originalLot - 1e-8);
   double net = g_auto[i].diaryDealNet;
   if(!complete)
      net += g_auto[i].profitUSD;   // estimate until the deal reaches history

   string reason = g_diary[idx].tp3Hit ? "tp3" : "closed";
   DiaryApplyClosedResult(idx, net, !complete, TimeCurrent(),
                          DiaryNowLocal(), reason,
                          g_auto[i].diaryLastExitPrice,
                          g_auto[i].diaryLastExitReason);
   DiaryAfterChange();
}

//+------------------------------------------------------------------+
//  A close can be finalised a tick before its deal is visible in
//  history.  Such rows are marked provisional and corrected here on
//  a later sync, so a TP1 partial banked in the same tick as the
//  final close is never lost from the result.
//+------------------------------------------------------------------+
void DiaryReconcileProvisionalRecords()
{
   if(!g_diaryReady) return;
   bool changed = false;
   int n = ArraySize(g_diary);
   for(int k = 0; k < n; k++)
   {
      if(g_diary[k].status != 1 || !g_diary[k].provisional) continue;

      ulong pos = g_diary[k].positionId;
      if(pos == 0 && g_diary[k].orderTicket > 0 && HistoryOrderSelect(g_diary[k].orderTicket))
         pos = (ulong)HistoryOrderGetInteger(g_diary[k].orderTicket, ORDER_POSITION_ID);
      if(pos == 0) continue;

      double net = 0.0, outVol = 0.0;
      ulong entryOrder = 0;
      datetime lastDeal = 0;
      double lastExitPrice = 0.0;
      long lastExitReason = -1;
      if(!DiaryDealsForPosition(pos, net, outVol, entryOrder, lastDeal,
                                lastExitPrice, lastExitReason))
         continue;
      if(outVol < g_diary[k].lot - 1e-8)
         continue;

      g_diary[k].positionId = pos;
      DiaryApplyClosedResult(k, net, false, lastDeal,
                             DiaryLocalFromServer(lastDeal),
                             g_diary[k].tp3Hit ? "tp3" : "closed",
                             lastExitPrice, lastExitReason);
      changed = true;
   }
   if(changed)
      DiaryAfterChange();
}

//+------------------------------------------------------------------+
//  Broker-side endings while the EA was away: an SL/TP close or a
//  pending that expired at the broker.  Open rows with no live slot
//  are checked against deal/order history and closed from facts.
//+------------------------------------------------------------------+
void DiaryReconcileOpenRecords()
{
   if(!g_diaryReady) return;
   bool changed = false;
   int n = ArraySize(g_diary);

   for(int k = 0; k < n; k++)
   {
      if(g_diary[k].status != 0) continue;

      bool live = false;
      for(int i = 0; i < TF_COUNT; i++)
         if(g_auto[i].active && g_auto[i].diaryRecordId == g_diary[k].id)
            live = true;
      if(live) continue;

      ulong pos = g_diary[k].positionId;
      if(pos == 0 && g_diary[k].orderTicket > 0 && HistoryOrderSelect(g_diary[k].orderTicket))
         pos = (ulong)HistoryOrderGetInteger(g_diary[k].orderTicket, ORDER_POSITION_ID);

      if(pos > 0)
      {
         double net = 0.0, outVol = 0.0;
         ulong entryOrder = 0;
         datetime lastDeal = 0;
         double lastExitPrice = 0.0;
         long lastExitReason = -1;
         if(DiaryDealsForPosition(pos, net, outVol, entryOrder, lastDeal,
                                  lastExitPrice, lastExitReason) &&
            outVol >= g_diary[k].lot - 1e-8)
         {
            g_diary[k].positionId = pos;
            // History proves the money result, not the path price took while
            // this EA was absent. Exclude incomplete peak/trail observations.
            g_diary[k].peakTp1Pct = -1.0;
            g_diary[k].trailKnown = false;
            DiaryApplyClosedResult(k, net, false, lastDeal,
                                   DiaryLocalFromServer(lastDeal),
                                   "broker-history", lastExitPrice,
                                   lastExitReason);
            changed = true;
            continue;
         }
      }

      if(!g_diary[k].filled && g_diary[k].orderTicket > 0 && HistoryOrderSelect(g_diary[k].orderTicket))
      {
         long state = HistoryOrderGetInteger(g_diary[k].orderTicket, ORDER_STATE);
         if(state == ORDER_STATE_CANCELED || state == ORDER_STATE_EXPIRED ||
            state == ORDER_STATE_REJECTED)
         {
            datetime done = (datetime)HistoryOrderGetInteger(g_diary[k].orderTicket,
                                                             ORDER_TIME_DONE);
            g_diary[k].status      = 2;
            g_diary[k].outcome     = 0;
            g_diary[k].resultR     = 0.0;
            g_diary[k].closedAt    = (done > 0) ? done : TimeCurrent();
            g_diary[k].localClosed = DiaryLocalFromServer(g_diary[k].closedAt);
            g_diary[k].closedDay   = DiaryDayKey(g_diary[k].localClosed);
            g_diary[k].exitReason  = "pending-ended";
            g_diary[k].provisional = false;
            changed = true;
         }
      }
   }

   if(changed)
      DiaryAfterChange();
}

//+------------------------------------------------------------------+
//  S is born here, after the broker accepted the order - never from
//  a plan that was only drawn on the panel.
//+------------------------------------------------------------------+
void DiaryBeginPlacement(int i, bool market, int planSlPts, double spreadPrice)
{
   if(!g_diaryReady || !g_auto[i].active)
      return;

   datetime localNow = DiaryNowLocal();
   int regime = DiaryRegimeCode(i);
   int style = 0;
   if(market)
      style = (regime == 2) ? 4 : 0;
   else if(g_rows[i].mode == 2)
      style = 2;
   else
      style = (regime == 2) ? 3 : 1;

   g_auto[i].diaryPlacedAt     = TimeCurrent();
   g_auto[i].diaryLocalPlaced  = localNow;
   g_auto[i].diaryPlacedDayKey = DiaryDayKey(localNow);
   g_auto[i].diaryPlanSlPts    = planSlPts;
   g_auto[i].diaryRegime       = regime;
   g_auto[i].diaryStyle        = style;
   g_auto[i].diaryCostTp1Pct   = DiaryCostPct(spreadPrice, g_auto[i].tp1Pts);
   g_auto[i].diaryPeakTp1Pct   = 0.0;
   g_auto[i].diaryDealNet      = 0.0;
   g_auto[i].diaryDealVolume   = 0.0;
   g_auto[i].diaryLastDeal     = 0;
   g_auto[i].diaryLastExitPrice = 0.0;
   g_auto[i].diaryLastExitReason = -1;

   SDiaryRecord r;
   r.id            = g_diaryNextId++;
   r.tf            = i;
   r.dir           = g_auto[i].dir;
   r.score         = g_auto[i].entryScore;
   r.regime        = regime;
   r.style         = style;
   r.status        = 0;
   r.outcome       = 0;
   r.placedDay     = g_auto[i].diaryPlacedDayKey;
   r.closedDay     = 0;
   r.placedAt      = g_auto[i].diaryPlacedAt;
   r.closedAt      = 0;
   r.localPlaced   = localNow;
   r.localClosed   = 0;
   r.orderTicket   = g_auto[i].ticket;
   r.positionId    = 0;
   r.lot           = g_auto[i].initLot;
   r.entryPrice    = g_auto[i].entryPrice;
   r.planSlPts     = planSlPts;
   r.tp1Pts        = g_auto[i].tp1Pts;
   r.tp2Pts        = g_auto[i].tp2Pts;
   r.tp3Pts        = g_auto[i].tp3Pts;
   r.costTp1Pct    = g_auto[i].diaryCostTp1Pct;
   r.peakTp1Pct    = 0.0;
   r.resultR       = 0.0;
   r.filled        = market;
   r.tp1Hit        = false;
   r.tp2Hit        = false;
   r.tp3Hit        = false;
   r.riskPct       = InpRiskPct;
   r.useRisk       = InpUseRisk;
   r.useMinLot     = InpUseMinLot;
   r.useStopLoss   = InpUseStopLoss;
   r.useTrailStop  = InpUseTrailStop;
   r.allowChoppy   = InpAllowChoppyTrade;
   r.rangeMode     = InpRangeMode;
   r.pointValue    = PointValuePerLot();
   r.exitReason    = "";
   r.provisional   = false;
   r.trailPct      = market ? g_auto[i].trailPct : 0;
   r.trailSteady   = market && g_auto[i].trailSteady;
   r.trailKnown    = market;
   r.trailArmed    = market && g_auto[i].trailStarted;
   r.protectionArmed = market && g_auto[i].trailActive;
   r.trailLockTp1Pct = -1.0;
   r.bestLockTp1Pct  = -9999.0;
   r.finalTp1Pct     = -9999.0;
   r.stopExit        = false;
   r.stopKnown       = false;

   int n = ArraySize(g_diary);
   ArrayResize(g_diary, n + 1);
   g_diary[n] = r;
   g_auto[i].diaryRecordId = r.id;
   SaveAutoSlotState(i);
   DiaryAfterChange();
}

//+------------------------------------------------------------------+
//  A pending upgraded to market is the same signal acted on, so it
//  must remain one S.  The old row is held while the slot resets,
//  then merged with the market placement (or expired if that market
//  order could not be sent).
//+------------------------------------------------------------------+
void DiaryBeginUpgrade(int i)
{
   g_diarySuppress[i] = true;
   g_diaryUpgrade[i].active      = true;
   g_diaryUpgrade[i].recordId    = g_auto[i].diaryRecordId;
   g_diaryUpgrade[i].placedDay   = g_auto[i].diaryPlacedDayKey;
   g_diaryUpgrade[i].placedAt    = g_auto[i].diaryPlacedAt;
   g_diaryUpgrade[i].localPlaced = g_auto[i].diaryLocalPlaced;
   g_diaryUpgrade[i].regime      = g_auto[i].diaryRegime;

   int idx = DiaryRecordIndexById(g_auto[i].diaryRecordId);
   if(idx >= 0)
   {
      g_diaryUpgrade[i].placedDay   = g_diary[idx].placedDay;
      g_diaryUpgrade[i].placedAt    = g_diary[idx].placedAt;
      g_diaryUpgrade[i].localPlaced = g_diary[idx].localPlaced;
      g_diaryUpgrade[i].regime      = g_diary[idx].regime;
   }
}

//+------------------------------------------------------------------+
void DiaryCancelUpgrade(int i)
{
   g_diarySuppress[i] = false;
   g_diaryUpgrade[i].active = false;
}

//+------------------------------------------------------------------+
void DiaryFinishUpgrade(int i, bool placed)
{
   SDiaryUpgrade up = g_diaryUpgrade[i];
   g_diarySuppress[i] = false;
   g_diaryUpgrade[i].active = false;
   if(!g_diaryReady || !up.active)
      return;

   int oldIdx = DiaryRecordIndexById(up.recordId);
   if(placed && g_auto[i].active)
   {
      int newIdx = DiaryRecordIndexById(g_auto[i].diaryRecordId);
      if(oldIdx >= 0 && newIdx >= 0 && oldIdx != newIdx)
      {
         SDiaryRecord merged = g_diary[newIdx];
         merged.id          = g_diary[oldIdx].id;
         merged.placedDay   = g_diary[oldIdx].placedDay;
         merged.placedAt    = g_diary[oldIdx].placedAt;
         merged.localPlaced = g_diary[oldIdx].localPlaced;
         merged.regime      = g_diary[oldIdx].regime;
         g_diary[oldIdx] = merged;

         int n = ArraySize(g_diary);
         for(int k = newIdx; k < n - 1; k++)
            g_diary[k] = g_diary[k + 1];
         ArrayResize(g_diary, n - 1);

         g_auto[i].diaryRecordId     = merged.id;
         g_auto[i].diaryPlacedDayKey = merged.placedDay;
         g_auto[i].diaryPlacedAt     = merged.placedAt;
         g_auto[i].diaryLocalPlaced  = merged.localPlaced;
         g_auto[i].diaryRegime       = merged.regime;
         SaveAutoSlotState(i);
      }
      else if(newIdx >= 0 && up.placedDay > 0)
      {
         g_diary[newIdx].placedDay   = up.placedDay;
         g_diary[newIdx].placedAt    = up.placedAt;
         g_diary[newIdx].localPlaced = up.localPlaced;
         g_diary[newIdx].regime      = up.regime;
         g_auto[i].diaryPlacedDayKey = up.placedDay;
         g_auto[i].diaryPlacedAt     = up.placedAt;
         g_auto[i].diaryLocalPlaced  = up.localPlaced;
         g_auto[i].diaryRegime       = up.regime;
         SaveAutoSlotState(i);
      }
      DiaryAfterChange();
      return;
   }

   if(!g_auto[i].active)
      ClearAutoSlotState(i);
   if(oldIdx >= 0 && g_diary[oldIdx].status == 0)
   {
      g_diary[oldIdx].status      = 2;
      g_diary[oldIdx].closedAt    = TimeCurrent();
      g_diary[oldIdx].localClosed = DiaryNowLocal();
      g_diary[oldIdx].closedDay   = DiaryDayKey(g_diary[oldIdx].localClosed);
      g_diary[oldIdx].exitReason  = "upgrade-failed";
      DiaryAfterChange();
   }
}

//+------------------------------------------------------------------+
void DiaryFlushOpenSlots()
{
   if(!g_diaryReady) return;
   for(int i = 0; i < TF_COUNT; i++)
      if(g_auto[i].active)
         DiarySyncSlotRecord(i, false);
   DiarySave();
}

//+------------------------------------------------------------------+
void DiaryInit()
{
   g_diaryFile = DiaryFileName();
   g_diaryCommonFlag = MQLInfoInteger(MQL_TESTER) ? 0 : FILE_COMMON;
   ArrayResize(g_diary, 0);
   g_diaryLoadFailed = false;
   g_diaryNextId = 1;
   g_diaryStarted = 0;
   g_diaryStartedDay = 0;
   for(int i = 0; i < TF_COUNT; i++)
   {
      g_diarySuppress[i] = false;
      g_diaryUpgrade[i].active = false;
      g_diaryUpgrade[i].recordId = 0;
      g_diaryUpgrade[i].placedDay = 0;
      g_diaryUpgrade[i].placedAt = 0;
      g_diaryUpgrade[i].localPlaced = 0;
      g_diaryUpgrade[i].regime = 0;
   }

   bool needSave = false;
   if(FileIsExist(g_diaryFile, g_diaryCommonFlag))
   {
      int h = FileOpen(g_diaryFile,
                       FILE_READ | FILE_TXT | FILE_ANSI | g_diaryCommonFlag);
      if(h != INVALID_HANDLE)
      {
         while(!FileIsEnding(h))
         {
            string line = FileReadString(h);
            StringTrimLeft(line);
            StringTrimRight(line);
            if(line == "") continue;
            if(StringGetCharacter(line, 0) == '#')
            {
               string p[];
               int pc = StringSplit(line, ';', p);
               if(pc >= 4)
               {
                  g_diaryStarted = (datetime)StringToInteger(p[2]);
                  g_diaryStartedDay = StringToInteger(p[3]);
               }
               if(pc >= 2 && StringToInteger(p[1]) != DIARY_VERSION)
                  g_diaryLoadFailed = true;   // preserve a file this build cannot read
               continue;
            }
            SDiaryRecord r;
            if(!DiaryParseRecordLine(line, r))
            {
               // Never rewrite a partially readable diary: that would erase
               // the rows this build could not parse.
               g_diaryLoadFailed = true;
               Print("SimpleEA: invalid diary row; existing file is protected "
                     "from overwrite. Back it up and repair it before restarting.");
               continue;
            }
            if(DiaryRecordIndexById(r.id) >= 0)
            {
               g_diaryLoadFailed = true;
               Print("SimpleEA: duplicate diary row id; file protected from overwrite.");
               continue;
            }
            int n = ArraySize(g_diary);
            ArrayResize(g_diary, n + 1);
            g_diary[n] = r;
            if(r.id >= g_diaryNextId)
               g_diaryNextId = r.id + 1;
         }
         FileClose(h);
      }
      else
      {
         //  The file exists but cannot be read.  Keeping this run's
         //  diary in memory is inconvenient; replacing a possibly
         //  years-long history with an empty file would be far worse.
         g_diaryLoadFailed = true;
         g_diaryWarned = true;
         PrintFormat("SimpleEA: calibration diary %s exists but could not be read "
                     "(error %d). It will NOT be overwritten; close anything holding "
                     "it open and restart the EA. Trading is unaffected.",
                     g_diaryFile, GetLastError());
      }
   }
   else
      needSave = true;

   if(g_diaryStarted <= 0)
   {
      datetime earliest = 0;
      int n = ArraySize(g_diary);
      for(int k = 0; k < n; k++)
      {
         datetime t = g_diary[k].localPlaced;
         if(t > 0 && (earliest == 0 || t < earliest))
            earliest = t;
      }
      g_diaryStarted = (earliest > 0) ? earliest : DiaryNowLocal();
      needSave = true;
   }
   g_diaryStartedDay = DiaryDayKey(g_diaryStarted);

   g_diaryReady = true;
   DiaryRefreshSummaries();
   DiaryReconcileProvisionalRecords();
   if(needSave)
      DiarySave();

   if(g_diaryLoadFailed)
      PrintFormat("SimpleEA: calibration diary for %s is being kept in memory only "
                  "because the existing file could not be safely read (%s).",
                  _Symbol, g_diaryFile);
   else
      PrintFormat("SimpleEA: calibration diary for %s ready - %d record(s) since %s (%s).",
                  _Symbol, ArraySize(g_diary),
                  TimeToString(g_diaryStarted, TIME_DATE), g_diaryFile);
}

//+------------------------------------------------------------------+
void CheckDiaryDayTransition()
{
   if(!g_diaryReady) return;
   long today = DiaryDayKey(DiaryNowLocal());
   if(today == 0 || today == g_healthTodayKey) return;
   DiaryReconcileOpenRecords();
   DiaryRefreshSummaries();
   if(ChartSupported() && !MarketClosed())
   {
      DrawPanel();
      ChartRedraw(0);
   }
}

//+------------------------------------------------------------------+
string DiaryDayHeaderText()
{
   return(StringFormat("| Day: S %d W %d L %d",
                       g_dayTotals.signals, g_dayTotals.wins,
                       g_dayTotals.losses));
}

//+------------------------------------------------------------------+
string DiaryPctText(int num, int den)
{
   if(den <= 0) return("--");
   return(StringFormat("%d%%", (int)MathRound((double)num / (double)den * 100.0)));
}

//+------------------------------------------------------------------+
string DiaryRatePctText(double rate)
{
   if(rate < 0.0) return("--");
   return(StringFormat("%d%%", (int)MathRound(rate * 100.0)));
}

//+------------------------------------------------------------------+
string DiaryRText(double r)
{
   return(StringFormat("%+.1fR", r));
}

//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
string AutoStatusTag(int i)
{
   if(!g_auto[i].active) return("");
   return(g_auto[i].isOpen ? "[OPEN]" : "[PLACED]");
}

//+------------------------------------------------------------------+
bool AnyAutoActive()
{
   for(int i = 0; i < TF_COUNT; i++)
      if(g_auto[i].active) return(true);
   return(false);
}

//+------------------------------------------------------------------+
bool AnyTrailstopOn()
{
   for(int i = 0; i < TF_COUNT; i++)
      if(g_auto[i].active && g_auto[i].trailActive) return(true);
   return(false);
}

//+------------------------------------------------------------------+
bool AnyStoplossOn()
{
   for(int i = 0; i < TF_COUNT; i++)
      if(g_auto[i].active && g_auto[i].slPrice > 0.0) return(true);
   return(false);
}

//+------------------------------------------------------------------+
int ActiveAutoCount()
{
   int n = 0;
   for(int i = 0; i < TF_COUNT; i++)
      if(g_auto[i].active) n++;
   return(n);
}

//+------------------------------------------------------------------+
void ClearAutoCells(int i)
{
   g_auto[i].head    = "";
   g_auto[i].headClr = clrSilver;
   for(int l = 0; l < AUTO_LINES; l++)
      for(int c = 0; c < 3; c++)
      {
         g_auto[i].lbl[l][c] = "";
         g_auto[i].val[l][c] = "";
         g_auto[i].clr[l][c] = clrGray;
      }
}

//+------------------------------------------------------------------+
void ResetAutoSlot(int i, bool keepSignalBar)
{
   //  Diary first, while the slot still knows what it was.  This is
   //  the single exit every terminal path shares; a pending-to-market
   //  upgrade and an OnInit slot clear are the explicitly suppressed
   //  exceptions, because neither one ends the original order idea.
   DiaryFinalizeSlot(i);
   if(!g_diarySuppress[i])
      ClearAutoSlotState(i);
   datetime sigBar = keepSignalBar ? g_auto[i].lastSignalBar : 0;
   g_auto[i].active        = false;
   g_auto[i].isOpen        = false;
   g_auto[i].ticket        = 0;
   g_auto[i].dir           = 0;
   g_auto[i].entryScore    = 0;
   g_auto[i].initLot       = 0.0;
   g_auto[i].curLot        = 0.0;
   g_auto[i].entryPrice    = 0.0;
   g_auto[i].slPrice       = 0.0;
   g_auto[i].tpPrice       = 0.0;
   g_auto[i].profitUSD     = 0.0;
   g_auto[i].slPts         = 0;
   g_auto[i].tp1Pts        = 0;
   g_auto[i].tp2Pts        = 0;
   g_auto[i].tp3Pts        = 0;
   g_auto[i].tp1Hit        = false;
   g_auto[i].tp2Hit        = false;
   g_auto[i].trailActive   = false;
   g_auto[i].trailSteady   = false;
   g_auto[i].trailStarted  = false;
   g_auto[i].trailPct      = 0;
   g_auto[i].trailGapPct   = 0.0;
   g_auto[i].trailRefTp1Pts = 0;
   g_auto[i].trailPeakPts  = 0.0;
   g_auto[i].trailAppliedPct = 0.0;
   g_auto[i].trailTriedPct   = 0.0;
   g_auto[i].trailLastTry    = 0;
   g_auto[i].floorLastTry    = 0;
   g_auto[i].isRange       = false;
   g_auto[i].rngTop        = 0.0;
   g_auto[i].rngBot        = 0.0;
   g_auto[i].placedBar     = 0;
   g_auto[i].fillBar       = 0;
   g_auto[i].lastEvalBar   = 0;
   g_auto[i].lastSignalBar = sigBar;
   g_auto[i].diaryRecordId    = 0;
   g_auto[i].diaryPositionId  = 0;
   g_auto[i].diaryPlacedDayKey = 0;
   g_auto[i].diaryPlanSlPts   = 0;
   g_auto[i].diaryRegime      = 0;
   g_auto[i].diaryStyle       = 0;
   g_auto[i].diaryPlacedAt    = 0;
   g_auto[i].diaryLocalPlaced = 0;
   g_auto[i].diaryCostTp1Pct  = 0.0;
   g_auto[i].diaryPeakTp1Pct  = 0.0;
   g_auto[i].diaryDealNet     = 0.0;
   g_auto[i].diaryDealVolume  = 0.0;
   g_auto[i].diaryLastDeal    = 0;
   g_auto[i].diaryLastExitPrice = 0.0;
   g_auto[i].diaryLastExitReason = -1;
   ClearAutoCells(i);
}

//+------------------------------------------------------------------+
void InitAutoState()
{
   //  Initialisation is not a trade ending.  On a parameter-change
   //  reinit the in-memory slots can still describe live broker
   //  orders; suppress diary finalisation while they are cleared so
   //  SyncAutoState() can re-attach those same trades to their rows.
   for(int i = 0; i < TF_COUNT; i++)
   {
      g_diarySuppress[i] = true;
      ResetAutoSlot(i, false);
      g_diarySuppress[i] = false;
   }
   g_autoShown = false;
}

//+------------------------------------------------------------------+
bool CanTradeNow()
{
   if(!InpAutoTrading || !ChartSupported()) return(false);
   if(MarketClosed())                       return(false);
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return(false);
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))           return(false);
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))   return(false);
   return(true);
}
//+------------------------------------------------------------------+
//  AUTOTRADING TIMER (PC LOCAL TIME) & ONE-SHOT PAUSE
//
//  CanTradeNow() above remains the MANAGEMENT permission: master
//  switch, supported chart, market open, terminal/account allowed.
//  The timer is only a PLACEMENT gate on top of it.  That split is
//  deliberate: while the timer is OFF the EA must keep trailing,
//  taking TP1/TP2/TP3 and applying its exit rules to trades that are
//  already open - with InpUseStopLoss=false a hard freeze could
//  leave a position with no SL at all.  Waiting pendings are the
//  opposite case: they are unfilled entries resting at the broker,
//  so the OFF transition cancels them instead of letting them fill
//  while the user believes autotrading is off.
//
//  Daily start/stop read the PC/VPS local clock (TimeLocal), as
//  requested - NOT broker server time.  The one-shot pause deadline
//  is stored in GMT so a 48-hour pause lasts 48 elapsed hours even
//  across a daylight-saving change; it is persisted in a terminal
//  GlobalVariable together with the requested hours, so a restart
//  neither extends it nor restarts a completed request.  Inputs are
//  read-only in MQL5, so the EA cannot rewrite InpAutoOffHours to 0
//  in the dialog; instead the completed request stays recorded and
//  the EFFECTIVE pause becomes 0 by itself.  Set 0 (clears the
//  record), then the hours again, to run another one-shot pause.
//+------------------------------------------------------------------+
bool ParseClockMinutes(const string value, int &minutes)
{
   minutes = -1;
   string txt = value;
   StringTrimLeft(txt);
   StringTrimRight(txt);

   string parts[];
   if(StringSplit(txt, 58, parts) != 2) return(false);   // 58 = ':'
   if(StringLen(parts[0]) < 1 || StringLen(parts[0]) > 2) return(false);
   if(StringLen(parts[1]) < 1 || StringLen(parts[1]) > 2) return(false);
   for(int part = 0; part < 2; part++)
      for(int k = 0; k < StringLen(parts[part]); k++)
      {
         ushort ch = StringGetCharacter(parts[part], k);
         if(ch < '0' || ch > '9') return(false);
      }

   int hour   = (int)StringToInteger(parts[0]);
   int minute = (int)StringToInteger(parts[1]);
   if(hour < 0 || hour > 23 || minute < 0 || minute > 59) return(false);
   minutes = hour * 60 + minute;
   return(true);
}

//+------------------------------------------------------------------+
datetime PauseUntilLocal()
{
   if(g_pauseUntilGMT <= 0) return(0);
   long offset = (long)TimeLocal() - (long)TimeGMT();
   return((datetime)((long)g_pauseUntilGMT + offset));
}

//+------------------------------------------------------------------+
bool AutoPauseActive()
{
   return(g_pauseUntilGMT > 0 && TimeGMT() < g_pauseUntilGMT);
}

//+------------------------------------------------------------------+
bool InAutoScheduleWindow()
{
   if(!InpUseAutoSchedule) return(true);
   if(g_schedStartMin < 0 || g_schedEndMin < 0) return(false);

   MqlDateTime dt;
   TimeToStruct(TimeLocal(), dt);
   int nowMin = dt.hour * 60 + dt.min;
   if(g_schedStartMin < g_schedEndMin)
      return(nowMin >= g_schedStartMin && nowMin < g_schedEndMin);
   return(nowMin >= g_schedStartMin || nowMin < g_schedEndMin); // overnight
}

//+------------------------------------------------------------------+
bool AutoTimerAllowsPlacement()
{
   return(!AutoPauseActive() && InAutoScheduleWindow());
}

//+------------------------------------------------------------------+
bool CanPlaceAutoOrders()
{
   return(CanTradeNow() && AutoTimerAllowsPlacement());
}

//+------------------------------------------------------------------+
bool InitAutoTimer()
{
   if(InpAutoOffHours < 0 || InpAutoOffHours > 8760)
   {
      PrintFormat("SimpleEA: InpAutoOffHours (%d) must be between 0 and 8760 hours "
                  "(0 = no pause, 48 = two days).", InpAutoOffHours);
      return(false);
   }

   if(InpUseAutoSchedule)
   {
      if(!ParseClockMinutes(InpAutoStartTime, g_schedStartMin) ||
         !ParseClockMinutes(InpAutoEndTime,   g_schedEndMin))
      {
         PrintFormat("SimpleEA: autotrading timer times must be HH:MM between 00:00 and "
                     "23:59 (PC local); got start '%s', stop '%s'.",
                     InpAutoStartTime, InpAutoEndTime);
         return(false);
      }
      if(g_schedStartMin == g_schedEndMin)
      {
         Print("SimpleEA: autotrading timer start and stop times must be different "
               "(for 24-hour autotrading, turn InpUseAutoSchedule off).");
         return(false);
      }
   }

   //  Persisted one-shot pause identity: one deadline per account +
   //  symbol + magic base, so other charts/EAs never share it.
   long   login    = AccountInfoInteger(ACCOUNT_LOGIN);
   string identity = StringFormat("%I64d.%s.%I64d", login, _Symbol, InpMagicBase);
   string base     = "SimpleEA.Pause." + identity;
   if(StringLen(base) > 54)
   {
      uint hash = 2166136261;
      for(int k = 0; k < StringLen(identity); k++)
         hash = (hash ^ (uint)StringGetCharacter(identity, k)) * 16777619;
      base = StringFormat("SimpleEA.Pause.%u", hash);
   }
   g_pauseGVUntil = base + ".Until";
   g_pauseGVReq   = base + ".Req";

   datetime nowGMT = TimeGMT();
   if(InpAutoOffHours == 0)
   {
      bool had = (GlobalVariableCheck(g_pauseGVUntil) ||
                  GlobalVariableCheck(g_pauseGVReq));
      GlobalVariableDel(g_pauseGVUntil);
      GlobalVariableDel(g_pauseGVReq);
      if(had)
      {
         GlobalVariablesFlush();
         Print("SimpleEA: one-shot autotrading pause cleared (InpAutoOffHours = 0).");
      }
      g_pauseUntilGMT = 0;
   }
   else
   {
      double storedUntil = 0.0, storedReq = 0.0;
      bool hasUntil = (GlobalVariableCheck(g_pauseGVUntil) &&
                       GlobalVariableGet(g_pauseGVUntil, storedUntil));
      bool hasReq   = (GlobalVariableCheck(g_pauseGVReq) &&
                       GlobalVariableGet(g_pauseGVReq, storedReq));
      if(hasUntil && hasReq && storedUntil > 0.0 &&
         (int)MathRound(storedReq) == InpAutoOffHours)
      {
         //  Same request seen again (restart / reinit): keep the
         //  original deadline, completed or not.  Never extend it.
         g_pauseUntilGMT = (datetime)(long)storedUntil;
         if(g_pauseUntilGMT > nowGMT)
            PrintFormat("SimpleEA: one-shot pause continues until %s PC local "
                        "(%I64d minutes remaining); new orders are paused, open trades stay managed.",
                        TimeToString(PauseUntilLocal(), TIME_DATE | TIME_MINUTES),
                        ((long)g_pauseUntilGMT - (long)nowGMT + 59) / 60);
         else
            PrintFormat("SimpleEA: the previous %d-hour pause completed at %s PC local.  The input "
                        "still shows %d, but the effective pause is 0; set 0, then %d again, for another.",
                        InpAutoOffHours,
                        TimeToString(PauseUntilLocal(), TIME_DATE | TIME_MINUTES),
                        InpAutoOffHours, InpAutoOffHours);
      }
      else
      {
         //  A fresh request (none stored, or a different number of hours).
         g_pauseUntilGMT = nowGMT + InpAutoOffHours * 3600;
         bool savedUntil = (GlobalVariableSet(g_pauseGVUntil,
                                              (double)(long)g_pauseUntilGMT) > 0);
         bool savedReq   = (GlobalVariableSet(g_pauseGVReq,
                                              (double)InpAutoOffHours) > 0);
         if(savedUntil && savedReq)
            GlobalVariablesFlush();
         else
            PrintFormat("SimpleEA: warning - could not save the pause deadline for restart "
                        "persistence (error %d); it still applies to this run.", GetLastError());
         PrintFormat("SimpleEA: one-shot pause set for the next %d hours, until %s PC local; "
                     "new orders are paused, open trades stay managed.",
                     InpAutoOffHours,
                     TimeToString(PauseUntilLocal(), TIME_DATE | TIME_MINUTES));
      }
   }

   g_timerWasAllowed = AutoTimerAllowsPlacement();
   g_timerStateInit  = true;

   if(InpUseAutoSchedule)
      PrintFormat("SimpleEA: daily autotrading timer %02d:%02d-%02d:%02d PC local "
                  "(PC local now %s) - new orders %s.",
                  g_schedStartMin / 60, g_schedStartMin % 60,
                  g_schedEndMin / 60,   g_schedEndMin % 60,
                  TimeToString(TimeLocal(), TIME_DATE | TIME_SECONDS),
                  g_timerWasAllowed ? "allowed" : "paused");
   return(true);
}

//+------------------------------------------------------------------+
int CancelAllAutoPendings()
{
   if(!CanTradeNow()) return(0);
   SyncAutoState();
   int cancelled = 0;
   for(int i = 0; i < TF_COUNT; i++)
   {
      if(!g_auto[i].active || g_auto[i].isOpen) continue;
      if(TradeDeleteOrder(g_auto[i].ticket))
      {
         g_auto[i].lastSignalBar = g_rows[i].lastBar;
         ResetAutoSlot(i, true);
         cancelled++;
      }
   }
   if(cancelled > 0)
   {
      SyncAutoState();
      UpdatePlan();
      UpdateAutoPanel();
   }
   return(cancelled);
}

//+------------------------------------------------------------------+
void CheckAutoTimerTransition()
{
   bool allowed = AutoTimerAllowsPlacement();
   if(!g_timerStateInit)
   {
      g_timerWasAllowed = allowed;
      g_timerStateInit  = true;
      return;
   }
   if(allowed == g_timerWasAllowed)
   {
      //  Still OFF: keep retrying a failed/unavailable pending cancel
      //  (throttled), so a resting limit cannot quietly survive.
      if(!allowed && InpAutoTrading && ChartSupported())
      {
         ulong nowMs = GetTickCount64();
         if(nowMs - g_lastPendCancelTryMs >= 2000)
         {
            g_lastPendCancelTryMs = nowMs;
            CancelAllAutoPendings();
         }
      }
      //  The header's "Resume ..." countdown is minute-granular: redraw
      //  only when the displayed minute actually rolls over (the same
      //  2-second timer tick checks it, so the flip to "On" is never late).
      if(ChartSupported() && g_panelOK && ResumeMinutes() != g_resumeMinsShown)
      {
         DrawPanel();
         ChartRedraw(0);
      }
      return;
   }
   g_timerWasAllowed = allowed;

   if(!InpAutoTrading || !ChartSupported()) return;

   if(!allowed)
   {
      g_lastPendCancelTryMs = GetTickCount64();
      int cancelled = CancelAllAutoPendings();
      PrintFormat("SimpleEA: autotrading timer OFF at %s PC local - no new orders; "
                  "cancelled %d pending order(s); open trades remain managed.",
                  TimeToString(TimeLocal(), TIME_DATE | TIME_SECONDS), cancelled);
   }
   else
   {
      PrintFormat("SimpleEA: autotrading timer ON at %s PC local - new orders allowed again.",
                  TimeToString(TimeLocal(), TIME_DATE | TIME_SECONDS));
      if(g_panelOK && CanTradeNow())
      {
         ManageAutoBar();
         UpdateAutoPanel();   // cells first: DrawPanel() -> DrawAutoPanel() draws them
      }
   }
   DrawPanel();
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//  THE HEADER STATES THE EFFECTIVE STATE, NOT THE INPUT.
//
//  MQL5 inputs are read-only at run time, so an EA can never rewrite
//  InpAutoTrading when its own timer closes the door.  The header is
//  therefore the one honest place to say what is true right now:
//     Off          the master switch is off (read-only advice)
//     Timer Pause  the switch is on but the timer/pause blocks placement
//     On           the switch is on and nothing blocks placement
//  "Timer Pause" rather than "Timer Off": Off already means "the feature
//  is switched off", and the two must not read as the same thing.
//+------------------------------------------------------------------+
string AutoTradingHeaderText()
{
   if(!InpAutoTrading) return("Off");
   return(AutoTimerAllowsPlacement() ? "On" : "Timer Pause");
}

//+------------------------------------------------------------------+
color AutoTradingHeaderColor()
{
   if(!InpAutoTrading) return(InpSellColor);
   return(AutoTimerAllowsPlacement() ? InpBuyColor : clrOrange);
}

//+------------------------------------------------------------------+
//  The Main Panel header has a second line (mode/status), so its
//  band is one row taller than the one-line headers used by the
//  notice panel and the 2nd Panel.  HEAD_H remains that one-line
//  height everywhere else.
//+------------------------------------------------------------------+
int MainHeaderHeight()
{
   return(HEAD_H + g_rowH);
}

//+------------------------------------------------------------------+
int PauseRemainingMinutes()
{
   if(!AutoPauseActive()) return(0);
   long secs = (long)g_pauseUntilGMT - (long)TimeGMT();
   return((int)((secs + 59) / 60));   // rounded up: never shows 0 while paused
}

//+------------------------------------------------------------------+
//  Minutes until the daily window next opens; 0 = open now (or no
//  schedule at all).  An overnight window (22:00-06:00) is handled by
//  the same modulo: the next start is simply the next 22:00.
//+------------------------------------------------------------------+
int MinutesUntilScheduleOpen()
{
   if(!InpUseAutoSchedule || g_schedStartMin < 0 || g_schedEndMin < 0) return(0);
   if(InAutoScheduleWindow()) return(0);

   MqlDateTime dt;
   TimeToStruct(TimeLocal(), dt);
   int nowMin = dt.hour * 60 + dt.min;
   int delta  = (g_schedStartMin - nowMin + 1440) % 1440;
   return(delta > 0 ? delta : 1440);
}

//+------------------------------------------------------------------+
//  Minutes until placement is allowed again: the LATER of the daily
//  window reopening and the one-shot pause ending, because placement
//  needs both doors open.  0 = placement is allowed right now.
//+------------------------------------------------------------------+
int ResumeMinutes()
{
   if(!InpAutoTrading) return(0);
   int sched = MinutesUntilScheduleOpen();
   int pause = PauseRemainingMinutes();
   if(sched <= 0 && pause <= 0) return(0);
   return((int)MathMax(sched, pause));
}

//+------------------------------------------------------------------+
//  "Resume 2h14m" beside the header status - empty when nothing is
//  blocking, so the header is uncluttered while the timer is off (the
//  input) or open.  Long pauses read in days, the last hour in minutes.
//     Resume 2d 0h     (pause >= 24h: 48-hour request shows as 2d)
//     Resume 23h59m
//     Resume 25m
//  The longest form is 13 characters; the panel reserves that width.
//+------------------------------------------------------------------+
string ResumeHeaderText()
{
   int mins = ResumeMinutes();
   if(mins <= 0) return("");
   if(mins >= 1440)
      return(StringFormat("Resume %dd %dh", mins / 1440, (mins % 1440) / 60));
   if(mins >= 60)
      return(StringFormat("Resume %dh%02dm", mins / 60, mins % 60));
   return(StringFormat("Resume %dm", mins));
}

//+------------------------------------------------------------------+
//  "Off" = no daily schedule and no active long pause; "On <window>"
//  = the schedule is enabled and currently open; "Paused <window>" =
//  enabled but outside it; an active long pause replaces the window
//  with "Paused by request" - the exact countdown lives on header
//  line 1 now, so it is not repeated here.  Longest form: 18 chars.
//+------------------------------------------------------------------+
string TimerHeaderText()
{
   if(AutoPauseActive()) return("Paused by request");
   if(!InpUseAutoSchedule) return("Off");

   string window = StringFormat("%02d:%02d-%02d:%02d",
                                g_schedStartMin / 60, g_schedStartMin % 60,
                                g_schedEndMin / 60,   g_schedEndMin % 60);
   return((InAutoScheduleWindow() ? "On " : "Paused ") + window);
}

//+------------------------------------------------------------------+
color TimerHeaderColor()
{
   if(AutoPauseActive()) return(clrOrange);
   if(!InpUseAutoSchedule) return(clrGray);
   return(InAutoScheduleWindow() ? InpBuyColor : clrOrange);
}


//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING FillingMode()
{
   uint filling = (uint)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((filling & SYMBOL_FILLING_FOK) != 0) return(ORDER_FILLING_FOK);
   if((filling & SYMBOL_FILLING_IOC) != 0) return(ORDER_FILLING_IOC);
   return(ORDER_FILLING_RETURN);
}

//+------------------------------------------------------------------+
//  AUTO SLIPPAGE ALLOWANCE  (no input - derived per order)
//
//  One fixed point number cannot be right on every symbol: 20 points
//  is 2 pips on a 5-digit FX pair, but a fraction of the spread on a
//  3-digit gold quote or an index.  So the allowance is computed at
//  the moment of the order from live market data:
//
//     allowance = 2.5 x max(current spread, broker stops level)
//
//  - the spread is what the fill can realistically drift through;
//  - the broker's SYMBOL_TRADE_STOPS_LEVEL protects thin/synthetic
//    symbols where the minimum distance is the real constraint;
//  - clamped to 5..50 points for entries (a wide-spread symbol simply
//    stops trading rather than accepting a bad fill), and to
//    8..75 points x the same rule for CLOSES, because a rejected close
//    is worse than a slightly worse exit.
//
//  Works unchanged on 2-, 3- and 5-digit symbols, FX, metals,
//  indices, crypto and cent accounts - nothing to configure.
//+------------------------------------------------------------------+
ulong AutoSlippagePts(bool closing)
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0.0) return(closing ? 30 : 20);

   double spreadPts = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spreadPts <= 0.0)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(ask > 0.0 && bid > 0.0) spreadPts = (ask - bid) / point;
   }

   double stopsPts = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double base     = MathMax(MathMax(spreadPts, stopsPts), 1.0);

   double dev = MathRound(2.5 * base);
   if(closing) dev *= 1.5;

   double lo = closing ? 8.0 : 5.0;
   double hi = (closing ? MathMax(75.0, 3.0 * base)
                        : MathMax(50.0, 2.0 * base));
   if(dev < lo) dev = lo;
   if(dev > hi) dev = hi;
   return((ulong)dev);
}

//+------------------------------------------------------------------+
double NormPrice(double p)
{
   int dg = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   return(NormalizeDouble(p, dg));
}

//+------------------------------------------------------------------+
double FloorLotStep(double lots)
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0) step = 0.01;
   double n = MathFloor(lots / step + 1e-8) * step;
   if(n < 0.0) n = 0.0;
   int digits = 0;
   double probe = step;
   while(probe < 1.0 && digits < 8) { probe *= 10.0; digits++; }
   return(NormalizeDouble(n, digits));
}

//+------------------------------------------------------------------+
//  Rule 6: at TP1, if lot > minLot, close 70% of the lot while leaving
//  at least minLot open.
//+------------------------------------------------------------------+
double CalcTP1CloseLot(double curLot)
{
   double mn = SymbolMinLot();
   if(curLot <= mn + 1e-8) return(0.0);
   double closeLot = FloorLotStep(curLot * 0.70);
   if(curLot - closeLot < mn - 1e-8)
      closeLot = FloorLotStep(curLot - mn);
   if(closeLot < mn - 1e-8) return(0.0);
   return(closeLot);
}

//+------------------------------------------------------------------+
//  Rule 6: at TP2, if lot > minLot, reduce remaining lot size to minLot.
//+------------------------------------------------------------------+
double CalcTP2CloseLot(double curLot)
{
   double mn = SymbolMinLot();
   if(curLot <= mn + 1e-8) return(0.0);
   double closeLot = FloorLotStep(curLot - mn);
   if(closeLot < mn - 1e-8) return(0.0);
   return(closeLot);
}

//+------------------------------------------------------------------+
//  Rule 8: every timeframe trades its own signal directly.  Only when
//  InpRequireM15M30SameTrend=true are M15 and M30 tied together: their
//  trends (Going up / Going down) must match before either can place.
//+------------------------------------------------------------------+
bool TrendMatchForTF(int i)
{
   if(i == 0 || !InpRequireM15M30SameTrend)
      return(g_rows[i].ok && g_rows[i].direction != 0);
   if(!g_rows[1].ok || !g_rows[2].ok)
      return(false);
   if(g_rows[1].direction == 0 || g_rows[2].direction == 0)
      return(false);
   return(g_rows[1].direction == g_rows[2].direction);
}

//+------------------------------------------------------------------+
//  Score/direction watcher after TP1 is hit (applies to both minLot and
//  lot > minLot): holds for TP2/TP3 while direction is unchanged and
//  score stays strong; closes immediately if score weakens or flips.
//+------------------------------------------------------------------+
bool IsScoreStrongForTrade(int i)
{
   if(!g_rows[i].ok) return(true);
   if(g_rows[i].direction != g_auto[i].dir) return(false);
   int needScore = MathMax(2, MathAbs(g_auto[i].entryScore));
   if(MathAbs(g_rows[i].score) < needScore) return(false);
   return(true);
}

//+------------------------------------------------------------------+
//  May a direction flip or a range box-break close this open trade
//  right now?
//     InpImmediateFlipClose = true  -> original behaviour: close on the
//                                        flip whatever the P&L is.
//     InpImmediateFlipClose = false -> the flip is held back while the
//                                        trade is under water.  The same
//                                        flip is re-checked on every later
//                                        closed bar, so it exits once the
//                                        trade is back in profit instead
//                                        of crystallising a loss.
//  "In profit" uses the same test as the HOLD-in-profit rule: either the
//  broker floating P&L or the raw price progress is strictly positive.
//+------------------------------------------------------------------+
bool FlipCloseAllowed(int i, double favPts)
{
   if(InpImmediateFlipClose) return(true);
   return(g_auto[i].profitUSD > 0.0 || favPts > 0.0);
}

//+------------------------------------------------------------------+
//  Ensure a candidate SL price respects the broker's minimum stop
//  distance from the current exit price (Bid for BUY, Ask for SELL).
//+------------------------------------------------------------------+
double ClampSLToStopsLevel(int dir, double candSL, double bid, double ask, double point)
{
   if(candSL <= 0.0 || point <= 0.0) return(0.0);
   double minStop = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
   double pad     = MathMax(point, minStop);
   if(dir > 0)
   {
      double maxSL = bid - pad;
      if(candSL > maxSL) candSL = maxSL;
   }
   else
   {
      double minSL = ask + pad;
      if(candSL < minSL) candSL = minSL;
   }
   return(NormPrice(candSL));
}

//+------------------------------------------------------------------+
//  Ensure a candidate TP price respects the broker's minimum stop
//  distance from the current market price.
//+------------------------------------------------------------------+
double ClampTPToStopsLevel(int dir, double candTP, double bid, double ask, double point)
{
   if(candTP <= 0.0 || point <= 0.0) return(0.0);
   double minStop = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
   double pad     = MathMax(point, minStop);
   if(dir > 0)
   {
      double minTP = ask + pad;
      if(candTP < minTP) candTP = minTP;
   }
   else
   {
      double maxTP = bid - pad;
      if(candTP > maxTP) candTP = maxTP;
   }
   return(NormPrice(candTP));
}

//+------------------------------------------------------------------+
//  True only when candSL is strictly tighter (closer to price / less
//  risk) than curSL.  Used so open-trade SL updates never widen risk.
//+------------------------------------------------------------------+
bool IsSLTighter(int dir, double candSL, double curSL, double point)
{
   if(candSL <= 0.0) return(false);
   if(curSL  <= 0.0) return(true);
   if(dir > 0) return(candSL > curSL + 0.5 * point);
   return(candSL < curSL - 0.5 * point);
}

//+------------------------------------------------------------------+
//  PRE-TP1 STEPPED TRAILSTOP (Entry -> TP1 only)
//
//  One selected percentage P drives the whole trail:
//     - price covering P% of the Entry->TP1 distance ACTIVATES it;
//     - the first SL sits P% of the activation->Entry distance back
//       from the activation price (P=40: activation at +40%, SL at
//       +24%, so the gap behind price is 16% of Entry->TP1);
//     - every further +5% of progress jumps the SL another +5%, so
//       the gap stays constant;
//     - at TP1 the trail hands off: its last SL simply remains and
//       the existing TP1 / TP2 / TP3 logic takes over.
//
//  SimpleEA picks P itself at fill: InpTrailPctTight when the
//  regime is not Steady, InpTrailPctSteady in a Steady regime with
//  a clear trend in the trade's direction.  The gap behind price
//  is then widened per timeframe (M15 x1.25, M30 x1.50) so the
//  slower styles get more breathing room at the same activation.
//  All percentages use the Entry->TP1 distance frozen at fill, so
//  candle-by-candle plan updates can never shift the steps.
//+------------------------------------------------------------------+
int ClampTrailPct(int pct)
{
   if(pct < 10) return(10);
   if(pct > 70) return(70);
   return(pct);
}

//+------------------------------------------------------------------+
double TrailRoomFactor(int i)
{
   if(i == 1) return(1.25);   // M15: 25% more breathing room
   if(i == 2) return(1.50);   // M30: 50% more breathing room
   return(1.0);               // M5: the tight baseline
}

//+------------------------------------------------------------------+
//  Choose and freeze this trade's trailstop settings at fill time.
//+------------------------------------------------------------------+
void InitTrailState(int i)
{
   if(!InpUseTrailStop)
   {
      g_auto[i].trailSteady    = false;
      g_auto[i].trailPct       = 0;
      g_auto[i].trailGapPct    = 0.0;
      g_auto[i].trailRefTp1Pts = 0;
      g_auto[i].trailStarted   = false;
      g_auto[i].trailPeakPts   = 0.0;
      g_auto[i].trailAppliedPct = 0.0;
      g_auto[i].trailTriedPct   = 0.0;
      g_auto[i].trailLastTry    = 0;
      g_auto[i].floorLastTry    = 0;
      return;
   }

   bool steady = (g_rows[i].ok && !g_auto[i].isRange &&
                  g_rows[i].direction == g_auto[i].dir &&
                  g_rows[i].hurst > g_rows[i].hTrend);

   g_auto[i].trailSteady    = steady;
   g_auto[i].trailPct       = ClampTrailPct(steady ? InpTrailPctSteady
                                                   : InpTrailPctTight);
   g_auto[i].trailGapPct    = (double)g_auto[i].trailPct *
                              (double)g_auto[i].trailPct / 100.0 *
                              TrailRoomFactor(i);
   g_auto[i].trailRefTp1Pts = g_auto[i].tp1Pts;
   g_auto[i].trailStarted   = false;
   g_auto[i].trailPeakPts   = 0.0;
   g_auto[i].trailAppliedPct = 0.0;
   g_auto[i].trailTriedPct   = 0.0;
   g_auto[i].trailLastTry    = 0;
   g_auto[i].floorLastTry    = 0;
}

#define HALF_TP1_TRIGGER_RATIO 0.50   // 50% of Entry->TP1 triggers the first profit lock
#define HALF_TP1_LOCK_RATIO    0.25   // at 50% of TP1, lock SL +25% of TP1 ahead of Entry
#define TP1_LOCK_RATIO         0.50   // at 100% of TP1 (TP1 hit), lock SL +50% of TP1 ahead of Entry

//+------------------------------------------------------------------+
//  Price at a given positive multiple of the Entry->TP1 distance
//  ahead of Entry (0.25 = +25% of TP1, 0.50 = +50% of TP1, 1.00 = TP1).
//  Rounds the point offset symmetrically so BUY and SELL mirror each
//  other to the point.
//+------------------------------------------------------------------+
double MilestoneSLPrice(int dir, double entryPrice, int tp1Pts, double ratio, double point)
{
   if(entryPrice <= 0.0 || tp1Pts <= 0 || point <= 0.0 || dir == 0) return(0.0);
   double offPts = MathMax(1.0, MathFloor(ratio * (double)tp1Pts + 0.5 + 1e-9));
   return(NormPrice(entryPrice + (double)dir * offPts * point));
}

//+------------------------------------------------------------------+
//  Clamp a profit-protection SL to broker stops level, refusing to
//  place a stop behind Entry if the broker's stops level is wider than
//  current favorable progress.
//+------------------------------------------------------------------+
double ClampProfitFloorSL(int dir, double entryPrice, double wantSL,
                          double bid, double ask, double point)
{
   double sl = ClampSLToStopsLevel(dir, wantSL, bid, ask, point);
   if(sl <= 0.0) return(0.0);
   if((double)dir * (sl - entryPrice) < -0.5 * point) return(0.0);
   return(sl);
}

//+------------------------------------------------------------------+
//  Universal 3-Step Profit-Protection Stop-Loss Floor.
//  Operates whether Trailstop is ON or OFF:
//     - 50% of TP1 reached  -> SL moves to +25% of TP1 ahead of Entry
//     - 100% of TP1 (TP1)   -> SL moves to +50% of TP1 ahead of Entry
//     - TP2 (75% of TP3)    -> SL moves to TP1 price (100% of TP1)
//  Never moves a tighter SL backwards, and retries (throttled) if an
//  earlier modify was rejected or temporarily clamped by stops level.
//+------------------------------------------------------------------+
bool UpdateProfitProtectionFloor(int i, double favPts, double bid, double ask, double point)
{
   if(g_auto[i].entryPrice <= 0.0 || point <= 0.0 || g_auto[i].tp1Pts <= 0)
      return(false);

   int    dir    = g_auto[i].dir;
   double wantSL = 0.0;
   if(g_auto[i].tp2Hit)
      wantSL = NormPrice(g_auto[i].entryPrice + (double)dir * (double)g_auto[i].tp1Pts * point);
   else if(g_auto[i].tp1Hit)
      wantSL = MilestoneSLPrice(dir, g_auto[i].entryPrice, g_auto[i].tp1Pts, TP1_LOCK_RATIO, point);
   else if(favPts >= HALF_TP1_TRIGGER_RATIO * (double)g_auto[i].tp1Pts - 1e-6)
      wantSL = MilestoneSLPrice(dir, g_auto[i].entryPrice, g_auto[i].tp1Pts, HALF_TP1_LOCK_RATIO, point);
   else
      return(false);

   double floorSL = ClampProfitFloorSL(dir, g_auto[i].entryPrice, wantSL, bid, ask, point);
   if(floorSL <= 0.0) return(false);

   if(!IsSLTighter(dir, floorSL, g_auto[i].slPrice, point))
      return(false);

   datetime now = TimeCurrent();
   if(g_auto[i].floorLastTry > 0 && now - g_auto[i].floorLastTry < 3)
      return(false);

   if(!TradeModifyPosition(g_auto[i].ticket, floorSL, g_auto[i].tpPrice))
   {
      g_auto[i].floorLastTry = now;
      return(false);
   }

   g_auto[i].floorLastTry = 0;
   g_auto[i].slPrice      = floorSL;
   g_auto[i].slPts        = (int)MathRound(MathAbs(g_auto[i].entryPrice - floorSL) / point);
   g_auto[i].trailActive  = true;
   SaveAutoSlotState(i);
   return(true);
}

//+------------------------------------------------------------------+
//  Tick-level pre-TP1 trailstop.  Returns true when the trail state
//  changed (activation or a step applied), so the caller can flag a
//  panel redraw.  Never moves an SL backwards, respects the universal
//  +25%-of-TP1 profit floor once 50% of TP1 has been covered, and
//  places the first SL itself when the order was opened without one
//  (InpUseStopLoss=false).
//+------------------------------------------------------------------+
bool UpdatePreTP1Trail(int i, double favPts, double bid, double ask, double point)
{
   if(!InpUseTrailStop || g_auto[i].tp1Hit) return(false);
   if(g_auto[i].trailRefTp1Pts <= 0 || g_auto[i].trailPct <= 0) return(false);
   if(g_auto[i].entryPrice <= 0.0 || point <= 0.0) return(false);

   if(favPts > g_auto[i].trailPeakPts)
      g_auto[i].trailPeakPts = favPts;

   double peakPct = g_auto[i].trailPeakPts / (double)g_auto[i].trailRefTp1Pts * 100.0;
   if(peakPct < (double)g_auto[i].trailPct) return(false);

   // Highest completed 5% step (capped at TP1 = 100% for the handoff)
   double cappedPct = MathMin(peakPct, 100.0);
   double steps     = MathFloor((cappedPct - (double)g_auto[i].trailPct) /
                                TRAIL_STEP_PCT + 1e-9);
   double levelPct  = (double)g_auto[i].trailPct + steps * TRAIL_STEP_PCT;
   if(levelPct <= g_auto[i].trailAppliedPct + 1e-9) return(false);

   // A failed modify for this step is retried, but not on every tick
   datetime now = TimeCurrent();
   if(MathAbs(levelPct - g_auto[i].trailTriedPct) < 1e-9 &&
      g_auto[i].trailLastTry > 0 && now - g_auto[i].trailLastTry < 5)
      return(false);

   int    dir        = g_auto[i].dir;
   double slProgPct  = levelPct - g_auto[i].trailGapPct;
   double candSL     = NormPrice(g_auto[i].entryPrice +
                                 (double)dir * slProgPct / 100.0 *
                                 (double)g_auto[i].trailRefTp1Pts * point);
   if(g_auto[i].tp1Pts > 0 &&
      favPts >= HALF_TP1_TRIGGER_RATIO * (double)g_auto[i].tp1Pts - 1e-6)
   {
      double floorWant = MilestoneSLPrice(dir, g_auto[i].entryPrice,
                                          g_auto[i].tp1Pts, HALF_TP1_LOCK_RATIO, point);
      if(IsSLTighter(dir, floorWant, candSL, point))
         candSL = floorWant;
   }
   candSL            = ClampSLToStopsLevel(dir, candSL, bid, ask, point);
   if(candSL <= 0.0) return(false);

   if(!IsSLTighter(dir, candSL, g_auto[i].slPrice, point))
   {
      // The SL already in place protects at least this much: count
      // the step as applied and never pull the SL back to the trail.
      g_auto[i].trailAppliedPct = levelPct;
      g_auto[i].trailStarted    = true;
      g_auto[i].trailActive     = true;
      SaveAutoSlotState(i);
      return(true);
   }

   g_auto[i].trailTriedPct = levelPct;
   g_auto[i].trailLastTry  = now;
   if(!TradeModifyPosition(g_auto[i].ticket, candSL, g_auto[i].tpPrice))
      return(false);

   g_auto[i].slPrice         = candSL;
   g_auto[i].slPts           = (int)MathRound(MathAbs(g_auto[i].entryPrice - candSL) / point);
   g_auto[i].trailAppliedPct = levelPct;
   g_auto[i].trailStarted    = true;
   g_auto[i].trailActive     = true;
   SaveAutoSlotState(i);
   return(true);
}

//+------------------------------------------------------------------+
//  Ensure a pending limit entry price sits on the valid side of the
//  current market (below Ask for BUY LIMIT, above Bid for SELL LIMIT).
//+------------------------------------------------------------------+
double ValidLimitPrice(int dir, double wantPrice, double bid, double ask, double point)
{
   double minStop = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
   double pad     = MathMax(point, minStop);
   double p       = wantPrice;
   if(dir > 0 && p >= ask - pad) p = ask - pad;
   if(dir < 0 && p <= bid + pad) p = bid + pad;
   return(NormPrice(p));
}

//+------------------------------------------------------------------+
//  Has a deal for timeframe `i` already entered on `barTime`?
//+------------------------------------------------------------------+
bool HasTradedOnBar(int i, datetime barTime)
{
   if(barTime <= 0) return(false);
   if(g_auto[i].lastSignalBar == barTime) return(true);
   if(!HistorySelect(barTime, TimeCurrent() + 60)) return(false);
   long magic = MagicForTF(i);
   int  total = HistoryDealsTotal();
   for(int d = 0; d < total; d++)
   {
      ulong deal = HistoryDealGetTicket(d);
      if(deal == 0) continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol) continue;
      if(HistoryDealGetInteger(deal, DEAL_MAGIC) != magic)   continue;
      if(HistoryDealGetInteger(deal, DEAL_ENTRY) == DEAL_ENTRY_IN)
      {
         g_auto[i].lastSignalBar = barTime;
         return(true);
      }
   }
   return(false);
}

//+------------------------------------------------------------------+
//  Low-level order wrappers (self-contained MqlTradeRequest calls).
//+------------------------------------------------------------------+
bool TradeOpenMarket(int i, int dir, double lot, double sl, double tp, ulong &outTicket)
{
   outTicket = 0;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0) return(false);

   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);

   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = _Symbol;
   req.volume       = lot;
   req.type         = (dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   req.price        = NormPrice((dir > 0) ? ask : bid);
   req.sl           = (sl > 0.0) ? NormPrice(sl) : 0.0;
   req.tp           = (tp > 0.0) ? NormPrice(tp) : 0.0;
   req.deviation    = AutoSlippagePts(false);   // open: live spread based
   req.magic        = MagicForTF(i);
   req.comment      = "SimpleEA_" + g_rows[i].tag;
   req.type_filling = FillingMode();

   bool sent = OrderSend(req, res);
   NoteMarketClosedRetcode(res.retcode);
   if(!sent) return(false);
   if(res.retcode != TRADE_RETCODE_DONE && res.retcode != TRADE_RETCODE_PLACED)
      return(false);
   outTicket = (res.order > 0) ? res.order : res.deal;
   return(true);
}

//+------------------------------------------------------------------+
bool TradePlaceLimit(int i, int dir, double lot, double price, double sl, double tp,
                     ulong &outTicket)
{
   outTicket = 0;
   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);

   req.action       = TRADE_ACTION_PENDING;
   req.symbol       = _Symbol;
   req.volume       = lot;
   req.type         = (dir > 0) ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_SELL_LIMIT;
   req.price        = NormPrice(price);
   req.sl           = (sl > 0.0) ? NormPrice(sl) : 0.0;
   req.tp           = (tp > 0.0) ? NormPrice(tp) : 0.0;
   req.magic        = MagicForTF(i);
   req.comment      = "SimpleEA_" + g_rows[i].tag;
   req.type_filling = FillingMode();
   req.type_time    = ORDER_TIME_GTC;

   bool sent = OrderSend(req, res);
   NoteMarketClosedRetcode(res.retcode);
   if(!sent) return(false);
   if(res.retcode != TRADE_RETCODE_DONE && res.retcode != TRADE_RETCODE_PLACED)
      return(false);
   outTicket = res.order;
   return(true);
}

//+------------------------------------------------------------------+
bool TradeModifyPosition(ulong posTicket, double newSL, double newTP)
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0.0) point = 0.00001;

   double normSL = (newSL > 0.0) ? NormPrice(newSL) : 0.0;
   double normTP = (newTP > 0.0) ? NormPrice(newTP) : 0.0;

   if(PositionSelectByTicket(posTicket))
   {
      double curSL = PositionGetDouble(POSITION_SL);
      double curTP = PositionGetDouble(POSITION_TP);
      if(MathAbs(normSL - curSL) < 0.5 * point &&
         MathAbs(normTP - curTP) < 0.5 * point)
         return(true);
   }

   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);

   req.action   = TRADE_ACTION_SLTP;
   req.position = posTicket;
   req.symbol   = _Symbol;
   req.sl       = normSL;
   req.tp       = normTP;

   if(!OrderSend(req, res))
   {
      NoteMarketClosedRetcode(res.retcode);
      if(res.retcode == TRADE_RETCODE_NO_CHANGES) return(true);
      int dg = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      PrintFormat("SimpleEA: TradeModifyPosition(#%I64u) failed retcode=%u sl=%.*f tp=%.*f",
                  posTicket, res.retcode, dg, normSL, dg, normTP);
      return(false);
   }
   return(res.retcode == TRADE_RETCODE_DONE ||
          res.retcode == TRADE_RETCODE_DONE_PARTIAL ||
          res.retcode == TRADE_RETCODE_PLACED ||
          res.retcode == TRADE_RETCODE_NO_CHANGES);
}

//+------------------------------------------------------------------+
bool TradeClosePosition(ulong posTicket, int dir, double volume, long magic)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0) return(false);

   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);

   req.action       = TRADE_ACTION_DEAL;
   req.position     = posTicket;
   req.symbol       = _Symbol;
   req.volume       = volume;
   req.type         = (dir > 0) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   req.price        = NormPrice((dir > 0) ? bid : ask);
   req.deviation    = AutoSlippagePts(true);    // close: slightly looser
   req.magic        = magic;
   req.type_filling = FillingMode();

   bool sent = OrderSend(req, res);
   NoteMarketClosedRetcode(res.retcode);
   if(!sent) return(false);
   return(res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_DONE_PARTIAL);
}

//+------------------------------------------------------------------+
bool TradeModifyOrder(ulong ordTicket, double newPrice, double newSL, double newTP)
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0.0) point = 0.00001;

   double normP  = NormPrice(newPrice);
   double normSL = (newSL > 0.0) ? NormPrice(newSL) : 0.0;
   double normTP = (newTP > 0.0) ? NormPrice(newTP) : 0.0;

   ENUM_ORDER_TYPE_TIME typeTime = ORDER_TIME_GTC;
   datetime             expTime  = 0;
   double               stopLim  = 0.0;

   if(OrderSelect(ordTicket))
   {
      double curP  = OrderGetDouble(ORDER_PRICE_OPEN);
      double curSL = OrderGetDouble(ORDER_SL);
      double curTP = OrderGetDouble(ORDER_TP);
      if(MathAbs(normP  - curP)  < 0.5 * point &&
         MathAbs(normSL - curSL) < 0.5 * point &&
         MathAbs(normTP - curTP) < 0.5 * point)
         return(true);

      typeTime = (ENUM_ORDER_TYPE_TIME)OrderGetInteger(ORDER_TYPE_TIME);
      expTime  = (datetime)OrderGetInteger(ORDER_TIME_EXPIRATION);
      stopLim  = OrderGetDouble(ORDER_PRICE_STOPLIMIT);
   }

   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);

   req.action     = TRADE_ACTION_MODIFY;
   req.order      = ordTicket;
   req.symbol     = _Symbol;
   req.price      = normP;
   req.sl         = normSL;
   req.tp         = normTP;
   req.stoplimit  = stopLim;
   req.type_time  = typeTime;
   req.expiration = expTime;

   if(!OrderSend(req, res))
   {
      NoteMarketClosedRetcode(res.retcode);
      if(res.retcode == TRADE_RETCODE_NO_CHANGES) return(true);
      int dg = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      PrintFormat("SimpleEA: TradeModifyOrder(#%I64u) failed retcode=%u price=%.*f sl=%.*f tp=%.*f",
                  ordTicket, res.retcode, dg, normP, dg, normSL, dg, normTP);
      return(false);
   }
   return(res.retcode == TRADE_RETCODE_DONE ||
          res.retcode == TRADE_RETCODE_PLACED ||
          res.retcode == TRADE_RETCODE_NO_CHANGES);
}

//+------------------------------------------------------------------+
bool TradeDeleteOrder(ulong ordTicket)
{
   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);

   req.action = TRADE_ACTION_REMOVE;
   req.order  = ordTicket;

   bool sent = OrderSend(req, res);
   NoteMarketClosedRetcode(res.retcode);
   if(!sent) return(false);
   return(res.retcode == TRADE_RETCODE_DONE);
}

//+------------------------------------------------------------------+
//  Synchronize g_auto[] with the broker's live open positions and
//  pending orders on _Symbol.
//+------------------------------------------------------------------+
void SyncAutoState()
{
   DiaryReconcileProvisionalRecords();
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0.0) point = 0.00001;

   for(int i = 0; i < TF_COUNT; i++)
   {
      long  magic      = MagicForTF(i);
      bool  foundPos   = false;
      bool  foundOrd   = false;
      bool  wasActive  = g_auto[i].active;
      bool  wasOpen    = (g_auto[i].active && g_auto[i].isOpen);
      bool  wasPending = (g_auto[i].active && !g_auto[i].isOpen);

      // ---- 1. Check open positions for this timeframe's magic -------
      int posTotal = PositionsTotal();
      for(int p = 0; p < posTotal; p++)
      {
         ulong tk = PositionGetTicket(p);
         if(tk == 0) continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
         if(PositionGetInteger(POSITION_MAGIC) != magic)   continue;

         foundPos             = true;
         g_auto[i].active     = true;
         g_auto[i].isOpen     = true;
         g_auto[i].ticket     = tk;
         g_auto[i].diaryPositionId = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
         g_auto[i].dir        = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
         g_auto[i].curLot     = PositionGetDouble(POSITION_VOLUME);
         g_auto[i].entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         g_auto[i].slPrice    = PositionGetDouble(POSITION_SL);
         g_auto[i].tpPrice    = PositionGetDouble(POSITION_TP);
         g_auto[i].profitUSD  = PositionGetDouble(POSITION_PROFIT);
         if(!wasOpen)
            g_auto[i].fillBar = g_rows[i].lastBar;   // fill noticed on this bar

         if(g_auto[i].slPrice > 0.0)
            g_auto[i].slPts = (int)MathRound(MathAbs(g_auto[i].entryPrice - g_auto[i].slPrice) / point);
         else
            g_auto[i].slPts = 0;

         // Recover or transition state when a pending order just filled or EA restarted
         if(!wasOpen)
         {
            if(!wasActive)
               RestoreAutoSlotState(i);
            if(g_auto[i].initLot <= 0.0)
               g_auto[i].initLot = g_auto[i].curLot;
            if(g_auto[i].entryScore == 0)
               g_auto[i].entryScore = (g_rows[i].direction == g_auto[i].dir && g_rows[i].score != 0)
                                      ? g_rows[i].score : (g_auto[i].dir * (wasPending ? 2 : 3));

            if(g_auto[i].tp3Pts <= 0)
            {
               int recTp3 = (g_auto[i].tpPrice > 0.0)
                  ? (int)MathMax(1.0, MathRound(MathAbs(g_auto[i].tpPrice - g_auto[i].entryPrice) / point))
                  : (g_plans[i].tp3Pts > 0 ? g_plans[i].tp3Pts : 50);
               int recTp1 = 1, recTp2 = 1;
               ComputeTPLevels(recTp3, recTp1, recTp2);
               g_auto[i].tp1Pts = recTp1;
               g_auto[i].tp2Pts = recTp2;
               g_auto[i].tp3Pts = recTp3;
            }

            // A freshly filled pending (or a position found after a
            // restart) gets its pre-TP1 trailstop settings frozen now,
            // against the TP1 distance recovered / carried above.
            double savedTapp = (!wasActive) ? g_auto[i].trailAppliedPct : 0.0;
            if(InpUseTrailStop && g_auto[i].trailRefTp1Pts <= 0)
               InitTrailState(i);
            if(savedTapp > 0.0)
               g_auto[i].trailAppliedPct = savedTapp;

            // Recover the trail / TP milestone state from persisted slot
            // flags and where the broker SL sits:
            //   SL at / beyond TP1    -> TP1 & TP2 were hit (SL locked to TP1)
            //   SL at +50%..TP1 (off) -> TP1 was hit (+50% of TP1 lock)
            //   SL at +25% (off)      -> 50%-of-TP1 floor active, TP1 NOT yet hit
            //   SL in profit (on)     -> trail / floor active; restore applied step
            if(g_auto[i].slPrice > 0.0)
            {
               double slFavPts    = (g_auto[i].dir > 0)
                                    ? (g_auto[i].slPrice - g_auto[i].entryPrice) / point
                                    : (g_auto[i].entryPrice - g_auto[i].slPrice) / point;
               double halfLockPts = MathMax(1.0, MathFloor(HALF_TP1_LOCK_RATIO * (double)g_auto[i].tp1Pts + 0.5 + 1e-9));
               double tp1LockPts  = MathMax(1.0, MathFloor(TP1_LOCK_RATIO * (double)g_auto[i].tp1Pts + 0.5 + 1e-9));

               if(g_auto[i].tp1Pts > 0 && slFavPts >= (double)g_auto[i].tp1Pts - 0.5)
               {
                  g_auto[i].tp1Hit      = true;
                  g_auto[i].tp2Hit      = true;
                  g_auto[i].trailActive = true;
                  if(InpUseTrailStop)
                     g_auto[i].trailStarted = true;
               }
               else if(!InpUseTrailStop)
               {
                  if(g_auto[i].tp1Pts > 0 && slFavPts >= tp1LockPts - 0.5)
                  {
                     g_auto[i].tp1Hit      = true;
                     g_auto[i].trailActive = true;
                  }
                  else if(slFavPts >= -0.5)
                  {
                     g_auto[i].trailActive = true;
                  }
               }
               else
               {
                  if(g_auto[i].trailAppliedPct > 0.0)
                  {
                     g_auto[i].trailStarted = true;
                     g_auto[i].trailActive  = true;
                     if(g_auto[i].trailRefTp1Pts > 0)
                        g_auto[i].trailPeakPts = g_auto[i].trailAppliedPct / 100.0 *
                                                 (double)g_auto[i].trailRefTp1Pts;
                  }
                  else if(MathAbs(slFavPts) <= 0.5)
                  {
                     g_auto[i].tp1Hit       = true;
                     g_auto[i].trailStarted = true;
                     g_auto[i].trailActive  = true;
                  }
                  else if(slFavPts > 0.5)
                  {
                     g_auto[i].trailActive = true;
                     if(g_auto[i].trailRefTp1Pts > 0 &&
                        MathAbs(slFavPts - halfLockPts) > 0.5)
                     {
                        double slPct = slFavPts / (double)g_auto[i].trailRefTp1Pts * 100.0;
                        if(slPct + g_auto[i].trailGapPct >= (double)g_auto[i].trailPct - 0.5)
                        {
                           g_auto[i].trailStarted    = true;
                           g_auto[i].trailAppliedPct = MathMin(100.0, slPct + g_auto[i].trailGapPct);
                           g_auto[i].trailPeakPts    = g_auto[i].trailAppliedPct / 100.0 *
                                                       (double)g_auto[i].trailRefTp1Pts;
                        }
                     }
                  }
               }
            }
            if(g_auto[i].lastSignalBar == 0)
               g_auto[i].lastSignalBar = g_rows[i].lastBar;
            DiaryAttachSlotRecord(i);
         }
         break;
      }

      if(foundPos) continue;

      // ---- 2. Check pending limit orders for this timeframe's magic -
      int ordTotal = OrdersTotal();
      for(int o = 0; o < ordTotal; o++)
      {
         ulong tk = OrderGetTicket(o);
         if(tk == 0) continue;
         if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
         if(OrderGetInteger(ORDER_MAGIC) != magic)   continue;

         ENUM_ORDER_TYPE otype = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
         foundOrd             = true;
         g_auto[i].active     = true;
         g_auto[i].isOpen     = false;
         g_auto[i].ticket     = tk;
         g_auto[i].dir        = (otype == ORDER_TYPE_BUY_LIMIT || otype == ORDER_TYPE_BUY_STOP) ? 1 : -1;
         g_auto[i].curLot     = OrderGetDouble(ORDER_VOLUME_CURRENT);
         g_auto[i].entryPrice = OrderGetDouble(ORDER_PRICE_OPEN);
         g_auto[i].slPrice    = OrderGetDouble(ORDER_SL);
         g_auto[i].tpPrice    = OrderGetDouble(ORDER_TP);
         g_auto[i].profitUSD  = 0.0;

         if(g_auto[i].slPrice > 0.0)
            g_auto[i].slPts = (int)MathRound(MathAbs(g_auto[i].entryPrice - g_auto[i].slPrice) / point);
         else
            g_auto[i].slPts = 0;

         if(!wasActive)
         {
            RestoreAutoSlotState(i);
            g_auto[i].initLot    = g_auto[i].curLot;
            g_auto[i].entryScore = (g_rows[i].direction == g_auto[i].dir && g_rows[i].score != 0)
                                   ? g_rows[i].score : (g_auto[i].dir * 2);
            int recTp3 = (g_auto[i].tpPrice > 0.0)
               ? (int)MathMax(1.0, MathRound(MathAbs(g_auto[i].tpPrice - g_auto[i].entryPrice) / point))
               : (g_plans[i].tp3Pts > 0 ? g_plans[i].tp3Pts : 50);
            int recTp1 = 1, recTp2 = 1;
            ComputeTPLevels(recTp3, recTp1, recTp2);
            g_auto[i].tp1Pts        = recTp1;
            g_auto[i].tp2Pts        = recTp2;
            g_auto[i].tp3Pts        = recTp3;
            g_auto[i].placedBar     = g_rows[i].lastBar;
            g_auto[i].lastSignalBar = g_rows[i].lastBar;
            DiaryAttachSlotRecord(i);
         }
         break;
      }

      if(!foundOrd)
         ResetAutoSlot(i, true);
   }
}

//+------------------------------------------------------------------+
//  Place the order advised by g_plans[i] (Market at 3/3, Limit at 2/3).
//+------------------------------------------------------------------+
bool PlacePlanOrder(int i)
{
   //  THE NEW-BAR PLACEMENT GATE, first key on this door.  A new order
   //  may only leave the terminal for a row whose own timeframe printed
   //  a new closed bar in the current CheckNewBars() pass.  Every other
   //  ManageAutoBar() pass - EA attach/restart, the return to a
   //  supported chart, a timer/schedule resume, or a pass triggered by
   //  another timeframe's close - reaches this function with the row
   //  unmarked and is refused here, so no caller can place mid-bar.
   //  Managing what already exists (closes, cancels, SL/TP modifies)
   //  never comes through this function and is unaffected.
   if(i < 0 || i >= TF_COUNT || !g_freshBar[i]) return(false);
   if(!CanPlaceAutoOrders()) return(false);
   if(g_plans[i].state != 2 || g_plans[i].dir == 0) return(false);
   if(!TrendMatchForTF(i)) return(false);
   //  THE CHOPPY PERMISSION GATE, second key.  UpdatePlanRow() may keep
   //  a state-2 plan alive solely to manage a position that was already
   //  open when its row turned Choppy; that plan must never be sent as
   //  a new order.  Choppy Trade Off means no market and no limit order
   //  leaves the terminal from this row, whatever a caller requests.
   if(g_rows[i].choppyBlocked) return(false);
   //  THE SCORE GATE, second key on the same door.  EvaluateRow() already
   //  refuses to publish a row whose score does not support its
   //  direction, so this can only fire if that were ever bypassed - but
   //  the last line before an order leaves the terminal should not rely
   //  on a caller having checked.  No BUY below InpBuyScore, no SELL
   //  above InpSellScore, in the trend game or the range game.
   if(!ScoreAllowsTrade(g_plans[i].dir, g_plans[i].score)) return(false);

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(point <= 0.0 || ask <= 0.0 || bid <= 0.0) return(false);

   int    dir    = g_plans[i].dir;
   int    score  = g_plans[i].score;
   bool   market = g_plans[i].market;
   double lot    = g_plans[i].lot;
   int    slPts  = g_plans[i].slPts;
   int    tp1Pts = g_plans[i].tp1Pts;
   int    tp2Pts = g_plans[i].tp2Pts;
   int    tp3Pts = g_plans[i].tp3Pts;
   ulong  ticket = 0;

   if(market)
   {
      double execP = (dir > 0) ? ask : bid;
      double slP   = InpUseStopLoss ? NormPrice(execP - (double)dir * (double)slPts * point) : 0.0;
      double tpP   = NormPrice(execP + (double)dir * (double)tp3Pts * point);

      if(!TradeOpenMarket(i, dir, lot, slP, tpP, ticket))
         return(false);

      g_auto[i].active        = true;
      g_auto[i].isOpen        = true;
      g_auto[i].ticket        = ticket;
      g_auto[i].dir           = dir;
      g_auto[i].entryScore    = score;
      g_auto[i].initLot       = lot;
      g_auto[i].curLot        = lot;
      g_auto[i].entryPrice    = execP;
      g_auto[i].slPrice       = slP;
      g_auto[i].tpPrice       = tpP;
      g_auto[i].profitUSD     = 0.0;
      g_auto[i].slPts         = InpUseStopLoss ? slPts : 0;
      g_auto[i].tp1Pts        = tp1Pts;
      g_auto[i].tp2Pts        = tp2Pts;
      g_auto[i].tp3Pts        = tp3Pts;
      g_auto[i].tp1Hit        = false;
      g_auto[i].tp2Hit        = false;
      g_auto[i].trailActive   = false;
      g_auto[i].isRange       = false;               // market orders are never range fades
      g_auto[i].rngTop        = 0.0;
      g_auto[i].rngBot        = 0.0;
      g_auto[i].placedBar     = g_rows[i].lastBar;
      g_auto[i].fillBar       = g_rows[i].lastBar;
      g_auto[i].lastEvalBar   = g_rows[i].lastBar;
      g_auto[i].lastSignalBar = g_rows[i].lastBar;
      InitTrailState(i);          // market fill: freeze the trailstop % now
      SaveAutoSlotState(i);
      DiaryBeginPlacement(i, true, slPts, ask - bid);
      return(true);
   }
   else
   {
      double pendP = ValidLimitPrice(dir, g_plans[i].entryPrice, bid, ask, point);
      double slP   = InpUseStopLoss ? NormPrice(pendP - (double)dir * (double)slPts * point) : 0.0;
      double tpP   = NormPrice(pendP + (double)dir * (double)tp3Pts * point);

      if(!TradePlaceLimit(i, dir, lot, pendP, slP, tpP, ticket))
         return(false);

      g_auto[i].active        = true;
      g_auto[i].isOpen        = false;
      g_auto[i].ticket        = ticket;
      g_auto[i].dir           = dir;
      g_auto[i].entryScore    = score;
      g_auto[i].initLot       = lot;
      g_auto[i].curLot        = lot;
      g_auto[i].entryPrice    = pendP;
      g_auto[i].slPrice       = slP;
      g_auto[i].tpPrice       = tpP;
      g_auto[i].profitUSD     = 0.0;
      g_auto[i].slPts         = InpUseStopLoss ? slPts : 0;
      g_auto[i].tp1Pts        = tp1Pts;
      g_auto[i].tp2Pts        = tp2Pts;
      g_auto[i].tp3Pts        = tp3Pts;
      g_auto[i].tp1Hit        = false;
      g_auto[i].tp2Hit        = false;
      g_auto[i].trailActive   = false;
      //  The trailstop is initialised when this pending fills (see
      //  SyncAutoState), so its % and TP1 reference match the fill.
      g_auto[i].trailSteady    = false;
      g_auto[i].trailStarted   = false;
      g_auto[i].trailPct       = 0;
      g_auto[i].trailGapPct    = 0.0;
      g_auto[i].trailRefTp1Pts = 0;
      g_auto[i].trailPeakPts   = 0.0;
      g_auto[i].trailAppliedPct = 0.0;
      g_auto[i].trailTriedPct   = 0.0;
      g_auto[i].trailLastTry    = 0;
      g_auto[i].floorLastTry    = 0;
      //  Range fades carry their box: a close outside it kills the trade
      //  (checked on every new closed bar, before the other rules).
      g_auto[i].isRange       = (g_rows[i].mode == 2);
      g_auto[i].rngTop        = (g_rows[i].mode == 2) ? g_rows[i].rngTop : 0.0;
      g_auto[i].rngBot        = (g_rows[i].mode == 2) ? g_rows[i].rngBot : 0.0;
      g_auto[i].placedBar     = g_rows[i].lastBar;
      g_auto[i].lastEvalBar   = g_rows[i].lastBar;
      g_auto[i].lastSignalBar = g_rows[i].lastBar;
      SaveAutoSlotState(i);
      DiaryBeginPlacement(i, false, slPts, ask - bid);
      return(true);
   }
}

//+------------------------------------------------------------------+
//  Bar-close autotrading logic:
//    - Manages open positions on signal/score changes and updates
//      TP1/TP2/TP3 + tightens SL when a new candle closes.
//    - Manages waiting pending limit orders (updates Entry/SL/TP,
//      upgrades 2/3 -> 3/3 to Market, or cancels on flip/HOLD, a
//      Choppy-permission veto, or expiry).
//    - Opens new Market/Limit orders for flat timeframes with a valid
//      plan (independent rows; M15 & M30 tied only if that input is on).
//+------------------------------------------------------------------+
void ManageAutoBar()
{
   SyncAutoState();
   if(!CanTradeNow())
   {
      UpdatePlan();
      return;
   }
   bool timerAllowsPlacement = AutoTimerAllowsPlacement();

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(point <= 0.0 || ask <= 0.0 || bid <= 0.0) return;

   for(int i = 0; i < TF_COUNT; i++)
   {
      // ---- CASE A: Open Market Position -----------------------------
      if(g_auto[i].active && g_auto[i].isOpen)
      {
         int    dir   = g_auto[i].dir;
         double exitP = (dir > 0) ? bid : ask;
         double favPts = (dir > 0) ? (exitP - g_auto[i].entryPrice) / point
                                   : (g_auto[i].entryPrice - exitP) / point;
         DiaryUpdateOpenSlot(i, favPts, true);

         // Track peak score strength in the trade's direction
         if(g_rows[i].ok && g_rows[i].direction == dir &&
            MathAbs(g_rows[i].score) > MathAbs(g_auto[i].entryScore))
         {
            g_auto[i].entryScore = g_rows[i].score;
            SaveAutoSlotState(i);
         }

         // 0) BOX TRADE: a closed bar outside the trade's box kills it.
         //    The box captured at placement is the thesis; the market just broke it.
         //    With InpImmediateFlipClose=false (default) a box-break is not allowed
         //    to bank a loss: while the trade is under water it is held and the same
         //    break is re-tested on every later closed bar until it is in profit.
         //    The remaining management rules below keep running meanwhile.
         if(g_auto[i].isRange && g_rows[i].ok &&
            (g_rows[i].lastClose > g_auto[i].rngTop || g_rows[i].lastClose < g_auto[i].rngBot))
         {
            if(FlipCloseAllowed(i, favPts))
            {
               if(TradeClosePosition(g_auto[i].ticket, dir, g_auto[i].curLot, MagicForTF(i)))
               {
                  g_auto[i].lastSignalBar = g_rows[i].lastBar;
                  ResetAutoSlot(i, true);
               }
               continue;
            }
         }

         // 1) Opposite direction signal -> close (and allow reversing into the new signal).
         //    With InpImmediateFlipClose=false (default) the flip only closes while the
         //    trade is in profit; under water it is held and re-checked on every later
         //    closed bar, so a reversal never crystallises a loss.  No reverse order is
         //    placed while the old trade is kept.
         if(g_rows[i].ok && g_rows[i].direction != 0 && g_rows[i].direction != dir)
         {
            if(FlipCloseAllowed(i, favPts))
            {
               if(TradeClosePosition(g_auto[i].ticket, dir, g_auto[i].curLot, MagicForTF(i)))
               {
                  ResetAutoSlot(i, false);
                  if(g_plans[i].state == 2 && TrendMatchForTF(i))
                     PlacePlanOrder(i);
               }
            }
            continue;
         }

         // Candle Wick Check: if finished closed bar reached TP1, confirm hit
         if(!g_auto[i].tp1Hit && g_auto[i].tp1Pts > 0 && point > 0.0)
         {
            double ch[], cl[];
            ArraySetAsSeries(ch, true);
            ArraySetAsSeries(cl, true);
            if(CopyHigh(_Symbol, g_rows[i].tf, 1, 1, ch) == 1 &&
               CopyLow (_Symbol, g_rows[i].tf, 1, 1, cl) == 1)
            {
               double barFav = (dir > 0) ? (ch[0] - g_auto[i].entryPrice) / point
                                         : (g_auto[i].entryPrice - cl[0]) / point;
               if(barFav >= (double)g_auto[i].tp1Pts - 1e-6)
               {
                  g_auto[i].tp1Hit      = true;
                  g_auto[i].trailActive = true;
                  SaveAutoSlotState(i);
                  double wantSL = MilestoneSLPrice(dir, g_auto[i].entryPrice,
                                                   g_auto[i].tp1Pts, TP1_LOCK_RATIO, point);
                  double tp1SL  = ClampProfitFloorSL(dir, g_auto[i].entryPrice,
                                                     wantSL, bid, ask, point);
                  if(tp1SL > 0.0 && IsSLTighter(dir, tp1SL, g_auto[i].slPrice, point))
                  {
                     if(TradeModifyPosition(g_auto[i].ticket, tp1SL, g_auto[i].tpPrice))
                     {
                        g_auto[i].slPrice = tp1SL;
                        g_auto[i].slPts   = (int)MathRound(MathAbs(g_auto[i].entryPrice - tp1SL) / point);
                     }
                  }
               }
            }
         }

         // 2) After TP1 is hit -> close if score weakened or direction dropped to HOLD.
         //    Range fades are exempt: their ENTRY was gated by the score, but once
         //    filled their exits are the box midpoint, the stop and the box-kill -
         //    the post-TP1 score watcher has no jurisdiction over them.
         if(g_auto[i].tp1Hit && !g_auto[i].isRange && !IsScoreStrongForTrade(i))
         {
            if(TradeClosePosition(g_auto[i].ticket, dir, g_auto[i].curLot, MagicForTF(i)))
            {
               g_auto[i].lastSignalBar = g_rows[i].lastBar;
               ResetAutoSlot(i, true);
            }
            continue;
         }

         // 3) Before TP1 is hit -> if timeframe drops to HOLD while trade is in profit, close
         if(!g_auto[i].tp1Hit && g_rows[i].ok && g_rows[i].direction == 0)
         {
            if(g_auto[i].profitUSD > 0.0 || favPts > 0.0)
            {
               if(TradeClosePosition(g_auto[i].ticket, dir, g_auto[i].curLot, MagicForTF(i)))
               {
                  g_auto[i].lastSignalBar = g_rows[i].lastBar;
                  ResetAutoSlot(i, true);
               }
            }
            continue;
         }

         // 4) Closed bar in the SAME direction -> SL may only TIGHTEN;
         //    TP targets (TP1/TP2/TP3) are frozen at entry and do not walk with ATR.
         if(g_rows[i].ok && g_rows[i].direction == dir && g_plans[i].state == 2)
         {
            double candSL = NormPrice(g_auto[i].entryPrice - (double)dir * (double)g_plans[i].slPts * point);
            candSL        = ClampSLToStopsLevel(dir, candSL, bid, ask, point);

            double useSL = g_auto[i].slPrice;
            if(!g_auto[i].tp1Hit && !g_auto[i].trailActive)
            {
               //  The stop may only ever TIGHTEN (README rule 6): the new
               //  plan's stop is taken only when it is closer to the entry
               //  than the one already in place, so a wider ATR on a new
               //  bar can never push an open trade's stop further away.
               //  With InpUseStopLoss=false and no SL yet there is nothing
               //  to keep, and the first stop stays the trailstop's job.
               double cand2 = InpUseStopLoss ? candSL : 0.0;
               if(cand2 > 0.0 && IsSLTighter(dir, cand2, g_auto[i].slPrice, point))
                  useSL = cand2;
            }
            else if(candSL > 0.0 && IsSLTighter(dir, candSL, g_auto[i].slPrice, point))
            {
               useSL = candSL;
            }

            // ---- Post-TP1 Runner Trailing: Trail stop behind recent 2-bar swing extrema ----
            if(InpUseTrailStop && g_auto[i].tp1Hit && point > 0.0)
            {
               double bh[], bl[];
               ArraySetAsSeries(bh, true);
               ArraySetAsSeries(bl, true);
               if(CopyHigh(_Symbol, g_rows[i].tf, 1, 2, bh) == 2 &&
                  CopyLow (_Symbol, g_rows[i].tf, 1, 2, bl) == 2)
               {
                  double atrVal = ATRClosed(g_rows[i].tf, ATR_PERIOD);
                  double cushion = (atrVal > 0.0) ? 0.10 * atrVal : point;
                  double runnerSL = 0.0;
                  if(dir > 0)
                  {
                     double minL = MathMin(bl[0], bl[1]);
                     runnerSL = NormPrice(minL - cushion);
                  }
                  else
                  {
                     double maxH = MathMax(bh[0], bh[1]);
                     runnerSL = NormPrice(maxH + cushion);
                  }
                  runnerSL = ClampSLToStopsLevel(dir, runnerSL, bid, ask, point);
                  if(runnerSL > 0.0 && IsSLTighter(dir, runnerSL, useSL, point))
                     useSL = runnerSL;
               }
            }

            if(MathAbs(useSL - g_auto[i].slPrice) >= 0.5 * point)
            {
               if(TradeModifyPosition(g_auto[i].ticket, useSL, g_auto[i].tpPrice))
               {
                  g_auto[i].slPrice       = useSL;
                  g_auto[i].lastEvalBar   = g_rows[i].lastBar;
                  g_auto[i].slPts         = (useSL > 0.0)
                                            ? (int)MathRound(MathAbs(g_auto[i].entryPrice - useSL) / point)
                                            : 0;
               }
            }
            else
            {
               g_auto[i].lastEvalBar = g_rows[i].lastBar;
            }
         }
         continue;
      }

      // ---- CASE B: Waiting Pending Limit Order ----------------------
      if(g_auto[i].active && !g_auto[i].isOpen)
      {
         int  dir     = g_auto[i].dir;

         // Choppy Trade OFF: if this row has turned Choppy, its waiting
         // order is still an unfilled NEW entry.  Cancel it on this
         // closed-bar pass instead of refreshing or upgrading it.  An
         // already-open position is handled in CASE A and is untouched
         // by this veto.
         if(g_rows[i].choppyBlocked)
         {
            if(TradeDeleteOrder(g_auto[i].ticket))
            {
               g_auto[i].lastSignalBar = g_rows[i].lastBar;
               ResetAutoSlot(i, true);
            }
            continue;
         }

         // Timer/pause OFF: a waiting order is an unfilled entry, so
         // cancel it rather than refresh it (it could otherwise fill
         // while new placements are supposed to be paused).
         if(!timerAllowsPlacement)
         {
            if(TradeDeleteOrder(g_auto[i].ticket))
            {
               g_auto[i].lastSignalBar = g_rows[i].lastBar;
               ResetAutoSlot(i, true);
            }
            continue;
         }

         int  tfSec   = PeriodSeconds(g_rows[i].tf);
         //  Range fades live on RANGE_VALID_BARS: the box-kill above
         //  (a close outside the box) is their real invalidation, and
         //  the pending is refreshed to the new plan on every closed
         //  bar anyway.  Expiring them on the 3-bar trend leash only
         //  produced a cancel -> one-bar gap at the band -> re-place
         //  cycle while the thesis was intact.
         int  vBars   = g_auto[i].isRange ? MathMax(1, RANGE_VALID_BARS)
                                          : VALID_BARS;
         datetime birthBar = (g_rows[i].sigBirth > 0) ? g_rows[i].sigBirth : g_auto[i].placedBar;
         bool expired = (birthBar > 0 && tfSec > 0 &&
                         g_rows[i].lastBar > birthBar &&
                         ((int)((g_rows[i].lastBar - birthBar) / tfSec) >= vBars));

         // 0) BOX TRADE: a closed bar outside the trade's box cancels the pending
         if(g_auto[i].isRange && g_rows[i].ok &&
            (g_rows[i].lastClose > g_auto[i].rngTop || g_rows[i].lastClose < g_auto[i].rngBot))
         {
            if(TradeDeleteOrder(g_auto[i].ticket))
            {
               g_auto[i].lastSignalBar = g_rows[i].lastBar;
               ResetAutoSlot(i, true);
            }
            continue;
         }

         // 1) Direction changed / HOLD / trend gate failed / expired -> cancel pending order
         if(!g_rows[i].ok || g_rows[i].direction != dir || !TrendMatchForTF(i) ||
            expired || g_plans[i].state != 2)
         {
            if(TradeDeleteOrder(g_auto[i].ticket))
            {
               bool flipped = (g_rows[i].ok && g_rows[i].direction != 0 && g_rows[i].direction != dir);
               g_auto[i].lastSignalBar = g_rows[i].lastBar;
               ResetAutoSlot(i, !flipped);
               if(flipped && g_plans[i].state == 2 && TrendMatchForTF(i))
                  PlacePlanOrder(i);
            }
            continue;
         }

         // 2) Score upgraded from 2/3 (Pending) to 3/3 (Market) in the same direction ->
         //    delete the pending limit order and open the Market order immediately
         if(g_plans[i].market)
         {
            DiaryBeginUpgrade(i);
            if(TradeDeleteOrder(g_auto[i].ticket))
            {
               ResetAutoSlot(i, false);
               bool upgraded = PlacePlanOrder(i);
               DiaryFinishUpgrade(i, upgraded);
            }
            else
               DiaryCancelUpgrade(i);
            continue;
         }

         // 3) Closed candle in the same direction (still Pending 2/3) ->
         //    update Entry, SL and TP1/TP2/TP3 as per SimpleEA's new plan
         double newEntry = ValidLimitPrice(dir, g_plans[i].entryPrice, bid, ask, point);
         double newSL    = InpUseStopLoss ? NormPrice(newEntry - (double)dir * (double)g_plans[i].slPts * point) : 0.0;
         double newTP    = NormPrice(newEntry + (double)dir * (double)g_plans[i].tp3Pts * point);

         g_auto[i].slPts  = InpUseStopLoss ? g_plans[i].slPts : 0;
         g_auto[i].tp1Pts = g_plans[i].tp1Pts;
         g_auto[i].tp2Pts = g_plans[i].tp2Pts;
         g_auto[i].tp3Pts = g_plans[i].tp3Pts;

         if(MathAbs(newEntry - g_auto[i].entryPrice) >= 0.5 * point ||
            MathAbs(newSL    - g_auto[i].slPrice)    >= 0.5 * point ||
            MathAbs(newTP    - g_auto[i].tpPrice)    >= 0.5 * point)
         {
            if(TradeModifyOrder(g_auto[i].ticket, newEntry, newSL, newTP))
            {
               g_auto[i].entryPrice  = newEntry;
               g_auto[i].slPrice     = newSL;
               g_auto[i].tpPrice     = newTP;
               g_auto[i].lastEvalBar = g_rows[i].lastBar;
            }
         }
         else
         {
            g_auto[i].lastEvalBar = g_rows[i].lastBar;
         }
         g_auto[i].diaryPlanSlPts = g_plans[i].slPts;
         DiarySyncSlotRecord(i, true);
         continue;
      }

      // ---- CASE C: Flat on this timeframe -> check new placement ----
      if(!g_auto[i].active)
      {
         if(timerAllowsPlacement && g_rows[i].ok && !g_rows[i].choppyBlocked &&
            g_rows[i].direction != 0 && g_plans[i].state == 2 &&
            TrendMatchForTF(i) && !HasTradedOnBar(i, g_rows[i].lastBar))
         {
            PlacePlanOrder(i);
         }
      }
   }

   SyncAutoState();
   UpdatePlan();
}

//+------------------------------------------------------------------+
//  Tick-level monitoring for TP1, TP2, TP3 hits and live 2nd-panel
//  updates.
//+------------------------------------------------------------------+
void ManageAutoTick()
{
   bool prevAct[TF_COUNT];
   bool prevOpen[TF_COUNT];
   for(int i = 0; i < TF_COUNT; i++)
   {
      prevAct[i]  = g_auto[i].active;
      prevOpen[i] = g_auto[i].isOpen;
   }

   bool hadActive = AnyAutoActive();
   SyncAutoState();
   bool nowActive = AnyAutoActive();

   if(!nowActive && !hadActive && !g_autoShown)
      return;

   bool stateChanged = (hadActive != nowActive);
   for(int i = 0; i < TF_COUNT; i++)
   {
      if(prevAct[i] != g_auto[i].active || prevOpen[i] != g_auto[i].isOpen)
         stateChanged = true;
   }

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(CanTradeNow() && point > 0.0 && ask > 0.0 && bid > 0.0)
   {
      for(int i = 0; i < TF_COUNT; i++)
      {
         if(!g_auto[i].active || !g_auto[i].isOpen) continue;

         int    dir    = g_auto[i].dir;
         double exitP  = (dir > 0) ? bid : ask;
         double favPts = (dir > 0) ? (exitP - g_auto[i].entryPrice) / point
                                   : (g_auto[i].entryPrice - exitP) / point;
         DiaryUpdateOpenSlot(i, favPts, false);

         // ---- TP3 hit: close order in full --------------------------
         if(g_auto[i].tp3Pts > 0 && favPts >= (double)g_auto[i].tp3Pts - 1e-6)
         {
            if(TradeClosePosition(g_auto[i].ticket, dir, g_auto[i].curLot, MagicForTF(i)))
            {
               ResetAutoSlot(i, true);
               stateChanged = true;
               continue;
            }
         }

         // ---- Pre-TP1 stepped trailstop: ratchet the SL in 5% steps
         //      on the way to TP1.  Runs before the milestone floor and
         //      TP1 check so a tick that lands on a trail step or TP1
         //      sends one clean modify directly to the tightest SL.
         if(UpdatePreTP1Trail(i, favPts, bid, ask, point))
            stateChanged = true;

         // ---- Universal 3-Step Profit-Protection Floor (Trailstop ON or OFF):
         //      50% of TP1 -> +25% of TP1 ahead of Entry; 100% -> +50% of TP1;
         //      TP2 -> TP1 price (100% of TP1).  Also retries if an earlier
         //      milestone modify was rejected or clamped by stops level.
         if(UpdateProfitProtectionFloor(i, favPts, bid, ask, point))
            stateChanged = true;

         // ---- TP1 hit: move SL up to +50% of TP1 ahead of Entry (only
         //      if tighter than any trailed SL) and partial-close 70% if
         //      lot > minLot -------------------------------------------
         double grossPts = (dir > 0) ? (ask - g_auto[i].entryPrice) / point
                                     : (g_auto[i].entryPrice - bid) / point;
         if(!g_auto[i].tp1Hit && g_auto[i].tp1Pts > 0 &&
            (favPts >= (double)g_auto[i].tp1Pts - 1e-6 ||
             (grossPts >= (double)g_auto[i].tp1Pts - 1e-6 && favPts > 0.0)))
         {
            g_auto[i].tp1Hit      = true;
            g_auto[i].trailActive = true;
            SaveAutoSlotState(i);
            stateChanged          = true;

            double wantTp1SL = MilestoneSLPrice(dir, g_auto[i].entryPrice,
                                                g_auto[i].tp1Pts, TP1_LOCK_RATIO, point);
            double tp1SL     = ClampProfitFloorSL(dir, g_auto[i].entryPrice,
                                                  wantTp1SL, bid, ask, point);
            if(tp1SL > 0.0 && IsSLTighter(dir, tp1SL, g_auto[i].slPrice, point))
            {
               if(TradeModifyPosition(g_auto[i].ticket, tp1SL, g_auto[i].tpPrice))
               {
                  g_auto[i].slPrice = tp1SL;
                  g_auto[i].slPts   = (int)MathRound(MathAbs(g_auto[i].entryPrice - tp1SL) / point);
               }
            }

            double close70 = CalcTP1CloseLot(g_auto[i].curLot);
            if(close70 > 0.0)
            {
               if(TradeClosePosition(g_auto[i].ticket, dir, close70, MagicForTF(i)))
                  g_auto[i].curLot = FloorLotStep(g_auto[i].curLot - close70);
            }

            // Watch score at TP1: if score already weakened or changed direction,
            // close remaining.  Range fades are exempt (box/stop/box-kill govern them).
            if(!g_auto[i].isRange && !IsScoreStrongForTrade(i))
            {
               SyncAutoState();
               if(g_auto[i].active && g_auto[i].isOpen)
               {
                  if(TradeClosePosition(g_auto[i].ticket, dir, g_auto[i].curLot, MagicForTF(i)))
                     ResetAutoSlot(i, true);
               }
               continue;
            }
         }

         // ---- TP2 hit: reduce remaining lot to minimum lot and lock
         //      SL to TP1 (100% of TP1) --------------------------------
         if(g_auto[i].tp1Hit && !g_auto[i].tp2Hit && g_auto[i].tp2Pts > 0 &&
            favPts >= (double)g_auto[i].tp2Pts - 1e-6)
         {
            g_auto[i].tp2Hit      = true;
            g_auto[i].trailActive = true;
            SaveAutoSlotState(i);
            stateChanged          = true;

            double tp1P   = g_auto[i].entryPrice + (double)dir * (double)g_auto[i].tp1Pts * point;
            double lockSL = ClampProfitFloorSL(dir, g_auto[i].entryPrice,
                                               tp1P, bid, ask, point);
            if(lockSL > 0.0 && IsSLTighter(dir, lockSL, g_auto[i].slPrice, point))
            {
               if(TradeModifyPosition(g_auto[i].ticket, lockSL, g_auto[i].tpPrice))
               {
                  g_auto[i].slPrice = lockSL;
                  g_auto[i].slPts   = (int)MathRound(MathAbs(g_auto[i].entryPrice - lockSL) / point);
               }
            }

            double closeToMin = CalcTP2CloseLot(g_auto[i].curLot);
            if(closeToMin > 0.0)
            {
               if(TradeClosePosition(g_auto[i].ticket, dir, closeToMin, MagicForTF(i)))
                  g_auto[i].curLot = SymbolMinLot();
            }

            //  Box trades are exempt from the score watcher too.
            if(!g_auto[i].isRange && !IsScoreStrongForTrade(i))
            {
               SyncAutoState();
               if(g_auto[i].active && g_auto[i].isOpen)
               {
                  if(TradeClosePosition(g_auto[i].ticket, dir, g_auto[i].curLot, MagicForTF(i)))
                     ResetAutoSlot(i, true);
               }
               continue;
            }
         }
      }
      SyncAutoState();
      for(int i = 0; i < TF_COUNT; i++)
      {
         if(prevAct[i] != g_auto[i].active || prevOpen[i] != g_auto[i].isOpen)
            stateChanged = true;
      }
   }

   if(stateChanged)
   {
      UpdatePlan();
      UpdateAutoPanel();
      DrawSupportedPanel();
   }
   else
   {
      UpdateAutoPanel();
      DrawAutoPanel();
   }
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//  Format the cells of the 2nd Panel ("Autotrading") for all active
//  timeframes.
//+------------------------------------------------------------------+
void UpdateAutoPanel()
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double pv    = PointValuePerLot();
   int    dg    = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   string cur   = AccountInfoString(ACCOUNT_CURRENCY);
   if(cur == "") cur = "USD";

   for(int i = 0; i < TF_COUNT; i++)
   {
      ClearAutoCells(i);
      if(!g_auto[i].active || !ChartSupported()) continue;

      int    dir   = g_auto[i].dir;
      color  dirC  = (dir > 0) ? InpBuyColor : InpSellColor;
      double lot   = g_auto[i].curLot;
      double liveP = (dir > 0) ? (g_auto[i].isOpen ? bid : ask)
                               : (g_auto[i].isOpen ? ask : bid);
      string liveL = (dir > 0) ? (g_auto[i].isOpen ? "Bid:" : "Ask:")
                               : (g_auto[i].isOpen ? "Ask:" : "Bid:");

      string kindTxt = g_auto[i].isOpen
                       ? ((dir > 0) ? "OPEN BUY"  : "OPEN SELL")
                       : ((dir > 0) ? "BUY LIMIT" : "SELL LIMIT");

      g_auto[i].head    = StringFormat("%-3s | %s", g_rows[i].tag, kindTxt);
      g_auto[i].headClr = dirC;

      // ---- Line 0: Lot @ x.xx | Entry: xxx.xx | Ask/Bid: xxx.xx -----
      g_auto[i].lbl[0][0] = "Lot @";
      g_auto[i].val[0][0] = DoubleToString(lot, 2);
      g_auto[i].clr[0][0] = InpTitleColor;

      g_auto[i].lbl[0][1] = "Entry:";
      g_auto[i].val[0][1] = DoubleToString(g_auto[i].entryPrice, dg);
      g_auto[i].clr[0][1] = dirC;

      g_auto[i].lbl[0][2] = liveL;
      g_auto[i].val[0][2] = (liveP > 0.0) ? DoubleToString(liveP, dg) : "--";
      g_auto[i].clr[0][2] = clrSilver;

      // ---- Line 1: TP1 & TP2 in price and account currency ----------
      double tp1Price = NormPrice(g_auto[i].entryPrice + (double)dir * (double)g_auto[i].tp1Pts * point);
      double tp2Price = NormPrice(g_auto[i].entryPrice + (double)dir * (double)g_auto[i].tp2Pts * point);
      double tp3Price = (g_auto[i].tpPrice > 0.0)
                        ? g_auto[i].tpPrice
                        : NormPrice(g_auto[i].entryPrice + (double)dir * (double)g_auto[i].tp3Pts * point);

      double tp1USD = (pv > 0.0) ? lot * (double)g_auto[i].tp1Pts * pv : 0.0;
      double tp2USD = (pv > 0.0) ? lot * (double)g_auto[i].tp2Pts * pv : 0.0;
      double tp3USD = (pv > 0.0) ? lot * (double)g_auto[i].tp3Pts * pv : 0.0;

      g_auto[i].lbl[1][0] = "TP1:";
      g_auto[i].val[1][0] = StringFormat("%s (%s %s)%s",
                                         DoubleToString(tp1Price, dg), DoubleToString(tp1USD, 2), cur,
                                         g_auto[i].tp1Hit ? " [HIT]" : "");
      g_auto[i].clr[1][0] = InpBuyColor;

      g_auto[i].lbl[1][1] = "TP2:";
      g_auto[i].val[1][1] = StringFormat("%s (%s %s)%s",
                                         DoubleToString(tp2Price, dg), DoubleToString(tp2USD, 2), cur,
                                         g_auto[i].tp2Hit ? " [HIT]" : "");
      g_auto[i].clr[1][1] = InpBuyColor;

      // ---- Line 2: TP3 & SL in price (or realtime Ask/Bid when SL is blank)
      g_auto[i].lbl[2][0] = "TP3:";
      g_auto[i].val[2][0] = StringFormat("%s (%s %s)",
                                         DoubleToString(tp3Price, dg), DoubleToString(tp3USD, 2), cur);
      g_auto[i].clr[2][0] = InpBuyColor;

      g_auto[i].lbl[2][1] = "SL:";
      if(g_auto[i].slPrice > 0.0 && point > 0.0)
      {
         int    slPtsNow    = (int)MathRound(MathAbs(g_auto[i].entryPrice - g_auto[i].slPrice) / point);
         double slUSD       = (pv > 0.0) ? lot * (double)slPtsNow * pv : 0.0;
         bool   isBE        = (slPtsNow == 0 || g_auto[i].trailActive);
         bool   slProtected = (g_auto[i].isOpen &&
                               ((double)dir * (g_auto[i].slPrice - g_auto[i].entryPrice) >= -0.5 * point));
         g_auto[i].val[2][1] = StringFormat("%s (%s %s)%s",
                                            DoubleToString(g_auto[i].slPrice, dg), DoubleToString(slUSD, 2), cur,
                                            (slPtsNow == 0 && isBE) ? " [BE]" : "");
         g_auto[i].clr[2][1] = slProtected ? InpBuyColor : InpSellColor;
      }
      else
      {
         // When SL is blank, show "-- (Ask/Bid: xxx.xx)" in realtime
         g_auto[i].val[2][1] = StringFormat("-- (%s %s)",
                                            liveL, (liveP > 0.0 ? DoubleToString(liveP, dg) : "--"));
         g_auto[i].clr[2][1] = clrSilver;
      }

      // ---- Line 3: Status / Waiting distance & LIVE gap to TP1/TP2/TP3
      //  The Distance cell counts down in realtime: how far the live
      //  close-side price still is from the next target (TP1 -> TP2 ->
      //  TP3 as each one is hit), not the frozen entry->TP distance.
      string nextTpTag   = !g_auto[i].tp1Hit ? "TP1" : (!g_auto[i].tp2Hit ? "TP2" : "TP3");
      double nextTpPrice = !g_auto[i].tp1Hit ? tp1Price
                           : (!g_auto[i].tp2Hit ? tp2Price : tp3Price);

      if(g_auto[i].isOpen)
      {
         g_auto[i].lbl[3][0] = "Status:";
         g_auto[i].val[3][0] = StringFormat("P/L %+0.2f %s", g_auto[i].profitUSD, cur);
         g_auto[i].clr[3][0] = (g_auto[i].profitUSD >= 0.0) ? InpBuyColor : InpSellColor;
      }
      else
      {
         int waitPts = (point > 0.0 && liveP > 0.0)
                       ? (int)MathRound(MathAbs(liveP - g_auto[i].entryPrice) / point)
                       : 0;
         g_auto[i].lbl[3][0] = "Waiting:";
         g_auto[i].val[3][0] = StringFormat("distance %d pts", waitPts);
         g_auto[i].clr[3][0] = clrSilver;
      }

      g_auto[i].lbl[3][1] = "Distance:";
      int gapPts = (point > 0.0 && liveP > 0.0)
                   ? (int)MathRound(MathAbs(nextTpPrice - liveP) / point)
                   : 0;
      g_auto[i].val[3][1] = StringFormat("to %s %d pts", nextTpTag, gapPts);
      g_auto[i].clr[3][1] = InpBuyColor;

      // ---- the trailstop % SimpleEA picked for this trade ----------
      g_auto[i].lbl[3][2] = "TS:";
      if(!g_auto[i].isOpen || g_auto[i].trailPct <= 0)
      {
         g_auto[i].val[3][2] = InpUseTrailStop ? "--" : "Off";
         g_auto[i].clr[3][2] = clrSilver;
      }
      else
      {
         g_auto[i].val[3][2] = StringFormat("%d%% %s", g_auto[i].trailPct,
                                            g_auto[i].trailSteady ? "Steady" : "Tight");
         g_auto[i].clr[3][2] = g_auto[i].trailStarted ? InpBuyColor : clrSilver;
      }
   }
}

//==================================================================
//  PANEL
//==================================================================
//  Plain words for the "Regime" side of the panel: HOW price is moving.
//     Steady  - moves tend to keep going the same way
//     Mixed   - no clear habit, nothing to trust either way
//     Choppy  - moves tend to turn back on themselves
//+------------------------------------------------------------------+
string RegimeText(int idx)
{
   double H = g_rows[idx].hurst;
   if(H > g_rows[idx].hTrend)  return("Steady");
   if(H < g_rows[idx].hRevert) return("Choppy");
   return("Mixed");
}

//+------------------------------------------------------------------+
color RegimeColor(int idx)
{
   double H = g_rows[idx].hurst;
   if(H > g_rows[idx].hTrend)  return(clrDeepSkyBlue);
   if(H < g_rows[idx].hRevert) return(clrOrange);
   return(clrSilver);
}

//  Plain words for the "Trend" side of the panel: WHICH WAY price is going.
//+------------------------------------------------------------------+
string PlainTrendText(int dir)
{
   if(dir > 0) return("Going up");
   if(dir < 0) return("Going down");
   return("Sideways");
}

//  The trading word for the same read, shown on the second line of each row
//  so nothing from the original panel is lost:
//     Going up = BUY,  Going down = SELL,  Sideways = HOLD.
//+------------------------------------------------------------------+
string DirectionText(int dir)
{
   if(dir > 0) return("BUY");
   if(dir < 0) return("SELL");
   return("HOLD");
}

//+------------------------------------------------------------------+
color DirectionColor(int dir)
{
   if(dir > 0) return(InpBuyColor);
   if(dir < 0) return(InpSellColor);
   return(InpHoldColor);
}

//+------------------------------------------------------------------+
string ShortTimeframe(ENUM_TIMEFRAMES tf)
{
   switch(tf)
   {
      case PERIOD_M1:  return("M1");
      case PERIOD_M2:  return("M2");
      case PERIOD_M3:  return("M3");
      case PERIOD_M4:  return("M4");
      case PERIOD_M5:  return("M5");
      case PERIOD_M6:  return("M6");
      case PERIOD_M10: return("M10");
      case PERIOD_M12: return("M12");
      case PERIOD_M15: return("M15");
      case PERIOD_M20: return("M20");
      case PERIOD_M30: return("M30");
      case PERIOD_H1:  return("H1");
      case PERIOD_H2:  return("H2");
      case PERIOD_H3:  return("H3");
      case PERIOD_H4:  return("H4");
      case PERIOD_H6:  return("H6");
      case PERIOD_H8:  return("H8");
      case PERIOD_H12: return("H12");
      case PERIOD_D1:  return("D1");
      case PERIOD_W1:  return("W1");
      case PERIOD_MN1: return("MN1");
   }
   return("TF");
}

//+------------------------------------------------------------------+
//  THE CHART-TIMEFRAME RULE
//+------------------------------------------------------------------+
//  True only while the chart the EA is running on is M5, M15 or M30.
//  This is the single test the whole rule hangs on: the panel is built
//  for those three timeframes only, and on any other chart every part
//  of the program refuses to produce a reading.
//+------------------------------------------------------------------+
bool ChartSupported()
{
   return(TIMEFRAME_OK((ENUM_TIMEFRAMES)Period()));
}

//+------------------------------------------------------------------+
//  THE MARKET-CLOSED RULE
//+------------------------------------------------------------------+
//  True while this symbol cannot be traded right now.  Four signals,
//  cheapest and most authoritative first:
//    1. the broker's own switch: SYMBOL_TRADE_MODE disabled / close-only,
//    2. the symbol's quoted trade sessions vs the server clock - the
//       weekend and daily-break case, the whole reason this exists,
//    3. a quote gone quiet while the server clock still runs (a symbol
//       halted mid-week; a generous threshold so quiet markets do not
//       trip it),
//    4. the server itself rejecting an order with "market closed" -
//       latched for a while, the belt to the session braces.
//  With InpDetectClosed off this is always false and the panel behaves
//  exactly as it did before.
//+------------------------------------------------------------------+
bool MarketClosed()
{
   if(!InpDetectClosed) return(false);

   // ---- 1) the broker's own switch ---------------------------------
   long mode = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(mode == SYMBOL_TRADE_MODE_DISABLED || mode == SYMBOL_TRADE_MODE_CLOSEONLY)
      return(true);

   // ---- 2) the quoted trade sessions vs the server clock -----------
   //  Session times are server-based, so the comparison uses the
   //  estimated server time, not the local clock.  Whether the broker
   //  publishes sessions at all is re-answered once per server day -
   //  it cannot change intraday.
   static int  scanDay = -1;      // server weekday of the last session scan
   static int  anySess = -1;      // 0 = broker publishes none, 1 = publishes
   MqlDateTime now;
   TimeToStruct(TimeTradeServer(), now);
   if(scanDay != now.day_of_week)
   {
      scanDay = now.day_of_week;
      anySess = 0;
      datetime sf, st;
      for(int d = 0; d < 7 && anySess == 0; d++)
      {
         uint k = 0;
         while(k < 32 && SymbolInfoSessionTrade(_Symbol, (ENUM_DAY_OF_WEEK)d, k, sf, st))
            k++;
         if(k > 0) anySess = 1;
      }
   }
   if(anySess == 1)
   {
      datetime sf, st;
      uint    k       = 0;
      bool    hasSess = false;   // the book has sessions for today
      bool    inSess  = false;   // this instant sits inside one of them
      int     sec     = now.hour * 3600 + now.min * 60 + now.sec;
      while(k < 32 && SymbolInfoSessionTrade(_Symbol, (ENUM_DAY_OF_WEEK)now.day_of_week, k, sf, st))
      {
         hasSess = true;
         int from = (int)((long)sf % 86400);   // session offsets are
         int to   = (int)((long)st % 86400);   // seconds of the day
         if(from < to) inSess = (inSess || (sec >= from && sec < to));
         else          inSess = (inSess || (sec >= from || sec < to));  // past midnight
         k++;
      }
      //  The broker publishes sessions, but none for today (a Sunday in
      //  a Mon-Fri book), or today's sessions do not cover this instant.
      if(!hasSess || !inSess)
         return(true);
   }

   // ---- 3) the quote went quiet while the server clock runs --------
   if(InpClosedStaleMin > 0)
   {
      datetime qt = (datetime)SymbolInfoInteger(_Symbol, SYMBOL_TIME);
      if(qt > 0 && (long)(TimeTradeServer() - qt) >= 60 * InpClosedStaleMin)
         return(true);
   }

   // ---- 4) the server said so on the last order attempt ------------
   if(g_srvSaidClosedUntil > TimeCurrent())
      return(true);

   return(false);
}

//  Called by the trade wrappers with every MqlTradeResult: when the
//  server answers "market closed" the latch makes MarketClosed() true
//  for the next while, even if the session book above disagrees - the
//  one source a broker cannot publish wrongly.
//+------------------------------------------------------------------+
void NoteMarketClosedRetcode(const uint retcode)
{
   if(retcode == TRADE_RETCODE_MARKET_CLOSED)
      g_srvSaidClosedUntil = TimeCurrent() + 15 * 60;
}

//  Name of the current chart timeframe, spelled the way a trader says it
//  ("H1", "M1", ...), for the notice and the journal line.  SHORT_TIMEFRAMES
//  does not know the "current chart" pseudo-period, so map that first.
//+------------------------------------------------------------------+
string ChartTimeframeText()
{
   ENUM_TIMEFRAMES tf = (ENUM_TIMEFRAMES)Period();
   if(tf == PERIOD_CURRENT) tf = (ENUM_TIMEFRAMES)_Period;
   return(ShortTimeframe(tf));
}

//+------------------------------------------------------------------+
void MakeLabel(string name, int x, int y, string text, color clr,
               int size, bool rightAnchor)
{
   string full = OBJ_PREFIX + name;
   if(ObjectFind(0, full) < 0)
      ObjectCreate(0, full, OBJ_LABEL, 0, 0, 0);

   // Never let a tiny font-size input produce an unreadable or invalid label.
   if(size < 6) size = 6;

   ObjectSetInteger(0, full, OBJPROP_CORNER,     CORNER_LEFT_UPPER);
   ObjectSetInteger(0, full, OBJPROP_XDISTANCE,  x);
   ObjectSetInteger(0, full, OBJPROP_YDISTANCE,  y);
   ObjectSetInteger(0, full, OBJPROP_COLOR,      clr);
   ObjectSetInteger(0, full, OBJPROP_FONTSIZE,   size);
   ObjectSetString (0, full, OBJPROP_FONT,       InpFont);
   ObjectSetInteger(0, full, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, full, OBJPROP_HIDDEN,     true);
   ObjectSetInteger(0, full, OBJPROP_BACK,       false);
   ObjectSetInteger(0, full, OBJPROP_ANCHOR,
                    rightAnchor ? ANCHOR_RIGHT_UPPER : ANCHOR_LEFT_UPPER);
   ObjectSetString (0, full, OBJPROP_TEXT,       text);
}

//+------------------------------------------------------------------+
//  Estimated rendered width of one character, in pixels, for a given
//  font size.  Used only to keep long text inside the panel box; it is
//  rounded up so the estimate errs on the wide side.
//+------------------------------------------------------------------+
//  The width the header + notice need.  Both panels are at least this
//  wide, so the notice can never be clipped - it is the one line that
//  must always be readable in full, whatever the font size.
//+------------------------------------------------------------------+
int NoticeWidth()
{
   int w = 10 + StringLen(IncompatibleNotice()) * CharW(InpFontSize + 1) + 10;
   if(w < PLAN_W_MIN) w = PLAN_W_MIN;
   return(w);
}

//+------------------------------------------------------------------+
//  Estimated width of one character, in pixels, for a given point size.
//  MetaTrader sizes fonts in POINTS, so what that means in pixels depends
//  on the screen DPI - the terminal reports it, so this uses the real
//  value instead of assuming 96.  A monospaced face needs about 0.55 em
//  per character, and the result is rounded UP, so the estimate is never
//  smaller than the real glyph advance.
//+------------------------------------------------------------------+
int CharW(int size)
{
   if(size < 6) size = 6;
   int dpi = (int)TerminalInfoInteger(TERMINAL_SCREEN_DPI);
   if(dpi < 72) dpi = 96;
   double em = (double)size * (double)dpi / 72.0;
   return((int)MathCeil(em * 0.55));
}

//+------------------------------------------------------------------+
//  THE COLUMN GRID - every x in the panel, scaled by the font size.
//
//  The panel is a monospaced table, so one number sizes everything: em,
//  the pixel advance of one character (CharW).  Before this, the column
//  anchors were raw pixels tuned at the old 9-point default - which is
//  fine until the font grows: at 10 points "Signal:" alone is 7 em wide
//  and the value still started at x+192, so the caption ran into its
//  own value by a few pixels and the panel looked crowded.
//
//  Now the font-9 design (150 / 282 / 414, and the kind column at 5 em)
//  is only a set of reference anchors: ColX() scales them around the left
//  padding by em / em(9), so raising the font widens every column in
//  proportion instead of squeezing text into the next label.  The value
//  x of a column is its label x plus PLAN_LBL_C (the widest label plus
//  a space), which is what actually guarantees the gap.
//+------------------------------------------------------------------+
int EmBase()
{
   int b = CharW(9);                 // the point size the anchors were drawn at
   return((b > 0) ? b : 1);
}

int ColX(int designPx)
{
   return(10 + (designPx - 10) * CharW(InpFontSize) / EmBase());
}

//+------------------------------------------------------------------+
//  Remove one panel object by short name.  Safe to call whether or not
//  the object exists, so callers never have to check first.
//+------------------------------------------------------------------+
void DeleteObject(string name)
{
   string full = OBJ_PREFIX + name;
   if(ObjectFind(0, full) >= 0)
      ObjectDelete(0, full);
}

//+------------------------------------------------------------------+
void MakeRect(string name, int x, int y, int w, int hh, color bg, color border)
{
   string full = OBJ_PREFIX + name;
   if(ObjectFind(0, full) < 0)
      ObjectCreate(0, full, OBJ_RECTANGLE_LABEL, 0, 0, 0);

   ObjectSetInteger(0, full, OBJPROP_CORNER,      CORNER_LEFT_UPPER);
   ObjectSetInteger(0, full, OBJPROP_XDISTANCE,   x);
   ObjectSetInteger(0, full, OBJPROP_YDISTANCE,   y);
   ObjectSetInteger(0, full, OBJPROP_XSIZE,       w);
   ObjectSetInteger(0, full, OBJPROP_YSIZE,       hh);
   ObjectSetInteger(0, full, OBJPROP_BGCOLOR,     bg);
   ObjectSetInteger(0, full, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, full, OBJPROP_COLOR,       border);
   ObjectSetInteger(0, full, OBJPROP_WIDTH,       1);
   ObjectSetInteger(0, full, OBJPROP_BACK,        false);
   ObjectSetInteger(0, full, OBJPROP_SELECTABLE,  false);
   ObjectSetInteger(0, full, OBJPROP_HIDDEN,      true);
}

//+------------------------------------------------------------------+
//  The header line + notice shown when the chart timeframe is not
//  supported.  Nothing else - no timeframe rows, no signal, no score.
//+------------------------------------------------------------------+
string IncompatibleNotice()
{
   return("Incompatible chart. Switch to " + TF_TEXT + ".");
}

//+------------------------------------------------------------------+
//  Create the static frame once, so the panel object set is stable.
//  NOTE: the title label deliberately belongs to DrawPanel(), so that an
//  unsupported chart can never inherit it from a supported one.
//+------------------------------------------------------------------+
void BuildPanel()
{
   int x = InpPanelX, y = InpPanelY;
   MakeRect("bg",  x, y, g_panelW, g_panelH, InpBgColor, clrDimGray);
   MakeRect("sep", x + 4, y + MainHeaderHeight() - 6, g_panelW - 8, 1, clrDimGray, clrDimGray);
}

//+------------------------------------------------------------------+
//  DrawPanel() never decides anything: it only shows whichever of the
//  three states applies.  There is no path through the program on which
//  the data panel can be drawn for a bare M1, H1, D1 ... chart, or while
//  the symbol has no trading session - this switch is the only way in.
//+------------------------------------------------------------------+
void DrawPanel()
{
   if(!ChartSupported())   DrawNoticePanel(IncompatibleNotice());
   else if(MarketClosed()) DrawNoticePanel("Market Closed");
   else                    DrawSupportedPanel();
}

//+------------------------------------------------------------------+
//  Supported chart timeframe (M5 / M15 / M30) - the full panel:
//
//     SimpleEA2.0 | Autotrading : On                 SYMBOL  M15
//     Timer: Off | Choppy Trade: On | M15/M30 Same Trend: Off
//     --------------------------------------------------------------
//     M5   Scalp       Trend: Going up     Regime: Steady
//                      Signal: BUY         Score: +3 / 3
//     ...
//
//  While the timer blocks placement, line 1 says so and counts down
//  (line 2 then names the setting that is doing it):
//
//     SimpleEA2.0 | Autotrading : Timer Pause  Resume 2h14m  SYMBOL  M15
//     Timer: Paused 08:00-17:00 | Choppy Trade: On | M15/M30 Same Trend: Off
//+------------------------------------------------------------------+
void DrawSupportedPanel()
{
   int x   = InpPanelX, y = InpPanelY;
   int pad = 10;
   int rowH = g_rowH;

   //  Size the panel to its content BEFORE drawing the background, so the
   //  trade plan can never be clipped on the right - and so the box hugs
   //  the content instead of leaving a wide empty edge when signals go.
   int    em        = CharW(InpFontSize);
   int    titleW    = StringLen(PANEL_TITLE) * CharW(InpFontSize + 1);
   string symRight  = "|  " + _Symbol + "  |  " + ChartTimeframeText();

   //  Line 1: value slot for the status word plus, when something is
   //  blocking, a 2-character gap and the "Resume ..." countdown.  The
   //  slot keeps its 6-character floor so the panel measures exactly as
   //  it did before whenever the timer is not in the way - it can only
   //  grow while the timer is actually holding placement back, which is
   //  at most a couple of times a day (and it shrinks again by itself).
   string autoText   = AutoTradingHeaderText();
   string resumeText = ResumeHeaderText();
   int    autoSlot   = (int)MathMax(6, StringLen(autoText));
   int    resumeSlot = (resumeText == "") ? 0 : (StringLen(resumeText) + 2);

   //  The Day diary counts live in the remaining header space after
   //  Autotrading/Resume and before the symbol.  Their slot is part of
   //  this same measurement, so they use blank space when it exists
   //  and widen the header only when it does not - never collide.
   string dayText    = DiaryDayHeaderText();
   int    daySlot    = StringLen(dayText) + 2;
   string healthNote = HealthNoteText();

   int    titleHeadW = pad + titleW + em
                       + (16 + autoSlot + resumeSlot + daySlot + 2 + StringLen(symRight)) * em + pad;
   int    statusHeadW = pad + STATUS_LINE_C * em + pad;
   int    headW     = (int)MathMax(titleHeadW, statusHeadW);
   int    wantW     = (int)MathMax(NoticeWidth(), headW);
   wantW            = (int)MathMax(wantW, PlanWidthNeed());
   if(healthNote != "")
      wantW = (int)MathMax(wantW, pad + StringLen(healthNote) * em + pad);
   int    mainHeadH = MainHeaderHeight();
   g_panelW         = wantW;
   g_panelH         = mainHeadH + TF_COUNT * 2 * rowH + 8
                      + PLAN_SEP_H + TotalPlanLines() * rowH
                      + ((healthNote != "") ? (rowH + 4) : 0);
   MakeRect("bg",  x, y, g_panelW, g_panelH, InpBgColor, clrDimGray);
   MakeRect("sep", x + 4, y + mainHeadH - 6, g_panelW - 8, 1, clrDimGray, clrDimGray);

   // ---- header: SimpleEA2.0 | Autotrading : On/Off/Timer Pause | SYMBOL | TF
   //  The word states the EFFECTIVE state (see AutoTradingHeaderText): the
   //  input is never rewritten, so the panel - not the dialog - is where
   //  the truth about "the timer is holding me back" is told.  Beside it,
   //  while something blocks placement, the countdown to when it reopens.
   MakeLabel("title", x + pad, y + 7, PANEL_TITLE,
             InpTitleColor, InpFontSize + 1, false);
   int autoCapX = x + pad + titleW + em;
   MakeLabel("autoCap", autoCapX, y + 8, "| Autotrading : ",
             clrSilver, InpFontSize, false);
   int autoValX = autoCapX + 16 * em;
   MakeLabel("autoVal", autoValX, y + 8, autoText,
             AutoTradingHeaderColor(), InpFontSize, false);
   if(resumeText != "")
      MakeLabel("resumeVal", autoValX + (autoSlot + 2) * em, y + 8, resumeText,
                clrOrange, InpFontSize, false);
   else
      DeleteObject("resumeVal");
   MakeLabel("dayVal", autoValX + (autoSlot + resumeSlot + 2) * em, y + 8,
             dayText, clrSilver, InpFontSize, false);
   MakeLabel("sym", x + g_panelW - pad, y + 8, symRight,
             InpTitleColor, InpFontSize, true);

   // ---- header line 2: the modes behind that On/Off/Paused -----------
   //  Fixed character columns (widest timer text reserved), so the
   //  three settings never shuffle sideways as their values change.
   //  Off is grey, not red: a switched-off mode is a choice, not an
   //  error.  Orange is reserved for a timer that is blocking trades.
   int statusY   = y + 8 + rowH;
   int timerCapX = x + pad;
   MakeLabel("timerCap", timerCapX, statusY, "Timer: ",
             clrSilver, InpFontSize, false);
   MakeLabel("timerVal", timerCapX + 7 * em, statusY, TimerHeaderText(),
             TimerHeaderColor(), InpFontSize, false);
   //  What the "Resume ..." line currently says, in minutes, so the 2-second
   //  tick can redraw exactly when the displayed minute rolls over.
   g_resumeMinsShown = ResumeMinutes();

   int choppyCapX = timerCapX + 26 * em;  // 7 + 18-char timer reserve + 1 space
   MakeLabel("choppyCap", choppyCapX, statusY, "| Choppy Trade: ",
             clrSilver, InpFontSize, false);
   //  This value is the PERMISSION (InpAllowChoppyTrade), not the box
   //  entry style (InpRangeMode): Off must mean no new Choppy order.
   MakeLabel("choppyVal", choppyCapX + 16 * em, statusY,
             InpAllowChoppyTrade ? "On" : "Off",
             InpAllowChoppyTrade ? InpBuyColor : clrGray, InpFontSize, false);

   int linkCapX = timerCapX + 46 * em;    // choppy value (3) + 1 space further on
   MakeLabel("linkCap", linkCapX, statusY, "| M15/M30 Same Trend: ",
             clrSilver, InpFontSize, false);
   MakeLabel("linkVal", linkCapX + 22 * em, statusY,
             InpRequireM15M30SameTrend ? "On" : "Off",
             InpRequireM15M30SameTrend ? InpBuyColor : clrGray,
             InpFontSize, false);

   // ---- two lines per timeframe -------------------------------------
   //  One column grid for both groups: the plan's captions and the row's
   //  "Trend:" / "Regime:" / "Signal:" / "Score:" labels share these x
   //  positions, so the two groups line up at every font size.
   int cA, vA, cB, vB, cC, vC;
   PlanColumns(cA, vA, cB, vB, cC, vC);
   int styleX = pad + 4 * em;        // clear of the 3-char timeframe tag

   //  Line 1 (plain words, every value NAMED so nothing is ambiguous):
   //     Trend: Going up      Regime: Steady
   //  Line 2 (the original trading read, kept from the first panel):
   //     Signal: BUY          Score: +3 / 3
   //  Trend = which way it is going, Regime = how it is moving,
   //  Signal/Score = what the old panel used to show on its own.
   for(int i = 0; i < TF_COUNT; i++)
   {
      int    ry  = y + mainHeadH + 2 + i * 2 * rowH;
      string sfx = "_" + IntegerToString(i);

      MakeLabel("tf" + sfx,    x + pad,      ry, g_rows[i].tag,
                clrWhite, InpFontSize, false);
      MakeLabel("style" + sfx, x + styleX, ry, g_rows[i].style,
                clrGray, InpFontSize, false);
      //  One compact diary verdict in the blank left half of the
      //  Signal line.  PlanColumns() reserves this strip, so the
      //  label can never run under "Signal:".
      MakeLabel("health" + sfx, x + pad, ry + rowH, HealthLabelText(i),
                HealthLabelColor(i), InpFontSize, false);

      MakeLabel("trendCap" + sfx,  x + cA, ry, "Trend:",
                clrGray, InpFontSize, false);
      MakeLabel("regimeCap" + sfx, x + cB, ry, "Regime:",
                clrGray, InpFontSize, false);
      MakeLabel("signalCap" + sfx, x + cA, ry + rowH, "Signal:",
                clrGray, InpFontSize, false);
      MakeLabel("scoreCap" + sfx,  x + cB, ry + rowH, "Score:",
                clrGray, InpFontSize, false);

      if(g_rows[i].ok)
      {
         //  THE TREND LINE SHOWS THE TREND (vote 1).  It used to print the
         //  row's trade direction, which read "Going down" on a range sell
         //  in an uptrend - the single most misleading thing on the panel.
         MakeLabel("dir" + sfx, x + vA, ry, PlainTrendText(g_rows[i].trendDir),
                   DirectionColor(g_rows[i].trendDir), InpFontSize + 1, false);
         MakeLabel("regimeVal" + sfx, x + vB, ry, RegimeText(i),
                   RegimeColor(i), InpFontSize + 1, false);
         //  A blocked row shows the trade its score WOULD have fired,
         //  greyed out - the gate now has a word and a colour instead of
         //  a silent HOLD.  A quiet row keeps its normal HOLD.
         int  sigDir = g_rows[i].direction;
         //  A Choppy-vetoed row keeps its would-be BUY/SELL word (that is
         //  useful information, and an open trade still needs the same
         //  direction for management), but grey says no NEW order may use it.
         bool greyed = g_rows[i].choppyBlocked;
         if(sigDir == 0)
         {
            if(g_rows[i].score >= InpBuyScore)       { sigDir = 1;  greyed = true; }
            else if(g_rows[i].score <= InpSellScore) { sigDir = -1; greyed = true; }
         }
         MakeLabel("signal" + sfx, x + vA, ry + rowH,
                   DirectionText(sigDir),
                   greyed ? clrGray : DirectionColor(sigDir), InpFontSize + 1, false);
         MakeLabel("score" + sfx, x + vB, ry + rowH,
                   StringFormat("%+d / 3", g_rows[i].score),
                   greyed ? clrGray : DirectionColor(sigDir), InpFontSize + 1, false);
      }
      else
      {
         MakeLabel("dir" + sfx,       x + vA, ry, "Waiting",
                   clrDimGray, InpFontSize, false);
         MakeLabel("regimeVal" + sfx, x + vB, ry, "...",
                   clrDimGray, InpFontSize, false);
         MakeLabel("signal" + sfx,    x + vA, ry + rowH, "...",
                   clrDimGray, InpFontSize, false);
         MakeLabel("score" + sfx,     x + vB, ry + rowH, "...",
                   clrDimGray, InpFontSize, false);
      }
   }

   // ---- the trade plan: one block per timeframe below the rows -------
   //  Always drawn: the plan is the panel's answer to "what will it do
   //  next", and the auto-trader reads the same numbers, so hiding it
   //  would only hide the working.
   DrawPlanBlock(x, y);

   // ---- one temporary bottom line, only while a lane is Poor --------
   if(healthNote != "")
   {
      int healthNoteY = y + mainHeadH + 2 + TF_COUNT * 2 * rowH
                        + PLAN_SEP_H + TotalPlanLines() * rowH + 2;
      MakeLabel("healthNote", x + pad, healthNoteY, healthNote,
                InpSellColor, InpFontSize, false);
   }
   else
      DeleteObject("healthNote");

   // ---- the 2nd panel (Autotrading): right of the Main Panel ---------
   DrawAutoPanel();

   // ---- the optional 3rd panel (History), opposite Autotrading ------
   DrawHistoryPanel();

   // ---- retire the notice-only panel, if it was the last one shown ----
   DeleteObject("notice");

   g_panelOK = true;
   g_drawnTf = (ENUM_TIMEFRAMES)Period();
}

//+------------------------------------------------------------------+
//  Column geometry for the plan blocks.  The labels sit at the same x
//  positions as the "Trend:" / "Regime:" labels of the row above, so the
//  two groups line up; a column is pushed right only when the values in
//  the column before it are unusually wide.
//+------------------------------------------------------------------+
void PlanColumns(int &cA, int &vA, int &cB, int &vB, int &cC, int &vC)
{
   int em = CharW(InpFontSize);

   //  The anchors are the font-9 design; ColX() scales them by the font
   //  the user actually picked.  The value x of each column is its label
   //  x + PLAN_LBL_C em (the widest caption plus a space), so a value can
   //  never start inside its own label - that was the 9-point-only gap.

   //  Column A also has to clear the decision word that sits left of it
   //  ("pending -2/3", or the same plus "[PLACED]" on a one-line block),
   //  which starts at 5 em.  At a small font the scaled anchor alone is
   //  not wide enough for both.
   int kindW = StringLen("pending -2/3");
   for(int i = 0; i < TF_COUNT; i++)
   {
      int w = StringLen(g_plans[i].kind);
      string tag = AutoStatusTag(i);
      if(tag != "" && g_plans[i].lines == 1)
         w += 1 + StringLen(tag);
      kindW = (int)MathMax(kindW, w);
   }

   //  Column A also clears the compact health label on each Signal
   //  line ("Health: Learning" + one space = 17 characters from pad).
   cA = (int)MathMax(MathMax(ColX(PLAN_COL_A), 10 + 5 * em + kindW * em + em),
                     10 + 17 * em);
   vA = cA + em * PLAN_LBL_C;

   //  Seed with the widest GROUP-1 values in this column ("Going down" is
   //  10 chars; the Signal cell is 4), then let the plan cells push the
   //  next column right only if they are wider still.
   int wA = 10 * em;
   for(int i = 0; i < TF_COUNT; i++)
      for(int l = 0; l < g_plans[i].lines; l++)
         if(g_plans[i].lbl[l][0] != "")
            wA = (int)MathMax(wA, StringLen(g_plans[i].val[l][0]) * em);

   cB = (int)MathMax(ColX(PLAN_COL_B), vA + wA + em * 2);
   vB = cB + em * PLAN_LBL_C;

   int wB = 6 * em;                  // "Choppy" / "+3 / 3" from the rows
   for(int i = 0; i < TF_COUNT; i++)
      for(int l = 0; l < g_plans[i].lines; l++)
         if(g_plans[i].lbl[l][1] != "")
            wB = (int)MathMax(wB, StringLen(g_plans[i].val[l][1]) * em);

   cC = (int)MathMax(ColX(PLAN_COL_C), vB + wB + em * 2);
   vC = cC + em * PLAN_LBL_C;
}

//+------------------------------------------------------------------+
//  How many lines the second group needs: 3 per active timeframe, 1 for
//  a HOLD or waiting one.  The panel height follows this, so the block
//  is never taller than it has content for.
//+------------------------------------------------------------------+
int TotalPlanLines()
{
   int n = 0;
   for(int i = 0; i < TF_COUNT; i++)
      n += g_plans[i].lines;
   return(n);
}

//+------------------------------------------------------------------+
//  How much width the second group needs, in pixels.  The panel is
//  sized from this before anything is drawn, so no line can run past the
//  right edge - whatever the price digits or the balance happen to be.
//+------------------------------------------------------------------+
int PlanWidthNeed()
{
   if(!ChartSupported()) return(0);

   int cA, vA, cB, vB, cC, vC;
   PlanColumns(cA, vA, cB, vB, cC, vC);
   int em = CharW(InpFontSize);

   //  timeframe tag at x+10 and the kind ("pending +3/3") at x+5 em
   int need = 10 + 5 * em + StringLen("pending +3/3") * em + 10;

   //  Group 1 draws on this same grid, so its widest cell has a say too.
   //  Sizing the panel from the plan alone clipped a reading at 10 points
   //  ("Choppy" / "+3 / 3" are the last cells of the two line 2s).
   need = (int)MathMax(need, vA + 5 * em + 10);      // "SELL" / "HOLD" / "Waiting"
   need = (int)MathMax(need, vB + 6 * em + 10);      // "Choppy" / "+3 / 3"
   string healthNote = HealthNoteText();
   if(healthNote != "")
      need = (int)MathMax(need, 10 + StringLen(healthNote) * em + 10);

   for(int i = 0; i < TF_COUNT; i++)
   {
      if(g_plans[i].lines == 1)
      {
         if(g_plans[i].note != "")
            need = (int)MathMax(need, cA + StringLen(g_plans[i].note) * em + 10);
         continue;
      }
      for(int l = 0; l < PLAN_LINES; l++)
         for(int c = 0; c < 3; c++)
         {
            if(g_plans[i].lbl[l][c] == "") continue;
            int vx = (c == 0) ? vA : ((c == 1) ? vB : vC);
            need = (int)MathMax(need, vx + StringLen(g_plans[i].val[l][c]) * em + 10);
         }
   }
   return(need);
}

//+------------------------------------------------------------------+
//  Draw the second group: one block per timeframe, separated from the
//  first group by a single line.  There is no heading line - the
//  timeframe tag at the start of each block says what it is.
//
//    M5   market -3/3   Entry: 4285.70        Lot: 0.28
//                       Stop: 4285.98 28pts   Target: 4285.45 25pts  Reach: ~1 bar
//                       Risk: 7.84 USD        Reward: 7.00 USD   Valid: 3/3 bars
//    M15  range fade    Entry: 4279.10 (limit at the band)           Lot: 0.28
//                       Stop: 4271.10 80pts   Target: 4287.10 80pts  Reach: ~2 bars
//    M30  pending -2/3  Entry: 4286.55        Lot: 0.01
//                       Stop: 4289.10 255pts   Target: 4281.45 510pts  Reach: ~9 bars
//    (a row stands aside only for a dead market or a score under the gate:
//     HOLD  score +1/3 - under the +2/-2 gate)
//
//+------------------------------------------------------------------+
void DrawPlanBlock(int x, int y)
{
   if(RowForChartTF() < 0) return;              // only on M5/M15/M30 charts

   int rowH = g_rowH;
   int gy   = y + MainHeaderHeight() + 2 + TF_COUNT * 2 * rowH + PLAN_SEP_H;

   //  the separator between the two groups
   MakeRect("planSep", x + 4, gy - 8, g_panelW - 8, 1, clrDimGray, clrDimGray);

   int cA, vA, cB, vB, cC, vC;
   PlanColumns(cA, vA, cB, vB, cC, vC);
   int kindX = 10 + 5 * CharW(InpFontSize);     // clear of the "M30" tag

   int line = 0;
   for(int i = 0; i < TF_COUNT; i++)
   {
      int    ry  = gy + line * rowH;
      string sfx = "_" + IntegerToString(i);

      // ---- timeframe tag and the entry decision --------------------
      MakeLabel("planHead" + sfx, x + 10, ry, g_plans[i].head,
                clrWhite, InpFontSize, false);

      color  kc      = clrDimGray;
      string kindTxt = g_plans[i].kind;
      string autoTag = AutoStatusTag(i);

      if(g_plans[i].state == 2)
         kc = (g_plans[i].dir > 0) ? InpBuyColor : InpSellColor;
      else if(autoTag != "" && g_plans[i].lines == 1)
      {
         kindTxt = (kindTxt != "") ? (kindTxt + " " + autoTag) : autoTag;
         kc      = (g_auto[i].dir > 0) ? InpBuyColor : InpSellColor;
      }

      if(kindTxt != "")
         MakeLabel("planKind" + sfx, x + kindX, ry, kindTxt, kc, InpFontSize, false);
      else
         DeleteObject("planKind" + sfx);

      // ---- mark [OPEN] or [PLACED] on the Main Panel plan block ----
      string stName = "planStatus" + sfx;
      if(autoTag != "" && g_plans[i].lines > 1)
      {
         color stClr = (g_auto[i].dir > 0) ? InpBuyColor : InpSellColor;
         MakeLabel(stName, x + kindX, ry + rowH, autoTag, stClr, InpFontSize, false);
      }
      else
         DeleteObject(stName);

      // ---- one-liner for a HOLD or waiting block -------------------
      string nn = "planNote" + sfx;
      if(g_plans[i].lines == 1 && g_plans[i].note != "")
         MakeLabel(nn, x + cA, ry, g_plans[i].note, clrDimGray, InpFontSize, false);
      else
         DeleteObject(nn);

      // ---- the cells ------------------------------------------------
      for(int l = 0; l < PLAN_LINES; l++)
      {
         for(int c = 0; c < 3; c++)
         {
            string ln = "planCell" + sfx + "_" + IntegerToString(l) + "_" + IntegerToString(c);
            if(l >= g_plans[i].lines || g_plans[i].lbl[l][c] == "")
            {
               DeleteObject(ln + "L");
               DeleteObject(ln + "V");
               continue;
            }
            int cx = (c == 0) ? cA : ((c == 1) ? cB : cC);
            int vx = (c == 0) ? vA : ((c == 1) ? vB : vC);

            MakeLabel(ln + "L", x + cx, ry + l * rowH,
                      g_plans[i].lbl[l][c], clrGray, InpFontSize, false);
            MakeLabel(ln + "V", x + vx, ry + l * rowH,
                      g_plans[i].val[l][c], g_plans[i].clr[l][c], InpFontSize, false);
         }
      }

      line += g_plans[i].lines;
   }
}

//+------------------------------------------------------------------+
void DeletePlanObjects()
{
   DeleteObject("planSep");
   for(int i = 0; i < TF_COUNT; i++)
   {
      string sfx = "_" + IntegerToString(i);
      DeleteObject("planHead"   + sfx);
      DeleteObject("planKind"   + sfx);
      DeleteObject("planStatus" + sfx);
      DeleteObject("planNote"   + sfx);
      for(int l = 0; l < PLAN_LINES; l++)
         for(int c = 0; c < 3; c++)
         {
            string ln = "planCell" + sfx + "_" + IntegerToString(l) + "_" + IntegerToString(c);
            DeleteObject(ln + "L");
            DeleteObject(ln + "V");
         }
   }
}

//==================================================================
//  SECOND PANEL : AUTOTRADING (RIGHT SIDE OF MAIN PANEL)
//==================================================================
//  Opens automatically when at least one market position or pending
//  limit order is active, and closes completely when flat.
//+------------------------------------------------------------------+
void MakeAutoLabel(string name, int x, int y, string text, color clr,
                   int size, bool rightAnchor)
{
   string full = AUTO_PREFIX + name;
   if(ObjectFind(0, full) < 0)
      ObjectCreate(0, full, OBJ_LABEL, 0, 0, 0);

   if(size < 6) size = 6;

   ObjectSetInteger(0, full, OBJPROP_CORNER,     CORNER_LEFT_UPPER);
   ObjectSetInteger(0, full, OBJPROP_XDISTANCE,  x);
   ObjectSetInteger(0, full, OBJPROP_YDISTANCE,  y);
   ObjectSetInteger(0, full, OBJPROP_COLOR,      clr);
   ObjectSetInteger(0, full, OBJPROP_FONTSIZE,   size);
   ObjectSetString (0, full, OBJPROP_FONT,       InpFont);
   ObjectSetInteger(0, full, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, full, OBJPROP_HIDDEN,     true);
   ObjectSetInteger(0, full, OBJPROP_BACK,       false);
   ObjectSetInteger(0, full, OBJPROP_ANCHOR,
                    rightAnchor ? ANCHOR_RIGHT_UPPER : ANCHOR_LEFT_UPPER);
   ObjectSetString (0, full, OBJPROP_TEXT,       text);
}

//+------------------------------------------------------------------+
void MakeAutoRect(string name, int x, int y, int w, int hh, color bg, color border)
{
   string full = AUTO_PREFIX + name;
   if(ObjectFind(0, full) < 0)
      ObjectCreate(0, full, OBJ_RECTANGLE_LABEL, 0, 0, 0);

   ObjectSetInteger(0, full, OBJPROP_CORNER,      CORNER_LEFT_UPPER);
   ObjectSetInteger(0, full, OBJPROP_XDISTANCE,   x);
   ObjectSetInteger(0, full, OBJPROP_YDISTANCE,   y);
   ObjectSetInteger(0, full, OBJPROP_XSIZE,       w);
   ObjectSetInteger(0, full, OBJPROP_YSIZE,       hh);
   ObjectSetInteger(0, full, OBJPROP_BGCOLOR,     bg);
   ObjectSetInteger(0, full, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, full, OBJPROP_COLOR,       border);
   ObjectSetInteger(0, full, OBJPROP_WIDTH,       1);
   ObjectSetInteger(0, full, OBJPROP_BACK,        false);
   ObjectSetInteger(0, full, OBJPROP_SELECTABLE,  false);
   ObjectSetInteger(0, full, OBJPROP_HIDDEN,      true);
}

//+------------------------------------------------------------------+
void DeleteAutoObject(string name)
{
   string full = AUTO_PREFIX + name;
   if(ObjectFind(0, full) >= 0)
      ObjectDelete(0, full);
}

//+------------------------------------------------------------------+
void DeleteAutoPanel()
{
   ObjectsDeleteAll(0, AUTO_PREFIX);
   g_autoShown = false;
}

//+------------------------------------------------------------------+
//  Column geometry for the 2nd Panel ("Autotrading").
//+------------------------------------------------------------------+
void AutoColumns(int &cA, int &vA, int &cB, int &vB, int &cC, int &vC)
{
   int em = CharW(InpFontSize);

   cA = (int)MathMax(ColX(AUTO_COL_A), 10 + (int)StringLen("M30 | SELL LIMIT") * em + em * 2);
   vA = cA + em * AUTO_LBL_A;

   int wA = 0;
   for(int i = 0; i < TF_COUNT; i++)
   {
      if(!g_auto[i].active) continue;
      for(int l = 0; l < AUTO_LINES; l++)
         if(g_auto[i].lbl[l][0] != "")
            wA = (int)MathMax(wA, StringLen(g_auto[i].val[l][0]) * em);
   }

   cB = (int)MathMax(ColX(AUTO_COL_B), vA + wA + em * 2);
   vB = cB + em * AUTO_LBL_B;

   int wB = 0;
   for(int i = 0; i < TF_COUNT; i++)
   {
      if(!g_auto[i].active) continue;
      for(int l = 0; l < AUTO_LINES; l++)
         if(g_auto[i].lbl[l][1] != "")
            wB = (int)MathMax(wB, StringLen(g_auto[i].val[l][1]) * em);
   }

   cC = (int)MathMax(ColX(AUTO_COL_C), vB + wB + em * 2);
   vC = cC + em * AUTO_LBL_C;
}

//+------------------------------------------------------------------+
int AutoWidthNeed()
{
   if(!ChartSupported() || !AnyAutoActive()) return(0);

   int cA, vA, cB, vB, cC, vC;
   AutoColumns(cA, vA, cB, vB, cC, vC);
   int em     = CharW(InpFontSize);
   int titleW = 11 * CharW(InpFontSize + 1);

   int headNeed = 10 + titleW + em
                  + (14 + 6 + 1 + 13 + 3 + 2 + StringLen("|  " + _Symbol)) * em + 10;
   int need = (int)MathMax(AUTO_W_MIN, headNeed);
   for(int i = 0; i < TF_COUNT; i++)
   {
      if(!g_auto[i].active) continue;
      for(int l = 0; l < AUTO_LINES; l++)
         for(int c = 0; c < 3; c++)
         {
            if(g_auto[i].lbl[l][c] == "") continue;
            int vx = (c == 0) ? vA : ((c == 1) ? vB : vC);
            need = (int)MathMax(need, vx + StringLen(g_auto[i].val[l][c]) * em + 10);
         }
   }
   return(need);
}

//+------------------------------------------------------------------+
//  Draw the 2nd Panel ("Autotrading") on the right or bottom of the
//  Main Panel when at least one market or pending order is open; close
//  it completely when no trade is open.
//+------------------------------------------------------------------+
void DrawAutoPanel()
{
   if(!ChartSupported() || !AnyAutoActive())
   {
      if(g_autoShown)
         DeleteAutoPanel();
      return;
   }

   int activeCnt = ActiveAutoCount();
   int rowH      = g_rowH;
   int pad       = 10;
   int x2        = (InpAutoPanelPos == AUTO_POS_BOTTOM)
                   ? InpPanelX
                   : (InpPanelX + g_panelW + AUTO_GAP_X);
   int y2        = (InpAutoPanelPos == AUTO_POS_BOTTOM)
                   ? (InpPanelY + g_panelH + AUTO_GAP_Y)
                   : InpPanelY;

   g_autoW = AutoWidthNeed();
   g_autoH = HEAD_H + activeCnt * AUTO_LINES * rowH
             + (activeCnt > 1 ? (activeCnt - 1) * AUTO_SEP_H : 0) + 8;

   MakeAutoRect("bg",  x2, y2, g_autoW, g_autoH, InpBgColor, clrDimGray);
   MakeAutoRect("sep", x2 + 4, y2 + HEAD_H - 6, g_autoW - 8, 1, clrDimGray, clrDimGray);

   //  The Trailstop header word has three states, so the switch and the
   //  trades never lie about each other:
   //     Off     InpUseTrailStop is false - the feature is disabled
   //     On      enabled and armed, but no trade is trailing yet
   //     Active  at least one trade is actually trailing right now
   bool   tsLive = AnyTrailstopOn();
   string tsText = !InpUseTrailStop ? "Off" : (tsLive ? "Active" : "On");
   color  tsClr  = InpUseTrailStop ? InpBuyColor : InpSellColor;
   bool   slOn   = AnyStoplossOn();
   int  em     = CharW(InpFontSize);
   int  titleW = 11 * CharW(InpFontSize + 1);

   MakeAutoLabel("title", x2 + pad, y2 + 7, "Autotrading",
                 InpTitleColor, InpFontSize + 1, false);
   int tsCapX = x2 + pad + titleW + em;
   MakeAutoLabel("tsCap", tsCapX, y2 + 8, "| Trailstop : ",
                 clrSilver, InpFontSize, false);
   int tsValX = tsCapX + 14 * em;
   MakeAutoLabel("tsVal", tsValX, y2 + 8, tsText,
                 tsClr, InpFontSize, false);
   int slCapX = tsValX + 6 * em + em;   // value slot fits the widest state, "Active"
   MakeAutoLabel("slCap", slCapX, y2 + 8, "| Stoploss : ",
                 clrSilver, InpFontSize, false);
   int slValX = slCapX + 13 * em;
   MakeAutoLabel("slVal", slValX, y2 + 8, slOn ? "On" : "Off",
                 slOn ? InpBuyColor : InpSellColor, InpFontSize, false);
   MakeAutoLabel("sym", x2 + g_autoW - pad, y2 + 8, "|  " + _Symbol,
                 InpTitleColor, InpFontSize, true);

   int cA, vA, cB, vB, cC, vC;
   AutoColumns(cA, vA, cB, vB, cC, vC);

   int curY  = y2 + HEAD_H + 2;
   int shown = 0;

   for(int i = 0; i < TF_COUNT; i++)
   {
      string sfx = "_" + IntegerToString(i);
      if(!g_auto[i].active)
      {
         DeleteAutoObject("cardSep"  + sfx);
         DeleteAutoObject("cardHead" + sfx);
         for(int l = 0; l < AUTO_LINES; l++)
            for(int c = 0; c < 3; c++)
            {
               string cn = "cardCell" + sfx + "_" + IntegerToString(l) + "_" + IntegerToString(c);
               DeleteAutoObject(cn + "L");
               DeleteAutoObject(cn + "V");
            }
         continue;
      }

      if(shown > 0)
      {
         MakeAutoRect("cardSep" + sfx, x2 + 4, curY + 3, g_autoW - 8, 1, clrDimGray, clrDimGray);
         curY += AUTO_SEP_H;
      }
      else
         DeleteAutoObject("cardSep" + sfx);

      MakeAutoLabel("cardHead" + sfx, x2 + pad, curY, g_auto[i].head,
                    g_auto[i].headClr, InpFontSize, false);

      for(int l = 0; l < AUTO_LINES; l++)
      {
         for(int c = 0; c < 3; c++)
         {
            string cn = "cardCell" + sfx + "_" + IntegerToString(l) + "_" + IntegerToString(c);
            if(g_auto[i].lbl[l][c] == "")
            {
               DeleteAutoObject(cn + "L");
               DeleteAutoObject(cn + "V");
               continue;
            }
            int cx = (c == 0) ? cA : ((c == 1) ? cB : cC);
            int vx = (c == 0) ? vA : ((c == 1) ? vB : vC);

            MakeAutoLabel(cn + "L", x2 + cx, curY + l * rowH,
                          g_auto[i].lbl[l][c], clrGray, InpFontSize, false);
            MakeAutoLabel(cn + "V", x2 + vx, curY + l * rowH,
                          g_auto[i].val[l][c], g_auto[i].clr[l][c], InpFontSize, false);
         }
      }

      curY += AUTO_LINES * rowH;
      shown++;
   }

   g_autoShown = true;
}

//==================================================================
//  THIRD PANEL : HISTORY (OPTIONAL, InpShowHealth)
//==================================================================
//  The diary records whether this panel is shown or not.  The panel
//  is the diary opened up: Day and lifetime totals first, then one
//  block per timeframe with its lifetime record, its 2/3-versus-3/3
//  split, the health and trailstop performance of its newest closed
//  trades, and the first fix that health suggests.  It sits opposite
//  the Autotrading panel:
//  Autotrading Right -> History below the Main Panel; Autotrading
//  Bottom -> History on the right.
//+------------------------------------------------------------------+
int  g_histW     = 0;
int  g_histH     = 0;
bool g_histShown = false;

//+------------------------------------------------------------------+
void MakeHistLabel(string name, int x, int y, string text, color clr,
                   int size, bool rightAnchor)
{
   string full = HIST_PREFIX + name;
   if(ObjectFind(0, full) < 0)
      ObjectCreate(0, full, OBJ_LABEL, 0, 0, 0);

   if(size < 6) size = 6;
   ObjectSetInteger(0, full, OBJPROP_CORNER,     CORNER_LEFT_UPPER);
   ObjectSetInteger(0, full, OBJPROP_XDISTANCE,  x);
   ObjectSetInteger(0, full, OBJPROP_YDISTANCE,  y);
   ObjectSetInteger(0, full, OBJPROP_COLOR,      clr);
   ObjectSetInteger(0, full, OBJPROP_FONTSIZE,   size);
   ObjectSetString (0, full, OBJPROP_FONT,       InpFont);
   ObjectSetInteger(0, full, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, full, OBJPROP_HIDDEN,     true);
   ObjectSetInteger(0, full, OBJPROP_BACK,       false);
   ObjectSetInteger(0, full, OBJPROP_ANCHOR,
                    rightAnchor ? ANCHOR_RIGHT_UPPER : ANCHOR_LEFT_UPPER);
   ObjectSetString (0, full, OBJPROP_TEXT,       text);
}

//+------------------------------------------------------------------+
void MakeHistRect(string name, int x, int y, int w, int hh, color bg, color border)
{
   string full = HIST_PREFIX + name;
   if(ObjectFind(0, full) < 0)
      ObjectCreate(0, full, OBJ_RECTANGLE_LABEL, 0, 0, 0);

   ObjectSetInteger(0, full, OBJPROP_CORNER,      CORNER_LEFT_UPPER);
   ObjectSetInteger(0, full, OBJPROP_XDISTANCE,   x);
   ObjectSetInteger(0, full, OBJPROP_YDISTANCE,   y);
   ObjectSetInteger(0, full, OBJPROP_XSIZE,       w);
   ObjectSetInteger(0, full, OBJPROP_YSIZE,       hh);
   ObjectSetInteger(0, full, OBJPROP_BGCOLOR,     bg);
   ObjectSetInteger(0, full, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, full, OBJPROP_COLOR,       border);
   ObjectSetInteger(0, full, OBJPROP_WIDTH,       1);
   ObjectSetInteger(0, full, OBJPROP_BACK,        false);
   ObjectSetInteger(0, full, OBJPROP_SELECTABLE,  false);
   ObjectSetInteger(0, full, OBJPROP_HIDDEN,      true);
}

//+------------------------------------------------------------------+
void DeleteHistoryPanel()
{
   ObjectsDeleteAll(0, HIST_PREFIX);
   g_histShown = false;
   g_histW = 0;
   g_histH = 0;
}

//+------------------------------------------------------------------+
void DrawHistoryPanel()
{
   if(!InpShowHealth || !ChartSupported() || !g_diaryReady)
   {
      if(g_histShown)
         DeleteHistoryPanel();
      return;
   }

   string lines[21];
   color  colors[21];

   lines[0] = StringFormat("Day: S %d  W %d  L %d  BE %d  Exp %d",
                           g_dayTotals.signals, g_dayTotals.wins,
                           g_dayTotals.losses, g_dayTotals.be,
                           g_dayTotals.expired);
   colors[0] = InpTitleColor;

   lines[1] = StringFormat("All: S %d  W %d  L %d  BE %d  Open %d  Wait %d  Exp %d  Net %s",
                           g_allTotals.signals, g_allTotals.wins,
                           g_allTotals.losses, g_allTotals.be,
                           g_allTotals.openCount, g_allTotals.waitCount,
                           g_allTotals.expired, DiaryRText(g_allTotals.netR));
   colors[1] = clrSilver;

   for(int i = 0; i < TF_COUNT; i++)
   {
      SHealthLane lane = g_health[i];
      int base = 2 + i * 6;

      string status = lane.label;
      if(StringFind(status, "Health:") != 0)
         status = "Health: " + status;
      if(lane.status < 0)
         status += StringFormat(" (%d/%d closed)", lane.closedCount,
                                HEALTH_MIN_CLOSED);
      lines[base] = g_rows[i].tag + "  " + status;
      colors[base] = HealthLabelColor(i);

      int laneClosed = lane.wins + lane.losses + lane.be;
      lines[base + 1] = StringFormat(
         "  All: S %d W %d L %d BE %d Open %d Wait %d Exp %d | Win %s | Net %s",
         lane.signals, lane.wins, lane.losses, lane.be,
         lane.openCount, lane.waitCount, lane.expired,
         DiaryPctText(lane.wins, laneClosed), DiaryRText(lane.netR));
      colors[base + 1] = clrSilver;

      lines[base + 2] = StringFormat(
         "  Score 2/3: W %d L %d TP1 %s (%d closed) | 3/3: W %d L %d TP1 %s (%d closed)",
         lane.score2Wins, lane.score2Losses,
         DiaryPctText(lane.score2Tp1, lane.score2Closed), lane.score2Closed,
         lane.score3Wins, lane.score3Losses,
         DiaryPctText(lane.score3Tp1, lane.score3Closed), lane.score3Closed);
      colors[base + 2] = clrSilver;

      string peakTxt = (lane.recMedianPeak < 0.0)
                       ? "--"
                       : StringFormat("%.0f%%", lane.recMedianPeak);
      string costTxt = (lane.recMedianCost < 0.0)
                       ? "--"
                       : StringFormat("%.0f%%", lane.recMedianCost);
      lines[base + 3] = StringFormat(
         "  Last %d: W %d L %d BE %d | TP1 %s Peak %s Cost %s | Net %s",
         lane.recN, lane.recWins, lane.recLosses, lane.recBe,
         DiaryRatePctText(lane.recTp1Rate), peakTxt, costTxt,
         DiaryRText(lane.recNetR));
      colors[base + 3] = InpTitleColor;

      string trailLockTxt = (lane.recTrailMedianLock < 0.0)
                            ? "--"
                            : StringFormat("%.0f%%", lane.recTrailMedianLock);
      string trailGivebackTxt = (lane.recTrailMedianGiveback < 0.0)
                                ? "--"
                                : StringFormat("%.0f%%",
                                               lane.recTrailMedianGiveback);
      string trailStopTxt = (lane.recTrailStopKnown > 0)
                            ? IntegerToString(lane.recTrailStopExits)
                            : "--";
      lines[base + 4] = StringFormat(
         "  Trail %d: Armed %s | Lock %s | Stop exits %s | Giveback %s",
         lane.recN, DiaryRatePctText(lane.recTrailArmRate), trailLockTxt,
         trailStopTxt, trailGivebackTxt);
      colors[base + 4] = clrSilver;

      lines[base + 5] = "  First step: " + lane.action;
      colors[base + 5] = HealthLabelColor(i);
   }

   lines[20] = "Diary suggests first steps; it never changes settings.";
   colors[20] = clrGray;

   int em = CharW(InpFontSize);
   int rowH = g_rowH;
   int pad = 10;
   string sinceText = "|  " + _Symbol + "  |  Since " +
                      TimeToString(g_diaryStarted, TIME_DATE);
   int widthNeed = pad + 7 * CharW(InpFontSize + 1) + em +
                   StringLen(sinceText) * em + pad;
   for(int l = 0; l < 21; l++)
      widthNeed = (int)MathMax(widthNeed, pad + StringLen(lines[l]) * em + pad);
   widthNeed = (int)MathMax(widthNeed, HIST_W_MIN);

   int x3 = (InpAutoPanelPos == AUTO_POS_RIGHT)
            ? InpPanelX
            : (InpPanelX + g_panelW + AUTO_GAP_X);
   int y3 = (InpAutoPanelPos == AUTO_POS_RIGHT)
            ? (InpPanelY + g_panelH + AUTO_GAP_Y)
            : InpPanelY;

   g_histW = widthNeed;
   g_histH = HEAD_H + 21 * rowH + 2 * 4 + 8;
   MakeHistRect("bg", x3, y3, g_histW, g_histH, InpBgColor, clrDimGray);
   MakeHistRect("sep", x3 + 4, y3 + HEAD_H - 6, g_histW - 8, 1,
                clrDimGray, clrDimGray);
   MakeHistLabel("title", x3 + pad, y3 + 7, "History",
                 InpTitleColor, InpFontSize + 1, false);
   MakeHistLabel("since", x3 + g_histW - pad, y3 + 8, sinceText,
                 InpTitleColor, InpFontSize, true);

   int curY = y3 + HEAD_H + 2;
   for(int l = 0; l < 21; l++)
   {
      //  A hairline before the second and third timeframe blocks.
      if(l == 8 || l == 14)
      {
         MakeHistRect("laneSep" + IntegerToString(l), x3 + 4, curY + 1,
                      g_histW - 8, 1, clrDimGray, clrDimGray);
         curY += 4;
      }
      MakeHistLabel("line" + IntegerToString(l), x3 + pad, curY,
                    lines[l], colors[l], InpFontSize, false);
      curY += rowH;
   }

   g_histShown = true;
}

//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//  THE NOTICE PANEL - an unsupported chart timeframe, or a market that
//  is not trading.
//
//     +-----------------------------------------------+
//     |  SimpleEA2.0                     XAUUSD  H1   |     <- unsupported
//     +-----------------------------------------------+        or closed
//     |  Incompatible chart. Switch to M5/M15/M30.    |
//     +-----------------------------------------------+
//     |  Market Closed                                |               <- closed
//     +-----------------------------------------------+
//
//  That is the whole panel - the header line the user always sees, plus
//  the notice where the M5/M15/M30 rows would have started.  No rows, no
//  Trend, no Regime, no Signal, no Score.  On another chart a reading
//  would be meaningless; on a closed market there is nothing to read -
//  both facts are withheld completely, in the same two-line shape.  The
//  box is sized to those two lines and the object set is trimmed to
//  match, so nothing from the data panel can linger underneath it.
//+------------------------------------------------------------------+
void DrawNoticePanel(const string noticeTxt)
{
   int x   = InpPanelX, y = InpPanelY;
   int pad = 10;

   //  Keep the header exactly where it sits in the full panel and put the
   //  notice on the line where the first timeframe row would have started,
   //  so an unsupported chart reads as the panel collapsing to its header
   //  rather than as a different widget appearing.
   //  the notice is drawn at font+1, so its own line needs that much room
   //  plus a margin - at 10 points the old +6 left the text 2 px from the
   //  bottom edge
   int noticeH = HEAD_H + 2 + (InpFontSize + 1) + 8;

   MakeRect("bg", x, y, g_panelW, noticeH, InpBgColor, clrDimGray);

   //  The separator and the whole trade-plan block belong to the full
   //  panel only - an unsupported chart shows no plan either.
   DeleteObject("sep");
   DeleteObject("autoCap");
   DeleteObject("autoVal");
   DeleteObject("resumeVal");
   DeleteObject("dayVal");
   DeleteObject("healthNote");
   DeleteObject("timerCap");
   DeleteObject("timerVal");
   DeleteObject("choppyCap");
   DeleteObject("choppyVal");
   DeleteObject("linkCap");
   DeleteObject("linkVal");
   DeletePlanObjects();
   DeleteAutoPanel();
   DeleteHistoryPanel();

   MakeLabel("title", x + pad, y + 7, PANEL_TITLE,
             InpTitleColor, InpFontSize + 1, false);
   //  Deliberately the real chart timeframe: the header states the fact,
   //  the line underneath states what to do about it.
   MakeLabel("sym", x + g_panelW - pad, y + 8,
             _Symbol + "  " + ChartTimeframeText(),
             InpTitleColor, InpFontSize, true);

   MakeLabel("notice", x + pad, y + HEAD_H + 2,
             noticeTxt,          InpSellColor, InpFontSize + 1, false);

   //  Remove every row object the full panel uses, so a single leftover
   //  cannot show through on an incompatible chart.
   for(int i = 0; i < TF_COUNT; i++)
   {
      string sfx = "_" + IntegerToString(i);
      DeleteObject("tf"        + sfx);
      DeleteObject("style"     + sfx);
      DeleteObject("health"    + sfx);
      DeleteObject("trendCap"  + sfx);
      DeleteObject("regimeCap" + sfx);
      DeleteObject("signalCap" + sfx);
      DeleteObject("scoreCap"  + sfx);
      DeleteObject("dir"       + sfx);
      DeleteObject("regimeVal" + sfx);
      DeleteObject("signal"    + sfx);
      DeleteObject("score"     + sfx);
   }

   g_panelOK = false;
   g_drawnTf = (ENUM_TIMEFRAMES)Period();
}

//+------------------------------------------------------------------+
void DeletePanel()
{
   ObjectsDeleteAll(0, OBJ_PREFIX);
   ObjectsDeleteAll(0, AUTO_PREFIX);
   ObjectsDeleteAll(0, HIST_PREFIX);
   g_autoShown = false;
   g_histShown = false;
   ChartRedraw(0);
}
//+------------------------------------------------------------------+
