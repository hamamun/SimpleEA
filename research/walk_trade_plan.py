"""Panel walk-through, including the second group (trade plan per timeframe).

Mirrors SimpleAdvisor.mq5 line for line:

  g_rows[]        the three timeframe readings (Group 1)
  g_plans[]       one plan block per timeframe (Group 2)
  UpdatePlanRow() builds each block's cells
  PlanColumns()   places the columns, aligned with "Trend:" / "Regime:" above
  PlanWidthNeed() and TotalPlanLines() size the panel BEFORE it is drawn
  DrawPlanBlock() places the text

The walk renders the panel on a character grid where one character is one
estimated pixel-column of the real font (CharW), so what you see is where the
text actually lands.  It then asserts that nothing runs past the panel edge -
the same guarantee the EA gives by sizing itself from the text it draws.

Run:  python walk_trade_plan.py
"""

import math
import sys

sys.path.insert(0, ".")
from verify_plan_math import SYMBOLS, plan, point_value_per_lot   # noqa: E402

HEAD_H, TF_COUNT, PLAN_SEP_H, PLAN_COL_A, PLAN_COL_B, PLAN_COL_C = 34, 3, 14, 150, 282, 414
PLAN_W_MIN = 406
# IncompatibleNotice() in the EA, verbatim
NOTICE = "Incompatible chart. Switch to M5/M15/M30."
PLAN_LBL_C = 8
FONT = 9
EM_EST = 0.55      # CharW(): what the EA budgets per character
DPI = 96
RENDER_CW = 9 * 96 / 72.0 * 0.55      # what one glyph really occupies (6.6 px)
CELL = RENDER_CW                      # the picture is one character per glyph

MINUTES = {"M5": 5, "M15": 15, "M30": 30}
HOLD, WAITING, ACTIVE = 0, 1, 2


def char_w(size=FONT, dpi=DPI):
    """CharW() in the EA: points -> pixels at the real screen DPI."""
    return int(math.ceil(size * dpi / 72.0 * EM_EST))


EM = char_w()
CW = RENDER_CW                        # used for placing text in the picture


