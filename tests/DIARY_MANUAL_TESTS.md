# Diary validation in MT5

The Python tests are source-level checks, not an MQL5 compiler or runtime test.
Before live use:

1. Compile SimpleAdvisor.mq5 in MetaEditor; expect no errors or conversion warning.
2. On demo, place/close a trade, restart, and confirm its row and totals survive.
3. Start a second copy with the same account/symbol/magic. It must fail initialization;
   after stopping the first copy, a new copy must start (the lock file may remain).
   All concurrent copies must use this updated build for locking to protect them.
4. Back up a diary, then damage a numeric field, truncate a row, or duplicate an ID.
   Restart and confirm a warning and that the CSV is not overwritten. Restore the
   backup afterwards. New records are memory-only until the file is repaired.
5. With 60 observed closed trades, confirm score/style/health use the newest 30
   and the previous 30 are the baseline. Each persistence half contains 15 trades.
6. Let a broker-side SL/TP close a recorded trade while the EA is stopped. On
   restart, confirm recovered P/L remains in totals but the row is excluded from
   health (peakTp1Pct = -1); health requires 30 eligible observed closed trades.

## Remaining observational limits

No offline tick reconstruction is attempted. Obsolete trailing CSV columns are reserved and ignored, not recreated or used in health statistics. This protection applies to
closes recovered by DiaryReconcileOpenRecords. A position resumed while still
open, or a connection gap while the EA stays loaded, can still have incomplete
intratrade observations. Existing historical rows are not retroactively repaired.
Health is descriptive evidence, not guaranteed complete execution telemetry or
an automatic strategy-learning engine. Older builds do not honor the lock.
