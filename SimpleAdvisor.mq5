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
//|  READ-ONLY.  This program contains no OrderSend / CTrade / trade  |
//|  calls of any kind.  It cannot place, modify or close an order.   |
//|  It only reads price history and draws text on the chart.         |
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
//|   3. REGIME     Rolling Hurst exponent (long-memory estimate).    |
//|                 Part 2: the regime does not merely abstain - it   |
//|                 PICKS THE GAME each row plays:                    |
//|                   Steady (H > threshold) : the trend is real,     |
//|                                            vote with the trend.   |
//|                   Choppy (H < revert)    : moves come back -      |
//|                                            play the range box.    |
//|                   Mixed  (in between)    : no edge either way,    |
//|                                            stand aside (says why).|
//|                 It stops the panel from making confident calls    |
//|                 when the market has no directional memory.        |
//|                                                                  |
//|  Score = vote1 + vote2 + vote3      (range -3 .. +3)              |
//|      BUY  if score >= +2                                          |
//|      SELL if score <= -2                                          |
//|      HOLD otherwise (and the plan block says WHY - mixed, dead     |
//|                      market, or a chop gate that did not clear)    |
//|  A Choppy row never reaches +3: the regime adds no trend vote in   |
//|  the range game - it trades through the box gates instead.         |
//|                                                                  |
//|  Kaufman's Efficiency Ratio acts as a dead-market gate: below     |
//|  InpERDead the market is not travelling anywhere, so any          |
//|  directional read is meaningless and the row is forced to HOLD    |
//|  with "dead market - nothing moves" on the plan block.            |
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
//|     SimpleEA | Incompatible chart. Switch to M5/M15/M30.          |
//|                                                                   |
//|  -----------------------------------------------------------------|
//|  TRADE PLAN (advice only - NO ORDER IS EVER SENT)                 |
//|  -----------------------------------------------------------------|
//|  Under the three timeframe rows, separated by one line, comes a     |
//|  SECOND GROUP with one block per timeframe - M5, M15, M30 - in the  |
//|  same two-column style as the first: where to enter (market or      |
//|  pending, decided by the score), the lot size, the stop and the     |
//|  target (price, points, money and a rough bar count), and how many  |
//|  bars the reading is worth acting on. A HOLD or waiting timeframe   |
//|  takes a single line, so the group is only as tall as its content.  |
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
//|   - Market order at score 3/3; Pending Limit order at score 2/3.  |
//|   - M5 trades its own signal directly; M15 and M30 require their  |
//|     trends (Going up / Going down) to match before placing.       |
//|   - Three take-profit levels per order:                           |
//|        TP3 = 100% of SimpleEA's advised target points             |
//|        TP2 = 25% less than TP3 (75% of TP3)                       |
//|        TP1 = 25% less than TP2 (75% of TP2 = 56.25% of TP3)       |
//|   - Market order management:                                      |
//|        TP1 hit -> moves SL to Entry (Break-Even, Trailstop ACTIVE)|
//|                   and closes 70% of lot (if lot > min lot).       |
//|                   Watches score/direction: if score weakens or    |
//|                   flips, closes immediately; if strong, holds.    |
//|        TP2 hit -> reduces remaining lot to min lot (if > min lot) |
//|                   and locks SL to TP1; continues watching score.  |
//|        TP3 hit -> closes order in full.                           |
//|        Before TP1 -> if timeframe drops to HOLD while in profit,  |
//|                   closes immediately; if opposite signal, closes. |
//|        New candle (same direction) -> updates TP1/TP2/TP3 and     |
//|                   tightens SL (never widens past initial risk).   |
//|   - Pending order management:                                     |
//|        New candle (same direction, score 2/3) -> updates Entry,   |
//|                   SL and TP1/TP2/TP3 to the new plan.             |
//|        Score upgrades to 3/3 (same direction) -> deletes pending  |
//|                   limit order and opens Market order immediately. |
//|        Direction changes / HOLD / expiry -> cancels pending.      |
//|   - Second Panel ("Autotrading", right or bottom of Main Panel):  |
//|        Controlled by InpAutoPanelPos (Right default, or Bottom).  |
//|        Opens automatically when any market/pending order exists   |
//|        and closes completely when flat.                           |
//|        Header shows: Autotrading | Trailstop On/Off | Stoploss    |
//|        On/Off | Symbol.                                           |
//|        Each card shows TP1/TP2/TP3/SL prices (with USD) and       |
//|        Distance from open price to TP1 -> TP2 -> TP3.             |
//|  -----------------------------------------------------------------|
//|  HONEST NOTE ON EXPECTATION                                       |
//|  -----------------------------------------------------------------|
//|  This panel is a structured, low-lag reading of trend, momentum   |
//|  and regime.  It is NOT a proven profitable system.  Independent  |
//|  testing of direction signals on liquid FX shows hit rates close  |
//|  to 50%, and on M5 the typical edge is smaller than a retail      |
//|  spread.  The regime column is the part that carries real         |
//|  information: it tells you when NOT to act.  See ReadMe.md.       |
//+------------------------------------------------------------------+
#property copyright "SimpleEA"
#property version   "2.00"
#property description "Multi-timeframe BUY/SELL/HOLD direction panel, trade plan and full-auto executor. M5 / M15 / M30 charts only."

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
input group "=== Autotrading ==="
input bool                InpAutoTrading  = true;            // Autotrading (true = full auto, false = read-only)
input bool                InpUseStopLoss  = true;            // Stoploss (true = place initial SL, false = only at BE after TP1)
input ENUM_AUTO_PANEL_POS InpAutoPanelPos = AUTO_POS_RIGHT;  // Right panel placement (Right or Bottom)
input long                InpMagicBase    = 202610;          // Base magic number (+0 M5, +1 M15, +2 M30)
input int                 InpSlippagePts  = 20;              // Max slippage in points for market orders

input group "=== Panel appearance ==="
input int      InpPanelX      = 12;          // Panel X offset (px)
input int      InpPanelY      = 24;          // Panel Y offset (px)
input int      InpFontSize    = 9;           // Font size
input string   InpFont        = "Consolas";  // Font (monospaced aligns best)
input color    InpBgColor     = C'18,18,24'; // Panel background
input color    InpTitleColor  = clrWhite;    // Title colour
input color    InpBuyColor    = clrLime;     // "Going up" colour
input color    InpSellColor   = clrTomato;   // "Going down" colour
input color    InpHoldColor   = clrSilver;   // "Sideways" colour

input group "=== Signal thresholds ==="
input int      InpBuyScore    = 2;           // Score >= this  => BUY
input int      InpSellScore   = -2;          // Score <= this  => SELL
input int      InpBarsToLoad  = 700;         // Closed bars pulled per timeframe

