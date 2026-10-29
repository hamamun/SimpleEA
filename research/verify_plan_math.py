"""Verify the current structure/observed-excursion plan with synthetic cases.

This replaces the obsolete ATR-multiplier arithmetic model. Tests include
production function bodies extracted into a C++ harness with stubbed broker
services; this is NOT an MQL5 compile, real-tick test, or profitability test.
"""
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
result = subprocess.run([sys.executable, '-m', 'unittest', 'discover', '-s', 'tests',
                         '-p', 'test_structure_plan.py', '-v'], cwd=root)
raise SystemExit(result.returncode)
