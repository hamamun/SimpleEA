"""Source-level regression checks; these do not execute or compile MQL5."""
from pathlib import Path
import unittest

SOURCE = (Path(__file__).resolve().parents[1] / 'SimpleAdvisor.mq5').read_text()


class DiaryRegressionTests(unittest.TestCase):
    def test_window_boundaries(self):
        for count in range(30, 61):
            start = max(0, count - 30)
            split = start + (count - start) // 2
            self.assertEqual(list(range(start, count)), list(range(count))[-30:])
            self.assertEqual(split - start, 15)
            self.assertEqual(count - split, 15)
        self.assertIn('int splitAt = recStart + recN / 2;', SOURCE)
        self.assertEqual(SOURCE.count('for(int k = recStart; k < lane.recentCount; k++)'), 2)
        self.assertIn('int start = (half == 0) ? startAt : splitAt;', SOURCE)

    def test_protection_guards(self):
        self.assertIn('if(g_diaryFile == "" || g_diaryLoadFailed) return(false);', SOURCE)
        self.assertIn('if(DiaryRecordIndexById(r.id) >= 0)', SOURCE)
        self.assertIn('if(!digitSeen) return(false);', SOURCE)
        self.assertIn('if(g_diaryLockHandle == INVALID_HANDLE)', SOURCE)
        self.assertIn('FileClose(g_diaryLockHandle);', SOURCE)

    def test_offline_and_character_conversion(self):
        self.assertIn('g_diary[k].peakTp1Pct = -1.0;', SOURCE)
        self.assertIn('if(r.peakTp1Pct < 0.0) continue;', SOURCE)
        self.assertIn('safe += ok ? ShortToString(ch) : "_";', SOURCE)


if __name__ == '__main__':
    unittest.main()
