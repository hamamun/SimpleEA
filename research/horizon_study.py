"""Signal horizon study - how many bars ahead is a SimpleEA reading informative?

Question this answers: the panel shows, say, XAUUSD M5 "SELL, Score -3 / 3".
From which bar does that apply, and how many bars ahead is it worth anything?

Method (all causal, exactly as the EA evaluates):
  * At the close of every bar i the EA's own rule is evaluated on closed bars
    up to i: Precision Trend vote, ROC vote, Hurst vote (the EA's variance-
    scaling estimator, window 256, thresholds 0.55/0.45), score >= +2 / <= -2,
    and the Kaufman ER dead-market gate at 0.10.
  * The forward return is measured from that same close[i] to close[i+h] -
    the bar where the reading appears is the entry bar, and h counts the bars
    AFTER it.
  * For every horizon h we report hit rate and mean signed pips per signal,
    with a 95% CI and p-value from a circular block bootstrap (block length h,
    which keeps the overlapping forward windows honest).
  * Persistence is measured separately: how long a direction stays on screen
    before the panel changes its mind.

Usage:
    python horizon_study.py            # all datasets found in DATA
    python horizon_study.py XAUUSD     # one symbol

Raw CSVs are not committed (see README); put them anywhere and edit DATA.
"""

import os
import sys

import numpy as np
import pandas as pd

from engine import precision_trend, efficiency_ratio
from validate import PIP, SPREAD_PIPS

RNG = np.random.default_rng(11)
BOOT = 1000                      # bootstrap resamples per horizon

# ---------------------------------------------------------------------------
# Data
# ---------------------------------------------------------------------------
DATA_DIR = os.environ.get("SIMPLEEA_DATA", "/tmp/fxdata")

DATA = [
    # (symbol, timeframe, path, bars-per-timeframe-file)
    ("XAUUSD", "M5",  "xauusd-5m-ohlcv-metals-historical-data/XAUUSD_5m.csv", 1),
    ("EURUSD", "M5",  "eurusd-5m-ohlcv-forex-historical-data/EURUSD_5m.csv", 1),
    ("GBPUSD", "M5",  "gbpusd-5m-ohlcv-forex-historical-data/GBPUSD_5m.csv", 1),
    ("USDJPY", "M5",  "usdjpy-5m-ohlcv-forex-historical-data/USDJPY_5m.csv", 1),
    ("XAUUSD", "M15", "xauusd-15m-ohlcv-metals-historical-data/XAUUSD_15m.csv", 1),
    ("EURUSD", "M15", "eurusd-15m-ohlcv-forex-historical-data/EURUSD_15m.csv", 1),
    ("XAUUSD", "M30", "xauusd-30m-ohlcv-metals-historical-data/XAUUSD_30m.csv", 1),
    ("EURUSD", "M30", "eurusd-30m-ohlcv-forex-historical-data/EURUSD_30m.csv", 1),
]

MINUTES = {"M5": 5, "M15": 15, "M30": 30}
HORIZONS = {"M5": tuple(range(1, 49)), "M15": tuple(range(1, 33)), "M30": tuple(range(1, 25))}

# EA defaults (SimpleAdvisor.mq5)
L1, L2 = 150, 24
ER_N, ER_DEAD = 20, 0.10
H_WIN, H_TREND, H_REVERT = 256, 0.55, 0.45
FADE_IN_RANGE = False


def load_csv(path):
    df = pd.read_csv(path)
    df["datetime"] = pd.to_datetime(df["datetime"], utc=True)
    df = df.sort_values("datetime").reset_index(drop=True)
    df = df[~df["datetime"].duplicated(keep="last")].reset_index(drop=True)
    return df


def load_m1_year(path):
    """EURUSD M1 era file: 'ts;open;high;low;close;volume', ts = YYYYMMDD HHMMSS."""
    df = pd.read_csv(path, sep=";", header=None,
                     names=["ts", "open", "high", "low", "close", "volume"])
    df["datetime"] = pd.to_datetime(df["ts"], format="%Y%m%d %H%M%S", utc=True)
    df = df.drop(columns=["ts"]).sort_values("datetime").reset_index(drop=True)
    return df


def resample(df, minutes):
    d = df.set_index("datetime")
    out = d.resample("%dmin" % minutes).agg({"open": "first", "high": "max",
                                             "low": "min", "close": "last"}).dropna()
    return out.reset_index()


ERA_2015 = [("EURUSD", "M5", 2015), ("EURUSD", "M15", 2015), ("EURUSD", "M30", 2015),
            ("EURUSD", "M5", 2016), ("EURUSD", "M30", 2016)]


