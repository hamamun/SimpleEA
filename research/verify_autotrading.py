"""Fixed-exit autotrading verification for SimpleAdvisor.mq5.

This suite has two deliberately separate layers:

1. Source-contract checks prove that the MQL5 has no trailing/SL-modification
   or signal/box open-position close path, that every new order carries an SL,
   and that pending-order entry management is still present.
2. A small Python model exercises the TP1/TP2/TP3 volume ladder for BUY and
   SELL, including minimum-lot and multi-level tick cases.

These are regression checks, not an MQL5 compilation or a profitability test.
Run: python3 research/verify_autotrading.py
"""

from pathlib import Path
import math

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "SimpleAdvisor.mq5").read_text(encoding="utf-8")
CHECKS = 0


def check(condition, message):
    global CHECKS
    CHECKS += 1
    if not condition:
        raise AssertionError(message)


def function_body(name, source=SOURCE):
    """Return one MQL function using a comment/string-aware brace scan."""
    marker = name + "("
    start = source.index(marker)
    brace = source.index("{", start)
    depth = 0
    i = brace
    state = "code"
    while i < len(source):
        ch = source[i]
        nxt = source[i + 1] if i + 1 < len(source) else ""
        if state == "code":
            if ch == "/" and nxt == "/":
                state = "line"
                i += 2
                continue
            if ch == "/" and nxt == "*":
                state = "block"
                i += 2
                continue
            if ch == '"':
                state = "string"
            elif ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    return source[start:i + 1]
        elif state == "line":
            if ch == "\n":
                state = "code"
        elif state == "block":
            if ch == "*" and nxt == "/":
                state = "code"
                i += 2
                continue
        elif state == "string":
            if ch == "\\":
                i += 2
                continue
            if ch == '"':
                state = "code"
        i += 1
    raise AssertionError("unterminated function: " + name)


def code_only(source):
    """Blank comments/strings while retaining positions and newlines."""
    out = list(source)
    i = 0
    state = "code"
    while i < len(source):
        ch = source[i]
        nxt = source[i + 1] if i + 1 < len(source) else ""
        if state == "code":
            if ch == "/" and nxt == "/":
                out[i] = out[i + 1] = " "
                state = "line"
                i += 2
                continue
            if ch == "/" and nxt == "*":
                out[i] = out[i + 1] = " "
                state = "block"
                i += 2
                continue
            if ch == '"':
                out[i] = " "
                state = "string"
        elif state == "line":
            if ch == "\n":
                state = "code"
            else:
                out[i] = " "
        elif state == "block":
            if ch == "*" and nxt == "/":
                out[i] = out[i + 1] = " "
                state = "code"
                i += 2
                continue
            if ch != "\n":
                out[i] = " "
        elif state == "string":
            if ch == "\\" and nxt:
                out[i] = out[i + 1] = " "
                i += 2
                continue
            if ch != "\n":
                out[i] = " "
            if ch == '"':
                state = "code"
        i += 1
    check(state in ("code", "line"), "unterminated MQL comment/string")
    return "".join(out)


def compute_tp_levels(tp3):
    """ComputeTPLevels(), including MQL's half-away-from-zero rounding."""
    tp3 = max(1, int(tp3))
    tp2 = max(1, int(math.floor(tp3 * 0.75 + 0.5)))
    tp1 = max(1, int(math.floor(tp2 * 0.75 + 0.5)))
    return tp1, tp2, tp3


def floor_lot_step(lots, spec):
    step = spec["step"]
    n = max(0.0, math.floor(lots / step + 1e-8) * step)
    digits = 0
    probe = step
    while probe < 1.0 and digits < 8:
        probe *= 10.0
        digits += 1
    return round(n, digits)


def calc_tp1_close_lot(cur_lot, spec):
    mn = spec["min_lot"]
    if cur_lot <= mn + 1e-8:
        return 0.0
    close_lot = floor_lot_step(cur_lot * 0.70, spec)
    if cur_lot - close_lot < mn - 1e-8:
        close_lot = floor_lot_step(cur_lot - mn, spec)
    if close_lot < mn - 1e-8:
        return 0.0
    return close_lot


def calc_tp2_close_lot(cur_lot, spec):
    mn = spec["min_lot"]
    if cur_lot <= mn + 1e-8:
        return 0.0
    close_lot = floor_lot_step(cur_lot - mn, spec)
    if close_lot < mn - 1e-8:
        return 0.0
    return close_lot


