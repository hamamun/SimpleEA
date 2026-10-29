"""Synthetic checks for the replacement plan and its safety contracts.

The compiled harness executes selected function bodies extracted from the
actual .mq5 under C++ with stubbed MT5 services. It is NOT an MQL compiler,
a broker simulation, a real-tick test, or evidence of profitability.
"""
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "SimpleAdvisor.mq5").read_text(encoding="utf-8")


def function_text(name):
    match = re.search(r"\b(?:void|int|bool|double|string)\s+" + re.escape(name) + r"\s*\(", SOURCE)
    if not match:
        raise AssertionError(f"function not found: {name}")
    start = match.start()
    brace = SOURCE.index("{", match.end())
    depth, i = 0, brace
    state = "code"
    while i < len(SOURCE):
        ch = SOURCE[i]
        nxt = SOURCE[i + 1] if i + 1 < len(SOURCE) else ""
        if state == "code":
            if ch == '/' and nxt == '/': state, i = "line", i + 1
            elif ch == '/' and nxt == '*': state, i = "block", i + 1
            elif ch == '"': state = "string"
            elif ch == "'": state = "char"
            elif ch == '{': depth += 1
            elif ch == '}':
                depth -= 1
                if depth == 0: return SOURCE[start:i + 1]
        elif state == "line":
            if ch == '\n': state = "code"
        elif state == "block":
            if ch == '*' and nxt == '/': state, i = "code", i + 1
        elif state in ("string", "char"):
            if ch == '\\': i += 1
            elif (state == "string" and ch == '"') or (state == "char" and ch == "'"):
                state = "code"
        i += 1
    raise AssertionError(f"unclosed function: {name}")