# ---------------------------------------------------------------------------
# The EA's Hurst estimator (variance scaling), vectorised
# ---------------------------------------------------------------------------
# MQL, verbatim:
#     start = i - window + 1
#     for scale in (1,2,4,8,16):
#         k = window // scale
#         for b in 0..k-1:  block sum of log returns over [start+b*scale, ...+scale)
#         sd = sample std of the k block sums (ddof = 1)
#     H = slope of log(sd) against log(scale) over the scales with sd > 0
#
# Blocks are aligned at the window start, so for scale s the alignment depends
# on (i - window + 1) mod s.  For each alignment the block sums form a plain
# series, so the std over the k blocks inside a window is a rolling statistic
# computed from cumulative sums.  Same numbers, O(n) per alignment instead of
# O(n * window) in Python.
def hurst_ea(close, window=H_WIN, scales=(1, 2, 4, 8, 16)):
    n = len(close)
    out = np.full(n, 0.5)                     # MQL returns 0.5 when undefined
    if n < window + 1:
        return out

    lr = np.zeros(n)
    with np.errstate(divide="ignore", invalid="ignore"):
        lr[1:] = np.log(close[1:] / close[:-1])
    lr[~np.isfinite(lr)] = 0.0                # MQL skips non-positive prices

    lx_log = np.log(np.array(scales, dtype=float))
    valid_scales = [s for s in scales if window // s >= 4]
    if len(valid_scales) < 3:
        return out

    # rolling log(sd) of the block sums, per scale, for every alignment
    logsd = {}
    for s in valid_scales:
        k = window // s
        best = np.full(n, np.nan)
        P = np.concatenate([[0.0], np.cumsum(lr)])
        for off in range(s):
            # block sums for the blocks aligned at absolute position `off`;
            # a block [a, a+s) sums the log returns lr[a..a+s-1], so the last
            # usable start is a = n-s (it needs close[a-1] .. close[n-1]).
            starts = np.arange(off, n - s + 1, s)
            sums = P[starts + s] - P[starts]
            m = len(sums)
            if m < k:
                continue
            c1 = np.concatenate([[0.0], np.cumsum(sums)])
            c2 = np.concatenate([[0.0], np.cumsum(sums * sums)])
            # window of k block sums starting at block index j
            j = np.arange(0, m - k + 1)
            S1 = c1[j + k] - c1[j]
            S2 = c2[j + k] - c2[j]
            var = (S2 - S1 * S1 / k) / (k - 1)
            with np.errstate(invalid="ignore"):
                sd = np.sqrt(var)
            # bar index i such that this window's blocks are exactly [start..i]
            # start = off + j*s, i = start + window - 1
            i = off + j * s + window - 1
            ok = (i < n) & np.isfinite(sd) & (sd > 0)
            best[i[ok]] = np.log(sd[ok])
        logsd[s] = best

    # per bar, least-squares slope of log(sd) against log(scale), over the
    # scales that produced a usable sd at that bar
    Y = np.vstack([logsd[s] for s in valid_scales])          # (S, n)
    X = np.broadcast_to(lx_log[:, None], Y.shape)
    mask = np.isfinite(Y)
    counts = mask.sum(axis=0)
    denom = np.maximum(counts, 1)
    mx = np.where(mask, X, 0.0).sum(axis=0) / denom
    my = np.where(mask, Y, 0.0).sum(axis=0) / denom
    dx = np.where(mask, X - mx, 0.0)
    dy = np.where(mask, Y - my, 0.0)
    sxy = (dx * dy).sum(axis=0)
    sxx = (dx * dx).sum(axis=0)

    # MQL guards on i + 1 >= window; the window that starts at index 0 would
    # need close[-1], which the EA never reaches in practice, so the first
    # `window` bars keep the 0.5 default.
    ok = (counts >= 3) & (sxx > 0) & (np.arange(n) >= window)
    out[ok] = sxy[ok] / sxx[ok]
    return out


# ---------------------------------------------------------------------------
# The EA's signal, bar for bar
# ---------------------------------------------------------------------------
def ea_signals(close):
    """Returns dir, score, trend, roc, H, ER - all exactly as the EA computes."""
    trend, roc = precision_trend(close, L1, L2)
    H = hurst_ea(close)
    ER = efficiency_ratio(close, ER_N)
    ER = np.where(np.isfinite(ER), ER, 0.0)     # MQL returns 0.0 before period

    v1 = np.sign(np.round(trend, 12)).astype(int)
    v2 = np.sign(np.round(roc, 12)).astype(int)
    v3 = np.where(H > H_TREND, v1, np.where(FADE_IN_RANGE & (H < H_REVERT), -v1, 0))
    score = v1 + v2 + v3

    dir_ = np.where(ER >= ER_DEAD,
                    np.where(score >= 2, 1, np.where(score <= -2, -1, 0)),
                    0).astype(int)
    return dir_, score, trend, roc, H, ER


def fwd(close, h):
    out = np.full(len(close), np.nan)
    out[:-h] = close[h:] - close[:-h]
    return out


# ---------------------------------------------------------------------------
# Statistics
# ---------------------------------------------------------------------------
def non_overlapping(x_idx, close, dir_, h, pipv):
    """Greedy non-overlapping pick of signal bars, so the h-bar windows do
    not share bars and a plain t-test is honest."""
    picks = []
    last = -1 - h
    n_max = len(close) - h          # the window must fit inside the data
    for i in x_idx:
        if i >= n_max:
            break
        if i >= last + h:
            picks.append(i)
            last = i
    if len(picks) < 30:
        return np.nan, np.nan, np.nan, 0
    p = np.array(picks)
    r = (close[p + h] - close[p]) / pipv * dir_[p]
    n = len(r)
    mean = float(r.mean())
    se = float(r.std(ddof=1) / np.sqrt(n)) if n > 1 else np.nan
    pval = np.nan
    if se > 0:
        from math import erf, sqrt
        z = abs(mean / se)
        pval = 2.0 * (1.0 - 0.5 * (1.0 + erf(z / sqrt(2.0))))
    return mean, mean - 1.96 * se, pval, n


def block_boot_mean(x, block, nsim=BOOT):
    """Circular block bootstrap CI/p for the mean of x (x is time-ordered)."""
    n = len(x)
    if n < 30:
        return np.nan, np.nan, np.nan
    k = int(np.ceil(n / block))
    starts = RNG.integers(0, n, size=(nsim, k))
    offs = np.arange(block)
    idx = ((starts[:, :, None] + offs[None, None, :]).reshape(nsim, -1)[:, :n]) % n
    out = x[idx].mean(axis=1)
    lo, hi = np.percentile(out, [2.5, 97.5])
    p = 2.0 * min((out <= 0).mean(), (out >= 0).mean())
    return lo, hi, min(p, 1.0)


def horizon_table(df, symbol, tf, rules):
    close = df["close"].to_numpy(float)
    dir_, score, *_ = ea_signals(close)
    pipv = PIP[symbol.split("-")[0]]          # era labels are "EURUSD-2015" 
    rows = []

    for name, mask in rules.items():
        idx = np.where(mask & (dir_ != 0))[0]
        if len(idx) < 60:
            continue
        for h in HORIZONS[tf]:
            idx_h = idx[idx < len(close) - h]
            if len(idx_h) < 60:
                continue
            r = (close[idx_h + h] - close[idx_h]) / pipv * dir_[idx_h]
            hit = float((np.sign(r) == np.sign(dir_[idx_h])).mean())
            mean = float(r.mean())
            lo, hi, p = block_boot_mean(r, block=h)
            ni_pips, ni_lo, ni_p, ni_n = non_overlapping(idx, close, dir_, h, pipv)
            rows.append(dict(symbol=symbol, tf=tf, rule=name, h=h,
                             minutes=h * MINUTES[tf], n=len(idx_h),
                             hit=round(hit, 4), pips=round(mean, 3),
                             ci_lo=round(lo, 3), ci_hi=round(hi, 3),
                             p=round(p, 4),
                             ni_n=ni_n, ni_pips=round(ni_pips, 3) if ni_n else np.nan,
                             ni_ci_lo=round(ni_lo, 3) if ni_n else np.nan,
                             ni_p=round(ni_p, 4) if ni_n else np.nan))
    return pd.DataFrame(rows)


def fresh_mask(dir_, score=None, want=None):
    """Bars where the panel FLIPS into a direction: the moment a trader
    would actually act on, as opposed to every bar that is still showing
    the same call."""
    prev = np.concatenate([[0], dir_[:-1]])
    m = (dir_ != 0) & (dir_ != prev)
    if want is not None:
        m = m & (np.abs(score) == want)
    return m


def life_study(close, dir_, idx, tf, pipv):
    """For every fresh entry: how many bars is that call still on screen?"""
    n = len(close)
    bars_to_flip, mfe, bars_to_mfe, ret_at_flip = [], [], [], []
    for i in idx:
        j = i
        while j + 1 < n and dir_[j + 1] == dir_[i]:
            j += 1
        run = j - i + 1
        seg = (close[i:j + 1] - close[i]) / pipv * dir_[i]
        k = int(np.argmax(seg))
        bars_to_flip.append(run)
        mfe.append(seg[k])
        bars_to_mfe.append(k + 1)
        ret_at_flip.append(seg[-1])
    bars_to_flip = np.array(bars_to_flip, float)
    mfe = np.array(mfe)
    bars_to_mfe = np.array(bars_to_mfe, float)
    ret_at_flip = np.array(ret_at_flip)
    return dict(symbol=None, tf=tf, entries=len(bars_to_flip),
                life_median_bars=float(np.median(bars_to_flip)),
                life_q1=float(np.percentile(bars_to_flip, 25)),
                life_q3=float(np.percentile(bars_to_flip, 75)),
                life_median_min=float(np.median(bars_to_flip)) * MINUTES[tf],
                pct_flip_within_3bars=float((bars_to_flip <= 3).mean()),
                pct_flip_within_10bars=float((bars_to_flip <= 10).mean()),
                mfe_median_pips=float(np.median(mfe)),
                bars_to_mfe_median=float(np.median(bars_to_mfe)),
                pips_at_flip_median=float(np.median(ret_at_flip)),
                pips_at_flip_mean=float(ret_at_flip.mean()))


def persistence(close, dir_, tf):
    """How long a reading stays on screen, in bars and in minutes."""
    nz = dir_ != 0
    runs = []
    i = 0
    while i < len(dir_):
        if not nz[i]:
            i += 1
            continue
        j = i
        while j + 1 < len(dir_) and dir_[j + 1] == dir_[i]:
            j += 1
        runs.append(j - i + 1)
        i = j + 1
    runs = np.array(runs)
    if len(runs) == 0:
        return {}
    # survival: starting from a bar in the middle of a run (a realistic random
    # check of the panel), how often is the same direction still shown k later?
    surv = {}
    idx = np.where(nz)[0]
    for k in (1, 2, 3, 5, 10, 20, 30):
        ok = idx[idx < len(dir_) - k]
        if len(ok) < 50:
            continue
        surv[k] = float((dir_[ok + k] == dir_[ok]).mean())
    return dict(runs=runs, median=float(np.median(runs)),
                q1=float(np.percentile(runs, 25)), q3=float(np.percentile(runs, 75)),
                mean=float(runs.mean()), surv=surv, minutes=MINUTES[tf])


# ---------------------------------------------------------------------------
def summarise(tab, tf):
    """Peak horizon, half-life and the horizon where the edge stops being > 0."""
    out = []
    for (sym, rule), g in tab.groupby(["symbol", "rule"]):
        g = g.sort_values("h")
        pips = g["pips"].to_numpy()
        hs = g["h"].to_numpy()
        peak_i = int(np.argmax(pips))
        peak_h, peak = int(hs[peak_i]), float(pips[peak_i])
        # cumulative edge: where does half of the peak-horizon edge arrive?
        cum = np.cumsum(pips)
        half = np.searchsorted(cum, cum[peak_i] / 2.0) + 1 if cum[peak_i] > 0 else -1
        # last horizon whose CI is entirely above zero
        sig = g[(g.ci_lo > 0)]
        last_sig = int(sig["h"].max()) if len(sig) else 0
        # horizon at which the average signal is no longer positive
        nz = np.where(pips <= 0)[0]
        zero_from = int(hs[nz[0]]) if len(nz) else 0
        out.append(dict(symbol=sym, tf=tf, rule=rule, signals=int(g["n"].iloc[0]),
                        peak_h=peak_h, peak_min=peak_h * MINUTES[tf],
                        peak_pips=round(peak, 3), half_life_h=half,
                        last_ci_positive_h=last_sig, first_nonpositive_h=zero_from))
    return pd.DataFrame(out)


def main():
    only = sys.argv[1] if len(sys.argv) > 1 else None

    all_tab, all_sum, all_pers, all_life = [], [], [], []

    # ---- datasets: 2026 third-party feed, plus independent 2015/2016 era --
    datasets = []
    for sym, tf, rel, _mult in DATA:
        p = os.path.join(DATA_DIR, rel)
        if os.path.exists(p):
            datasets.append((sym, tf, p, None))
        else:
            print("missing:", p)

    era_dir = os.path.join(DATA_DIR, "..", "old", "x")
    for sym, tf, year in ERA_2015:
        p = os.path.join(era_dir, "%s_%d.csv" % (sym, year))
        if os.path.exists(p):
            datasets.append((sym, tf, p, year))
        else:
            print("missing (era):", p)

    for base_sym, tf, path, year in datasets:
        if only and base_sym != only:
            continue
        if year:
            df = resample(load_m1_year(path), MINUTES[tf])
            sym = "%s-%d" % (base_sym, year)
        else:
            df = load_csv(path)
            sym = base_sym
        pipv_sym = base_sym
        close = df["close"].to_numpy(float)
        dir_, score, *_ = ea_signals(close)

        rules = {
            "EA signal (|score|>=2)": np.ones(len(close), dtype=bool),
            "score 3/3": np.abs(score) == 3,
            "score 2/3": np.abs(score) == 2,
            "fresh flip (any)": fresh_mask(dir_),
            "fresh flip 3/3": fresh_mask(dir_, score, 3),
        }
        tab = horizon_table(df, sym, tf, rules)
        all_tab.append(tab)

        for name, want in (("fresh flip (any)", None), ("fresh flip 3/3", 3)):
            fm = fresh_mask(dir_, score, want)
            life = life_study(close, dir_, np.where(fm)[0], tf, PIP[pipv_sym])
            life["symbol"] = sym
            life["rule"] = name
            all_life.append(life)

        p = persistence(close, dir_, tf)
        all_pers.append(dict(symbol=sym, tf=tf, runs=len(p.get("runs", [])),
                             median_bars=p.get("median"), q1_bars=p.get("q1"),
                             q3_bars=p.get("q3"),
                             median_min=(p.get("median") or 0) * MINUTES[tf],
                             **{"still_same_%d" % k: round(v, 3)
                                for k, v in p.get("surv", {}).items()}))

        s = summarise(tab, tf)
        all_sum.append(s)

        cover = float((dir_ != 0).mean())
        tf_real = tf
        if year:
            tf_real = tf
        print("\n===== %s %s =====  %d bars  %s -> %s   signals on %.1f%% of bars"
              % (sym, tf_real, len(df), df["datetime"].iloc[0].date(),
                 df["datetime"].iloc[-1].date(), cover * 100))
        print(s.to_string(index=False))

    tab = pd.concat(all_tab, ignore_index=True)
    summ = pd.concat(all_sum, ignore_index=True)
    pers = pd.DataFrame(all_pers)
    life = pd.DataFrame(all_life)

    os.makedirs("results", exist_ok=True)
    tab.to_csv("results/horizon_by_bar.csv", index=False)
    summ.to_csv("results/horizon_summary.csv", index=False)
    pers.to_csv("results/horizon_persistence.csv", index=False)
    life.to_csv("results/horizon_life.csv", index=False)

    pd.set_option("display.width", 250)
    print("\n\n########## HORIZON SUMMARY (all datasets) ##########")
    print(summ.to_string(index=False))
    print("\n########## PERSISTENCE (how long a reading stays on screen) ##########")
    print(pers.to_string(index=False))

    print("\n########## SIGNAL LIFE (fresh flips only) ##########")
    print(life[["symbol", "tf", "rule", "entries", "life_median_bars", "life_median_min",
                "life_q1", "life_q3", "pct_flip_within_3bars", "pct_flip_within_10bars",
                "mfe_median_pips", "bars_to_mfe_median",
                "pips_at_flip_median"]].to_string(index=False))

    print("\n\n########## EDGE BY HORIZON - EA signal, all scores ##########")
    for (sym, tf), g in tab[tab.rule == "EA signal (|score|>=2)"].groupby(["symbol", "tf"]):
        keep = g[g.h.isin([1, 2, 3, 4, 6, 8, 12, 16, 20, 24, 32, 40, 48])]
        print("\n%s %s  (pips = mean signed move per signal, CI from block bootstrap)"
              % (sym, tf))
        print(keep[["h", "minutes", "n", "hit", "pips", "ci_lo", "ci_hi", "p"]].to_string(index=False))

    print("\n\n########## EDGE BY HORIZON - fresh flips only ##########")
    for (sym, tf), g in tab[tab.rule == "fresh flip (any)"].groupby(["symbol", "tf"]):
        keep = g[g.h.isin([1, 2, 3, 4, 6, 8, 12, 16, 20, 24, 32, 40, 48])]
        print("\n%s %s  fresh flips" % (sym, tf))
        print(keep[["h", "minutes", "n", "hit", "pips", "ci_lo", "ci_hi", "p",
                     "ni_n", "ni_pips", "ni_ci_lo", "ni_p"]].to_string(index=False))

    print("\nspread hurdles used for reference (retail-typical pips):",
          {k: v for k, v in SPREAD_PIPS.items()})


if __name__ == "__main__":
    main()
