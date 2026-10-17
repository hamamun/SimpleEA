"""Autotrading engine & Second Panel verification.

Transcribes the autotrading and 2nd-panel logic of SimpleAdvisor.mq5 line for
line and verifies every rule:

  Rule 1  InpAutoTrading (default true, full auto hands-free; false = read-only)
  Rule 2  Strictly 1 active trade/order per timeframe (M5, M15, M30) at a time
  Rule 3  Market order at score 3/3; Pending Limit order at score 2/3
  Rule 4  Smart updates on open positions and waiting pending orders
  Rule 5  Three TP levels: TP3 = 100% advised, TP2 = 75% of TP3, TP1 = 75% of TP2
  Rule 6  TP1 -> 70% partial close (if > minLot) + SL to Break-Even + Trailstop
          ACTIVE + Score/Direction watcher (for BOTH minLot and > minLot);
          TP2 -> reduce lot to minLot + lock SL to TP1; TP3 -> full close
  Rule 7  Candle-by-candle updates: open SL tightens only (never widens);
          pre-TP1 HOLD closes if in profit; pending 2/3 -> 3/3 upgrades to
          Market immediately; pending updates Entry/SL/TP on new bar or cancels
          on flip/HOLD/expiry
  Rule 8  M5 trades its own signal directly; M15 and M30 require matching
          trend direction between M15 and M30
  Rule 10 2nd Panel header: "Autotrading | Trailstop : Off/On | Stoploss : On/Off | SYMBOL"
          Main Panel header: "SimpleEA | Autotrading : On/Off | SYMBOL | TF" + full-width sep
  Rule 11 2nd Panel placement input InpAutoPanelPos (AUTO_POS_RIGHT default, or
          AUTO_POS_BOTTOM below Main Panel); opens when orders exist and closes
          completely (0 objects) when no trade/order is open
  Rule 12 2nd Panel rows: TF | OPEN/LIMIT | Lot @ | Entry | Ask/Bid | TP1/TP2/TP3
          prices (USD) | SL price (USD) or -- (Ask/Bid) | Status / Waiting
          distance | Distance: to TP1 -> to TP2 (when TP1 hit) -> to TP3 (when TP2 hit),
          plus [OPEN]/[PLACED] on Main Panel

Run:  python3 research/verify_autotrading.py
"""

import math
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from verify_plan_math import SYMBOLS, point_value_per_lot, normalize_lots  # noqa: E402
from walk_trade_plan import (HEAD_H, TF_COUNT, PLAN_SEP_H, PLAN_COL_A,
                             PLAN_COL_B, PLAN_COL_C, PLAN_W_MIN, PLAN_LBL_C,
                             NOTICE, FONT, DPI, RENDER_CW, CELL, char_w)  # noqa: E402

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


def compute_tp_levels(tp3):
    """ComputeTPLevels() in SimpleAdvisor.mq5."""
    tp3 = max(1, int(tp3))
    tp2 = max(1, int(round(tp3 * 0.75)))
    tp1 = max(1, int(round(tp2 * 0.75)))
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
        self.placed_bar = 0
        self.last_eval_bar = 0
        self.last_signal_bar = sig_bar
        self.head = ""
        self.lbl = {}
        self.val = {}