class SourceContracts(unittest.TestCase):
    def test_atr_does_not_set_new_plan_prices(self):
        for obsolete in ("SL_ATR_M5", "SL_ATR_M15", "SL_ATR_M30", "TP_ATR_M5",
                         "TP_ATR_M15", "TP_ATR_M30", "PEND_ATR", "RANGE_SL_ATR", "RANGE_MIN_ATR"):
            self.assertNotIn(obsolete, SOURCE)
        for name in ("StructureGeometry", "ReplayObservation", "PlanPricesValid", "UpdatePlanRow", "PlacePlanOrder"):
            body = function_text(name)
            self.assertNotIn("ATRClosed(", body, name)
            self.assertNotIn("signalAtr", body, name)
        self.assertIn("ROC_DEAD_ATR * signalAtr", function_text("ObserveLane"))
        self.assertIn("ATRClosed(", function_text("EvaluateRow"))  # unchanged signal noise gate

    def test_hold_is_a_new_entry_gate_not_a_signal_or_exit(self):
        plan = function_text("UpdatePlanRow")
        self.assertIn("obs.filled < OBS_MIN_CASES", plan)
        self.assertIn('StringFormat("need %d analogs", OBS_MIN_CASES), "swing-only"', plan)
        self.assertIn('HoldPlan(i, entryVeto)', plan)
        self.assertNotRegex(plan, r"g_rows\[i\]\.direction\s*=(?!=)")
        self.assertIn("CanTradeNow() && AutoTimerAllowsPlacement()", function_text("CanPlaceAutoOrders"))
        self.assertIn("ACCOUNT_MARGIN_MODE_RETAIL_HEDGING", plan)
        self.assertIn("ACCOUNT_MARGIN_MODE_RETAIL_HEDGING", function_text("PlacePlanOrder"))
        self.assertIn("g_plans[i].state != 2", function_text("PlacePlanOrder"))
        preview = function_text("ShowHeldPlan")
        self.assertIn('HoldPlan(i, why)', preview)
        self.assertIn('"NO ORDER"', preview)
        self.assertNotIn('g_plans[i].entryPrice =', preview)
        bar = function_text("ManageAutoBar")
        open_branch = bar.split("// ---- CASE A:", 1)[1].split("// ---- CASE B:", 1)[0]
        self.assertNotIn("TradeClosePosition", open_branch)
        self.assertNotIn("TradeModify", open_branch)
        self.assertNotIn("InpEnableNewEntries", SOURCE)
        self.assertNotIn("InpRoundTripCommissionPerLot", SOURCE)
        for name in ("InpAutoTrading", "InpAutoTradeM5", "InpAutoTradeM15", "InpAutoTradeM30",
                     "InpAllowChoppyTrade", "InpAllowMixedTrade"):
            self.assertRegex(SOURCE, rf"input bool\s+{name}\s*=\s*true")
        self.assertRegex(SOURCE, r"input bool\s+InpUseAutoSchedule\s*=\s*false")
        self.assertRegex(SOURCE, r"input int\s+InpAutoOffHours\s*=\s*0")
        self.assertIn("!InpAutoTrading", function_text("CanTradeNow"))
        self.assertIn("TERMINAL_TRADE_ALLOWED", function_text("CanTradeNow"))
        self.assertIn("ACCOUNT_TRADE_ALLOWED", function_text("CanTradeNow"))
        for label in ('"Entry:"', '"Stop:"', '"TP1~:"', '"TP2~:"', '"TP3~:"'):
            self.assertIn(label, preview)
        self.assertIn('"--"', preview)

    def test_spread_only_screen_and_fee_disclosure(self):
        prices = function_text("PlanPricesValid")
        self.assertIn("(ask - bid) + eps", prices)
        self.assertNotIn("commissionPrice", prices)
        plan = function_text("UpdatePlanRow")
        self.assertIn('g_plans[i].lbl[3][2] = "Fees:"', plan)
        self.assertIn('g_plans[i].val[3][2] = "not included"', plan)
        self.assertIn('double perLotRisk = (double)slPts * pv;', plan)
        self.assertIn('double actualRisk = lot * (double)slPts * pv;', function_text("PlacePlanOrder"))
        monitor = function_text("UpdateAutoPanel")
        self.assertIn('"TP/SL; fees excluded"', monitor)
        self.assertIn('"%s (%s %s est)"', monitor)

    def test_replay_does_not_invent_tick_order_or_open_samples(self):
        replay = function_text("ReplayObservation")
        self.assertIn("last + horizon >= ArraySize(bars)", replay)
        self.assertIn("if(stopped) break", replay)
        self.assertIn("!market && k == first", replay)
        self.assertIn("bars[k].high + spread >= g.stop", replay)
        self.assertIn("bars[first].low + fillSpread <= g.entry", replay)
        observe = function_text("ObserveLane")
        self.assertIn("if(t + horizon >= lastStart) continue", observe)
        self.assertGreater(observe.index("lastStart = t"), observe.index("ReplayObservation("))
        self.assertIn("pastScore != score", observe)
        self.assertIn("pastRegime != obs.regime", observe)
        self.assertIn("pastMarket != market", observe)
        self.assertIn("pastRange != range", observe)
        self.assertNotIn('"Reach:"', SOURCE)

    def test_execution_journals_and_executable_quote(self):
        place = function_text("PlacePlanOrder")
        self.assertLess(place.index("BeginTargetIntent("), place.index("TradeOpenMarket("))
        self.assertIn("g_plans[i].tp1Price", place)
        bar = function_text("ManageAutoBar")
        pending = bar.split("// ---- CASE B:", 1)[1].split("// ---- CASE C:", 1)[0]
        self.assertLess(pending.index("BeginTargetUpdate("), pending.index("TradeModifyOrder("))
        self.assertGreater(pending.index("g_auto[i].tp1Price = newTP1"), pending.index("if(TradeModifyOrder("))
        self.assertLess(pending.index("BrokerExitsDiffer("), pending.index("BeginTargetUpdate("))
        modify = function_text("TradeModifyOrder")
        self.assertIn("PendingLevelsMatch(ordTicket", modify)
        self.assertNotIn("res.retcode == TRADE_RETCODE_PLACED", modify)
        tick = function_text("ManageAutoTick")
        self.assertIn("(dir > 0) ? bid : ask", tick)
        self.assertNotIn("grossPts", tick)
        self.assertIn("g_auto[i].tp1Skipped", tick)
        self.assertIn("g_auto[i].cancelPending || missingLevels || planBlocked", tick)
        self.assertIn("RequestPendingCancellation(i)", tick)
        self.assertNotRegex(tick, re.compile(r"RequestPendingCancellation\(i\).*?ResetAutoSlot", re.S))
        self.assertNotIn("DiaryBeginUpgrade(i)", pending)
        self.assertNotRegex(pending, re.compile(r"RequestPendingCancellation\(i\).*?ResetAutoSlot", re.S))
        self.assertIn("g_auto[i].residualOrder) continue", tick)
        self.assertIn("g_auto[i].multiplePositions) continue", tick)
        self.assertIn("TRADE_RETCODE_DONE_PARTIAL", function_text("TradeOpenMarket"))
        self.assertIn("inFlight = (res.retcode == TRADE_RETCODE_PLACED)", function_text("TradeOpenMarket"))
        self.assertIn("ORDER_FILLING_RETURN", function_text("TradePlaceLimit"))
        self.assertIn("TRADE_RETCODE_DONE_PARTIAL", function_text("TradePlaceLimit"))
        self.assertIn("posTicket == 0 || !PositionSelectByTicket(posTicket)", function_text("TradeClosePosition"))
        self.assertIn("liveVolume - volume < SymbolMinLot()", function_text("TradeClosePosition"))
        self.assertIn("outTicket = res.order", function_text("TradeOpenMarket"))
        for name in ("TradeOpenMarket", "TradePlaceLimit", "TradeClosePosition"):
            self.assertIn("TRADE_RETCODE_LOCKED", function_text(name))
            self.assertIn("TRADE_RETCODE_ERROR", function_text(name))
        self.assertIn('if(status == 0) { DeleteTargetIntent(i);', place)
        sync = function_text("SyncAutoState")
        self.assertIn('!foundOrd && !GlobalVariableCheck(AutoGVKey(i, "iv"))', sync)
        self.assertIn('BrokerSlotEnded(i, wasActive)', sync)
        self.assertIn('GlobalVariableCheck(AutoGVKey(i, "lv"))', function_text("PlanHasUncertainOrder"))
        self.assertIn("g_auto[i].diaryPositionId != livePositionId", sync)
        self.assertIn("MathAbs(previousSL - g_auto[i].slPrice)", sync)
        self.assertIn("MathAbs(previousEntry - g_auto[i].entryPrice)", sync)
        self.assertIn("g_auto[i].ticket != tk", sync)
        self.assertNotIn("g_auto[", SOURCE[:SOURCE.index("SAutoState g_auto[")])
        milestone = function_text("ManageMilestone")
        self.assertLess(milestone.index("StoreMilestone(i, stage, start, goal, done, true)"),
                        milestone.index("TradeClosePosition("))
        self.assertIn("if(status == 0)", milestone)
        self.assertIn("if(awaiting || !reached)", milestone)
        self.assertIn("g_auto[i].legacyRecovery && r.tp1Hit", function_text("DiaryAttachSlotRecord"))


