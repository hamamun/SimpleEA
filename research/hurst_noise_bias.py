#!/usr/bin/env python3
"""
How much can SimpleEA's Hurst regime label be trusted on M5?

SimpleEA uses ONE window - HURST_WINDOW = 256 bars - on all three
timeframes.  That is 21 hours of history on M5 but 128 hours on M30.
On top of that, every quote bounces between bid and ask, which makes
short-horizon returns look mean-reverting and drags the estimate down.

This script separates the two questions using SYNTHETIC data, where the
true Hurst is known:

  Q1  With clean data, does the estimator recover the truth?
      (fBm is self-similar, so M5 and M30 must agree here.  Any gap is
       pure estimator bias/variance, not a time-span effect.)

  Q2  How far does bid/ask bounce drag the estimate, at M5 vs M30?
      Bounce does NOT average away when bars are summed: the added
      noise increments telescope, so six of them sum to the same
      variance as one.  The true signal, meanwhile, grows like 6^H.
      So the noise-to-signal ratio improves by ~6^H going M5 -> M30.

Run:
    python3 research/hurst_noise_bias.py            # default sweep
    python3 research/hurst_noise_bias.py --quick    # fewer bars, faster

It needs numpy only.  No market data required.
"""

import argparse
import sys

import numpy as np

# --- SimpleEA constants (SimpleAdvisor.mq5 THE ENGINE PROFILE) --------
HURST_WINDOW = 256
HURST_TREND = 0.55      # H above -> "Steady"
HURST_REVERT = 0.45     # H below -> "Choppy"
SCALES = (1, 2, 4, 8, 16)
M5_PER_M30 = 6