class FixedExitModel:
    """The reduced ManageAutoTick() contract, with a broker-like close log."""

    def __init__(self, direction, entry, point, sl_pts, tp3_pts, lot, spec):
        self.dir = direction
        self.entry = entry
        self.point = point
        self.sl_pts = sl_pts
        self.sl_price = entry - direction * sl_pts * point
        self.original_sl = self.sl_price
        self.tp1_pts, self.tp2_pts, self.tp3_pts = compute_tp_levels(tp3_pts)
        self.tp_price = entry + direction * tp3_pts * point
        self.cur_lot = lot
        self.tp1_hit = False
        self.tp2_hit = False
        self.active = True
        self.closes = []
        self.spec = spec

    def close(self, volume, reason):
        if volume <= 0.0 or not self.active:
            return
        self.closes.append((reason, volume))
        self.cur_lot = floor_lot_step(self.cur_lot - volume, self.spec)
        if self.cur_lot <= 1e-8:
            self.active = False

    def tick(self, exit_price, gross_price=None):
        """Tick exits only; no signal, regime, box or SL input exists."""
        if not self.active:
            return
        if gross_price is None:
            gross_price = exit_price
        fav_pts = self.dir * (exit_price - self.entry) / self.point
        gross_pts = self.dir * (gross_price - self.entry) / self.point

        if self.tp3_pts > 0 and fav_pts >= self.tp3_pts - 1e-6:
            self.close(self.cur_lot, "TP3")
            return

        if (not self.tp1_hit and self.tp1_pts > 0 and
                (fav_pts >= self.tp1_pts - 1e-6 or
                 (gross_pts >= self.tp1_pts - 1e-6 and fav_pts > 0.0))):
            self.tp1_hit = True
            self.close(calc_tp1_close_lot(self.cur_lot, self.spec), "TP1")

        if (self.tp1_hit and not self.tp2_hit and self.tp2_pts > 0 and
                fav_pts >= self.tp2_pts - 1e-6):
            self.tp2_hit = True
            self.close(calc_tp2_close_lot(self.cur_lot, self.spec), "TP2")

        check(self.sl_price == self.original_sl,
              "the model must never move the entry SL")


