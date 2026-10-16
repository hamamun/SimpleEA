"""Signal horizon, part 2: does the move ever get far enough to pay?

Part 1 (horizon_study.py) measured the mean move h bars after a reading and
how long a reading stays on screen.  This part adds the two numbers a trader
actually needs:

  1. MFE / MAE per signal - how far does price run in the signal's favour
     (and against it) while that signal is on the panel?  The signal's own
     lifetime is used, so this is "what this reading would have given me if
     I had held it exactly as long as the panel showed it".

  2. First passage to a target - starting from the close of the bar the
     signal appears on, does price touch +T pips before -T pips?

     Bars are wide on XAUUSD and M1/M5 gold bars routinely contain BOTH
     levels, so a single assumption about which came first is not honest.
     Both bounds are reported instead:
        win_pct_worst   - every ambiguous bar counted as the stop
        win_pct_best    - every ambiguous bar counted as the target
     The truth is inside that bracket; anything else is a modelling choice.

Run:  python first_passage.py            # all datasets
      python first_passage.py XAUUSD     # one symbol
"""

import os
import sys

import numpy as np
import pandas as pd

from horizon_study import (ea_signals, fresh_mask, load_csv, load_m1_year,
                           resample, DATA, ERA_2015, DATA_DIR, MINUTES)
from validate import PIP, SPREAD_PIPS

MAXBARS = 48


def mfe_mae(df, symbol, tf):
    """Per fresh flip: best and worst point before the panel flips again."""
    close = df["close"].to_numpy(float)
    high = df["high"].to_numpy(float)
    low = df["low"].to_numpy(float)
    dir_, score, *_ = ea_signals(close)
    pipv = PIP[symbol.split("-")[0]]
    entries = np.where(fresh_mask(dir_))[0]

    hist_mfe, hist_mae, life = [], [], []
    for i in entries:
        j = i
        while j + 1 < len(close) and dir_[j + 1] == dir_[i]:
            j += 1
        d = dir_[i]
        if d > 0:
            fav = (high[i + 1:j + 2].max() - close[i]) / pipv if j > i else 0.0
            adv = (close[i] - low[i + 1:j + 2].min()) / pipv if j > i else 0.0
        else:
            fav = (close[i] - low[i + 1:j + 2].min()) / pipv if j > i else 0.0
            adv = (high[i + 1:j + 2].max() - close[i]) / pipv if j > i else 0.0
        hist_mfe.append(fav)
        hist_mae.append(adv)
        life.append(j - i + 1)

    hist_mfe = np.array(hist_mfe)
    hist_mae = np.array(hist_mae)
    sp = SPREAD_PIPS[symbol.split("-")[0]]
    return dict(symbol=symbol, tf=tf, entries=len(hist_mfe),
                life_median_bars=float(np.median(life)),
                mfe_median=round(float(np.median(hist_mfe)), 2),
                mfe_p75=round(float(np.percentile(hist_mfe, 75)), 2),
                mfe_p90=round(float(np.percentile(hist_mfe, 90)), 2),
                mae_median=round(float(np.median(hist_mae)), 2),
                pct_mfe_over_spread=round(100.0 * float((hist_mfe > sp).mean()), 1),
                spread=sp)


def first_passage(df, symbol, tf, targets, maxbars=MAXBARS):
    """First touch of +T / -T pips from the close of the flip bar."""
    close = df["close"].to_numpy(float)
    high = df["high"].to_numpy(float)
    low = df["low"].to_numpy(float)
    dir_, score, *_ = ea_signals(close)
    pipv = PIP[symbol.split("-")[0]]
    entries = np.where(fresh_mask(dir_))[0]

    rows = []
    for T in targets:
        wins = losses = ambig = 0
        bars_win = []
        for i in entries:
            if i + 1 >= len(close):
                continue
            d = dir_[i]
            tp = close[i] + d * T * pipv
            sl = close[i] - d * T * pipv
            for k in range(1, min(maxbars, len(close) - 1 - i) + 1):
                if d > 0:
                    hit_tp = high[i + k] >= tp
                    hit_sl = low[i + k] <= sl
                else:
                    hit_tp = low[i + k] <= tp
                    hit_sl = high[i + k] >= sl
                if hit_tp and hit_sl:
                    ambig += 1
                    break
                if hit_tp:
                    wins += 1; bars_win.append(k)
                    break
                if hit_sl:
                    losses += 1
                    break
            # neither touched inside the window: unresolved, counted nowhere
        total = wins + losses + ambig
        if total == 0:
            continue
        rows.append(dict(
            symbol=symbol, tf=tf, target_pips=T, n=total,
            win_pct_worst=round(100.0 * wins / total, 1),
            win_pct_best=round(100.0 * (wins + ambig) / total, 1),
            clean_loss_pct=round(100.0 * losses / total, 1),
            ambiguous_pct=round(100.0 * ambig / total, 1),
            median_bars_to_win=float(np.median(bars_win)) if bars_win else np.nan))
    return pd.DataFrame(rows)


def build_datasets(only=None):
    out = []
    for sym, tf, rel, _ in DATA:
        p = os.path.join(DATA_DIR, rel)
        if os.path.exists(p) and (not only or sym == only):
            out.append((sym, tf, p, None))
    for sym, tf, year in ERA_2015:
        p = os.path.join(DATA_DIR, "..", "old", "x", "%s_%d.csv" % (sym, year))
        if os.path.exists(p) and (not only or sym == only):
            out.append((sym, tf, p, year))
    return out


def main():
    only = sys.argv[1] if len(sys.argv) > 1 else None

    mfe_rows, fp_rows = [], []
    for base_sym, tf, path, year in build_datasets(only):
        sym = "%s-%d" % (base_sym, year) if year else base_sym
        df = resample(load_m1_year(path), MINUTES[tf]) if year else load_csv(path)
        sp = SPREAD_PIPS[base_sym]
        targets = sorted({round(sp, 2), round(sp * 2, 2), round(sp * 4, 2)})

        m = mfe_mae(df, sym, tf)
        mfe_rows.append(m)
        print("\n===== %s %s =====  (retail spread %.1f pips)" % (sym, tf, sp))
        print(pd.DataFrame([m]).drop(columns=["symbol", "tf", "spread"]).to_string(index=False))

        t = first_passage(df, sym, tf, targets)
        fp_rows.append(t)
        print(t.to_string(index=False))

    os.makedirs("results", exist_ok=True)
    mfe = pd.DataFrame(mfe_rows)
    fp = pd.concat(fp_rows, ignore_index=True)
    mfe.to_csv("results/horizon_mfe.csv", index=False)
    fp.to_csv("results/horizon_first_passage.csv", index=False)

    pd.set_option("display.width", 250)
    print("\n\n########## MFE / MAE per signal, while that signal is on the panel ##########")
    print(mfe.to_string(index=False))
    print("\nwritten: results/horizon_mfe.csv, results/horizon_first_passage.csv")


if __name__ == "__main__":
    main()
