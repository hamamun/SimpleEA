//+------------------------------------------------------------------+
//| SimpleAdvisor.mq5 - M5/M15/M30 signal, structure plan & executor |
//|                                                                  |
//| The original signal engine retains its ATR noise deadbands.       |
//| New-entry prices, stops and targets do NOT use ATR multiples.    |
//| They use confirmed swings and conservative, completed historical |
//| Bid-bar analogs per symbol/timeframe/regime/score/entry style.   |
//|                                                                  |
//| InpAutoTrading defaults true: eligible new entries are enabled.   |
//| InpAutoTrading=false is read-only, including for open positions.  |
//| Spread is checked; broker commissions/fees are not estimated.    |
//| A plan HOLD does not erase the independent BUY/SELL signal.       |
//|                                                                  |
//| TP1/TP2 are EA-managed; the fixed SL and TP3 are broker-side.     |
//| Historical touches are not guaranteed fills, bar ordering/spread  |
//| are approximations, and no performance or profit is guaranteed.  |
//| Compile in MetaEditor, then test real ticks, forward and demo.    |
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

//  Where the M5 row takes its Steady / Mixed / Choppy label from.
//
//  The regime label is a measurement of HOW price has been moving, and
//  it is only as good as the history behind it.  HURST_WINDOW is counted
//  in bars, and 256 bars is 21 hours on M5 but 128 hours on M30 - one
//  sixth of the evidence.  On top of that, every quote bounces between
//  bid and ask, and that bounce makes short-horizon returns look
//  mean-reverting, which drags the estimate down.  Both effects are worst
//  on M5 and mild on M30, so M5 may read its regime from a slower row:
//
//     Own  - M5 keeps its own label (128 hours at M5 sampling)
//     M15  - M5 borrows M15's label (128 hours, 3-bar sampling)
//     M30  - M5 borrows M30's label (128 hours, 6-bar sampling)
//
//  This borrows the LABEL, it does not require the two rows to AGREE.
//  A "must match" rule would do the opposite of what is wanted: an M5
//  row that reads Choppy most of the time would only be allowed to trade
//  when the higher row was Choppy too - blocking every trend.
//
//  Direction and score stay M5's own.  Only the regime label - and with
//  it the entry style (box fade vs pullback) and Choppy permission -
//  comes from the chosen row.
enum ENUM_M5_REGIME
{
   M5_REGIME_OWN = 0, // M5's own
   M5_REGIME_M15 = 1, // Borrow from M15
   M5_REGIME_M30 = 2  // Borrow from M30
};

//==================================================================
//  INPUTS
//==================================================================
input group "=== Autotrading & order management ==="
input bool                InpAutoTrading  = true;            // Master: false is read-only (including existing positions)
//  Daily timer + one-shot pause, both on PC LOCAL time.  These gate
//  NEW placements only: while OFF, waiting pendings are cancelled and
//  already-open trades keep their fixed SL and TP1/TP2/TP3 handling.
input bool                InpUseAutoSchedule = false;        // Use daily autotrading timer (PC local time)
input string              InpAutoStartTime   = "08:00";      // Autotrading start time (PC local HH:MM)
input string              InpAutoEndTime     = "17:00";      // Autotrading stop time (PC local HH:MM)
input int                 InpAutoOffHours    = 0;            // One-shot pause hours from when set (0=off, 48=2 days)
input bool                InpRequireM15M30SameTrend = false; // M15/M30 same trend required to place (false = untied)
input long                InpMagicBase    = 202610;          // Base magic number (+0 M5, +1 M15, +2 M30)

//  WHICH TIMEFRAMES MAY TRADE AT ALL.  Three master switches, all on, so
//  a row can be taken out of the game without touching the signal engine
//  or the other two rows.  Switching one off does exactly what the daily
//  timer and the Choppy veto already do, no more and no less:
//     - NO NEW order of any kind is sent for that row (market or limit);
//     - a waiting pending on that row is cancelled - it is an unfilled
//       entry, and it could fill while the row is switched off;
//     - an ALREADY OPEN position keeps TP1/TP2/TP3 handling and its
//       unchanged SL.  A switch must never abandon a live trade.
//  The row keeps reading and keeps drawing its plan, so the panel still
//  shows what that timeframe would do if it were switched back on.
input bool                InpAutoTradeM5  = true;            // Autotrade M5  (false = no new M5 orders; open M5 trades stay managed)
input bool                InpAutoTradeM15 = true;            // Autotrade M15 (false = no new M15 orders; open M15 trades stay managed)
input bool                InpAutoTradeM30 = true;            // Autotrade M30 (false = no new M30 orders; open M30 trades stay managed)

input group "=== Signal, regime permission & range mode ==="
input int      InpBuyScore    = 2;           // Score >= this  => BUY
input int      InpSellScore   = -2;          // Score <= this  => SELL

//  TWO DIFFERENT CHOPPY QUESTIONS, TWO DIFFERENT SWITCHES.
//  1) InpAllowChoppyTrade is PERMISSION: "may a row that currently reads
//     Choppy open a new trade at all?"  False vetoes both a 2/3 limit and
//     a 3/3 market order on that row and cancels a still-waiting pending
//     when its row turns Choppy.  It never closes an already-open trade.
//  2) InpRangeMode is ENTRY STYLE, consulted only after permission is
//     given: on a Choppy 2/3, true lets a usable box price the limit;
//     false (or an unusable box) uses a confirmed swing pullback.
//  InpBuyScore / InpSellScore still gate every order in every regime
//  (ScoreAllowsTrade()), and the score still picks the order type:
//  3/3 -> market, 2/3 -> limit.  The Main Panel's "Choppy Trade" value
//  mirrors the PERMISSION switch, because that is what its words mean.
input bool     InpAllowChoppyTrade = true;   // Allow Choppy trade (false = no NEW orders while a row is Choppy)
//  The Mixed permission works exactly like the Choppy one, one switch for
//  all three rows.  Mixed is the label between the two thresholds
//  (HURST_REVERT <= H <= HURST_TREND) - neither trending nor reverting -
//  and it is the biggest of the three buckets, so switching this off
//  removes well over half of all entries.  That is a deliberate choice to
//  make, not a default, so it ships ON.
input bool     InpAllowMixedTrade  = true;   // Allow Mixed trade (false = no NEW orders while a row is Mixed)
// Choppy range mode can place a limit at a usable 20-bar box band;
// otherwise a limit uses a confirmed swing. Stops and all targets are
// determined separately from structure and completed historical analogs.
input bool     InpRangeMode    = true;       // Range mode: box-band entry for an ALLOWED Choppy 2/3 (default ON)

//  The three rows used to be three sealed rooms: every reading came from
//  its own bars and no row ever saw another.  These two switches open a
//  door - M5 may take its regime label from a slower row, and M5 may be
//  held to the higher row's direction before it places.  Both default to
//  the SAFE side of their own trade-off:
//     InpM5RegimeFrom     - M15 (M5 sampling can bias the label)
//     InpM5RequireHigher  - OFF (a direction veto costs 15-30 min, which
//                                is longer than an M5 reading lives, so
//                                it would kill the trades it allows)
input ENUM_M5_REGIME InpM5RegimeFrom    = M5_REGIME_M15; // M5 regime label: M5's own / borrow M15 / borrow M30
input bool           InpM5RequireHigher = false;         // M5 must match M15's direction to place (false = untied)

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
//  The regime window used to be ONE number - 256 bars - handed to all
//  three rows alike.  Counted in bars that is 21 hours of history on M5,
//  64 on M15 and 128 on M30: the row with the noisiest data got the least
//  evidence to work with.  It is now expressed as a SPAN, and each row's
//  bar count falls out of it, so all three judge the regime over the same
//  stretch of market.  M30 lands on 256, exactly where it always was.
#define HURST_SPAN_HOURS 128.0                                          // hours of history behind a regime label
#define HURST_WINDOW_M5  ((int)MathRound(HURST_SPAN_HOURS * 60.0 /  5.0)) // 1536 bars
#define HURST_WINDOW_M15 ((int)MathRound(HURST_SPAN_HOURS * 60.0 / 15.0)) //  512 bars
#define HURST_WINDOW_M30 ((int)MathRound(HURST_SPAN_HOURS * 60.0 / 30.0)) //  256 bars
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

// ATR remains only in the existing signal engine's noise deadbands.
// Entry, stop and targets below never use ATR or fixed ATR multiples.
#define ATR_PERIOD      14
// Closed-bar structure windows and forward observation horizons, per lane.
// These initial profiles are policy choices, not tested profit guarantees.
#define STRUCTURE_M5       36
#define STRUCTURE_M15      48
#define STRUCTURE_M30      72
#define OBS_HORIZON_M5      4
#define OBS_HORIZON_M15     6
#define OBS_HORIZON_M30     8
#define OBS_HISTORY_BARS 12000
#define OBS_MIN_CASES      30
// Empirical favorable-excursion quantiles: all three come from the
// lane's own completed, conservatively replayed historical analogs.
#define OBS_Q1 0.50
#define OBS_Q2 0.70
#define OBS_Q3 0.85
//  ---- THE REGIME PROFILE (baked in: the tested boundaries) -----------
//  Same reasoning as the block above, and for once the numbers are not
//  even a calibration: H is a property of the series, not of the symbol.
//  H > 0.5 means moves remember each other, H < 0.5 means they undo each
//  other, and 0.55 / 0.45 is the band the literature uses either side of
//  the 0.5 coin-flip before it will call a regime at all (SIGNAL_LOGIC.md
//  section 4).  Nothing about gold, or about M5, moves those numbers -
//  only a different estimator would - so they are not a dial.  The window
//  the estimate is taken over is now a SPAN (HURST_SPAN_HOURS in THE
//  ENGINE PROFILE above) rather than one bar count, so every row gets the
//  same stretch of history instead of M5 getting a sixth of M30's.  Widen
//  the band here and the panel goes quieter; narrow it and it trades more
//  - which is exactly why it is not a user input.
#define HURST_TREND     0.55      // H above this = persistent: Steady
#define HURST_REVERT    0.45      // H below this = anti-persistent: Choppy (box-priced limits)

// Range mode selects an entry band only; stops and targets are still
// derived from confirmed structure and observed forward price behavior.
#define RANGE_BARS       20
#define RANGE_ER_MAX     0.40
#define RANGE_VALID_BARS 8

#define VALID_BARS      3         // trend reading's leash in bars (research/HORIZON.md)
#define RISK_SCORE3_X   2.0       // score 3 risks this multiple of the score-2 percentage
#define BAL_PER_001     1000.0    // risk-off mode: balance per 0.01 lot
#define SCORE3_FACTOR   1.5       // risk-off mode: lot multiplier at score 3
#define HEAD_H      34     // height of a ONE-LINE header band (notice + 2nd Panel)
#define STATUS_LINE_C 71   // widest Main Panel mode-status line, in characters
#define PLAN_W_MIN  406    // panel width with no plan showing
#define PLAN_LINES  4      // lines for a full plan or indicative HOLD; other HOLDs use 1
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
   int            hWindow;    // Hurst window in bars (this row's own)
   double         hTrend;     // Hurst persistent threshold
   double         hRevert;    // Hurst anti-persistent threshold
   //  The regime label this row actually acts on: 0 Mixed, 1 Steady,
   //  2 Choppy.  It is stored rather than recomputed so the box decision,
   //  the Choppy veto, the diary and the panel all
   //  read the same number even when M5 is using M15's label.
   int            regime;     // effective label, -1 until first evaluated
   int            regimeSrc;  // -1 own, otherwise the row it came from
   // ---- the entry style and the reason, per row -----------------------
   int            mode;       // 0 plain limit/market entry, 2 the box prices the limit
   bool           choppyBlocked;// score direction exists, but InpAllowChoppyTrade=false
                                // on a Choppy row forbids a NEW entry (open trades stay managed)
   bool           mixedBlocked; // ...and the same for InpAllowMixedTrade=false on a Mixed row
   string         blockReason;// why this row is not trading ("" = quiet or no reason)
   double         rngTop;     // range box: upper band (valid while mode == 2)
   double         rngBot;     // range box: lower band (valid while mode == 2)
   double         lastClose;  // last closed-bar price (pending box-entry invalidation)
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
ulong    g_lastSafetyCancelMs[TF_COUNT]; // per-lane rejected safety-cancel retries
ulong    g_lastResidualCancelMs[TF_COUNT]; // partial-fill remainder cancellation
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
   //  Each row now carries its own window, so the pull has to cover the
   //  longest of them - one pull size is shared by all three timeframes.
   //  MathMax keeps this honest if the three constants are ever edited so
   //  that M5 is no longer the largest.
   int hneed = (int)MathMax(HURST_WINDOW_M5,
                            MathMax(HURST_WINDOW_M15, HURST_WINDOW_M30));
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
                  int l1, int l2, int hWindow, double hTrend, double hRevert)
{
   g_rows[i].tf      = tf;
   g_rows[i].tag     = tag;
   g_rows[i].style   = style;
   g_rows[i].l1      = l1;
   g_rows[i].l2      = l2;
   g_rows[i].hWindow = hWindow;
   g_rows[i].hTrend  = hTrend;
   g_rows[i].hRevert = hRevert;
   g_rows[i].score      = 0;
   g_rows[i].direction  = 0;
   g_rows[i].trendDir   = 0;
   g_rows[i].hurst      = 0.5;
   g_rows[i].er         = 0.0;
   g_rows[i].regime     = -1;      // nothing measured yet
   g_rows[i].regimeSrc  = -1;      // and so nothing borrowed yet
   g_rows[i].mode       = 0;
   g_rows[i].choppyBlocked = false;
   g_rows[i].mixedBlocked  = false;
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
   ConfigureRow(0, PERIOD_M5,  "M5",  "Scalp",      TREND_L1, TREND_L2, HURST_WINDOW_M5,
                HURST_TREND,    HURST_REVERT);
   ConfigureRow(1, PERIOD_M15, "M15", "Short-term", TREND_L1, TREND_L2, HURST_WINDOW_M15,
                HURST_TREND,    HURST_REVERT);
   ConfigureRow(2, PERIOD_M30, "M30", "Intraday",   TREND_L1, TREND_L2, HURST_WINDOW_M30,
                HURST_TREND,    HURST_REVERT);

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
   PrintFormat("SimpleEA: standard engine - Precision Trend %d/%d, "
               "E/R %d with dead-market gate %.2f (all three timeframes).",
               TREND_L1, TREND_L2, ER_PERIOD, ER_DEAD);
   //  State the calibration the reads came from, including the two things
   //  that used to be invisible: that the regime window is now a span
   //  rather than one bar count, and whose label M5 is actually acting on.
   PrintFormat("SimpleEA: regime window %.0f h = %d bars M5 / %d M15 / %d M30; "
               "M5 regime label from %s; M5 higher-TF direction gate %s.",
               HURST_SPAN_HOURS, g_rows[0].hWindow, g_rows[1].hWindow, g_rows[2].hWindow,
               (InpM5RegimeFrom == M5_REGIME_OWN) ? "M5 (own)"
                  : ((InpM5RegimeFrom == M5_REGIME_M30) ? "M30" : "M15"),
               InpM5RequireHigher ? "On" : "Off");
   //  Say plainly which rows may trade and which regimes may be traded,
   //  so a quiet chart is never mistaken for a broken one.
   PrintFormat("SimpleEA: autotrading per timeframe - M5 %s / M15 %s / M30 %s; "
               "regime permission - Choppy %s, Mixed %s.",
               InpAutoTradeM5 ? "On" : "Off",
               InpAutoTradeM15 ? "On" : "Off",
               InpAutoTradeM30 ? "On" : "Off",
               InpAllowChoppyTrade ? "allowed" : "vetoed",
               InpAllowMixedTrade  ? "allowed" : "vetoed");

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
      SyncAutoState();
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
   // Protect already-open positions before a new-bar replay can run.
   if(ChartSupported() && g_panelOK) ManageAutoTick();
   CheckNewBars();
   CheckAutoTimerTransition();
   CheckDiaryDayTransition();
}

//+------------------------------------------------------------------+
void OnTimer()
{
   if(ChartSupported() && g_panelOK) ManageAutoTick();
   CheckNewBars();
   CheckAutoTimerTransition();
   CheckDiaryDayTransition();
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
   //  The guard used to be "i + 1 < window", which let i == window - 1
   //  through.  That makes start == 0, and the innermost read
   //  p0 = close[start - 1] then reaches close[-1].  With the shipped
   //  numbers (i = last bar of a 700+ pull, window = 256) start is far
   //  from 0 so it never fired, but raising HURST_* or shrinking the
   //  pull turns this into an out-of-bounds read.  Requiring i >= window
   //  keeps start >= 1, so the smallest index ever touched is 0.
   if(i < window || window < 32) return(0.5);

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

   //  vol[0] is the still-forming bar, vol[1] is the bar under test, so
   //  the baseline starts at vol[2].  The bar being judged used to sit
   //  INSIDE its own average (the loop began at k = 1), which let a thin
   //  bar drag down the very number it was compared against and quietly
   //  pass the gate.  Excluding it is what makes the confirmation a test
   //  rather than a tautology.
   long lastVol = vol[1]; // Most recently finished closed bar
   long sumVol  = 0;
   int  valid   = 0;
   for(int k = 2; k <= period + 1; k++)
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
//  game may take its entry from the box, but it may only trade in a
//  direction the score actually supports.  Before this gate existed a Choppy row
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
//  THE TWO NEW GATES
//==================================================================
//  Both answer the same question the Choppy veto always did - "may a NEW
//  order leave the terminal for this row" - and both deliberately say
//  nothing about what already exists.  An open trade's fixed SL and
//  TP1/TP2/TP3 exits never consult either one.
//+------------------------------------------------------------------+
//  The per-timeframe master switch: is this row in the game at all?
bool AutoTradingAllowed(int i)
{
   if(i == 0) return(InpAutoTradeM5);
   if(i == 1) return(InpAutoTradeM15);
   if(i == 2) return(InpAutoTradeM30);
   return(false);
}

//+------------------------------------------------------------------+
//  The regime permission: Choppy veto, Mixed veto, or neither.
//  Kept as one function so a new entry has a single place to ask, and so
//  the panel, the plan, the placer and the pending manager cannot drift
//  apart about which regimes are tradeable this session.
bool RegimeBlocksEntry(int i)
{
   return(g_rows[i].choppyBlocked || g_rows[i].mixedBlocked);
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
         g_rows[r].mixedBlocked  = false;
         g_rows[r].blockReason  = "";
         g_rows[r].rngTop       = 0.0;
         g_rows[r].rngBot       = 0.0;
         g_rows[r].lastClose    = 0.0;
         g_rows[r].lastBar      = 0;
         g_rows[r].sigBirth     = 0;
         g_rows[r].regime       = -1;
         g_rows[r].regimeSrc    = -1;
      }
      return;
   }

   //  SLOWEST FIRST.  M5 may now read its regime label off M15 or M30,
   //  so those have to be measured before M5 asks.  Descending order
   //  (M30, M15, M5) guarantees any row can borrow from a slower one and
   //  still see a number computed on this very pass - not last bar's.
   for(int r = TF_COUNT - 1; r >= 0; r--)
      EvaluateRow(r);
}

