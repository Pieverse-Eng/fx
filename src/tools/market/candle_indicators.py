"""Deterministic closed-candle calculations; no network, formula evaluation or orders.

Definitions: Fidelity technical indicator guides for RSI and EMA. EMA uses
alpha=2/(period+1), Wilder RSI alpha=1/period, each seeded with an arithmetic
mean. The bounded initialization convention is part of every result: three
additional periods after the seed. It is not an infinite-history estimate.
"""
from __future__ import annotations

import json
import math
import sys

INTERVAL_MS = {"15m": 900_000, "1h": 3_600_000, "4h": 14_400_000}


def required_history(spec: dict) -> int:
    period = spec["period"]
    seed = period if spec["name"] == "sma" else 4 * period + (spec["name"] == "rsi")
    return seed + max(0, spec.get("series", 0) - 1)


def validate_spec(spec: dict) -> None:
    if not isinstance(spec, dict) or set(spec) - {"name", "period", "series"}:
        raise ValueError("Invalid indicator specification")
    if spec.get("name") not in ("sma", "ema", "rsi"):
        raise ValueError("Unsupported indicator; supported: sma, ema, rsi")
    if type(spec.get("period")) is not int or not 2 <= spec["period"] <= 200:
        raise ValueError("period must be an integer from 2 to 200")
    if type(spec.get("series", 0)) is not int or not 0 <= spec.get("series", 0) <= 64:
        raise ValueError("series must be an integer from 0 to 64")


def _values(closes: list[float], name: str, period: int) -> list[float | None]:
    out = [None] * len(closes)
    if name == "sma":
        for i in range(period - 1, len(closes)):
            out[i] = math.fsum(closes[i - period + 1:i + 1]) / period
        return out
    if name == "ema":
        current = math.fsum(closes[:period]) / period
        out[period - 1] = current
        alpha = 2 / (period + 1)
        for i in range(period, len(closes)):
            current += alpha * (closes[i] - current)
            out[i] = current
        return out
    changes = [b - a for a, b in zip(closes, closes[1:])]
    gain = math.fsum(max(x, 0) for x in changes[:period]) / period
    loss = math.fsum(max(-x, 0) for x in changes[:period]) / period
    for i in range(period, len(closes)):
        if i > period:
            delta = changes[i - 1]
            gain = (gain * (period - 1) + max(delta, 0)) / period
            loss = (loss * (period - 1) + max(-delta, 0)) / period
        out[i] = 50.0 if gain == loss == 0 else 100.0 if loss == 0 else 100 - 100 / (1 + gain / loss)
    return out


def calculate(frame: dict | None, interval: str, spec: dict, quote: str | None) -> dict:
    validate_spec(spec)
    needed = required_history(spec)
    result = {"name": spec["name"], "parameters": {"period": spec["period"]},
              "interval": interval, "status": "unavailable", "value": None,
              "unit": "index_0_100" if spec["name"] == "rsi" else quote,
              "requiredClosedCandles": needed, "lastClosedAt": None, "gaps": [],
              "convention": "closed candles; arithmetic mean" if spec["name"] == "sma" else
                  "closed candles; arithmetic-mean seed + 3 periods warm-up; " +
                  ("Wilder alpha=1/period; flat RSI=50" if spec["name"] == "rsi" else "EMA alpha=2/(period+1)")}
    if interval not in INTERVAL_MS:
        result["gaps"] = ["Unsupported interval"]
        return result
    closed = frame.get("closed", []) if isinstance(frame, dict) else []
    if not isinstance(closed, list):
        result["gaps"] = ["Invalid closed candle data"]
        return result
    rows = closed[-needed:]
    result["availableClosedCandles"] = len(rows)
    if len(rows) < needed:
        result["gaps"] = ["Insufficient closed history for the documented initialization"]
        return result
    if (frame or {}).get("qualityGaps"):
        result["gaps"] = list(frame["qualityGaps"])
        return result
    if any(not isinstance(r, list) or len(r) != 6 or any(type(v) not in (float, int) or not math.isfinite(v) for v in r[:5]) for r in rows):
        result["gaps"] = ["Invalid OHLC values"]
        return result
    if any(b[0] - a[0] != INTERVAL_MS[interval] for a, b in zip(rows, rows[1:])):
        result["gaps"] = ["Missing, duplicate or out-of-order closed bars; no gap filling"]
        return result
    values = _values([r[4] for r in rows], spec["name"], spec["period"])
    result.update(status="available", value=values[-1], lastClosedAt=rows[-1][0])
    if spec.get("series"):
        count = spec["series"]
        result["series"] = [{"time": row[0], "value": value} for row, value in zip(rows[-count:], values[-count:])]
    return result


def enrich(payload: dict, request: dict) -> dict:
    specs = request.get("indicators", [])
    for spec in specs:
        validate_spec(spec)
    for row in payload.get("results", []):
        row["indicators"] = [calculate(row.get("timeframes", {}).get(interval), interval, spec, row.get("quote"))
                             for interval in request.get("intervals", ["15m", "1h", "4h"]) for spec in specs]
    return payload


if __name__ == "__main__":
    json.dump(enrich(json.load(sys.stdin), json.loads(sys.argv[1])), sys.stdout, separators=(",", ":"), allow_nan=False)