def verify_source_contract():
    removed = (
        "InpImmediateFlipClose", "InpUseStopLoss", "InpUseTrailStop",
        "InpTrailPctTight", "InpTrailPctSteady", "UpdatePreTP1Trail",
        "UpdateProfitProtectionFloor", "IsScoreStrongForTrade",
        "FlipCloseAllowed", "MilestoneSLPrice", "ClampProfitFloorSL",
        "InitTrailState", "TradeModifyPosition", "TRADE_ACTION_SLTP",
        "TRAIL_STEP_PCT", "HALF_TP1_LOCK_RATIO", "TP1_LOCK_RATIO",
        "useTrailStop", "protectionArmed", "bestLockTp1Pct", "bestStopTp1Pct", '"tapp"',
    )
    for token in removed:
        check(token not in SOURCE, "removed exit rule is still present: " + token)
    check("trail" not in SOURCE.lower(),
          "a trail-related identifier or stale code comment remains in SimpleAdvisor.mq5")

    tick = function_body("void ManageAutoTick")
    bar = function_body("void ManageAutoBar")
    place = function_body("bool PlacePlanOrder")
    sync = function_body("void SyncAutoState")

    check(tick.count("TradeClosePosition(") == 3 and
          SOURCE.count("TradeClosePosition(") == 4,
          "the wrapper plus exactly TP3, TP1 and TP2 must be the only close sites")
    check("TradeClosePosition(" not in bar,
          "bar manager must not close an open position on a signal/box event")
    check("TradeModifyPosition" not in tick + bar + sync,
          "open-position SL/TP modification path returned")
    check("OrderSend(" not in tick + bar,
          "managers must use the reviewed trade wrappers")
    check("g_auto[i].slPrice =" not in tick,
          "tick exits must not rewrite SL state")
    check("g_auto[i].tp1Hit = true;" in tick and
          "g_auto[i].tp2Hit = true;" in tick,
          "TP milestone state must be retained")
    check("g_auto[i].entryScore = g_rows[i].score" not in bar,
          "open-trade peak-score watcher must not return")

    case_a = bar[bar.index("// ---- CASE A"):bar.index("// ---- CASE B")]
    case_b = bar[bar.index("// ---- CASE B"):bar.index("// ---- CASE C")]
    check("continue;" in case_a and "Trade" not in case_a and "OrderSend" not in case_a,
          "open-position bar branch must be observation-only")
    for token in ("TradeDeleteOrder(", "TradeModifyOrder(", "PlacePlanOrder(",
                  "g_plans[i].market", "expired", "RegimeBlocksEntry(i)",
                  "timerAllowsPlacement", "g_auto[i].rngTop", "g_auto[i].rngBot"):
        check(token in case_b, "pending entry management was lost: " + token)
    check("TradeClosePosition(" not in case_b and "TradeModifyPosition" not in case_b,
          "pending branch must not manage an open position")

    check("NormPrice(execP - (double)dir * (double)slPts * point)" in place,
          "market order must carry its planned fixed SL")
    check("NormPrice(pendP - (double)dir * (double)slPts * point)" in place,
          "pending order must carry its planned fixed SL")
    check("NormPrice(execP + (double)dir * (double)tp3Pts * point)" in place and
          "NormPrice(pendP + (double)dir * (double)tp3Pts * point)" in place,
          "both order types must carry TP3")
    check("g_auto[i].slPts         = slPts;" in place,
          "placed slot must retain the initial SL distance")
    check("if(i < 0 || i >= TF_COUNT || !g_freshBar[i]) return(false);" in place and
          "if(!ScoreAllowsTrade(g_plans[i].dir, g_plans[i].score)) return(false);" in place and
          "if(!TrendMatchForTF(i)) return(false);" in place,
          "entry timing/score/trend gates must remain intact")

    for token in ("| Exits : ", '"TP/SL"', '"Fixed" : "Missing"',
                  'g_auto[i].lbl[3][2] = "Exit:"',
                  '"-- (missing)"'):
        check(token in SOURCE, "fixed-exit panel text missing: " + token)
    check('"| Trailstop : "' not in SOURCE and 'g_auto[i].lbl[3][2] = "TS:"' not in SOURCE,
          "obsolete trailstop panel claims remain")
    check("r.useStopLoss   = true;" in SOURCE and
          's += "0;"; // CSV 34:' in SOURCE and
          's += "0;0;0;0;0;-1.0000;-9999.0000;";' in SOURCE,
          "diary rows must keep fixed-SL data and reserved compatibility columns")
    check("p[34] and p[40-46] are reserved compatibility columns" in SOURCE and
          "if(n > 47) r.finalTp1Pct" in SOURCE and
          "if(n > 49) r.stopKnown" in SOURCE,
          "40-50 field diary compatibility must remain without legacy calculations")
    parser_code = code_only(function_body("bool DiaryParseRecordLine"))
    for field in (34, 40, 41, 42, 43, 44, 45, 46):
        check(f"p[{field}]" not in parser_code,
              f"reserved diary column {field} is still loaded into state")

    serializer = function_body("string DiaryRecordLine")
    serialized_fields = 1  # field 0 is initialized with DIARY_VERSION
    for line in serializer.splitlines():
        line = line.strip()
        if not line.startswith("s +="):
            continue
        if line.startswith('s += "'):
            serialized_fields += line.split('"', 2)[1].count(";")
        else:
            serialized_fields += 1
    check(serialized_fields == 50,
          f"diary serializer must retain 50 columns, found {serialized_fields}")

    # Lightweight lexical validation; this is not advertised as compilation.
    stripped = code_only(SOURCE)
    pairs = {")": "(", "]": "[", "}": "{"}
    stack = []
    for ch in stripped:
        if ch in "([{":
            stack.append(ch)
        elif ch in ")]}":
            if not stack or stack[-1] != pairs[ch]:
                raise AssertionError("unbalanced MQL delimiter near " + ch)
            stack.pop()
    check(not stack, "unclosed MQL delimiters: " + repr(stack[-10:]))


def verify_tp_arithmetic():
    for tp3, expected in ((67, (38, 50, 67)), (204, (115, 153, 204)),
                          (510, (287, 383, 510)), (1, (1, 1, 1)),
                          (2, (2, 2, 2)), (3, (2, 2, 3))):
        check(compute_tp_levels(tp3) == expected,
              "TP ladder mismatch for %d: %r" % (tp3, compute_tp_levels(tp3)))

    gold = {"min_lot": 0.01, "step": 0.01}
    index = {"min_lot": 0.10, "step": 0.10}
    for spec, lot, tp1_close, remainder in (
            (gold, 1.00, 0.70, 0.30), (gold, 0.10, 0.07, 0.03),
            (gold, 0.02, 0.01, 0.01), (gold, 0.01, 0.00, 0.01),
            (index, 1.00, 0.70, 0.30), (index, 0.20, 0.10, 0.10),
            (index, 0.10, 0.00, 0.10)):
        got = calc_tp1_close_lot(lot, spec)
        check(abs(got - tp1_close) < 1e-8,
              "TP1 volume mismatch: lot %.2f -> %.2f" % (lot, got))
        check(abs((lot - got) - remainder) < 1e-8,
              "TP1 must leave a valid remainder")
        check(got == 0.0 or (got >= spec["min_lot"] - 1e-8 and
                             lot - got >= spec["min_lot"] - 1e-8),
              "TP1 partial must respect broker minimum on both legs")

    for spec, lot, expected, remainder in (
            (gold, 0.30, 0.29, 0.01), (gold, 0.03, 0.02, 0.01),
            (gold, 0.01, 0.00, 0.01), (index, 0.30, 0.20, 0.10),
            (index, 0.10, 0.00, 0.10)):
        got = calc_tp2_close_lot(lot, spec)
        check(abs(got - expected) < 1e-8,
              "TP2 volume mismatch: lot %.2f -> %.2f" % (lot, got))
        check(abs((lot - got) - remainder) < 1e-8,
              "TP2 must leave exactly broker minimum when a partial is possible")


