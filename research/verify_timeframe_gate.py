"""Chart-timeframe rule - state-machine check.

Transcribes the panel logic of SimpleAdvisor.mq5 (OnInit / OnTick / OnTimer /
CheckNewBars / EvaluateAll / BuildPanel / DrawPanel / DrawSupportedPanel /
DrawIncompatiblePanel) and drives it through every timeframe MetaTrader can
put a chart on and every switch between them.

What it proves:
  1. On M5 / M15 / M30 the full panel is drawn, exactly as before this change.
  2. On every OTHER timeframe the panel is the header line plus the notice
     "Incompatible chart. Switch to M5/M15/M30." and nothing else: no
     Trend / Regime / Signal / Score text, no "Waiting", no leftover row.
  3. The engine is never invoked while the chart is on a wrong timeframe
     (measured by counting entries into the scoring code), and 200 ticks plus
     200 timer beats change nothing on screen.
  4. Every switch works with and without the MetaTrader re-init that normally
     happens when the chart timeframe is changed.
  5. Geometry: the notice panel is header-height only, the notice text fits
     inside it at the font size in use, and the header sits on exactly the
     same line as it does in the full panel.

The signal arithmetic itself is NOT re-tested here - that lives in
research/verify_mql.py against the validated reference engine.  This script
only exercises the chart-timeframe gate and the drawing state machine.
"""

import math
from enum import Enum

# ----------------------------------------------------------------------
# Metrics, mirroring SimpleAdvisor.mq5
# ----------------------------------------------------------------------
HEAD_H  = 34          # header band height
ROW_H   = 20          # one text line (InpFontSize + 11 with the default 9)
TF_COUNT = 3
EM_EST  = 0.75        # CharW(): per-character width estimate, rounded up
EM_REAL = 0.55 * 96.0 / 72.0   # a monospaced face really needs about this much


class TF(Enum):
    M1 = "M1";   M2 = "M2";   M3 = "M3";   M4 = "M4";   M5 = "M5"
    M6 = "M6";   M10 = "M10"; M12 = "M12"; M15 = "M15"; M20 = "M20"
    M30 = "M30"; H1 = "H1";   H2 = "H2";   H3 = "H3";   H4 = "H4"
    H6 = "H6";   H8 = "H8";   H12 = "H12"; D1 = "D1";   W1 = "W1"
    MN1 = "MN1"


SUPPORTED = {TF.M5, TF.M15, TF.M30}
TF_TEXT = "M5/M15/M30"

NOTICE = "Incompatible chart. Switch to " + TF_TEXT + "."

ROW_OBJECTS = ["tf", "style", "trendCap", "regimeCap", "signalCap", "scoreCap",
               "dir", "regimeVal", "signal", "score"]

#  Illustration only: what the stand-in engine returns for each row.
READINGS = {"M5":  (1, 3, "Steady"),
            "M15": (0, 1, "Mixed"),
            "M30": (-1, -2, "Choppy")}


def timeframe_ok(tf):
    """TIMEFRAME_OK() in SimpleAdvisor.mq5."""
    return tf in SUPPORTED


