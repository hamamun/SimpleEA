"""Autotrading engine & Second Panel verification.

Transcribes the autotrading and 2nd-panel logic of SimpleAdvisor.mq5 line for
line and verifies every rule:

  Rule 1  InpAutoTrading (default true, full auto hands-free; false = read-only)
  Rule 2  Strictly 1 active trade/order per timeframe (M5, M15, M30) at a time
  Rule 3  Market order at score 3/3; Pending Limit order at score 2/3
          THE SCORE GATE: no order may be placed in a direction the score
          does not support (BUY >= InpBuyScore, SELL <= InpSellScore) -
          in the trend game AND in the range game.  Checked twice: when
          the row publishes a direction, and again in PlacePlanOrder().
  Rule 4  Smart updates on open positions and waiting pending orders
  Rule 5  Three TP levels: TP3 = 100% advised, TP2 = 75% of TP3, TP1 = 75% of TP2
  Rule 6  TP1 -> 70% partial close (if > minLot) + SL to Break-Even + Trailstop
          ACTIVE + Score/Direction watcher (for BOTH minLot and > minLot);
          TP2 -> reduce lot to minLot + lock SL to TP1; TP3 -> full close
  Rule 7  Candle-by-candle updates: open SL tightens only (never widens);
          pre-TP1 HOLD closes if in profit; pending 2/3 -> 3/3 upgrades to
          Market immediately; pending updates Entry/SL/TP on new bar or cancels
          on flip/HOLD/expiry
  Rule 8  Every timeframe trades its own signal directly by default
          (InpRequireM15M30SameTrend=false); with that input true, M15
          and M30 require matching trend direction between them
  Rule 10 2nd Panel header: "Autotrading | Trailstop : Off/On/Active | Stoploss : On/Off | SYMBOL"
          Main Panel header: "SimpleEA | Autotrading : On/Off/Paused | SYMBOL | TF",
          then "Timer: ... | Choppy Trade: On/Off | M15/M30 Same Trend: On/Off" + full-width sep
  Rule 11 2nd Panel placement input InpAutoPanelPos (AUTO_POS_RIGHT default, or
          AUTO_POS_BOTTOM below Main Panel); opens when orders exist and closes
          completely (0 objects) when no trade/order is open
  Rule 12 2nd Panel rows: TF | OPEN/LIMIT | Lot @ | Entry | Ask/Bid | TP1/TP2/TP3
          prices (USD) | SL price (USD) or -- (Ask/Bid) | Status / Waiting
          distance | Distance: live gap to TP1 -> to TP2 (when TP1 hit) -> to TP3
          (when TP2 hit), counted down in points from the current Ask/Bid,
          plus [OPEN]/[PLACED] on Main Panel
  Rule 13 Pre-TP1 stepped trailstop (Entry -> TP1 only): the selected %
          (Tight 40 when the regime is not Steady, Steady 55 in a clear
          Steady trend, picked at fill) both activates the trail and is
          counted back from the activation price to place the first SL;
          every further +5% of progress jumps the SL +5% (gap widened
          x1.25 on M15, x1.50 on M30).  Percentages use the Entry->TP1
          distance frozen at fill.  At TP1 the trail hands off - the
          TP1 Break-Even move only applies if it is tighter than the
          trailed SL.  With InpUseStopLoss=false the trail places the
          first SL itself at activation.  The card shows "TS: 40% Tight"
          / "55% Steady".
  Rule 14 Time cells: an advice plan or a waiting pending order shows
          the idea's leash counting down (Valid: left/total bars - 3 for
          trend rows, 8 for range fades), re-born when the direction
          changes, the game switches, or the leash runs out (0/total is
          the rethink bar and shows for exactly one bar).  A live trade
          switches to Hold: N bars (est ~M) - bars held against the
          Reach estimate.
  Rule 15 PC-local autotrading timer + one-shot pause: outside the
          daily window (or during InpAutoOffHours) no new orders are
          placed and waiting pendings are cancelled, while open
          trades keep being managed.  The pause deadline persists
          across restarts and a completed request does not restart.

  Part 2 (the regime now DECIDES instead of abstaining):
          Steady rows trade the trend game exactly as above; Choppy rows
          place a RANGE FADE - a limit at the opposite band of the box,
          target = half the box (midpoint), stop = band + RANGE_SL_ATR
          ATR, kind "range fade"; Mixed / dead / gated chop rows place
          nothing and the plan block says why.  A closed bar outside
          the trade's box kills it (cancel pending / close open), range
          fades are exempt from the score watcher, and blocked rows show
          their would-be Signal greyed out.

Run:  python3 research/verify_autotrading.py
"""

import math
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from verify_plan_math import SYMBOLS, point_value_per_lot, normalize_lots  # noqa: E402
from walk_trade_plan import (HEAD_H, TF_COUNT, PLAN_SEP_H, PLAN_COL_A,
                             PLAN_COL_B, PLAN_COL_C, PLAN_W_MIN, PLAN_LBL_C,
                             NOTICE, FONT, DPI, RENDER_CW, CELL, char_w, col_x,
                             SL_ATR, TP_ATR, RANGE_SL_ATR, per_tf)  # noqa: E402

AUTO_POS_RIGHT = 0
AUTO_POS_BOTTOM = 1
AUTO_GAP_X = 10
AUTO_GAP_Y = 10
AUTO_W_MIN = 420
AUTO_LINES = 4
AUTO_SEP_H = 10
AUTO_COL_A = 150
AUTO_COL_B = 320
AUTO_COL_C = 480
AUTO_LBL_A = 9
AUTO_LBL_B = 11
AUTO_LBL_C = 5

EM = char_w(FONT, DPI)
TAGS = ("M5", "M15", "M30")
STYLES = {"M5": "Scalp", "M15": "Short-term", "M30": "Intraday"}
TF_SEC = {"M5": 300, "M15": 900, "M30": 1800}


def parse_clock_minutes(value):
    """ParseClockMinutes() in SimpleAdvisor.mq5 (raises on bad input)."""
    txt = value.strip()
    parts = txt.split(":")
    if len(parts) != 2:
        raise ValueError(value)
    if not (1 <= len(parts[0]) <= 2 and 1 <= len(parts[1]) <= 2):
        raise ValueError(value)
    if not all(part.isdigit() for part in parts):
        raise ValueError(value)
    hour, minute = int(parts[0]), int(parts[1])
    if hour < 0 or hour > 23 or minute < 0 or minute > 59:
        raise ValueError(value)
    return hour * 60 + minute


def compute_tp_levels(tp3):
    """ComputeTPLevels() in SimpleAdvisor.mq5.

    MQL5 MathRound rounds halves away from zero (382.5 -> 383), while
    Python's round() rounds halves to even (382.5 -> 382) - floor(x+0.5)
    mirrors the terminal exactly, which the 510-pt M30 default target
    (x.75 = 382.5) actually exercises.
    """
    tp3 = max(1, int(tp3))
    tp2 = max(1, int(math.floor(tp3 * 0.75 + 0.5)))
    tp1 = max(1, int(math.floor(tp2 * 0.75 + 0.5)))
    return tp1, tp2, tp3


def floor_lot_step(lots, spec):
    """FloorLotStep() in SimpleAdvisor.mq5."""
    step = spec["step"] or 0.01
    n = max(0.0, math.floor(lots / step + 1e-8) * step)
    digits = 0
    probe = step
    while probe < 1.0 and digits < 8:
        probe *= 10.0
        digits += 1
    return round(n, digits)


def calc_tp1_close_lot(cur_lot, spec):
    """CalcTP1CloseLot() in SimpleAdvisor.mq5."""
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
    """CalcTP2CloseLot() in SimpleAdvisor.mq5."""
    mn = spec["min_lot"]
    if cur_lot <= mn + 1e-8:
        return 0.0
    close_lot = floor_lot_step(cur_lot - mn, spec)
    if close_lot < mn - 1e-8:
        return 0.0
    return close_lot


class AutoSlot:
    def __init__(self):
        self.reset(keep_signal_bar=False)

    def reset(self, keep_signal_bar=True):
        sig_bar = getattr(self, "last_signal_bar", 0) if keep_signal_bar else 0
        self.active = False
        self.is_open = False
        self.ticket = 0
        self.dir = 0
        self.entry_score = 0
        self.init_lot = 0.0
        self.cur_lot = 0.0
        self.entry_price = 0.0
        self.sl_price = 0.0
        self.tp_price = 0.0
        self.profit_usd = 0.0
        self.sl_pts = 0
        self.tp1_pts = 0
        self.tp2_pts = 0
        self.tp3_pts = 0
        self.tp1_hit = False
        self.tp2_hit = False
        self.trail_active = False
        self.trail_steady = False
        self.trail_started = False
        self.trail_pct = 0
        self.trail_gap_pct = 0.0
        self.trail_ref_tp1_pts = 0
        self.trail_peak_pts = 0.0
        self.trail_applied_pct = 0.0
        self.trail_tried_pct = 0.0
        self.trail_last_try = 0
        self.is_range = False
        self.rng_top = 0.0
        self.rng_bot = 0.0
        self.placed_bar = 0
        self.fill_bar = 0
        self.last_eval_bar = 0
        self.last_signal_bar = sig_bar
        self.head = ""
        self.lbl = {}
        self.val = {}


