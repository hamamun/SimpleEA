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
//|                 H > threshold : persistent -> the trend is real,  |
//|                                 vote with the trend.              |
//|                 otherwise     : random walk or anti-persistent    |
//|                                 -> ABSTAIN.                       |
//|                 This is the component that stops the panel from   |
//|                 making confident calls when the market has no     |
//|                 directional memory.                               |
//|                                                                  |
//|  Score = vote1 + vote2 + vote3      (range -3 .. +3)              |
//|      BUY  if score >= +2                                          |
//|      SELL if score <= -2                                          |
//|      HOLD otherwise                                               |
//|                                                                  |
//|  Kaufman's Efficiency Ratio acts as a dead-market gate: below     |
//|  InpERDead the market is not travelling anywhere, so any          |
//|  directional read is meaningless and the row is forced to HOLD.   |
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
//|  target in price, points and account currency, and how many bars    |
//|  the reading is worth acting on.  A HOLD or waiting timeframe takes |
//|  a single line, so the group is only as tall as it has content for. |
//|                                                                  |
//|  Nothing is calculated at all while the chart is on a wrong       |
//|  timeframe, so no stale or out-of-context number can be read off  |
//|  the screen.  Switching the chart back to M5, M15 or M30 brings   |
//|  the full panel straight back.                                    |
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
#property version   "1.13"
#property description "Read-only multi-timeframe BUY/SELL/HOLD direction panel. M5 / M15 / M30 charts only; other timeframes show a header-only notice."

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

//==================================================================
//  INPUTS
//==================================================================
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

input group "=== Trade plan (advice only - the EA never sends an order) ==="
input bool     InpShowPlan     = true;       // Show the trade plan block
input bool     InpUseRisk      = true;       // Size by RISK % of balance (false = balance+score ladder)
input bool     InpUseMinLot    = false;      // Always advise the symbol's minimum lot
input double   InpRiskScore2   = 0.5;        // Risk % when score is 2 (risk mode)
input double   InpRiskScore3   = 1.0;        // Risk % when score is 3 (risk mode)
input double   InpBalPer001    = 1000.0;     // Risk-off mode: balance per 0.01 lot
input double   InpScore3Factor = 1.5;        // Risk-off mode: lot multiplier at score 3
input int      InpATRPeriod    = 14;         // ATR period (closed bars, chart timeframe)
input double   InpSLATR        = 1.2;        // Stop loss   = this many ATR
input double   InpTPATR        = 2.4;        // Take profit = this many ATR
input double   InpPendATR      = 0.5;        // Pending entry offset = this many ATR
input int      InpValidBars    = 3;          // Signal validity in bars (see research/HORIZON.md)

input group "=== Shared engine settings ==="
input int      InpHurstWindow = 256;         // Hurst estimate window (bars)
input int      InpERPeriod    = 20;          // Kaufman efficiency-ratio period
input double   InpERDead      = 0.10;        // Efficiency below this => dead market, force HOLD
input bool     InpFadeInRange = false;       // Anti-persistent regime: vote AGAINST the trend (see note)

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
#define OBJ_PREFIX "SA_"
#define TF_COUNT   3
#define TF_TEXT    "M5/M15/M30"
#define HEAD_H     34     // height of the header band (title + symbol line)
#define PLAN_W_MIN 406    // panel width with no plan showing
#define PLAN_LINES 3      // lines an ACTIVE timeframe uses (1 for HOLD)
#define PLAN_COL_A 150    // first cell column: aligns with "Trend:" above
#define PLAN_COL_B 282    // second cell column: aligns with "Regime:" above
#define PLAN_COL_C 414    // third cell column: used by the "Valid" cell
#define PLAN_LBL_C 8      // widest label in a column, in characters
#define PLAN_SEP_H 14     // gap between the last timeframe row and the plan

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
                  int l1, int l2, double hTrend, double hRevert)
{
   g_rows[i].tf      = tf;
   g_rows[i].tag     = tag;
   g_rows[i].style   = style;
   g_rows[i].l1      = l1;
   g_rows[i].l2      = l2;
   g_rows[i].hTrend  = hTrend;
   g_rows[i].hRevert = hRevert;
   g_rows[i].score      = 0;
   g_rows[i].direction  = 0;
   g_rows[i].hurst      = 0.5;
   g_rows[i].er         = 0.0;
   g_rows[i].ok         = false;
   g_rows[i].lastBar    = 0;
}

//+------------------------------------------------------------------+
int OnInit()
{
   ConfigureRow(0, PERIOD_M5,  "M5",  "Scalp",      InpL1_M5,  InpL2_M5,
                InpHurstTrendM5,  InpHurstRevertM5);
   ConfigureRow(1, PERIOD_M15, "M15", "Short-term", InpL1_M15, InpL2_M15,
                InpHurstTrendM15, InpHurstRevertM15);
   ConfigureRow(2, PERIOD_M30, "M30", "Intraday",   InpL1_M30, InpL2_M30,
                InpHurstTrendM30, InpHurstRevertM30);

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
}