class Panel:
    """The EA's state: three readings, three plan blocks, and what got drawn."""

    def __init__(self, symbol, spec, balance, tags=("M5", "M15", "M30"),
                 cur="USD", use_risk=True, use_min_lot=False, risk2=0.5, risk3=1.0,
                 sl_atr=1.2, tp_atr=2.4, pend_atr=0.5, valid_bars=3, show_plan=True,
                 atr=None):
        self.symbol, self.spec, self.balance, self.cur = symbol, spec, balance, cur
        self.tags = tags
        self.use_risk, self.use_min_lot = use_risk, use_min_lot
        self.risk2, self.risk3 = risk2, risk3
        self.sl_atr, self.tp_atr, self.pend_atr = sl_atr, tp_atr, pend_atr
        self.valid_bars, self.show_plan = valid_bars, show_plan
        self.panel_w = 406
        self.panel_h = 130
        # g_rows: tag -> (ok, direction, score, trend, regime)
        self.rows = {t: dict(ok=True, dir=0, score=0, trend="Sideways", regime="Mixed")
                     for t in tags}
        self.plans = {t: dict(state=HOLD, dir=0, score=0, market=False, lines=1,
                              head=t, kind="", note="", lbl={}, val={}, clr={})
                      for t in tags}
        #  average ranges, in PRICE terms, for the symbol this panel is on
        self.atr = atr or {"M5": 0.28, "M15": 0.85, "M30": 1.70}
        self.now = {"M5": "14:30", "M15": "14:45", "M30": "15:00"}

    def set_reading(self, tag, direction=0, score=0, trend="Sideways",
                    regime="Mixed", ok=True):
        self.rows[tag].update(ok=ok, dir=direction, score=score,
                              trend=trend, regime=regime)

    # ---- UpdatePlanRow() ------------------------------------------------
    def update_plan_row(self, tag):
        p = self.plans[tag]
        p.update(state=HOLD, dir=0, score=0, market=False, lines=1,
                 head=tag, kind="", note="", lbl={}, val={}, clr={})
        r = self.rows[tag]

        if not r["ok"]:
            p.update(state=WAITING, kind="waiting", note="history still loading")
            return
        if r["dir"] == 0:
            p.update(state=HOLD, kind="HOLD", note="nothing to place")
            return

        spec = self.spec
        point = spec["point"]
        price = self.price
        pv = point_value_per_lot(spec)
        dir_, score = r["dir"], r["score"]
        market = abs(score) >= 3
        dg = spec["digits"]
        atr = self.atr[tag]
        entry = price + (spec["point"] if dir_ > 0 else 0.0) * 0     # ask ~= bid + spread/2
        offset = self.pend_atr * atr
        pend = entry - dir_ * offset

        # stop / target snapped to the point grid, widened to the broker minimum
        sl_pts = max(1, int(round(self.sl_atr * atr / point)))
        tp_pts = max(1, int(round(self.tp_atr * atr / point)))
        min_stop = spec["stops_level"] * point
        widened = False
        if min_stop > 0 and sl_pts * point < min_stop:
            sl_pts = int(math.ceil(min_stop / point))
            widened = True
        sl_price = entry - dir_ * sl_pts * point
        tp_price = entry + dir_ * tp_pts * point

        # lot
        lots = spec["min_lot"]
        want_risk, min_lot = 0.0, False
        if self.use_min_lot:
            min_lot = True
        elif self.use_risk:
            pct = self.risk3 if abs(score) >= 3 else self.risk2
            want_risk = self.balance * pct / 100.0
            lots = want_risk / (sl_pts * pv) if pv > 0 else spec["min_lot"]
        else:
            lots = (self.balance / 1000.0) * 0.01
            if abs(score) >= 3:
                lots *= 1.5
        step = spec["step"]
        lots = math.floor(lots / step + 1e-8) * step
        lots = max(spec["min_lot"], min(spec["max_lot"], lots))
        digits = 0
        probe = step
        while probe < 1.0 and digits < 8:
            probe *= 10.0
            digits += 1
        lots = round(lots, digits)

        risk_usd = lots * sl_pts * pv
        reward_usd = lots * tp_pts * pv
        risk_over = (not self.use_min_lot and self.use_risk and want_risk > 0
                     and risk_usd > want_risk * 1.05)

        lot_txt = "%.2f" % lots
        if min_lot:
            lot_txt += " (min)"
        elif risk_over:
            lot_txt += " (min, %.2f %s)" % (risk_usd, self.cur)

        p.update(state=ACTIVE, dir=dir_, score=score, market=market, lines=3,
                 kind="%s %+d/%d" % ("market" if market else "pending", score, 3))
        p["lbl"][(0, 0)] = "Entry:"
        p["val"][(0, 0)] = "%.*f" % (dg, entry if market else pend)
        p["clr"][(0, 0)] = "dir"
        p["lbl"][(0, 1)] = "Lot:"
        p["val"][(0, 1)] = lot_txt
        p["clr"][(0, 1)] = "title"
        p["lbl"][(1, 0)] = "Stop:"
        p["val"][(1, 0)] = "%.*f %dpts%s" % (dg, sl_price, sl_pts, " (min)" if widened else "")
        p["clr"][(1, 0)] = "sell"
        p["lbl"][(1, 1)] = "Target:"
        p["val"][(1, 1)] = "%.*f %dpts" % (dg, tp_price, tp_pts)
        p["clr"][(1, 1)] = "buy"
        p["lbl"][(2, 0)] = "Risk:"
        p["val"][(2, 0)] = "%.2f %s" % (risk_usd, self.cur)
        p["clr"][(2, 0)] = "sell"
        p["lbl"][(2, 1)] = "Reward:"
        p["val"][(2, 1)] = "%.2f %s" % (reward_usd, self.cur)
        p["clr"][(2, 1)] = "buy"
        p["lbl"][(2, 2)] = "Valid:"
        p["val"][(2, 2)] = "%d bars -> %s" % (self.valid_bars, self.now[tag])
        p["clr"][(2, 2)] = "silver"

    def update_plan(self):
        for t in self.tags:
            self.update_plan_row(t)

    # ---- PlanColumns() --------------------------------------------------
    def plan_columns(self):
        cA, cB, cC = PLAN_COL_A, PLAN_COL_B, PLAN_COL_C
        vA = cA + EM * PLAN_LBL_C
        wA = max([len(p["val"][(l, 0)]) for t, p in self.plans.items()
                  for l in range(p["lines"]) if (l, 0) in p["val"]] or [0])
        cB = max(cB, vA + wA * EM + EM * 2)
        vB = cB + EM * PLAN_LBL_C
        wB = max([len(p["val"][(l, 1)]) for t, p in self.plans.items()
                  for l in range(p["lines"]) if (l, 1) in p["val"]] or [0])
        cC = max(cC, vB + wB * EM + EM * 2)
        vC = cC + EM * PLAN_LBL_C
        return cA, vA, cB, vB, cC, vC

    def total_plan_lines(self):
        return 0 if not self.show_plan else sum(p["lines"] for p in self.plans.values())

    # ---- PlanWidthNeed() ------------------------------------------------
    def plan_width_need(self):
        if not self.show_plan:
            return 0
        cA, vA, cB, vB, cC, vC = self.plan_columns()
        need = 44 + len("pending +3/3") * EM + 10
        for t, p in self.plans.items():
            if p["lines"] == 1:
                if p["note"]:
                    need = max(need, cA + len(p["note"]) * EM + 10)
                continue
            for (l, c), v in p["val"].items():
                vx = (vA, vB, vC)[c]
                need = max(need, vx + len(v) * EM + 10)
        return need

    # ---- DrawSupportedPanel() -------------------------------------------
    def draw(self):
        row_h = FONT + 11
        self.panel_h = (HEAD_H + TF_COUNT * 2 * row_h + 8
                        + (PLAN_SEP_H + self.total_plan_lines() * row_h if self.show_plan else 0))
        # the real EA: NoticeWidth() is the floor for BOTH panels, then the
        # plan's own measured need (when it is shown) can only add to it
        want = max(PLAN_W_MIN,
                   10 + len(NOTICE) * char_w(FONT + 1, DPI) + 10)
        if self.show_plan:
            want = max(want, self.plan_width_need())
        self.panel_w = want

        w_cols = int((self.panel_w - 4) / CELL)    # usable half-glyph columns
        grid = [[" "] * w_cols for _ in range(40)]
        last_col = {}                              # rightmost column used per line
        placed = []                                # (row, x_end_px) for the edge check

        def put(text, x_px, line):
            if not text:
                return
            col = max(0, int(round(x_px / CELL)))
            #  keep labels and values visually apart: the real panel leaves a
            #  few pixels between them, and whole-character rounding can
            #  swallow that gap ("Trend:" + its value would read as one word)
            col = max(col, last_col.get(line, -1) + 2)
            for k, ch in enumerate(text):
                if col + k < w_cols:
                    grid[line][col + k] = ch
            last_col[line] = col + len(text) - 1
            placed.append((line, x_px, x_px + len(text) * RENDER_CW, text))

        separators = set()

        # ---- Group 1 -----------------------------------------------------
        put("SimpleEA", 10, 0)
        sym = "%s  %s" % (self.symbol, self.tags[0])
        put(sym, self.panel_w - 10 - len(sym) * RENDER_CW, 0)
        separators.add(1)
        line = 2
        for t in self.tags:
            r = self.rows[t]
            put(t, 10, line)
            put({"M5": "Scalp", "M15": "Short-term", "M30": "Intraday"}[t], 44, line)
            put("Trend:", 150, line)
            put(r["trend"], 192, line)
            put("Regime:", 282, line)
            put(r["regime"], 330, line)
            line += 1
            put("Signal:", 150, line)
            put({"1": "BUY", "-1": "SELL", "0": "HOLD"}[str(r["dir"])], 192, line)
            put("Score:", 282, line)
            put("%+d / 3" % r["score"], 330, line)
            line += 1

        # ---- Group 2 -----------------------------------------------------
        if self.show_plan:
            separators.add(line)                     # the separator between groups
            line += 1
            cA, vA, cB, vB, cC, vC = self.plan_columns()
            for t in self.tags:
                p = self.plans[t]
                put(p["head"], 10, line)
                if p["kind"]:
                    put(p["kind"], 44, line)
                if p["lines"] == 1 and p["note"]:
                    put(p["note"], cA, line)
                for l in range(p["lines"]):
                    for c in range(3):
                        key = (l, c)
                        if key not in p["lbl"]:
                            continue
                        put(p["lbl"][key], (cA, cB, cC)[c], line + l)
                        put(p["val"][key], (vA, vB, vC)[c], line + l)
                line += p["lines"]

        rows = ["".join(r).rstrip() for r in grid]
        for r in separators:
            rows[r] = "-" * w_cols
        return rows, line, separators, placed

    def render(self, title):
        grid, last, separators, placed = self.draw()
        w_cols = int((self.panel_w - 4) / CW)
        print("\n" + "=" * 96)
        print(title)
        print("=" * 96)
        print("  +" + "-" * w_cols + "+")
        for i, txt in enumerate(grid):
            if i >= last:                      # `last` is the next free row
                break
            print("  | %s |" % txt.ljust(w_cols))
        print("  +" + "-" * w_cols + "+")
        print("  panel: %d x %d px   (one character = %.1f px)"
              % (self.panel_w, self.panel_h, CELL))

        # ---- the guarantee: nothing drawn may pass the right edge --------
        over = []
        for line, x0, x_end, txt in placed:
            if x_end > self.panel_w - 3:
                over.append((line, txt, x_end))
        for line, txt, w in over:
            print("  !! line %d ends at %.0f px in a %d px panel: %r"
                  % (line, w, self.panel_w, txt))
        self.placed = placed
        return over


