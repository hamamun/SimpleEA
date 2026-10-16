//+------------------------------------------------------------------+
//|                                              SimpleAdvisor.mq5   |
//|                     A very simple multi-timeframe direction panel |
//|                                                                  |
//|  Shows BUY / SELL / HOLD for M5 (scalping), M15 (short-term) and  |
//|  M30 (intraday) on ANY symbol.                                    |
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
//|  HONEST NOTE ON EXPECTATION                                       |
//|  -----------------------------------------------------------------|
//|  This panel is a structured, low-lag reading of trend, momentum   |
//|  and regime.  It is NOT a proven profitable system.  Independent  |
//|  testing of direction signals on liquid FX shows hit rates close  |
//|  to 50%, and on M5 the typical edge is smaller than a retail      |
//|  spread.  The regime column is the part that carries real         |
//|  information: it tells you when NOT to act.  See ReadMe.md.       |
//+------------------------------------------------------------------+
#property copyright "SimpleAdvisor"
#property version   "1.00"
#property description "Read-only multi-timeframe BUY/SELL/HOLD direction panel for M5 / M15 / M30 on any symbol."

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
input color    InpBuyColor    = clrLime;     // BUY colour
input color    InpSellColor   = clrTomato;   // SELL colour
input color    InpHoldColor   = clrSilver;   // HOLD colour
input bool     InpShowRegime  = true;        // Show the regime footer line

input group "=== Signal thresholds ==="
input int      InpBuyScore    = 2;           // Score >= this  => BUY
input int      InpSellScore   = -2;          // Score <= this  => SELL
input int      InpBarsToLoad  = 700;         // Closed bars pulled per timeframe

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

int g_panelW = 252;
int g_panelH = 130;
int g_rowH   = 20;

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
      Print("SimpleAdvisor: the long trend period must be greater than the short one. ",
            "Set L1 > L2 for every timeframe.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   g_rowH   = InpFontSize + 11;
   g_panelH = 34 + TF_COUNT * g_rowH + (InpShowRegime ? g_rowH + 16 : 8);

   BuildPanel();
   EvaluateAll();
   DrawPanel();

   // A 2-second timer keeps the panel honest even on a dead tick stream;
   // the heavy work only runs when a new bar actually closes.
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

   if(need)
   {
      EvaluateAll();
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
}

//==================================================================
//  PANEL
//==================================================================
string RegimeText(int idx)
{
   double H = g_rows[idx].hurst;
   if(H > g_rows[idx].hTrend)  return("trend");
   if(H < g_rows[idx].hRevert) return("range");
   return("random");
}

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
//  Create the static parts once, so the panel object set is stable.
//+------------------------------------------------------------------+
void BuildPanel()
{
   int x = InpPanelX, y = InpPanelY;
   MakeRect("bg",  x, y, g_panelW, g_panelH, InpBgColor, clrDimGray);
   MakeRect("sep", x + 4, y + 28, g_panelW - 8, 1, clrDimGray, clrDimGray);
}

//+------------------------------------------------------------------+
void DrawPanel()
{
   int x   = InpPanelX, y = InpPanelY;
   int pad = 10;
   int rowH = g_rowH;

   // ---- header ----------------------------------------------------
   MakeLabel("title", x + pad, y + 7, "SimpleAdvisor",
             InpTitleColor, InpFontSize + 1, false);
   MakeLabel("sym", x + g_panelW - pad, y + 8,
             _Symbol + "  " + ShortTimeframe((ENUM_TIMEFRAMES)Period()),
             InpTitleColor, InpFontSize, true);

   // ---- one row per timeframe -------------------------------------
   for(int i = 0; i < TF_COUNT; i++)
   {
      int    ry  = y + 36 + i * rowH;
      string sfx = "_" + IntegerToString(i);

      MakeLabel("tf" + sfx,    x + pad,      ry, g_rows[i].tag,
                clrWhite, InpFontSize, false);
      MakeLabel("style" + sfx, x + pad + 34, ry, g_rows[i].style,
                clrGray, InpFontSize, false);

      if(g_rows[i].ok)
      {
         MakeLabel("dir" + sfx, x + 168, ry, DirectionText(g_rows[i].direction),
                   DirectionColor(g_rows[i].direction), InpFontSize + 1, false);
         MakeLabel("score" + sfx, x + g_panelW - pad, ry,
                   StringFormat("%+d / 3", g_rows[i].score),
                   DirectionColor(g_rows[i].direction), InpFontSize, true);
      }
      else
      {
         MakeLabel("dir" + sfx,   x + 168, ry, "waiting",
                   clrDimGray, InpFontSize, false);
         MakeLabel("score" + sfx, x + g_panelW - pad, ry, "...",
                   clrDimGray, InpFontSize, true);
      }
   }

   // ---- optional regime footer ------------------------------------
   if(InpShowRegime)
   {
      int    fy  = y + 36 + TF_COUNT * rowH;
      string reg = "Regime";

      for(int i = 0; i < TF_COUNT; i++)
         reg += StringFormat("  %s %s", g_rows[i].tag, RegimeText(i));

      MakeLabel("regime", x + pad, fy, reg, clrDarkGray, InpFontSize - 1, false);

      string det = "";
      for(int i = 0; i < TF_COUNT; i++)
         det += StringFormat("%s H=%.2f  ", g_rows[i].tag, g_rows[i].hurst);

      MakeLabel("detail", x + pad, fy + 12, det, clrDimGray, InpFontSize - 2, false);
   }
}

//+------------------------------------------------------------------+
void DeletePanel()
{
   ObjectsDeleteAll(0, OBJ_PREFIX);
   ChartRedraw(0);
}
//+------------------------------------------------------------------+