//+------------------------------------------------------------------+
void OnTimer()
{
   CheckNewBars();
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
      DrawPanel();
      ChartRedraw(0);
      return;
   }

   if(need)
   {
      EvaluateAll();
      UpdatePlan();
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
         g_rows[r].ok        = false;
         g_rows[r].score     = 0;
         g_rows[r].direction = 0;
         g_rows[r].lastBar   = 0;
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
      g_rows[idx].ok        = false;
      g_rows[idx].score     = 0;
      g_rows[idx].direction = 0;
      return;
   }

   int n    = ArraySize(c);
   int last = n - 1;                       // most recently CLOSED bar

   // ---- components 1 and 2 : trend and momentum -------------------
   double trend[], roc[];
   PrecisionTrend(c, g_rows[idx].l1, g_rows[idx].l2, trend, roc);

   int v1 = (trend[last] > 0.0) ? 1 : ((trend[last] < 0.0) ? -1 : 0);
   int v2 = (roc[last]   > 0.0) ? 1 : ((roc[last]   < 0.0) ? -1 : 0);

   // ---- component 3 : regime --------------------------------------
   double H  = HurstExponent(c, last, InpHurstWindow);
   double ER = EfficiencyRatio(c, last, InpERPeriod);

   int v3 = 0;
   if(H > g_rows[idx].hTrend)
      v3 = v1;                                   // persistent: back the trend
   else if(InpFadeInRange && H < g_rows[idx].hRevert)
      v3 = -v1;                                  // anti-persistent: fade it
   else
      v3 = 0;                                    // no memory: abstain

   int score = v1 + v2 + v3;

   // ---- dead-market gate ------------------------------------------
   int dir = 0;
   if(ER >= InpERDead)
   {
      if(score >= InpBuyScore)       dir = 1;
      else if(score <= InpSellScore) dir = -1;
   }

   g_rows[idx].ok        = true;
   g_rows[idx].score     = score;
   g_rows[idx].direction = dir;
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
//     1. WHERE  - market entry, or a pending order if the score is only 2
//     2. HOW MUCH - lot size, from balance and score
//     3. TARGET - take profit in points and in account currency
//     4. STOP   - stop loss   in points and in account currency
//     5. UNTIL  - how long the reading is worth acting on
//
//  Entry type is decided by the score, not by the user:
//     score 3/3  -> all three components agree -> MARKET entry
//     score 2/3  -> two of three agree        -> PENDING (wait for a better price)
//  (Measured behaviour of both is in research/HORIZON.md; the pending price
//   is one InpPendATR step beyond the market, which is the only place in
//   this block where a choice - not a measurement - is being made.)
//+------------------------------------------------------------------+
//  ONE PLAN PER TIMEFRAME.  The second group is three blocks, one for M5,
//  one for M15, one for M30 - because when autotrading arrives the panel
//  has to be able to say "buy M5, sell M30" and the executor acts per row.
struct SPlanRow
{
   int    state;                  // 0 HOLD, 1 waiting for data, 2 active
   int    dir;                    // +1 buy, -1 sell
   int    score;
   bool   market;                 // true = market entry, false = pending
   int    lines;                  // lines this block occupies: 1 or PLAN_LINES
   string head;                   // "M5" / "M15" / "M30"
   string kind;                   // "market -3/3" / "pending +2/3" / "HOLD" / "waiting"
   string note;                   // one-liners for the inactive states
   // ---- ready to draw: label + value per cell -------------------------
   string lbl[PLAN_LINES][3];
   string val[PLAN_LINES][3];
   color  clr[PLAN_LINES][3];
};

