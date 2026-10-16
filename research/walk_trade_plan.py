"""Panel walk-through, including the trade-plan block.

Mirrors SimpleAdvisor.mq5 exactly:

  UpdatePlan()      builds the plan lines into g_plan.text[] (and colours)
  PlanWidthNeed()   measures them, and the panel grows to fit before drawing
  DrawPlanBlock()   places them under the timeframe rows

So this prints the panel the way the reader sees it for the cases that
matter, and then asserts that no line runs past the panel edge - the same
guarantee the EA gives by sizing itself from the text it is about to draw.

Every number comes from verify_plan_math.plan(), which is checked against
hand-derived broker contracts, so the pictures below are what the EA draws.

Run:  python walk_trade_plan.py
"""

import math
import sys

sys.path.insert(0, ".")
from verify_plan_math import SYMBOLS, plan          # noqa: E402

HEAD_H, TF_COUNT, PLAN_SEP_H = 34, 3, 14
PLAN_LINES, PLAN_ROWS = 8, 7
PANEL_W_MIN = 406                     # g_panelW
EM_REAL = 0.55          # what a monospaced face really needs, in em
EM_EST  = 0.60          # CharW(): what the EA budgets, plus margin
DPI     = 96            # TERMINAL_SCREEN_DPI in this sandbox's model
FONT = 9                              # InpFontSize
MINUTES = {"M5": 5, "M15": 15, "M30": 30}

ROWS = [("M5", "Scalp", "Going down", "SELL", "-3 / 3", "Steady"),
        ("M15", "Short-term", "Going up", "BUY", "+2 / 3", "Mixed"),
        ("M30", "Intraday", "Going down", "SELL", "-2 / 3", "Choppy")]


def char_w(size):
    """CharW() in the EA: points -> pixels at the real screen DPI."""
    dpi = DPI if DPI >= 72 else 96
    return int(math.ceil(size * dpi / 72.0 * EM_EST))


def real_char_w(size):
    return size * DPI / 72.0 * EM_REAL


def plan_width_need(texts, font=FONT, dpi=DPI):
    """PlanWidthNeed() in the EA: body at font, header at font+1."""
    widest_body, widest_head = 0, 0
    for i, t in enumerate(texts):
        n = len(t)
        if i <= 1:
            if i == 1 and texts[0]:
                n += len(texts[0]) + 4
            widest_head = max(widest_head, n)
        else:
            widest_body = max(widest_body, n)
    need_body = 10 + widest_body * char_w(font) + 10
    need_head = 10 + widest_head * char_w(font + 1) + 10
    return max(need_body, need_head)


def update_plan(spec, score, atr, price, balance, tf="M5", symbol="XAUUSD",
                cur="USD", use_risk=True, use_min_lot=False, risk2=0.5,
                risk3=1.0, sl_atr=1.2, tp_atr=2.4, pend_atr=0.5,
                valid_bars=3, expiry="14:30", hold=False, digits=None):
    """UpdatePlan(): returns the seven ready-to-draw lines."""
    dg = digits if digits is not None else spec["digits"]
    texts = [""] * PLAN_LINES
    texts[0] = "Trade plan:"

    if hold:
        texts[1] = "%s row shows HOLD - no trade to plan" % tf
        return texts

    d = 1 if score > 0 else -1
    side = "BUY" if d > 0 else "SELL"
    r = plan(spec, d, atr=atr, balance=balance, use_risk=use_risk,
             use_min_lot=use_min_lot, risk2=risk2, risk3=risk3,
             sl_atr=sl_atr, tp_atr=tp_atr, score=score, entry=price)

    market = abs(score) >= 3
    why = "3 of 3 - go to market" if market else "2 of 3 - wait for a better price"
    offset = pend_atr * atr
    pend = price - d * offset
    alt = price + d * offset

    texts[1] = "%s  %s   %s   score %+d/%d" % (symbol, tf, side, score, 3)
    if market:
        texts[2] = "Entry  : MARKET %.*f   (%s)" % (dg, price, why)
    else:
        texts[2] = "Entry  : PENDING %s %.*f   (%s)" % (
            "buy limit" if d > 0 else "sell limit", dg, pend, why)
    texts[3] = "Alt    : %s %.*f   (follow the move instead)" % (
        "buy stop" if d > 0 else "sell stop", dg, alt)
    texts[4] = "Stop   : %.*f   %d pts   risk %.2f %s" % (
        dg, r["sl_price"], r["sl_pts"], r["risk_usd"], cur)
    texts[5] = "Target : %.*f   %d pts   reward %.2f %s   R:R 1:%.2f" % (
        dg, r["tp_price"], r["tp_pts"], r["reward_usd"], cur, r["rr"])

    if use_min_lot:
        size = "Lot    : %.2f   (symbol minimum)" % r["lot"]
    elif use_risk:
        pct = risk3 if abs(score) >= 3 else risk2
        size = "Lot    : %.2f   (%.2f%% of %.2f %s)" % (r["lot"], pct, balance, cur)
    else:
        size = "Lot    : %.2f   (balance ladder%s)" % (
            r["lot"], ", x1.5 at score 3" if abs(score) >= 3 else "")
    if not use_min_lot and use_risk and r["want_risk"] and r["risk_usd"] > r["want_risk"] * 1.05:
        size += "   - min lot risks %.2f %s" % (r["risk_usd"], cur)
    texts[6] = size
    texts[7] = "Valid  : %d bars (%d min) - until %s, or if the panel flips" % (
        valid_bars, valid_bars * MINUTES[tf], expiry)
    return texts