# ---------------------------------------------------------------- fGn --
def fgn(H, n, rng):
    """Fractional Gaussian noise, unit variance, via Davies-Harte
    (circulant embedding).  Returns n increments ~ fGn with exponent H."""
    m = 1
    while m < 2 * n:
        m *= 2
    k = np.arange(m, dtype=float)
    g = 0.5 * (np.abs(k + 1) ** (2 * H)
               - 2.0 * np.abs(k) ** (2 * H)
               + np.abs(k - 1) ** (2 * H))
    # first row of the circulant: g[0..m/2] then g[m/2-1..1] reversed
    c = np.concatenate([g[:m // 2 + 1], g[1:m // 2][::-1]])
    lam = np.maximum(np.fft.fft(c).real, 0.0)
    w = rng.standard_normal(m) + 1j * rng.standard_normal(m)
    w[0] = w[0].real
    w[m // 2] = w[m // 2].real
    z = np.fft.ifft(np.sqrt(lam) * w) * np.sqrt(m)
    return z.real[:n]


# ------------------------------------------ SimpleEA's estimator ------
def mql_hurst_scalar(close, i, window=HURST_WINDOW):
    """Literal line-by-line transcription of HurstExponent() in
    SimpleAdvisor.mq5.  Kept as the reference the fast version is
    checked against."""
    if i + 1 < window or window < 32:
        return 0.5
    start = i - window + 1
    lx, ly = [], []
    for s in SCALES:
        k = window // s
        if k < 4:
            continue
        sums = []
        for b in range(k):
            tot = 0.0
            for j in range(s):
                idx = start + b * s + j
                p1, p0 = close[idx], close[idx - 1]
                if p0 > 0.0 and p1 > 0.0:
                    tot += np.log(p1 / p0)
            sums.append(tot)
        sums = np.array(sums)
        mean = sums.mean()
        var = ((sums - mean) ** 2).sum() / (k - 1)
        sd = np.sqrt(var)
        if sd <= 0.0:
            continue
        lx.append(np.log(float(s)))
        ly.append(np.log(sd))
    if len(lx) < 3:
        return 0.5
    lx = np.array(lx)
    ly = np.array(ly)
    mx, my = lx.mean(), ly.mean()
    sxy = ((lx - mx) * (ly - my)).sum()
    sxx = ((lx - mx) ** 2).sum()
    if sxx <= 0.0:
        return 0.5
    return sxy / sxx


def mql_hurst_rolling(close, window=HURST_WINDOW, step=1):
    """Vectorised equivalent of the above, evaluated every `step` bars."""
    lr = np.diff(np.log(close))          # lr[j] = log(close[j+1]/close[j])
    n = len(close)
    out = np.full(n, np.nan)
    ls = np.log(np.array(SCALES, dtype=float))
    for i in range(window, n, step):
        # MQL reads idx = start .. start+window-1, i.e. lr[i-window .. i-1]
        x = lr[i - window:i]
        st = []
        for s in SCALES:
            k = window // s
            if k < 4:
                st.append(np.nan)
                continue
            agg = x[:k * s].reshape(k, s).sum(axis=1)
            st.append(agg.std(ddof=1))
        st = np.array(st)
        ok = np.isfinite(st) & (st > 0)
        if ok.sum() >= 3:
            out[i] = np.polyfit(ls[ok], np.log(st[ok]), 1)[0]
    return out


# ------------------------------------------------------ bid/ask ------
def add_bounce(logp, nsr, rng, persist=0.5):
    """Roll-style bid/ask bounce.

    observed mid = true mid + (spread/2) * q_t,  q_t = +/-1 trade direction.
    The RETURN error is (spread/2)*(q_t - q_{t-1}), std = spread/2*sqrt(2)
    for i.i.d. flow.  `nsr` = that std as a multiple of the true 5-min
    return std.  `persist` = P(q repeats); 0.5 = i.i.d. flow.
    """
    if nsr <= 0.0:
        return logp
    sig = float(np.std(np.diff(logp)))
    half = nsr * sig / np.sqrt(2.0)      # = spread/2
    n = len(logp)
    q = np.empty(n)
    cur = 1.0
    u = rng.random(n)
    for t in range(n):
        if u[t] > persist:
            cur = -cur
        q[t] = cur
    return logp + half * q


# ------------------------------------------------------------ run ----
def summarise(close, step, tag, true_h):
    h = mql_hurst_rolling(close, HURST_WINDOW, step)
    h = h[np.isfinite(h)]
    if h.size == 0:
        return None
    r = np.diff(np.log(close))
    return {
        "tag": tag,
        "true": true_h,
        "n": h.size,
        "mean": float(h.mean()),
        "median": float(np.median(h)),
        "std": float(h.std()),
        "p_steady": float((h > HURST_TREND).mean()),
        "p_choppy": float((h < HURST_REVERT).mean()),
        "ac1": float(np.corrcoef(r[:-1], r[1:])[0, 1]),
    }


def print_row(s):
    print(f"  {s['tag']:<26} {s['true']:>5.2f} {s['mean']:>7.3f} "
          f"{s['mean'] - s['true']:>+8.3f} {s['std']:>6.3f} "
          f"{s['p_steady'] * 100:>7.1f}% {s['p_choppy'] * 100:>7.1f}% "
          f"{s['ac1']:>+7.3f}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--quick", action="store_true")
    args = ap.parse_args()

    n_m5 = 120_000 if args.quick else 300_000
    step = 20
    rng = np.random.default_rng(20261027)

    # ---- self-check: does the fast version match the MQL original? ----
    probe = np.exp(np.cumsum(fgn(0.65, 4000, rng) * 1e-4))
    for i in (1200, 2500, 3700):
        a = mql_hurst_scalar(probe, i)
        b = mql_hurst_rolling(probe, HURST_WINDOW, 1)[i]
        if abs(a - b) > 1e-9:
            print(f"SELF-CHECK FAILED at i={i}: scalar {a} vs rolling {b}")
            return 1
    print("self-check: rolling estimator matches the MQL transcription exactly\n")

    # ---- self-check: does the generator have the right H? -------------
    print("generator check (empirical vs theoretical lag-1 autocorrelation):")
    for H in (0.65, 0.50, 0.35):
        x = fgn(H, 200_000, rng)
        emp = np.corrcoef(x[:-1], x[1:])[0, 1]
        theo = 2.0 ** (2 * H - 1) - 1.0
        print(f"  H={H:.2f}  empirical {emp:+.4f}   theoretical {theo:+.4f}")
    print()

    for H in (0.65, 0.50, 0.35):
        truth = {0.65: "Steady", 0.50: "Mixed", 0.35: "Choppy"}[H]
        inc = fgn(H, n_m5, rng) * 1e-4
        lp = np.cumsum(inc)
        print(f"TRUE H = {H:.2f}   (SimpleEA should say \"{truth}\")")
        print(f"  {'series':<26} {'true':>5} {'est':>7} {'bias':>8} "
              f"{'sd':>6} {'Steady':>8} {'Choppy':>8} {'ac1':>7}")

        # clean
        print_row(summarise(np.exp(lp), step, "M5  clean", H))
        m30_clean = lp[::M5_PER_M30]
        print_row(summarise(np.exp(m30_clean), 4, "M30 clean", H))

        # with bounce, several noise levels
        for nsr in (0.25, 0.5, 1.0, 1.5):
            lpn = add_bounce(lp, nsr, rng)
            print_row(summarise(np.exp(lpn), step,
                                f"M5  bounce x{nsr:.2f}", H))
            print_row(summarise(np.exp(lpn[::M5_PER_M30]), 4,
                                f"M30 bounce x{nsr:.2f}", H))
        print()

    return 0


if __name__ == "__main__":
    sys.exit(main())
