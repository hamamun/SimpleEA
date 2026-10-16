"""Validation harness: does the direction engine carry forward-return edge?

Causal evaluation: the signal is decided at the close of bar i and the forward
return is measured from close[i] to close[i+h].  Costs are NOT modelled in the
raw numbers -- the spread hurdle is applied separately so we can see how much
edge has to survive.
"""

import sys
import numpy as np
import pandas as pd
from engine import (precision_trend, efficiency_ratio, hurst_dfa, hurst_rs,
                    atr, load_csv)

PIP = {"EURUSD": 0.0001, "GBPUSD": 0.0001, "USDJPY": 0.01, "XAUUSD": 0.1}
SPREAD_PIPS = {"EURUSD": 0.8, "GBPUSD": 1.0, "USDJPY": 1.0, "XAUUSD": 1.8}  # retail-typical


def fwd_ret(close, h):
    out = np.full(len(close), np.nan)
    out[:-h] = close[h:] - close[:-h]
    return out


def hit_stats(sel, fwd, pipv):
    """sel: boolean mask of bars where we act.  direction taken from `sign`."""
    if sel.sum() == 0:
        return None
    return sel.sum(), fwd[sel]


def evaluate(df, symbol, tf, l1, l2, er_n, er_min, h_list, gate=None):
    close = df["close"].to_numpy(float)
    high = df["high"].to_numpy(float)
    low = df["low"].to_numpy(float)
    n = len(close)

    trend, roc = precision_trend(close, l1, l2)
    er = efficiency_ratio(close, er_n)
    a = atr(high, low, close, 14)
    pipv = PIP[symbol]

    # ---- rule: direction = trend sign, confirmed by ROC sign -------------
    sig = np.zeros(n, dtype=int)                     # +1 buy, -1 sell, 0 hold
    up = (trend > 0) & (roc > 0)
    dn = (trend < 0) & (roc < 0)
    sig[up] = 1
    sig[dn] = -1
    sig = np.where(np.isfinite(er) & np.isfinite(a), sig, 0)
    if er_min > 0:
        sig[er < er_min] = 0
    if gate is not None:
        sig[~gate] = 0

    rows = []
    for h in h_list:
        fr = fwd_ret(close, h)
        ok = np.isfinite(fr) & (sig != 0)
        if ok.sum() < 30:
            continue
        d = sig[ok].astype(float)
        r = fr[ok]
        won = (np.sign(r) == d)
        hit = won.mean()
        se = np.sqrt(hit * (1 - hit) / len(r))
        pnl_pips = (d * r / pipv)
        edge = pnl_pips.mean()
        # cost of crossing the spread once per trade
        cost = SPREAD_PIPS[symbol]
        rows.append(dict(symbol=symbol, tf=tf, L1=l1, L2=l2, er_n=er_n,
                         er_min=er_min, h=h, nsig=int(ok.sum()),
                         cover=round(ok.sum() / n, 3),
                         hit=round(hit, 4), hit_se=round(se, 4),
                         edge_pips=round(edge, 3),
                         net_pips=round(edge - cost, 3),
                         edge_atr=round((d * r / a[ok]).mean(), 4),
                         med_atr_pips=round(np.median(a[ok] / pipv), 1)))
    return pd.DataFrame(rows)


def baseline_ema(df, symbol, tf, fast=9, slow=21, h_list=(6, 12, 24)):
    close = df["close"].to_numpy(float)
    n = len(close)
    ef = pd.Series(close).ewm(span=fast, adjust=False).mean().to_numpy()
    es = pd.Series(close).ewm(span=slow, adjust=False).mean().to_numpy()
    sig = np.where(ef > es, 1, -1)
    rows = []
    for h in h_list:
        fr = fwd_ret(close, h)
        ok = np.isfinite(fr)
        d = sig[ok].astype(float)
        r = fr[ok]
        hit = (np.sign(r) == d).mean()
        rows.append(dict(symbol=symbol, tf=tf, rule=f"EMA{fast}/{slow}", h=h,
                         hit=round(hit, 4),
                         edge_pips=round((d * r / PIP[symbol]).mean(), 3)))
    return pd.DataFrame(rows)