# ----------------------------------------------------------------------
# The EA, transcribed
# ----------------------------------------------------------------------
class SimpleEA:
    def __init__(self, symbol, tf, font_size=9):
        self.symbol = symbol
        self.tf = tf                      # the chart timeframe
        self.font = font_size
        self.row_h = font_size + 11
        self.panel_x = 12
        self.panel_y = 24
        self.panel_w = 406                # g_panelW (widened in on_init if needed)
        self.panel_h = HEAD_H + TF_COUNT * 2 * self.row_h + 8   # g_panelH
        self.objects = {}                 # name -> ("label", text, y) | ("rect", w, h)
        self.panel_ok = False             # g_panelOK
        self.drawn_tf = None              # g_drawnTf
        self.rows = [{"tag": t, "ok": False, "score": 0, "dir": 0, "regime": ""}
                     for t in ("M5", "M15", "M30")]
        self.engine_calls = 0             # counts EvaluateRow() entries
        self.timer_on = False
        self.log = []

    # ---- the single test everything hangs on --------------------------
    def chart_supported(self):
        return timeframe_ok(self.tf)

    def chart_timeframe_text(self):
        return self.tf.value               # ShortTimeframe()

    # ---- object helpers ----------------------------------------------
    def make_label(self, name, text, y):
        self.objects[name] = ("label", text, y)

    def make_rect(self, name, w, h):
        self.objects[name] = ("rect", w, h)

    def delete_object(self, name):
        self.objects.pop(name, None)

    def delete_panel(self):
        self.objects.clear()

    def char_w(self):
        """CharW(): one character, in pixels, rounded up (never too small)."""
        return int(math.ceil((self.font + 1) * EM_EST))

    def text_width(self, text):
        """Estimated rendered width, conservative (what OnInit uses)."""
        return len(text) * self.char_w()

    # ---- setup --------------------------------------------------------
    def on_init(self):
        self.objects.clear()
        self.panel_ok = False
        self.drawn_tf = None

        self.panel_h = HEAD_H + TF_COUNT * 2 * self.row_h + 8
        notice_w = 10 + self.text_width(NOTICE) + 10
        if notice_w > self.panel_w:
            self.panel_w = notice_w

        self.build_panel()

        if not self.chart_supported():
            #  The exact line OnInit() writes to the Experts journal.
            self.log.append("SimpleEA: the %s chart is not supported. This panel "
                            "is calibrated for %s only - switch the chart "
                            "timeframe to see it."
                            % (self.chart_timeframe_text(), TF_TEXT))
        else:
            self.evaluate_all()

        self.draw_panel()

        #  The timer runs in both states.  On a supported chart the heavy
        #  work only runs when a new bar closes; on any other chart the
        #  timer just notices if the chart came back to M5/M15/M30.
        self.timer_on = True

    def on_deinit(self):
        self.timer_on = False
        self.delete_panel()

    def on_tick(self):
        self.check_new_bars()

    def on_timer(self):
        self.check_new_bars()

    def check_new_bars(self):
        if not self.chart_supported():
            if self.panel_ok or self.drawn_tf != self.tf:
                self.draw_panel()
            return

        if not self.panel_ok:               # coming back from a wrong chart
            self.evaluate_all()
            self.draw_panel()
            return

        if self.new_bar():
            self.evaluate_all()
            self.draw_panel()

    def new_bar(self):
        return not self.rows[0]["ok"]

    # ---- evaluation ---------------------------------------------------
    def evaluate_all(self):
        if not self.chart_supported():
            for r in self.rows:
                r.update(ok=False, score=0, dir=0)
            return
        for r in self.rows:
            self.evaluate_row(r)

    def evaluate_row(self, r):
        # Stands in for the real engine (Precision Trend + ROC + Hurst + ER,
        # verified separately in verify_mql.py).  Counted, so the tests can
        # prove it is never entered on an unsupported chart.  The readings
        # themselves are fixed illustrations, one per timeframe.
        self.engine_calls += 1
        dir_, score, regime = READINGS[r["tag"]]
        r.update(ok=True, score=score, dir=dir_, regime=regime)

    # ---- drawing ------------------------------------------------------
    def build_panel(self):
        self.make_rect("bg", self.panel_w, self.panel_h)
        self.make_rect("sep", self.panel_w - 8, 1)

    def draw_panel(self):
        if self.chart_supported():
            self.draw_supported_panel()
        else:
            self.draw_incompatible_panel()

    def draw_supported_panel(self):
        self.panel_h = HEAD_H + TF_COUNT * 2 * self.row_h + 8
        self.make_rect("bg", self.panel_w, self.panel_h)
        self.make_rect("sep", self.panel_w - 8, 1)
        self.make_label("title", "SimpleEA2.0", self.panel_y + 7)
        self.make_label("sym", "%s  %s" % (self.symbol, self.chart_timeframe_text()),
                        self.panel_y + 8)

        for i, r in enumerate(self.rows):
            sfx = "_%d" % i
            ry = self.panel_y + HEAD_H + 2 + i * 2 * self.row_h
            for base in ROW_OBJECTS:
                self.make_label(base + sfx, "...", ry)

        self.delete_object("notice")
        self.panel_ok = True
        self.drawn_tf = self.tf

    def notice_h(self):
        return HEAD_H + 2 + (self.font + 1) + 6

    def draw_incompatible_panel(self):
        self.make_rect("bg", self.panel_w, self.notice_h())
        self.delete_object("sep")
        self.make_label("title", "SimpleEA2.0", self.panel_y + 7)
        self.make_label("sym", "%s  %s" % (self.symbol, self.chart_timeframe_text()),
                        self.panel_y + 8)
        self.make_label("notice", NOTICE, self.panel_y + HEAD_H + 2)

        for i in range(TF_COUNT):
            sfx = "_%d" % i
            for base in ROW_OBJECTS:
                self.delete_object(base + sfx)

        self.panel_ok = False
        self.drawn_tf = self.tf

    # ---- what a user would actually read off the screen ---------------
    def visible_texts(self):
        return sorted(v[1] for v in self.objects.values() if v[0] == "label")

    def row_objects_visible(self):
        return [k for k in self.objects
                if any(k.startswith(b + "_") for b in ROW_OBJECTS)]