# ---------------------------------------------------------------------
#  The width sweep: CharW() budgets 0.55 em per character.  MetaTrader
#  sizes fonts in points, so the pixel advance depends on the screen DPI,
#  and different monospaced faces are not all 0.55 em wide.  This section
#  re-measures the widest line of the widest case with REAL glyph
#  advances, from a 72 dpi laptop screen to a 192 dpi monitor and font
#  sizes 6..16, and reports what the budget costs.  It fails only if the
#  default font (Consolas) would clip - a wider face is reported, since
#  every pixel of slack is a pixel of panel the user asked not to waste.
# ---------------------------------------------------------------------
ADVANCES = {"Consolas (the default)": 0.5498,
            "DejaVu Sans Mono": 0.6020,
            "Courier New": 0.6000,
            "Lucida Console": 0.6000}


def sweep():
    print("\n" + "=" * 96)
    print("Width sweep - does the 0.55 em budget hold up across DPI and font size?")
    print("=" * 96)
    worst = {}
    for name, adv in ADVANCES.items():
        worst[name] = (0.0, None, 0.0)
        for dpi in (72, 96, 120, 144, 192):
            for size in range(6, 17):
                # the widest line the panel ever draws, in this font size:
                # case A (three active timeframes) is the widest of the eight
                p = Panel("XAUUSD", SYMBOLS["XAUUSD-2d"], 800.0)
                for t, r in (("M5",  dict(direction=-1, score=-3, trend="Going down", regime="Steady")),
                             ("M15", dict(direction=1,  score=2,  trend="Going up",   regime="Mixed")),
                             ("M30", dict(direction=-1, score=-2, trend="Going down", regime="Choppy"))):
                    p.set_reading(t, **r)
                p.price = 4285.70
                p.update_plan()
                # widths as the EA computes them, at THIS dpi and size
                em_bud = char_w(size, dpi)
                em_real = size * dpi / 72.0 * adv
                need_bud = panel_need_at(p, em_bud)
                need_real = panel_need_at(p, em_real)
                if need_real > need_bud:
                    f = (need_real / need_bud - 1.0) * 100.0
                    if f > worst[name][0]:
                        worst[name] = (f, (dpi, size), need_real - need_bud)
        f, where, px = worst[name]
        if px <= 0:
            print("  %-22s budget always sufficient" % name)
        else:
            print("  %-22s widest overshoot %+6.2f px (%+.1f%%) at dpi %d, font %d"
                  % (name, px, f, where[0], where[1]))
    f, where, px = worst["Consolas (the default)"]
    return px > 0.5