//+------------------------------------------------------------------+
void EvaluateRow(int idx)
{
   double c[], h[], l[];

   //  Nothing may leak from the previous bar - including the label.
   g_rows[idx].regime    = -1;
   g_rows[idx].regimeSrc = -1;

   int want = BarsNeeded();   // raised automatically by the periods / windows above
   if(!LoadClosed(_Symbol, g_rows[idx].tf, want, c, h, l))
   {
      //  The long regime window made the pull much larger.  A broker with
      //  shallow history must not lose the whole row over it, so fall
      //  back to the shorter pull: the signal still works, and a Hurst
      //  window that cannot be filled simply returns its neutral 0.5
      //  (Mixed) instead of killing the row.
      if(!LoadClosed(_Symbol, g_rows[idx].tf, BARS_BASE, c, h, l))
      {
         g_rows[idx].ok           = false;
         g_rows[idx].score        = 0;
         g_rows[idx].direction    = 0;
         g_rows[idx].trendDir     = 0;
         g_rows[idx].mode         = 0;
         g_rows[idx].choppyBlocked = false;
         g_rows[idx].mixedBlocked  = false;
         g_rows[idx].blockReason  = "";
         g_rows[idx].rngTop       = 0.0;
         g_rows[idx].rngBot       = 0.0;
         g_rows[idx].lastClose    = 0.0;
         g_rows[idx].lastBar      = 0;
         g_rows[idx].sigBirth     = 0;
         return;
      }
   }

   int n    = ArraySize(c);
   int last = n - 1;                               // most recently CLOSED bar

   //  The idea's leash clock (the Valid cell): what the row said before
   int prevDir  = g_rows[idx].direction;
   int prevMode = g_rows[idx].mode;

   // ---- fresh state: nothing may leak from the previous bar --------
   g_rows[idx].mode          = 0;
   g_rows[idx].choppyBlocked = false;
   g_rows[idx].mixedBlocked  = false;
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

   // The regime is a label, permission and optional range-entry style;
   // it does not erase the directional score. It does not set ATR exits.
   //  This row's OWN Hurst, over its own (now time-equalised) window.
   //  It is always measured - the panel shows it, and it is the fallback
   //  whenever there is nothing to borrow from - but it is only the label
   //  the row ACTS on when no source is being used.
   double H    = HurstExponent(c, last, g_rows[idx].hWindow);
   double ER   = EfficiencyRatio(c, last, ER_PERIOD);

   //  Whose label decides the regime?  Borrowing needs a source that
   //  measured successfully on THIS pass: EvaluateAll() runs slowest
   //  first, so M15 and M30 are finished before M5 asks.  If the source
   //  has no data, or has not run yet, M5 quietly keeps its own label
   //  rather than trading on a stale one.
   int regimeSrc = -1;
   if(idx == 0 && InpM5RegimeFrom != M5_REGIME_OWN)
   {
      int src = (InpM5RegimeFrom == M5_REGIME_M30) ? 2 : 1;
      if(g_rows[src].ok && g_rows[src].regime >= 0)
         regimeSrc = src;
   }

   int game = 0;                       // 0 mixed | 1 steady | 2 choppy
   if(regimeSrc >= 0)
      game = g_rows[regimeSrc].regime;
   else
   {
      if(H > g_rows[idx].hTrend)       game = 1;
      else if(H < g_rows[idx].hRevert) game = 2;
   }
   //  One stored label, so the box decision, the Choppy veto, the
   //  diary and the panel can never disagree about
   //  which regime this row is in.
   g_rows[idx].regime    = game;
   g_rows[idx].regimeSrc = regimeSrc;

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

   //  The Mixed permission, the same shape as the Choppy one: it vetoes
   //  NEW entries only, never closes or abandons anything already open,
   //  and leaves the would-be direction on the panel (greyed) so the row
   //  still says what it would do if the switch were on.
   bool mixedBlocked = (!InpAllowMixedTrade && game == 0 && dir != 0);
   if(mixedBlocked)
      g_rows[idx].blockReason = "mixed " + emDash + " Mixed Trade is Off";

   // ---- the entry style: an allowed Choppy 2/3 may use the box ----
   // A usable Choppy box changes the pending entry band only; otherwise
   // a confirmed swing supplies the pending entry. Stops/targets are
   // independently checked in the structure plan.
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
      double half   = 0.5 * (top - bot);          // range-style spread clearance

      bool usable = (spread >= 0.0 && n >= nb && top > bot &&
                     ER < RANGE_ER_MAX && bid <= top && bid >= bot &&
                     half > spread); // entry style only; final cost/risk gates are in the plan
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
   g_rows[idx].mixedBlocked  = mixedBlocked;
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
//  TRADE PLAN: new entries only, separate from open-position management
//==================================================================
// Confirmed swings supply entry/invalidation and opposing barriers.
// Completed, non-overlapping bar analogs supply three empirical
// favorable-excursion quantiles. Insufficient history, costs, risk or
// broker restrictions produce HOLD without changing the signal.
// M5/M15/M30 use separate lookbacks and observation horizons.
//+------------------------------------------------------------------+
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
   double   entryPrice;           // advised entry price (ask/bid or structural limit)
   double   slPrice;
   double   tp1Price;
   double   tp2Price;
   double   tp3Price;
   double   lot;                  // normalized lot size
   int      slPts;                // stop distance in points
   int      tpPts;                // target (TP3) distance in points
   int      tp1Pts;               // independently observed/structure-capped targets
   int      tp2Pts;
   int      tp3Pts;
   datetime validUntil;           // expiration timestamp
   // ---- ready to draw: label + value per cell -------------------------
   string   lbl[PLAN_LINES][3];
   string   val[PLAN_LINES][3];
   color    clr[PLAN_LINES][3];
};

SPlanRow g_plans[TF_COUNT];

//+------------------------------------------------------------------+
//  Legacy migration ONLY: pre-upgrade positions used this ladder on
//  restart. New orders persist their independent absolute TP1/TP2 prices.
//+------------------------------------------------------------------+
void ComputeLegacyTPLevels(int tp3, int &tp1, int &tp2)
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
int VolumeStepDigits(double step)
{
   int digits = 0;
   double scaled = step;
   while(digits < 8 && MathAbs(scaled - MathRound(scaled)) > 1e-8)
   {
      scaled *= 10.0;
      digits++;
   }
   return(digits);
}

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
   if(n > mx) n = MathFloor(mx / step + 1e-8) * step;
   return(NormalizeDouble(n, VolumeStepDigits(step)));
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
   g_plans[i].slPrice    = 0.0;
   g_plans[i].tp1Price   = 0.0;
   g_plans[i].tp2Price   = 0.0;
   g_plans[i].tp3Price   = 0.0;
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

//==================================================================
//  STRUCTURE AND COMPLETED HISTORICAL BAR OBSERVATIONS
//==================================================================
// The replay is a conservative bar-level ANALOG, not a backtest of fills
// or a forecast. It reconstructs the closed-bar score/regime and entry
// style approximately; a pending touch is not proof of execution. Bid
// bars have no intrabar ordering or intrabar Ask/spread history, so a
// stop in a bar wins any ambiguity, and a pending fill bar contributes
// no favorable extreme. Samples end at the fixed horizon even if an
// actual trade would have closed earlier. No unfinished window is used.

struct SStructureGeometry
{
   double entry;
   double stop;
   double cap[3];             // distance to the first three opposing swings
};

struct SObservationCache
{
   datetime bar;
   int dir;
   int score;
   int regime;
   int regimeSrc;
   bool market;
   bool range;
   int eligible;              // non-overlapping matching, valid setups
   int filled;                // market probes or one-bar pending touches
   double q1;
   double q2;
   double q3;
};

SObservationCache g_observations[TF_COUNT];

int StructureWindow(int i)
{
   return(i == 0 ? STRUCTURE_M5 : (i == 1 ? STRUCTURE_M15 : STRUCTURE_M30));
}

int ObservationHorizon(int i)
{
   return(i == 0 ? OBS_HORIZON_M5 : (i == 1 ? OBS_HORIZON_M15 : OBS_HORIZON_M30));
}

double PriceDown(double price, double tick)
{
   if(tick <= 0.0) return(0.0);
   return(NormPrice(MathFloor(price / tick + 1e-9) * tick));
}

double PriceUp(double price, double tick)
{
   if(tick <= 0.0) return(0.0);
   return(NormPrice(MathCeil(price / tick - 1e-9) * tick));
}

bool ConfirmedSwingLow(const MqlRates &bars[], int k, int last)
{
   return(k > 0 && k < last && bars[k].low < bars[k - 1].low &&
          bars[k].low <= bars[k + 1].low);
}

bool ConfirmedSwingHigh(const MqlRates &bars[], int k, int last)
{
   return(k > 0 && k < last && bars[k].high > bars[k - 1].high &&
          bars[k].high >= bars[k + 1].high);
}

void BoxAt(const MqlRates &bars[], int last, double &top, double &bot)
{
   top = -DBL_MAX;
   bot = DBL_MAX;
   int first = (int)MathMax(0, last - RANGE_BARS + 1);
   for(int k = first; k <= last; k++)
   {
      top = MathMax(top, bars[k].high);
      bot = MathMin(bot, bars[k].low);
   }
}

// Insert a positive distance in the nearest-three ordered set. Prices at
// the same tick are one level, not three independently supported targets.
void InsertStructureCap(double distance, double tick, double &caps[])
{
   if(distance <= 0.0) return;
   for(int j = 0; j < 3; j++)
      if(caps[j] > 0.0 && MathAbs(caps[j] - distance) < 0.5 * tick) return;
   for(int j = 0; j < 3; j++)
   {
      if(caps[j] <= 0.0 || distance < caps[j])
      {
         for(int m = 2; m > j; m--) caps[m] = caps[m - 1];
         caps[j] = distance;
         return;
      }
   }
}

// All pivots use k+1 <= last, so the right-hand confirmation bar is
// closed at the decision. Entry, invalidation and opposing barriers are
// therefore determined without looking into the observation window.
bool StructureGeometry(const MqlRates &bars[], int last, int i, int dir,
                       bool market, bool range, double bid, double ask,
                       double point, double tick, double minStop,
                       SStructureGeometry &out)
{
   out.entry = 0.0;
   out.stop = 0.0;
   for(int j = 0; j < 3; j++) out.cap[j] = 0.0;
   if(last < 2 || dir == 0 || point <= 0.0 || tick <= 0.0 ||
      bid <= 0.0 || ask < bid) return(false);

   int first = (int)MathMax(1, last - StructureWindow(i) + 1);
   double offset = MathMax(tick, minStop);
   if(market)
      out.entry = dir > 0 ? ask : bid;
   else if(range)
   {
      double top, bot;
      BoxAt(bars, last, top, bot);
      out.entry = (dir > 0) ? PriceDown(bot, tick) : PriceUp(top, tick);
   }
   else
   {
      // Nearest confirmed support/resistance on the valid limit side.
      for(int k = first; k < last; k++)
      {
         if(dir > 0 && ConfirmedSwingLow(bars, k, last))
         {
            double p = PriceDown(bars[k].low, tick);
            if(p > 0.0 && p <= ask - offset + 1e-9 * tick &&
               (out.entry <= 0.0 || p > out.entry)) out.entry = p;
         }
         if(dir < 0 && ConfirmedSwingHigh(bars, k, last))
         {
            double p = PriceUp(bars[k].high, tick);
            if(p >= bid + offset - 1e-9 * tick &&
               (out.entry <= 0.0 || p < out.entry)) out.entry = p;
         }
      }
   }
   if(out.entry <= 0.0) return(false);
   if(!market && ((dir > 0 && out.entry > ask - offset + 1e-9 * tick) ||
                  (dir < 0 && out.entry < bid + offset - 1e-9 * tick)))
      return(false); // never move a structure entry to an invented broker price

   // A limit's own entry pivot cannot also be its invalidation pivot.
   // Search a separate, confirmed level beyond entry and add one live
   // spread (at least one tick) outside it for quote-side protection.
   double support = 0.0;
   for(int k = first; k < last; k++)
   {
      if(dir > 0 && ConfirmedSwingLow(bars, k, last) &&
         bars[k].low < out.entry - 0.5 * tick &&
         (support <= 0.0 || bars[k].low > support)) support = bars[k].low;
      if(dir < 0 && ConfirmedSwingHigh(bars, k, last) &&
         bars[k].high > out.entry + 0.5 * tick &&
         (support <= 0.0 || bars[k].high < support)) support = bars[k].high;
   }
   if(support <= 0.0) return(false);
   double buffer = MathMax(tick, ask - bid);
   out.stop = (dir > 0) ? PriceDown(support - buffer, tick)
                        : PriceUp(support + buffer, tick);
   double stopBase = market ? (dir > 0 ? bid : ask) : out.entry;
   if(out.stop <= 0.0 || (double)dir * (stopBase - out.stop) < minStop - 1e-9 * tick ||
      (double)dir * (out.entry - out.stop) < tick - 1e-9 * tick)
      return(false);

   double caps[3] = {0.0, 0.0, 0.0};
   for(int k = first; k < last; k++)
   {
      if(dir > 0 && ConfirmedSwingHigh(bars, k, last))
      {
         double p = PriceDown(bars[k].high, tick);
         InsertStructureCap(p - out.entry, tick, caps);
      }
      if(dir < 0 && ConfirmedSwingLow(bars, k, last))
      {
         double p = PriceUp(bars[k].low, tick);
         InsertStructureCap(out.entry - p, tick, caps);
      }
   }
   for(int j = 0; j < 3; j++) out.cap[j] = caps[j];
   return(true);
}

// Same zero-crossing procedure as AdaptiveCyclePeriod(), but explicitly
// ending at a historical closed bar. The high-pass filter is causal.
int ObservationCycleAt(const double &hp[], int last)
{
   if(last + 1 < 40) return(TREND_L2);
   int first = (int)MathMax(2, last + 1 - 120);
   int cross[];
   int n = 0;
   for(int k = first + 1; k <= last; k++)
   {
      if((hp[k - 1] <= 0.0 && hp[k] > 0.0) ||
         (hp[k - 1] >= 0.0 && hp[k] < 0.0))
      {
         ArrayResize(cross, n + 1);
         cross[n++] = k;
      }
   }
   if(n < 3) return(TREND_L2);
   int diffs[];
   ArrayResize(diffs, n - 1);
   for(int j = 0; j < n - 1; j++) diffs[j] = cross[j + 1] - cross[j];
   ArraySort(diffs);
   return((int)MathMax(14, MathMin(36, diffs[(n - 1) / 2] * 2)));
}

// Precompute the same adaptive trend/ROC for past bars. The long filter is
// warmed up before sampling; its initial state can differ slightly from
// the EA's rolling live pull, hence these are approximate reconstructions.
void ObservationTrends(const double &close[], double &trend[], double &roc[])
{
   int n = ArraySize(close);
   ArrayResize(trend, n);
   ArrayResize(roc, n);
   ArrayInitialize(trend, 0.0);
   ArrayInitialize(roc, 0.0);
   double hp40[];
   HighPass3(close, 40, hp40);
   int cycles[];
   ArrayResize(cycles, n);
   for(int k = 0; k < n; k++) cycles[k] = ObservationCycleAt(hp40, k);
   for(int cycle = 14; cycle <= 36; cycle++)
   {
      int l1 = (int)MathRound((double)cycle * 6.25);
      l1 = (int)MathMax(90, MathMin(225, l1));
      double hp1[], hp2[];
      HighPass3(close, l1, hp1);
      HighPass3(close, cycle, hp2);
      for(int k = 1; k < n; k++)
      {
         if(cycles[k] != cycle) continue;
         trend[k] = hp1[k] - hp2[k];
         double prior = hp1[k - 1] - hp2[k - 1];
         roc[k] = ((double)cycle / 6.28) * (trend[k] - prior);
      }
   }
}

// ATR is reproduced here solely to reconstruct the unchanged signal's
// vote deadbands; it is never used to set an entry, stop or target.
double ObservationSignalATR(const MqlRates &bars[], int last)
{
   if(last < ATR_PERIOD) return(0.0);
   double sum = 0.0;
   for(int k = last - ATR_PERIOD + 1; k <= last; k++)
   {
      double tr = bars[k].high - bars[k].low;
      tr = MathMax(tr, MathAbs(bars[k].high - bars[k - 1].close));
      tr = MathMax(tr, MathAbs(bars[k].low - bars[k - 1].close));
      sum += tr;
   }
   return(sum / (double)ATR_PERIOD);
}

bool ObservationVolumeOK(const MqlRates &bars[], int last)
{
   if(last < 20) return(true);
   long sum = 0;
   int valid = 0;
   for(int k = last - 20; k < last; k++)
      if(bars[k].tick_volume > 0) { sum += bars[k].tick_volume; valid++; }
   if(valid < 10 || sum == 0) return(true);
   return((double)bars[last].tick_volume >= VOL_RATIO_MIN * (double)sum / (double)valid);
}

// Precompute causal sums of the same log returns used by HurstExponent.
// Reusing them avoids millions of repeated logarithms while an existing
// trade is waiting for its next tick to be managed.
void ObservationReturnPrefix(const double &close[], double &prefix[])
{
   int n = ArraySize(close);
   ArrayResize(prefix, n);
   if(n == 0) return;
   prefix[0] = 0.0;
   for(int k = 1; k < n; k++)
   {
      double r = (close[k] > 0.0 && close[k - 1] > 0.0)
                 ? MathLog(close[k] / close[k - 1]) : 0.0;
      prefix[k] = prefix[k - 1] + r;
   }
}