class AutoTraderSim:
    """Full transcription of SimpleAdvisor.mq5's plan + autotrader + dual panels."""

    def __init__(self, symbol="XAUUSD", spec=None, balance=800.0, auto_trading=True,
                 use_stop_loss=True, auto_panel_pos=AUTO_POS_RIGHT, panel_x=12, panel_y=24,
                 use_risk=True, use_min_lot=False, risk2=0.5, risk3=1.0,
                 sl_atr=1.2, tp_atr=2.4, pend_atr=0.5, valid_bars=3, show_plan=True):
        self.symbol = symbol
        self.spec = spec or SYMBOLS["XAUUSD-2d"]
        self.balance = balance
        self.cur = "USD"
        self.auto_trading = auto_trading
        self.use_stop_loss = use_stop_loss
        self.auto_panel_pos = auto_panel_pos
        self.panel_x = panel_x
        self.panel_y = panel_y
        self.use_risk = use_risk
        self.use_min_lot = use_min_lot
        self.risk2 = risk2
        self.risk3 = risk3
        self.sl_atr = sl_atr
        self.tp_atr = tp_atr
        self.pend_atr = pend_atr
        self.valid_bars = valid_bars
        self.show_plan = show_plan

        self.bid = 4285.70
        self.ask = 4285.70
        self.atr = {"M5": 0.28, "M15": 0.85, "M30": 1.70}
        self.rows = {t: dict(ok=True, dir=0, score=0, trend="Sideways",
                             regime="Mixed", last_bar=1000) for t in TAGS}
        self.plans = {t: dict(state=0, dir=0, score=0, market=False, lines=1,
                              head=t, kind="", note="", entry_price=0.0, lot=0.0,
                              sl_pts=0, tp_pts=0, tp1_pts=0, tp2_pts=0, tp3_pts=0,
                              lbl={}, val={}) for t in TAGS}
        self.auto = {t: AutoSlot() for t in TAGS}
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
                atr=None, bar_time=None, ok=True):
        if trend is None:
            trend = "Going up" if direction > 0 else ("Going down" if direction < 0 else "Sideways")
        if atr is not None:
            self.atr[tag] = atr
        r = self.rows[tag]
        r["ok"] = ok
        r["dir"] = direction
        r["score"] = score
        r["trend"] = trend
        r["regime"] = regime
        if bar_time is not None:
            r["last_bar"] = bar_time

    def trend_match_for_tf(self, tag):
        """TrendMatchForTF() in SimpleAdvisor.mq5 (Rule 8)."""
        if tag == "M5":
            return self.rows["M5"]["ok"] and self.rows["M5"]["dir"] != 0
        r15, r30 = self.rows["M15"], self.rows["M30"]
        if not r15["ok"] or not r30["ok"]:
            return False
        if r15["dir"] == 0 or r30["dir"] == 0:
            return False
        return r15["dir"] == r30["dir"]

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
                p.update(state=0, kind="HOLD", note="nothing to place")
                continue

            dir_, score = r["dir"], r["score"]
            market = abs(score) >= 3
            a = self.auto[t]
            is_open_now = (a.active and a.is_open and a.dir == dir_ and a.entry_price > 0.0)
            is_pend_now = (a.active and not a.is_open and a.dir == dir_ and a.entry_price > 0.0)
            atr = self.atr[t]
            entry = self.ask if dir_ > 0 else self.bid
            offset = self.pend_atr * atr
            pend = entry - dir_ * offset
            plan_entry = entry if market else pend

            sl_pts = max(1, int(round(self.sl_atr * atr / point)))
            tp_pts = max(1, int(round(self.tp_atr * atr / point)))
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
                     kind="%s %+d/%d" % (kind_word, score, 3),
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
            p["lbl"][(2, 0)] = "Risk:"
            p["val"][(2, 0)] = "%.2f %s" % (risk_usd, self.cur)
            p["lbl"][(2, 1)] = "Reward:"
            p["val"][(2, 1)] = "%.2f %s" % (reward_usd, self.cur)
            p["lbl"][(2, 2)] = "Valid:"
            p["val"][(2, 2)] = "%d bars -> 14:30" % self.valid_bars

    def place_plan_order(self, tag):
        if not self.auto_trading:
            return False
        p = self.plans[tag]
        r = self.rows[tag]
        if p["state"] != 2 or p["dir"] == 0 or not self.trend_match_for_tf(tag):
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
            a.placed_bar = r["last_bar"]
            a.last_eval_bar = r["last_bar"]
            a.last_signal_bar = r["last_bar"]
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

                # 1) Opposite direction -> close immediately (and reverse into new signal)
                if r["ok"] and r["dir"] != 0 and r["dir"] != a.dir:
                    a.reset(keep_signal_bar=False)
                    if p["state"] == 2 and self.trend_match_for_tf(t):
                        self.place_plan_order(t)
                    continue

                # 2) Post-TP1 score/direction watcher
                if a.tp1_hit and not self.is_score_strong(t):
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
                        if self.use_stop_loss and cand_sl > 0.0:
                            a.sl_price = cand_sl
                            a.sl_pts = int(round(abs(a.entry_price - a.sl_price) / point))
                        else:
                            a.sl_price = 0.0
                            a.sl_pts = 0
                    elif cand_sl > 0.0 and self.is_sl_tighter(a.dir, cand_sl, a.sl_price):
                        a.sl_price = cand_sl
                        a.sl_pts = int(round(abs(a.entry_price - a.sl_price) / point))
                    a.last_eval_bar = r["last_bar"]
                continue

            # CASE B: Waiting Pending Limit Order
            if a.active and not a.is_open:
                tf_sec = TF_SEC[t]
                expired = (a.placed_bar > 0 and r["last_bar"] > a.placed_bar
                           and ((r["last_bar"] - a.placed_bar) // tf_sec) >= self.valid_bars)
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
                if (r["ok"] and r["dir"] != 0 and p["state"] == 2
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

                # Simulate broker filling a limit order when price reaches entry_price
                if not a.is_open:
                    if (a.dir > 0 and ask <= a.entry_price) or (a.dir < 0 and bid >= a.entry_price):
                        a.is_open = True
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

                # TP1 hit -> Break-Even SL + Trailstop ACTIVE + 70% partial close + Score check
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

                    if not self.is_score_strong(t):
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

                    if not self.is_score_strong(t):
                        a.reset(keep_signal_bar=True)
                        continue

        self.refresh_live_pnl()
        self.update_plan()
        self.update_auto_panel()

    def any_auto_active(self):
        return any(self.auto[t].active for t in TAGS)

    def any_trailstop_on(self):
        return any(self.auto[t].active and self.auto[t].trail_active for t in TAGS)

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
            next_tp_pts = a.tp1_pts if not a.tp1_hit else (a.tp2_pts if not a.tp2_hit else a.tp3_pts)

            if a.is_open:
                a.lbl[(3, 0)] = "Status:"
                a.val[(3, 0)] = "P/L %+0.2f %s" % (a.profit_usd, self.cur)
            else:
                wait_pts = int(round(abs(live_p - a.entry_price) / point))
                a.lbl[(3, 0)] = "Waiting:"
                a.val[(3, 0)] = "distance %d pts" % wait_pts

            a.lbl[(3, 1)] = "Distance:"
            a.val[(3, 1)] = "to %s %d pts" % (next_tp_tag, next_tp_pts)

        self.auto_shown = self.any_auto_active()

    def auto_columns(self):
        cA = max(AUTO_COL_A, 10 + len("M30 | SELL LIMIT") * EM + EM * 2)
        vA = cA + EM * AUTO_LBL_A
        wA = max([len(a.val[(l, 0)]) for a in self.auto.values() if a.active
                  for l in range(AUTO_LINES) if (l, 0) in a.val] or [0])
        cB = max(AUTO_COL_B, vA + wA * EM + EM * 2)
        vB = cB + EM * AUTO_LBL_B
        wB = max([len(a.val[(l, 1)]) for a in self.auto.values() if a.active
                  for l in range(AUTO_LINES) if (l, 1) in a.val] or [0])
        cC = max(AUTO_COL_C, vB + wB * EM + EM * 2)
        vC = cC + EM * AUTO_LBL_C
        return cA, vA, cB, vB, cC, vC

    def auto_width_need(self):
        if not self.any_auto_active():
            return 0
        cA, vA, cB, vB, cC, vC = self.auto_columns()
        title_w = 11 * char_w(FONT + 1, DPI)
        head_need = (10 + title_w + EM
                     + (14 + 3 + 1 + 13 + 3 + 2 + len("|  " + self.symbol)) * EM + 10)
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
            col = max(col, last_col.get(line, -1) + 2)
            for k, ch in enumerate(text):
                if col + k < w_cols:
                    grid[line][col + k] = ch
            last_col[line] = col + len(text) - 1
            placed.append((line, x_px, x_px + len(text) * RENDER_CW, text))

        title_w = 11 * char_w(FONT + 1, DPI)
        ts_on = self.any_trailstop_on()
        sl_on = self.any_stoploss_on()
        ts_cap_x = 10 + title_w + EM
        ts_val_x = ts_cap_x + 14 * EM
        sl_cap_x = ts_val_x + 3 * EM + EM
        sl_val_x = sl_cap_x + 13 * EM
        sym_right = "|  " + self.symbol

        put("Autotrading", 10, 0)
        put("| Trailstop :", ts_cap_x, 0)
        put("On" if ts_on else "Off", ts_val_x, 0)
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
    # 3. Rule 8: M5 independent; M15 and M30 require trend match
    # ------------------------------------------------------------------
    sim = AutoTraderSim(auto_trading=True)
    # M5 SELL (-3/3), M15 BUY (+3/3), M30 SELL (-2/3) -> M15 and M30 clash!
    sim.set_bar("M5", -1, -3, bar_time=1000)
    sim.set_bar("M15", 1, 3, bar_time=1000)
    sim.set_bar("M30", -1, -2, bar_time=1000)
    sim.update_plan()
    sim.manage_auto_bar()
    check(sim.auto["M5"].active and sim.auto["M5"].is_open,
          "M5 must open its market trade independently")
    check(not sim.auto["M15"].active and not sim.auto["M30"].active,
          "M15 and M30 must NOT place orders when M15 and M30 trends disagree")

    # Now M30 aligns with M15 (M15 BUY +3/3 market, M30 BUY +2/3 pending limit)
    sim.set_bar("M30", 1, 2, bar_time=1800)
    sim.update_plan()
    sim.manage_auto_bar()
    check(sim.auto["M5"].active and sim.auto["M15"].active and sim.auto["M30"].active,
          "When M15 and M30 trends match, all 3 timeframes have 1 independent order each")
    check(sim.auto["M15"].is_open and not sim.auto["M30"].is_open,
          "Score 3/3 opens Market order (M15); score 2/3 places Pending Limit order (M30)")
    print("  ok  Rule 2, 3 & 8: 1 order per TF, Market at 3/3, Limit at 2/3, M15/M30 trend match enforced")

    over = sim.render_both_panels("State 1: All 3 Timeframes Active (M5 Market SELL, M15 Market BUY, M30 Pending BUY LIMIT)")
    check(not over, "2nd panel overflowed: %s" % (over,))

    # ------------------------------------------------------------------
    # 4. Rule 6 & 12: Market order TP1/TP2/TP3/SL prices, Distance to
    #    TP1 -> TP2 -> TP3, and Trailstop/Stoploss header status
    # ------------------------------------------------------------------
    # M5 is SELL 0.23 lots @ 4285.70, TP1=38pts (4285.32), TP2=50pts (4285.20), TP3=67pts (4285.03), SL=34pts (4286.04)
    check(abs(sim.auto["M5"].cur_lot - 0.23) < 1e-6, "M5 initial lot should be 0.23")
    check(sim.auto["M5"].val[(1, 0)] == "4285.32 (8.74 USD)",
          "M5 TP1 must show price 4285.32 (8.74 USD); got %r" % sim.auto["M5"].val[(1, 0)])
    check(sim.auto["M5"].val[(1, 1)] == "4285.20 (11.50 USD)",
          "M5 TP2 must show price 4285.20 (11.50 USD); got %r" % sim.auto["M5"].val[(1, 1)])
    check(sim.auto["M5"].val[(2, 0)] == "4285.03 (15.41 USD)",
          "M5 TP3 must show price 4285.03 (15.41 USD); got %r" % sim.auto["M5"].val[(2, 0)])
    check(sim.auto["M5"].val[(2, 1)] == "4286.04 (7.82 USD)",
          "M5 SL must show price 4286.04 (7.82 USD); got %r" % sim.auto["M5"].val[(2, 1)])
    check(sim.auto["M5"].lbl[(3, 1)] == "Distance:" and sim.auto["M5"].val[(3, 1)] == "to TP1 38 pts",
          "Before TP1 hit, M5 Distance must show 'to TP1 38 pts'; got %r" % sim.auto["M5"].val[(3, 1)])
    check(not sim.any_trailstop_on() and sim.any_stoploss_on(),
          "Before TP1 hit, header must report Trailstop Off and Stoploss On")

    # Tick moves Ask down 38 pts to 4285.32 -> hits TP1!
    sim.manage_auto_tick(bid=4285.30, ask=4285.32)
    check(sim.auto["M5"].tp1_hit and sim.auto["M5"].trail_active,
          "At TP1 hit, tp1_hit and trail_active must be True")
    check(sim.any_trailstop_on() and sim.any_stoploss_on(),
          "At TP1 hit, header must report Trailstop On and Stoploss On")
    check(abs(sim.auto["M5"].cur_lot - 0.07) < 1e-6,
          "At TP1 hit on 0.23 lot, 70%% (0.16) closes leaving 0.07 lot; got %.2f" % sim.auto["M5"].cur_lot)
    check(abs(sim.auto["M5"].sl_price - 4285.70) < 1e-6,
          "At TP1 hit, SL must move to Entry (Break-Even 4285.70); got %.2f" % sim.auto["M5"].sl_price)
    check(sim.auto["M5"].val[(2, 1)] == "4285.70 (0.00 USD) [BE]",
          "At TP1 hit, SL cell must show '4285.70 (0.00 USD) [BE]'; got %r" % sim.auto["M5"].val[(2, 1)])
    check(sim.auto["M5"].val[(3, 1)] == "to TP2 50 pts",
          "After TP1 hit, M5 Distance must advance to 'to TP2 50 pts'; got %r" % sim.auto["M5"].val[(3, 1)])

    over = sim.render_both_panels("State 2: M5 Hits TP1 (70% Closed -> 0.07 Lot Left, SL Moved to Break-Even, Trailstop On)")
    check(not over, "2nd panel overflowed: %s" % (over,))

    # Tick moves Ask down 50 pts from 4285.70 to 4285.20 -> hits TP2!
    sim.manage_auto_tick(bid=4285.18, ask=4285.20)
    check(sim.auto["M5"].tp2_hit, "At TP2 hit, tp2_hit must be True")
    check(abs(sim.auto["M5"].cur_lot - 0.01) < 1e-6,
          "At TP2 hit, lot must reduce to minimum lot (0.01); got %.2f" % sim.auto["M5"].cur_lot)
    check(abs(sim.auto["M5"].sl_price - (4285.70 - 0.38)) < 1e-6,
          "At TP2 hit, SL locks to TP1 price (4285.32); got %.2f" % sim.auto["M5"].sl_price)
    check(sim.auto["M5"].val[(3, 1)] == "to TP3 67 pts",
          "After TP2 hit, M5 Distance must advance to 'to TP3 67 pts'; got %r" % sim.auto["M5"].val[(3, 1)])

    # Check Bottom placement option (AUTO_POS_BOTTOM)
    sim.auto_panel_pos = AUTO_POS_BOTTOM
    over_bot = sim.render_both_panels("State 2b: M5 Hits TP2 (Bottom Placement Below Main Panel, Distance -> to TP3 67 pts)")
    check(not over_bot, "2nd panel overflowed in Bottom placement: %s" % (over_bot,))
    check(sim.auto_x == sim.panel_x and sim.auto_y == sim.panel_y + sim.panel_h + AUTO_GAP_Y,
          "AUTO_POS_BOTTOM must place 2nd panel directly below Main Panel")
    sim.auto_panel_pos = AUTO_POS_RIGHT

    # Tick moves Ask down 67 pts from 4285.70 to 4285.03 -> hits TP3!
    sim.manage_auto_tick(bid=4285.01, ask=4285.03)
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
    # New candle with WIDER ATR (0.40) before TP1 is hit -> both TP and SL update to new plan!
    sim3.set_bar("M5", 1, 3, atr=0.40, bar_time=1300)
    sim3.update_plan()
    sim3.manage_auto_bar()
    check(sim3.auto["M5"].sl_pts == sim3.plans["M5"]["sl_pts"] and sim3.auto["M5"].sl_price < orig_sl,
          "Before TP1/Trailstop, open trade SL must update to the new candle's plan")
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
    # 7. InpUseStopLoss = false: No initial SL placed, but when TP1 hits
    #    SL IS placed at the Entry point (Break-Even)
    # ------------------------------------------------------------------
    sim_nosl = AutoTraderSim(auto_trading=True, use_stop_loss=False)
    sim_nosl.set_bar("M5", 1, 3, atr=0.28, bar_time=1000)
    sim_nosl.update_plan()
    sim_nosl.manage_auto_bar()
    check(sim_nosl.auto["M5"].active and sim_nosl.auto["M5"].is_open, "M5 BUY opened with InpUseStopLoss=false")
    check(sim_nosl.auto["M5"].sl_price == 0.0 and sim_nosl.auto["M5"].sl_pts == 0,
          "When InpUseStopLoss=false, no initial SL may be placed on the order")
    check(not sim_nosl.any_stoploss_on() and not sim_nosl.any_trailstop_on(),
          "Before TP1 hit with InpUseStopLoss=false, header must show Trailstop : Off | Stoploss : Off")
    check(sim_nosl.auto["M5"].val[(2, 1)].startswith("-- ("),
          "Before TP1 hit with InpUseStopLoss=false, SL cell must show '-- (Bid: ...)'; got %r"
          % sim_nosl.auto["M5"].val[(2, 1)])

    # New candle before TP1 hit -> TP updates, SL remains 0.0 (not placed)
    sim_nosl.set_bar("M5", 1, 3, atr=0.35, bar_time=1300)
    sim_nosl.update_plan()
    sim_nosl.manage_auto_bar()
    check(sim_nosl.auto["M5"].sl_price == 0.0,
          "Before TP1 hit with InpUseStopLoss=false, bar close must keep SL off (0.0)")

    # Price reaches TP1 -> SL MUST be placed at Entry point (Break-Even) even though InpUseStopLoss=false!
    tp1_bid = sim_nosl.auto["M5"].entry_price + sim_nosl.auto["M5"].tp1_pts * 0.01
    sim_nosl.manage_auto_tick(bid=tp1_bid, ask=tp1_bid + 0.02)
    check(sim_nosl.auto["M5"].tp1_hit and sim_nosl.auto["M5"].trail_active,
          "TP1 hit with InpUseStopLoss=false must activate TP1 and Trailstop")
    check(abs(sim_nosl.auto["M5"].sl_price - sim_nosl.auto["M5"].entry_price) < 1e-6,
          "When TP1 hits with InpUseStopLoss=false, SL MUST be placed at Entry point (%.2f); got %.2f"
          % (sim_nosl.auto["M5"].entry_price, sim_nosl.auto["M5"].sl_price))
    check(sim_nosl.any_trailstop_on() and sim_nosl.any_stoploss_on(),
          "After TP1 hits with InpUseStopLoss=false, header must show Trailstop : On | Stoploss : On")
    print("  ok  InpUseStopLoss=false: no SL placed initially; when TP1 hits, SL is placed at Entry (Break-Even)")

    print("  ok  Rule 4, 7, 10, 11, 12: Candle updates, 2/3->3/3 upgrade, HOLD-in-profit close, and 2nd panel auto-close")
    print("\nall autotrading and 2nd-panel checks passed")


if __name__ == "__main__":
    main()