def panel_need_at(p, em):
    """PlanWidthNeed()/NoticeWidth() with a given pixel width per character."""
    cA, cB, cC = PLAN_COL_A, PLAN_COL_B, PLAN_COL_C
    vA, vB = cA + em * PLAN_LBL_C, cB + em * PLAN_LBL_C
    wA = max([len(q["val"][(l, 0)]) for q in p.plans.values()
              for l in range(q["lines"]) if (l, 0) in q["val"]] or [0])
    cB = max(cB, vA + wA * em + em * 2)
    vB = cB + em * PLAN_LBL_C
    wB = max([len(q["val"][(l, 1)]) for q in p.plans.values()
              for l in range(q["lines"]) if (l, 1) in q["val"]] or [0])
    cC = max(cC, vB + wB * em + em * 2)
    vC = cC + em * PLAN_LBL_C
    need = max(PLAN_W_MIN, 10 + len(NOTICE) * em + 10,
               44 + len("pending +3/3") * em + 10)
    for q in p.plans.values():
        if q["lines"] == 1:
            if q["note"]:
                need = max(need, cA + len(q["note"]) * em + 10)
            continue
        for (l, c), v in q["val"].items():
            need = max(need, (vA, vB, vC)[c] + len(v) * em + 10)
    return need


def case(title, readings, symbol="XAUUSD", spec=None, balance=800.0, price=4285.70, **kw):
    p = Panel(symbol, spec or SYMBOLS["XAUUSD-2d"], balance, **kw)
    p.price = price
    for tag, r in readings.items():
        p.set_reading(tag, **r)
    p.update_plan()
    return p.render(title)


