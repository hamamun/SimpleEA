"""Retired ATR-era panel walk; run current structure-plan checks instead.

The previous character-grid walkthrough modeled ATR-multiplied plan prices
and imported a retired helper, so it cannot represent the current EA. This
wrapper runs the current synthetic/extracted plan checks; it does NOT render
an MT5 panel or replace visual verification in MetaTrader.
"""
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
print('ATR-era panel walkthrough retired; running structure-plan tests (not a visual test).', flush=True)
result = subprocess.run([sys.executable, '-m', 'unittest', 'discover', '-s', 'tests',
                         '-p', 'test_structure_plan.py', '-v'], cwd=root)
raise SystemExit(result.returncode)