def verify_fixed_exit_paths():
    spec = {"min_lot": 0.01, "step": 0.01}
    for direction in (1, -1):
        entry = 4285.70
        point = 0.01
        trade = FixedExitModel(direction, entry, point, 34, 67, 1.00, spec)
        expected_sl = entry - direction * 0.34
        expected_tp = entry + direction * 0.67
        check(abs(trade.sl_price - expected_sl) < 1e-9,
              "initial BUY/SELL SL is not mirrored correctly")
        check(abs(trade.tp_price - expected_tp) < 1e-9,
              "initial BUY/SELL TP3 is not mirrored correctly")

        # This used to activate the universal floor/trailing.  It now does nothing.
        trade.tick(entry + direction * 19 * point)
        check(not trade.closes and not trade.tp1_hit and
              trade.sl_price == expected_sl,
              "pre-TP1 progress must not close or move SL")

        trade.tick(entry + direction * 38 * point)
        check(trade.tp1_hit and not trade.tp2_hit and
              trade.closes == [("TP1", 0.70)] and abs(trade.cur_lot - 0.30) < 1e-8,
              "TP1 must close 70% only")
        check(trade.sl_price == expected_sl, "TP1 must not lock or trail SL")

        # A later candle/signal cannot call this model at all: only another price
        # tick drives exits.  Repeating the same tick must not duplicate TP1.
        trade.tick(entry + direction * 38 * point)
        check(trade.closes == [("TP1", 0.70)], "TP1 partial must happen once")

        trade.tick(entry + direction * 50 * point)
        check(trade.tp2_hit and trade.closes == [("TP1", 0.70), ("TP2", 0.29)] and
              abs(trade.cur_lot - 0.01) < 1e-8,
              "TP2 must reduce the remainder to minimum lot")
        check(trade.sl_price == expected_sl, "TP2 must not move SL to TP1")

        trade.tick(entry + direction * 50 * point)
        check(len(trade.closes) == 2, "TP2 partial must happen once")
        trade.tick(entry + direction * 67 * point)
        check(not trade.active and trade.closes[-1] == ("TP3", 0.01),
              "TP3 must close the final remainder")
        check(trade.sl_price == expected_sl, "SL must still equal its entry value")

    # A direct jump through all levels takes TP3 first and closes the whole lot.
    jumped = FixedExitModel(1, 100.0, 0.01, 20, 67, 1.00, spec)
    jumped.tick(100.67)
    check(not jumped.active and jumped.closes == [("TP3", 1.00)],
          "a TP3 tick must close full volume, not manufacture earlier partials")

    # Minimum-lot trades mark TP milestones but cannot make invalid partials.
    small = FixedExitModel(-1, 100.0, 0.01, 20, 67, 0.01, spec)
    small.tick(99.62)
    check(small.tp1_hit and small.active and not small.closes,
          "minimum-lot TP1 must not close an invalid remainder")
    small.tick(99.50)
    check(small.tp2_hit and small.active and not small.closes,
          "minimum-lot TP2 must not close an invalid remainder")
    small.tick(99.33)
    check(not small.active and small.closes == [("TP3", 0.01)],
          "minimum-lot TP3 must still close in full")

    # Gross-price TP1 fallback remains, but still requires positive net progress.
    gross = FixedExitModel(1, 100.0, 0.01, 20, 67, 1.00, spec)
    gross.tick(100.30, gross_price=100.38)
    check(gross.tp1_hit and gross.closes == [("TP1", 0.70)],
          "gross TP1/spread fallback must retain its partial close")
    negative = FixedExitModel(1, 100.0, 0.01, 20, 67, 1.00, spec)
    negative.tick(99.90, gross_price=100.38)
    check(not negative.tp1_hit and not negative.closes,
          "gross TP1 fallback must not trigger with negative net progress")


def main():
    verify_source_contract()
    print("  ok  source contains fixed TP/SL exits only; pending entries preserved")
    verify_tp_arithmetic()
    print("  ok  TP rounding and broker-lot partial arithmetic")
    verify_fixed_exit_paths()
    print("  ok  BUY/SELL TP1 -> TP2 -> TP3 paths never move SL")
    print("\nall %d fixed-exit autotrading checks passed" % CHECKS)
    print("note: Python/source verification only; compile SimpleAdvisor.mq5 in MetaEditor")


if __name__ == "__main__":
    main()
