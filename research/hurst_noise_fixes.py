#!/usr/bin/env python3
"""
Experiment 2 for research/hurst_noise_bias.py.

That script showed the M5 Hurst label is wrecked by bid/ask bounce, not by
the 256-bar window.  This one asks: WHICH FIX actually recovers the truth?

Variants compared, all at the same noise level:
    A  M5 as-is            scales (1,2,4,8,16)      <- what SimpleEA does now
    B  M5, longer window   1536 bars                <- "give M5 128h of history"
    C  M5, skip the bounce scales (4,8,16,32,64)    <- don't read the noisy lags
    D  M15 = borrow from 3-bar aggregation
    E  M30 = borrow from 6-bar aggregation

Run:  python3 research/hurst_noise_fixes.py
"""

import numpy as np

from hurst_noise_bias import (HURST_WINDOW, HURST_TREND, HURST_REVERT,
                              fgn, add_bounce, mql_hurst_rolling)

M5_PER_M30 = 6


def est(close, window=HURST_WINDOW, scales=(1, 2, 4, 8, 16), step=20):
    """Rolling Hurst with a configurable window and scale set."""
    import numpy as _np
    lr = _np.diff(_np.log(close))
    n = len(close)
    out = _np.full(n, _np.nan)
    ls = _np.log(_np.array(scales, dtype=float))
    for i in range(window, n, step):
        x = lr[i - window:i]
        st = []
        for s in scales:
            k = window // s
            if k < 4:
                st.append(_np.nan)
                continue
            st.append(x[:k * s].reshape(k, s).sum(axis=1).std(ddof=1))
        st = _np.array(st)
        ok = _np.isfinite(st) & (st > 0)
        if ok.sum() >= 3:
            out[i] = _np.polyfit(ls[ok], _np.log(st[ok]), 1)[0]
    return out


def report(h, true_h, tag):
    h = h[np.isfinite(h)]
    if h.size == 0:
        print(f"  {tag:<38}  no data")
        return
    wrong = ((h > HURST_TREND) if true_h <= 0.5 else (h < HURST_REVERT)).mean()
    print(f"  {tag:<38} {h.mean():>6.3f} {h.mean()-true_h:>+7.3f} "
          f"{h.std():>6.3f} {(h>HURST_TREND).mean()*100:>7.1f}% "
          f"{(h<HURST_REVERT).mean()*100:>7.1f}% {wrong*100:>7.1f}%")


def main():
    n = 300_000
    rng = np.random.default_rng(4242)

    print("Which fix recovers the true regime?  'wrong' = labelled the "
          "opposite character\n")
    for H in (0.65, 0.50):
        want = "Steady" if H > 0.55 else "Mixed"
        inc = fgn(H, n, rng) * 1e-4
        lp = np.cumsum(inc)
        for nsr in (1.0, 1.5):
            lpn = add_bounce(lp, nsr, rng)
            p5 = np.exp(lpn)
            p15 = np.exp(lpn[::3])
            p30 = np.exp(lpn[::M5_PER_M30])
            print(f"TRUE H = {H:.2f} (should read \"{want}\")   "
                  f"bounce x{nsr:.2f}")
            print(f"  {'variant':<38} {'est':>6} {'bias':>7} {'sd':>6} "
                  f"{'Steady':>8} {'Choppy':>8} {'wrong':>7}")
            report(est(p5), H, "A  M5 now (256 bars)")
            report(est(p5, window=1536, step=60), H,
                   "B  M5 longer window (1536 bars)")
            report(est(p5, scales=(4, 8, 16, 32, 64)), H,
                   "C  M5 skip short scales (4..64)")
            report(est(p15), H, "D  M15 (borrow, 3-bar agg)")
            report(est(p30), H, "E  M30 (borrow, 6-bar agg)")
            print()

    return 0


if __name__ == "__main__":
    main()
