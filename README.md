# SimpleEA 2.0

`SimpleAdvisor.mq5` is a single-file MetaTrader 5 Expert Advisor with separate **M5 (scalp), M15 (short-term), and M30 (intraday)** signal and trade-plan lanes. The directional engine evaluates closed bars; entries and exits also depend on live quotes and broker execution.

> **Default behavior:** `InpAutoTrading=true` and new entries are enabled. An eligible signal can place a real order on a fresh bar when MT5 and the broker permit trading. The structure/history planner has **not** been compiled in MetaEditor or validated with a broker. Its policy choices are unvalidated, and stops and cancellations are not guaranteed.

## Signal versus trading HOLD

The existing three-vote direction, trend, Hurst regime, and score engine is retained. It may display **BUY** or **SELL** while the trade plan says **HOLD**: that means there is a directional reading, but the EA cannot open a new trade under the current data, structure, spread, risk, or permission checks. A signal can itself be HOLD when, for example, the score or efficiency gate does not qualify.

With the master enabled, a trading HOLD blocks new orders and requests cancellation of waiting entries; it does **not** close an existing position or change its SL/TP. A broker can reject a cancellation or fill an order before it is cancelled, so check the actual broker state.

## Previous versus current trade plan

| Feature | Previous ATR-based EA | Current structure/history plan |
|---|---|---|
| Ordinary pending entry | Offset by 0.5 × ATR, increased for spread/broker limits | Confirmed support/resistance; eligible range limits use the box band |
| Non-range stop | Nominal M5/M15/M30: 1.0/1.2/1.5 × ATR | Beyond a separate confirmed invalidation swing with a quote-side buffer |
| Non-range final target (TP3) | Nominal M5/M15/M30: 0.9/1.8/3.0 × ATR | Historical follow-through quantile, capped by an opposing swing when available |
| TP1 and TP2 | About 56.25% and 75% of TP3, with point rounding | Independently selected historical quantiles and structure caps |
| Insufficient evidence | ATR formulas supplied levels | Trading HOLD; available candidate prices are marked indicative and are not orders |
| Timeframe treatment | Fixed multipliers per timeframe | M5/M15/M30 use separate structure windows and 4/6/8-bar observation horizons |

The previous non-range distances could be widened to meet the broker's minimum. The **new plan's entry, SL and TP prices do not use ATR multipliers**. ATR remains in the retained signal engine's noise/structure vote filters. The earlier default-off entry switch and manual commission input have been removed.

## Structure and historical trade plans

- A market entry uses the executable quote; a limit uses a confirmed support/resistance swing, or an eligible 20-bar box band. The stop lies beyond a separate confirmed invalidation swing. If valid structure or broker distances are unavailable, the lane holds rather than inventing a level.
- TP1, TP2, and TP3 come from separate quantiles of **completed historical bar-level analogs** for the same symbol, timeframe, direction, score, regime, and entry style. Follow-through is measured before the first observed stop. Current opposing swings can cap targets.
- At least **30** qualifying, nonoverlapping hypothetical fills/touches are required. Pending touches are not proof of fills. Bar OHLC and spread proxies cannot recover true tick order, slippage, or historical Ask; ambiguous stop bars are treated conservatively. These statistics are not confidence, win probability, or proof of an edge.
- M5's shorter observation window is intended for faster scalps; M15/M30 use longer horizons. Actual distances depend on the market and need not be ordered by timeframe. Each lane is checked against its own spread and risk—M5 is not rejected for being smaller than another lane.
- The screen checks **spread only**, not commission, swap, or slippage. Planned risk, lot sizing, and staged reward **exclude unknown fees**, so actual costs and losses can be higher; the panel displays `Fees: not included`. The diary's settled net results may include broker-reported commissions and swap.
- New entries require a **hedging account** so timeframe positions can be isolated; netting/exchange accounts are held. Multiple same-magic positions in one lane suspend its software exits for manual review.

## What the panels show

On a supported M5, M15, or M30 chart, the main panel shows all three timeframe signals, followed by their plans. Example layout with placeholders, not actual prices:

```text
M5 Scalp     Trend: Going up     Regime: Steady
             Signal: BUY         Score: +3 / 3

M5 market +3/3  Entry: <price>   Lot: <lot>       Data: <filled>/<eligible> analogs
                Stop: <price>    TP1: <price>      TP2: <price>
                TP3: <price>     Risk: <estimate>  Reward: <estimate>
                Valid: <bars>    Window: 4 bars    Fees: not included
```