input group "=== Trade plan & sizing ==="
input bool     InpShowPlan     = true;       // Show the trade plan block
input bool     InpUseRisk      = true;       // Size by RISK % of balance (false = balance+score ladder)
input bool     InpUseMinLot    = false;      // Always advise the symbol's minimum lot
input double   InpRiskScore2   = 0.5;        // Risk % when score is 2 (risk mode)
input double   InpRiskScore3   = 1.0;        // Risk % when score is 3 (risk mode)
input double   InpBalPer001    = 1000.0;     // Risk-off mode: balance per 0.01 lot
input double   InpScore3Factor = 1.5;        // Risk-off mode: lot multiplier at score 3
input int      InpATRPeriod    = 14;         // ATR period (closed bars, chart timeframe)
//  Stop and target are set PER TIMEFRAME, so the three styles are told
//  apart by their aim: a scalp aims near and quick, an intraday trade
//  aims far and lets the move run.  R:R = target / stop (0.9 / 1.5 / 2.0).
input double   InpSLATR_M5     = 1.0;        // M5 scalp:       stop   = this many ATR
input double   InpTPATR_M5     = 0.9;        // M5 scalp:       target = this many ATR (R:R 1:0.9)
input double   InpSLATR_M15    = 1.2;        // M15 short-term: stop   = this many ATR
input double   InpTPATR_M15    = 1.8;        // M15 short-term: target = this many ATR (R:R 1:1.5)
input double   InpSLATR_M30    = 1.5;        // M30 intraday:   stop   = this many ATR
input double   InpTPATR_M30    = 3.0;        // M30 intraday:   target = this many ATR (R:R 1:2.0)
input double   InpPendATR      = 0.5;        // Pending entry offset = this many ATR
input int      InpValidBars    = 3;          // Signal validity in bars (see research/HORIZON.md)

input group "=== Shared engine settings ==="
input int      InpHurstWindow = 256;         // Hurst estimate window (bars)
input int      InpERPeriod    = 20;          // Kaufman efficiency-ratio period
input double   InpERDead      = 0.10;        // Efficiency below this => dead market, force HOLD

input group "=== Range mode (choppy markets) ==="
//  Part 2: the regime now DECIDES instead of abstaining.  Steady rows
//  play the trend game as before; Choppy rows (H below the revert
//  threshold - moves genuinely come back) play the RANGE game: entry at
//  the box band, target at the box midpoint, stop beyond the band.  All
//  numbers below are gates, not guesses - every one must pass or the
//  row stands aside and the plan block says why.
input bool     InpRangeMode    = true;       // Range mode: trade the box when choppy (default ON)
input int      InpRangeBars    = 20;         // Range box = last N closed bars
input double   InpRangeMinATR  = 2.0;        // Box must be at least this many ATR tall
input double   InpRangeSpreadX = 3.0;        // Half-box target must be >= this many spreads
input double   InpRangeERMax   = 0.40;       // Efficiency above this => a trend, not a box
input double   InpRangeSLATR   = 1.0;        // Range stop = band + this many ATR

input group "=== M5 engine (scalping) ==="
input int      InpL1_M5          = 150;      // Trend filter long period
input int      InpL2_M5          = 24;       // Trend filter short period
input double   InpHurstTrendM5   = 0.55;     // H above this = persistent regime
input double   InpHurstRevertM5  = 0.45;     // H below this = anti-persistent regime

input group "=== M15 engine (short-term) ==="
input int      InpL1_M15         = 150;
input int      InpL2_M15         = 24;
input double   InpHurstTrendM15  = 0.55;
input double   InpHurstRevertM15 = 0.45;

input group "=== M30 engine (intraday) ==="
input int      InpL1_M30         = 150;
input int      InpL2_M30         = 24;
input double   InpHurstTrendM30  = 0.55;
input double   InpHurstRevertM30 = 0.45;

//==================================================================
//  INTERNALS
//==================================================================
#define OBJ_PREFIX  "SA_"
#define AUTO_PREFIX "SA2_"
#define TF_COUNT    3
#define TF_TEXT     "M5/M15/M30"
#define HEAD_H      34     // height of the header band (title + symbol line)
#define PLAN_W_MIN  406    // panel width with no plan showing
#define PLAN_LINES  3      // lines an ACTIVE timeframe uses (1 for HOLD)
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
#define AUTO_COL_A  150    // first cell column in the 2nd Panel
#define AUTO_COL_B  320    // second cell column in the 2nd Panel
#define AUTO_COL_C  480    // third cell column in the 2nd Panel
#define AUTO_LBL_A  9      // label width in chars for Col A ("Waiting: ")
#define AUTO_LBL_B  11     // label width in chars for Col B ("Distance: ")
#define AUTO_LBL_C  5      // label width in chars for Col C ("Ask: " / "Bid: ")

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
   // ---- Part 2: the regime's decision, per row -----------------------
   int            mode;       // 0 stand aside, 1 trend game, 2 range game (only set when dir != 0)
   string         blockReason;// why this row is not trading ("" = quiet or no reason)
   double         rngTop;     // range box: upper band (valid while mode == 2)
   double         rngBot;     // range box: lower band (valid while mode == 2)
   double         lastClose;  // close of the last closed bar (box-kill checks)
   // ---- refreshed every evaluation ----
   int            score;      // -3 .. +3
   int            direction;  // +1 buy, -1 sell, 0 hold
   double         hurst;      // regime estimate
   double         er;         // efficiency ratio
   bool           ok;         // data available?
   datetime       lastBar;    // last closed bar we have seen
};

SRow g_rows[TF_COUNT];

int  g_panelW  = 406;   // wide enough for the header + the notice line
int  g_panelH  = 130;   // height of the full panel (recomputed in OnInit)
int  g_rowH    = 20;
bool g_panelOK = false; // what is currently drawn: false = notice only

ENUM_TIMEFRAMES g_drawnTf = (ENUM_TIMEFRAMES)0;  // timeframe the header was drawn for

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
   g_rows[i].hurst      = 0.5;
   g_rows[i].er         = 0.0;
   g_rows[i].mode       = 0;
   g_rows[i].blockReason = "";
   g_rows[i].rngTop     = 0.0;
   g_rows[i].rngBot     = 0.0;
   g_rows[i].lastClose  = 0.0;
   g_rows[i].ok         = false;
   g_rows[i].lastBar    = 0;
}