def main():
    print("SimpleEA - Group 1 (readings) + Group 2 (one plan per timeframe)")

    bad = []
    bad += case("A)  all three timeframes active",
                {"M5":  dict(direction=-1, score=-3, trend="Going down", regime="Steady"),
                 "M15": dict(direction=1,  score=2,  trend="Going up",   regime="Mixed"),
                 "M30": dict(direction=-1, score=-2, trend="Going down", regime="Choppy")})
    bad += case("B)  the common case: one active, two HOLD (one line each)",
                {"M5":  dict(direction=-1, score=-3, trend="Going down", regime="Steady"),
                 "M15": dict(direction=0,  score=0,  trend="Sideways",   regime="Mixed"),
                 "M30": dict(direction=0,  score=0,  trend="Sideways",   regime="Choppy")})
    bad += case("C)  nothing anywhere: Group 2 shrinks to three lines",
                {"M5":  dict(direction=0, score=0),
                 "M15": dict(direction=0, score=0),
                 "M30": dict(direction=0, score=0)})
    bad += case("D)  M15 still downloading history",
                {"M5":  dict(direction=-1, score=-3, trend="Going down", regime="Steady"),
                 "M15": dict(ok=False),
                 "M30": dict(direction=0, score=0)})
    bad += case("E)  a $200 account where the minimum lot risks more than 1% (flagged)",
                {"M5":  dict(direction=-1, score=-3, trend="Going down", regime="Steady"),
                 "M15": dict(direction=0, score=0),
                 "M30": dict(direction=0, score=0)}, balance=200.0)
    bad += case("F)  a big balance and a wide stop: do long numbers break the layout?",
                {"M5":  dict(direction=-1, score=-3, trend="Going down", regime="Steady"),
                 "M15": dict(direction=1, score=3, trend="Going up", regime="Steady"),
                 "M30": dict(direction=0, score=0)}, balance=2500000.0)
    bad += case("G)  min-lot mode on EURUSD",
                {"M5":  dict(direction=1, score=3, trend="Going up", regime="Steady"),
                 "M15": dict(direction=0, score=0),
                 "M30": dict(direction=0, score=0)},
                symbol="EURUSD", spec=SYMBOLS["EURUSD-5d"], balance=800.0,
                use_min_lot=True, price=1.08542,
                atr={"M5": 0.00055, "M15": 0.00090, "M30": 0.00140})
    bad += case("H)  InpShowPlan = false: Group 2 is not drawn at all",
                {"M5":  dict(direction=1, score=3, trend="Going up", regime="Steady"),
                 "M15": dict(direction=0, score=0),
                 "M30": dict(direction=0, score=0)}, show_plan=False)

    bad += [("sweep", 0.0, 0.0)] if sweep() else []

    print("\n" + "=" * 96)
    if bad:
        print("FAILED: %d problem(s)" % len(bad))
        sys.exit(1)
    print("PASS: every case fits.  The panel measures Group 2's text and sizes")
    print("itself before drawing, and HOLD/waiting rows collapse to one line,")
    print("so the block is exactly as tall and as wide as its content needs.")


if __name__ == "__main__":
    main()