double ObservationHurst(const double &prefix[], int last, int window)
{
   if(last < window || window < 32) return(0.5);
   int scales[5] = {1, 2, 4, 8, 16};
   double lx[5], ly[5];
   int m = 0, start = last - window + 1;
   for(int s = 0; s < 5; s++)
   {
      int scale = scales[s], count = window / scale;
      if(count < 4) continue;
      double mean = 0.0;
      for(int b = 0; b < count; b++)
      {
         int first = start + b * scale;
         mean += prefix[first + scale - 1] - prefix[first - 1];
      }
      mean /= (double)count;
      double variance = 0.0;
      for(int b = 0; b < count; b++)
      {
         int first = start + b * scale;
         double sum = prefix[first + scale - 1] - prefix[first - 1];
         variance += (sum - mean) * (sum - mean);
      }
      double sd = MathSqrt(variance / (double)(count - 1));
      if(sd <= 0.0) continue;
      lx[m] = MathLog((double)scale);
      ly[m] = MathLog(sd);
      m++;
   }
   if(m < 3) return(0.5);
   double mx = 0.0, my = 0.0;
   for(int j = 0; j < m; j++) { mx += lx[j]; my += ly[j]; }
   mx /= (double)m; my /= (double)m;
   double sxy = 0.0, sxx = 0.0;
   for(int j = 0; j < m; j++)
   {
      sxy += (lx[j] - mx) * (ly[j] - my);
      sxx += (lx[j] - mx) * (lx[j] - mx);
   }
   return(sxx > 0.0 ? sxy / sxx : 0.5);
}

// Index the last slower bar that had finished by the historical decision.
int ObservationSourceIndex(const MqlRates &source[], datetime decision, int seconds)
{
   int lo = 0, hi = ArraySize(source) - 1, found = -1;
   while(lo <= hi)
   {
      int mid = (lo + hi) / 2;
      if(source[mid].time + seconds <= decision) { found = mid; lo = mid + 1; }
      else hi = mid - 1;
   }
   return(found);
}

double ObservationSpread(const MqlRates &bar, double point, double fallback)
{
   // A zero bar spread may be missing data. Use the current spread as a
   // conservative proxy, not an assertion about the historical tick spread.
   return(bar.spread > 0 ? (double)bar.spread * point : fallback);
}

// Return max executable-side favorable travel before the first stop over a
// COMPLETE horizon. Equal-bar stop/target order is unknown: count the stop
// first. For a hypothetical limit, a touch only qualifies the sample; its
// fill bar's favorable extreme is ignored as it may precede the touch.
bool ReplayObservation(const MqlRates &bars[], int last, int horizon, int dir,
                       bool market, const SStructureGeometry &g,
                       double point, double spreadFallback, double &mfeR)
{
   mfeR = 0.0;
   if(last + horizon >= ArraySize(bars)) return(false);
   double risk = (double)dir * (g.entry - g.stop);
   if(risk <= 0.0) return(false);
   int first = last + 1;
   if(!market)
   {
      double fillSpread = ObservationSpread(bars[first], point, spreadFallback);
      bool touched = (dir > 0) ? (bars[first].low + fillSpread <= g.entry)
                               : (bars[first].high >= g.entry);
      if(!touched) return(false); // count in eligible, not in filled
   }
   double best = 0.0;
   for(int k = first; k <= last + horizon; k++)
   {
      double spread = ObservationSpread(bars[k], point, spreadFallback);
      bool stopped = (dir > 0) ? (bars[k].low <= g.stop)
                               : (bars[k].high + spread >= g.stop);
      if(stopped) break;       // stop first when both extremes share a bar
      if(!market && k == first) continue; // high/low may precede the touch
      double favorable = (dir > 0) ? (bars[k].high - g.entry)
                                   : (g.entry - (bars[k].low + spread));
      if(favorable > best) best = favorable;
   }
   mfeR = MathMax(0.0, best / risk);
   return(true);
}

void ObserveLane(int i, int dir, int score, bool market, bool range,
                 double point, double tick, double minStop, double currentSpread)
{
   SObservationCache cached = g_observations[i];
   if(cached.bar == g_rows[i].lastBar && cached.bar > 0 && cached.dir == dir &&
      cached.score == score && cached.regime == g_rows[i].regime &&
      cached.regimeSrc == g_rows[i].regimeSrc && cached.market == market &&
      cached.range == range) return;

   SObservationCache obs;
   ZeroMemory(obs);
   obs.dir = dir;
   obs.score = score;
   obs.regime = g_rows[i].regime;
   obs.regimeSrc = g_rows[i].regimeSrc;
   obs.market = market;
   obs.range = range;
   MqlRates bars[];
   ArraySetAsSeries(bars, false);
   int n = CopyRates(_Symbol, g_rows[i].tf, 1, OBS_HISTORY_BARS, bars);
   int warmup = 4 * 225;
   if(g_rows[i].regimeSrc < 0) warmup = (int)MathMax(warmup, g_rows[i].hWindow);
   int horizon = ObservationHorizon(i);
   if(n <= warmup + horizon + OBS_MIN_CASES)
   {
      // A partial download is not cached; a subsequent refresh may load it.
      g_observations[i] = obs;
      return;
   }

   double c[], h[], l[];
   ArrayResize(c, n); ArrayResize(h, n); ArrayResize(l, n);
   for(int k = 0; k < n; k++)
   {
      c[k] = bars[k].close; h[k] = bars[k].high; l[k] = bars[k].low;
   }
   double trend[], roc[], ownPrefix[];
   ObservationTrends(c, trend, roc);
   ObservationReturnPrefix(c, ownPrefix);

   MqlRates source[];
   double sourceClose[], sourcePrefix[];
   int src = g_rows[i].regimeSrc;
   if(src >= 0)
   {
      ArraySetAsSeries(source, false);
      int ns = CopyRates(_Symbol, g_rows[src].tf, 1, OBS_HISTORY_BARS, source);
      if(ns <= g_rows[src].hWindow + 1)
      {
         g_observations[i] = obs;
         return;
      }
      ArrayResize(sourceClose, ns);
      for(int k = 0; k < ns; k++) sourceClose[k] = source[k].close;
      ObservationReturnPrefix(sourceClose, sourcePrefix);
   }

   double samples[];
   int lastStart = n;
   for(int t = n - horizon - 1; t >= warmup; t--)
   {
      if(t + horizon >= lastStart) continue; // no overlapping replay windows
      double er = EfficiencyRatio(c, t, ER_PERIOD);
      if(er < ER_DEAD) continue;
      double signalAtr = ObservationSignalATR(bars, t);
      int v1 = trend[t] > 0.0 ? 1 : (trend[t] < 0.0 ? -1 : 0);
      double dead = ROC_DEAD_ATR * signalAtr;
      int v2 = roc[t] > dead ? 1 : (roc[t] < -dead ? -1 : 0);
      int v3 = StructureVote(c, h, l, t, STRUCT_PERIOD, signalAtr);
      int pastScore = v1 + v2 + v3;
      if(pastScore != score || !ScoreAllowsTrade(dir, pastScore)) continue;
      bool pastMarket = (MathAbs(pastScore) >= 3 && ObservationVolumeOK(bars, t));
      if(pastMarket != market) continue;

      double H;
      if(src >= 0)
      {
         int j = ObservationSourceIndex(source, bars[t + 1].time,
                                        (int)PeriodSeconds(g_rows[src].tf));
         if(j < g_rows[src].hWindow) continue;
         H = ObservationHurst(sourcePrefix, j, g_rows[src].hWindow);
      }
      else H = ObservationHurst(ownPrefix, t, g_rows[i].hWindow);
      int pastRegime = H > g_rows[i].hTrend ? 1 : (H < g_rows[i].hRevert ? 2 : 0);
      if(pastRegime != obs.regime) continue;

      double spread = ObservationSpread(bars[t + 1], point, currentSpread);
      double bid = bars[t + 1].open;
      double ask = bid + spread;
      double top, bot;
      BoxAt(bars, t, top, bot);
      bool pastRange = (!pastMarket && pastRegime == 2 && InpRangeMode &&
                        MathAbs(pastScore) < 3 && er < RANGE_ER_MAX &&
                        bid >= bot && bid <= top && 0.5 * (top - bot) > spread);
      if(pastRange != range) continue;
      SStructureGeometry geometry;
      if(!StructureGeometry(bars, t, i, dir, pastMarket, pastRange,
                            bid, ask, point, tick, minStop, geometry)) continue;
      obs.eligible++;
      double mfeR = 0.0;
      if(!ReplayObservation(bars, t, horizon, dir, pastMarket, geometry,
                            point, currentSpread, mfeR)) continue;
      lastStart = t; // filled/probed observations do not overlap
      int count = ArraySize(samples);
      ArrayResize(samples, count + 1);
      samples[count] = mfeR;
   }
   obs.filled = ArraySize(samples);
   if(obs.filled > 0)
   {
      ArraySort(samples);
      obs.q1 = samples[(int)MathFloor((obs.filled - 1) * OBS_Q1)];
      obs.q2 = samples[(int)MathFloor((obs.filled - 1) * OBS_Q2)];
      obs.q3 = samples[(int)MathFloor((obs.filled - 1) * OBS_Q3)];
   }
   obs.bar = g_rows[i].lastBar;
   g_observations[i] = obs;
}


//+------------------------------------------------------------------+
// Build a new-entry plan only. A HOLD here never changes the published
// direction or an already-open position's broker/EA exit levels.
//+------------------------------------------------------------------+
void HoldPlan(int i, string why)
{
   g_plans[i].state = 0;
   g_plans[i].kind = "HOLD";
   g_plans[i].note = why;
}

// Show only the prices actually available for a held signal. These cells
// are informational: state stays HOLD and no executable prices are stored.
// Swing-only targets are barriers, not historically validated TP forecasts.
void ShowHeldPlan(int i, string why, string basis, double entry, double stop,
                  double tp1, double tp2, double tp3, int filled, int eligible)
{
   HoldPlan(i, why);
   g_plans[i].lines = PLAN_LINES;
   int dg = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_plans[i].lbl[0][0] = "Entry:";
   g_plans[i].val[0][0] = entry > 0.0 ? DoubleToString(entry, dg) : "--";
   g_plans[i].lbl[0][1] = "Stop:";
   g_plans[i].val[0][1] = stop > 0.0 ? DoubleToString(stop, dg) : "--";
   g_plans[i].lbl[0][2] = "Data:";
   g_plans[i].val[0][2] = filled >= 0 ? StringFormat("%d/%d analogs", filled, eligible) : "--";
   g_plans[i].lbl[1][0] = "TP1~:";
   g_plans[i].val[1][0] = tp1 > 0.0 ? DoubleToString(tp1, dg) : "--";
   g_plans[i].lbl[1][1] = "TP2~:";
   g_plans[i].val[1][1] = tp2 > 0.0 ? DoubleToString(tp2, dg) : "--";
   g_plans[i].lbl[1][2] = "TP3~:";
   g_plans[i].val[1][2] = tp3 > 0.0 ? DoubleToString(tp3, dg) : "--";
   g_plans[i].lbl[2][0] = "Basis:";
   g_plans[i].val[2][0] = basis;
   g_plans[i].lbl[2][1] = "Action:";
   g_plans[i].val[2][1] = "NO ORDER";
   g_plans[i].lbl[3][0] = "Reason:";
   g_plans[i].val[3][0] = why;
   for(int l = 0; l < PLAN_LINES; l++)
      for(int c = 0; c < 3; c++) g_plans[i].clr[l][c] = clrSilver;
   g_plans[i].clr[2][1] = clrOrange; // NO ORDER
   g_plans[i].clr[3][0] = clrOrange; // HOLD reason
}

// Check the actual executable sides and broker distances rather than
// forcing an observed/structural target farther out to satisfy a minimum.
bool PlanPricesValid(int dir, bool market, double entry, double stop,
                     double tp1, double tp2, double tp3,
                     double bid, double ask, double point, double tick,
                     double minStop, double pv)
{
   if(dir == 0 || entry <= 0.0 || stop <= 0.0 || bid <= 0.0 || ask < bid ||
      point <= 0.0 || tick <= 0.0 || pv <= 0.0) return(false);
   double eps = 1e-7 * tick;
   if((double)dir * (entry - stop) < tick - eps ||
      (double)dir * (tp1 - entry) < tick - eps ||
      (double)dir * (tp2 - tp1) < tick - eps ||
      (double)dir * (tp3 - tp2) < tick - eps) return(false);
   double base = market ? (dir > 0 ? bid : ask) : entry;
   if((double)dir * (base - stop) < minStop - eps ||
      (double)dir * (tp3 - base) < minStop - eps) return(false);
   if(!market)
   {
      double offset = MathMax(tick, minStop);
      if(dir > 0 && entry > ask - offset + eps) return(false);
      if(dir < 0 && entry < bid + offset - eps) return(false);
   }
   // Conservative cost screen within this lane, not against another
   // timeframe. Distance already starts at the executable entry side;
   // requiring it to clear the spread too protects very small targets.
   // Actual broker commissions are not known in advance here; this is a
   // spread-only screen, not a claim that commissions are zero.
   if((double)dir * (tp1 - entry) <= (ask - bid) + eps)
      return(false);
   return(true);
}