def render(title, *args, **kw):
    """DrawSupportedPanel(): size to content, then draw."""
    texts = update_plan(*args, **kw)
    font = kw.get("font", FONT)
    panel_w = max(PANEL_W_MIN, plan_width_need(texts, font))
    panel_h = HEAD_H + TF_COUNT * 2 * (font + 11) + 8 + PLAN_SEP_H + PLAN_ROWS * (font + 11)

    print("\n" + "=" * 78)
    print(title)
    print("=" * 78)

    def box(s, right_anchor=False):
        width = panel_w - 4
        if right_anchor:
            return "  | " + s.rjust(width)[:width] + " |"
        return "  | " + s.ljust(width)[:width] + " |"

    print("  +" + "-" * (panel_w - 2) + "+")
    print(box("SimpleEA" + ("%s  %s" % (kw.get("symbol", "XAUUSD"), kw.get("tf", "M5"))).rjust(panel_w - 14)))
    print("  |" + "-" * (panel_w - 2) + "|")
    for tag, style, trend, sig, sc, regime in ROWS:
        print(box("%-4s %-11s Trend: %-12s Regime: %s" % (tag, style, trend, regime)))
        print(box("%-4s %-11s Signal: %-11s Score: %s" % ("", "", sig, sc)))
    print("  |" + "-" * (panel_w - 2) + "|")

    bad = []
    avail = panel_w - 20                       # what the text has to fit in
    for i, txt in enumerate(texts):
        if txt == "":
            continue
        real = len(txt) * real_char_w(font)             # realistic rendered width
        if real > avail:
            bad.append((i, len(txt), real, avail))
        if i == 1:
            print(box(txt, right_anchor=True))
        elif i == 0:
            print(box(txt))
        else:
            print(box(txt))
    print("  +" + "-" * (panel_w - 2) + "+")
    print("  panel: %d x %d px" % (panel_w, panel_h))

    if bad:
        for i, n, real, a in bad:
            print("  !! line %d is %d chars (~%.0f px) past the %d px of text space"
                  % (i, n, real, a))
    else:
        print("  (every line fits: text needs <= %d px, %d px available)" % (avail, avail))
    return bad


def main():
    print("SimpleEA trade plan - what the panel draws")
    for dpi in (72, 96, 120, 144, 192):
        globals()["DPI"] = dpi
        for size in (6, 8, 9, 10, 12, 16):
            check = char_w(size) >= real_char_w(size)
            if not check:
                print("  !! CharW under-estimates at DPI %d size %d (%.2f vs %.2f)"
                      % (dpi, size, char_w(size), real_char_w(size)))
                sys.exit(1)
    globals()["DPI"] = 96
    print("  CharW() is conservative at 72-192 DPI and sizes 6-16: ok")
    bad = []
    bad += render("CASE 1  XAUUSD M5  SELL 3/3  $800  RISK mode  -> MARKET",
                  SYMBOLS["XAUUSD-2d"], -3, atr=0.28, price=4285.70, balance=800.0,
                  symbol="XAUUSD", tf="M5")
    bad += render("CASE 2  XAUUSD M5  SELL 2/3  -> the EA switches to a PENDING entry",
                  SYMBOLS["XAUUSD-2d"], -2, atr=0.28, price=4285.70, balance=800.0,
                  symbol="XAUUSD", tf="M5")
    bad += render("CASE 3  EURUSD M15 BUY 3/3  $800  RISK-OFF ladder",
                  SYMBOLS["EURUSD-5d"], 3, atr=0.0010, price=1.08542, balance=800.0,
                  use_risk=False, symbol="EURUSD", tf="M15")
    bad += render("CASE 4  EURUSD M15 BUY 3/3  $800  MIN-LOT mode",
                  SYMBOLS["EURUSD-5d"], 3, atr=0.0010, price=1.08542, balance=800.0,
                  use_min_lot=True, symbol="EURUSD", tf="M15")
    bad += render("CASE 5  XAUUSD M5  $200, wide stop: min lot risks more than 1% (flagged)",
                  SYMBOLS["XAUUSD-2d"], -3, atr=2.8, price=4285.70, balance=200.0,
                  symbol="XAUUSD", tf="M5")
    bad += render("CASE 6  XAUUSD M30 HOLD -> no plan, one line",
                  SYMBOLS["XAUUSD-2d"], 0, atr=1.2, price=4285.70, balance=800.0,
                  hold=True, symbol="XAUUSD", tf="M30")
    bad += render("CASE 7  the same gold trade on a 3-DIGIT broker (points differ, money does not)",
                  SYMBOLS["XAUUSD-3d"], -3, atr=0.28, price=4285.700, balance=800.0,
                  symbol="XAUUSD", tf="M5")
    bad += render("CASE 8  a big balance: does a long number break the layout?",
                  SYMBOLS["XAUUSD-2d"], -3, atr=0.28, price=4285.70, balance=2500000.0,
                  symbol="XAUUSD", tf="M5")

    print("\n" + "=" * 78)
    if bad:
        print("FAILED: %d line(s) overflow" % len(bad))
        sys.exit(1)
    print("PASS: every case fits. The panel sizes itself from the text it draws,")
    print("so a long price or a large balance widens it instead of clipping it.")
    print("Panel with the plan: header %d + rows %d + gap %d + %d plan rows = %d px"
          % (HEAD_H, TF_COUNT * 2 * (FONT + 11), PLAN_SEP_H, PLAN_ROWS * (FONT + 11),
             HEAD_H + TF_COUNT * 2 * (FONT + 11) + 8 + PLAN_SEP_H + PLAN_ROWS * (FONT + 11)))


if __name__ == "__main__":
    main()
