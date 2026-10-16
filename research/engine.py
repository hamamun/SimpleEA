"""
Reference engine -- mirrors, line for line, the logic that will go into the MQL5
adviser.  Every function here is CAUSAL: the value at index i uses only data
from indices <= i, so it can be evaluated bar-by-bar exactly as the EA will.

Components
----------
1. Ehlers Precision Trend (TASC Sept 2024, "Precision Trend Analysis")
       Trend = HighPass(close, L1) - HighPass(close, L2)
       ROC   = (L2 / 2*pi) * (Trend - Trend[1])
   The difference of two highpass filters is a bandpass that keeps cycles
   between L2 and L1 bars.  Near-zero lag, unlike EMA/SMA.

2. Kaufman Efficiency Ratio  ER = |C[n]-C[0]| / sum|C[i]-C[i+1]|
   Regime gate: 1.0 = clean trend, 0.0 = pure chop.

3. Rolling Hurst exponent (R/S and DFA) -- long-memory regime classifier.
   H > 0.5  persistent (trending),  H < 0.5  anti-persistent (mean reverting).
"""

import numpy as np
import pandas as pd

# ----------------------------------------------------------------------------
# Ehlers HighPass3 -- 1:1 transcription of the TradeStation code published in
# TASC September 2024 Traders' Tips (c) John F. Ehlers.
#   a1 = ExpValue(-1.414 * 3.14159 / Period);
#   b1 = 2 * a1 * Cosine(1.414 * 180 / Period);   <-- Cosine() takes DEGREES
#   c2 = b1;  c3 = -a1*a1;  c1 = (1 + c2 - c3)/4;
#   HP = c1*(P - 2*P[1] + P[2]) + c2*HP[1] + c3*HP[2];
# 1.414*180/Period degrees == 1.414*pi/Period radians, so cos() takes that
# angle directly in radians below.
# ----------------------------------------------------------------------------
def highpass3(price: np.ndarray, period: int) -> np.ndarray:
    n = len(price)
    hp = np.zeros(n)
    f = 1.414 * np.pi / period
    a1 = np.exp(-f)
    c2 = 2.0 * a1 * np.cos(f)
    c3 = -a1 * a1
    c1 = (1.0 + c2 - c3) / 4.0
    p1 = price[1] if n > 1 else price[0]
    p2 = price[0]
    h1 = hp[0]
    h2 = 0.0
    for i in range(2, n):
        p0 = price[i]
        hp[i] = c1 * (p0 - 2.0 * p1 + p2) + c2 * h1 + c3 * h2
        p2 = p1
        p1 = p0
        h2 = h1
        h1 = hp[i]
    return hp


def precision_trend(close: np.ndarray, l1: int, l2: int):
    """Returns (trend, roc).  Trend sign = direction, ROC sign = fresh push."""
    hp1 = highpass3(close, l1)
    hp2 = highpass3(close, l2)
    trend = hp1 - hp2
    roc = np.zeros_like(trend)
    roc[1:] = (l2 / 6.28) * (trend[1:] - trend[:-1])
    return trend, roc


# ----------------------------------------------------------------------------
# Kaufman Efficiency Ratio
# ----------------------------------------------------------------------------
def efficiency_ratio(close: np.ndarray, n: int) -> np.ndarray:
    """net move / total path travelled over n bars.  1 = straight line, 0 = chop."""
    out = np.full(len(close), np.nan)
    absd = np.abs(np.diff(close))
    csum = np.concatenate([[0.0], np.cumsum(absd)])          # csum[i] = sum(absd[0:i])
    for i in range(n, len(close)):
        path = csum[i] - csum[i - n]
        out[i] = 0.0 if path <= 0 else abs(close[i] - close[i - n]) / path
    return out