void UpdatePlanRow(int i)
{
   ClearPlanRow(i);
   if(!g_rows[i].ok)
   {
      g_plans[i].state = 1;
      g_plans[i].kind = "waiting";
      g_plans[i].note = "signal history still loading";
      return;
   }
   if(PlanHasOpenPosition(i))
   {
      HoldPlan(i, "position open; existing exits retained (EA trading required)");
      return;
   }
   if(PlanHasUncertainOrder(i))
   {
      HoldPlan(i, "order response uncertain or pending; review broker state");
      return;
   }
   if(g_rows[i].direction == 0)
   {
      HoldPlan(i, g_rows[i].blockReason != "" ? g_rows[i].blockReason : "nothing to place");
      return;
   }
   // Compute visible prices even when a permission vetoes execution.
   // The plan stays HOLD; PlacePlanOrder requires state 2.
   string entryVeto = "";
   if(!AutoTradingAllowed(i)) entryVeto = "lane switched off";
   else if(RegimeBlocksEntry(i)) entryVeto = "regime blocks entry";
   // Netting combines positions by symbol and cannot isolate the three lanes.
   else if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      entryVeto = "hedging required";
   else if(!TrendMatchForTF(i)) entryVeto = "trend gate mismatch";
   else if(!AutoTimerAllowsPlacement()) entryVeto = "timer paused";

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double pv = PointValuePerLot();
   if(point <= 0.0 || tick <= 0.0 || bid <= 0.0 || ask < bid || pv <= 0.0)
   {
      HoldPlan(i, "price, tick size or point value unavailable");
      return;
   }
   if(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN) <= 0.0 ||
      SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX) <= 0.0 ||
      SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP) <= 0.0)
   {
      HoldPlan(i, "broker volume limits unavailable");
      return;
   }
   if((ENUM_SYMBOL_CHART_MODE)SymbolInfoInteger(_Symbol, SYMBOL_CHART_MODE) != SYMBOL_CHART_MODE_BID)
   {
      HoldPlan(i, "historical Bid bars unavailable for executable-side replay");
      return;
   }
   int dir = g_rows[i].direction;
   int score = g_rows[i].score;
   bool market = (MathAbs(score) >= 3 && IsVolumeConfirmed(g_rows[i].tf, 20));
   bool isRange = (g_rows[i].mode == 2 && !market);
   double minStop = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;

   MqlRates bars[];
   ArraySetAsSeries(bars, false);
   int n = CopyRates(_Symbol, g_rows[i].tf, 1, StructureWindow(i) + 2, bars);
   if(n < StructureWindow(i) + 2)
   {
      HoldPlan(i, "closed-bar structure still loading");
      return;
   }
   SStructureGeometry geo;
   if(!StructureGeometry(bars, n - 1, i, dir, market, isRange,
                         bid, ask, point, tick, minStop, geo))
   {
      ShowHeldPlan(i, "no structure", "unconfirmed", geo.entry, geo.stop,
                   0.0, 0.0, 0.0, -1, -1);
      return;
   }

   // These are real opposing swing barriers, not a replacement for the
   // data-derived TP plan. Display them only as non-tradable candidates
   // when the historical observations cannot support target selection.
   double swings[3];
   for(int j = 0; j < 3; j++)
   {
      swings[j] = 0.0;
      if(geo.cap[j] > 0.0)
         swings[j] = dir > 0 ? PriceDown(geo.entry + geo.cap[j], tick)
                             : PriceUp(geo.entry - geo.cap[j], tick);
   }

   ObserveLane(i, dir, score, market, isRange, point, tick, minStop, ask - bid);
   SObservationCache obs = g_observations[i];
   if(obs.filled < OBS_MIN_CASES)
   {
      ShowHeldPlan(i, StringFormat("need %d analogs", OBS_MIN_CASES), "swing-only", geo.entry, geo.stop,
                   swings[0], swings[1], swings[2], obs.filled, obs.eligible);
      return;
   }
   if(obs.q1 <= 0.0 || obs.q2 <= 0.0 || obs.q3 <= 0.0)
   {
      ShowHeldPlan(i, "weak follow-through", "swing-only", geo.entry, geo.stop,
                   swings[0], swings[1], swings[2], obs.filled, obs.eligible);
      return;
   }

   double riskDistance = (double)dir * (geo.entry - geo.stop);
   double distances[3];
   distances[0] = riskDistance * obs.q1;
   distances[1] = riskDistance * obs.q2;
   distances[2] = riskDistance * obs.q3;
   for(int j = 0; j < 3; j++)
      if(geo.cap[j] > 0.0) distances[j] = MathMin(distances[j], geo.cap[j]);
   double tp1 = dir > 0 ? PriceDown(geo.entry + distances[0], tick)
                        : PriceUp(geo.entry - distances[0], tick);
   double tp2 = dir > 0 ? PriceDown(geo.entry + distances[1], tick)
                        : PriceUp(geo.entry - distances[1], tick);
   double tp3 = dir > 0 ? PriceDown(geo.entry + distances[2], tick)
                        : PriceUp(geo.entry - distances[2], tick);
   if(!PlanPricesValid(dir, market, geo.entry, geo.stop, tp1, tp2, tp3,
                       bid, ask, point, tick, minStop, pv))
   {
      ShowHeldPlan(i, "cost/broker/order", "observed", geo.entry, geo.stop,
                   tp1, tp2, tp3, obs.filled, obs.eligible);
      return;
   }
   int slPts = (int)MathRound(riskDistance / point);
   int tp1Pts = (int)MathRound((double)dir * (tp1 - geo.entry) / point);
   int tp2Pts = (int)MathRound((double)dir * (tp2 - geo.entry) / point);
   int tp3Pts = (int)MathRound((double)dir * (tp3 - geo.entry) / point);
   if(slPts <= 0 || tp1Pts <= 0 || tp2Pts <= tp1Pts || tp3Pts <= tp2Pts)
   {
      ShowHeldPlan(i, "target grid", "observed", geo.entry, geo.stop,
                   tp1, tp2, tp3, obs.filled, obs.eligible);
      return;
   }

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance <= 0.0)
   {
      ShowHeldPlan(i, "no balance", "observed", geo.entry, geo.stop,
                   tp1, tp2, tp3, obs.filled, obs.eligible);
      return;
   }
   double perLotRisk = (double)slPts * pv; // excludes unknown commissions/fees
   double wantRisk = 0.0;
   double lots = SymbolMinLot();
   if(InpUseMinLot)
      lots = SymbolMinLot();
   else if(InpUseRisk)
   {
      double pct = InpRiskPct * (MathAbs(score) >= 3 ? RISK_SCORE3_X : 1.0);
      wantRisk = balance * pct / 100.0;
      lots = wantRisk / perLotRisk;
   }
   else
   {
      lots = balance / BAL_PER_001 * 0.01;
      if(MathAbs(score) >= 3) lots *= SCORE3_FACTOR;
   }
   double lot = NormalizeLots(lots);
   // A pending order cannot change volume via a price modification. Size
   // and risk its refreshed plan using the lot already at the broker.
   double pendingLot = market ? 0.0 : ExistingPendingVolume(i, dir);
   if(pendingLot > 0.0) lot = pendingLot;
   double riskMoney = lot * perLotRisk;
   if(!InpUseMinLot && InpUseRisk && (wantRisk <= 0.0 || riskMoney > wantRisk * 1.000001))
   {
      ShowHeldPlan(i, "risk exceeds budget", "observed", geo.entry, geo.stop,
                   tp1, tp2, tp3, obs.filled, obs.eligible);
      return;
   }
   // A target-ladder payout, not full lot at TP3. This is conditional on
   // every close being filled at its target; slippage/unknown fees omitted.
   double close1 = CalcTP1CloseLot(lot);
   double left1 = FloorLotStep(lot - close1);
   double close2 = CalcTP2CloseLot(left1);
   double left2 = FloorLotStep(left1 - close2);
   double reward = (close1 * tp1Pts + close2 * tp2Pts + left2 * tp3Pts) * pv;
   if(reward <= 0.0)
   {
      ShowHeldPlan(i, "payout not positive", "observed", geo.entry, geo.stop,
                   tp1, tp2, tp3, obs.filled, obs.eligible);
      return;
   }

   int vBars = isRange ? MathMax(1, RANGE_VALID_BARS) : VALID_BARS;
   datetime until = g_rows[i].lastBar + (datetime)((vBars + 1) * PeriodSeconds(g_rows[i].tf));
   int tfSec = (int)PeriodSeconds(g_rows[i].tf);
   long age = 0;
   if(g_rows[i].sigBirth > 0 && tfSec > 0 && g_rows[i].lastBar > g_rows[i].sigBirth)
      age = (long)((g_rows[i].lastBar - g_rows[i].sigBirth) / tfSec);
   int left = (int)MathMax(0, MathMin(vBars, vBars - (int)age));
   int dg = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   string currency = AccountInfoString(ACCOUNT_CURRENCY);
   color dirColor = dir > 0 ? InpBuyColor : InpSellColor;

   g_plans[i].state = 2;
   g_plans[i].dir = dir;
   g_plans[i].score = score;
   g_plans[i].market = market;
   g_plans[i].lines = PLAN_LINES;
   g_plans[i].kind = isRange ? "range fade" : StringFormat("%s %+d/3", market ? "market" : "pending", score);
   g_plans[i].entryPrice = geo.entry;
   g_plans[i].slPrice = geo.stop;
   g_plans[i].tp1Price = tp1;
   g_plans[i].tp2Price = tp2;
   g_plans[i].tp3Price = tp3;
   g_plans[i].lot = lot;
   g_plans[i].slPts = slPts;
   g_plans[i].tpPts = tp3Pts;
   g_plans[i].tp1Pts = tp1Pts;
   g_plans[i].tp2Pts = tp2Pts;
   g_plans[i].tp3Pts = tp3Pts;
   g_plans[i].validUntil = until;

   g_plans[i].lbl[0][0] = "Entry:";
   g_plans[i].val[0][0] = DoubleToString(geo.entry, dg);
   g_plans[i].clr[0][0] = dirColor;
   g_plans[i].lbl[0][1] = "Lot:";
   g_plans[i].val[0][1] = DoubleToString(lot, 2) + (InpUseMinLot ? " (min)" : "");
   g_plans[i].clr[0][1] = InpTitleColor;
   g_plans[i].lbl[0][2] = "Data:";
   g_plans[i].val[0][2] = StringFormat("%d/%d analogs", obs.filled, obs.eligible);
   g_plans[i].clr[0][2] = clrSilver;

   g_plans[i].lbl[1][0] = "Stop:";
   g_plans[i].val[1][0] = StringFormat("%s %dpts", DoubleToString(geo.stop, dg), slPts);
   g_plans[i].clr[1][0] = InpSellColor;
   g_plans[i].lbl[1][1] = "TP1:";
   g_plans[i].val[1][1] = StringFormat("%s %dpts", DoubleToString(tp1, dg), tp1Pts);
   g_plans[i].clr[1][1] = InpBuyColor;
   g_plans[i].lbl[1][2] = "TP2:";
   g_plans[i].val[1][2] = StringFormat("%s %dpts", DoubleToString(tp2, dg), tp2Pts);
   g_plans[i].clr[1][2] = InpBuyColor;

   g_plans[i].lbl[2][0] = "TP3:";
   g_plans[i].val[2][0] = StringFormat("%s %dpts", DoubleToString(tp3, dg), tp3Pts);
   g_plans[i].clr[2][0] = InpBuyColor;
   g_plans[i].lbl[2][1] = "Risk:";
   g_plans[i].val[2][1] = StringFormat("%s %s (est)", DoubleToString(riskMoney, 2), currency);
   g_plans[i].clr[2][1] = InpSellColor;
   g_plans[i].lbl[2][2] = "Reward:";
   g_plans[i].val[2][2] = StringFormat("%s %s (est)", DoubleToString(reward, 2), currency);
   g_plans[i].clr[2][2] = InpBuyColor;

   g_plans[i].lbl[3][0] = "Valid:";
   g_plans[i].val[3][0] = StringFormat("%d/%d bars", left, vBars);
   g_plans[i].clr[3][0] = clrSilver;
   g_plans[i].lbl[3][1] = "Window:";
   g_plans[i].val[3][1] = StringFormat("%d bars", ObservationHorizon(i));
   g_plans[i].clr[3][1] = clrSilver;
   g_plans[i].lbl[3][2] = "Fees:";
   g_plans[i].val[3][2] = "not included";
   g_plans[i].clr[3][2] = clrSilver;
   if(entryVeto != "")
   {
      HoldPlan(i, entryVeto); // retain the visible plan, but never execute it
      g_plans[i].lbl[3][0] = "Block:";
      g_plans[i].val[3][0] = entryVeto;
      g_plans[i].clr[3][0] = clrOrange;
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
   bool     isOpen;        // true = open position, false = broker order
   bool     marketInFlight; // an accepted market request not yet resolved
   bool     residualOrder; // remaining entry order while a position is open
   bool     multiplePositions; // ambiguous same-magic positions require review
   ulong    ticket;        // position or order ticket
   int      dir;           // +1 buy, -1 sell
   int      entryScore;    // score when placed/opened
   double   initLot;       // initial lot size when placed/opened
   double   curLot;        // current remaining lot size
   double   entryPrice;    // position open price or pending limit price
   double   slPrice;       // current broker SL price (0.0 if none)
   double   tpPrice;       // current broker TP price (TP3)
   double   tp1Price;      // absolute target: frozen at placement/repricing
   double   tp2Price;
   bool     modernTargets; // recoverable absolute-level persistence
   bool     legacyRecovery; // one-time migration of a pre-upgrade trade
   bool     newTradeMarker; // broker comment identifies a new structure plan
   bool     legacyTradeMarker; // old SimpleEA_ comment proves legacy fallback is applicable
   bool     tp1Skipped;    // target no longer profitable after slippage
   bool     tp2Skipped;
   bool     tp1Short;      // broker partial left an untradeable residual
   bool     tp2Short;
   bool     cancelPending; // a rejected cancel must be retried, never refreshed
   double   tp1StartLot;
   double   tp1GoalLot;
   double   tp1DoneLot;
   bool     tp1Awaiting;   // accepted but execution volume not yet known
   double   tp2StartLot;
   double   tp2GoalLot;
   double   tp2DoneLot;
   bool     tp2Awaiting;
   double   profitUSD;     // live position profit in account currency
   int      slPts;         // current SL distance from entry in points
   int      tp1Pts;        // signed favorable distances from actual fill
   int      tp2Pts;
   int      tp3Pts;
   bool     tp1Hit;        // true once TP1 has been reached
   bool     tp2Hit;        // true once TP2 has been reached
   bool     isRange;       // range-fade entry; box rules apply only while pending
   double   rngTop;        // pending range entry's upper invalidation band
   double   rngBot;        // pending range entry's lower invalidation band
   datetime placedBar;     // closed-bar timestamp when pending order was placed
   datetime fillBar;       // closed-bar timestamp when the position filled/opened
   datetime lastEvalBar;   // last closed bar on which a pending update was evaluated
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

bool PlanHasOpenPosition(int i)
{
   return(g_auto[i].active && g_auto[i].isOpen);
}

bool PlanHasUncertainOrder(int i)
{
   return((!g_auto[i].active && (GlobalVariableCheck(AutoGVKey(i, "iv")) ||
                                 GlobalVariableCheck(AutoGVKey(i, "lv")))) ||
          (g_auto[i].active && g_auto[i].marketInFlight));
}

double ExistingPendingVolume(int i, int dir)
{
   if(g_auto[i].active && !g_auto[i].isOpen && g_auto[i].dir == dir)
      return(g_auto[i].curLot);
   return(0.0);
}

// The terminal's global variables are doubles; split broker IDs into two
// 32-bit halves so even a 64-bit ticket can be checked exactly.
bool SetSlotGV(int i, string field, double value)
{
   return(GlobalVariableSet(AutoGVKey(i, field), value) != 0);
}

void DeleteTargetIntent(int i)
{
   string fields[] = {"iv", "id", "ie", "is", "i1", "i2", "i3"};
   for(int k = 0; k < ArraySize(fields); k++) GlobalVariableDel(AutoGVKey(i, fields[k]));
}

void DeleteTargetUpdate(int i)
{
   string fields[] = {"uv", "ue", "us", "u1", "u2", "u3"};
   for(int k = 0; k < ArraySize(fields); k++) GlobalVariableDel(AutoGVKey(i, fields[k]));
}

// Journal before sending, so a restart between broker acceptance and slot
// persistence can recover absolute targets from the matching broker order.
bool BeginTargetIntent(int i, int dir, double entry, double sl,
                       double tp1, double tp2, double tp3)
{
   DeleteTargetIntent(i);
   DeleteTargetUpdate(i);
   GlobalVariableDel(AutoGVKey(i, "lv"));
   GlobalVariableDel(AutoGVKey(i, "tp1"));
   GlobalVariableDel(AutoGVKey(i, "tp2"));
   GlobalVariableDel(AutoGVKey(i, "cx"));
   bool ok = true;
   if(!SetSlotGV(i, "id", (double)dir)) ok = false;
   if(!SetSlotGV(i, "ie", entry)) ok = false;
   if(!SetSlotGV(i, "is", sl)) ok = false;
   if(!SetSlotGV(i, "i1", tp1)) ok = false;
   if(!SetSlotGV(i, "i2", tp2)) ok = false;
   if(!SetSlotGV(i, "i3", tp3)) ok = false;
   if(ok && !SetSlotGV(i, "iv", 1.0)) ok = false; // commit marker last
   GlobalVariablesFlush();
   if(!ok) DeleteTargetIntent(i);
   return(ok);
}

bool BeginTargetUpdate(int i, double entry, double sl,
                       double tp1, double tp2, double tp3)
{
   DeleteTargetUpdate(i);
   bool ok = true;
   if(!SetSlotGV(i, "ue", entry)) ok = false;
   if(!SetSlotGV(i, "us", sl)) ok = false;
   if(!SetSlotGV(i, "u1", tp1)) ok = false;
   if(!SetSlotGV(i, "u2", tp2)) ok = false;
   if(!SetSlotGV(i, "u3", tp3)) ok = false;
   if(ok && !SetSlotGV(i, "uv", 1.0)) ok = false;
   GlobalVariablesFlush();
   if(!ok) DeleteTargetUpdate(i);
   return(ok);
}

bool StoredSlotIdentityMatches(int i)
{
   if(!GlobalVariableCheck(AutoGVKey(i, "ik")) ||
      !GlobalVariableCheck(AutoGVKey(i, "ih")) ||
      !GlobalVariableCheck(AutoGVKey(i, "il"))) return(false);
   int kind = (int)GlobalVariableGet(AutoGVKey(i, "ik"));
   ulong hi = (ulong)GlobalVariableGet(AutoGVKey(i, "ih"));
   ulong lo = (ulong)GlobalVariableGet(AutoGVKey(i, "il"));
   ulong id = (hi << 32) | lo;
   if(id == 0) return(false);
   if(kind == 2)
      return(g_auto[i].isOpen && g_auto[i].diaryPositionId == id);
   if(kind != 1) return(false);
   if(!g_auto[i].isOpen) return(g_auto[i].ticket == id);
   // A pending/market order may have filled while the terminal was down.
   return(g_auto[i].diaryPositionId > 0 && HistoryOrderSelect(id) &&
          (ulong)HistoryOrderGetInteger(id, ORDER_POSITION_ID) == g_auto[i].diaryPositionId);
}

bool SaveAutoSlotState(int i)
{
   bool ok = true;
   if(g_auto[i].cancelPending && !SetSlotGV(i, "cx", 1.0)) ok = false;
   if(g_auto[i].isRange)
   {
      if(!SetSlotGV(i, "rng", 1.0)) ok = false;
      if(!SetSlotGV(i, "top", g_auto[i].rngTop)) ok = false;
      if(!SetSlotGV(i, "bot", g_auto[i].rngBot)) ok = false;
   }
   else
   {
      GlobalVariableDel(AutoGVKey(i, "rng"));
      GlobalVariableDel(AutoGVKey(i, "top"));
      GlobalVariableDel(AutoGVKey(i, "bot"));
   }
   if(g_auto[i].entryScore != 0 && !SetSlotGV(i, "score", (double)g_auto[i].entryScore)) ok = false;
   if(g_auto[i].placedBar > 0 && !SetSlotGV(i, "placed", (double)g_auto[i].placedBar)) ok = false;
   if(g_auto[i].tp1Hit) { if(!SetSlotGV(i, "tp1", 1.0)) ok = false; }
   else GlobalVariableDel(AutoGVKey(i, "tp1"));
   if(g_auto[i].tp2Hit) { if(!SetSlotGV(i, "tp2", 1.0)) ok = false; }
   else GlobalVariableDel(AutoGVKey(i, "tp2"));

   if(g_auto[i].modernTargets && g_auto[i].tp1Price > 0.0 && g_auto[i].tp2Price > 0.0)
   {
      int kind = (g_auto[i].isOpen && g_auto[i].diaryPositionId > 0) ? 2 : 1;
      ulong id = kind == 2 ? g_auto[i].diaryPositionId : g_auto[i].ticket;
      if(id == 0) ok = false;
      if(!SetSlotGV(i, "ik", (double)kind)) ok = false;
      if(!SetSlotGV(i, "ih", (double)(id >> 32))) ok = false;
      if(!SetSlotGV(i, "il", (double)(id & (ulong)0xFFFFFFFF))) ok = false;
      if(!SetSlotGV(i, "ld", (double)g_auto[i].dir)) ok = false;
      if(!SetSlotGV(i, "le", g_auto[i].entryPrice)) ok = false;
      if(!SetSlotGV(i, "ls", g_auto[i].slPrice)) ok = false;
      if(!SetSlotGV(i, "l1", g_auto[i].tp1Price)) ok = false;
      if(!SetSlotGV(i, "l2", g_auto[i].tp2Price)) ok = false;
      if(!SetSlotGV(i, "l3", g_auto[i].tpPrice)) ok = false;
      if(!SetSlotGV(i, "s1", g_auto[i].tp1StartLot)) ok = false;
      if(!SetSlotGV(i, "g1", g_auto[i].tp1GoalLot)) ok = false;
      if(!SetSlotGV(i, "c1", g_auto[i].tp1DoneLot)) ok = false;
      if(!SetSlotGV(i, "s2", g_auto[i].tp2StartLot)) ok = false;
      if(!SetSlotGV(i, "g2", g_auto[i].tp2GoalLot)) ok = false;
      if(!SetSlotGV(i, "c2", g_auto[i].tp2DoneLot)) ok = false;
      if(!SetSlotGV(i, "k1", g_auto[i].tp1Skipped ? 1.0 : 0.0)) ok = false;
      if(!SetSlotGV(i, "k2", g_auto[i].tp2Skipped ? 1.0 : 0.0)) ok = false;
      if(!SetSlotGV(i, "x1", g_auto[i].tp1Short ? 1.0 : 0.0)) ok = false;
      if(!SetSlotGV(i, "x2", g_auto[i].tp2Short ? 1.0 : 0.0)) ok = false;
      // A false in-flight flag must never overwrite a previously durable
      // true flag unless all reconciliation fields were saved successfully.
      if(ok && !SetSlotGV(i, "a1", g_auto[i].tp1Awaiting ? 1.0 : 0.0)) ok = false;
      if(ok && !SetSlotGV(i, "a2", g_auto[i].tp2Awaiting ? 1.0 : 0.0)) ok = false;
      if(ok && !g_auto[i].cancelPending && !SetSlotGV(i, "cx", 0.0)) ok = false;
      if(ok && !SetSlotGV(i, "lv", 2.0)) ok = false; // commit marker
   }
   if(g_auto[i].diaryRecordId > 0)
   {
      if(!SetSlotGV(i, "drec", (double)g_auto[i].diaryRecordId)) ok = false;
      if(!SetSlotGV(i, "dday", (double)g_auto[i].diaryPlacedDayKey)) ok = false;
      if(!SetSlotGV(i, "dsl", (double)g_auto[i].diaryPlanSlPts)) ok = false;
      if(!SetSlotGV(i, "dreg", (double)g_auto[i].diaryRegime)) ok = false;
      if(!SetSlotGV(i, "dsty", (double)g_auto[i].diaryStyle)) ok = false;
      if(!SetSlotGV(i, "dat", (double)g_auto[i].diaryPlacedAt)) ok = false;
      if(!SetSlotGV(i, "dlocal", (double)g_auto[i].diaryLocalPlaced)) ok = false;
      if(!SetSlotGV(i, "dcost", g_auto[i].diaryCostTp1Pct)) ok = false;
      if(!SetSlotGV(i, "dpeak", g_auto[i].diaryPeakTp1Pct)) ok = false;
   }
   GlobalVariablesFlush();
   if(!ok) PrintFormat("SimpleEA: cannot persist %s target state; staged exits need attention.", g_rows[i].tag);
   return(ok);
}

void ClearAutoSlotState(int i)
{
   string fields[] = {"rng", "top", "bot", "score", "placed", "tp1", "tp2",
                      "drec", "dday", "dsl", "dreg", "dsty", "dat", "dlocal", "dcost", "dpeak",
                      "ik", "ih", "il", "lv", "ld", "le", "ls", "l1", "l2", "l3",
                      "s1", "g1", "c1", "a1", "s2", "g2", "c2", "a2", "k1", "k2", "x1", "x2", "cx"};
   for(int k = 0; k < ArraySize(fields); k++) GlobalVariableDel(AutoGVKey(i, fields[k]));
   DeleteTargetIntent(i);
   DeleteTargetUpdate(i);
   GlobalVariablesFlush();
}

double SlotGV(int i, string field, double fallback = 0.0)
{
   return(GlobalVariableCheck(AutoGVKey(i, field)) ? GlobalVariableGet(AutoGVKey(i, field)) : fallback);
}

void RestoreAutoSlotState(int i)
{
   // Never attach flags from a different new-format order using the same
   // magic number. Older installations had no identity field.
   if(GlobalVariableCheck(AutoGVKey(i, "lv")) && !StoredSlotIdentityMatches(i)) return;
   g_auto[i].isRange = SlotGV(i, "rng") > 0.5;
   g_auto[i].rngTop = SlotGV(i, "top");
   g_auto[i].rngBot = SlotGV(i, "bot");
   g_auto[i].entryScore = (int)MathRound(SlotGV(i, "score"));
   g_auto[i].placedBar = (datetime)SlotGV(i, "placed");
   g_auto[i].tp1Hit = SlotGV(i, "tp1") > 0.5;
   g_auto[i].tp2Hit = SlotGV(i, "tp2") > 0.5;
   g_auto[i].diaryRecordId = (long)MathRound(SlotGV(i, "drec"));
   g_auto[i].diaryPlacedDayKey = (long)MathRound(SlotGV(i, "dday"));
   g_auto[i].diaryPlanSlPts = (int)MathRound(SlotGV(i, "dsl"));
   g_auto[i].diaryRegime = (int)MathRound(SlotGV(i, "dreg"));
   g_auto[i].diaryStyle = (int)MathRound(SlotGV(i, "dsty"));
   g_auto[i].diaryPlacedAt = (datetime)SlotGV(i, "dat");
   g_auto[i].diaryLocalPlaced = (datetime)SlotGV(i, "dlocal");
   g_auto[i].diaryCostTp1Pct = SlotGV(i, "dcost");
   g_auto[i].diaryPeakTp1Pct = SlotGV(i, "dpeak");
   if(GlobalVariableCheck(AutoGVKey(i, "lv")))
   {
      g_auto[i].tp1StartLot = SlotGV(i, "s1");
      g_auto[i].tp1GoalLot = SlotGV(i, "g1");
      g_auto[i].tp1DoneLot = SlotGV(i, "c1");
      g_auto[i].tp1Awaiting = SlotGV(i, "a1") > 0.5;
      g_auto[i].tp2StartLot = SlotGV(i, "s2");
      g_auto[i].tp2GoalLot = SlotGV(i, "g2");
      g_auto[i].tp2DoneLot = SlotGV(i, "c2");
      g_auto[i].tp2Awaiting = SlotGV(i, "a2") > 0.5;
      g_auto[i].tp1Skipped = SlotGV(i, "k1") > 0.5;
      g_auto[i].tp2Skipped = SlotGV(i, "k2") > 0.5;
      g_auto[i].tp1Short = SlotGV(i, "x1") > 0.5;
      g_auto[i].tp2Short = SlotGV(i, "x2") > 0.5;
      g_auto[i].cancelPending = SlotGV(i, "cx") > 0.5;
   }
}

void RefreshSlotTargetDistances(int i, double point)
{
   if(point <= 0.0) return;
   int dir = g_auto[i].dir;
   g_auto[i].tp1Pts = g_auto[i].tp1Price > 0.0
      ? (int)MathMax(0, MathRound((double)dir * (g_auto[i].tp1Price - g_auto[i].entryPrice) / point)) : 0;
   g_auto[i].tp2Pts = g_auto[i].tp2Price > 0.0
      ? (int)MathMax(0, MathRound((double)dir * (g_auto[i].tp2Price - g_auto[i].entryPrice) / point)) : 0;
   g_auto[i].tp3Pts = g_auto[i].tpPrice > 0.0
      ? (int)MathMax(0, MathRound((double)dir * (g_auto[i].tpPrice - g_auto[i].entryPrice) / point)) : 0;
}

bool MatchingBrokerLevels(int i, double entry, double sl, double tp, double tolerance)
{
   if(MathAbs(g_auto[i].slPrice - sl) > tolerance ||
      MathAbs(g_auto[i].tpPrice - tp) > tolerance) return(false);
   return(g_auto[i].isOpen || MathAbs(g_auto[i].entryPrice - entry) <= tolerance);
}

void RecoverSlotTargets(int i, double point)
{
   double tol = 0.5 * point;
   bool hasVersion = GlobalVariableCheck(AutoGVKey(i, "lv"));
   bool identity = hasVersion && StoredSlotIdentityMatches(i);
   bool recovered = false;
   if(identity && GlobalVariableCheck(AutoGVKey(i, "uv")) &&
      MatchingBrokerLevels(i, SlotGV(i, "ue"), SlotGV(i, "us"), SlotGV(i, "u3"), tol))
   {
      // Modification reached the broker before the terminal stopped.
      g_auto[i].tp1Price = SlotGV(i, "u1");
      g_auto[i].tp2Price = SlotGV(i, "u2");
      recovered = true;
   }
   else if(identity && (int)SlotGV(i, "ld") == g_auto[i].dir &&
           MatchingBrokerLevels(i, SlotGV(i, "le"), SlotGV(i, "ls"), SlotGV(i, "l3"), tol))
   {
      g_auto[i].tp1Price = SlotGV(i, "l1");
      g_auto[i].tp2Price = SlotGV(i, "l2");
      recovered = true;
   }
   else if(!hasVersion && GlobalVariableCheck(AutoGVKey(i, "iv")) &&
           (int)SlotGV(i, "id") == g_auto[i].dir &&
           MatchingBrokerLevels(i, SlotGV(i, "ie"), SlotGV(i, "is"), SlotGV(i, "i3"), tol))
   {
      g_auto[i].tp1Price = SlotGV(i, "i1");
      g_auto[i].tp2Price = SlotGV(i, "i2");
      recovered = true;
   }
   else if(!hasVersion && !GlobalVariableCheck(AutoGVKey(i, "iv")) &&
           g_auto[i].legacyTradeMarker && g_auto[i].isOpen && g_auto[i].tpPrice > 0.0)
   {
      // A pre-upgrade trade's diary can retain the exact distances that
      // were active before recompilation. Only if that row is unavailable
      // use the OLD restart reconstruction; never apply it to SEA3 orders.
      if(!LegacyDiaryTargetPrices(i, point, g_auto[i].tp1Price, g_auto[i].tp2Price))
      {
         int tp3 = (int)MathMax(1.0, MathRound(MathAbs(g_auto[i].tpPrice - g_auto[i].entryPrice) / point));
         int tp1 = 1, tp2 = 1;
         ComputeLegacyTPLevels(tp3, tp1, tp2);
         g_auto[i].tp1Price = NormPrice(g_auto[i].entryPrice + (double)g_auto[i].dir * tp1 * point);
         g_auto[i].tp2Price = NormPrice(g_auto[i].entryPrice + (double)g_auto[i].dir * tp2 * point);
      }
      g_auto[i].legacyRecovery = true;
      recovered = true;
   }
   if(recovered && g_auto[i].tp1Price > 0.0 && g_auto[i].tp2Price > 0.0 &&
      (double)g_auto[i].dir * (g_auto[i].tp2Price - g_auto[i].tp1Price) >= -tol &&
      (double)g_auto[i].dir * (g_auto[i].tpPrice - g_auto[i].tp2Price) >= -tol)
   {
      g_auto[i].modernTargets = true;
      RefreshSlotTargetDistances(i, point);
      if(SaveAutoSlotState(i)) { DeleteTargetIntent(i); DeleteTargetUpdate(i); }
      return;
   }
   // Unknown identity/state or externally altered broker exits: never
   // invent new software targets. Broker SL/TP remain untouched.
   g_auto[i].tp1Price = 0.0;
   g_auto[i].tp2Price = 0.0;
   g_auto[i].modernTargets = false;
   RefreshSlotTargetDistances(i, point);
   PrintFormat("SimpleEA: %s staged targets unavailable; broker SL/TP3 left unchanged. Review the trade.", g_rows[i].tag);
}


//==================================================================
//  CALIBRATION-HEALTH DIARY
//==================================================================
//  The diary records actual order outcomes separately from the bar-based
//  planning analogs; it does not modify the plan or place orders.  It records one small row for each original order idea
//  that SimpleEA actually acted on, then derives Day totals and
//  per-timeframe health warnings from those rows.  It never changes
//  a target, a stop, a score rule, a risk setting or a switch.
//
//  One row means one original idea:
//     - a pending that is merely repriced stays the same row;
//     - a cancelled pending and any later fresh-bar placement are separate ideas;
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
   bool     allowChoppy;
   bool     rangeMode;
   double   pointValue;      // account-currency value of 1 point x 1 lot at placement
   string   exitReason;      // compact token, never contains ';'
   bool     provisional;     // closed before the final deal reached history
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

SDiaryRecord  g_diary[];
SDiaryTotals  g_dayTotals;
SDiaryTotals  g_allTotals;
SHealthLane   g_health[TF_COUNT];

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
   s += "0;"; // CSV 34: reserved for backward-compatible row width
   s += IntegerToString(r.allowChoppy ? 1 : 0) + ";";
   s += IntegerToString(r.rangeMode ? 1 : 0) + ";";
   s += r.exitReason + ";";
   s += IntegerToString(r.provisional ? 1 : 0) + ";";
   s += DoubleToString(r.pointValue, 10) + ";";
   // CSV 40-46: reserved defaults; old and new 50-column rows remain readable.
   s += "0;0;0;0;0;-1.0000;-9999.0000;";
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
   // p[34] and p[40-46] are reserved compatibility columns, not strategy state.
   r.allowChoppy   = (StringToInteger(p[35]) != 0);
   r.rangeMode     = (StringToInteger(p[36]) != 0);
   r.exitReason    = p[37];
   r.provisional   = (StringToInteger(p[38]) != 0);
   r.pointValue    = StringToDouble(p[39]);

   // Rows ending at p[39] predate the final-exit diagnostics.
   r.finalTp1Pct     = -9999.0;
   r.stopExit        = false;
   r.stopKnown       = false;
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
   seg.n          = 0;
   seg.wins       = 0;
   seg.losses     = 0;
   seg.be         = 0;
   seg.tp1        = 0;
   seg.tp2        = 0;
   seg.tp3        = 0;
   seg.nearCount  = 0;
   seg.costN      = 0;
   seg.netR       = 0.0;
   seg.tp1Rate    = -1.0;
   seg.medianPeak = -1.0;
   seg.medianCost = -1.0;
   if(count <= 0 || start < 0 || start >= g_health[lane].recentCount)
      return;
   if(start + count > g_health[lane].recentCount)
      count = g_health[lane].recentCount - start;

   double peaks[];
   double costs[];
   ArrayResize(peaks, count);
   ArrayResize(costs, count);
   int peakN = 0;
   int costN = 0;

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
   }

   seg.costN = costN;
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
   //  The regime the trade actually acted on, so the diary can be read
   //  against what the EA did rather than against a number it ignored.
   if(g_rows[i].regime < 0)
   {
      if(g_rows[i].hurst > g_rows[i].hTrend)  return(1);
      if(g_rows[i].hurst < g_rows[i].hRevert) return(2);
      return(0);
   }
   return(g_rows[i].regime);
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