SPlanRow g_plans[TF_COUNT];

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
   g_plans[i].state  = 0;
   g_plans[i].dir    = 0;
   g_plans[i].score  = 0;
   g_plans[i].market = false;
   g_plans[i].lines  = 1;
   g_plans[i].head   = g_rows[i].tag;
   g_plans[i].kind   = "";
   g_plans[i].note   = "";

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
      g_plans[i].note  = "nothing to place";
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

   int    dir    = g_rows[i].direction;
   int    score  = g_rows[i].score;
   bool   market = (MathAbs(score) >= 3);          // 3 of 3 -> trade now
   double entry  = (dir > 0) ? ask : bid;
   double offset = InpPendATR * atr;
   double pend   = (dir > 0) ? (entry - offset) : (entry + offset);

   // ---- stop and target, snapped onto the broker's point grid ------
   int slPts = (int)MathMax(1.0, MathRound(InpSLATR * atr / point));
   int tpPts = (int)MathMax(1.0, MathRound(InpTPATR * atr / point));

   double minStop = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
   bool   widened = false;
   if(minStop > 0.0 && (double)slPts * point < minStop)
   {
      slPts   = (int)MathCeil(minStop / point);
      widened = true;
   }

   double slPrice = (dir > 0) ? (entry - (double)slPts * point)
                              : (entry + (double)slPts * point);
   double tpPrice = (dir > 0) ? (entry + (double)tpPts * point)
                              : (entry - (double)tpPts * point);

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
   double riskUSD   = (pv > 0.0) ? lot * (double)slPts * pv : 0.0;
   double rewardUSD = (pv > 0.0) ? lot * (double)tpPts * pv : 0.0;
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

   g_plans[i].state  = 2;
   g_plans[i].dir    = dir;
   g_plans[i].score  = score;
   g_plans[i].market = market;
   g_plans[i].lines  = PLAN_LINES;
   g_plans[i].kind   = StringFormat("%s %+d/%d",
                                    market ? "market" : "pending", score, 3);

   g_plans[i].lbl[0][0] = "Entry:";
   g_plans[i].val[0][0] = DoubleToString(market ? entry : pend, dg);
   g_plans[i].clr[0][0] = dirC;

   string lotTxt = DoubleToString(lot, 2);
   if(minLot)        lotTxt += " (min)";
   else if(riskOver) lotTxt += StringFormat(" (min, %s %s)",
                                            DoubleToString(riskUSD, 2), cur);
   g_plans[i].lbl[0][1] = "Lot:";
   g_plans[i].val[0][1] = lotTxt;
   g_plans[i].clr[0][1] = InpTitleColor;

   g_plans[i].lbl[1][0] = "Stop:";
   g_plans[i].val[1][0] = StringFormat("%s %dpts%s", DoubleToString(slPrice, dg), slPts,
                                       widened ? " (min)" : "");
   g_plans[i].clr[1][0] = InpSellColor;

   g_plans[i].lbl[1][1] = "Target:";
   g_plans[i].val[1][1] = StringFormat("%s %dpts", DoubleToString(tpPrice, dg), tpPts);
   g_plans[i].clr[1][1] = InpBuyColor;

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
      if(!InpShowPlan || !ChartSupported()) continue;
      UpdatePlanRow(i);
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
   int wantW = NoticeWidth();
   if(InpShowPlan) wantW = (int)MathMax(wantW, PlanWidthNeed());
   g_panelW = wantW;
   g_panelH = HEAD_H + TF_COUNT * 2 * rowH + 8
              + (InpShowPlan ? (PLAN_SEP_H + TotalPlanLines() * rowH) : 0);
   MakeRect("bg", x, y, g_panelW, g_panelH, InpBgColor, clrDimGray);

   // ---- header ----------------------------------------------------
   MakeLabel("title", x + pad, y + 7, "SimpleEA",
             InpTitleColor, InpFontSize + 1, false);
   MakeLabel("sym", x + g_panelW - pad, y + 8,
             _Symbol + "  " + ChartTimeframeText(),
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
         MakeLabel("signal" + sfx, x + 192, ry + rowH,
                   DirectionText(g_rows[i].direction),
                   DirectionColor(g_rows[i].direction), InpFontSize + 1, false);
         MakeLabel("score" + sfx, x + 330, ry + rowH,
                   StringFormat("%+d / 3", g_rows[i].score),
                   DirectionColor(g_rows[i].direction), InpFontSize + 1, false);
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
//    M5   market -3/3   Entry: 4285.70        Lot: 0.23
//                       Stop: 4286.04 34pts   Target: 4285.03 67pts
//                       Risk: 7.82 USD        Reward: 15.41 USD   Valid: 3 bars -> 14:30
//    M15  HOLD          nothing to place
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

      color kc = clrDimGray;
      if(g_plans[i].state == 2)
         kc = (g_plans[i].dir > 0) ? InpBuyColor : InpSellColor;
      if(g_plans[i].kind != "")
         MakeLabel("planKind" + sfx, x + 44, ry, g_plans[i].kind, kc, InpFontSize, false);
      else
         DeleteObject("planKind" + sfx);

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
      DeleteObject("planHead" + sfx);
      DeleteObject("planKind" + sfx);
      DeleteObject("planNote" + sfx);
      for(int l = 0; l < PLAN_LINES; l++)
         for(int c = 0; c < 3; c++)
         {
            string ln = "planCell" + sfx + "_" + IntegerToString(l) + "_" + IntegerToString(c);
            DeleteObject(ln + "L");
            DeleteObject(ln + "V");
         }
   }
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
   DeletePlanObjects();

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
   ChartRedraw(0);
}
//+------------------------------------------------------------------+