//+------------------------------------------------------------------+
int OnInit()
{
   ConfigureRow(0, PERIOD_M5,  "M5",  "Scalp",      InpL1_M5,  InpL2_M5,
                InpHurstTrendM5,  InpHurstRevertM5,  InpSLATR_M5,  InpTPATR_M5);
   ConfigureRow(1, PERIOD_M15, "M15", "Short-term", InpL1_M15, InpL2_M15,
                InpHurstTrendM15, InpHurstRevertM15, InpSLATR_M15, InpTPATR_M15);
   ConfigureRow(2, PERIOD_M30, "M30", "Intraday",   InpL1_M30, InpL2_M30,
                InpHurstTrendM30, InpHurstRevertM30, InpSLATR_M30, InpTPATR_M30);

   if(InpL1_M5 < InpL2_M5 || InpL1_M15 < InpL2_M15 || InpL1_M30 < InpL2_M30)
   {
      Print("SimpleEA: the long trend period must be greater than the short one. ",
            "Set L1 > L2 for every timeframe.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   g_rowH   = InpFontSize + 11;
   // Each timeframe takes TWO lines: Trend/Regime on the first,
   // Signal (BUY/SELL/HOLD)/Score on the second.
   //  height is only provisional here: DrawSupportedPanel() recomputes it
   //  because the second group's height depends on how many timeframes
   //  actually have a signal.
   g_panelH = HEAD_H + TF_COUNT * 2 * g_rowH + 8;

   //  The notice is the one line that must always be readable in full, so
   //  the width that line needs is a floor for BOTH panels - the normal one
   //  and the notice one - whatever the font size.
   g_panelW = NoticeWidth();

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
   else
   {
      EvaluateAll();
      UpdatePlan();
      ManageAutoBar();
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
   DeletePanel();
}

//+------------------------------------------------------------------+
void OnTick()
{
   //  Goes through CheckNewBars() even on an unsupported chart, so that a
   //  live timeframe change is caught whether or not MetaTrader re-started
   //  the EA for it.  On a wrong chart that call costs one comparison.
   CheckNewBars();

   //  Real-time tick checks for TP1/TP2/TP3 partial closes, break-even SL,
   //  and live Ask/Bid/P&L updates on the 2nd Panel.
   if(ChartSupported() && g_panelOK)
      ManageAutoTick();
}

//+------------------------------------------------------------------+
void OnTimer()
{
   CheckNewBars();
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

   bool need = false;

   for(int i = 0; i < TF_COUNT; i++)
   {
      datetime closedBar = LastClosedBarTime(_Symbol, g_rows[i].tf);
      if(closedBar != g_rows[i].lastBar)
      {
         need = true;
         break;
      }
   }

   //  Coming back onto M5/M15/M30 after an unsupported timeframe: rebuild
   //  from the current data instead of showing whatever was last computed.
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
      UpdateAutoPanel();
      DrawPanel();
      ChartRedraw(0);
   }
}

//+------------------------------------------------------------------+
//  Time of the most recently CLOSED bar on a timeframe, or 0 if unknown.
//+------------------------------------------------------------------+
datetime LastClosedBarTime(string sym, ENUM_TIMEFRAMES tf)
{
   datetime times[];
   if(CopyTime(sym, tf, 0, 2, times) == 2)
      return(times[1]);
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
//  COMPONENT 3 : ROLLING HURST EXPONENT
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
         g_rows[r].mode         = 0;
         g_rows[r].blockReason  = "";
         g_rows[r].rngTop       = 0.0;
         g_rows[r].rngBot       = 0.0;
         g_rows[r].lastClose    = 0.0;
         g_rows[r].lastBar      = 0;
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

   int want = MathMax(InpBarsToLoad, InpHurstWindow + 50);
   if(!LoadClosed(_Symbol, g_rows[idx].tf, want, c, h, l))
   {
      g_rows[idx].ok           = false;
      g_rows[idx].score        = 0;
      g_rows[idx].direction    = 0;
      g_rows[idx].mode         = 0;
      g_rows[idx].blockReason  = "";
      g_rows[idx].rngTop       = 0.0;
      g_rows[idx].rngBot       = 0.0;
      g_rows[idx].lastClose    = 0.0;
      return;
   }

   int n    = ArraySize(c);
   int last = n - 1;                               // most recently CLOSED bar

   // ---- fresh state: nothing may leak from the previous bar --------
   g_rows[idx].mode        = 0;
   g_rows[idx].blockReason = "";
   g_rows[idx].rngTop      = 0.0;
   g_rows[idx].rngBot      = 0.0;
   g_rows[idx].lastClose   = c[last];

   // ---- components 1 and 2 : trend and momentum -------------------
   double trend[], roc[];
   PrecisionTrend(c, g_rows[idx].l1, g_rows[idx].l2, trend, roc);

   int v1 = (trend[last] > 0.0) ? 1 : ((trend[last] < 0.0) ? -1 : 0);
   int v2 = (roc[last]   > 0.0) ? 1 : ((roc[last]   < 0.0) ? -1 : 0);

   // ---- component 3 : regime - and the decision it drives (Part 2) --
   //  The regime no longer merely abstains from the vote; it picks the
   //  game this row plays:
   //     Steady  (H > hTrend)  -> the TREND game (score gates as before)
   //     Choppy  (H < hRevert) -> the RANGE game (box gates below)
   //     Mixed   (in between)  -> stand aside: nothing is calculable
   //  Each row uses ITS OWN timeframe's eyes - M5's chop never touches
   //  M15/M30 and vice versa.
   double H  = HurstExponent(c, last, InpHurstWindow);
   double ER = EfficiencyRatio(c, last, InpERPeriod);

   int v3   = 0;
   int mode = 0;                          // 0 stand aside | 1 trend game | 2 range game
   if(H > g_rows[idx].hTrend)
   {
      mode = 1;                           // Steady: back the trend
      v3   = v1;
   }
   else if(H < g_rows[idx].hRevert)
   {
      mode = 2;                           // Choppy: moves revert - the range game
      v3   = 0;
   }
   else
      g_rows[idx].blockReason = "mixed — no edge either way";   // no memory: nothing to compute

   int score = v1 + v2 + v3;              // range mode never reaches 3: v3 stays 0

   // ---- the decision -----------------------------------------------
   int dir = 0;
   if(ER < InpERDead)
   {
      mode = 0;
      g_rows[idx].blockReason = "dead market — nothing moves";
   }
   else if(mode == 1)
   {
      if(score >= InpBuyScore)       dir = 1;
      else if(score <= InpSellScore) dir = -1;
      // quiet trend (|score| below the gate): no reason, "nothing to place"
   }
   else if(mode == 2)
   {
      if(!InpRangeMode)
         g_rows[idx].blockReason = "chop — range mode is off";
      else
      {
         // ---- the box: actual highs and lows of the last N closed bars
         int    nb   = MathMax(5, InpRangeBars);
         int    from = MathMax(0, n - nb);
         double top  = -DBL_MAX;
         double bot  =  DBL_MAX;
         for(int k = from; k <= last; k++)
         {
            if(h[k] > top) top = h[k];
            if(l[k] < bot) bot = l[k];
         }
         double atr    = ATRClosed(g_rows[idx].tf, InpATRPeriod);
         double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double spread = ask - bid;
         double mid    = 0.5 * (top + bot);
         double half   = 0.5 * (top - bot);       // the target: band -> midpoint

         string why = "";
         if(atr <= 0.0 || spread < 0.0 || n < nb || top <= bot)
            why = "chop — no valid box yet";      // data or geometry not there
         else if(top - bot < InpRangeMinATR * atr)
            why = "chop — no valid box yet";      // box too flat to trade
         else if(ER >= InpRangeERMax)
            why = "chop — no valid box yet";      // it is a walk, not a box
         else if(bid > top || bid < bot)
            why = "chop — no valid box yet";      // price broke the box
         else if(half < InpRangeSpreadX * spread)
            why = "chop — nothing clears the spread";   // the cost gate

         if(why != "")
            g_rows[idx].blockReason = why;
         else
         {
            g_rows[idx].rngTop = top;
            g_rows[idx].rngBot = bot;
            dir = (bid > mid) ? -1 : +1;          // upper half: fade down from the top band
         }
      }
      if(dir == 0) mode = 0;                      // a failed gate means: stand aside
   }

   g_rows[idx].ok        = true;
   g_rows[idx].score     = score;
   g_rows[idx].direction = dir;
   g_rows[idx].mode      = (dir != 0) ? mode : 0;
   g_rows[idx].hurst     = H;
   g_rows[idx].er        = ER;

   //  Remember the bar this reading came from, so CheckNewBars() can tell
   //  a genuinely new closed bar from a tick on the bar it already scored
   //  (without this the panel re-read all three timeframes on every tick).
   g_rows[idx].lastBar   = LastClosedBarTime(_Symbol, g_rows[idx].tf);
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
//  Entry type is decided by the score, not by the user:
//     score 3/3  -> all three components agree -> MARKET entry
//     score 2/3  -> two of three agree        -> PENDING (wait for a better price)
//  In the range game (Choppy rows) it is ALWAYS a limit at the opposite
//  band of the box - the box decides the entry, the score has no say,
//  and the target is half the box (band -> midpoint), never a wish.
//  (Measured behaviour of both is in research/HORIZON.md; the pending price
//   is one InpPendATR step beyond the market, which is the only place in
//   this block where a choice - not a measurement - is being made.)
//+------------------------------------------------------------------+
//  ONE PLAN PER TIMEFRAME.  The second group is three blocks, one for M5,
//  one for M15, one for M30 - because when autotrading arrives the panel
//  has to be able to say "buy M5, sell M30" and the executor acts per row.
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
      //  Part 2: the row says WHY it stands aside; a quiet row keeps
      //  the classic "nothing to place".
      g_plans[i].note  = (g_rows[i].blockReason != "") ? g_rows[i].blockReason
                                                       : "nothing to place";
      return;
   }

   double atr   = ATRClosed(g_rows[i].tf, InpATRPeriod);
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
   bool   isRange    = (g_rows[i].mode == 2);               // Part 2: this row plays the range game
   bool   market     = (!isRange && MathAbs(score) >= 3);   // 3 of 3 -> trade now (range is always a limit)
   bool   isOpenNow  = (g_auto[i].active && g_auto[i].isOpen && g_auto[i].dir == dir &&
                        g_auto[i].entryPrice > 0.0);
   bool   isPendNow  = (g_auto[i].active && !g_auto[i].isOpen && g_auto[i].dir == dir &&
                        g_auto[i].entryPrice > 0.0);
   double entry      = (dir > 0) ? ask : bid;
   double offset     = InpPendATR * atr;
   double pend       = ValidLimitPrice(dir, (dir > 0) ? (entry - offset) : (entry + offset),
                                       bid, ask, point);
   double planEntry  = market ? entry : pend;

   // ---- stop and target ---------------------------------------------
   //  Trend rows keep the per-timeframe ATR profiles (scalp aims near,
   //  intraday aims far).  Range rows are pure box geometry: entry at
   //  the OPPOSITE band, stop = band + InpRangeSLATR ATR, target =
   //  half the box (band -> midpoint).  Neither is ever shrunk by hand.
   int slPts, tpPts;
   if(isRange)
   {
      planEntry = ValidLimitPrice(dir, (dir > 0) ? g_rows[i].rngBot : g_rows[i].rngTop,
                                  bid, ask, point);
      slPts = (int)MathMax(1.0, MathRound(InpRangeSLATR * atr / point));
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
      double pct = (MathAbs(score) >= 3) ? InpRiskScore3 : InpRiskScore2;
      wantRisk   = balance * pct / 100.0;
      if(pv > 0.0 && slPts > 0)
         lots = wantRisk / ((double)slPts * pv);
   }
   else
   {
      double step = (InpBalPer001 > 0.0) ? InpBalPer001 : 1000.0;
      lots = (balance / step) * 0.01;
      if(MathAbs(score) >= 3) lots *= InpScore3Factor;
   }

   double lot       = NormalizeLots(lots);
   double dispLot   = ((isOpenNow || isPendNow) && g_auto[i].curLot > 0.0) ? g_auto[i].curLot : lot;
   double riskUSD   = (pv > 0.0) ? dispLot * (double)dispSlPts * pv : 0.0;
   double rewardUSD = (pv > 0.0) ? dispLot * (double)dispTpPts * pv : 0.0;
   bool   riskOver  = (!InpUseMinLot && InpUseRisk && wantRisk > 0.0 &&
                       riskUSD > wantRisk * 1.05);

   // ---- how long this reading is worth acting on -------------------
   datetime until  = 0;
   datetime sigBar = LastClosedBarTime(_Symbol, g_rows[i].tf);
   if(sigBar > 0)
      until = sigBar + (datetime)((InpValidBars + 1) * PeriodSeconds(g_rows[i].tf));

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

   g_plans[i].lbl[2][2] = "Valid:";
   g_plans[i].val[2][2] = (until > 0)
      ? StringFormat("%d bars -> %s", InpValidBars, TimeToString(until, TIME_MINUTES))
      : StringFormat("%d bars", InpValidBars);
   g_plans[i].clr[2][2] = clrSilver;
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
   bool     isRange;       // true when this order is a range fade (box trade)
   double   rngTop;        // range box upper band captured at placement (box-kill)
   double   rngBot;        // range box lower band captured at placement (box-kill)
   datetime placedBar;     // closed-bar timestamp when pending order was placed
   datetime lastEvalBar;   // last closed bar on which SL/TP update was evaluated
   datetime lastSignalBar; // closed-bar timestamp on which a trade was opened
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
   g_auto[i].isRange       = false;
   g_auto[i].rngTop        = 0.0;
   g_auto[i].rngBot        = 0.0;
   g_auto[i].placedBar     = 0;
   g_auto[i].lastEvalBar   = 0;
   g_auto[i].lastSignalBar = sigBar;
   ClearAutoCells(i);
}

//+------------------------------------------------------------------+
void InitAutoState()
{
   for(int i = 0; i < TF_COUNT; i++)
      ResetAutoSlot(i, false);
   g_autoShown = false;
}

//+------------------------------------------------------------------+
bool CanTradeNow()
{
   if(!InpAutoTrading || !ChartSupported()) return(false);
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return(false);
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))           return(false);
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))   return(false);
   return(true);
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
//  Rule 8: M5 trades its own signal directly; M15 and M30 require their
//  trends (Going up / Going down) to match before placing an order.
//+------------------------------------------------------------------+
bool TrendMatchForTF(int i)
{
   if(i == 0)
      return(g_rows[0].ok && g_rows[0].direction != 0);
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
   req.deviation    = (ulong)MathMax(0, InpSlippagePts);
   req.magic        = MagicForTF(i);
   req.comment      = "SimpleEA_" + g_rows[i].tag;
   req.type_filling = FillingMode();

   if(!OrderSend(req, res)) return(false);
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

   if(!OrderSend(req, res)) return(false);
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
   req.deviation    = (ulong)MathMax(0, InpSlippagePts);
   req.magic        = magic;
   req.type_filling = FillingMode();

   if(!OrderSend(req, res)) return(false);
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

   if(!OrderSend(req, res)) return(false);
   return(res.retcode == TRADE_RETCODE_DONE);
}