// Recover exact legacy staged distances from the actual recorded idea,
// before falling back to the old pre-diary restart rule.
bool LegacyDiaryTargetPrices(int i, double point, double &tp1, double &tp2)
{
   if(!g_diaryReady || point <= 0.0) return(false);
   int idx = DiaryFindOpenRecordForSlot(i);
   if(idx < 0 || g_diary[idx].dir != g_auto[i].dir ||
      g_diary[idx].entryPrice <= 0.0 || g_diary[idx].tp1Pts <= 0 ||
      g_diary[idx].tp2Pts < g_diary[idx].tp1Pts) return(false);
   tp1 = NormPrice(g_diary[idx].entryPrice + (double)g_auto[i].dir * g_diary[idx].tp1Pts * point);
   tp2 = NormPrice(g_diary[idx].entryPrice + (double)g_auto[i].dir * g_diary[idx].tp2Pts * point);
   return(true);
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
   // Old diary hit fields record a price reach, not proof of a successful
   // partial. They may only preserve the pre-upgrade recovery behavior;
   // new-format execution flags come exclusively from persisted broker work.
   if(g_auto[i].legacyRecovery && r.tp1Hit) g_auto[i].tp1Hit = true;
   if(g_auto[i].legacyRecovery && r.tp2Hit) g_auto[i].tp2Hit = true;
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

// When a partially-filled entry's remainder is gone, the position's
// settled volume, not the originally requested volume, defines the idea.
void DiarySetSettledEntryVolume(int i)
{
   if(!g_diaryReady || !g_auto[i].active || !g_auto[i].isOpen ||
      g_auto[i].tp1Hit || g_auto[i].tp2Hit || g_auto[i].tp1GoalLot > 0.0 ||
      g_auto[i].tp2GoalLot > 0.0 || g_auto[i].curLot <= 0.0) return;
   g_auto[i].initLot = g_auto[i].curLot;
   int idx = DiaryRecordIndexById(g_auto[i].diaryRecordId);
   if(idx >= 0 && g_diary[idx].status == 0 &&
      MathAbs(g_diary[idx].lot - g_auto[i].curLot) > 1e-8)
   {
      g_diary[idx].lot = g_auto[i].curLot;
      DiaryAfterChange();
   }
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
//  TP3, broker SL/TP, manual close noticed by sync, or a pending
//  cancelled for any reason - lands in exactly one row.
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
            // this EA was absent. Exclude incomplete peak observations.
            g_diary[k].peakTp1Pct = -1.0;
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
   r.useStopLoss   = true;   // every new order carries its planned broker-side SL
   r.allowChoppy   = InpAllowChoppyTrade;
   r.rangeMode     = InpRangeMode;
   r.pointValue    = PointValuePerLot();
   r.exitReason    = "";
   r.provisional   = false;
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
      g_diarySuppress[i] = false;

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
bool AllActiveStopsPresent()
{
   bool found = false;
   for(int i = 0; i < TF_COUNT; i++)
   {
      if(!g_auto[i].active) continue;
      found = true;
      if(g_auto[i].slPrice <= 0.0) return(false);
   }
   return(found);
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
   //  the single exit every terminal path shares; an OnInit or
   //  identity-change slot clear is explicitly suppressed because it
   //  does not establish that the broker position has ended.
   DiaryFinalizeSlot(i);
   if(!g_diarySuppress[i])
      ClearAutoSlotState(i);
   datetime sigBar = keepSignalBar ? g_auto[i].lastSignalBar : 0;
   g_auto[i].active        = false;
   g_auto[i].isOpen        = false;
   g_auto[i].marketInFlight = false;
   g_auto[i].residualOrder = false;
   g_auto[i].multiplePositions = false;
   g_auto[i].ticket        = 0;
   g_auto[i].dir           = 0;
   g_auto[i].entryScore    = 0;
   g_auto[i].initLot       = 0.0;
   g_auto[i].curLot        = 0.0;
   g_auto[i].entryPrice    = 0.0;
   g_auto[i].slPrice       = 0.0;
   g_auto[i].tpPrice       = 0.0;
   g_auto[i].tp1Price      = 0.0;
   g_auto[i].tp2Price      = 0.0;
   g_auto[i].modernTargets = false;
   g_auto[i].legacyRecovery = false;
   g_auto[i].newTradeMarker = false;
   g_auto[i].legacyTradeMarker = false;
   g_auto[i].tp1Skipped = false;
   g_auto[i].tp2Skipped = false;
   g_auto[i].tp1Short = false;
   g_auto[i].tp2Short = false;
   g_auto[i].cancelPending = false;
   g_auto[i].tp1StartLot = 0.0;
   g_auto[i].tp1GoalLot = 0.0;
   g_auto[i].tp1DoneLot = 0.0;
   g_auto[i].tp1Awaiting = false;
   g_auto[i].tp2StartLot = 0.0;
   g_auto[i].tp2GoalLot = 0.0;
   g_auto[i].tp2DoneLot = 0.0;
   g_auto[i].tp2Awaiting = false;
   g_auto[i].profitUSD     = 0.0;
   g_auto[i].slPts         = 0;
   g_auto[i].tp1Pts        = 0;
   g_auto[i].tp2Pts        = 0;
   g_auto[i].tp3Pts        = 0;
   g_auto[i].tp1Hit        = false;
   g_auto[i].tp2Hit        = false;
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
//  deliberate: while the timer is OFF the EA must keep taking
//  TP1/TP2/TP3 on trades that are already open.  Their broker-side SL
//  remains fixed and needs no timer-driven modification.  Waiting
//  pendings are the
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
      if(RequestPendingCancellation(i))
      {
         g_auto[i].lastSignalBar = g_rows[i].lastBar;
         cancelled++; // Sync resolves a possible partial-fill/cancel race
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
//     On           the switch is on and no header-level gate blocks placement
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
   return(NormalizeDouble(n, VolumeStepDigits(step)));
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
   //  M5 used to be excluded by NAME - "if(i == 0 ...)" returned true
   //  before anything else, so no setting anywhere could ever give the
   //  fastest row any higher-timeframe context.  It is now a switch like
   //  any other: off by default, because a direction veto costs 15-30
   //  minutes and an M5 reading only lives 10-15, so turning it on stops
   //  most of the trades it would allow.  The door exists now; whether to
   //  walk through it is the operator's call.
   if(i == 0)
   {
      if(!g_rows[0].ok || g_rows[0].direction == 0) return(false);
      if(!InpM5RequireHigher)                        return(true);
      if(!g_rows[1].ok || g_rows[1].direction == 0)  return(false);
      return(g_rows[1].direction == g_rows[0].direction);
   }

   if(!g_rows[i].ok || g_rows[i].direction == 0) return(false);
   if(!InpRequireM15M30SameTrend)                return(true);
   if(!g_rows[1].ok || !g_rows[2].ok)
      return(false);
   if(g_rows[1].direction == 0 || g_rows[2].direction == 0)
      return(false);
   return(g_rows[1].direction == g_rows[2].direction);
}

//+------------------------------------------------------------------+
//  Has a deal for timeframe `i` already entered on `barTime`?
//+------------------------------------------------------------------+
//  A pure question: "has this row already opened a trade on this bar?"
//
//  Two things were wrong here.  First, it WROTE to g_auto[].lastSignalBar
//  while answering - a side effect inside a predicate, and the only place
//  a freshly placed order was ever stamped with its bar, so the answer
//  could not be asked twice without changing it.  PlacePlanOrder() now
//  stamps the bar itself and this function only reads.
//
//  Second, it failed OPEN: when HistorySelect() failed it returned false
//  ("no trade on this bar"), which is exactly the answer that lets a
//  second order go out on a bar that already has one.  An unknown history
//  must block a new order, not authorise it, so every doubt now returns
//  true.
bool HasTradedOnBar(int i, datetime barTime)
{
   if(barTime <= 0)                              return(true);  // unknown -> block
   if(g_auto[i].lastSignalBar == barTime)        return(true);
   if(!HistorySelect(barTime, TimeCurrent() + 60)) return(true);  // history unavailable -> block
   long magic = MagicForTF(i);
   int  total = HistoryDealsTotal();
   for(int d = 0; d < total; d++)
   {
      ulong deal = HistoryDealGetTicket(d);
      if(deal == 0) continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol) continue;
      if(HistoryDealGetInteger(deal, DEAL_MAGIC) != magic)   continue;
      if(HistoryDealGetInteger(deal, DEAL_ENTRY) == DEAL_ENTRY_IN)
         return(true);
   }
   return(false);
}

//+------------------------------------------------------------------+
//  Low-level order wrappers (self-contained MqlTradeRequest calls).
//+------------------------------------------------------------------+
// 1 = accepted, 0 = definitive rejection, -1 = transport/async uncertainty.
int TradeOpenMarket(int i, int dir, double lot, double sl, double tp, ulong &outTicket,
                    double &outVolume, double &outPrice, bool &inFlight)
{
   outTicket = 0;
   outVolume = 0.0;
   outPrice = 0.0;
   inFlight = false;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0) return(0);

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
   req.comment      = "SEA3_" + g_rows[i].tag;
   req.type_filling = FillingMode();

   bool sent = OrderSend(req, res);
   NoteMarketClosedRetcode(res.retcode);
   if(res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_DONE_PARTIAL ||
      res.retcode == TRADE_RETCODE_PLACED)
   {
      outTicket = res.order; // a deal ticket is not an order/position identity
      outVolume = res.volume > 0.0 ? res.volume : lot;
      outPrice = res.price > 0.0 ? res.price : req.price;
      inFlight = (res.retcode == TRADE_RETCODE_PLACED); // acceptance is not a confirmed fill
      return(1);
   }
   if((!sent && res.retcode == 0) || res.retcode == TRADE_RETCODE_TIMEOUT ||
      res.retcode == TRADE_RETCODE_CONNECTION || res.retcode == TRADE_RETCODE_ERROR ||
      res.retcode == TRADE_RETCODE_LOCKED || res.retcode == TRADE_RETCODE_ORDER_CHANGED) return(-1);
   return(0);
}

//+------------------------------------------------------------------+
int TradePlaceLimit(int i, int dir, double lot, double price, double sl, double tp,
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
   req.comment      = "SEA3_" + g_rows[i].tag;
   req.type_filling = ORDER_FILLING_RETURN; // pending orders use RETURN
   req.type_time    = ORDER_TIME_GTC;

   bool sent = OrderSend(req, res);
   NoteMarketClosedRetcode(res.retcode);
   if(res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_DONE_PARTIAL ||
      res.retcode == TRADE_RETCODE_PLACED)
   {
      outTicket = res.order;
      return(1);
   }
   if((!sent && res.retcode == 0) || res.retcode == TRADE_RETCODE_TIMEOUT ||
      res.retcode == TRADE_RETCODE_CONNECTION || res.retcode == TRADE_RETCODE_ERROR ||
      res.retcode == TRADE_RETCODE_LOCKED || res.retcode == TRADE_RETCODE_ORDER_CHANGED) return(-1);
   return(0);
}

//+------------------------------------------------------------------+
// 1 = accepted/completed, 0 = definitive rejection, -1 = uncertain.
int TradeClosePosition(ulong posTicket, int dir, double volume, long magic,
                       double &executed, bool &uncertain)
{
   executed = 0.0;
   uncertain = false;
   // A zero/stale position ticket must never become an opposite opening
   // order on a hedging account. Verify identity immediately before send.
   if(posTicket == 0 || !PositionSelectByTicket(posTicket) ||
      PositionGetString(POSITION_SYMBOL) != _Symbol ||
      PositionGetInteger(POSITION_MAGIC) != magic ||
      (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? 1 : -1) != dir)
      return(0);
   double liveVolume = PositionGetDouble(POSITION_VOLUME);
   if(volume <= 0.0 || liveVolume - volume < SymbolMinLot() - 1e-8) return(0);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0) return(0);
   MqlTradeRequest req;
   MqlTradeResult res;
   ZeroMemory(req);
   ZeroMemory(res);
   req.action = TRADE_ACTION_DEAL;
   req.position = posTicket;
   req.symbol = _Symbol;
   req.volume = volume;
   req.type = (dir > 0) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   req.price = NormPrice((dir > 0) ? bid : ask);
   req.deviation = AutoSlippagePts(true);
   req.magic = magic;
   req.type_filling = FillingMode();
   bool sent = OrderSend(req, res);
   NoteMarketClosedRetcode(res.retcode);
   if(res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_DONE_PARTIAL)
   {
      executed = res.volume;
      uncertain = (res.retcode == TRADE_RETCODE_DONE_PARTIAL &&
                   req.type_filling == ORDER_FILLING_RETURN);
      return(1);
   }
   if(!sent && res.retcode == 0) return(-1);
   if(res.retcode == TRADE_RETCODE_TIMEOUT || res.retcode == TRADE_RETCODE_CONNECTION ||
      res.retcode == TRADE_RETCODE_PLACED || res.retcode == TRADE_RETCODE_ERROR ||
      res.retcode == TRADE_RETCODE_LOCKED || res.retcode == TRADE_RETCODE_ORDER_CHANGED) return(-1);
   return(0);
}

