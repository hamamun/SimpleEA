"""Walk the chart-timeframe rule the way a user actually meets it.

Uses the same verified model as research/verify_timeframe_gate.py and prints,
at every step, exactly what would be on the chart:

    python walk_timeframes.py

The readings are fixed illustrations (the stand-in engine returns one reading
per timeframe) - the point of this walk is the LAYOUT and the SWITCHING, not
the numbers.  Every step is re-checked with the same assertions the test suite
uses, so if the panel could show a stale row or a missing notice, this script
would fail rather than print fiction.
"""

from verify_timeframe_gate import (SimpleEA, TF, NOTICE, check_full_panel,
                                   check_notice_panel)

W = 61          # inner width of the drawn box

TREND_TEXT  = {1: "Going up", 0: "Sideways", -1: "Going down"}
SIGNAL_TEXT = {1: "BUY",      0: "HOLD",     -1: "SELL"}


def box(header_right, lines):
    """Draw the panel exactly as the reader sees it."""
    def inner(t):
        return t.ljust(W)[:W]

    out = [" ┌" + "─" * W + "┐"]
    head = "  SimpleEA"
    out.append(" │" + inner(head + header_right.rjust(W - len(head) - 1) + " ") + "│")
    out.append(" ├" + "─" * W + "┤")
    for l in lines:
        out.append(" │" + inner(l) + "│")
    out.append(" └" + "─" * W + "┘")
    return "\n".join("     " + l for l in out)


def render(ea):
    """What is on the chart right now, taken from the model's own objects."""
    right = "%s  %s" % (ea.symbol, ea.tf.value)

    if "notice" in ea.objects:                       # notice panel
        # the notice text is read from the drawn object, not retyped here
        text = ea.objects["notice"][1]
        return box(right, ["  " + text])

    lines = []                                       # full data panel
    for r in ea.rows:
        lines.append("  %-4s %-11s Trend: %-12s Regime: %s"
                     % (r["tag"], STYLE[r["tag"]],
                        TREND_TEXT[r["dir"]] if r["ok"] else "Waiting",
                        r["regime"] if r["ok"] else "..."))
        lines.append("  %-4s %-11s Signal: %-11s Score: %s"
                     % ("", "", SIGNAL_TEXT[r["dir"]] if r["ok"] else "...",
                        ("%+d / 3" % r["score"]) if r["ok"] else "..."))
    return box(right, lines)


STYLE = {"M5": "Scalp", "M15": "Short-term", "M30": "Intraday"}


def step(n, title, ea, note="", journal_from=0):
    print("\n%d) %s" % (n, title))
    if note:
        print("   %s" % note)
    for line in ea.log[journal_from:]:
        print("   journal: %s" % line)
    if len(ea.log) == journal_from:
        print("   journal: (nothing - this chart is supported)")
    print("   engine reads so far: %d" % ea.engine_calls)
    print(render(ea))


def main():
    print("SimpleEA - what the chart shows, step by step")
    print("=" * 72)
    print("\nThe EA is attached once, to a EURUSD chart, and the chart")
    print("timeframe is changed while it stays attached.")

    ea = SimpleEA("EURUSD", TF.H1)
    ea.on_init()
    check_notice_panel(ea, "H1")
    step(1, "Attached on an H1 chart - unsupported",
         ea, "No history read, nothing calculated, no row drawn.",
         journal_from=0)

    # leaving it there: ticks and timer beats change nothing
    for _ in range(100):
        ea.on_tick()
        ea.on_timer()
    assert ea.engine_calls == 0
    print("\n   ... left there for 100 ticks and 100 timer beats:")
    print("       engine reads still %d - the notice is not a live panel,"
          % ea.engine_calls)
    print("       it just sits there.")

    logs = len(ea.log)
    ea.on_deinit(); ea.tf = TF.M15; ea.on_init()
    check_full_panel(ea, "H1 -> M15")
    step(2, "Chart changed to M15 - the regular panel is back",
         ea, "MetaTrader restarts the EA; the panel is recalculated from "
            "current data.", journal_from=logs)

    logs = len(ea.log)
    ea.on_deinit(); ea.tf = TF.M1; ea.on_init()
    check_notice_panel(ea, "M15 -> M1")
    step(3, "Chart changed to M1 - unsupported again", ea,
         "Rows are deleted, not greyed out: nothing stale can be read off.",
         journal_from=logs)

    logs = len(ea.log)
    ea.tf = TF.D1                     # no re-init this time
    ea.on_tick(); ea.on_timer()
    check_notice_panel(ea, "M1 -> D1, no re-init")
    step(4, "Chart changed to D1 without MetaTrader restarting the EA", ea,
         "The safety net catches it: the notice appears anyway.",
         journal_from=logs)

    logs = len(ea.log)
    ea.tf = TF.H4
    ea.on_tick()
    check_notice_panel(ea, "D1 -> H4, no re-init")
    step(5, "Changed again, D1 -> H4, still on a wrong timeframe", ea,
         "The notice keeps up - the header never shows a stale timeframe.",
         journal_from=logs)

    logs = len(ea.log)
    ea.tf = TF.M30
    ea.on_tick()
    check_full_panel(ea, "H4 -> M30, no re-init")
    step(6, "Back to M30 - the regular panel returns", ea,
         "Rebuilt from current data, then it refreshes on each closed bar "
         "as usual.", journal_from=logs)

    print("\n" + "=" * 72)
    print("Summary: the panel is the data panel if and only if the chart is")
    print("M5, M15 or M30.  Any other timeframe: header + notice, no data.")
    print("Every step above was re-checked with the test-suite assertions.")


if __name__ == "__main__":
    main()