@unittest.skipUnless(shutil.which("g++"), "requires g++ to execute extracted pure MQL bodies")
class ExtractedFunctionTests(unittest.TestCase):
    def test_structure_replay_restart_and_milestones(self):
        names = [
            "StructureWindow", "ObservationHorizon", "PriceDown", "PriceUp",
            "ConfirmedSwingLow", "ConfirmedSwingHigh", "BoxAt", "InsertStructureCap",
            "StructureGeometry", "ObservationSpread", "ReplayObservation", "PlanPricesValid",
            "HurstExponent", "ObservationReturnPrefix", "ObservationHurst",
            "ComputeLegacyTPLevels", "SymbolMinLot", "VolumeStepDigits", "NormalizeLots", "FloorLotStep",
            "CalcTP1CloseLot", "CalcTP2CloseLot", "SetSlotGV", "DeleteTargetIntent", "DeleteTargetUpdate",
            "BeginTargetIntent", "BeginTargetUpdate", "StoredSlotIdentityMatches", "SaveAutoSlotState",
            "ClearAutoSlotState", "SlotGV", "RestoreAutoSlotState", "RefreshSlotTargetDistances",
            "MatchingBrokerLevels", "RecoverSlotTargets", "BrokerExitsDiffer", "PendingLevelsMatch", "TradeModifyOrder", "RequestPendingCancellation", "CancelEntryRemainders",
            "BrokerPositionEnded", "BrokerOrderEnded", "BrokerSlotEnded",
            "StoreMilestone", "ManageMilestone",
        ]
        code = "\n\n".join(function_text(name) for name in names)
        # Adapt only MQL's array-reference syntax to std::vector / a C array;
        # the production calculations and branching are otherwise unchanged.
        code = code.replace("const MqlRates &bars[]", "const std::vector<MqlRates> &bars")
        code = code.replace("double &caps[]", "double *caps")
        code = code.replace("const double &close[]", "const std::vector<double> &close")
        code = code.replace("const double &prefix[]", "const std::vector<double> &prefix")
        code = code.replace("double &prefix[]", "std::vector<double> &prefix")
        code = code.replace("double sums[];", "std::vector<double> sums;")
        with tempfile.TemporaryDirectory(prefix="simpleea-test-") as directory:
            d = Path(directory)
            (d / "extracted.hpp").write_text(code, encoding="utf-8")
            binary = d / "structure-harness"
            build = subprocess.run(["g++", "-std=c++17", "-O1", "-Wall", "-Wextra", "-I", str(d),
                                    str(ROOT / "tests" / "structure_harness.cpp"), "-o", str(binary)],
                                   text=True, capture_output=True)
            self.assertEqual(build.returncode, 0, build.stderr)
            result = subprocess.run([str(binary)], text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("checks passed", result.stdout)


    def test_plan_defaults_and_held_display(self):
        names = ["ClearPlanRow", "HoldPlan", "ShowHeldPlan", "PlanPricesValid",
                 "UpdatePlanRow", "CanPlaceAutoOrders"]
        code = "\n\n".join(function_text(name) for name in names)
        code = code.replace("MqlRates bars[];", "std::vector<MqlRates> bars;")
        with tempfile.TemporaryDirectory(prefix="simpleea-plan-") as directory:
            d = Path(directory)
            (d / "extracted.hpp").write_text(code, encoding="utf-8")
            binary = d / "plan-harness"
            build = subprocess.run(["g++", "-std=c++17", "-O1", "-Wall", "-Wextra", "-I", str(d),
                                    str(ROOT / "tests" / "plan_harness.cpp"), "-o", str(binary)],
                                   text=True, capture_output=True)
            self.assertEqual(build.returncode, 0, build.stderr)
            result = subprocess.run([str(binary)], text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("extracted plan defaults, held previews, spread and permissions passed", result.stdout)

    def test_full_observation_pipeline(self):
        names = ["HighPass3", "EfficiencyRatio", "StructureVote", "ScoreAllowsTrade",
                 "StructureWindow", "ObservationHorizon", "PriceDown", "PriceUp",
                 "ConfirmedSwingLow", "ConfirmedSwingHigh", "BoxAt", "InsertStructureCap",
                 "StructureGeometry", "ObservationCycleAt", "ObservationTrends",
                 "ObservationSignalATR", "ObservationVolumeOK", "ObservationReturnPrefix",
                 "ObservationHurst", "ObservationSourceIndex", "ObservationSpread", "ReplayObservation", "PlanPricesValid", "ObserveLane"]
        code = "\n\n".join(function_text(name) for name in names)
        code = re.sub(r"const double &(\w+)\[\]", r"const std::vector<double> &\1", code)
        code = re.sub(r"double &(\w+)\[\]", r"std::vector<double> &\1", code)
        code = re.sub(r"const MqlRates &(\w+)\[\]", r"const std::vector<MqlRates> &\1", code)
        code = code.replace("std::vector<double> &caps", "double *caps")
        # Rewrite dynamic array declarations, leaving fixed-size stack arrays alone.
        code = re.sub(r"\b(double|int|MqlRates)\s+((?:\w+\[\](?:,\s*)?)+);",
                      lambda m: " ".join(f"std::vector<{m.group(1)}> {name};"
                                         for name in re.findall(r"(\w+)\[\]", m.group(2))), code)
        with tempfile.TemporaryDirectory(prefix="simpleea-observe-") as directory:
            d = Path(directory)
            (d / "extracted.hpp").write_text(code, encoding="utf-8")
            binary = d / "observe-harness"
            build = subprocess.run(["g++", "-std=c++17", "-O2", "-Wall", "-Wextra", "-I", str(d),
                                    str(ROOT / "tests" / "observation_harness.cpp"), "-o", str(binary)],
                                   text=True, capture_output=True)
            self.assertEqual(build.returncode, 0, build.stderr)
            result = subprocess.run([str(binary)], text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("full synthetic observation pipeline passed", result.stdout)


if __name__ == "__main__":
    unittest.main()