//+------------------------------------------------------------------+
// A broker-visible exit change lets restart recovery tell an old pending
// fill from a modified fill. If only the price/software targets differ,
// preserve the old ladder instead of creating an indistinguishable race.
bool BrokerExitsDiffer(double oldSL, double oldTP, double newSL, double newTP, double point)
{
   return(MathAbs(oldSL - newSL) >= 0.5 * point ||
          MathAbs(oldTP - newTP) >= 0.5 * point);
}

bool PendingLevelsMatch(ulong ticket, double price, double sl, double tp, double tolerance)
{
   if(!OrderSelect(ticket)) return(false);
   return(MathAbs(OrderGetDouble(ORDER_PRICE_OPEN) - price) < tolerance &&
          MathAbs(OrderGetDouble(ORDER_SL) - sl) < tolerance &&
          MathAbs(OrderGetDouble(ORDER_TP) - tp) < tolerance);
}

bool TradeModifyOrder(ulong ordTicket, double newPrice, double newSL, double newTP)
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0.0) return(false);
   double normP = NormPrice(newPrice);
   double normSL = (newSL > 0.0) ? NormPrice(newSL) : 0.0;
   double normTP = (newTP > 0.0) ? NormPrice(newTP) : 0.0;
   if(!OrderSelect(ordTicket)) return(false);
   ENUM_ORDER_TYPE_TIME typeTime = (ENUM_ORDER_TYPE_TIME)OrderGetInteger(ORDER_TYPE_TIME);
   datetime expTime = (datetime)OrderGetInteger(ORDER_TIME_EXPIRATION);
   double stopLim = OrderGetDouble(ORDER_PRICE_STOPLIMIT);
   if(PendingLevelsMatch(ordTicket, normP, normSL, normTP, 0.5 * point)) return(true);

   MqlTradeRequest req;
   MqlTradeResult res;
   ZeroMemory(req);
   ZeroMemory(res);
   req.action = TRADE_ACTION_MODIFY;
   req.order = ordTicket;
   req.symbol = _Symbol;
   req.price = normP;
   req.sl = normSL;
   req.tp = normTP;
   req.stoplimit = stopLim;
   req.type_time = typeTime;
   req.expiration = expTime;
   bool sent = OrderSend(req, res);
   NoteMarketClosedRetcode(res.retcode);
   if((sent && res.retcode == TRADE_RETCODE_DONE) || res.retcode == TRADE_RETCODE_NO_CHANGES)
   {
      // Acceptance alone is not enough: the actual broker order must
      // show these values before we commit the independent TP1/TP2.
      if(PendingLevelsMatch(ordTicket, normP, normSL, normTP, 0.5 * point)) return(true);
   }
   PrintFormat("SimpleEA: TradeModifyOrder(#%I64u) not confirmed (retcode=%u).", ordTicket, res.retcode);
   return(false); // includes asynchronous PLACED and unknown outcomes
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

// A HOLD remains a cancellation obligation until the broker confirms it.
// Persist this before requesting deletion, so a rejection/restart can
// never silently turn the waiting entry back into a fresh plan.
bool RequestPendingCancellation(int i)
{
   if(!g_auto[i].cancelPending)
   {
      g_auto[i].cancelPending = true;
      if(!SaveAutoSlotState(i) && SlotGV(i, "cx") < 0.5)
      {
         // If the cancel latch cannot be written, invalidate recovery of
         // a new/pending ladder so a restart treats it as missing and tries
         // to cancel rather than silently refreshing it. Filesystem failure
         // can also prevent deletion; the operator must check the broker.
         GlobalVariableDel(AutoGVKey(i, "lv"));
         DeleteTargetIntent(i);
         DeleteTargetUpdate(i);
         GlobalVariablesFlush();
         PrintFormat("SimpleEA: %s cancel latch could not be saved; verify/cancel this broker order manually.", g_rows[i].tag);
      }
   }
   return(TradeDeleteOrder(g_auto[i].ticket));
}

// A partially filled entry can leave an order at the broker while a
// position is already open. Stop it from increasing the position later;
// until the broker confirms cancellation, defer software partial exits.
bool CancelEntryRemainders(int i)
{
   bool found = false, tried = false;
   ulong nowMs = GetTickCount64();
   bool canCancel = CanTradeNow() && nowMs - g_lastResidualCancelMs[i] >= 2000;
   for(int k = OrdersTotal() - 1; k >= 0; k--)
   {
      ulong ticket = OrderGetTicket(k);
      if(ticket == 0 || OrderGetString(ORDER_SYMBOL) != _Symbol ||
         OrderGetInteger(ORDER_MAGIC) != MagicForTF(i)) continue;
      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      bool buyEntry = (type == ORDER_TYPE_BUY || type == ORDER_TYPE_BUY_LIMIT ||
                       type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_BUY_STOP_LIMIT);
      bool sellEntry = (type == ORDER_TYPE_SELL || type == ORDER_TYPE_SELL_LIMIT ||
                        type == ORDER_TYPE_SELL_STOP || type == ORDER_TYPE_SELL_STOP_LIMIT);
      if((g_auto[i].dir > 0 && !buyEntry) || (g_auto[i].dir < 0 && !sellEntry)) continue;
      found = true;
      if(canCancel)
      {
         tried = true;
         if(!TradeDeleteOrder(ticket))
            PrintFormat("SimpleEA: %s entry remainder #%I64u still needs cancellation.", g_rows[i].tag, ticket);
      }
   }
   if(tried) g_lastResidualCancelMs[i] = nowMs;
   return(found); // rescan on the next sync before permitting TP1/TP2
}

// A temporarily empty position/order list during reconnect is not proof
// of closure. Clear a stored target ladder only when broker history proves
// the original position was fully closed or the unfilled order ended.
bool BrokerPositionEnded(ulong positionId)
{
   if(positionId == 0 || !TerminalInfoInteger(TERMINAL_CONNECTED) ||
      !HistorySelectByPosition(positionId)) return(false);
   double entered = 0.0, exited = 0.0;
   int n = HistoryDealsTotal();
   for(int k = 0; k < n; k++)
   {
      ulong deal = HistoryDealGetTicket(k);
      if(deal == 0 || (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID) != positionId) continue;
      long how = HistoryDealGetInteger(deal, DEAL_ENTRY);
      double volume = HistoryDealGetDouble(deal, DEAL_VOLUME);
      if(volume <= 0.0) continue;
      if(how == DEAL_ENTRY_IN) entered += volume;
      else if(how == DEAL_ENTRY_OUT || how == DEAL_ENTRY_OUT_BY) exited += volume;
      else if(how == DEAL_ENTRY_INOUT) return(false); // reversal needs manual review
   }
   return(entered > 0.0 && exited + 1e-8 >= entered);
}

bool BrokerOrderEnded(ulong orderId)
{
   if(orderId == 0 || !TerminalInfoInteger(TERMINAL_CONNECTED) || !HistoryOrderSelect(orderId)) return(false);
   long state = HistoryOrderGetInteger(orderId, ORDER_STATE);
   if(state != ORDER_STATE_CANCELED && state != ORDER_STATE_EXPIRED &&
      state != ORDER_STATE_REJECTED && state != ORDER_STATE_FILLED) return(false);
   ulong positionId = (ulong)HistoryOrderGetInteger(orderId, ORDER_POSITION_ID);
   if(positionId > 0) return(BrokerPositionEnded(positionId));
   return(state != ORDER_STATE_FILLED); // a fill with no position id is ambiguous
}

bool BrokerSlotEnded(int i, bool wasActive)
{
   if(wasActive && g_auto[i].isOpen && g_auto[i].diaryPositionId > 0)
      return(BrokerPositionEnded(g_auto[i].diaryPositionId));
   if(wasActive && !g_auto[i].isOpen && g_auto[i].ticket > 0)
      return(BrokerOrderEnded(g_auto[i].ticket));
   if(!GlobalVariableCheck(AutoGVKey(i, "lv")) ||
      !GlobalVariableCheck(AutoGVKey(i, "ik")) ||
      !GlobalVariableCheck(AutoGVKey(i, "ih")) ||
      !GlobalVariableCheck(AutoGVKey(i, "il"))) return(false);
   ulong id = ((ulong)SlotGV(i, "ih") << 32) | (ulong)SlotGV(i, "il");
   int kind = (int)SlotGV(i, "ik");
   if(kind == 2) return(BrokerPositionEnded(id));
   if(kind == 1) return(BrokerOrderEnded(id));
   return(false);
}

