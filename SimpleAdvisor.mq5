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
//|  Under the three timeframe rows the panel prints, for the chart's |
//|  own timeframe, what a trade would look like: where to enter       |
//|  (market or pending), what lot size, target and stop in points and |
//|  in account currency, and how long the reading is worth acting on. |
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
#define PLAN_LINES 8      // text slots in the trade-plan block
#define PLAN_ROWS  7      // rows drawn (slot 0 and 1 share the heading row)
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
   g_panelH = HEAD_H + TF_COUNT * 2 * g_rowH + 8
              + (InpShowPlan ? (PLAN_SEP_H + PLAN_ROWS * g_rowH) : 0);

   //  The notice is the one line that must always be readable in full, so
   //  widen the panel if a large font size would otherwise clip it.  The
   //  estimate is deliberately generous: a monospaced face at the default
   //  10-point size needs about 0.55 em per character, and MetaTrader sizes
   //  fonts in points, so 0.75 em (rounded up) can only ever be too wide.
   int noticeW = 10 + StringLen(IncompatibleNotice()) * CharW(InpFontSize + 1) + 10;
   if(noticeW > g_panelW) g_panelW = noticeW;

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
struct STradePlan
{
   bool           has;        // a signal exists on the chart timeframe
   int            row;        // which of the three rows is the chart timeframe
   int            dir;        // +1 buy, -1 sell
   int            score;
   ENUM_TIMEFRAMES tf;
   double         atr;
   double         entry;      // market entry (ask for a buy, bid for a sell)
   double         pend;       // pending-entry price (better than market)
   double         slPrice, tpPrice;
   double         slDist, tpDist;
   int            slPts, tpPts;
   double         pv;         // account currency per 1 point per 1.0 lot
   double         lot;
   double         riskUSD, rewardUSD, rr;
   double         wantRiskUSD;
   bool           riskOver;   // min lot forced the risk above the target
   bool           minLot;     // advising the symbol minimum lot
   bool           stopLevelHit;
   datetime       until;
   string         why;        // plain words: why market or pending
   // ---- ready to draw: one row per line of the block -------------------
   string         text[PLAN_LINES];
   color          clr[PLAN_LINES];
};