# ----------------------------------------------------------------------------
# Rolling Hurst exponent -- DFA (detrended fluctuation analysis)
# Scaled log-log regression of fluctuation vs window size, on log returns.
# ----------------------------------------------------------------------------
def hurst_dfa(close: np.ndarray, window: int = 256, min_scale: int = 8):
    n = len(close)
    out = np.full(n, np.nan)
    logret = np.zeros(n)
    with np.errstate(divide="ignore", invalid="ignore"):
        logret[1:] = np.log(close[1:] / close[:-1])
    scales = np.unique(np.round(np.logspace(np.log10(min_scale),
                                            np.log10(window // 4), 8)).astype(int))
    for i in range(window, n):
        x = logret[i - window + 1:i + 1]
        x = x[np.isfinite(x)]
        if len(x) < window:
            continue
        prof = np.cumsum(x - x.mean())
        y = np.log(scales.astype(float))
        f = np.empty(len(scales))
        for k, s in enumerate(scales):
            m = len(prof) // s
            if m < 4:
                f[k] = np.nan
                continue
            seg = prof[:m * s].reshape(m, s)
            t = np.arange(s)
            # linear detrend each segment (vectorised)
            tm = t.mean()
            den = ((t - tm) ** 2).sum()
            slope = ((seg - seg.mean(axis=1, keepdims=True)) * (t - tm)).sum(axis=1) / den
            fit = (seg.mean(axis=1, keepdims=True)
                   + slope[:, None] * (t - tm)[None, :])
            f[k] = np.sqrt(((seg - fit) ** 2).mean())
        ok = np.isfinite(f) & (f > 0)
        if ok.sum() >= 3:
            out[i] = np.polyfit(y[ok], np.log(f[ok]), 1)[0]
    return out


def hurst_rs(close: np.ndarray, window: int = 256):
    """Classic rescaled-range Hurst, computed on log returns."""
    n = len(close)
    out = np.full(n, np.nan)
    logret = np.zeros(n)
    with np.errstate(divide="ignore", invalid="ignore"):
        logret[1:] = np.log(close[1:] / close[:-1])
    scales = np.unique(np.round(np.logspace(np.log10(8), np.log10(window // 4), 8)).astype(int))
    for i in range(window, n):
        x = logret[i - window + 1:i + 1]
        x = x[np.isfinite(x)]
        if len(x) < window:
            continue
        rs = np.empty(len(scales))
        for k, s in enumerate(scales):
            m = len(x) // s
            if m < 1:
                rs[k] = np.nan
                continue
            seg = x[:m * s].reshape(m, s)
            dev = np.cumsum(seg - seg.mean(axis=1, keepdims=True), axis=1)
            rng = dev.max(axis=1) - dev.min(axis=1)
            sd = seg.std(axis=1, ddof=1)
            with np.errstate(divide="ignore", invalid="ignore"):
                val = rng / sd
            val = val[np.isfinite(val) & (val > 0)]
            rs[k] = val.mean() if len(val) else np.nan
        ok = np.isfinite(rs) & (rs > 0)
        if ok.sum() >= 3:
            out[i] = np.polyfit(np.log(scales[ok].astype(float)), np.log(rs[ok]), 1)[0]
    return out


# ----------------------------------------------------------------------------
# ATR (Wilder) -- used only to normalise, never to signal
# ----------------------------------------------------------------------------
def atr(high, low, close, n: int) -> np.ndarray:
    prev = np.concatenate([[close[0]], close[:-1]])
    tr = np.maximum(high - low, np.maximum(np.abs(high - prev), np.abs(low - prev)))
    out = np.full(len(close), np.nan)
    if len(tr) < n:
        return out
    a = tr[:n].mean()
    out[n - 1] = a
    for i in range(n, len(tr)):
        a = (a * (n - 1) + tr[i]) / n
        out[i] = a
    return out


def load_csv(path: str) -> pd.DataFrame:
    df = pd.read_csv(path)
    df["datetime"] = pd.to_datetime(df["datetime"], utc=True)
    df = df.sort_values("datetime").reset_index(drop=True)
    df = df[~df["datetime"].duplicated(keep="last")].reset_index(drop=True)
    return df