# ----------------------------------------------------------------------
# Tests
# ----------------------------------------------------------------------
def check(cond, msg):
    if not cond:
        raise AssertionError(msg)


def switch_with_reinit(ea, tf):
    """MetaTrader's normal path: chart timeframe change -> deinit + init."""
    ea.on_deinit()
    ea.tf = tf
    ea.on_init()


def switch_without_reinit(ea, tf):
    """The safety net: the EA is not re-initialised, only ticks/timer run."""
    ea.tf = tf
    ea.on_tick()
    if ea.timer_on:
        ea.on_timer()


def check_full_panel(ea, where):
    check(ea.panel_ok, "%s: panel should be marked as the data panel" % where)
    check("notice" not in ea.objects, "%s: no notice on a supported chart" % where)
    check(len(ea.row_objects_visible()) == 10 * TF_COUNT,
          "%s: every row object should be drawn" % where)
    check("SimpleEA2.0" in ea.visible_texts(), "%s: header missing" % where)

    bg = ea.objects["bg"]
    assert bg[0] == "rect"
    check(bg[2] == HEAD_H + TF_COUNT * 2 * ea.row_h + 8,
          "%s: full panel height wrong" % where)
    # last row line must sit inside the background
    last_y = ea.panel_y + HEAD_H + 2 + (TF_COUNT - 1) * 2 * ea.row_h + ea.row_h
    check(last_y + ea.font + 1 <= ea.panel_y + bg[2],
          "%s: last row falls outside the panel" % where)
    check("sep" in ea.objects, "%s: separator missing" % where)


def check_notice_panel(ea, where):
    check(not ea.panel_ok, "%s: panel must not be marked as the data panel" % where)
    check(ea.row_objects_visible() == [], "%s: row objects left behind" % where)

    labels = ea.visible_texts()
    expected = sorted(["SimpleEA2.0", ea.symbol + "  " + ea.tf.value, NOTICE])
    check(labels == expected, "%s: expected exactly %s, got %s" % (where, expected, labels))
    for forbidden in ("BUY", "SELL", "HOLD", "Trend:", "Regime:",
                      "Signal:", "Score:", "Waiting", "..."):
        check(not any(forbidden in t for t in labels),
              "%s: '%s' must not appear" % (where, forbidden))

    # header line + notice line: no rows, no separator
    bg = ea.objects["bg"]
    check(bg == ("rect", ea.panel_w, ea.notice_h()),
          "%s: panel is not header + notice height" % where)
    check("sep" not in ea.objects, "%s: separator should be gone" % where)
    check(len(ea.objects) == 4, "%s: unexpected object count" % where)

    # every label must sit on one of the two lines, and the whole notice
    # must be inside the background box
    _, text, y = ea.objects["notice"]
    check(text == NOTICE, "%s: notice text changed" % where)
    check(ea.text_width(text) + 10 <= bg[1],
          "%s: notice is wider than the panel (%.0f > %d)"
          % (where, ea.text_width(text) + 10, bg[1]))
    check(y + ea.font + 1 <= ea.panel_y + bg[2],
          "%s: notice falls below the panel" % where)
    check(y >= ea.panel_y + HEAD_H + 1,
          "%s: notice overlaps the header line" % where)
    check(ea.objects["title"][2] + ea.font + 1 <= y,
          "%s: header text overlaps the notice line" % where)


def test_supported_charts():
    for tf in sorted(SUPPORTED, key=lambda t: t.value):
        ea = SimpleEA("XAUUSD", tf)
        ea.on_init()
        check(ea.timer_on, "%s: refresh timer should be running" % tf.value)
        check(ea.engine_calls > 0, "%s: engine should run" % tf.value)
        check_full_panel(ea, tf.value)
    print("  ok  M5 / M15 / M30 draw the full panel")


