"""Trade-plan arithmetic check.

The MQL is transcribed here function for function (PointValuePerLot,
NormalizeLots, the risk / ladder / min-lot branches, point conversion and the
USD figures) and run against broker contracts whose correct answers can be
worked out by hand.  This is the part of the trade plan that is pure
arithmetic, so it is the part that can be proven without a terminal.

It cannot prove anything about the market - only that the numbers the panel
prints for lot / points / money are the right ones for the contract it is
looking at.  Market behaviour is research/HORIZON.md.

Run:  python verify_plan_math.py
"""

import math

# ----------------------------------------------------------------------
# Broker contracts.  tick_value is what MetaTrader reports for one lot:
# SYMBOL_TRADE_TICK_VALUE = account currency gained per 1 tick per 1 lot,
# and SYMBOL_TRADE_TICK_SIZE is that tick in price units.
# The USD figures below are also derived by hand in the comments - if the
# code ever disagrees with the hand derivation, this script fails.
# ----------------------------------------------------------------------
SYMBOLS = {
    # 100 oz per lot.  Price 4285.70, 2-digit broker -> point 0.01.
    # 1 point = $0.01 move = 100 oz * $0.01 = $1.00 per lot.
    "XAUUSD-2d": dict(point=0.01, tick_size=0.01, tick_value=1.00,
                      min_lot=0.01, step=0.01, max_lot=100.0, digits=2, stops_level=0),
    # 3-digit gold broker: point 0.001, 1 point = $0.10 per lot.
    "XAUUSD-3d": dict(point=0.001, tick_size=0.001, tick_value=0.10,
                      min_lot=0.01, step=0.01, max_lot=100.0, digits=3, stops_level=0),
    # 100,000 EUR per lot.  1 point (0.00001) = $1.00 per lot.
    "EURUSD-5d": dict(point=0.00001, tick_size=0.00001, tick_value=1.00,
                      min_lot=0.01, step=0.01, max_lot=100.0, digits=5, stops_level=0),
    # USDJPY quoted in JPY: $1.00 per point is wrong - at 147.00,
    # 1 point (0.001) = 100,000 * 0.001 / 147.00 = $0.6803 per lot.
    "USDJPY-3d": dict(point=0.001, tick_size=0.001, tick_value=0.6802721088435374,
                      min_lot=0.01, step=0.01, max_lot=100.0, digits=3, stops_level=0),
    # An index CFD, 1 unit per lot, $1 per point per lot, min lot 0.1.
    "US30":      dict(point=0.1, tick_size=0.1, tick_value=0.10,
                      min_lot=0.1, step=0.1, max_lot=50.0, digits=1, stops_level=20),
}


def point_value_per_lot(c):
    """PointValuePerLot() in SimpleAdvisor.mq5."""
    if c["point"] <= 0 or c["tick_size"] <= 0 or c["tick_value"] <= 0:
        return 0.0
    return c["tick_value"] * (c["point"] / c["tick_size"])


def normalize_lots(lots, c):
    """NormalizeLots() in SimpleAdvisor.mq5."""
    step = c["step"] or 0.01
    mn = c["min_lot"] or step
    mx = c["max_lot"] or 100.0
    n = math.floor(lots / step + 1e-8) * step
    if n < mn:
        n = mn
    if n > mx:
        n = mx
    digits = 0
    probe = step
    while probe < 1.0 and digits < 8:
        probe *= 10.0
        digits += 1
    return round(n, digits)