int CountLanePositions(int i)
{
   int count = 0;
   for(int k = 0; k < PositionsTotal(); k++)
   {
      ulong ticket = PositionGetTicket(k);
      if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol ||
         PositionGetInteger(POSITION_MAGIC) != MagicForTF(i)) continue;
      count++;
   }
   return(count);
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
      bool  hadResidual = g_auto[i].residualOrder;
      bool  hadMultiple = g_auto[i].multiplePositions;
      int   positionCount = CountLanePositions(i);

      // ---- 1. Check open positions for this timeframe's magic -------
      int posTotal = PositionsTotal();
      for(int p = 0; p < posTotal; p++)
      {
         ulong tk = PositionGetTicket(p);
         if(tk == 0) continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
         if(PositionGetInteger(POSITION_MAGIC) != magic)   continue;

         ulong livePositionId = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
         if(wasOpen && g_auto[i].diaryPositionId > 0 && livePositionId > 0 &&
            g_auto[i].diaryPositionId != livePositionId)
         {
            // Never carry one position's targets/partial flags to another
            // same-magic position after manual action or multiple fills.
            g_diarySuppress[i] = true;
            ResetAutoSlot(i, true);
            g_diarySuppress[i] = false;
            wasActive = false; wasOpen = false; wasPending = false;
            hadResidual = false;
            PrintFormat("SimpleEA: %s position identity changed; recovering by broker identity.", g_rows[i].tag);
         }
         double previousSL = g_auto[i].slPrice;
         double previousTP = g_auto[i].tpPrice;
         foundPos             = true;
         g_auto[i].active     = true;
         g_auto[i].isOpen     = true;
         g_auto[i].marketInFlight = false;
         g_auto[i].multiplePositions = (positionCount > 1);
         if(g_auto[i].multiplePositions && !hadMultiple)
            PrintFormat("SimpleEA: %s has multiple same-magic positions; software exits suspended, review manually.", g_rows[i].tag);
         g_auto[i].ticket     = tk;
         g_auto[i].diaryPositionId = livePositionId;
         string posComment = PositionGetString(POSITION_COMMENT);
         g_auto[i].newTradeMarker = (StringFind(posComment, "SEA3_") == 0);
         g_auto[i].legacyTradeMarker = (StringFind(posComment, "SimpleEA_") == 0);
         g_auto[i].dir        = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
         g_auto[i].curLot     = PositionGetDouble(POSITION_VOLUME);
         g_auto[i].entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         g_auto[i].slPrice    = PositionGetDouble(POSITION_SL);
         g_auto[i].tpPrice    = PositionGetDouble(POSITION_TP);
         g_auto[i].profitUSD  = PositionGetDouble(POSITION_PROFIT);
         g_auto[i].residualOrder = CancelEntryRemainders(i);
         if(!wasOpen)
         {
            g_auto[i].fillBar = g_rows[i].lastBar;   // fill noticed on this bar
            if(wasPending) g_auto[i].cancelPending = false;
         }

         if(g_auto[i].slPrice > 0.0)
            g_auto[i].slPts = (int)MathRound(MathAbs(g_auto[i].entryPrice - g_auto[i].slPrice) / point);
         else
            g_auto[i].slPts = 0;
         if(wasOpen)
         {
            if(MathAbs(previousSL - g_auto[i].slPrice) > 0.5 * point ||
               MathAbs(previousTP - g_auto[i].tpPrice) > 0.5 * point)
               RecoverSlotTargets(i, point); // external SL/TP alteration: do not reuse stale ladder
            else
               RefreshSlotTargetDistances(i, point);
         }

         // Recover or transition state when a pending order just filled or EA restarted
         if(!wasOpen)
         {
            if(!wasActive)
               RestoreAutoSlotState(i);
            if(wasPending || g_auto[i].initLot <= 0.0)
               g_auto[i].initLot = g_auto[i].curLot;
            if(g_auto[i].entryScore == 0)
               g_auto[i].entryScore = (g_rows[i].direction == g_auto[i].dir && g_rows[i].score != 0)
                                      ? g_rows[i].score : (g_auto[i].dir * (wasPending ? 2 : 3));

            if(!wasActive || GlobalVariableCheck(AutoGVKey(i, "uv")))
               RecoverSlotTargets(i, point);
            else
               RefreshSlotTargetDistances(i, point);

            // Fixed exits do not derive TP1/TP2 state from the broker SL.
            // Persisted slot flags and the diary retain partial-close state;
            // a fixed SL must never be mistaken for a TP milestone lock.

            if(g_auto[i].lastSignalBar == 0)
               g_auto[i].lastSignalBar = g_rows[i].lastBar;
            DiaryAttachSlotRecord(i);
            if(g_auto[i].modernTargets && SaveAutoSlotState(i))
            {
               DeleteTargetIntent(i);
               DeleteTargetUpdate(i);
            }
         }
         else if(g_auto[i].modernTargets && g_auto[i].diaryPositionId > 0 &&
                 (int)SlotGV(i, "ik") != 2)
         {
            // Promote a market-order/pending identity to its actual position.
            if(SaveAutoSlotState(i)) { DeleteTargetIntent(i); GlobalVariablesFlush(); }
         }
         if(!g_auto[i].residualOrder && (wasPending || hadResidual))
            DiarySetSettledEntryVolume(i);
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

         if(wasOpen || (wasPending && g_auto[i].ticket > 0 && g_auto[i].ticket != tk))
         {
            // A different/remainder order must not inherit the old slot.
            g_diarySuppress[i] = true;
            ResetAutoSlot(i, true);
            g_diarySuppress[i] = false;
            wasActive = false; wasOpen = false; wasPending = false;
         }
         double previousEntry = g_auto[i].entryPrice;
         double previousPendingSL = g_auto[i].slPrice;
         double previousPendingTP = g_auto[i].tpPrice;
         ENUM_ORDER_TYPE otype = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
         foundOrd             = true;
         g_auto[i].active     = true;
         g_auto[i].isOpen     = false;
         g_auto[i].marketInFlight = (otype == ORDER_TYPE_BUY || otype == ORDER_TYPE_SELL);
         g_auto[i].ticket     = tk;
         string ordComment = OrderGetString(ORDER_COMMENT);
         g_auto[i].newTradeMarker = (StringFind(ordComment, "SEA3_") == 0);
         g_auto[i].legacyTradeMarker = (StringFind(ordComment, "SimpleEA_") == 0);
         g_auto[i].dir        = (otype == ORDER_TYPE_BUY || otype == ORDER_TYPE_BUY_LIMIT ||
                                 otype == ORDER_TYPE_BUY_STOP || otype == ORDER_TYPE_BUY_STOP_LIMIT) ? 1 : -1;
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
            g_auto[i].initLot = g_auto[i].curLot;
            if(g_auto[i].entryScore == 0)
               g_auto[i].entryScore = (g_rows[i].direction == g_auto[i].dir && g_rows[i].score != 0)
                                      ? g_rows[i].score : (g_auto[i].dir * 2);
            RecoverSlotTargets(i, point);
            if(g_auto[i].placedBar == 0) g_auto[i].placedBar = g_rows[i].lastBar;
            g_auto[i].lastSignalBar = g_rows[i].lastBar;
            DiaryAttachSlotRecord(i);
         }
         else
         {
            if(GlobalVariableCheck(AutoGVKey(i, "uv")) ||
               MathAbs(previousEntry - g_auto[i].entryPrice) > 0.5 * point ||
               MathAbs(previousPendingSL - g_auto[i].slPrice) > 0.5 * point ||
               MathAbs(previousPendingTP - g_auto[i].tpPrice) > 0.5 * point)
               RecoverSlotTargets(i, point);
            else
               RefreshSlotTargetDistances(i, point);
         }
         break;
      }

      if(!foundOrd && !GlobalVariableCheck(AutoGVKey(i, "iv")) &&
         (wasActive || GlobalVariableCheck(AutoGVKey(i, "lv"))) && BrokerSlotEnded(i, wasActive))
      {
         if(!wasActive) DiaryReconcileOpenRecords();
         ResetAutoSlot(i, true); // history proves the slot ended
      }
      // Otherwise preserve the identity/journal across disconnect or
      // delayed history; an unresolved slot blocks new entries.
   }
}

//+------------------------------------------------------------------+
//  Place the order advised by g_plans[i] (Market at 3/3, Limit at 2/3).
//+------------------------------------------------------------------+
bool PlacePlanOrder(int i)
{
   if(i < 0 || i >= TF_COUNT || !g_freshBar[i]) return(false);
   if(!CanPlaceAutoOrders() || g_auto[i].active || PlanHasUncertainOrder(i)) return(false);
   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING) return(false);
   if(g_plans[i].state != 2 || g_plans[i].dir == 0) return(false);
   if(!TrendMatchForTF(i)) return(false);
   if(!AutoTradingAllowed(i)) return(false);
   if(RegimeBlocksEntry(i)) return(false);
   if(!ScoreAllowsTrade(g_plans[i].dir, g_plans[i].score)) return(false);

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double pv = PointValuePerLot();
   double minStop = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
   int dir = g_plans[i].dir;
   int score = g_plans[i].score;
   bool market = g_plans[i].market;
   double entry = market ? (dir > 0 ? ask : bid) : g_plans[i].entryPrice;
   double sl = g_plans[i].slPrice;
   double tp1 = g_plans[i].tp1Price;
   double tp2 = g_plans[i].tp2Price;
   double tp3 = g_plans[i].tp3Price;
   double lot = g_plans[i].lot;
   if(!PlanPricesValid(dir, market, entry, sl, tp1, tp2, tp3,
                       bid, ask, point, tick, minStop, pv)) return(false);
   int slPts = (int)MathRound((double)dir * (entry - sl) / point);
   if(slPts <= 0 || lot <= 0.0) return(false);
   if(!InpUseMinLot && InpUseRisk)
   {
      double budget = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPct / 100.0 *
                      (MathAbs(score) >= 3 ? RISK_SCORE3_X : 1.0);
      double actualRisk = lot * (double)slPts * pv; // fees not included
      if(budget <= 0.0 || actualRisk > budget * 1.000001) return(false);
   }

   // Persist the intended levels BEFORE sending; a failure to journal
   // cannot be allowed to create an order whose software targets vanish.
   if(!BeginTargetIntent(i, dir, entry, sl, tp1, tp2, tp3)) return(false);
   ulong ticket = 0;
   double filledVolume = lot, filledPrice = entry;
   bool inFlight = false;
   int status = market ? TradeOpenMarket(i, dir, lot, sl, tp3, ticket,
                                         filledVolume, filledPrice, inFlight)
                       : TradePlaceLimit(i, dir, lot, entry, sl, tp3, ticket);
   if(status <= 0)
   {
      if(status == 0) { DeleteTargetIntent(i); GlobalVariablesFlush(); }
      else PrintFormat("SimpleEA: %s order result uncertain; verify broker state before clearing intent.", g_rows[i].tag);
      return(false);
   }
   if(market && !inFlight && filledPrice > 0.0) entry = filledPrice;
   if(market && !inFlight && filledVolume > 0.0) lot = filledVolume;

   g_auto[i].active = true;
   g_auto[i].isOpen = market && !inFlight;
   g_auto[i].marketInFlight = inFlight;
   g_auto[i].ticket = ticket;
   g_auto[i].dir = dir;
   g_auto[i].entryScore = score;
   g_auto[i].initLot = lot;
   g_auto[i].curLot = lot;
   g_auto[i].entryPrice = entry;
   g_auto[i].slPrice = sl;
   g_auto[i].tpPrice = tp3;
   g_auto[i].tp1Price = tp1;
   g_auto[i].tp2Price = tp2;
   g_auto[i].modernTargets = true;
   g_auto[i].legacyRecovery = false;
   g_auto[i].newTradeMarker = true;
   g_auto[i].legacyTradeMarker = false;
   g_auto[i].profitUSD = 0.0;
   g_auto[i].slPts = slPts;
   g_auto[i].tp1Hit = false;
   g_auto[i].tp2Hit = false;
   g_auto[i].tp1Skipped = false;
   g_auto[i].tp2Skipped = false;
   g_auto[i].tp1Short = false;
   g_auto[i].tp2Short = false;
   g_auto[i].isRange = (!market && g_rows[i].mode == 2);
   g_auto[i].rngTop = g_auto[i].isRange ? g_rows[i].rngTop : 0.0;
   g_auto[i].rngBot = g_auto[i].isRange ? g_rows[i].rngBot : 0.0;
   g_auto[i].placedBar = g_rows[i].lastBar;
   g_auto[i].fillBar = market ? g_rows[i].lastBar : 0;
   g_auto[i].lastEvalBar = g_rows[i].lastBar;
   g_auto[i].lastSignalBar = g_rows[i].lastBar;
   RefreshSlotTargetDistances(i, point);
   if(SaveAutoSlotState(i) && !inFlight)
   {
      DeleteTargetIntent(i);
      GlobalVariablesFlush();
   }
   if(!inFlight) DiaryBeginPlacement(i, market, slPts, ask - bid);
   return(true);
}


