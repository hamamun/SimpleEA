"""Source-level fixed-exit/diary regressions; these do not compile MQL5."""
import unittest
from test_structure_plan import SOURCE, function_text


def code_only(source):
    out = list(source)
    i, state = 0, 'code'
    while i < len(source):
        ch = source[i]
        nxt = source[i + 1] if i + 1 < len(source) else ''
        if state == 'code':
            if ch == '/' and nxt == '/':
                out[i] = out[i + 1] = ' '; state = 'line'; i += 2; continue
            if ch == '/' and nxt == '*':
                out[i] = out[i + 1] = ' '; state = 'block'; i += 2; continue
            if ch in ('"', "'"):
                out[i] = ' '; state = 'string' if ch == '"' else 'char'
        elif state == 'line':
            if ch == '\n': state = 'code'
            else: out[i] = ' '
        elif state == 'block':
            if ch == '*' and nxt == '/':
                out[i] = out[i + 1] = ' '; state = 'code'; i += 2; continue
            if ch != '\n': out[i] = ' '
        else:
            if ch == '\\' and nxt:
                out[i] = out[i + 1] = ' '; i += 2; continue
            if ch != '\n': out[i] = ' '
            if (state == 'string' and ch == '"') or (state == 'char' and ch == "'"):
                state = 'code'
        i += 1
    if state not in ('code', 'line'):
        raise AssertionError('unterminated MQL literal or comment')
    return ''.join(out)


class FixedExitContracts(unittest.TestCase):
    def test_only_reviewed_position_management_paths(self):
        code = code_only(SOURCE)
        for removed in ('InpImmediateFlipClose', 'InpUseStopLoss', 'InpUseTrailStop',
                        'UpdatePreTP1Trail', 'UpdateProfitProtectionFloor',
                        'TradeModifyPosition', 'TRADE_ACTION_SLTP', 'MilestoneSLPrice'):
            self.assertNotIn(removed, code)
        tick = function_text('ManageAutoTick')
        bar = function_text('ManageAutoBar')
        open_branch = bar.split('// ---- CASE A:', 1)[1].split('// ---- CASE B:', 1)[0]
        self.assertNotIn('TradeClosePosition(', open_branch)
        self.assertNotIn('TradeModifyOrder(', open_branch)
        self.assertNotIn('OrderSend(', tick + bar)
        self.assertNotIn('g_auto[i].slPrice =', tick)
        self.assertEqual(SOURCE.count('TradeClosePosition('), 2)  # wrapper and milestone
        self.assertIn('g_auto[i].tpPrice', tick)  # broker TP3, no fabricated software close
        self.assertIn('ManageMilestone(i, 1, reached)', tick)
        self.assertIn('ManageMilestone(i, 2, reached)', tick)
        for name in ('TradeOpenMarket', 'TradePlaceLimit'):
            wrapper = function_text(name)
            self.assertIn('req.sl', wrapper)
            self.assertIn('req.tp', wrapper)
        for token in ('RequestPendingCancellation(', 'TradeModifyOrder(', 'PlacePlanOrder(', 'expired'):
            self.assertIn(token, bar)

    def test_diary_schema_stays_compatible(self):
        serializer = function_text('DiaryRecordLine')
        count = 1
        for line in serializer.splitlines():
            line = line.strip()
            if line.startswith('s += "'):
                count += line.split('"', 2)[1].count(';')
            elif line.startswith('s +='):
                count += 1
        self.assertEqual(count, 50)
        parser = code_only(function_text('DiaryParseRecordLine'))
        for field in (34, 40, 41, 42, 43, 44, 45, 46):
            self.assertNotIn(f'p[{field}]', parser)
        self.assertIn('if(n > 47) r.finalTp1Pct', SOURCE)
        self.assertIn('if(n > 49) r.stopKnown', SOURCE)
        self.assertIn('r.useStopLoss   = true;', SOURCE)

    def test_balanced_delimiters(self):
        pairs = {')': '(', ']': '[', '}': '{'}
        stack = []
        for ch in code_only(SOURCE):
            if ch in '([{': stack.append(ch)
            elif ch in pairs:
                self.assertTrue(stack and stack.pop() == pairs[ch], f'unbalanced {ch}')
        self.assertEqual(stack, [])


if __name__ == '__main__':
    unittest.main()