def plan(c, direction, atr, balance, use_risk=True, use_min_lot=False,
         risk2=0.5, risk3=1.0, bal_per_001=1000.0, score3_factor=1.5,
         sl_atr=1.2, tp_atr=2.4, score=3, entry=None, box=None,
         range_sl_atr=1.0):
    """The plan numbers, exactly as UpdatePlanRow() computes them.

    sl_atr / tp_atr stand for the EA's baked-in per-timeframe profile
    (SL_ATR_* / TP_ATR_*): the caller passes the pair belonging to
    the row being built - M5 1.0/0.9, M15 1.2/1.8, M30 1.5/3.0.  The
    1.2/2.4 defaults below are only the classic single-pair arithmetic
    example the hand-derived checks in main() were written against.

    box=(top, bot) switches to the Part 2 RANGE branch of UpdatePlanRow():
    sl_atr / tp_atr are then ignored, exactly as the MQL ignores them -
    the stop is range_sl_atr (InpRangeSLATR) * ATR and the target is
    half the box, no matter what the timeframe's trend profile says.
    """
    pv = point_value_per_lot(c)
    point = c["point"]

    # distances snapped onto the broker's point grid first (as in UpdatePlan)
    if box is not None:
        sl_pts = max(1, int(round(range_sl_atr * atr / point)))
        tp_pts = max(1, int(round(0.5 * (box[0] - box[1]) / point)))
    else:
        sl_pts = max(1, int(round(sl_atr * atr / point)))
        tp_pts = max(1, int(round(tp_atr * atr / point)))
    min_stop = c["stops_level"] * point
    if min_stop > 0 and sl_pts * point < min_stop:
        sl_pts = int(math.ceil(min_stop / point))
    sl_dist = sl_pts * point
    tp_dist = tp_pts * point

    want_risk = 0.0
    if use_min_lot:
        lots = c["min_lot"]
    elif use_risk:
        pct = risk3 if abs(score) >= 3 else risk2
        want_risk = balance * pct / 100.0
        lots = want_risk / (sl_pts * pv) if pv > 0 else c["min_lot"]
    else:
        lots = (balance / bal_per_001) * 0.01
        if abs(score) >= 3:
            lots *= score3_factor

    lot = normalize_lots(lots, c)
    risk_usd = lot * sl_pts * pv
    reward_usd = lot * tp_pts * pv

    if entry is not None:
        sl_price = entry - direction * sl_dist
        tp_price = entry + direction * tp_dist
    else:
        sl_price = tp_price = None

    return dict(lot=lot, sl_pts=sl_pts, tp_pts=tp_pts, pv=pv,
                risk_usd=risk_usd, reward_usd=reward_usd,
                rr=reward_usd / risk_usd if risk_usd else 0.0,
                want_risk=want_risk, sl_price=sl_price, tp_price=tp_price,
                sl_dist=sl_dist, tp_dist=tp_dist)


def check(cond, msg):
    if not cond:
        raise AssertionError(msg)


def approx(a, b, tol=1e-6):
    return abs(a - b) <= tol