//+------------------------------------------------------------------+
//  Bar-close autotrading logic:
//    - Open positions keep their original SL/TP and are NOT closed by
//      direction flips, HOLD, score weakening or range-box breaks.
//      TP1/TP2/TP3 handling is performed once per tick in ManageAutoTick().
//    - Waiting pending limits still update or cancel as entry
//      management.  These rules never apply to an already-filled trade.
//    - Flat timeframes retain the existing score-to-order mapping.
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
         double exitP = (g_auto[i].dir > 0) ? bid : ask;
         double favPts = (g_auto[i].dir > 0)
                         ? (exitP - g_auto[i].entryPrice) / point
                         : (g_auto[i].entryPrice - exitP) / point;
         DiaryUpdateOpenSlot(i, favPts, true);

         // Deliberately no open-position order request here.  The entry
         // signal may change freely without moving SL or closing the trade.
         continue;
      }

      // ---- CASE B: Waiting Pending Limit Order ----------------------
      if(g_auto[i].active && !g_auto[i].isOpen)
      {
         int  dir     = g_auto[i].dir;
         if(g_auto[i].cancelPending)
         {
            RequestPendingCancellation(i);
            continue;
         }
         if(g_auto[i].marketInFlight)
            continue; // await broker resolution; it is not a limit to reprice

         // A row that may not open anything cannot keep a waiting order:
         // a pending is still an unfilled NEW entry, whether the row was
         // switched off (InpAutoTradeM5/M15/M30) or vetoed by the Choppy
         // / Mixed permission.  Cancel it on this closed-bar pass instead
         // of refreshing or upgrading it.  An already-open position is
         // handled in CASE A and is untouched by either veto.
         if(!AutoTradingAllowed(i) || RegimeBlocksEntry(i))
         {
            if(RequestPendingCancellation(i))
               g_auto[i].lastSignalBar = g_rows[i].lastBar;
            continue;
         }

         // Timer/pause OFF: a waiting order is an unfilled entry, so
         // cancel it rather than refresh it (it could otherwise fill
         // while new placements are supposed to be paused).
         if(!timerAllowsPlacement)
         {
            if(RequestPendingCancellation(i))
               g_auto[i].lastSignalBar = g_rows[i].lastBar;
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
            if(RequestPendingCancellation(i))
               g_auto[i].lastSignalBar = g_rows[i].lastBar;
            continue;
         }

         // 1) Direction changed / HOLD / trend gate failed / expired -> cancel pending order
         if(!g_rows[i].ok || g_rows[i].direction != dir || !TrendMatchForTF(i) ||
            expired || g_plans[i].state != 2)
         {
            if(RequestPendingCancellation(i))
               g_auto[i].lastSignalBar = g_rows[i].lastBar;
            continue;
         }

         // 2) A stronger score cancels the old limit, but never sends an
         // immediate replacement: it could have partially filled during the
         // delete. A later fresh bar may place after broker reconciliation.
         if(g_plans[i].market)
         {
            if(RequestPendingCancellation(i))
               g_auto[i].lastSignalBar = g_rows[i].lastBar;
            continue;
         }

         // Refresh a waiting order only after the broker accepts its
         // Entry/SL/TP3. A write-ahead journal resolves a restart or a
         // fill that races the modification; the old levels are never
         // overwritten just because a modification was requested.
         double newEntry = g_plans[i].entryPrice;
         double newSL = g_plans[i].slPrice;
         double newTP1 = g_plans[i].tp1Price;
         double newTP2 = g_plans[i].tp2Price;
         double newTP3 = g_plans[i].tp3Price;
         double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
         double minStop = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
         double pv = PointValuePerLot();
         if(!PlanPricesValid(dir, false, newEntry, newSL, newTP1, newTP2, newTP3,
                             bid, ask, point, tick, minStop, pv))
         {
            RequestPendingCancellation(i);
            continue;
         }
         if(!BrokerExitsDiffer(g_auto[i].slPrice, g_auto[i].tpPrice, newSL, newTP3, point))
            continue; // no broker-observable distinction after a fill; keep the old plan
         if(!BeginTargetUpdate(i, newEntry, newSL, newTP1, newTP2, newTP3))
         {
            RequestPendingCancellation(i);
            continue;
         }
         if(TradeModifyOrder(g_auto[i].ticket, newEntry, newSL, newTP3))
         {
            g_auto[i].entryPrice = newEntry;
            g_auto[i].slPrice = newSL;
            g_auto[i].tpPrice = newTP3;
            g_auto[i].tp1Price = newTP1;
            g_auto[i].tp2Price = newTP2;
            g_auto[i].modernTargets = true;
            g_auto[i].slPts = g_plans[i].slPts;
            g_auto[i].isRange = (g_rows[i].mode == 2);
            g_auto[i].rngTop = g_auto[i].isRange ? g_rows[i].rngTop : 0.0;
            g_auto[i].rngBot = g_auto[i].isRange ? g_rows[i].rngBot : 0.0;
            g_auto[i].lastEvalBar = g_rows[i].lastBar;
            g_auto[i].diaryPlanSlPts = g_plans[i].slPts;
            RefreshSlotTargetDistances(i, point);
            if(SaveAutoSlotState(i)) { DeleteTargetUpdate(i); GlobalVariablesFlush(); }
            DiarySyncSlotRecord(i, true);
         }
         else
         {
            // On uncertainty keep the journal. If cancellation is also
            // rejected the next broker sync reconciles whichever levels
            // actually exist, rather than asserting the new ones did.
            PrintFormat("SimpleEA: %s pending modification not confirmed; cancelling if possible.", g_rows[i].tag);
            RequestPendingCancellation(i);
         }
         continue;
      }

      // ---- CASE C: Flat on this timeframe -> check new placement ----
      if(!g_auto[i].active)
      {
         if(timerAllowsPlacement && AutoTradingAllowed(i) &&
            g_rows[i].ok && !RegimeBlocksEntry(i) &&
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

// A milestone is journaled before a close request. An explicit broker
// rejection leaves it retryable; an uncertain/async result is left in
// REVIEW rather than risking a duplicate close. Actual volume reduction
// also reconciles a crash between the broker fill and our persistence.
void StoreMilestone(int i, int stage, double start, double goal, double done, bool awaiting)
{
   if(stage == 1)
   {
      g_auto[i].tp1StartLot = start; g_auto[i].tp1GoalLot = goal;
      g_auto[i].tp1DoneLot = done; g_auto[i].tp1Awaiting = awaiting;
   }
   else
   {
      g_auto[i].tp2StartLot = start; g_auto[i].tp2GoalLot = goal;
      g_auto[i].tp2DoneLot = done; g_auto[i].tp2Awaiting = awaiting;
   }
}

bool ManageMilestone(int i, int stage, bool reached)
{
   if(g_auto[i].ticket == 0 || !PositionSelectByTicket(g_auto[i].ticket)) return(false);
   double liveVolume = PositionGetDouble(POSITION_VOLUME);
   if(liveVolume <= 0.0) return(false);
   g_auto[i].curLot = liveVolume;
   bool hit = stage == 1 ? g_auto[i].tp1Hit : g_auto[i].tp2Hit;
   if(hit) return(false);
   double start = stage == 1 ? g_auto[i].tp1StartLot : g_auto[i].tp2StartLot;
   double goal = stage == 1 ? g_auto[i].tp1GoalLot : g_auto[i].tp2GoalLot;
   double done = stage == 1 ? g_auto[i].tp1DoneLot : g_auto[i].tp2DoneLot;
   bool awaiting = stage == 1 ? g_auto[i].tp1Awaiting : g_auto[i].tp2Awaiting;
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0) step = 0.01;
   double tol = step * 0.25;

   if(goal <= 0.0)
   {
      if(!reached) return(false);
      // Never base TP2 on a stale broker volume after TP1's accepted fill.
      if(stage == 2 && g_auto[i].tp1GoalLot > 0.0 &&
         g_auto[i].curLot > g_auto[i].tp1StartLot - g_auto[i].tp1DoneLot + tol)
         return(false);
      start = g_auto[i].curLot;
      goal = stage == 1 ? CalcTP1CloseLot(start) : CalcTP2CloseLot(start);
      done = 0.0;
      if(goal <= 0.0)
      {
         // There is no valid partial on the broker's lot grid. The level
         // was reached, but no close was claimed or sent.
         if(stage == 1) g_auto[i].tp1Hit = true;
         else g_auto[i].tp2Hit = true;
         SaveAutoSlotState(i);
         return(true);
      }
      StoreMilestone(i, stage, start, goal, done, false);
      if(!SaveAutoSlotState(i)) return(false);
   }
   double observed = MathMax(0.0, start - g_auto[i].curLot);
   done = MathMax(done, observed);
   if(done + tol >= goal)
   {
      StoreMilestone(i, stage, start, goal, done, false);
      if(stage == 1) g_auto[i].tp1Hit = true;
      else g_auto[i].tp2Hit = true;
      SaveAutoSlotState(i);
      return(true);
   }
   if(awaiting || !reached)
   {
      StoreMilestone(i, stage, start, goal, done, awaiting);
      return(false);
   }
   double remaining = FloorLotStep(goal - done);
   double minLot = SymbolMinLot();
   double maximum = FloorLotStep(g_auto[i].curLot - minLot);
   remaining = MathMin(remaining, maximum);
   if(remaining < minLot - tol)
   {
      if(done > tol)
      {
         // A broker partial can leave less than one minimum lot to close.
         // Do not over-close: expose the shortfall and advance the ladder.
         if(stage == 1) { g_auto[i].tp1Short = true; g_auto[i].tp1Hit = true; }
         else { g_auto[i].tp2Short = true; g_auto[i].tp2Hit = true; }
         StoreMilestone(i, stage, start, goal, done, false);
         SaveAutoSlotState(i);
         PrintFormat("SimpleEA: %s TP%d has an uncloseable residual below the broker minimum.",
                     g_rows[i].tag, stage);
         return(true);
      }
      return(false);
   }

   // Persist an in-flight marker first: a crash after the send cannot
   // automatically submit the same close twice.
   StoreMilestone(i, stage, start, goal, done, true);
   if(!SaveAutoSlotState(i)) return(false);
   double executed = 0.0;
   bool uncertain = false;
   int status = TradeClosePosition(g_auto[i].ticket, g_auto[i].dir, remaining,
                                   MagicForTF(i), executed, uncertain);
   if(status == 0) // confirmed rejection: retry when the target is reached
   {
      StoreMilestone(i, stage, start, goal, done, false);
      SaveAutoSlotState(i);
      return(false);
   }
   if(status < 0) // ambiguous transport/async response: wait for review
   {
      PrintFormat("SimpleEA: %s TP%d close result is uncertain; review before retrying.", g_rows[i].tag, stage);
      return(true);
   }
   if(executed > 0.0) done = MathMin(goal, done + executed);
   if(PositionSelectByTicket(g_auto[i].ticket))
   {
      g_auto[i].curLot = PositionGetDouble(POSITION_VOLUME);
      done = MathMax(done, MathMax(0.0, start - g_auto[i].curLot));
   }
   bool wait = uncertain || executed <= 0.0;
   StoreMilestone(i, stage, start, goal, done, wait);
   if(done + tol >= goal)
   {
      if(stage == 1) g_auto[i].tp1Hit = true;
      else g_auto[i].tp2Hit = true;
      StoreMilestone(i, stage, start, goal, done, false);
   }
   SaveAutoSlotState(i);
   return(true);
}


//+------------------------------------------------------------------+
//  Tick-level fixed-exit management.
//
// TP1/TP2 submit staged partial closes on executable Bid/Ask only.
// The original SL and TP3 remain at the broker and are never moved here.
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
      if(prevAct[i] != g_auto[i].active || prevOpen[i] != g_auto[i].isOpen)
         stateChanged = true;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(CanTradeNow() && point > 0.0 && ask > 0.0 && bid > 0.0)
   {
      for(int i = 0; i < TF_COUNT; i++)
      {
         if(!g_auto[i].active) continue;
         int dir = g_auto[i].dir;
         if(!g_auto[i].isOpen)
         {
            if(g_auto[i].marketInFlight)
            {
               // An accepted market request is not a limit to reprice.
               // Only a genuine entry veto asks the broker to cancel it.
               bool veto = (!AutoTradingAllowed(i) ||
                            RegimeBlocksEntry(i) || !AutoTimerAllowsPlacement() ||
                            !g_rows[i].ok || g_rows[i].direction != dir || !TrendMatchForTF(i));
               ulong nowMs = GetTickCount64();
               if((veto || g_auto[i].cancelPending) && nowMs - g_lastSafetyCancelMs[i] >= 2000)
               {
                  g_lastSafetyCancelMs[i] = nowMs;
                  if(RequestPendingCancellation(i)) stateChanged = true;
               }
               continue;
            }
            // A spread spike can invalidate an unfilled scalp before the
            // next bar. Cancel, never silently move its structure level.
            bool missingLevels = (g_auto[i].slPrice <= 0.0 || g_auto[i].tpPrice <= 0.0 ||
                                  g_auto[i].tp1Price <= 0.0 || g_auto[i].tp2Price <= 0.0 ||
                                  (double)dir * (g_auto[i].tp2Price - g_auto[i].tp1Price) < -0.5 * point ||
                                  (double)dir * (g_auto[i].tpPrice - g_auto[i].tp2Price) < -0.5 * point);
            bool planBlocked = (!g_rows[i].ok || g_rows[i].direction != dir ||
                                !AutoTradingAllowed(i) || RegimeBlocksEntry(i) ||
                                !AutoTimerAllowsPlacement() || !TrendMatchForTF(i) ||
                                g_plans[i].state != 2 || g_plans[i].dir != dir);
            if(g_auto[i].cancelPending || missingLevels || planBlocked ||
               (double)dir * (g_auto[i].tp1Price - g_auto[i].entryPrice) <= ask - bid)
            {
               ulong nowMs = GetTickCount64();
               if(nowMs - g_lastSafetyCancelMs[i] >= 2000)
               {
                  g_lastSafetyCancelMs[i] = nowMs;
                  if(RequestPendingCancellation(i)) stateChanged = true;
               }
            }
            continue;
         }

         double exitP = (dir > 0) ? bid : ask; // executable close side
         double favPts = (double)dir * (exitP - g_auto[i].entryPrice) / point;
         DiaryUpdateOpenSlot(i, favPts, false);

         if(g_auto[i].multiplePositions) continue; // single-slot state is ambiguous

         // TP3 is broker-side. When it is crossed, do not manufacture
         // lower partials while that broker exit is being processed.
         if(g_auto[i].tpPrice > 0.0 &&
            (double)dir * (exitP - g_auto[i].tpPrice) >= -0.5 * point) continue;

         bool ordered = (g_auto[i].tp1Price > 0.0 && g_auto[i].tp2Price > 0.0 &&
                         g_auto[i].tpPrice > 0.0 &&
                         (double)dir * (g_auto[i].tp2Price - g_auto[i].tp1Price) >= -0.5 * point &&
                         (double)dir * (g_auto[i].tpPrice - g_auto[i].tp2Price) >= -0.5 * point);
         if(!ordered || g_auto[i].residualOrder) continue; // wait for entry remainder cancellation

         if(!g_auto[i].tp1Hit && !g_auto[i].tp1Skipped &&
            (double)dir * (g_auto[i].tp1Price - g_auto[i].entryPrice) <= 0.0)
         {
            g_auto[i].tp1Skipped = true;
            SaveAutoSlotState(i);
            stateChanged = true;
            PrintFormat("SimpleEA: %s TP1 skipped because the actual fill was at/beyond it.", g_rows[i].tag);
         }
         if(!g_auto[i].tp2Hit && !g_auto[i].tp2Skipped &&
            (double)dir * (g_auto[i].tp2Price - g_auto[i].entryPrice) <= 0.0)
         {
            g_auto[i].tp2Skipped = true;
            SaveAutoSlotState(i);
            stateChanged = true;
            PrintFormat("SimpleEA: %s TP2 skipped because the actual fill was at/beyond it.", g_rows[i].tag);
         }
         if(!g_auto[i].tp1Skipped && !g_auto[i].tp1Hit)
         {
            bool reached = ((double)dir * (exitP - g_auto[i].tp1Price) >= -0.5 * point);
            if(ManageMilestone(i, 1, reached))
            {
               stateChanged = true;
               continue; // wait for a fresh broker volume before TP2
            }
         }
         if((g_auto[i].tp1Hit || g_auto[i].tp1Skipped) &&
            !g_auto[i].tp2Skipped && !g_auto[i].tp2Hit)
         {
            bool reached = ((double)dir * (exitP - g_auto[i].tp2Price) >= -0.5 * point);
            if(ManageMilestone(i, 2, reached)) stateChanged = true;
         }
      }
      SyncAutoState();
      for(int i = 0; i < TF_COUNT; i++)
         if(prevAct[i] != g_auto[i].active || prevOpen[i] != g_auto[i].isOpen)
            stateChanged = true;
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
                       : (g_auto[i].marketInFlight ? "MARKET PENDING" :
                          ((dir > 0) ? "BUY LIMIT" : "SELL LIMIT"));

      if(g_auto[i].residualOrder) kindTxt += " + ENTRY REMAINDER";
      if(g_auto[i].multiplePositions) kindTxt += " + MULTIPLE: REVIEW";
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

      // TP1/TP2 are the frozen absolute software levels, not a
      // reconstruction from TP3 or the potentially slipped fill price.
      double tp1Price = g_auto[i].tp1Price;
      double tp2Price = g_auto[i].tp2Price;
      double tp3Price = g_auto[i].tpPrice;
      string state1 = g_auto[i].tp1Skipped ? " [SKIP]" :
                      (g_auto[i].tp1Short ? " [PART]" :
                       (g_auto[i].tp1Hit ? " [HIT]" : (g_auto[i].tp1Awaiting ? " [REVIEW]" : "")));
      string state2 = g_auto[i].tp2Skipped ? " [SKIP]" :
                      (g_auto[i].tp2Short ? " [PART]" :
                       (g_auto[i].tp2Hit ? " [HIT]" : (g_auto[i].tp2Awaiting ? " [REVIEW]" : "")));
      g_auto[i].lbl[1][0] = "TP1:";
      g_auto[i].val[1][0] = (tp1Price > 0.0) ? DoubleToString(tp1Price, dg) + state1 : "-- (unavailable)";
      g_auto[i].clr[1][0] = tp1Price > 0.0 ? InpBuyColor : InpSellColor;
      g_auto[i].lbl[1][1] = "TP2:";
      g_auto[i].val[1][1] = (tp2Price > 0.0) ? DoubleToString(tp2Price, dg) + state2 : "-- (unavailable)";
      g_auto[i].clr[1][1] = tp2Price > 0.0 ? InpBuyColor : InpSellColor;
      g_auto[i].lbl[2][0] = "TP3:";
      g_auto[i].val[2][0] = (tp3Price > 0.0) ? DoubleToString(tp3Price, dg) : "-- (missing)";
      g_auto[i].clr[2][0] = tp3Price > 0.0 ? InpBuyColor : InpSellColor;

      g_auto[i].lbl[2][1] = "SL:";
      if(g_auto[i].slPrice > 0.0 && point > 0.0)
      {
         int    slPtsNow    = (int)MathRound(MathAbs(g_auto[i].entryPrice - g_auto[i].slPrice) / point);
         double slUSD       = (pv > 0.0) ? lot * (double)slPtsNow * pv : 0.0;
         bool   slProtected = (g_auto[i].isOpen &&
                               ((double)dir * (g_auto[i].slPrice - g_auto[i].entryPrice) >= -0.5 * point));
         g_auto[i].val[2][1] = StringFormat("%s (%s %s est)",
                                            DoubleToString(g_auto[i].slPrice, dg), DoubleToString(slUSD, 2), cur);
         g_auto[i].clr[2][1] = slProtected ? InpBuyColor : InpSellColor;
      }
      else
      {
         // New orders always have an SL; this warns about a legacy or
         // externally altered position without modifying it after entry.
         g_auto[i].val[2][1] = "-- (missing)";
         g_auto[i].clr[2][1] = InpSellColor;
      }

      // ---- Line 3: Status / Waiting distance & LIVE gap to TP1/TP2/TP3
      //  The Distance cell counts down in realtime: how far the live
      //  close-side price still is from the next target (TP1 -> TP2 ->
      //  TP3 as each one is hit), not the frozen entry->TP distance.
      bool next1 = !g_auto[i].tp1Hit && !g_auto[i].tp1Skipped && tp1Price > 0.0;
      bool next2 = !g_auto[i].tp2Hit && !g_auto[i].tp2Skipped && tp2Price > 0.0;
      string nextTpTag = next1 ? "TP1" : (next2 ? "TP2" : "TP3");
      double nextTpPrice = next1 ? tp1Price : (next2 ? tp2Price : tp3Price);

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
      int gapPts = (point > 0.0 && liveP > 0.0 && nextTpPrice > 0.0)
                   ? (int)MathRound(MathAbs(nextTpPrice - liveP) / point) : 0;
      g_auto[i].val[3][1] = nextTpPrice > 0.0
                            ? StringFormat("to %s %d pts", nextTpTag, gapPts) : "-- (missing)";
      g_auto[i].clr[3][1] = InpBuyColor;

      // ---- fixed exit policy and cost-estimate disclosure ------------
      g_auto[i].lbl[3][2] = "Exit:";
      g_auto[i].val[3][2] = "TP/SL; fees excluded";
      g_auto[i].clr[3][2] = clrSilver;
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
//  The label the row is acting on, with its source named.  A borrowed
//  label must never be mistaken for the row's own reading - "Choppy<-M15"
//  says both things at once, so the panel can never overstate what M5
//  measured for itself.
string RegimeText(int idx)
{
   string base = "Mixed";
   if(g_rows[idx].regime == 1)            base = "Steady";
   else if(g_rows[idx].regime == 2)       base = "Choppy";
   else if(g_rows[idx].regime < 0)
   {
      //  Not evaluated yet - fall back to the raw Hurst so the very first
      //  paint still shows something meaningful.
      if(g_rows[idx].hurst > g_rows[idx].hTrend)       base = "Steady";
      else if(g_rows[idx].hurst < g_rows[idx].hRevert) base = "Choppy";
   }
   if(g_rows[idx].regimeSrc >= 0)
      return(base + "<-" + g_rows[g_rows[idx].regimeSrc].tag);
   return(base);
}

//+------------------------------------------------------------------+
color RegimeColor(int idx)
{
   int g = g_rows[idx].regime;
   if(g < 0)
   {
      if(g_rows[idx].hurst > g_rows[idx].hTrend)       g = 1;
      else if(g_rows[idx].hurst < g_rows[idx].hRevert) g = 2;
      else                                             g = 0;
   }
   if(g == 1) return(clrDeepSkyBlue);
   if(g == 2) return(clrOrange);
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
         //  Greyed out for any reason a new order would be refused: the
         //  row is switched off, or the regime permission vetoes it.  The
         //  would-be direction stays on screen either way - that is useful
         //  information, and an open trade still needs it for management.
         bool greyed = (!AutoTradingAllowed(i) || RegimeBlocksEntry(i));
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

   //  "Choppy" (6 chars) used to be the widest thing a regime cell could
   //  hold; a borrowed label now reads "Choppy<-M15" (11), so the width is
   //  measured from what is actually on screen instead of assumed.
   int wB = 6 * em;
   for(int i = 0; i < TF_COUNT; i++)
      wB = (int)MathMax(wB, StringLen(RegimeText(i)) * em);
   for(int i = 0; i < TF_COUNT; i++)
      for(int l = 0; l < g_plans[i].lines; l++)
         if(g_plans[i].lbl[l][1] != "")
            wB = (int)MathMax(wB, StringLen(g_plans[i].val[l][1]) * em);

   cC = (int)MathMax(ColX(PLAN_COL_C), vB + wB + em * 2);
   vC = cC + em * PLAN_LBL_C;
}

//+------------------------------------------------------------------+
//  Full plans and indicative held prices use four lines; a HOLD without
//  a displayable structure or a waiting block uses one. The panel height
//  follows the content.
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
// Draw the per-timeframe entry, targets, observation count, estimated
// staged reward and risk. A HOLD can show indicative non-tradable prices.
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

      // ---- one-liner for a HOLD without a preview or waiting block ---
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
                  + (StringLen("| Exits : TP/SL") + 1
                     + StringLen("| Stoploss : ") + 7 + 2
                     + StringLen("|  " + _Symbol)) * em + 10;
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

   bool slOn = AllActiveStopsPresent();
   int  em     = CharW(InpFontSize);
   int  titleW = 11 * CharW(InpFontSize + 1);

   MakeAutoLabel("title", x2 + pad, y2 + 7, "Autotrading",
                 InpTitleColor, InpFontSize + 1, false);
   int exitCapX = x2 + pad + titleW + em;
   string exitCap = "| Exits : ";
   MakeAutoLabel("exitCap", exitCapX, y2 + 8, exitCap,
                 clrSilver, InpFontSize, false);
   int exitValX = exitCapX + StringLen(exitCap) * em;
   MakeAutoLabel("exitVal", exitValX, y2 + 8, "TP/SL",
                 InpTitleColor, InpFontSize, false);
   int slCapX = exitValX + 6 * em;
   string slCap = "| Stoploss : ";
   MakeAutoLabel("slCap", slCapX, y2 + 8, slCap,
                 clrSilver, InpFontSize, false);
   int slValX = slCapX + StringLen(slCap) * em;
   MakeAutoLabel("slVal", slValX, y2 + 8, slOn ? "Fixed" : "Missing",
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
//  split, the health of its newest closed trades, the fixed-exit
//  policy, and the first fix that health suggests.  It sits opposite
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

      lines[base + 4] =
         "  Exits: TP1 partial | TP2 partial | TP3 full | fixed broker SL";
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