If the data are insufficient but confirmed swing barriers are available, a held plan can instead show `Entry`, `Stop`, `TP1~`, `TP2~`, `TP3~`, `Basis: swing-only`, `Action: NO ORDER`, and the reason. These are indicative swing barriers, **not a validated target plan**. If a barrier or stop cannot be determined, it is shown as `--`; the EA does not invent a price. A plan that fails another check may show `Basis: observed` with indicative target candidates. A permission-vetoed otherwise-valid plan shows HOLD and its `Block` reason. Some unavailable-data cases show only a one-line HOLD or `waiting`.

When an order or position exists, the separate Autotrading panel shows its broker entry and SL, frozen TP1/TP2/TP3, live quote, and status. It marks the SL money amount as an estimate and displays `fees excluded`. `[HIT]`, `[SKIP]`, `[PART]`, and `[REVIEW]` describe the software partial stages. The main header's `On` describes the master and timer only; it does not mean every account, broker, or plan gate is satisfied.

## Position management

Broker-side SL and TP3 are sent with new orders and are not intentionally moved after fill. TP1 and TP2 are fixed absolute software levels; later quotes or signals do not recalculate them. Favorable exits use **Bid for BUY positions and Ask for SELL positions**.

| Stage | Intended action |
|---|---|
| TP1 | Close 70%, rounded to the broker lot step, when a valid remainder can stay open |
| TP2 | Reduce the remaining volume to broker minimum when possible |
| TP3 | Broker-side target for the remainder |
| SL | Broker-side protective stop |

TP1/TP2 require the EA, terminal, and trading permissions to remain operational. Fill slippage can place a software target at or behind the actual entry; that stage is skipped rather than shifted. Rejected partials are retryable; an ambiguous response is marked for review instead of blindly sending a duplicate. Stops can slip, and actual losses can exceed the planned risk. For restart and older-trade caveats, see [the specification](documents.md#54-restart-manual-action-and-diary-recovery).

## Setup and operation

1. Copy `SimpleAdvisor.mq5` to `MQL5/Experts/` and compile with MetaEditor. This repository does not contain a compiled EA.
2. Attach to an M5, M15, or M30 chart with sufficient history. **The default permits eligible new entries** on each lane's next fresh bar; MT5 Algo Trading, account/broker permissions, and all plan/entry gates must also allow them.
3. For a **read-only preview**, set `InpAutoTrading=false`; disabling MT5 Algo Trading is an additional safeguard. Master-off mode makes **no trade requests and does not manage existing positions**.
4. Commission, swap and slippage are not estimated in a new plan. Account for your broker's actual charges separately. See the [MT5/broker validation checklist](documents.md#11-manual-mt5-and-broker-validation-checklist).

## Important inputs

| Input | Default | Meaning |
|---|---:|---|
| `InpAutoTrading` | `true` | Master for trade requests and open-position management; `false` is read-only |
| `InpUseRisk` / `InpRiskPct` / `InpUseMinLot` | `true` / `0.5` / `false` | Risk sizing, default risk percent, or minimum-lot override; fees excluded |
| `InpAutoTradeM5` / `M15` / `M30` | `true` | Per-lane entry switches; open positions remain managed |
| `InpAllowChoppyTrade` / `InpAllowMixedTrade` / `InpRangeMode` | `true` | Regime permissions and optional Choppy box entry style |
| `InpUseAutoSchedule` / `InpAutoOffHours` | `false` / `0` | PC-local entry schedule and optional one-shot pause |
| `InpAutoPanelPos` / `InpShowHealth` | `Bottom` / `false` | Position panel placement and optional diary/history panel |

The diary normally records confirmed order ideas and outcomes separately from the historical bar analogs; its health labels do not prove or automatically change strategy performance.

## Verification here

```bash
python3 -m unittest discover -s tests -v
python3 research/verify_plan_math.py
python3 research/verify_autotrading.py
python3 research/verify_timeframe_gate.py
python3 research/verify_regime_fixes.py
```

The structure tests compile extracted calculations as C++ with synthetic data and stubbed MT5 services; they require `g++`. Other checks include source contracts and historical Python models. **None compile MQL5, simulate a broker accurately, or substitute for real-tick and forward testing.** See [`documents.md`](documents.md) for the full current contract and limitations.