//+------------------------------------------------------------------+
//  Synchronize g_auto[] with the broker's live open positions and
//  pending orders on _Symbol.
//+------------------------------------------------------------------+
void SyncAutoState()
{
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
         g_auto[i].dir        = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
         g_auto[i].curLot     = PositionGetDouble(POSITION_VOLUME);
         g_auto[i].entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         g_auto[i].slPrice    = PositionGetDouble(POSITION_SL);
         g_auto[i].tpPrice    = PositionGetDouble(POSITION_TP);
         g_auto[i].profitUSD  = PositionGetDouble(POSITION_PROFIT);

         if(g_auto[i].slPrice > 0.0)
            g_auto[i].slPts = (int)MathRound(MathAbs(g_auto[i].entryPrice - g_auto[i].slPrice) / point);
         else
            g_auto[i].slPts = 0;

         // Recover or transition state when a pending order just filled or EA restarted
         if(!wasOpen)
         {
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

            // If SL is already at Break-Even or better, mark TP1 hit and Trailstop active
            if(g_auto[i].slPrice > 0.0)
            {
               bool atBE = (g_auto[i].dir > 0)
                           ? (g_auto[i].slPrice >= g_auto[i].entryPrice - 0.5 * point)
                           : (g_auto[i].slPrice <= g_auto[i].entryPrice + 0.5 * point);
               if(atBE)
               {
                  g_auto[i].tp1Hit      = true;
                  g_auto[i].trailActive = true;
               }
            }
            if(g_auto[i].lastSignalBar == 0)
               g_auto[i].lastSignalBar = g_rows[i].lastBar;
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
   if(!CanTradeNow()) return(false);
   if(g_plans[i].state != 2 || g_plans[i].dir == 0) return(false);
   if(!TrendMatchForTF(i)) return(false);

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
      g_auto[i].lastEvalBar   = g_rows[i].lastBar;
      g_auto[i].lastSignalBar = g_rows[i].lastBar;
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
      //  Range fades carry their box: a close outside it kills the trade
      //  (checked on every new closed bar, before the other rules).
      g_auto[i].isRange       = (g_rows[i].mode == 2);
      g_auto[i].rngTop        = (g_rows[i].mode == 2) ? g_rows[i].rngTop : 0.0;
      g_auto[i].rngBot        = (g_rows[i].mode == 2) ? g_rows[i].rngBot : 0.0;
      g_auto[i].placedBar     = g_rows[i].lastBar;
      g_auto[i].lastEvalBar   = g_rows[i].lastBar;
      g_auto[i].lastSignalBar = g_rows[i].lastBar;
      return(true);
   }
}