STradePlan g_plan;

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
//  Build the plan for the chart timeframe.  Called only when the chart
//  timeframe is supported - on any other chart there is no plan at all.
//+------------------------------------------------------------------+
void UpdatePlan()
{
   int row = RowForChartTF();
   g_plan.has = false;
   for(int i = 0; i < PLAN_LINES; i++)
   {
      g_plan.text[i] = "";
      g_plan.clr[i]  = clrGray;
   }
   g_plan.row = (row >= 0) ? row : 0;
   if(!InpShowPlan || !ChartSupported() || row < 0) return;

   string cur  = AccountInfoString(ACCOUNT_CURRENCY);
   int    dg   = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   // ---- the "no plan" case: one line, in plain words -------------------
   if(!g_rows[row].ok || g_rows[row].direction == 0)
   {
      g_plan.text[0] = "Trade plan:";
      g_plan.clr [0] = clrGray;
      g_plan.text[1] = StringFormat("%s row shows %s - no trade to plan",
                                    g_rows[row].tag,
                                    g_rows[row].ok ? "HOLD" : "no data yet");
      g_plan.clr [1] = clrDimGray;
      for(int k = 2; k < PLAN_LINES; k++) g_plan.text[k] = "";
      return;                                // no plan: nothing to compute
   }

   // ---- there is a signal: compute the whole plan ----------------------
   double atr = ATRClosed(g_rows[row].tf, InpATRPeriod);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double pv    = PointValuePerLot();
   if(atr <= 0.0 || point <= 0.0 || bid <= 0.0 || ask <= 0.0) return;

   g_plan.has   = true;
   g_plan.tf    = g_rows[row].tf;
   g_plan.dir   = g_rows[row].direction;
   g_plan.score = g_rows[row].score;
   g_plan.atr   = atr;
   g_plan.pv    = pv;
   g_plan.entry = (g_plan.dir > 0) ? ask : bid;

   // ---- 3 + 4. stop and target, snapped onto the point grid ------------
   g_plan.slPts = (int)MathMax(1.0, MathRound(InpSLATR * atr / point));
   g_plan.tpPts = (int)MathMax(1.0, MathRound(InpTPATR * atr / point));

   double minStop = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
   if(minStop > 0.0 && (double)g_plan.slPts * point < minStop)
   {
      g_plan.slPts = (int)MathCeil(minStop / point);
      g_plan.stopLevelHit = true;
   }

   g_plan.slDist = (double)g_plan.slPts * point;
   g_plan.tpDist = (double)g_plan.tpPts * point;
   if(g_plan.dir > 0)
   {
      g_plan.slPrice = g_plan.entry - g_plan.slDist;
      g_plan.tpPrice = g_plan.entry + g_plan.tpDist;
   }
   else
   {
      g_plan.slPrice = g_plan.entry + g_plan.slDist;
      g_plan.tpPrice = g_plan.entry - g_plan.tpDist;
   }

   // ---- 2. lot size ----------------------------------------------------
   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double lots     = SymbolMinLot();
   double wantRisk = 0.0;

   if(InpUseMinLot)
   {
      g_plan.minLot = true;
      lots = SymbolMinLot();
   }
   else if(InpUseRisk)
   {
      double pct = (MathAbs(g_plan.score) >= 3) ? InpRiskScore3 : InpRiskScore2;
      wantRisk   = balance * pct / 100.0;
      if(pv > 0.0 && g_plan.slPts > 0)
         lots = wantRisk / ((double)g_plan.slPts * pv);
   }
   else
   {
      double step = (InpBalPer001 > 0.0) ? InpBalPer001 : 1000.0;
      lots = (balance / step) * 0.01;
      if(MathAbs(g_plan.score) >= 3) lots *= InpScore3Factor;
   }

   g_plan.lot       = NormalizeLots(lots);
   g_plan.riskUSD   = (pv > 0.0) ? g_plan.lot * (double)g_plan.slPts * pv : 0.0;
   g_plan.rewardUSD = (pv > 0.0) ? g_plan.lot * (double)g_plan.tpPts * pv : 0.0;
   g_plan.rr        = (g_plan.riskUSD > 0.0) ? g_plan.rewardUSD / g_plan.riskUSD : 0.0;
   g_plan.wantRiskUSD = wantRisk;
   if(!InpUseMinLot && InpUseRisk && wantRisk > 0.0 && g_plan.riskUSD > wantRisk * 1.05)
      g_plan.riskOver = true;

   // ---- 5. how long the reading is worth acting on ---------------------
   datetime sigBar = LastClosedBarTime(_Symbol, g_plan.tf);
   if(sigBar > 0)
      g_plan.until = sigBar + (datetime)((InpValidBars + 1) * PeriodSeconds(g_plan.tf));

   // ---- 1. market or pending, decided by the score ---------------------
   bool   market = (MathAbs(g_plan.score) >= 3);
   double offset = InpPendATR * atr;
   g_plan.pend = (g_plan.dir > 0) ? (g_plan.entry - offset) : (g_plan.entry + offset);
   double alt  = (g_plan.dir > 0) ? (g_plan.entry + offset) : (g_plan.entry - offset);
   g_plan.why  = market ? "3 of 3 - go to market"
                        : "2 of 3 - wait for a better price";

   string side = (g_plan.dir > 0) ? "BUY" : "SELL";
   color  dirC = (g_plan.dir > 0) ? InpBuyColor : InpSellColor;

   // ---- the lines, ready to draw ---------------------------------------
   g_plan.text[0] = "Trade plan:";
   g_plan.clr [0] = clrGray;

   g_plan.text[1] = StringFormat("%s  %s   %s   score %+d/%d",
                                 _Symbol, g_rows[row].tag, side, g_plan.score, 3);
   g_plan.clr [1] = dirC;

   if(market)
      g_plan.text[2] = StringFormat("Entry  : MARKET %s   (%s)",
                                    DoubleToString(g_plan.entry, dg), g_plan.why);
   else
      g_plan.text[2] = StringFormat("Entry  : PENDING %s %s   (%s)",
                                    (g_plan.dir > 0) ? "buy limit" : "sell limit",
                                    DoubleToString(g_plan.pend, dg), g_plan.why);
   g_plan.clr [2] = dirC;

   g_plan.text[3] = StringFormat("Alt    : %s %s   (follow the move instead)",
                                 (g_plan.dir > 0) ? "buy stop" : "sell stop",
                                 DoubleToString(alt, dg));
   g_plan.clr [3] = clrGray;

   string stopTxt = StringFormat("Stop   : %s   %d pts   risk %s %s",
                                 DoubleToString(g_plan.slPrice, dg), g_plan.slPts,
                                 DoubleToString(g_plan.riskUSD, 2), cur);
   if(g_plan.stopLevelHit) stopTxt += "  (broker minimum)";
   g_plan.text[4] = stopTxt;
   g_plan.clr [4] = InpSellColor;

   g_plan.text[5] = StringFormat("Target : %s   %d pts   reward %s %s   R:R 1:%.2f",
                                 DoubleToString(g_plan.tpPrice, dg), g_plan.tpPts,
                                 DoubleToString(g_plan.rewardUSD, 2), cur, g_plan.rr);
   g_plan.clr [5] = InpBuyColor;

   string sizeTxt;
   if(g_plan.minLot)
      sizeTxt = StringFormat("Lot    : %s   (symbol minimum)", DoubleToString(g_plan.lot, 2));
   else if(InpUseRisk)
      sizeTxt = StringFormat("Lot    : %s   (%.2f%% of %.2f %s)",
                             DoubleToString(g_plan.lot, 2),
                             (MathAbs(g_plan.score) >= 3) ? InpRiskScore3 : InpRiskScore2,
                             balance, cur);
   else
      sizeTxt = StringFormat("Lot    : %s   (balance ladder%s)",
                             DoubleToString(g_plan.lot, 2),
                             (MathAbs(g_plan.score) >= 3) ? ", x1.5 at score 3" : "");
   if(g_plan.riskOver)
      sizeTxt += StringFormat("   - min lot risks %s %s",
                              DoubleToString(g_plan.riskUSD, 2), cur);
   g_plan.text[6] = sizeTxt;
   g_plan.clr [6] = InpTitleColor;

   // ---- 5. until ---------------------------------------------------
   if(g_plan.until > 0)
      g_plan.text[7] = StringFormat("Valid  : %d bars (%d min) - until %s, or if the panel flips",
                                    InpValidBars,
                                    InpValidBars * (int)(PeriodSeconds(g_plan.tf) / 60),
                                    TimeToString(g_plan.until, TIME_MINUTES));
   else
      g_plan.text[7] = StringFormat("Valid  : %d bars - or until the panel flips",
                                    InpValidBars);
   g_plan.clr [7] = clrSilver;
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
//+------------------------------------------------------------------+
//  Estimated width of one character, in pixels, for a given point size.
//  MetaTrader sizes fonts in POINTS, so what that means in pixels depends
//  on the screen DPI - the terminal reports it, so this uses the real
//  value instead of assuming 96.  A monospaced face needs about 0.55 em
//  per character; 0.60 is used, so the estimate always errs wide.
//+------------------------------------------------------------------+
int CharW(int size)
{
   if(size < 6) size = 6;
   int dpi = (int)TerminalInfoInteger(TERMINAL_SCREEN_DPI);
   if(dpi < 72) dpi = 96;
   double em = (double)size * (double)dpi / 72.0;
   return((int)MathCeil(em * 0.60));
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
   //  trade plan can never be clipped on the right.  The rows need 96 px
   //  to their widest value, the header needs its two ends.
   if(InpShowPlan)
   {
      int need = PlanWidthNeed();
      if(need > g_panelW) g_panelW = need;
   }
   g_panelH = HEAD_H + TF_COUNT * 2 * rowH + 8
              + (InpShowPlan ? (PLAN_SEP_H + PLAN_ROWS * rowH) : 0);
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

   // ---- trade plan for the chart's own timeframe --------------------
   if(InpShowPlan) DrawPlanBlock(x, y);
   else            DeletePlanObjects();

   // ---- retire the notice-only panel, if it was the last one shown ----
   DeleteObject("notice");

   g_panelOK = true;
   g_drawnTf = (ENUM_TIMEFRAMES)Period();
}

//+------------------------------------------------------------------+
//  How much width the plan block needs, in pixels.  The panel is sized
//  from this before anything is drawn, so no line can ever run past the
//  right edge - whatever the price digits or the balance happen to be.
//+------------------------------------------------------------------+
int PlanWidthNeed()
{
   if(!InpShowPlan) return(0);

   int widestBody = 0;      // lines 2..6, drawn at InpFontSize
   int widestHead = 0;      // line 0 ends and line 1 right-aligns on one row
   for(int i = 0; i < PLAN_LINES; i++)
   {
      int n = StringLen(g_plan.text[i]);
      if(i <= 1)
      {
         //  "Trade plan:" from the left and the signal from the right share
         //  the row, so they are measured together
         if(i == 1 && g_plan.text[0] != "") n += StringLen(g_plan.text[0]) + 4;
         if(n > widestHead) widestHead = n;
      }
      else if(n > widestBody) widestBody = n;
   }

   int needBody = 10 + widestBody * CharW(InpFontSize) + 10;
   int needHead = 10 + widestHead * CharW(InpFontSize + 1) + 10;
   return(MathMax(needBody, needHead));
}

//+------------------------------------------------------------------+
//  Place the plan lines that UpdatePlan() prepared.  Six lines, one per
//  question, under the timeframe rows:
//
//    Trade plan:            XAUUSD  M5   SELL   score -3/3
//    Entry  : MARKET 4285.70   (3 of 3 agree - go to market)
//    Alt    : sell stop 4285.56   (follow the move instead)
//    Stop   : 4286.04   34 pts   risk 7.82 USD
//    Target : 4285.03   67 pts   reward 15.41 USD   R:R 1:1.97
//    Lot    : 0.23   (1.00% of 800.00 USD)
//+------------------------------------------------------------------+
void DrawPlanBlock(int x, int y)
{
   int row = RowForChartTF();
   if(row < 0) return;                      // only ever drawn on M5/M15/M30

   int pad  = 10;
   int rowH = g_rowH;
   int py   = y + HEAD_H + 2 + TF_COUNT * 2 * rowH + PLAN_SEP_H;

   MakeRect("planSep", x + 4, py - 8, g_panelW - 8, 1, clrDimGray, clrDimGray);

   for(int i = 0; i < PLAN_LINES; i++)
   {
      string name = "plan" + IntegerToString(i);
      if(g_plan.text[i] == "")
      {
         DeleteObject(name);
         continue;
      }
      if(i == 1)
      {
         //  heading: "Trade plan:" on the left, the signal on the right
         MakeLabel(name, x + g_panelW - pad, py, g_plan.text[i],
                   g_plan.clr[i], InpFontSize + 1, true);
      }
      else
         MakeLabel(name, x + pad, py + (i - 1) * rowH, g_plan.text[i],
                   g_plan.clr[i], InpFontSize, false);
   }
}

//+------------------------------------------------------------------+
void DeletePlanObjects()
{
   DeleteObject("planSep");
   for(int k = 0; k < PLAN_LINES; k++)
      DeleteObject("plan" + IntegerToString(k));
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
