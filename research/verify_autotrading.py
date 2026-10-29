"""Run current fixed-exit and structure-execution regressions.

The old ATR/75%-ladder model is intentionally retired. These tests exercise
selected MQL function bodies as C++ with stubs plus source contracts; they
are NOT MetaEditor compilation, broker execution, or profitability tests.
"""
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
for pattern in ('test_fixed_exit_contracts.py', 'test_structure_plan.py'):
    result = subprocess.run([sys.executable, '-m', 'unittest', 'discover', '-s', 'tests',
                             '-p', pattern, '-v'], cwd=root)
    if result.returncode:
        raise SystemExit(result.returncode)
print('\nSource/extracted-function checks passed; compile and test in MT5 separately.')