def test_unsupported_charts():
    for tf in TF:
        if tf in SUPPORTED:
            continue
        ea = SimpleEA("XAUUSD", tf)
        ea.on_init()

        check(ea.engine_calls == 0, "%s: engine must not run" % tf.value)
        check_notice_panel(ea, tf.value)

        #  200 ticks and 200 timer beats on a wrong chart: still nothing read,
        #  still nothing recomputed, still exactly the same objects.
        snapshot = dict(ea.objects)
        for _ in range(200):
            ea.on_tick()
            ea.on_timer()
        check(ea.objects == snapshot, "%s: panel changed on its own" % tf.value)
        check(ea.engine_calls == 0, "%s: engine must stay idle" % tf.value)
    print("  ok  all 18 unsupported timeframes show the header + notice only")


def test_switch_with_reinit():
    for src, dst in [(TF.M5, TF.H1), (TF.H1, TF.M5), (TF.M30, TF.M1),
                     (TF.D1, TF.M15), (TF.M15, TF.MN1), (TF.H4, TF.H2)]:
        ea = SimpleEA("EURUSD", src)
        ea.on_init()
        switch_with_reinit(ea, dst)

        if dst in SUPPORTED:
            check(ea.engine_calls > 0, "%s -> %s: engine should run" % (src.value, dst.value))
            check_full_panel(ea, "%s->%s" % (src.value, dst.value))
        else:
            check_notice_panel(ea, "%s->%s" % (src.value, dst.value))
    print("  ok  timeframe change with re-init (both directions)")


def test_switch_without_reinit():
    for src, dst in [(TF.M5, TF.H1), (TF.H1, TF.M15), (TF.M30, TF.D1),
                     (TF.H1, TF.H4), (TF.M15, TF.W1)]:
        ea = SimpleEA("GBPUSD", src)
        ea.on_init()
        before = ea.engine_calls
        switch_without_reinit(ea, dst)

        if dst in SUPPORTED:
            check(ea.engine_calls > before,
                  "%s -> %s: rows must be recomputed, not reused" % (src.value, dst.value))
            check_full_panel(ea, "%s->%s" % (src.value, dst.value))
        else:
            check(ea.engine_calls == before,
                  "%s -> %s: engine must not run on the wrong chart" % (src.value, dst.value))
            check_notice_panel(ea, "%s->%s" % (src.value, dst.value))
    print("  ok  live timeframe change without re-init (safety net)")


def test_notice_follows_the_chart():
    """H1 -> H4 with no re-init: the header must not keep saying H1."""
    ea = SimpleEA("USDJPY", TF.H1)
    ea.on_init()
    for tf in (TF.H4, TF.H2, TF.D1):
        switch_without_reinit(ea, tf)
        check(ea.visible_texts() == sorted(["SimpleEA2.0", "USDJPY  " + tf.value, NOTICE]),
              "header stale after unsupported -> unsupported: %s" % tf.value)
    switch_without_reinit(ea, TF.M30)
    check_full_panel(ea, "H1->M30")
    print("  ok  notice tracks the chart timeframe it is showing")


def test_font_sizes():
    """The notice must stay inside the panel at every font size offered, and
    CharW() must never under-estimate real rendered text width."""
    for size in (6, 8, 9, 12, 16, 24):
        ea_probe = SimpleEA("XAUUSD", TF.H1, font_size=size)
        check(ea_probe.char_w() >= (size + 1) * EM_REAL,
              "CharW() under-estimates at font size %d" % size)
        for tf in (TF.M5, TF.H1):
            ea = SimpleEA("XAUUSD", tf, font_size=size)
            ea.on_init()
            if tf in SUPPORTED:
                check_full_panel(ea, "%s font %d" % (tf.value, size))
            else:
                check_notice_panel(ea, "%s font %d" % (tf.value, size))
    print("  ok  notice fits at font sizes 6 - 24")


def test_full_cycle():
    """One long walk over every timeframe, re-init on every step."""
    ea = SimpleEA("XAUUSD", TF.M1)
    ea.on_init()
    for tf in TF:
        switch_with_reinit(ea, tf)
        if tf in SUPPORTED:
            check(ea.engine_calls > 0, "%s: engine should run" % tf.value)
            check_full_panel(ea, tf.value)
        else:
            check_notice_panel(ea, tf.value)
    print("  ok  walked all 21 timeframes with a re-init on each")


if __name__ == "__main__":
    print("SimpleEA chart-timeframe rule")
    test_supported_charts()
    test_unsupported_charts()
    test_switch_with_reinit()
    test_switch_without_reinit()
    test_notice_follows_the_chart()
    test_font_sizes()
    test_full_cycle()
    print("\nheader line : SimpleEA2.0")
    print("notice line : %s" % NOTICE)
    print("all chart-timeframe rule checks passed")