class AutoTraderSim:
    """Full transcription of SimpleAdvisor.mq5's plan + autotrader + dual panels."""

    #  NOTE: use_stop_loss defaults to True here because most checks below
    #  assert the stop a freshly placed order carries.  The SHIPPED EA
    #  default is false (InpUseStopLoss=false: the pre-TP1 trail places the
    #  first SL); the no-SL behaviour is verified explicitly further down
    #  with use_stop_loss=False.
    def __init__(self, symbol="XAUUSD", spec=None, balance=800.0, auto_trading=True,
                 require_m15_m30_same_trend=False, range_mode=True,
                 use_auto_schedule=False, auto_start_time="08:00",
                 auto_end_time="17:00", auto_off_hours=0,
                 local_minute_of_day=600, gmt_now=1700000000, pause_store=None,
                 use_stop_loss=True, use_trail_stop=True, trail_pct_tight=40,
                 trail_pct_steady=55, auto_panel_pos=AUTO_POS_RIGHT, panel_x=12, panel_y=24,
                 use_risk=True, use_min_lot=False, risk2=0.5, risk3=1.0,
                 sl_atr=None, tp_atr=None, pend_atr=0.5, valid_bars=3):
        self.symbol = symbol
        self.spec = spec or SYMBOLS["XAUUSD-2d"]
        self.balance = balance
        self.cur = "USD"
        self.auto_trading = auto_trading
        self.require_m15_m30_same_trend = require_m15_m30_same_trend
        self.range_mode = range_mode
        self.use_auto_schedule = use_auto_schedule
        self.auto_start_time = auto_start_time
        self.auto_end_time = auto_end_time
        self.auto_off_hours = auto_off_hours
        self.local_minute_of_day = local_minute_of_day
        self.gmt_now = gmt_now
        self.pause_store = {} if pause_store is None else pause_store
        self.sched_start_min = -1
        self.sched_end_min = -1
        if use_auto_schedule:
            self.sched_start_min = parse_clock_minutes(auto_start_time)
            self.sched_end_min = parse_clock_minutes(auto_end_time)
            if self.sched_start_min == self.sched_end_min:
                raise ValueError("schedule start and stop must differ")
        self.pause_until_gmt = 0
        self.init_auto_pause()
        self.timer_was_allowed = self.auto_timer_allows_placement()
        self.timer_state_init = True
        self.use_stop_loss = use_stop_loss
        self.use_trail_stop = use_trail_stop
        self.trail_pct_tight = trail_pct_tight
        self.trail_pct_steady = trail_pct_steady
        self.auto_panel_pos = auto_panel_pos
        self.panel_x = panel_x
        self.panel_y = panel_y
        self.use_risk = use_risk
        self.use_min_lot = use_min_lot
        self.risk2 = risk2
        self.risk3 = risk3
        #  InpBuyScore / InpSellScore: the absolute score gate
        self.buy_score = 2
        self.sell_score = -2
        #  per-timeframe stop/target (SL_ATR_* / TP_ATR_*): None =
        #  the EA's shipped profile - scalp aims near, intraday aims far
        self.sl_atr = per_tf(sl_atr, SL_ATR)
        self.tp_atr = per_tf(tp_atr, TP_ATR)
        self.pend_atr = pend_atr
        self.valid_bars = valid_bars
        self.valid_bars_range = 8

        self.bid = 4285.70
        self.ask = 4285.70
        #  RANGE_SL_ATR: the range game's stop is band + this many ATR
        self.range_sl_atr = RANGE_SL_ATR
        self.atr = {"M5": 0.28, "M15": 0.85, "M30": 1.70}
        self.rows = {t: dict(ok=True, dir=0, score=0, trend="Sideways",
                             regime="Mixed", last_bar=1000, mode=0, reason="",
                             rng_top=0.0, rng_bot=0.0, last_close=0.0)
                     for t in TAGS}
        self.plans = {t: dict(state=0, dir=0, score=0, market=False, lines=1,
                              head=t, kind="", note="", entry_price=0.0, lot=0.0,
                              sl_pts=0, tp_pts=0, tp1_pts=0, tp2_pts=0, tp3_pts=0,
                              lbl={}, val={}) for t in TAGS}
        self.auto = {t: AutoSlot() for t in TAGS}
        self.sig_birth = {t: 0 for t in TAGS}
        self.next_ticket = 100
        self.panel_w = PLAN_W_MIN
        self.panel_h = 130
        self.auto_x = 0
        self.auto_y = 0
        self.auto_w = 0
        self.auto_h = 0
        self.auto_shown = False

    def norm_price(self, p):
        return round(p, self.spec["digits"])

    def set_bar(self, tag, direction, score, trend=None, regime="Steady",
                atr=None, bar_time=None, ok=True, mode=None, reason=None,
                rng_top=0.0, rng_bot=0.0, close=None):
        if trend is None:
            trend = "Going up" if direction > 0 else ("Going down" if direction < 0 else "Sideways")
        if atr is not None:
            self.atr[tag] = atr
        r = self.rows[tag]
        prev_dir, prev_mode = r["dir"], r["mode"]
        #  mode / reason mirror SRow.mode / SRow.blockReason as
        #  EvaluateRow() writes them (the walk carries the same rules):
        #  Mixed and Choppy rows that do not trade always carry their
        #  why; a Steady row stays quiet.  Dead-market depends on ER,
        #  which the sim does not model - pass it explicitly.
        if mode is None:
            mode = 1 if direction != 0 else 0
        if reason is None:
            reason = "" if direction != 0 else (
                "score %+d/3 — under the %+d/%+d gate" % (score, self.buy_score, self.sell_score))
        #  THE SCORE GATE (ScoreAllowsTrade): the score decides WHETHER the
        #  row trades, in every regime.  The regime only decides HOW the
        #  limit is priced (mode == 2 = at the box band).
        if direction != 0 and not self.score_allows(direction, score):
            reason = "score %+d/3 — under the %+d/%+d gate" % (
                score, self.buy_score, self.sell_score)
            mode = 0
            direction = 0
        r["ok"] = ok
        r["dir"] = direction
        r["score"] = score
        r["trend"] = trend
        r["regime"] = regime
        r["mode"] = mode
        r["reason"] = reason
        r["rng_top"] = rng_top
        r["rng_bot"] = rng_bot
        r["last_close"] = self.bid if close is None else close
        if bar_time is not None:
            r["last_bar"] = bar_time

        #  Signal leash birth (EvaluateRow in SimpleAdvisor.mq5): the idea
        #  is re-born when the direction changes, the game switches (trend
        #  <-> range), or the old leash has run out; a row that stands
        #  aside carries no leash at all.
        if direction == 0:
            self.sig_birth[tag] = 0
        else:
            vb = self.valid_bars_range if mode == 2 else self.valid_bars
            if self.sig_birth[tag] > 0 and r["last_bar"] > self.sig_birth[tag]:
                age = (r["last_bar"] - self.sig_birth[tag]) // TF_SEC[tag]
            else:
                age = vb + 1
            if (direction != prev_dir or age > vb
                    or (prev_dir != 0 and (prev_mode == 2) != (mode == 2))):
                self.sig_birth[tag] = r["last_bar"]

    def trend_match_for_tf(self, tag):
        """TrendMatchForTF() in SimpleAdvisor.mq5 (Rule 8)."""
        if tag == "M5" or not self.require_m15_m30_same_trend:
            return self.rows[tag]["ok"] and self.rows[tag]["dir"] != 0
        r15, r30 = self.rows["M15"], self.rows["M30"]
        if not r15["ok"] or not r30["ok"]:
            return False
        if r15["dir"] == 0 or r30["dir"] == 0:
            return False
        return r15["dir"] == r30["dir"]

    def init_auto_pause(self):
        """One-shot pause half of InitAutoTimer() in SimpleAdvisor.mq5."""
        req = self.auto_off_hours
        if req < 0 or req > 8760:
            raise ValueError("InpAutoOffHours out of range")
        if req == 0:
            self.pause_store.clear()
            self.pause_until_gmt = 0
        elif self.pause_store.get("req") == req and self.pause_store.get("until", 0) > 0:
            # Same request on restart/reinit: original deadline stands,
            # whether it is still running or already completed.
            self.pause_until_gmt = self.pause_store["until"]
        else:
            self.pause_until_gmt = self.gmt_now + req * 3600
            self.pause_store["until"] = self.pause_until_gmt
            self.pause_store["req"] = req

    def auto_pause_active(self):
        return self.pause_until_gmt > 0 and self.gmt_now < self.pause_until_gmt

    def in_auto_schedule_window(self):
        if not self.use_auto_schedule:
            return True
        if self.sched_start_min < 0 or self.sched_end_min < 0:
            return False
        now = self.local_minute_of_day
        if self.sched_start_min < self.sched_end_min:
            return self.sched_start_min <= now < self.sched_end_min
        return now >= self.sched_start_min or now < self.sched_end_min

    def auto_timer_allows_placement(self):
        return not self.auto_pause_active() and self.in_auto_schedule_window()

    def can_place_auto_orders(self):
        return self.auto_trading and self.auto_timer_allows_placement()

    def cancel_all_auto_pendings(self):
        cancelled = 0
        if not self.auto_trading:
            return 0
        for t in TAGS:
            a = self.auto[t]
            if a.active and not a.is_open:
                a.last_signal_bar = self.rows[t]["last_bar"]
                a.reset(keep_signal_bar=True)
                cancelled += 1
        return cancelled

    def check_auto_timer_transition(self):
        """CheckAutoTimerTransition() in SimpleAdvisor.mq5."""
        allowed = self.auto_timer_allows_placement()
        if not self.timer_state_init:
            self.timer_was_allowed = allowed
            self.timer_state_init = True
            return
        if allowed == self.timer_was_allowed:
            if not allowed and self.auto_trading:
                self.cancel_all_auto_pendings()
            return
        self.timer_was_allowed = allowed
        if not self.auto_trading:
            return
        if not allowed:
            self.cancel_all_auto_pendings()
        else:
            self.manage_auto_bar()

    def auto_trading_header_text(self):
        if not self.auto_trading:
            return "Off"
        return "On" if self.auto_timer_allows_placement() else "Paused"

    def pause_remaining_minutes(self):
        """PauseRemainingMinutes() in SimpleAdvisor.mq5."""
        if not self.auto_pause_active():
            return 0
        return (self.pause_until_gmt - self.gmt_now + 59) // 60

    def timer_header_text(self):
        """TimerHeaderText() in SimpleAdvisor.mq5."""
        if self.auto_pause_active():
            mins = self.pause_remaining_minutes()
            if mins >= 60:
                return "Paused %dh %02dm" % (mins // 60, mins % 60)
            return "Paused %dm" % mins
        if not self.use_auto_schedule:
            return "Off"
        window = "%02d:%02d-%02d:%02d" % (
            self.sched_start_min // 60, self.sched_start_min % 60,
            self.sched_end_min // 60, self.sched_end_min % 60)
        return ("On " if self.in_auto_schedule_window() else "Paused ") + window

    def header_status_values(self):
        """The three values on Main Panel header line 2."""
        return (self.timer_header_text(),
                "On" if self.range_mode else "Off",
                "On" if self.require_m15_m30_same_trend else "Off")

    def header_status_line(self):
        timer, choppy, same_trend = self.header_status_values()
        return "Timer: %s | Choppy Trade: %s | M15/M30 Same Trend: %s" % (
            timer, choppy, same_trend)

    def score_allows(self, dir_, score):
        """ScoreAllowsTrade() in SimpleAdvisor.mq5 - the absolute gate."""
        if dir_ == 0:
            return False
        if dir_ > 0:
            return score >= self.buy_score
        return score <= self.sell_score

    def is_score_strong(self, tag):
        """IsScoreStrongForTrade() in SimpleAdvisor.mq5."""
        r = self.rows[tag]
        a = self.auto[tag]
        if not r["ok"]:
            return True
        if r["dir"] != a.dir:
            return False
        need = max(2, abs(a.entry_score))
        return abs(r["score"]) >= need

    def clamp_sl_to_stops(self, dir_, cand_sl):
        point = self.spec["point"]
        if cand_sl <= 0.0 or point <= 0.0:
            return 0.0
        min_stop = self.spec["stops_level"] * point
        pad = max(point, min_stop)
        if dir_ > 0:
            cand_sl = min(cand_sl, self.bid - pad)
        else:
            cand_sl = max(cand_sl, self.ask + pad)
        return self.norm_price(cand_sl)

    def is_sl_tighter(self, dir_, cand_sl, cur_sl):
        point = self.spec["point"]
        if cand_sl <= 0.0:
            return False
        if cur_sl <= 0.0:
            return True
        if dir_ > 0:
            return cand_sl > cur_sl + 0.5 * point
        return cand_sl < cur_sl - 0.5 * point

    def trail_room_factor(self, tag):
        """TrailRoomFactor() in SimpleAdvisor.mq5."""
        return {"M5": 1.0, "M15": 1.25, "M30": 1.50}[tag]

    def init_trail(self, tag):
        """InitTrailState() in SimpleAdvisor.mq5 (settings frozen at fill)."""
        a = self.auto[tag]
        r = self.rows[tag]
        if not self.use_trail_stop:
            a.trail_steady = False
            a.trail_pct = 0
            a.trail_gap_pct = 0.0
            a.trail_ref_tp1_pts = 0
            a.trail_started = False
            a.trail_peak_pts = 0.0
            a.trail_applied_pct = 0.0
            a.trail_tried_pct = 0.0
            a.trail_last_try = 0
            return
        steady = (r["ok"] and not a.is_range and r["dir"] == a.dir
                  and r["regime"] == "Steady")
        a.trail_steady = steady
        a.trail_pct = max(10, min(70, int(self.trail_pct_steady if steady
                                          else self.trail_pct_tight)))
        a.trail_gap_pct = a.trail_pct * a.trail_pct / 100.0 * self.trail_room_factor(tag)
        a.trail_ref_tp1_pts = a.tp1_pts
        a.trail_started = False
        a.trail_peak_pts = 0.0
        a.trail_applied_pct = 0.0
        a.trail_tried_pct = 0.0
        a.trail_last_try = 0

    def update_pre_tp1_trail(self, tag, fav_pts):
        """UpdatePreTP1Trail() in SimpleAdvisor.mq5 (sim modifies always succeed)."""
        a = self.auto[tag]
        point = self.spec["point"]
        if not self.use_trail_stop or a.tp1_hit:
            return False
        if a.trail_ref_tp1_pts <= 0 or a.trail_pct <= 0 or a.entry_price <= 0.0:
            return False
        a.trail_peak_pts = max(a.trail_peak_pts, fav_pts)
        peak_pct = a.trail_peak_pts / a.trail_ref_tp1_pts * 100.0
        if peak_pct < a.trail_pct:
            return False
        capped = min(peak_pct, 100.0)
        steps = math.floor((capped - a.trail_pct) / 5.0 + 1e-9)
        level_pct = a.trail_pct + steps * 5.0
        if level_pct <= a.trail_applied_pct + 1e-9:
            return False
        sl_prog_pct = level_pct - a.trail_gap_pct
        cand_sl = self.norm_price(a.entry_price + a.dir * sl_prog_pct / 100.0
                                  * a.trail_ref_tp1_pts * point)
        cand_sl = self.clamp_sl_to_stops(a.dir, cand_sl)
        if cand_sl <= 0.0:
            return False
        if not self.is_sl_tighter(a.dir, cand_sl, a.sl_price):
            a.trail_applied_pct = level_pct
            a.trail_started = True
            a.trail_active = True
            return True
        a.sl_price = cand_sl
        a.sl_pts = int(round(abs(a.entry_price - cand_sl) / point))
        a.trail_applied_pct = level_pct
        a.trail_started = True
        a.trail_active = True
        return True

    def update_plan(self):
        point = self.spec["point"]
        pv = point_value_per_lot(self.spec)
        dg = self.spec["digits"]

        for t in TAGS:
            p = self.plans[t]
            p.update(state=0, dir=0, score=0, market=False, lines=1, head=t,
                     kind="", note="", entry_price=0.0, lot=0.0, sl_pts=0,
                     tp_pts=0, tp1_pts=0, tp2_pts=0, tp3_pts=0, lbl={}, val={})
            r = self.rows[t]
            if not r["ok"]:
                p.update(state=1, kind="waiting", note="history still loading")
                continue
            if r["dir"] == 0:
                p.update(state=0, kind="HOLD",
                         note=r["reason"] or "nothing to place")
                continue

            dir_, score = r["dir"], r["score"]
            #  3/3 -> market, 2/3 -> limit, in EVERY regime.  mode == 2 only
            #  says the box prices this limit.
            market = abs(score) >= 3
            is_range = (r["mode"] == 2) and not market
            a = self.auto[t]
            is_open_now = (a.active and a.is_open and a.dir == dir_ and a.entry_price > 0.0)
            is_pend_now = (a.active and not a.is_open and a.dir == dir_ and a.entry_price > 0.0)
            atr = self.atr[t]
            entry = self.ask if dir_ > 0 else self.bid
            offset = self.pend_atr * atr
            pend = entry - dir_ * offset
            plan_entry = entry if market else pend

            #  trend rows keep the per-timeframe profiles; range rows are
            #  pure box geometry (band entry, stop = band + RANGE_SL_ATR
            #  ATR, target = half the box) - never shrunk by hand
            if is_range:
                plan_entry = r["rng_bot"] if dir_ > 0 else r["rng_top"]
                sl_pts = max(1, int(round(self.range_sl_atr * atr / point)))
                tp_pts = max(1, int(round(0.5 * (r["rng_top"] - r["rng_bot"]) / point)))
            else:
                sl_pts = max(1, int(round(self.sl_atr[t] * atr / point)))
                tp_pts = max(1, int(round(self.tp_atr[t] * atr / point)))
            min_stop = self.spec["stops_level"] * point
            widened = False
            if min_stop > 0 and sl_pts * point < min_stop:
                sl_pts = int(math.ceil(min_stop / point))
                widened = True
            if min_stop > 0 and tp_pts * point < min_stop:
                tp_pts = int(math.ceil(min_stop / point))

            disp_entry = (a.entry_price if is_open_now
                          else (a.entry_price if is_pend_now else plan_entry))
            disp_sl_pts = a.sl_pts if ((is_open_now or is_pend_now) and a.sl_price > 0.0) else sl_pts
            disp_tp_pts = (a.tp3_pts if (is_open_now and a.tp3_pts > 0)
                           else (a.tp3_pts if (is_pend_now and a.tp3_pts > 0) else tp_pts))

            sl_price = disp_entry - dir_ * disp_sl_pts * point
            if (is_open_now or is_pend_now) and a.sl_price > 0.0:
                sl_price = a.sl_price
            tp_price = disp_entry + dir_ * disp_tp_pts * point
            if (is_open_now or is_pend_now) and a.tp_price > 0.0:
                tp_price = a.tp_price

            want_risk, min_lot = 0.0, False
            if self.use_min_lot:
                min_lot = True
                lots = self.spec["min_lot"]
            elif self.use_risk:
                pct = self.risk3 if abs(score) >= 3 else self.risk2
                want_risk = self.balance * pct / 100.0
                lots = want_risk / (sl_pts * pv) if pv > 0 else self.spec["min_lot"]
            else:
                lots = (self.balance / 1000.0) * 0.01
                if abs(score) >= 3:
                    lots *= 1.5
            lot = normalize_lots(lots, self.spec)
            disp_lot = a.cur_lot if ((is_open_now or is_pend_now) and a.cur_lot > 0.0) else lot
            risk_usd = disp_lot * disp_sl_pts * pv
            reward_usd = disp_lot * disp_tp_pts * pv
            risk_over = (not self.use_min_lot and self.use_risk and want_risk > 0
                         and risk_usd > want_risk * 1.05)

            tp1_pts, tp2_pts, tp3_pts = compute_tp_levels(tp_pts)

            lot_txt = "%.2f" % disp_lot
            if min_lot:
                lot_txt += " (min)"
            elif risk_over:
                lot_txt += " (min, %.2f %s)" % (risk_usd, self.cur)

            kind_word = (("buy" if dir_ > 0 else "sell") if is_open_now
                         else ("market" if market else "pending"))

            p.update(state=2, dir=dir_, score=score, market=market, lines=3,
                     kind=("range fade" if is_range
                           else "%s %+d/%d" % (kind_word, score, 3)),
                     entry_price=self.norm_price(plan_entry),
                     lot=lot, sl_pts=sl_pts, tp_pts=tp_pts,
                     tp1_pts=tp1_pts, tp2_pts=tp2_pts, tp3_pts=tp3_pts)
            p["lbl"][(0, 0)] = "Entry:"
            p["val"][(0, 0)] = "%.*f" % (dg, disp_entry)
            p["lbl"][(0, 1)] = "Lot:"
            p["val"][(0, 1)] = lot_txt
            p["lbl"][(1, 0)] = "Stop:"
            p["val"][(1, 0)] = "%.*f %dpts%s" % (dg, sl_price, disp_sl_pts, " (min)" if widened else "")
            p["lbl"][(1, 1)] = "Target:"
            p["val"][(1, 1)] = "%.*f %dpts" % (dg, tp_price, disp_tp_pts)
            #  Reach: rough bar count behind the target - bars ~ (target / ATR)^2
            eta = max(1, int(round((tp_pts * point / atr) ** 2)))
            p["lbl"][(1, 2)] = "Reach:"
            p["val"][(1, 2)] = "~%d bar%s" % (eta, "" if eta == 1 else "s")
            p["lbl"][(2, 0)] = "Risk:"
            p["val"][(2, 0)] = "%.2f %s" % (risk_usd, self.cur)
            p["lbl"][(2, 1)] = "Reward:"
            p["val"][(2, 1)] = "%.2f %s" % (reward_usd, self.cur)
            #  Time cell: the idea's own leash counting down (Valid) or,
            #  once a trade is live, hold time against the Reach estimate
            #  (Hold) - UpdatePlanRow() in SimpleAdvisor.mq5.
            vbars = self.valid_bars_range if is_range else self.valid_bars
            if self.sig_birth[t] > 0 and r["last_bar"] > self.sig_birth[t]:
                age = (r["last_bar"] - self.sig_birth[t]) // TF_SEC[t]
            else:
                age = 0
            if is_open_now:
                fill = a.fill_bar if a.fill_bar > 0 else a.placed_bar
                held = max(0, (r["last_bar"] - fill) // TF_SEC[t]) if fill > 0 else 0
                p["lbl"][(2, 2)] = "Hold:"
                p["val"][(2, 2)] = "%d bar%s (est ~%d)" % (held, "" if held == 1 else "s", eta)
            else:
                left = max(0, min(vbars, vbars - age))
                p["lbl"][(2, 2)] = "Valid:"
                p["val"][(2, 2)] = "%d/%d bars" % (left, vbars)

    def place_plan_order(self, tag):
        if not self.can_place_auto_orders():
            return False
        p = self.plans[tag]
        r = self.rows[tag]
        if p["state"] != 2 or p["dir"] == 0 or not self.trend_match_for_tf(tag):
            return False
        if not self.score_allows(p["dir"], p["score"]):
            return False

        point = self.spec["point"]
        dir_ = p["dir"]
        a = self.auto[tag]
        self.next_ticket += 1

        if p["market"]:
            exec_p = self.norm_price(self.ask if dir_ > 0 else self.bid)
            sl_p = self.norm_price(exec_p - dir_ * p["sl_pts"] * point) if self.use_stop_loss else 0.0
            tp_p = self.norm_price(exec_p + dir_ * p["tp3_pts"] * point)
            a.active = True
            a.is_open = True
            a.ticket = self.next_ticket
            a.dir = dir_
            a.entry_score = p["score"]
            a.init_lot = p["lot"]
            a.cur_lot = p["lot"]
            a.entry_price = exec_p
            a.sl_price = sl_p
            a.tp_price = tp_p
            a.profit_usd = 0.0
            a.sl_pts = p["sl_pts"] if self.use_stop_loss else 0
            a.tp1_pts = p["tp1_pts"]
            a.tp2_pts = p["tp2_pts"]
            a.tp3_pts = p["tp3_pts"]
            a.tp1_hit = False
            a.tp2_hit = False
            a.trail_active = False
            a.is_range = False                # market orders are never range fades
            a.rng_top = 0.0
            a.rng_bot = 0.0
            a.placed_bar = r["last_bar"]
            a.fill_bar = r["last_bar"]
            a.last_eval_bar = r["last_bar"]
            a.last_signal_bar = r["last_bar"]
            self.init_trail(tag)      # market fill: freeze the trailstop % now
            return True
        else:
            pend_p = self.norm_price(p["entry_price"])
            sl_p = self.norm_price(pend_p - dir_ * p["sl_pts"] * point) if self.use_stop_loss else 0.0
            tp_p = self.norm_price(pend_p + dir_ * p["tp3_pts"] * point)
            a.active = True
            a.is_open = False
            a.ticket = self.next_ticket
            a.dir = dir_
            a.entry_score = p["score"]
            a.init_lot = p["lot"]
            a.cur_lot = p["lot"]
            a.entry_price = pend_p
            a.sl_price = sl_p
            a.tp_price = tp_p
            a.profit_usd = 0.0
            a.sl_pts = p["sl_pts"] if self.use_stop_loss else 0
            a.tp1_pts = p["tp1_pts"]
            a.tp2_pts = p["tp2_pts"]
            a.tp3_pts = p["tp3_pts"]
            a.tp1_hit = False
            a.tp2_hit = False
            a.trail_active = False
            #  trailstop initialised at fill (see manage_auto_tick below)
            a.trail_steady = False
            a.trail_started = False
            a.trail_pct = 0
            a.trail_gap_pct = 0.0
            a.trail_ref_tp1_pts = 0
            a.trail_peak_pts = 0.0
            a.trail_applied_pct = 0.0
            a.trail_tried_pct = 0.0
            a.trail_last_try = 0
            #  range fades carry their box: a close outside it kills the trade
            a.is_range = (r["mode"] == 2)
            a.rng_top = r["rng_top"] if r["mode"] == 2 else 0.0
            a.rng_bot = r["rng_bot"] if r["mode"] == 2 else 0.0
            a.placed_bar = r["last_bar"]
            a.last_eval_bar = r["last_bar"]
            a.last_signal_bar = r["last_bar"]
            return True

    def refresh_live_pnl(self):
        point = self.spec["point"]
        pv = point_value_per_lot(self.spec)
        for t in TAGS:
            a = self.auto[t]
            if not a.active:
                continue
            if a.is_open:
                exit_p = self.bid if a.dir > 0 else self.ask
                fav_pts = ((exit_p - a.entry_price) / point if a.dir > 0
                           else (a.entry_price - exit_p) / point)
                a.profit_usd = round(a.cur_lot * fav_pts * pv, 2)
            else:
                a.profit_usd = 0.0

    def manage_auto_bar(self):
        """ManageAutoBar() in SimpleAdvisor.mq5."""
        self.refresh_live_pnl()
        if not self.auto_trading:
            return
        timer_allows_placement = self.auto_timer_allows_placement()
        point = self.spec["point"]

        for t in TAGS:
            a = self.auto[t]
            r = self.rows[t]
            p = self.plans[t]

            # CASE A: Open Market Position
            if a.active and a.is_open:
                exit_p = self.bid if a.dir > 0 else self.ask
                fav_pts = ((exit_p - a.entry_price) / point if a.dir > 0
                           else (a.entry_price - exit_p) / point)

                if r["ok"] and r["dir"] == a.dir and abs(r["score"]) > abs(a.entry_score):
                    a.entry_score = r["score"]

                # 0) RANGE FADE: a closed bar outside the trade's box kills it
                if (a.is_range and r["ok"]
                        and (r["last_close"] > a.rng_top or r["last_close"] < a.rng_bot)):
                    a.last_signal_bar = r["last_bar"]
                    a.reset(keep_signal_bar=True)
                    continue

                # 1) Opposite direction -> close immediately (and reverse into new signal)
                if r["ok"] and r["dir"] != 0 and r["dir"] != a.dir:
                    a.reset(keep_signal_bar=False)
                    if p["state"] == 2 and self.trend_match_for_tf(t):
                        self.place_plan_order(t)
                    continue

                # 2) Post-TP1 score/direction watcher (range fades exempt)
                if a.tp1_hit and not a.is_range and not self.is_score_strong(t):
                    a.last_signal_bar = r["last_bar"]
                    a.reset(keep_signal_bar=True)
                    continue

                # 3) Pre-TP1 drop to HOLD -> close if in profit
                if not a.tp1_hit and r["ok"] and r["dir"] == 0:
                    if a.profit_usd > 0.0 or fav_pts > 0.0:
                        a.last_signal_bar = r["last_bar"]
                        a.reset(keep_signal_bar=True)
                    continue

                # 4) Same-direction closed candle -> update TP1/TP2/TP3 and SL
                if r["ok"] and r["dir"] == a.dir and p["state"] == 2:
                    new_tp1, new_tp2, new_tp3 = compute_tp_levels(p["tp3_pts"])
                    if not a.tp1_hit:
                        a.tp1_pts = new_tp1
                    if not a.tp2_hit:
                        a.tp2_pts = new_tp2
                    a.tp3_pts = new_tp3
                    a.tp_price = self.norm_price(a.entry_price + a.dir * new_tp3 * point)

                    cand_sl = self.norm_price(a.entry_price - a.dir * p["sl_pts"] * point)
                    cand_sl = self.clamp_sl_to_stops(a.dir, cand_sl)
                    if not a.tp1_hit and not a.trail_active:
                        #  README rule 6: the stop only ever TIGHTENS.
                        cand2 = cand_sl if self.use_stop_loss else 0.0
                        if cand2 > 0.0 and self.is_sl_tighter(a.dir, cand2, a.sl_price):
                            a.sl_price = cand2
                            a.sl_pts = int(round(abs(a.entry_price - a.sl_price) / point))
                    elif cand_sl > 0.0 and self.is_sl_tighter(a.dir, cand_sl, a.sl_price):
                        a.sl_price = cand_sl
                        a.sl_pts = int(round(abs(a.entry_price - a.sl_price) / point))
                    a.last_eval_bar = r["last_bar"]
                continue

            # CASE B: Waiting Pending Limit Order
            if a.active and not a.is_open:
                tf_sec = TF_SEC[t]
                leash = self.valid_bars_range if a.is_range else self.valid_bars
                expired = (a.placed_bar > 0 and r["last_bar"] > a.placed_bar
                           and ((r["last_bar"] - a.placed_bar) // tf_sec) >= leash)

                # Timer/pause OFF: cancel the unfilled entry, never refresh it
                if not timer_allows_placement:
                    a.last_signal_bar = r["last_bar"]
                    a.reset(keep_signal_bar=True)
                    continue

                # 0) RANGE FADE: a closed bar outside the trade's box cancels the pending
                if (a.is_range and r["ok"]
                        and (r["last_close"] > a.rng_top or r["last_close"] < a.rng_bot)):
                    a.last_signal_bar = r["last_bar"]
                    a.reset(keep_signal_bar=True)
                    continue

                if (not r["ok"] or r["dir"] != a.dir or not self.trend_match_for_tf(t)
                        or expired or p["state"] != 2):
                    flipped = (r["ok"] and r["dir"] != 0 and r["dir"] != a.dir)
                    a.last_signal_bar = r["last_bar"]
                    a.reset(keep_signal_bar=not flipped)
                    if flipped and p["state"] == 2 and self.trend_match_for_tf(t):
                        self.place_plan_order(t)
                    continue

                # Score upgraded from 2/3 (Pending) to 3/3 (Market) in same direction
                if p["market"]:
                    a.reset(keep_signal_bar=False)
                    self.place_plan_order(t)
                    continue

                # Closed candle in same direction (still Pending 2/3) -> update Entry/SL/TP
                a.entry_price = self.norm_price(p["entry_price"])
                a.sl_pts = p["sl_pts"] if self.use_stop_loss else 0
                a.tp1_pts = p["tp1_pts"]
                a.tp2_pts = p["tp2_pts"]
                a.tp3_pts = p["tp3_pts"]
                a.sl_price = self.norm_price(a.entry_price - a.dir * a.sl_pts * point) if self.use_stop_loss else 0.0
                a.tp_price = self.norm_price(a.entry_price + a.dir * a.tp3_pts * point)
                a.last_eval_bar = r["last_bar"]
                continue

            # CASE C: Flat -> check new order placement
            if not a.active:
                if (timer_allows_placement and r["ok"] and r["dir"] != 0 and p["state"] == 2
                        and self.trend_match_for_tf(t)
                        and a.last_signal_bar != r["last_bar"]):
                    self.place_plan_order(t)

        self.refresh_live_pnl()
        self.update_plan()
        self.update_auto_panel()

    def manage_auto_tick(self, bid, ask):
        """ManageAutoTick() in SimpleAdvisor.mq5."""
        self.bid = bid
        self.ask = ask
        self.refresh_live_pnl()
        point = self.spec["point"]

        if self.auto_trading:
            for t in TAGS:
                a = self.auto[t]
                if not a.active:
                    continue

                # Timer/pause OFF cancels pendings (OnTick transition in MQL)
                if not a.is_open and not self.auto_timer_allows_placement():
                    a.last_signal_bar = self.rows[t]["last_bar"]
                    a.reset(keep_signal_bar=True)
                    continue

                # Simulate broker filling a limit order when price reaches entry_price
                if not a.is_open:
                    if (a.dir > 0 and ask <= a.entry_price) or (a.dir < 0 and bid >= a.entry_price):
                        a.is_open = True
                        a.fill_bar = self.rows[t]["last_bar"]
                        self.init_trail(t)   # pending fill: freeze the trailstop %
                        self.refresh_live_pnl()
                    else:
                        continue

                exit_p = bid if a.dir > 0 else ask
                fav_pts = ((exit_p - a.entry_price) / point if a.dir > 0
                           else (a.entry_price - exit_p) / point)

                # Check SL hit on broker
                if a.sl_price > 0.0:
                    if (a.dir > 0 and bid <= a.sl_price) or (a.dir < 0 and ask >= a.sl_price):
                        a.reset(keep_signal_bar=True)
                        continue

                # TP3 hit -> full close
                if a.tp3_pts > 0 and fav_pts >= a.tp3_pts - 1e-6:
                    a.reset(keep_signal_bar=True)
                    continue

                # Pre-TP1 stepped trailstop (before the TP1 check, as in MQL)
                self.update_pre_tp1_trail(t, fav_pts)

                # TP1 hit -> Break-Even SL only if tighter than the trailed
                # SL + 70% partial close + Score check
                if not a.tp1_hit and a.tp1_pts > 0 and fav_pts >= a.tp1_pts - 1e-6:
                    a.tp1_hit = True
                    a.trail_active = True
                    be_sl = self.clamp_sl_to_stops(a.dir, a.entry_price)
                    if be_sl > 0.0 and self.is_sl_tighter(a.dir, be_sl, a.sl_price):
                        a.sl_price = be_sl
                        a.sl_pts = int(round(abs(a.entry_price - be_sl) / point))

                    close70 = calc_tp1_close_lot(a.cur_lot, self.spec)
                    if close70 > 0.0:
                        a.cur_lot = floor_lot_step(a.cur_lot - close70, self.spec)

                    #  range fades are exempt from the score watcher (Part 2)
                    if not a.is_range and not self.is_score_strong(t):
                        a.reset(keep_signal_bar=True)
                        continue

                # TP2 hit -> reduce lot to minLot + lock SL to TP1 + Score check
                if a.tp1_hit and not a.tp2_hit and a.tp2_pts > 0 and fav_pts >= a.tp2_pts - 1e-6:
                    a.tp2_hit = True
                    a.trail_active = True
                    tp1_p = a.entry_price + a.dir * a.tp1_pts * point
                    lock_sl = self.clamp_sl_to_stops(a.dir, tp1_p)
                    if lock_sl > 0.0 and self.is_sl_tighter(a.dir, lock_sl, a.sl_price):
                        a.sl_price = lock_sl
                        a.sl_pts = int(round(abs(a.entry_price - lock_sl) / point))

                    close_min = calc_tp2_close_lot(a.cur_lot, self.spec)
                    if close_min > 0.0:
                        a.cur_lot = self.spec["min_lot"]

                    #  range fades are exempt from the score watcher (Part 2)
                    if not a.is_range and not self.is_score_strong(t):
                        a.reset(keep_signal_bar=True)
                        continue

        self.refresh_live_pnl()
        self.update_plan()
        self.update_auto_panel()

    def any_auto_active(self):
        return any(self.auto[t].active for t in TAGS)

    def any_trailstop_on(self):
        return any(self.auto[t].active and self.auto[t].trail_active for t in TAGS)

    def trailstop_label(self):
        """Trailstop word on the 2nd Panel header (DrawAutoPanel in SimpleAdvisor.mq5):
        'Off' = InpUseTrailStop is false, 'On' = armed but nothing is trailing yet,
        'Active' = at least one trade is actually trailing."""
        if not self.use_trail_stop:
            return "Off"
        return "Active" if self.any_trailstop_on() else "On"

    def any_stoploss_on(self):
        return any(self.auto[t].active and self.auto[t].sl_price > 0.0 for t in TAGS)

    def update_auto_panel(self):
        """UpdateAutoPanel() in SimpleAdvisor.mq5."""
        point = self.spec["point"]
        pv = point_value_per_lot(self.spec)
        dg = self.spec["digits"]

        for t in TAGS:
            a = self.auto[t]
            a.head = ""
            a.lbl = {}
            a.val = {}
            if not a.active:
                continue

            dir_ = a.dir
            lot = a.cur_lot
            live_p = (self.bid if a.is_open else self.ask) if dir_ > 0 else (self.ask if a.is_open else self.bid)
            live_l = ("Bid:" if a.is_open else "Ask:") if dir_ > 0 else ("Ask:" if a.is_open else "Bid:")
            kind_txt = ("OPEN BUY" if dir_ > 0 else "OPEN SELL") if a.is_open else ("BUY LIMIT" if dir_ > 0 else "SELL LIMIT")

            a.head = "%-3s | %s" % (t, kind_txt)
            a.lbl[(0, 0)] = "Lot @"
            a.val[(0, 0)] = "%.2f" % lot
            a.lbl[(0, 1)] = "Entry:"
            a.val[(0, 1)] = "%.*f" % (dg, a.entry_price)
            a.lbl[(0, 2)] = live_l
            a.val[(0, 2)] = "%.*f" % (dg, live_p)

            tp1_price = self.norm_price(a.entry_price + dir_ * a.tp1_pts * point)
            tp2_price = self.norm_price(a.entry_price + dir_ * a.tp2_pts * point)
            tp3_price = a.tp_price if a.tp_price > 0.0 else self.norm_price(a.entry_price + dir_ * a.tp3_pts * point)

            tp1_usd = lot * a.tp1_pts * pv
            tp2_usd = lot * a.tp2_pts * pv
            tp3_usd = lot * a.tp3_pts * pv

            a.lbl[(1, 0)] = "TP1:"
            a.val[(1, 0)] = "%.*f (%.2f %s)%s" % (dg, tp1_price, tp1_usd, self.cur, " [HIT]" if a.tp1_hit else "")
            a.lbl[(1, 1)] = "TP2:"
            a.val[(1, 1)] = "%.*f (%.2f %s)%s" % (dg, tp2_price, tp2_usd, self.cur, " [HIT]" if a.tp2_hit else "")
            a.lbl[(2, 0)] = "TP3:"
            a.val[(2, 0)] = "%.*f (%.2f %s)" % (dg, tp3_price, tp3_usd, self.cur)

            a.lbl[(2, 1)] = "SL:"
            if a.sl_price > 0.0:
                sl_pts_now = int(round(abs(a.entry_price - a.sl_price) / point))
                sl_usd = lot * sl_pts_now * pv
                is_be = (sl_pts_now == 0 or a.trail_active)
                a.val[(2, 1)] = "%.*f (%.2f %s)%s" % (
                    dg, a.sl_price, sl_usd, self.cur, " [BE]" if (sl_pts_now == 0 and is_be) else "")
            else:
                a.val[(2, 1)] = "-- (%s %.*f)" % (live_l, dg, live_p)

            next_tp_tag = "TP1" if not a.tp1_hit else ("TP2" if not a.tp2_hit else "TP3")
            next_tp_price = tp1_price if not a.tp1_hit else (tp2_price if not a.tp2_hit else tp3_price)

            if a.is_open:
                a.lbl[(3, 0)] = "Status:"
                a.val[(3, 0)] = "P/L %+0.2f %s" % (a.profit_usd, self.cur)
            else:
                wait_pts = int(round(abs(live_p - a.entry_price) / point))
                a.lbl[(3, 0)] = "Waiting:"
                a.val[(3, 0)] = "distance %d pts" % wait_pts

            gap_pts = int(round(abs(next_tp_price - live_p) / point)) if point > 0.0 and live_p > 0.0 else 0
            a.lbl[(3, 1)] = "Distance:"
            a.val[(3, 1)] = "to %s %d pts" % (next_tp_tag, gap_pts)

            a.lbl[(3, 2)] = "TS:"
            if not a.is_open or a.trail_pct <= 0:
                a.val[(3, 2)] = "--" if self.use_trail_stop else "Off"
            else:
                a.val[(3, 2)] = "%d%% %s" % (a.trail_pct,
                                             "Steady" if a.trail_steady else "Tight")

        self.auto_shown = self.any_auto_active()

    def auto_columns(self):
        cA = max(col_x(AUTO_COL_A), 10 + len("M30 | SELL LIMIT") * EM + EM * 2)
        vA = cA + EM * AUTO_LBL_A
        wA = max([len(a.val[(l, 0)]) for a in self.auto.values() if a.active
                  for l in range(AUTO_LINES) if (l, 0) in a.val] or [0])
        cB = max(col_x(AUTO_COL_B), vA + wA * EM + EM * 2)
        vB = cB + EM * AUTO_LBL_B
        wB = max([len(a.val[(l, 1)]) for a in self.auto.values() if a.active
                  for l in range(AUTO_LINES) if (l, 1) in a.val] or [0])
        cC = max(col_x(AUTO_COL_C), vB + wB * EM + EM * 2)
        vC = cC + EM * AUTO_LBL_C
        return cA, vA, cB, vB, cC, vC

    def auto_width_need(self):
        if not self.any_auto_active():
            return 0
        cA, vA, cB, vB, cC, vC = self.auto_columns()
        title_w = 11 * char_w(FONT + 1, DPI)
        head_need = (10 + title_w + EM
                     + (14 + 6 + 1 + 13 + 3 + 2 + len("|  " + self.symbol)) * EM + 10)
        need = max(AUTO_W_MIN, head_need)
        for a in self.auto.values():
            if not a.active:
                continue
            for (l, c), v in a.val.items():
                vx = (vA, vB, vC)[c]
                need = max(need, vx + len(v) * EM + 10)
        return need

    def render_both_panels(self, title):
        """Render Main Panel (left) and 2nd Panel (right or bottom) and assert zero overflow."""
        row_h = FONT + 11
        # ---- Main Panel status tags ([OPEN] / [PLACED]) ----
        main_tags = {}
        for t in TAGS:
            if self.auto[t].active:
                main_tags[t] = "[OPEN]" if self.auto[t].is_open else "[PLACED]"
            else:
                main_tags[t] = ""

        # ---- 2nd Panel geometry ----
        if not self.any_auto_active():
            self.auto_w = 0
            self.auto_h = 0
            print("\n" + "=" * 96)
            print(title)
            print("=" * 96)
            print("  Main Panel tags: %s   |   2nd Panel: CLOSED (0 objects)" % main_tags)
            return []

        active_cnt = sum(1 for t in TAGS if self.auto[t].active)
        self.auto_x = (self.panel_x if self.auto_panel_pos == AUTO_POS_BOTTOM
                       else self.panel_x + self.panel_w + AUTO_GAP_X)
        self.auto_y = (self.panel_y + self.panel_h + AUTO_GAP_Y
                       if self.auto_panel_pos == AUTO_POS_BOTTOM else self.panel_y)
        self.auto_w = self.auto_width_need()
        self.auto_h = (HEAD_H + active_cnt * AUTO_LINES * row_h
                       + (active_cnt - 1) * AUTO_SEP_H + 8)

        w_cols = int((self.auto_w - 4) / CELL)
        grid = [[" "] * w_cols for _ in range(30)]
        last_col = {}
        placed = []
        separators = set()

        def put(text, x_px, line):
            if not text:
                return
            col = max(0, int(round(x_px / CELL)))
            for k, ch in enumerate(text):
                if col + k < w_cols:
                    grid[line][col + k] = ch
            last_col[line] = col + len(text) - 1
            placed.append((line, x_px, x_px + len(text) * RENDER_CW, text))

        title_w = 11 * char_w(FONT + 1, DPI)
        ts_text = self.trailstop_label()
        sl_on = self.any_stoploss_on()
        ts_cap_x = 10 + title_w + EM
        ts_val_x = ts_cap_x + 14 * EM
        sl_cap_x = ts_val_x + 6 * EM + EM
        sl_val_x = sl_cap_x + 13 * EM
        sym_right = "|  " + self.symbol

        put("Autotrading", 10, 0)
        put("| Trailstop :", ts_cap_x, 0)
        put(ts_text, ts_val_x, 0)
        put("| Stoploss :", sl_cap_x, 0)
        put("On" if sl_on else "Off", sl_val_x, 0)
        put(sym_right, self.auto_w - 10 - len(sym_right) * RENDER_CW, 0)
        separators.add(1)
        line = 2
        cA, vA, cB, vB, cC, vC = self.auto_columns()
        shown = 0
        for t in TAGS:
            a = self.auto[t]
            if not a.active:
                continue
            if shown > 0:
                separators.add(line)
                line += 1
            put(a.head, 10, line)
            for l in range(AUTO_LINES):
                for c in range(3):
                    if (l, c) not in a.lbl:
                        continue
                    put(a.lbl[(l, c)], (cA, cB, cC)[c], line + l)
                    put(a.val[(l, c)], (vA, vB, vC)[c], line + l)
            line += AUTO_LINES
            shown += 1

        rows = ["".join(r).rstrip() for r in grid]
        for r in separators:
            rows[r] = "-" * w_cols

        pos_txt = "bottom of Main Panel" if self.auto_panel_pos == AUTO_POS_BOTTOM else "right of Main Panel"
        print("\n" + "=" * 96)
        print(title)
        print("=" * 96)
        print("  Main Panel status badges: M5=%s  M15=%s  M30=%s"
              % (main_tags["M5"] or "none", main_tags["M15"] or "none", main_tags["M30"] or "none"))
        print("  +" + "-" * w_cols + "+")
        for i in range(line):
            print("  | %s |" % rows[i].ljust(w_cols))
        print("  +" + "-" * w_cols + "+")
        print("  2nd Panel (%s at x=%d, y=%d): %d x %d px"
              % (pos_txt, self.auto_x, self.auto_y, self.auto_w, self.auto_h))

        over = [(ln, txt, x_end) for ln, _, x_end, txt in placed if x_end > self.auto_w - 3]
        for ln, txt, x_end in over:
            print("  !! line %d ends at %.0f px in a %d px panel: %r"
                  % (ln, x_end, self.auto_w, txt))
        #  and no two pieces of text may share a pixel on the same line
        by_line = {}
        for ln, x0, x_end, txt in placed:
            by_line.setdefault(ln, []).append((x0, x_end, txt))
        for ln, spans in sorted(by_line.items()):
            spans.sort()
            for (a0, a1, at), (b0, b1, bt) in zip(spans, spans[1:]):
                if b0 < a1 - 0.5:
                    over.append((ln, "%s | %s" % (at, bt), b0 - a1))
                    print("  !! line %d: %r overlaps %r by %.1f px"
                          % (ln, at, bt, a1 - b0))
        return over


def check(cond, msg):
    if not cond:
        raise AssertionError(msg)


def main():
    print("SimpleEA Autotrading & Second Panel verification")

    # ------------------------------------------------------------------
    # 1. Rule 5: TP1, TP2, TP3 levels
    # ------------------------------------------------------------------
    tp1, tp2, tp3 = compute_tp_levels(67)
    check(tp3 == 67 and tp2 == 50 and tp1 == 38,
          "TP levels for 67 pts must be TP3=67, TP2=50 (25%% less), TP1=38 (25%% less of TP2); got %s"
          % ((tp1, tp2, tp3),))
    tp1_b, tp2_b, tp3_b = compute_tp_levels(204)
    check(tp3_b == 204 and tp2_b == 153 and tp1_b == 115,
          "TP levels for 204 pts must be TP3=204, TP2=153, TP1=115; got %s"
          % ((tp1_b, tp2_b, tp3_b),))
    print("  ok  Rule 5: TP3 = 100%, TP2 = 25% less of TP3, TP1 = 25% less of TP2")

    # ------------------------------------------------------------------
    # 2. Rule 1: InpAutoTrading = false (read-only mode)
    # ------------------------------------------------------------------
    sim_off = AutoTraderSim(auto_trading=False)
    sim_off.set_bar("M5", -1, -3, bar_time=1000)
    sim_off.set_bar("M15", 1, 3, bar_time=1000)
    sim_off.set_bar("M30", 1, 3, bar_time=1000)
    sim_off.update_plan()
    sim_off.manage_auto_bar()
    check(not sim_off.any_auto_active() and not sim_off.auto_shown,
          "When InpAutoTrading=false, no orders may be placed and 2nd panel must stay closed")
    print("  ok  Rule 1: InpAutoTrading=false keeps EA read-only and 2nd panel closed")

    # ------------------------------------------------------------------
    # 3. Rule 8: all timeframes independent by default; the optional
    #    InpRequireM15M30SameTrend=true ties M15 and M30 together
    # ------------------------------------------------------------------
    sim = AutoTraderSim(auto_trading=True)
    check(sim.require_m15_m30_same_trend is False,
          "the shipped default must be untied (InpRequireM15M30SameTrend=false)")
    # M5 SELL (-3/3), M15 BUY (+3/3), M30 SELL (-2/3) -> M15/M30 clash,
    # but untied rows place on their own directions anyway.
    sim.set_bar("M5", -1, -3, bar_time=1000)
    sim.set_bar("M15", 1, 3, bar_time=1000)
    sim.set_bar("M30", -1, -2, bar_time=1000)
    sim.update_plan()
    sim.manage_auto_bar()
    check(sim.auto["M5"].active and sim.auto["M5"].is_open,
          "M5 must open its market trade independently")
    check(sim.auto["M15"].active and sim.auto["M15"].is_open
          and sim.auto["M30"].active and not sim.auto["M30"].is_open,
          "untied M15/M30 must place on their own directions even when they disagree")

    # Tied mode: the same clash blocks both M15 and M30 (M5 still places).
    sim_tied = AutoTraderSim(auto_trading=True, require_m15_m30_same_trend=True)
    sim_tied.set_bar("M5", -1, -3, bar_time=1000)
    sim_tied.set_bar("M15", 1, 3, bar_time=1000)
    sim_tied.set_bar("M30", -1, -2, bar_time=1000)
    sim_tied.update_plan()
    sim_tied.manage_auto_bar()
    check(sim_tied.auto["M5"].active and sim_tied.auto["M5"].is_open,
          "M5 must stay independent even when the M15/M30 tie is on")
    check(not sim_tied.auto["M15"].active and not sim_tied.auto["M30"].active,
          "tied M15 and M30 must NOT place orders when their trends disagree")
    sim_tied.set_bar("M30", 1, 2, bar_time=1800)
    sim_tied.update_plan()
    sim_tied.manage_auto_bar()
    check(sim_tied.auto["M15"].active and sim_tied.auto["M15"].is_open
          and sim_tied.auto["M30"].active and not sim_tied.auto["M30"].is_open,
          "tied M15/M30 must place once their trends match (Market M15, Limit M30)")

    # Return the untied sim to the all-aligned state the panel checks use:
    # M30 flips to BUY, so its SELL limit is replaced by a BUY limit.
    sim.set_bar("M30", 1, 2, bar_time=1800)
    sim.update_plan()
    sim.manage_auto_bar()
    check(sim.auto["M5"].active and sim.auto["M15"].active and sim.auto["M30"].active,
          "When all rows qualify, all 3 timeframes have 1 independent order each")
    check(sim.auto["M15"].is_open and not sim.auto["M30"].is_open,
          "Score 3/3 opens Market order (M15); score 2/3 places Pending Limit order (M30)")
    print("  ok  Rule 2, 3 & 8: 1 order per TF, Market at 3/3, Limit at 2/3, M15/M30 untied by default / tied on request")

    over = sim.render_both_panels("State 1: All 3 Timeframes Active (M5 Market SELL, M15 Market BUY, M30 Pending BUY LIMIT)")
    check(not over, "2nd panel overflowed: %s" % (over,))

    # The tie also governs waiting pendings: untied pendings survive an
    # M15/M30 disagreement; tied pendings are cancelled when it appears.
    pend_free = AutoTraderSim(auto_trading=True)
    pend_free.set_bar("M15", 1, 2, bar_time=1000)
    pend_free.set_bar("M30", -1, -2, bar_time=1000)
    pend_free.update_plan()
    pend_free.manage_auto_bar()
    pend_free.set_bar("M15", 1, 2, bar_time=1900)
    pend_free.set_bar("M30", -1, -2, bar_time=2800)
    pend_free.update_plan()
    pend_free.manage_auto_bar()
    check(pend_free.auto["M15"].active and not pend_free.auto["M15"].is_open
          and pend_free.auto["M30"].active and not pend_free.auto["M30"].is_open,
          "untied M15/M30 pendings must survive their directions disagreeing")

    pend_tied = AutoTraderSim(auto_trading=True, require_m15_m30_same_trend=True)
    pend_tied.set_bar("M15", 1, 2, bar_time=1000)
    pend_tied.set_bar("M30", 1, 2, bar_time=1000)
    pend_tied.update_plan()
    pend_tied.manage_auto_bar()
    check(pend_tied.auto["M15"].active and pend_tied.auto["M30"].active,
          "tied M15/M30 pendings must place while their trends match")
    pend_tied.set_bar("M15", 1, 2, bar_time=1900)
    pend_tied.set_bar("M30", 0, 0, bar_time=2800)
    pend_tied.update_plan()
    pend_tied.manage_auto_bar()
    check(not pend_tied.auto["M15"].active,
          "a tied M15 pending must cancel when M30 no longer matches")
    print("  ok  Rule 8 pendings: untied pendings survive disagreement; tied pendings cancel")

    # ------------------------------------------------------------------
    # 3c. Rule 15: PC-local timer + one-shot pause (placement gate only)
    # ------------------------------------------------------------------
    check(parse_clock_minutes("08:00") == 480 and parse_clock_minutes("7:05") == 425,
          "clock parser must accept HH:MM and H:MM")
    for bad in ("24:00", "08:60", "08", "ab:cd", "08:00:00"):
        try:
            parse_clock_minutes(bad)
            raised = False
        except ValueError:
            raised = True
        check(raised, "clock parser must reject %r" % bad)
    try:
        AutoTraderSim(use_auto_schedule=True, auto_start_time="08:00", auto_end_time="08:00")
        raised = False
    except ValueError:
        raised = True
    check(raised, "equal schedule start/stop must be rejected")

    overnight = AutoTraderSim(use_auto_schedule=True, auto_start_time="22:00",
                              auto_end_time="06:00", local_minute_of_day=23 * 60)
    check(overnight.in_auto_schedule_window(), "23:00 must be inside a 22:00-06:00 window")
    overnight.local_minute_of_day = 12 * 60
    check(not overnight.in_auto_schedule_window(), "12:00 must be outside a 22:00-06:00 window")

    sched = AutoTraderSim(auto_trading=True, use_auto_schedule=True,
                          auto_start_time="08:00", auto_end_time="17:00",
                          local_minute_of_day=7 * 60)
    sched.set_bar("M5", -1, -3, bar_time=1000)
    sched.set_bar("M15", 1, 3, bar_time=1000)
    sched.set_bar("M30", 1, 2, bar_time=1000)
    sched.update_plan()
    sched.manage_auto_bar()
    check(not sched.any_auto_active(),
          "before the start time no timeframe may place")
    check(sched.auto_trading_header_text() == "Paused",
          "header must read Paused while the timer is OFF")
    check(sched.timer_header_text() == "Paused 08:00-17:00",
          "status line must show the closed daily window; got %r" % sched.timer_header_text())

    sched.local_minute_of_day = 8 * 60
    check(sched.timer_header_text() == "On 08:00-17:00",
          "status line must show the open daily window; got %r" % sched.timer_header_text())
    sched.check_auto_timer_transition()
    check(sched.auto["M5"].active and sched.auto["M5"].is_open
          and sched.auto["M15"].active and sched.auto["M15"].is_open
          and sched.auto["M30"].active and not sched.auto["M30"].is_open,
          "the ON transition must run a placement pass (Market M5/M15, Limit M30)")

    sched.local_minute_of_day = 17 * 60
    check(sched.timer_header_text() == "Paused 08:00-17:00",
          "the stop minute must already read Paused; got %r" % sched.timer_header_text())
    sched.check_auto_timer_transition()
    check(not sched.auto["M30"].active,
          "the OFF transition must cancel a waiting pending order")
    check(sched.auto["M5"].active and sched.auto["M5"].is_open
          and sched.auto["M15"].active and sched.auto["M15"].is_open,
          "open trades must remain (and stay managed) after the timer turns OFF")
    m5a = sched.auto["M5"]
    tp1_ask = m5a.entry_price - m5a.tp1_pts * sched.spec["point"]  # SELL: exits at ask
    sched.manage_auto_tick(bid=tp1_ask - 0.02, ask=tp1_ask)
    check(sched.auto["M5"].tp1_hit and sched.auto["M5"].active,
          "TP1 management must keep working while the timer is OFF")

    pause_store = {}
    t0 = 1700000000
    pause1 = AutoTraderSim(auto_off_hours=48, gmt_now=t0, pause_store=pause_store)
    check(pause_store.get("until") == t0 + 48 * 3600 and pause_store.get("req") == 48,
          "a fresh 48h request must persist its deadline; got %r" % (pause_store,))
    check(pause1.auto_pause_active() and not pause1.can_place_auto_orders(),
          "the one-shot pause must block placement immediately")
    pause1.gmt_now = t0 + 48 * 60
    check(pause1.timer_header_text() == "Paused 47h 12m",
          "status line must count down the long pause; got %r" % pause1.timer_header_text())
    pause2 = AutoTraderSim(auto_off_hours=48, gmt_now=t0 + 3600, pause_store=pause_store)
    check(pause2.pause_until_gmt == t0 + 48 * 3600,
          "a restart must continue the original deadline, not extend it")
    pause3 = AutoTraderSim(auto_off_hours=48, gmt_now=t0 + 48 * 3600 + 1,
                           pause_store=pause_store)
    check(not pause3.auto_pause_active() and pause3.can_place_auto_orders()
          and pause3.pause_until_gmt == t0 + 48 * 3600,
          "after expiry the effective pause is 0 and the same input must not restart it")
    AutoTraderSim(auto_off_hours=0, gmt_now=t0 + 48 * 3600 + 2, pause_store=pause_store)
    check(pause_store == {}, "setting 0 must clear the stored pause request")
    pause4 = AutoTraderSim(auto_off_hours=48, gmt_now=t0 + 50 * 3600,
                           pause_store=pause_store)
    check(pause4.pause_until_gmt == t0 + 98 * 3600 and pause4.auto_pause_active(),
          "after 0, setting 48 again must start a fresh 48h pause")
    modes = AutoTraderSim(range_mode=False, require_m15_m30_same_trend=True)
    check(modes.header_status_values() == ("Off", "Off", "On"),
          "header line 2 must mirror Timer / Choppy Trade / Same Trend inputs; got %r"
          % (modes.header_status_values(),))
    widest = AutoTraderSim(use_auto_schedule=True, local_minute_of_day=7 * 60,
                           range_mode=False, require_m15_m30_same_trend=False)
    check(len(widest.header_status_line()) == 71,
          "widest header status line must match STATUS_LINE_C=71; got %d (%r)"
          % (len(widest.header_status_line()), widest.header_status_line()))
    print("  ok  Rule 15: daily PC-local timer, OFF cancels pendings/manages opens, one-shot pause persists and auto-expires")
    print("  ok  Header line 2: Timer window/countdown, Choppy Trade and M15/M30 Same Trend modes")

    # ------------------------------------------------------------------
    # 3b. Per-timeframe stop/target profile: the three styles aim apart
    # ------------------------------------------------------------------
    #  Shipped profile (SL_ATR_* / TP_ATR_*): M5 1.0/0.9, M15 1.2/1.8,
    #  M30 1.5/3.0 ATR - on the sim's XAUUSD ATRs 0.28 / 0.85 / 1.70 that is
    #  stop/target 28/25, 102/153, 255/510 points -> R:R 1:0.89 / 1:1.5 / 1:2.
    #  This check is about the STOP the order carries at placement, so it
    #  needs the initial-SL mode explicitly: the shipped default is false
    #  (the pre-TP1 trail places the first SL instead).
    prof = AutoTraderSim(auto_trading=True, use_stop_loss=True)
    prof.set_bar("M5", 1, 3, bar_time=1000)
    prof.set_bar("M15", 1, 3, bar_time=1000)
    prof.set_bar("M30", 1, 3, bar_time=1000)
    prof.update_plan()
    expect = {"M5": (28, 25), "M15": (102, 153), "M30": (255, 510)}
    for t in TAGS:
        sl_e, tp_e = expect[t]
        check(prof.plans[t]["sl_pts"] == sl_e and prof.plans[t]["tp_pts"] == tp_e,
              "%s plan must be stop %d / target %d pts; got %d / %d"
              % (t, sl_e, tp_e, prof.plans[t]["sl_pts"], prof.plans[t]["tp_pts"]))
    check(prof.plans["M5"]["tp_pts"] < prof.plans["M15"]["tp_pts"] < prof.plans["M30"]["tp_pts"],
          "targets must fan out with the timeframe (scalp near, intraday far)")
    rr = {t: prof.plans[t]["tp_pts"] / prof.plans[t]["sl_pts"] for t in TAGS}
    for t, want in (("M5", 0.9), ("M15", 1.5), ("M30", 2.0)):
        check(abs(rr[t] - want) < 0.05,
              "%s R:R must be about 1:%.1f, got 1:%.2f" % (t, want, rr[t]))
    reach = {"M5": "~1 bar", "M15": "~3 bars", "M30": "~9 bars"}
    for t in TAGS:
        check(prof.plans[t]["val"].get((1, 2)) == reach[t],
              "%s Reach cell must be %r; got %r"
              % (t, reach[t], prof.plans[t]["val"].get((1, 2))))
    prof.manage_auto_bar()
    check(prof.auto["M5"].active and prof.auto["M15"].active and prof.auto["M30"].active,
          "all three profiled timeframes must place their orders")
    check(prof.auto["M5"].sl_pts == 28 and prof.auto["M5"].tp3_pts == 25,
          "the placed M5 order must carry the scalp stop 28 / target 25 pts; got %d / %d"
          % (prof.auto["M5"].sl_pts, prof.auto["M5"].tp3_pts))
    check(prof.auto["M30"].sl_pts == 255 and prof.auto["M30"].tp3_pts == 510,
          "the placed M30 order must carry the intraday stop 255 / target 510 pts; got %d / %d"
          % (prof.auto["M30"].sl_pts, prof.auto["M30"].tp3_pts))
    print("  ok  Per-timeframe profile: M5 28/25 (R:R 0.89, Reach ~1 bar), "
          "M15 102/153 (1.5, ~3 bars), M30 255/510 (2.0, ~9 bars)")

    # ------------------------------------------------------------------
    # 4. Rule 6 & 12: Market order TP1/TP2/TP3/SL prices, Distance to
    #    TP1 -> TP2 -> TP3, and Trailstop/Stoploss header status
    # ------------------------------------------------------------------
    # M5 is SELL 0.28 lots @ 4285.70, TP1=14pts (4285.56), TP2=19pts (4285.51), TP3=25pts (4285.45), SL=28pts (4285.98)
    # (the shipped per-timeframe profile: M5 stop = 1.0 ATR, target = 0.9 ATR -> R:R under 1)
    check(abs(sim.auto["M5"].cur_lot - 0.28) < 1e-6, "M5 initial lot should be 0.28")
    check(sim.auto["M5"].val[(1, 0)] == "4285.56 (3.92 USD)",
          "M5 TP1 must show price 4285.56 (3.92 USD); got %r" % sim.auto["M5"].val[(1, 0)])
    check(sim.auto["M5"].val[(1, 1)] == "4285.51 (5.32 USD)",
          "M5 TP2 must show price 4285.51 (5.32 USD); got %r" % sim.auto["M5"].val[(1, 1)])
    check(sim.auto["M5"].val[(2, 0)] == "4285.45 (7.00 USD)",
          "M5 TP3 must show price 4285.45 (7.00 USD); got %r" % sim.auto["M5"].val[(2, 0)])
    check(sim.auto["M5"].val[(2, 1)] == "4285.98 (7.84 USD)",
          "M5 SL must show price 4285.98 (7.84 USD); got %r" % sim.auto["M5"].val[(2, 1)])
    check(sim.auto["M5"].lbl[(3, 1)] == "Distance:" and sim.auto["M5"].val[(3, 1)] == "to TP1 14 pts",
          "Before TP1 hit, M5 Distance must show 'to TP1 14 pts'; got %r" % sim.auto["M5"].val[(3, 1)])
    check(sim.trailstop_label() == "On" and sim.any_stoploss_on(),
          "Before TP1 hit, header must report Trailstop On (armed) and Stoploss On")

    # Tick moves Bid down to TP1 4285.56 -> hits TP1!  The Row was Steady,
    # so the pre-TP1 trail picked 55% at fill; at TP1 its final stepped SL
    # sits at 100 - 30.25 = 69.75% of the 14-pt Entry->TP1 distance
    # (4285.60) - tighter than Break-Even, so the TP1 rule leaves it there.
    check(sim.auto["M5"].trail_pct == 55 and sim.auto["M5"].trail_steady,
          "A Steady row must pick the Steady trail %% (55) at fill; got %d"
          % sim.auto["M5"].trail_pct)
    check(sim.auto["M5"].val[(3, 2)] == "55% Steady",
          "The card must show the picked trail %% ('TS: 55%% Steady'); got %r"
          % sim.auto["M5"].val.get((3, 2)))
    sim.manage_auto_tick(bid=4285.54, ask=4285.56)
    check(sim.auto["M5"].tp1_hit and sim.auto["M5"].trail_active,
          "At TP1 hit, tp1_hit and trail_active must be True")
    check(sim.trailstop_label() == "Active" and sim.any_stoploss_on(),
          "At TP1 hit, header must report Trailstop Active and Stoploss On")
    check(abs(sim.auto["M5"].cur_lot - 0.09) < 1e-6,
          "At TP1 hit on 0.28 lot, 70%% (0.19) closes leaving 0.09 lot; got %.2f" % sim.auto["M5"].cur_lot)
    check(abs(sim.auto["M5"].sl_price - 4285.60) < 1e-6,
          "At TP1 hit, the trailed SL (4285.60) is tighter than Break-Even and must remain; got %.2f"
          % sim.auto["M5"].sl_price)
    check(sim.auto["M5"].val[(2, 1)] == "4285.60 (0.90 USD)",
          "At TP1 hit, SL cell must show the trailed SL '4285.60 (0.90 USD)'; got %r"
          % sim.auto["M5"].val[(2, 1)])
    check(sim.auto["M5"].val[(3, 1)] == "to TP2 5 pts",
          "After TP1 hit, M5 Distance must show the live gap 'to TP2 5 pts'; got %r" % sim.auto["M5"].val[(3, 1)])

    over = sim.render_both_panels("State 2: M5 Hits TP1 (70% Closed -> 0.09 Lot Left, Trailed SL Remains, Trailstop Active)")
    check(not over, "2nd panel overflowed: %s" % (over,))

    # Tick moves Bid down to TP2 4285.51 -> hits TP2!
    sim.manage_auto_tick(bid=4285.49, ask=4285.51)
    check(sim.auto["M5"].tp2_hit, "At TP2 hit, tp2_hit must be True")
    check(abs(sim.auto["M5"].cur_lot - 0.01) < 1e-6,
          "At TP2 hit, lot must reduce to minimum lot (0.01); got %.2f" % sim.auto["M5"].cur_lot)
    check(abs(sim.auto["M5"].sl_price - (4285.70 - 0.14)) < 1e-6,
          "At TP2 hit, SL locks to TP1 price (4285.56); got %.2f" % sim.auto["M5"].sl_price)
    check(sim.auto["M5"].val[(3, 1)] == "to TP3 6 pts",
          "After TP2 hit, M5 Distance must show the live gap 'to TP3 6 pts'; got %r" % sim.auto["M5"].val[(3, 1)])

    # Check Bottom placement option (AUTO_POS_BOTTOM)
    sim.auto_panel_pos = AUTO_POS_BOTTOM
    over_bot = sim.render_both_panels("State 2b: M5 Hits TP2 (Bottom Placement Below Main Panel, Distance -> to TP3 6 pts)")
    check(not over_bot, "2nd panel overflowed in Bottom placement: %s" % (over_bot,))
    check(sim.auto_x == sim.panel_x and sim.auto_y == sim.panel_y + sim.panel_h + AUTO_GAP_Y,
          "AUTO_POS_BOTTOM must place 2nd panel directly below Main Panel")
    sim.auto_panel_pos = AUTO_POS_RIGHT

    # Tick moves Bid down to TP3 4285.45 -> hits TP3!
    sim.manage_auto_tick(bid=4285.43, ask=4285.45)
    check(not sim.auto["M5"].active, "At TP3 hit, M5 order must close completely")
    print("  ok  Rule 6 & 12: TP1/TP2/TP3/SL prices, Distance to TP1->TP2->TP3, Trailstop/Stoploss header & Right/Bottom placement")

    # ------------------------------------------------------------------
    # 5. Rule 6: Score Watcher after TP1 (for both > minLot and minLot)
    # ------------------------------------------------------------------
    # Test A: Lot > minLot (M15 BUY 0.07 lot) hits TP1, then score weakens from +3/3 to +2/3 -> closes!
    sim2 = AutoTraderSim(auto_trading=True)
    sim2.set_bar("M15", 1, 3, bar_time=1000)
    sim2.set_bar("M30", 1, 3, bar_time=1000)
    sim2.update_plan()
    sim2.manage_auto_bar()
    check(sim2.auto["M15"].active and sim2.auto["M15"].cur_lot > 0.01, "M15 opened with lot > minLot")
    tp1_price_m15 = sim2.auto["M15"].entry_price + sim2.auto["M15"].tp1_pts * 0.01
    sim2.manage_auto_tick(bid=tp1_price_m15, ask=tp1_price_m15 + 0.02)
    check(sim2.auto["M15"].tp1_hit and sim2.auto["M15"].active, "M15 hit TP1 and stayed open while score is +3/3")
    # Next candle on M15: score weakens from +3/3 to +2/3
    sim2.set_bar("M15", 1, 2, bar_time=1900)
    sim2.update_plan()
    sim2.manage_auto_bar()
    check(not sim2.auto["M15"].active,
          "After TP1 hit (even when initial lot > minLot), weakening score (+3 -> +2) must close the trade")

    # Test B: Minimum-lot order (0.01 lot) hits TP1, score stays strong (+3/3) -> holds for TP2 & TP3!
    sim_min = AutoTraderSim(auto_trading=True, use_min_lot=True)
    sim_min.set_bar("M5", 1, 3, bar_time=1000)
    sim_min.update_plan()
    sim_min.manage_auto_bar()
    check(abs(sim_min.auto["M5"].cur_lot - 0.01) < 1e-6, "M5 opened at 0.01 minLot")
    # Hit TP1 while score is +3/3 -> stays open!
    p_tp1 = sim_min.auto["M5"].entry_price + sim_min.auto["M5"].tp1_pts * 0.01
    sim_min.manage_auto_tick(bid=p_tp1, ask=p_tp1 + 0.02)
    check(sim_min.auto["M5"].active and sim_min.auto["M5"].tp1_hit,
          "Min-lot trade at TP1 with strong +3/3 score must stay open for TP2")
    # Hit TP2 while score is +3/3 -> stays open for TP3!
    p_tp2 = sim_min.auto["M5"].entry_price + sim_min.auto["M5"].tp2_pts * 0.01
    sim_min.manage_auto_tick(bid=p_tp2, ask=p_tp2 + 0.02)
    check(sim_min.auto["M5"].active and sim_min.auto["M5"].tp2_hit,
          "Min-lot trade at TP2 with strong +3/3 score must stay open for TP3")
    # Now if score weakens to +2/3 before TP3 -> closes immediately!
    sim_min.set_bar("M5", 1, 2, bar_time=1300)
    sim_min.update_plan()
    sim_min.manage_auto_bar()
    check(not sim_min.auto["M5"].active,
          "Min-lot trade must close when score weakens after TP1/TP2")
    print("  ok  Rule 6 (Score Watcher): holds while strong, closes when score weakens (both minLot and > minLot)")

    # ------------------------------------------------------------------
    # 6. Rule 4 & 7: Candle updates for Open Market Trade & Pending Order
    # ------------------------------------------------------------------
    sim3 = AutoTraderSim(auto_trading=True)
    sim3.set_bar("M5", 1, 3, atr=0.28, bar_time=1000)
    sim3.update_plan()
    sim3.manage_auto_bar()
    check(sim3.plans["M5"]["kind"] == "buy +3/3",
          "Left Panel must show 'buy +3/3' (not 'market +3/3') when order is [OPEN]; got %r"
          % sim3.plans["M5"]["kind"])
    orig_sl = sim3.auto["M5"].sl_price
    #  New candle with WIDER ATR (0.40) before TP1: the plan's stop is now
    #  further from entry, but an OPEN trade's risk must never grow -
    #  README rule 6 ("only tightens, never widens") is enforced.
    sim3.set_bar("M5", 1, 3, atr=0.40, bar_time=1300)
    sim3.update_plan()
    check(sim3.plans["M5"]["sl_pts"] > sim3.auto["M5"].sl_pts,
          "setup: the wider ATR must give the plan a wider stop than the open trade carries")
    sim3.manage_auto_bar()
    check(abs(sim3.auto["M5"].sl_price - orig_sl) < 1e-9,
          "Before TP1, a wider ATR must NEVER widen an open trade's SL; got %.2f -> %.2f"
          % (orig_sl, sim3.auto["M5"].sl_price))
    check(sim3.auto["M5"].tp3_pts == sim3.plans["M5"]["tp3_pts"],
          "Open trade TP1/TP2/TP3 must update to the new candle's plan")

    # New candle with SMALLER ATR (0.20) -> SL tightens to new plan!
    sim3.set_bar("M5", 1, 3, atr=0.20, bar_time=1600)
    sim3.update_plan()
    sim3.manage_auto_bar()
    check(sim3.auto["M5"].sl_price > orig_sl,
          "Open trade SL must tighten when new candle advises a closer stop")

    # Pre-TP1 drop to HOLD: when NOT in profit -> stays open; when IN profit -> closes!
    sim3.manage_auto_tick(bid=4285.60, ask=4285.62)   # slightly in loss
    sim3.set_bar("M5", 0, 0, bar_time=1900)
    sim3.update_plan()
    sim3.manage_auto_bar()
    check(sim3.auto["M5"].active,
          "Pre-TP1 drop to HOLD while not in profit must keep trade open")
    sim3.manage_auto_tick(bid=4285.80, ask=4285.82)   # now in profit (+10 pts, before TP1)
    sim3.manage_auto_bar()
    check(not sim3.auto["M5"].active,
          "Pre-TP1 drop to HOLD while in profit must close the trade immediately")

    # Pending order (2/3) updates on new candle, and when filled on tick shows "buy +2/3" [OPEN]!
    sim3.bid = sim3.ask = 4285.70
    sim3.set_bar("M5", 1, 2, atr=0.28, bar_time=2200)
    sim3.update_plan()
    sim3.manage_auto_bar()
    check(sim3.auto["M5"].active and not sim3.auto["M5"].is_open,
          "Score +2/3 must place a Pending Limit order")
    check(sim3.plans["M5"]["kind"] == "pending +2/3",
          "Left Panel must show 'pending +2/3' while [PLACED]; got %r" % sim3.plans["M5"]["kind"])
    old_pend_entry = sim3.auto["M5"].entry_price
    # Next candle still +2/3 but different ATR -> updates pending entry/SL/TP
    sim3.set_bar("M5", 1, 2, atr=0.40, bar_time=2500)
    sim3.update_plan()
    sim3.manage_auto_bar()
    check(sim3.auto["M5"].entry_price != old_pend_entry and not sim3.auto["M5"].is_open,
          "Pending limit order must update Entry/SL/TP on new candle")
    # Next candle upgrades from +2/3 to +3/3 -> deletes pending and opens Market immediately!
    sim3.set_bar("M5", 1, 3, atr=0.40, bar_time=2800)
    sim3.update_plan()
    sim3.manage_auto_bar()
    check(sim3.auto["M5"].active and sim3.auto["M5"].is_open,
          "When pending 2/3 upgrades to 3/3 in same direction, it must convert to an open Market order")
    # Opposite direction signal (-2/3 SELL) -> closes open BUY trade and places SELL limit!
    sim3.set_bar("M5", -1, -2, atr=0.40, bar_time=3100)
    sim3.update_plan()
    sim3.manage_auto_bar()
    check(sim3.auto["M5"].active and sim3.auto["M5"].dir == -1 and not sim3.auto["M5"].is_open,
          "Opposite signal (-2/3 SELL) must close BUY and place SELL LIMIT")
    # Price ticks up to SELL LIMIT entry -> fills and becomes OPEN SELL with "sell -2/3" on Left Panel!
    fill_bid = sim3.auto["M5"].entry_price
    sim3.manage_auto_tick(bid=fill_bid, ask=fill_bid + 0.02)
    check(sim3.auto["M5"].is_open and sim3.plans["M5"]["kind"] == "sell -2/3",
          "When SELL LIMIT fills on tick, Left Panel must show 'sell -2/3' [OPEN] (not 'pending -2/3'); got %r"
          % sim3.plans["M5"]["kind"])
    check(sim3.plans["M5"]["val"][(0, 0)] == "%.2f" % fill_bid,
          "Left Panel Entry must match the open order's entry price")
    # Flip to HOLD (0) while in profit -> closes open SELL and closes 2nd panel completely:
    sim3.manage_auto_tick(bid=fill_bid - 0.20, ask=fill_bid - 0.18)
    sim3.set_bar("M5", 0, 0, bar_time=3400)
    sim3.update_plan()
    sim3.manage_auto_bar()
    check(not sim3.any_auto_active() and not sim3.auto_shown,
          "When all trades/orders close, the 2nd panel must close completely")
    over = sim3.render_both_panels("State 3: Flat (No Open or Pending Orders -> 2nd Panel Closes Completely)")
    check(not over, "Unexpected overflow when flat")

    # ------------------------------------------------------------------
    # 6b. Rule 13: Pre-TP1 stepped trailstop - Tight %, 5% steps, TF room
    # ------------------------------------------------------------------
    # Tight 40% (regime not Steady), no initial SL: at +40% of the 14-pt
    # Entry->TP1 the trail places the first SL itself at +24% (40 counted
    # back 40% towards Entry); each further +5% jumps it +5%.
    tr = AutoTraderSim(auto_trading=True, use_stop_loss=False)
    tr.set_bar("M5", 1, 3, regime="Mixed", atr=0.28, bar_time=1000)
    tr.update_plan()
    tr.manage_auto_bar()
    a_tr = tr.auto["M5"]
    check(a_tr.active and a_tr.is_open and a_tr.sl_price == 0.0,
          "trail test: M5 BUY must open with no SL (InpUseStopLoss=false)")
    check(a_tr.trail_pct == 40 and not a_tr.trail_steady and a_tr.trail_ref_tp1_pts == 14,
          "a non-Steady row must pick Tight 40%% with the 14-pt TP1 reference; got %d%% / %d pts"
          % (a_tr.trail_pct, a_tr.trail_ref_tp1_pts))
    check(abs(a_tr.trail_gap_pct - 16.0) < 1e-9,
          "Tight 40%% on M5 must leave a 16%% gap behind price; got %.2f" % a_tr.trail_gap_pct)
    check(a_tr.val[(3, 2)] == "40% Tight",
          "the card must show 'TS: 40%% Tight'; got %r" % a_tr.val.get((3, 2)))
    check(tr.trailstop_label() == "On",
          "before activation the header must report Trailstop On (armed), not Active")

    # +6 pts = 42.9% of TP1: activation step 40 -> SL at +24% (4285.73)
    tr.manage_auto_tick(bid=4285.76, ask=4285.78)
    check(a_tr.trail_started and a_tr.trail_active and tr.trailstop_label() == "Active",
          "crossing 40%% of Entry->TP1 must activate the trailstop (header: Active)")
    check(abs(a_tr.sl_price - 4285.73) < 1e-6,
          "at activation the trail must place SL at +24%% (4285.73); got %.2f" % a_tr.sl_price)
    check(not a_tr.tp1_hit, "trail activation happens BEFORE TP1 (tp1_hit must stay False)")

    tr.use_trail_stop = False
    check(tr.trailstop_label() == "Off",
          "with InpUseTrailStop=false the header must report Off even while a trade trails")
    tr.use_trail_stop = True

    # +7 pts = 50%: two 5% steps landed -> SL at +34% (4285.75)
    tr.manage_auto_tick(bid=4285.77, ask=4285.79)
    check(abs(a_tr.sl_price - 4285.75) < 1e-6,
          "at +50%% progress the SL must step to +34%% (4285.75); got %.2f" % a_tr.sl_price)

    # Price falls back onto the trailed SL -> trade closes before TP1
    tr.manage_auto_tick(bid=4285.75, ask=4285.77)
    check(not a_tr.active,
          "price falling onto the trailed SL must close the trade before TP1")
    print("  ok  Rule 13 (Tight): activation places SL at +24%, +5% steps, pre-TP1 stop-out, "
          "first SL self-placed when InpUseStopLoss=false")

    # Steady 55% on M15: same activation idea, gap widened x1.25
    tr2 = AutoTraderSim(auto_trading=True)
    tr2.set_bar("M15", 1, 3, regime="Steady", bar_time=1000)
    tr2.set_bar("M30", 1, 2, regime="Steady", bar_time=1000)
    tr2.update_plan()
    tr2.manage_auto_bar()
    a_tr2 = tr2.auto["M15"]
    check(a_tr2.active and a_tr2.is_open, "trail test: M15 BUY must open (market at 3/3)")
    check(a_tr2.trail_pct == 55 and a_tr2.trail_steady and a_tr2.trail_ref_tp1_pts == 86,
          "a Steady M15 row must pick 55%% with the 86-pt TP1 reference; got %d%% / %d pts"
          % (a_tr2.trail_pct, a_tr2.trail_ref_tp1_pts))
    check(abs(a_tr2.trail_gap_pct - 55 * 55 / 100.0 * 1.25) < 1e-9,
          "M15 must widen the gap x1.25 (37.81%%); got %.2f" % a_tr2.trail_gap_pct)
    # +48 pts = 55.8% of TP1: activation step 55 -> SL at 55 - 37.81 = +17.19%
    tr2.manage_auto_tick(bid=a_tr2.entry_price + 0.48, ask=a_tr2.entry_price + 0.50)
    check(a_tr2.trail_started and abs(a_tr2.sl_price - 4285.85) < 1e-6,
          "Steady M15 activation must place SL at +17.19%% (4285.85); got %.2f" % a_tr2.sl_price)
    check(a_tr2.val[(3, 2)] == "55% Steady",
          "the card must show 'TS: 55%% Steady'; got %r" % a_tr2.val.get((3, 2)))
    print("  ok  Rule 13 (Steady): 55% picked in a clear Steady trend, M15 gap widened x1.25")

    # ------------------------------------------------------------------
    # 7. InpUseStopLoss = false: No initial SL placed; the pre-TP1
    #    trailstop places the first SL at activation, and at TP1 the
    #    final trailed SL remains (Break-Even only if tighter)
    # ------------------------------------------------------------------
    sim_nosl = AutoTraderSim(auto_trading=True, use_stop_loss=False)
    sim_nosl.set_bar("M5", 1, 3, atr=0.28, bar_time=1000)
    sim_nosl.update_plan()
    sim_nosl.manage_auto_bar()
    check(sim_nosl.auto["M5"].active and sim_nosl.auto["M5"].is_open, "M5 BUY opened with InpUseStopLoss=false")
    check(sim_nosl.auto["M5"].sl_price == 0.0 and sim_nosl.auto["M5"].sl_pts == 0,
          "When InpUseStopLoss=false, no initial SL may be placed on the order")
    check(sim_nosl.trailstop_label() == "On" and not sim_nosl.any_stoploss_on(),
          "Before TP1 hit with InpUseStopLoss=false, header must show Trailstop : On | Stoploss : Off")
    check(sim_nosl.auto["M5"].val[(2, 1)].startswith("-- ("),
          "Before TP1 hit with InpUseStopLoss=false, SL cell must show '-- (Bid: ...)'; got %r"
          % sim_nosl.auto["M5"].val[(2, 1)])

    # New candle before TP1 hit -> TP updates, SL remains 0.0 (not placed)
    sim_nosl.set_bar("M5", 1, 3, atr=0.35, bar_time=1300)
    sim_nosl.update_plan()
    sim_nosl.manage_auto_bar()
    check(sim_nosl.auto["M5"].sl_price == 0.0,
          "Before TP1 hit with InpUseStopLoss=false, bar close must keep SL off (0.0)")

    # Price reaches TP1 in one tick: the trail lands its final stepped SL
    # first (Steady 55% picked at fill, reference frozen at the fill-time
    # 14-pt TP1 -> SL at +69.75% of 14 pts = 4285.80), and the TP1
    # Break-Even move must NOT pull it back to Entry.
    tp1_bid = sim_nosl.auto["M5"].entry_price + sim_nosl.auto["M5"].tp1_pts * 0.01
    sim_nosl.manage_auto_tick(bid=tp1_bid, ask=tp1_bid + 0.02)
    check(sim_nosl.auto["M5"].tp1_hit and sim_nosl.auto["M5"].trail_active,
          "TP1 hit with InpUseStopLoss=false must activate TP1 and Trailstop")
    check(abs(sim_nosl.auto["M5"].sl_price - 4285.80) < 1e-6,
          "When TP1 hits with InpUseStopLoss=false, the final trailed SL (4285.80) must remain; got %.2f"
          % sim_nosl.auto["M5"].sl_price)
    check(sim_nosl.trailstop_label() == "Active" and sim_nosl.any_stoploss_on(),
          "After TP1 hits with InpUseStopLoss=false, header must show Trailstop : Active | Stoploss : On")
    print("  ok  InpUseStopLoss=false: no SL placed initially; the trail places it and TP1 keeps the trailed SL")

    print("  ok  Rule 4, 7, 10, 11, 12: Candle updates, 2/3->3/3 upgrade, HOLD-in-profit close, and 2nd panel auto-close")

    # ------------------------------------------------------------------
    # 8. The score decides (in every regime); the regime prices the limit
    # ------------------------------------------------------------------
    # 8a. Rows that stand aside say WHY, and never place
    rng = AutoTraderSim(auto_trading=True)
    rng.set_bar("M5", 0, 1, regime="Mixed", bar_time=1000)          # under the gate
    rng.set_bar("M15", 0, -3, regime="Steady", bar_time=1000,       # dead market (ER)
                reason="quiet — nothing worth trading")
    rng.set_bar("M30", 0, 0, regime="Choppy", bar_time=1000)        # under the gate
    rng.update_plan()
    check(rng.plans["M5"]["kind"] == "HOLD" and rng.plans["M5"]["state"] == 0,
          "a +1/3 row is under the +2 gate and must HOLD; got %r" % (rng.plans["M5"],))
    check(rng.plans["M5"]["note"] == "score +1/3 — under the +2/-2 gate",
          "an under-gate row must say which gate refused it; got %r" % rng.plans["M5"]["note"])
    check(rng.plans["M15"]["note"] == "quiet — nothing worth trading",
          "quiet row must say why; got %r" % rng.plans["M15"]["note"])
    check(rng.plans["M30"]["note"] == "score +0/3 — under the +2/-2 gate",
          "a chop row under the gate must say why; got %r" % rng.plans["M30"]["note"])
    rng.manage_auto_bar()
    check(not rng.any_auto_active(),
          "rows under the gate must never place an order")
    print("  ok  8a: rows under the score gate (and a dead market) hold with a reason, place nothing")

    # 8a-2. THE RULE, UNIFORM IN EVERY REGIME: 3 -> market, 2 -> limit.
    #       A Mixed row at +2 places a LIMIT (it used to stand aside), and
    #       a Choppy row at -3 places a MARKET order (the range game used
    #       to be limit-only).
    for regime, score, want_market in (("Mixed", 2, False), ("Steady", 2, False),
                                       ("Mixed", 3, True), ("Choppy", 3, True),
                                       ("Steady", 3, True)):
        u = AutoTraderSim(auto_trading=True)
        u.set_bar("M5", +1, score, regime=regime, bar_time=1000,
                  mode=(2 if regime == "Choppy" else 1),
                  rng_top=4286.60, rng_bot=4284.60)
        u.update_plan()
        p5 = u.plans["M5"]
        check(p5["state"] == 2 and p5["market"] == want_market,
              "%s at %+d/3 must be a %s; got market=%r"
              % (regime, score, "market" if want_market else "limit", p5["market"]))
        u.manage_auto_bar()
        a5 = u.auto["M5"]
        check(a5.active and a5.is_open == want_market,
              "%s at %+d/3 must place a%s %s order; got open=%r"
              % (regime, score, "" if want_market else " waiting",
                 "market" if want_market else "limit", a5.is_open))
    print("  ok  8a-2: 3/3 -> market and 2/3 -> limit in EVERY regime (Mixed included)")

    # 8a-3. The THIRD VOTE is its own measurement, so 2/3 is reachable.
    #       StructureVote() in SimpleAdvisor.mq5: net move over
    #       STRUCT_PERIOD bars, silent unless it beats STRUCT_DEAD_ATR ATR.
    def structure_vote(close, i, period=20, atr=0.28, dead_atr=0.25):
        if period < 1 or i < period:
            return 0
        move = close[i] - close[i - period]
        dead = dead_atr * atr if atr > 0 else 0.0
        if move > dead:
            return 1
        if move < -dead:
            return -1
        return 0

    flat = [4285.70] * 40
    up = [4285.00 + 0.02 * k for k in range(40)]        # +0.38 over 20 bars
    drift = [4285.00 + 0.002 * k for k in range(40)]    # +0.038: inside the dead band
    check(structure_vote(up, 39) == 1, "a +0.38 move over 20 bars must vote +1")
    check(structure_vote(drift, 39) == 0,
          "a move inside STRUCT_DEAD_ATR (0.38 ATR here) must vote 0, not +1")
    check(structure_vote(flat, 39) == 0, "no move must vote 0")

    #  The three votes are independent, so every score from -3..+3 exists:
    #  v1 = trend, v2 = ROC of the trend line, v3 = structure (above).
    for v1, v2, v3, want in ((1, 1, 1, 3), (1, 1, 0, 2), (1, 0, 1, 2),
                             (1, -1, 1, 1), (0, 0, 0, 0), (-1, -1, 0, -2)):
        check(v1 + v2 + v3 == want, "votes %+d/%+d/%+d must score %+d" % (v1, v2, v3, want))
    print("  ok  8a-3: vote 3 is independent (structure), so 2/3 - the LIMIT state - really occurs")

    # 8b. Range fade: limit at the opposite band, box geometry (M5 independent)
    box_top, box_bot = 4286.60, 4284.60      # sell from the top: bid 4285.70 > mid 4285.60
    rng2 = AutoTraderSim(auto_trading=True)
    rng2.set_bar("M5", -1, -2, regime="Choppy", mode=2,
                 rng_top=box_top, rng_bot=box_bot, bar_time=1000)
    rng2.update_plan()
    check(rng2.plans["M5"]["kind"] == "range fade",
          "range plan kind must be 'range fade'; got %r" % rng2.plans["M5"]["kind"])
    check(abs(rng2.plans["M5"]["entry_price"] - box_top) < 1e-9,
          "range entry must be the opposite band (%.2f); got %.2f"
          % (box_top, rng2.plans["M5"]["entry_price"]))
    check(rng2.plans["M5"]["sl_pts"] == 28 and rng2.plans["M5"]["tp_pts"] == 100,
          "range stop must be 1 ATR = 28 pts and target half the box = 100 pts; got %d / %d"
          % (rng2.plans["M5"]["sl_pts"], rng2.plans["M5"]["tp_pts"]))
    rng2.manage_auto_bar()
    a2 = rng2.auto["M5"]
    check(a2.active and not a2.is_open and a2.is_range,
          "M5 must place its own range pending (it is independent of M15/M30)")
    check(abs(a2.entry_price - box_top) < 1e-9 and a2.sl_pts == 28 and a2.tp3_pts == 100,
          "placed range order must carry band entry 4286.60, stop 28 pts, target 100 pts; "
          "got entry %.2f / %d / %d" % (a2.entry_price, a2.sl_pts, a2.tp3_pts))
    check(a2.rng_top == box_top and a2.rng_bot == box_bot,
          "the box must be captured at placement for the box-kill check")
    check(abs(a2.sl_price - (box_top + 0.28)) < 1e-9 and abs(a2.tp_price - 4285.60) < 1e-9,
          "range SL = band + 1 ATR (4286.88), TP = midpoint (4285.60); got %.2f / %.2f"
          % (a2.sl_price, a2.tp_price))
    check(not rng2.auto["M15"].active and not rng2.auto["M30"].active,
          "the other timeframes must stay flat")
    print("  ok  Part 2 range fade: limit at the band, stop = band + 1 ATR, target = box midpoint, M5 independent")

    # 8c. Fill at the band, then a close outside the box KILLS the open trade
    rng2.manage_auto_tick(bid=box_top, ask=box_top + 0.02)
    check(rng2.auto["M5"].is_open, "the range sell limit must fill when bid reaches the band")
    rng2.set_bar("M5", -1, -2, regime="Choppy", mode=2,
                 rng_top=box_top, rng_bot=box_bot, bar_time=1900,
                 close=box_top + 0.30)         # close broke the top of the trade's box
    rng2.update_plan()
    rng2.manage_auto_bar()
    check(not rng2.auto["M5"].active,
          "a close outside the trade's box must kill the open range trade")
    print("  ok  Part 2 box-kill (open): a closed bar outside the box closes the trade")

    # 8d. Re-place on a new valid bar; a close below the box cancels the pending
    rng2.set_bar("M5", -1, -2, regime="Choppy", mode=2,
                 rng_top=box_top, rng_bot=box_bot, bar_time=2500, close=4285.70)
    rng2.update_plan()
    rng2.manage_auto_bar()
    check(rng2.auto["M5"].active and not rng2.auto["M5"].is_open and rng2.auto["M5"].is_range,
          "a fresh bar inside a valid box must re-place the range pending")
    rng2.set_bar("M5", -1, -2, regime="Choppy", mode=2,
                 rng_top=box_top, rng_bot=box_bot, bar_time=3100,
                 close=box_bot - 0.30)          # close broke the bottom
    rng2.update_plan()
    rng2.manage_auto_bar()
    check(not rng2.auto["M5"].active,
          "a close outside the trade's box must cancel the pending range order")
    print("  ok  Part 2 box-kill (pending): a closed bar outside the box cancels the limit order")

    # 8e. Range fades are exempt from the post-TP1 score watcher
    rng3 = AutoTraderSim(auto_trading=True)
    rng3.set_bar("M5", -1, -2, regime="Choppy", mode=2,
                 rng_top=box_top, rng_bot=box_bot, bar_time=1000)
    rng3.update_plan()
    rng3.manage_auto_bar()
    check(rng3.auto["M5"].active and not rng3.auto["M5"].is_open, "range pending placed")
    rng3.manage_auto_tick(bid=box_top, ask=box_top + 0.02)
    check(rng3.auto["M5"].is_open, "range pending filled at the band")
    tp1_p = rng3.auto["M5"].entry_price - rng3.auto["M5"].tp1_pts * 0.01
    rng3.manage_auto_tick(bid=tp1_p - 0.02, ask=tp1_p)   # the sim exits sells at ask
    check(rng3.auto["M5"].tp1_hit and rng3.auto["M5"].active,
          "range fade must reach TP1 and stay open")
    rng3.set_bar("M5", -1, 0, regime="Choppy", mode=2,
                 rng_top=box_top, rng_bot=box_bot, bar_time=1600)   # score now too weak for the watcher
    rng3.update_plan()
    rng3.manage_auto_bar()
    check(rng3.auto["M5"].active,
          "range fades are exempt from the score watcher - box, stop and box-kill govern them")
    print("  ok  Part 2 score watcher: trend rows watch the score, range fades do not")

    # ------------------------------------------------------------------
    # 8f. THE SCORE GATE IS ABSOLUTE (the "it traded at score 0" report)
    #     InpBuyScore / InpSellScore are a gate on the ORDER, not only on
    #     the trend game: no direction the score does not support may be
    #     published by a row, and none may be sent by PlacePlanOrder().
    # ------------------------------------------------------------------
    gate = AutoTraderSim(auto_trading=True)
    gate.set_bar("M5", -1, 0, regime="Choppy", mode=2,
                 rng_top=box_top, rng_bot=box_bot, bar_time=1000)
    gate.update_plan()
    check(gate.rows["M5"]["dir"] == 0,
          "a box SELL on score 0/3 must be refused by the score gate")
    check(gate.plans["M5"]["kind"] == "HOLD",
          "the refused row must show HOLD; got %r" % gate.plans["M5"]["kind"])
    check(gate.plans["M5"]["note"] == "score +0/3 — under the +2/-2 gate",
          "the refused row must say which gate refused it; got %r" % gate.plans["M5"]["note"])
    gate.manage_auto_bar()
    check(not gate.any_auto_active(),
          "NO order may be placed while the score is under the gate")

    # A trend row below its gate is refused the same way.
    gate.set_bar("M15", 1, 1, regime="Steady", bar_time=1000)
    gate.update_plan()
    check(gate.rows["M15"]["dir"] == 0 and gate.plans["M15"]["kind"] == "HOLD",
          "a Steady BUY at +1/3 must be refused (InpBuyScore is +2)")

    # The input is what decides: raise the SELL gate to -3 and -2/3 is refused.
    strict = AutoTraderSim(auto_trading=True)
    strict.sell_score = -3
    strict.set_bar("M5", -1, -2, regime="Choppy", mode=2,
                   rng_top=box_top, rng_bot=box_bot, bar_time=1000)
    strict.update_plan()
    check(strict.rows["M5"]["dir"] == 0 and not strict.auto["M5"].active,
          "InpSellScore=-3 must refuse a -2/3 box sell - the input is obeyed")

    # Second key: even a plan that somehow carries an ungated score cannot
    # leave the terminal (PlacePlanOrder's own gate).
    gate2 = AutoTraderSim(auto_trading=True)
    gate2.set_bar("M5", -1, -2, regime="Choppy", mode=2,
                  rng_top=box_top, rng_bot=box_bot, bar_time=1000)
    gate2.update_plan()
    check(gate2.plans["M5"]["state"] == 2 and gate2.plans["M5"]["dir"] == -1,
          "setup: a -2/3 box sell is a valid plan")
    gate2.plans["M5"]["score"] = 0                 # tamper: bypass the row gate
    check(not gate2.place_plan_order("M5") and not gate2.auto["M5"].active,
          "PlacePlanOrder must refuse an order whose score is under the gate")
    print("  ok  Score gate: InpBuyScore/InpSellScore gate the ORDER in both games "
          "(row + placement), and a refused row says why")

    # ------------------------------------------------------------------
    # 9. Rule 14: the time cells - Valid countdown & Hold (open trade)
    # ------------------------------------------------------------------
    # 9a. Advice-only (no order anywhere): the idea's own leash counts
    #     down in closed bars and re-births exactly where the auto-trader
    #     would expire / re-place a waiting order.
    lt = AutoTraderSim(auto_trading=False)
    for bar, want in ((1000, "3/3 bars"), (1300, "2/3 bars"), (1600, "1/3 bars"),
                      (1900, "0/3 bars"), (2200, "3/3 bars")):
        lt.set_bar("M5", 1, 3, regime="Steady", bar_time=bar)
        lt.update_plan()
        check(lt.plans["M5"]["val"][(2, 2)] == want,
              "advice Valid at bar %d must show %r; got %r"
              % (bar, want, lt.plans["M5"]["val"][(2, 2)]))
    lt.set_bar("M5", -1, -3, regime="Steady", bar_time=2500)
    lt.update_plan()
    check(lt.plans["M5"]["val"][(2, 2)] == "3/3 bars",
          "a direction change must re-birth the leash; got %r"
          % lt.plans["M5"]["val"][(2, 2)])

    # 9b. Open trade: Hold bars held vs the Reach estimate (no leash)
    ht = AutoTraderSim(auto_trading=True)
    ht.set_bar("M5", 1, 3, regime="Steady", atr=0.28, bar_time=1000)
    ht.update_plan()
    ht.manage_auto_bar()
    ht.update_plan()
    check(ht.plans["M5"]["lbl"][(2, 2)] == "Hold:",
          "a live trade must switch the time cell to Hold; got %r"
          % ht.plans["M5"]["lbl"][(2, 2)])
    check(ht.plans["M5"]["val"][(2, 2)] == "0 bars (est ~1)",
          "a just-opened trade must show '0 bars (est ~1)'; got %r"
          % ht.plans["M5"]["val"][(2, 2)])
    ht.set_bar("M5", 1, 3, regime="Steady", atr=0.28, bar_time=1300)
    ht.update_plan()
    check(ht.plans["M5"]["val"][(2, 2)] == "1 bar (est ~1)",
          "held bars must count up per closed bar; got %r"
          % ht.plans["M5"]["val"][(2, 2)])
    print("  ok  Rule 14: Valid counts the idea's leash (0/x rethink bar), "
          "Hold shows bars held vs Reach")

    print("\nall autotrading and 2nd-panel checks passed")


if __name__ == "__main__":
    main()