def main():
    print("Point value per lot (the number every other figure depends on)")

    # --- hand-derived point values -------------------------------------
    check(approx(point_value_per_lot(SYMBOLS["XAUUSD-2d"]), 1.00),
          "XAUUSD 2-digit: 1 point must be $1.00 per lot")
    check(approx(point_value_per_lot(SYMBOLS["XAUUSD-3d"]), 0.10),
          "XAUUSD 3-digit: 1 point must be $0.10 per lot")
    check(approx(point_value_per_lot(SYMBOLS["EURUSD-5d"]), 1.00),
          "EURUSD 5-digit: 1 point must be $1.00 per lot")
    check(approx(point_value_per_lot(SYMBOLS["USDJPY-3d"]), 0.6802721, 1e-6),
          "USDJPY 3-digit: 1 point must be 100000*0.001/147.00 = $0.6802721")
    for name, c in SYMBOLS.items():
        print("  ok  %-11s 1 point = %+.5f per lot" % (name, point_value_per_lot(c)))

    # --- lot grid ------------------------------------------------------
    print("\nLot grid (broker min / step / max)")
    check(approx(normalize_lots(0.235, SYMBOLS["XAUUSD-2d"]), 0.23),
          "0.235 lots on a 0.01-step symbol must round DOWN to 0.23")
    check(approx(normalize_lots(0.0001, SYMBOLS["XAUUSD-2d"]), 0.01),
          "a tiny size must be lifted to the 0.01 minimum")
    check(approx(normalize_lots(5.0, SYMBOLS["US30"]), 5.0),
          "whole steps must survive untouched")
    check(approx(normalize_lots(0.04, SYMBOLS["US30"]), 0.1),
          "below the 0.1 minimum must be lifted to 0.1")
    check(approx(normalize_lots(999.0, SYMBOLS["US30"]), 50.0),
          "above the maximum must be capped")
    print("  ok  rounds down to the step, clamps to min and max")

    # --- risk mode: the 1% gold example, by hand ------------------------
    # $800 balance, 1% at score 3 = $8.00 risk.
    # ATR 0.28 (28 cents) -> stop 1.2 ATR = 0.336 = 34 points (rounded).
    # $8.00 / (34 pts x $1.00) = 0.235 lots -> 0.23 after the lot grid.
    print("\nRisk mode - XAUUSD, $800 balance, 1% at score 3")
    r = plan(SYMBOLS["XAUUSD-2d"], +1, atr=0.28, balance=800.0, score=3, risk3=1.0)
    check(r["sl_pts"] == 34, "stop should be 34 points, got %d" % r["sl_pts"])
    check(r["tp_pts"] == 67, "target should be exactly 67 points, got %d" % r["tp_pts"])
    check(approx(r["lot"], 0.23), "lot should be 0.23, got %s" % r["lot"])
    check(approx(r["risk_usd"], 7.82, 0.01),
          "risk at 0.23 lots is 0.23*34*$1 = $7.82, got %.2f" % r["risk_usd"])
    check(r["risk_usd"] <= 8.0, "risk must never exceed the 1% target when rounding down")
    check(approx(r["rr"], 67.0 / 34.0, 1e-9),
          "R:R is the ratio of the actual levels: 67/34 = 1.97, got %.2f" % r["rr"])
    print("  ok  lot %.2f   stop %d pts ($%.2f)   target %d pts ($%.2f)   R:R 1:%.2f"
          % (r["lot"], r["sl_pts"], r["risk_usd"], r["tp_pts"], r["reward_usd"], r["rr"]))

    # --- same trade, score 2 -> half the risk ---------------------------
    r2 = plan(SYMBOLS["XAUUSD-2d"], +1, atr=0.28, balance=800.0, score=2,
              risk2=0.5, risk3=1.0)
    check(r2["risk_usd"] < r["risk_usd"],
          "score 2 at 0.5%% must risk less than score 3 at 1%%")
    check(approx(r2["rr"], r["rr"], 0.3),
          "R:R is set by the ATR multiples, not by the score")
    print("  ok  score 2 risks $%.2f at the same stop (score 3: $%.2f)"
          % (r2["risk_usd"], r["risk_usd"]))

    # --- small account: min lot wins, and the panel must say so ---------
    # $200 balance at 1% = $2.00 risk, but 0.01 lots x 34 pts = $0.34?? No:
    # 0.01 lots on 2-digit gold is $1.00/point, so 34 pts = $0.34 risk.
    # A tiny stop on a cheap symbol can therefore risk LESS than asked -
    # that is fine (never more).  To test the "risk above target" flag we
    # use a big stop instead: ATR 2.8 -> 336 points -> 0.01 lots = $3.36
    # risk against a $2.00 target.
    r3 = plan(SYMBOLS["XAUUSD-2d"], +1, atr=2.8, balance=200.0, score=3)
    check(approx(r3["lot"], 0.01), "small account must fall back to 0.01")
    check(r3["risk_usd"] > r3["want_risk"],
          "with a wide stop the minimum lot risks MORE than 1% - the panel flags this")
    print("  ok  $200 account, wide stop: min lot 0.01 risks $%.2f vs $%.2f target (flagged)"
          % (r3["risk_usd"], r3["want_risk"]))

    # --- min-lot mode ---------------------------------------------------
    r4 = plan(SYMBOLS["US30"], +1, atr=50.0, balance=50000.0, use_min_lot=True, score=3)
    check(approx(r4["lot"], 0.1), "min-lot mode must return the symbol minimum")
    print("  ok  min-lot mode on US30 -> %.2f lots regardless of balance" % r4["lot"])

    # --- risk-off ladder ------------------------------------------------
    # $1,000 balance, $1,000 per 0.01 lot -> 0.01 lots; score 3 -> x1.5 = 0.015
    # -> snapped DOWN to the 0.01 grid = 0.01.
    r5 = plan(SYMBOLS["EURUSD-5d"], -1, atr=0.0004, balance=1000.0, use_risk=False, score=3)
    check(approx(r5["lot"], 0.01), "ladder at $1,000 must give 0.01 lots, got %s" % r5["lot"])
    # $5,000 -> 0.05 lots; score 3 -> x1.5 = 0.075 -> 0.07
    r6 = plan(SYMBOLS["EURUSD-5d"], -1, atr=0.0004, balance=5000.0, use_risk=False, score=3)
    check(approx(r6["lot"], 0.07), "ladder at $5,000 with score 3 must give 0.07, got %s" % r6["lot"])
    print("  ok  ladder: $1,000 -> 0.01 lots, $5,000 score 3 -> 0.07 lots")

    # --- price levels ---------------------------------------------------
    # SELL gold at 4285.70, stop 34 pts, target 67 pts.
    r7 = plan(SYMBOLS["XAUUSD-2d"], -1, atr=0.28, balance=800.0, score=3, entry=4285.70)
    check(approx(r7["sl_price"], 4285.70 + 0.34, 1e-9),
          "sell stop must sit exactly 34 points ABOVE the entry: got %.2f" % r7["sl_price"])
    check(approx(r7["tp_price"], 4285.70 - 0.67, 1e-9),
          "sell target must sit exactly 67 points BELOW the entry: got %.2f" % r7["tp_price"])
    print("  ok  SELL 4285.70 -> stop %.2f / target %.2f (above / below, as they must be)"
          % (r7["sl_price"], r7["tp_price"]))

    r8 = plan(SYMBOLS["XAUUSD-2d"], +1, atr=0.28, balance=800.0, score=3, entry=4285.90)
    check(r8["sl_price"] < 4285.90 < r8["tp_price"],
          "buy stop must sit below the entry and target above it")
    print("  ok  BUY  4285.90 -> stop %.2f / target %.2f (mirrored correctly)"
          % (r8["sl_price"], r8["tp_price"]))

    # --- broker minimum stop distance -----------------------------------
    # US30 has stops_level 20 points = 2.0 price units; a 1.2 ATR stop of
    # 0.6 units must be widened to 2.0.
    r9 = plan(SYMBOLS["US30"], +1, atr=0.5, balance=10000.0, score=3, entry=41000.0)
    check(approx(r9["sl_dist"], 2.0, 1e-9),
          "stop must be widened to the broker minimum of 2.0, got %.3f" % r9["sl_dist"])
    check(approx(r9["sl_price"], 41000.0 - 2.0, 1e-9),
          "the widened stop must be used for the price too")
    check(r9["sl_pts"] == 20, "widened stop should report 20 points, got %d" % r9["sl_pts"])
    print("  ok  broker min stop distance respected (US30: 0.6 widened to 2.0 units)")

    # --- USDJPY: the cross-currency case --------------------------------
    # 0.10 lots, 30-point stop: 0.10 * 30 * $0.6802721 = $2.0408
    r10 = plan(SYMBOLS["USDJPY-3d"], -1, atr=0.10, balance=1000.0, use_risk=False, score=2)
    check(approx(r10["lot"], 0.01), "USDJPY ladder at $1,000 -> 0.01 lots")
    check(approx(r10["risk_usd"], 0.01 * r10["sl_pts"] * point_value_per_lot(SYMBOLS["USDJPY-3d"]), 1e-12),
          "USDJPY money must use the JPY-converted point value, not $1/point")
    print("  ok  USDJPY money uses the converted point value ($%.4f/lot/point), risk $%.2f"
          % (r10["pv"], r10["risk_usd"]))

    # --- per-timeframe profiles: the three styles must NOT share one aim -
    # The EA bakes in SL_ATR_* / TP_ATR_* per timeframe (M5 1.0/0.9,
    # M15 1.2/1.8, M30 1.5/3.0 ATR).  On the XAUUSD ATRs 0.28 / 0.85 / 1.70
    # that is stop/target 28/25, 102/153, 255/510 points - hand-checkable
    # and fanning out with the timeframe.
    print("\nPer-timeframe profiles - scalp near, intraday far")
    profiles = (("M5",  0.28, 1.0, 0.9, 28, 25),
                ("M15", 0.85, 1.2, 1.8, 102, 153),
                ("M30", 1.70, 1.5, 3.0, 255, 510))
    prev_tp = 0
    for name, atr, sl_a, tp_a, sl_want, tp_want in profiles:
        r = plan(SYMBOLS["XAUUSD-2d"], +1, atr=atr, balance=800.0, score=3,
                 sl_atr=sl_a, tp_atr=tp_a)
        check(r["sl_pts"] == sl_want,
              "%s stop must be %d pts, got %d" % (name, sl_want, r["sl_pts"]))
        check(r["tp_pts"] == tp_want,
              "%s target must be %d pts, got %d" % (name, tp_want, r["tp_pts"]))
        check(r["tp_pts"] > prev_tp,
              "%s target must be farther than the previous timeframe's" % name)
        prev_tp = r["tp_pts"]
        print("  ok  %-4s stop %3d pts  target %3d pts  R:R 1:%.2f"
              % (name, r["sl_pts"], r["tp_pts"], r["rr"]))
    r_rr = {n: plan(SYMBOLS["XAUUSD-2d"], +1, atr=a, balance=800.0, score=3,
                    sl_atr=sa, tp_atr=ta)["rr"]
            for n, a, sa, ta, _, _ in profiles}
    check(abs(r_rr["M5"] - 0.89) < 0.02, "M5 R:R must be about 1:0.89, got %.2f" % r_rr["M5"])
    check(abs(r_rr["M15"] - 1.50) < 0.02, "M15 R:R must be 1:1.50, got %.2f" % r_rr["M15"])
    check(abs(r_rr["M30"] - 2.00) < 0.02, "M30 R:R must be 1:2.00, got %.2f" % r_rr["M30"])
    print("  ok  R:R rises with the timeframe: 1:0.89 / 1:1.50 / 1:2.00")

    # --- range fade (Part 2): the box decides every number ---------------
    # Box top/bot are actual highs and lows; the plan takes entry at the
    # opposite band, stop = band + InpRangeSLATR (1.0) ATR, target =
    # half the box (band -> midpoint).  Hand-derived on XAUUSD 2-digit.
    print("\nRange fade - box geometry, not an opinion")
    top, bot = 4286.60, 4284.60                 # 2.00 price units tall
    # SELL from the top band, ATR 0.85 (Choppy M15):
    rb = plan(SYMBOLS["XAUUSD-2d"], -1, atr=0.85, balance=800.0, score=-1,
              box=(top, bot), entry=top)
    check(rb["sl_pts"] == 85, "range stop must be 1.0 ATR = 85 pts, got %d" % rb["sl_pts"])
    check(rb["tp_pts"] == 100, "range target must be half the box = 100 pts, got %d" % rb["tp_pts"])
    check(approx(rb["tp_price"], 0.5 * (top + bot), 1e-9),
          "the sell target must be EXACTLY the box midpoint, got %.4f" % rb["tp_price"])
    check(approx(rb["sl_price"], top + 0.85, 1e-9),
          "the sell stop must be band + 1 ATR, got %.4f" % rb["sl_price"])
    check(approx(rb["want_risk"], 4.0, 1e-9),
          "score 1 is a score-2-risk row: 0.5%% of $800 = $4, got %.2f" % rb["want_risk"])
    print("  ok  SELL band %.2f -> stop %.2f (band+ATR)  target %.2f (midpoint)  "
          "stop %d pts / target %d pts"
          % (top, rb["sl_price"], rb["tp_price"], rb["sl_pts"], rb["tp_pts"]))
    # BUY from the bottom band of a wider box, ATR 1.70 (Choppy M30):
    top, bot = 4290.00, 4282.00                 # 8.00 units tall
    rb2 = plan(SYMBOLS["XAUUSD-2d"], +1, atr=1.70, balance=800.0, score=1,
               box=(top, bot), entry=bot)
    check(rb2["sl_pts"] == 170, "range stop must be 170 pts, got %d" % rb2["sl_pts"])
    check(rb2["tp_pts"] == 400, "range target must be 400 pts (half of 8.00), got %d" % rb2["tp_pts"])
    check(approx(rb2["tp_price"], 0.5 * (top + bot), 1e-9),
          "the buy target must also land on the midpoint, got %.4f" % rb2["tp_price"])
    check(approx(rb2["sl_price"], bot - 1.70, 1e-9),
          "the buy stop must be band - 1 ATR, got %.4f" % rb2["sl_price"])
    check(rb2["sl_price"] < bot < rb2["tp_price"],
          "buy range: stop below the band, entry at the band, midpoint above")
    #  The trend profiles must have NO say in a range row:
    rb3 = plan(SYMBOLS["XAUUSD-2d"], +1, atr=1.70, balance=800.0, score=1,
               sl_atr=1.5, tp_atr=3.0,          # M30's trend profile...
               box=(top, bot), entry=bot)       # ...must be ignored
    check(rb3["sl_pts"] == rb2["sl_pts"] and rb3["tp_pts"] == rb2["tp_pts"],
          "the range branch must ignore SL_ATR/TP_ATR entirely")
    print("  ok  BUY band %.2f -> stop %.2f  target %.2f (midpoint); trend profile ignored"
          % (bot, rb2["sl_price"], rb2["tp_price"]))

    print("\nall trade-plan arithmetic checks passed")


if __name__ == "__main__":
    main()