//+------------------------------------------------------------------+
//  Bar-close autotrading logic:
//    - Manages open positions on signal/score changes and updates
//      TP1/TP2/TP3 + tightens SL when a new candle closes.
//    - Manages waiting pending limit orders (updates Entry/SL/TP,
//      upgrades 2/3 -> 3/3 to Market, or cancels on flip/HOLD/expiry).
//    - Opens new Market/Limit orders for flat timeframes with a valid
//      plan (M5 independent; M15 & M30 require matching trend).
//+------------------------------------------------------------------+
void ManageAutoBar()
{
   SyncAutoState();
   if(!CanTradeNow())
   {
      UpdatePlan();
      return;
   }

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

         // Track peak score strength in the trade's direction
         if(g_rows[i].ok && g_rows[i].direction == dir &&
            MathAbs(g_rows[i].score) > MathAbs(g_auto[i].entryScore))
         {
            g_auto[i].entryScore = g_rows[i].score;
         }

         // 0) RANGE FADE: a closed bar outside the trade's box kills it (Part 2).
         //    The box captured at placement is the thesis; the market just broke it.
         if(g_auto[i].isRange && g_rows[i].ok &&
            (g_rows[i].lastClose > g_auto[i].rngTop || g_rows[i].lastClose < g_auto[i].rngBot))
         {
            if(TradeClosePosition(g_auto[i].ticket, dir, g_auto[i].curLot, MagicForTF(i)))
            {
               g_auto[i].lastSignalBar = g_rows[i].lastBar;
               ResetAutoSlot(i, true);
            }
            continue;
         }

         // 1) Opposite direction signal -> close immediately (and allow reversing into the new signal)
         if(g_rows[i].ok && g_rows[i].direction != 0 && g_rows[i].direction != dir)
         {
            if(TradeClosePosition(g_auto[i].ticket, dir, g_auto[i].curLot, MagicForTF(i)))
            {
               ResetAutoSlot(i, false);
               if(g_plans[i].state == 2 && TrendMatchForTF(i))
                  PlacePlanOrder(i);
            }
            continue;
         }

         // 2) After TP1 is hit -> close if score weakened or direction dropped to HOLD.
         //    Range fades are exempt: their exits are the box midpoint, the stop and
         //    the box-kill - the trend score has no jurisdiction over them.
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

         // 4) Closed bar in the SAME direction -> update TP1/TP2/TP3 and SL
         if(g_rows[i].ok && g_rows[i].direction == dir && g_plans[i].state == 2)
         {
            int newTp3 = g_plans[i].tp3Pts;
            int newTp1 = 1, newTp2 = 1;
            ComputeTPLevels(newTp3, newTp1, newTp2);

            if(!g_auto[i].tp1Hit) g_auto[i].tp1Pts = newTp1;
            if(!g_auto[i].tp2Hit) g_auto[i].tp2Pts = newTp2;
            g_auto[i].tp3Pts = newTp3;

            double rawTpPrice = NormPrice(g_auto[i].entryPrice + (double)dir * (double)newTp3 * point);
            double newTpPrice = ClampTPToStopsLevel(dir, rawTpPrice, bid, ask, point);
            double candSL     = NormPrice(g_auto[i].entryPrice - (double)dir * (double)g_plans[i].slPts * point);
            candSL            = ClampSLToStopsLevel(dir, candSL, bid, ask, point);

            double useSL = g_auto[i].slPrice;
            if(!g_auto[i].tp1Hit && !g_auto[i].trailActive)
            {
               useSL = InpUseStopLoss ? candSL : 0.0;
            }
            else if(candSL > 0.0 && IsSLTighter(dir, candSL, g_auto[i].slPrice, point))
            {
               useSL = candSL;
            }

            if(MathAbs(newTpPrice - g_auto[i].tpPrice) >= 0.5 * point ||
               MathAbs(useSL      - g_auto[i].slPrice) >= 0.5 * point)
            {
               if(TradeModifyPosition(g_auto[i].ticket, useSL, newTpPrice))
               {
                  g_auto[i].slPrice       = useSL;
                  g_auto[i].tpPrice       = newTpPrice;
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
         int  tfSec   = PeriodSeconds(g_rows[i].tf);
         bool expired = (g_auto[i].placedBar > 0 && tfSec > 0 &&
                         g_rows[i].lastBar > g_auto[i].placedBar &&
                         ((int)((g_rows[i].lastBar - g_auto[i].placedBar) / tfSec) >= InpValidBars));

         // 0) RANGE FADE: a closed bar outside the trade's box cancels the pending (Part 2)
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

         // 1) Direction changed / HOLD / M15-M30 mismatch / expired -> cancel pending order
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
            if(TradeDeleteOrder(g_auto[i].ticket))
            {
               ResetAutoSlot(i, false);
               PlacePlanOrder(i);
            }
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
         continue;
      }

      // ---- CASE C: Flat on this timeframe -> check new placement ----
      if(!g_auto[i].active)
      {
         if(g_rows[i].ok && g_rows[i].direction != 0 && g_plans[i].state == 2 &&
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

         // ---- TP1 hit: move SL to Break-Even (Trailstop ACTIVE) and
         //      partial-close 70% if lot > minLot ---------------------
         if(!g_auto[i].tp1Hit && g_auto[i].tp1Pts > 0 &&
            favPts >= (double)g_auto[i].tp1Pts - 1e-6)
         {
            g_auto[i].tp1Hit      = true;
            g_auto[i].trailActive = true;
            stateChanged          = true;

            double beSL = ClampSLToStopsLevel(dir, g_auto[i].entryPrice, bid, ask, point);
            if(beSL > 0.0 && IsSLTighter(dir, beSL, g_auto[i].slPrice, point))
            {
               if(TradeModifyPosition(g_auto[i].ticket, beSL, g_auto[i].tpPrice))
               {
                  g_auto[i].slPrice = beSL;
                  g_auto[i].slPts   = (int)MathRound(MathAbs(g_auto[i].entryPrice - beSL) / point);
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
         //      SL to TP1 ---------------------------------------------
         if(g_auto[i].tp1Hit && !g_auto[i].tp2Hit && g_auto[i].tp2Pts > 0 &&
            favPts >= (double)g_auto[i].tp2Pts - 1e-6)
         {
            g_auto[i].tp2Hit      = true;
            g_auto[i].trailActive = true;
            stateChanged          = true;

            double tp1P   = g_auto[i].entryPrice + (double)dir * (double)g_auto[i].tp1Pts * point;
            double lockSL = ClampSLToStopsLevel(dir, tp1P, bid, ask, point);
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

            //  Range fades are exempt from the score watcher too (Part 2).
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
         int    slPtsNow = (int)MathRound(MathAbs(g_auto[i].entryPrice - g_auto[i].slPrice) / point);
         double slUSD    = (pv > 0.0) ? lot * (double)slPtsNow * pv : 0.0;
         bool   isBE     = (slPtsNow == 0 || g_auto[i].trailActive);
         g_auto[i].val[2][1] = StringFormat("%s (%s %s)%s",
                                            DoubleToString(g_auto[i].slPrice, dg), DoubleToString(slUSD, 2), cur,
                                            (slPtsNow == 0 && isBE) ? " [BE]" : "");
         g_auto[i].clr[2][1] = (slPtsNow == 0 && isBE) ? InpBuyColor : InpSellColor;
      }
      else
      {
         // When SL is blank, show "-- (Ask/Bid: xxx.xx)" in realtime
         g_auto[i].val[2][1] = StringFormat("-- (%s %s)",
                                            liveL, (liveP > 0.0 ? DoubleToString(liveP, dg) : "--"));
         g_auto[i].clr[2][1] = clrSilver;
      }

      // ---- Line 3: Status / Waiting distance & Distance from open price to TP1/TP2/TP3
      string nextTpTag = !g_auto[i].tp1Hit ? "TP1" : (!g_auto[i].tp2Hit ? "TP2" : "TP3");
      int    nextTpPts = !g_auto[i].tp1Hit ? g_auto[i].tp1Pts
                                           : (!g_auto[i].tp2Hit ? g_auto[i].tp2Pts : g_auto[i].tp3Pts);

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
      g_auto[i].val[3][1] = StringFormat("to %s %d pts", nextTpTag, nextTpPts);
      g_auto[i].clr[3][1] = InpBuyColor;
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
   MakeRect("sep", x + 4, y + HEAD_H - 6, g_panelW - 8, 1, clrDimGray, clrDimGray);
}

//+------------------------------------------------------------------+
//  DrawPanel() never decides anything: it only shows whichever of the
//  two panels the chart timeframe allows.  There is no path through the
//  program on which the data panel can be drawn for a bare M1, H1, D1 ...
//  chart, because this switch is the only way in.
//+------------------------------------------------------------------+
void DrawPanel()
{
   if(ChartSupported()) DrawSupportedPanel();
   else                 DrawIncompatiblePanel();
}

//+------------------------------------------------------------------+
//  Supported chart timeframe (M5 / M15 / M30) - the full panel:
//
//     SimpleEA                                      SYMBOL  M15
//     --------------------------------------------------------------
//     M5   Scalp       Trend: Going up     Regime: Steady
//                      Signal: BUY         Score: +3 / 3
//     ...
//+------------------------------------------------------------------+
void DrawSupportedPanel()
{
   int x   = InpPanelX, y = InpPanelY;
   int pad = 10;
   int rowH = g_rowH;

   //  Size the panel to its content BEFORE drawing the background, so the
   //  trade plan can never be clipped on the right - and so the box hugs
   //  the content instead of leaving a wide empty edge when signals go.
   int    em       = CharW(InpFontSize);
   int    titleW   = 8 * CharW(InpFontSize + 1);
   string symRight = "|  " + _Symbol + "  |  " + ChartTimeframeText();
   int    headW    = pad + titleW + em + (16 + 3 + 2 + StringLen(symRight)) * em + pad;
   int    wantW    = (int)MathMax(NoticeWidth(), headW);
   if(InpShowPlan) wantW = (int)MathMax(wantW, PlanWidthNeed());
   g_panelW = wantW;
   g_panelH = HEAD_H + TF_COUNT * 2 * rowH + 8
              + (InpShowPlan ? (PLAN_SEP_H + TotalPlanLines() * rowH) : 0);
   MakeRect("bg",  x, y, g_panelW, g_panelH, InpBgColor, clrDimGray);
   MakeRect("sep", x + 4, y + HEAD_H - 6, g_panelW - 8, 1, clrDimGray, clrDimGray);

   // ---- header: SimpleEA | Autotrading : On/Off | SYMBOL | TF -----
   MakeLabel("title", x + pad, y + 7, "SimpleEA",
             InpTitleColor, InpFontSize + 1, false);
   int autoCapX = x + pad + titleW + em;
   MakeLabel("autoCap", autoCapX, y + 8, "| Autotrading : ",
             clrSilver, InpFontSize, false);
   int autoValX = autoCapX + 16 * em;
   MakeLabel("autoVal", autoValX, y + 8, InpAutoTrading ? "On" : "Off",
             InpAutoTrading ? InpBuyColor : InpSellColor, InpFontSize, false);
   MakeLabel("sym", x + g_panelW - pad, y + 8, symRight,
             InpTitleColor, InpFontSize, true);

   // ---- two lines per timeframe -------------------------------------
   //  Line 1 (plain words, every value NAMED so nothing is ambiguous):
   //     Trend: Going up      Regime: Steady
   //  Line 2 (the original trading read, kept from the first panel):
   //     Signal: BUY          Score: +3 / 3
   //  Trend = which way it is going, Regime = how it is moving,
   //  Signal/Score = what the old panel used to show on its own.
   for(int i = 0; i < TF_COUNT; i++)
   {
      int    ry  = y + HEAD_H + 2 + i * 2 * rowH;
      string sfx = "_" + IntegerToString(i);

      MakeLabel("tf" + sfx,    x + pad,      ry, g_rows[i].tag,
                clrWhite, InpFontSize, false);
      MakeLabel("style" + sfx, x + pad + 34, ry, g_rows[i].style,
                clrGray, InpFontSize, false);

      MakeLabel("trendCap" + sfx,  x + 150, ry, "Trend:",
                clrGray, InpFontSize, false);
      MakeLabel("regimeCap" + sfx, x + 282, ry, "Regime:",
                clrGray, InpFontSize, false);
      MakeLabel("signalCap" + sfx, x + 150, ry + rowH, "Signal:",
                clrGray, InpFontSize, false);
      MakeLabel("scoreCap" + sfx,  x + 282, ry + rowH, "Score:",
                clrGray, InpFontSize, false);

      if(g_rows[i].ok)
      {
         MakeLabel("dir" + sfx, x + 192, ry, PlainTrendText(g_rows[i].direction),
                   DirectionColor(g_rows[i].direction), InpFontSize + 1, false);
         MakeLabel("regimeVal" + sfx, x + 330, ry, RegimeText(i),
                   RegimeColor(i), InpFontSize + 1, false);
         //  Part 2: a blocked row shows the trade it WOULD have fired,
         //  greyed out - the gate now has a word and a colour instead of
         //  a silent HOLD.  A quiet row keeps its normal HOLD.
         int  sigDir = g_rows[i].direction;
         bool greyed = false;
         if(sigDir == 0)
         {
            if(g_rows[i].score >= InpBuyScore)       { sigDir = 1;  greyed = true; }
            else if(g_rows[i].score <= InpSellScore) { sigDir = -1; greyed = true; }
         }
         MakeLabel("signal" + sfx, x + 192, ry + rowH,
                   DirectionText(sigDir),
                   greyed ? clrGray : DirectionColor(sigDir), InpFontSize + 1, false);
         MakeLabel("score" + sfx, x + 330, ry + rowH,
                   StringFormat("%+d / 3", g_rows[i].score),
                   greyed ? clrGray : DirectionColor(sigDir), InpFontSize + 1, false);
      }
      else
      {
         MakeLabel("dir" + sfx,       x + 192, ry, "Waiting",
                   clrDimGray, InpFontSize, false);
         MakeLabel("regimeVal" + sfx, x + 330, ry, "...",
                   clrDimGray, InpFontSize, false);
         MakeLabel("signal" + sfx,    x + 192, ry + rowH, "...",
                   clrDimGray, InpFontSize, false);
         MakeLabel("score" + sfx,     x + 330, ry + rowH, "...",
                   clrDimGray, InpFontSize, false);
      }
   }

   // ---- the trade plan: one block per timeframe below the rows -------
   if(InpShowPlan) DrawPlanBlock(x, y);
   else            DeletePlanObjects();

   // ---- the 2nd panel (Autotrading): right of the Main Panel ---------
   DrawAutoPanel();

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

   cA = PLAN_COL_A;
   vA = cA + em * PLAN_LBL_C;

   int wA = 0;
   for(int i = 0; i < TF_COUNT; i++)
      for(int l = 0; l < g_plans[i].lines; l++)
         if(g_plans[i].lbl[l][0] != "")
            wA = (int)MathMax(wA, StringLen(g_plans[i].val[l][0]) * em);

   cB = (int)MathMax(PLAN_COL_B, vA + wA + em * 2);
   vB = cB + em * PLAN_LBL_C;

   int wB = 0;
   for(int i = 0; i < TF_COUNT; i++)
      for(int l = 0; l < g_plans[i].lines; l++)
         if(g_plans[i].lbl[l][1] != "")
            wB = (int)MathMax(wB, StringLen(g_plans[i].val[l][1]) * em);

   cC = (int)MathMax(PLAN_COL_C, vB + wB + em * 2);
   vC = cC + em * PLAN_LBL_C;
}

//+------------------------------------------------------------------+
//  How many lines the second group needs: 3 per active timeframe, 1 for
//  a HOLD or waiting one.  The panel height follows this, so the block
//  is never taller than it has content for.
//+------------------------------------------------------------------+
int TotalPlanLines()
{
   if(!InpShowPlan) return(0);

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
   if(!InpShowPlan || !ChartSupported()) return(0);

   int cA, vA, cB, vB, cC, vC;
   PlanColumns(cA, vA, cB, vB, cC, vC);
   int em = CharW(InpFontSize);

   //  timeframe tag at x+10 and the kind ("pending +3/3") at x+44
   int need = 44 + StringLen("pending +3/3") * em + 10;

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
//                       Risk: 7.84 USD        Reward: 7.00 USD   Valid: 3 bars -> 14:30
//    M15  range fade    Entry: 4279.10 (limit at the band)           Lot: 0.28
//                       Stop: 4271.10 80pts   Target: 4287.10 80pts  Reach: ~2 bars
//    M30  HOLD          mixed — no edge either way
//
//+------------------------------------------------------------------+
void DrawPlanBlock(int x, int y)
{
   if(RowForChartTF() < 0) return;              // only on M5/M15/M30 charts

   int rowH = g_rowH;
   int gy   = y + HEAD_H + 2 + TF_COUNT * 2 * rowH + PLAN_SEP_H;

   //  the separator between the two groups
   MakeRect("planSep", x + 4, gy - 8, g_panelW - 8, 1, clrDimGray, clrDimGray);

   int cA, vA, cB, vB, cC, vC;
   PlanColumns(cA, vA, cB, vB, cC, vC);

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
         MakeLabel("planKind" + sfx, x + 44, ry, kindTxt, kc, InpFontSize, false);
      else
         DeleteObject("planKind" + sfx);

      // ---- mark [OPEN] or [PLACED] on the Main Panel plan block ----
      string stName = "planStatus" + sfx;
      if(autoTag != "" && g_plans[i].lines > 1)
      {
         color stClr = (g_auto[i].dir > 0) ? InpBuyColor : InpSellColor;
         MakeLabel(stName, x + 44, ry + rowH, autoTag, stClr, InpFontSize, false);
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

   cA = (int)MathMax(AUTO_COL_A, 10 + (int)StringLen("M30 | SELL LIMIT") * em + em * 2);
   vA = cA + em * AUTO_LBL_A;

   int wA = 0;
   for(int i = 0; i < TF_COUNT; i++)
   {
      if(!g_auto[i].active) continue;
      for(int l = 0; l < AUTO_LINES; l++)
         if(g_auto[i].lbl[l][0] != "")
            wA = (int)MathMax(wA, StringLen(g_auto[i].val[l][0]) * em);
   }

   cB = (int)MathMax(AUTO_COL_B, vA + wA + em * 2);
   vB = cB + em * AUTO_LBL_B;

   int wB = 0;
   for(int i = 0; i < TF_COUNT; i++)
   {
      if(!g_auto[i].active) continue;
      for(int l = 0; l < AUTO_LINES; l++)
         if(g_auto[i].lbl[l][1] != "")
            wB = (int)MathMax(wB, StringLen(g_auto[i].val[l][1]) * em);
   }

   cC = (int)MathMax(AUTO_COL_C, vB + wB + em * 2);
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
                  + (14 + 3 + 1 + 13 + 3 + 2 + StringLen("|  " + _Symbol)) * em + 10;
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

   bool tsOn   = AnyTrailstopOn();
   bool slOn   = AnyStoplossOn();
   int  em     = CharW(InpFontSize);
   int  titleW = 11 * CharW(InpFontSize + 1);

   MakeAutoLabel("title", x2 + pad, y2 + 7, "Autotrading",
                 InpTitleColor, InpFontSize + 1, false);
   int tsCapX = x2 + pad + titleW + em;
   MakeAutoLabel("tsCap", tsCapX, y2 + 8, "| Trailstop : ",
                 clrSilver, InpFontSize, false);
   int tsValX = tsCapX + 14 * em;
   MakeAutoLabel("tsVal", tsValX, y2 + 8, tsOn ? "On" : "Off",
                 tsOn ? InpBuyColor : InpSellColor, InpFontSize, false);
   int slCapX = tsValX + 3 * em + em;
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

//+------------------------------------------------------------------+
//  Unsupported chart timeframe - THE NOTICE PANEL.
//
//     +-----------------------------------------------+
//     |  SimpleEA                        XAUUSD  H1   |
//     +-----------------------------------------------+
//     |  Incompatible chart. Switch to M5/M15/M30.    |
//     +-----------------------------------------------+
//
//  Read as one line:  SimpleEA | Incompatible chart. Switch to M5/M15/M30.
//
//  That is the whole panel - the header line the user always sees, plus
//  the notice where the M5/M15/M30 rows would have started.  No rows, no
//  Trend, no Regime, no Signal, no Score: the engine is calibrated for
//  those three timeframes only, so a reading taken on any other chart
//  would be meaningless and is withheld completely.  The box is sized to
//  those two lines and the object set is trimmed to match, so nothing
//  from the data panel can linger underneath it.
//+------------------------------------------------------------------+
void DrawIncompatiblePanel()
{
   int x   = InpPanelX, y = InpPanelY;
   int pad = 10;

   //  Keep the header exactly where it sits in the full panel and put the
   //  notice on the line where the first timeframe row would have started,
   //  so an unsupported chart reads as the panel collapsing to its header
   //  rather than as a different widget appearing.
   int noticeH = HEAD_H + 2 + (InpFontSize + 1) + 6;

   MakeRect("bg", x, y, g_panelW, noticeH, InpBgColor, clrDimGray);

   //  The separator and the whole trade-plan block belong to the full
   //  panel only - an unsupported chart shows no plan either.
   DeleteObject("sep");
   DeleteObject("autoCap");
   DeleteObject("autoVal");
   DeletePlanObjects();
   DeleteAutoPanel();

   MakeLabel("title", x + pad, y + 7, "SimpleEA",
             InpTitleColor, InpFontSize + 1, false);
   //  Deliberately the real chart timeframe: the header states the fact,
   //  the line underneath states what to do about it.
   MakeLabel("sym", x + g_panelW - pad, y + 8,
             _Symbol + "  " + ChartTimeframeText(),
             InpTitleColor, InpFontSize, true);

   MakeLabel("notice", x + pad, y + HEAD_H + 2,
             IncompatibleNotice(), InpSellColor, InpFontSize + 1, false);

   //  Remove every row object the full panel uses, so a single leftover
   //  cannot show through on an incompatible chart.
   for(int i = 0; i < TF_COUNT; i++)
   {
      string sfx = "_" + IntegerToString(i);
      DeleteObject("tf"        + sfx);
      DeleteObject("style"     + sfx);
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
   g_autoShown = false;
   ChartRedraw(0);
}
//+------------------------------------------------------------------+
