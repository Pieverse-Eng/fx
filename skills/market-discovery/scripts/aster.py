#!/usr/bin/env python3
"""Discover Aster perpetual symbols with one public catalog request."""

import argparse
from datetime import datetime, timezone
import json
import re
import sys
from urllib.error import URLError
from urllib.request import Request, urlopen


SOURCE = "https://fapi.asterdex.com/fapi/v3/exchangeInfo"
REQUIRED = ("symbol", "baseAsset", "quoteAsset", "marginAsset", "contractType", "status")
OPTIONAL = ("underlyingType", "underlyingSubType", "channel")


def ticker(value):
    value = value.strip().upper()
    if not re.fullmatch(r"[A-Z0-9]+", value):
        raise argparse.ArgumentTypeError("use a base or quote ticker, not a name or pair")
    return value


def select_markets(payload, bases, quote=None):
    if not isinstance(payload, dict) or "code" in payload:
        raise ValueError("Aster returned an API error or invalid catalog")
    symbols = payload.get("symbols")
    if not isinstance(symbols, list) or not symbols:
        raise ValueError("Aster returned a missing or empty symbol catalog")
    markets = []
    for row in symbols:
        if not isinstance(row, dict) or not isinstance(row.get("status"), str) or not row["status"]:
            raise ValueError("Aster returned a symbol without trading status")
        # Pending listings can legitimately have an empty contractType.
        if row["status"] != "TRADING":
            continue
        if any(
            not isinstance(row.get(key), str) or not row[key] for key in REQUIRED
        ):
            raise ValueError("Aster returned an incomplete symbol record")
        if (
            row["baseAsset"] in bases
            and (quote is None or row["quoteAsset"] == quote)
            and row["contractType"] == "PERPETUAL"
        ):
            markets.append({key: row[key] for key in REQUIRED + OPTIONAL if key in row})
    return sorted(markets, key=lambda row: (row["baseAsset"], row["quoteAsset"], row["symbol"]))


def discover(bases, quote=None):
    request = Request(SOURCE, headers={"Accept": "application/json"})
    with urlopen(request, timeout=20) as response:
        payload = json.load(response)
    return {
        "venue": "aster",
        "source": SOURCE,
        "queriedAt": datetime.now(timezone.utc).isoformat(),
        "baseAssets": bases,
        "quoteAsset": quote,
        "markets": select_markets(payload, bases, quote),
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    exchange = commands.add_parser("exchange-info", help="Find active perpetual contracts")
    exchange.add_argument("--base-asset", type=ticker, nargs="+", required=True)
    exchange.add_argument("--quote-asset", type=ticker)
    args = parser.parse_args(argv)
    try:
        result = discover(list(dict.fromkeys(args.base_asset)), args.quote_asset)
    except (URLError, OSError, ValueError) as exc:
        print(json.dumps({"error": str(exc), "source": SOURCE}), file=sys.stderr)
        return 1
    print(json.dumps(result, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
