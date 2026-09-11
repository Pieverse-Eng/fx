"""Exercise the registered tool with a local gateway and fixture venue CLIs."""
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

binary = str(Path(sys.argv[1]).resolve())
fixtures = Path(sys.argv[2]).resolve()


def exercise(kind, tool_name="discover_markets", references=False, multiple=False):
    if os.environ.get("FX_MARKET_TEST_CASE") and kind != os.environ["FX_MARKET_TEST_CASE"]:
        return
    with tempfile.TemporaryDirectory(prefix="fx-discovery-runtime-") as directory:
        home = Path(directory)
        (home / ".fx").mkdir()
        (home / ".fx.json").write_text(json.dumps({"context": True, "max_tool_result_bytes": 32768}))
        if kind == "denied":
            (home / ".fx/settings.json").write_text(json.dumps({"permission": {tool_name: "deny"}}))
        requests = []
        failures = []
        call_ids = ["call_" + uuid.uuid4().hex[:24] for _ in range(2 if multiple else 1)]
        args = {"tickers": ["ETH", "HOOD", "MSTR", "XAU", "BONK"] if kind == "orderly" else ["BTC", "CRCL"]}
        if tool_name == "compare_trade_routes":
            args = {"ticker": "BTC", "product": "perp", "direction": "long", "amount": "1000"}
            if kind == "evm":
                args = {"ticker": "CRCL", "product": "spot", "amount": "1000"}
            if kind == "gate_fractional":
                args["amount"] = "0.003"  # 0.3 contracts at the fixture's 100 USDT price.
            if kind == "snapshot":
                args.pop("amount")
                args.pop("direction")
            if kind.startswith("quote_"):
                args["quote"] = kind.removeprefix("quote_").upper()
            if kind == "currency_usdc":
                args["currency"] = "USDC"
            if kind == "invalid_quote":
                args["quote"] = "USDT;echo bad"
        if kind == "invalid":
            args["venues"] = ["binance"]
        if kind == "aliases":
            args = ({"ticker": "SKHYNIX", "product": "perp", "direction": "long", "amount": "1000"}
                    if tool_name == "compare_trade_routes" else {"tickers": ["SKHYNIX", "SAMSUNG"]})
        (fixtures / "calls").write_text("")
        (fixtures / "commands").write_text("")
        marker = fixtures / "binance-assets.fail"
        if kind == "partial":
            marker.touch()

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_POST(self):
                try:
                    request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                    requests.append(request)
                    if len(requests) == 1:
                        tools = {tool["function"]["name"]: tool["function"] for tool in request["tools"]}
                        if kind != "denied":
                            schema = tools[tool_name]["parameters"]
                            assert set(schema["properties"]) == ({"ticker", "product", "amount", "currency", "quote", "direction"} if tool_name == "compare_trade_routes" else {"tickers", "product", "quote"} if tool_name == "discover_markets" else {"tickers"}), schema
                            assert schema["required"] == (["ticker", "product"] if tool_name == "compare_trade_routes" else ["tickers"])
                        delta = {"role": "assistant", "tool_calls": [{"index": 0, "id": call_ids[0], "type": "function", "function": {"name": tool_name, "arguments": json.dumps(args)}}]}
                        if multiple:
                            delta["tool_calls"].append({"index": 1, "id": call_ids[1], "type": "function", "function": {"name": tool_name, "arguments": json.dumps(args)}})
                        reason = "tool_calls"
                    else:
                        final = "DISCOVERY_TEST_OK"
                        if references:
                            # Select IDs exclusively from model-visible text, never
                            # from provider metadata or prearranged fixture IDs.
                            refs = []
                            for message in request["messages"]:
                                if message.get("role") != "tool":
                                    continue
                                markers = re.findall(r"FX result reference: ([^\n]*)", message["content"])
                                assert len(markers) == 1, message["content"]
                                ref = json.loads(markers[0])["result_ref"]
                                assert ref == message["tool_call_id"]
                                refs.append(ref)
                            final = json.dumps({"result_refs": list(reversed(refs))})
                        delta = {"role": "assistant", "content": final}
                        reason = "stop"
                    chunks = [{"choices": [{"index": 0, "delta": delta, "finish_reason": None}]}, {"choices": [{"index": 0, "delta": {}, "finish_reason": reason}]}]
                    body = ("".join("data: " + json.dumps(chunk) + "\n\n" for chunk in chunks) + "data: [DONE]\n\n").encode()
                    self.send_response(200)
                    self.send_header("Content-Type", "text/event-stream")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                except Exception as error:
                    failures.append(repr(error))
                    self.send_response(500)
                    self.end_headers()

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        env = {"PATH": str(fixtures) + os.pathsep + os.environ["PATH"], "HOME": str(home), "FIXTURE_DIR": str(fixtures), "LANG": "C.UTF-8", "FX_PROVIDER": "pieverse", "FX_PIEVERSE_API_KEY": "local-fixture", "FX_MODEL": "pieverse/test/model", "FX_DISABLE_KEYCHAIN": "1", "FX_SKIP_ONBOARDING": "1", "FX_PIEVERSE_BASE_URL": f"http://127.0.0.1:{server.server_port}/v1"}
        if kind == "evm":
            env.update(FX_PLATFORM_EVM_QUOTE_URL="http://fixture/market-research/evm-quote", FX_PLATFORM_QUOTE_TOKEN="fixture")
        try:
            prompt = "Research SKHYNIX and SAMSUNG markets." if kind == "aliases" else "Find available BTC and CRCL markets."
            result = subprocess.run([binary, "ask", "--auto", "--json", "--no-save", "--", prompt], cwd=home, env=env, text=True, capture_output=True, timeout=40)
            assert not failures, failures
            assert result.returncode == 0, (result.returncode, result.stderr)
            assert not any(text in result.stderr.lower() for text in ("panic:", "segmentation fault", "error:", "assertion failed")), result.stderr
            assert len(requests) == 2, requests
            output = json.loads(result.stdout)
            if references:
                assert json.loads(output["output"]) == {"result_refs": list(reversed(call_ids))}, output
            else:
                assert output["output"].strip() == "DISCOVERY_TEST_OK", output
            assert [call["name"] for call in output["tool_calls"]] == [tool_name] * (2 if multiple else 1), output
            calls = (fixtures / "calls").read_text().splitlines()
            if kind in ("invalid", "invalid_quote", "denied"):
                assert not calls, calls
            else:
                if tool_name == "discover_markets" and not multiple:
                    # CRCL needs one extra Gate stock metadata query.
                    expected_calls = 19 if kind in ("aliases", "orderly") else 20
                    catalogs = [call for call in calls if call != "route-lighter-book"]
                    assert len(catalogs) == expected_calls and len(set(catalogs)) == expected_calls, calls
                    book_commands = [line for line in (fixtures / "commands").read_text().splitlines()
                                     if line.startswith("purr:lighter order-book-depth ")]
                    expected_books = ([f"purr:lighter order-book-depth --market {symbol} --market-type perp --limit 100"
                                       for symbol in ("SKHYNIXUSD", "SAMSUNGUSD")]
                                      if kind == "aliases" else [])
                    if kind != "orderly":
                        assert sorted(book_commands) == sorted(expected_books), book_commands
                        assert calls.count("route-lighter-book") == len(expected_books), calls
                messages = [message for message in requests[1]["messages"] if message.get("role") == "tool"]
                # Tool result presentation may add an envelope; locate the JSON payload.
                content = messages[-1]["content"]
                decoder = json.JSONDecoder()
                payload = None
                for offset, char in enumerate(content):
                    if char != "{":
                        continue
                    try:
                        candidate, _ = decoder.raw_decode(content[offset:])
                        if isinstance(candidate, dict) and set(candidate) == ({"bestRoute", "rankedRoutes", "gaps", "markets"} if tool_name == "compare_trade_routes" else {"results", "errors"} if tool_name != "get_market_candles" else {"columns", "results", "errors"}):
                            payload = candidate
                            break
                    except ValueError:
                        pass
                assert payload is not None, content
                if references:
                    assert json.loads(output["final_output"]) == ([payload, payload] if multiple else payload), output
                    if tool_name == "get_market_candles":
                        assert len(output["final_output"]) > 10_000
                    # The model emitted only IDs, while the binary returned the payload.
                    assert len(output["output"]) < 100
                if tool_name != "compare_trade_routes":
                    assert [entry["ticker"] for entry in payload["results"]] == args["tickers"]
                if kind == "orderly":
                    assert payload["errors"] == [], payload
                    expected = ["PERP_ETH_USDC", "PERP_HOOD_USDC_mythos", "PERP_MSTR_USDC_mythos", "PERP_XAU_USDC", "PERP_1000BONK_USDC"]
                    for row, symbol in zip(payload["results"], expected):
                        assert [m["symbol"] for m in row["markets"] if m["venue"] == "orderly"] == [symbol], row
                elif kind == "aliases":
                    commands = (fixtures / "commands").read_text()
                    if tool_name == "discover_markets":
                        assert payload["errors"] == [], payload
                        expected = [{("aster", "SKHYNIXUSDT"), ("hyperliquid", "xyz:SKHX"), ("lighter", "SKHYNIXUSD")},
                                    {("aster", "SAMSUNGUSDT"), ("hyperliquid", "xyz:SMSN"), ("lighter", "SAMSUNGUSD")}]
                        assert [{(m["venue"], m["symbol"]) for m in r["markets"]} for r in payload["results"]] == expected, payload
                        assert next(m for m in payload["results"][0]["markets"] if m["venue"] == "hyperliquid")["assetId"] == 110003
                        assert next(m for m in payload["results"][0]["markets"] if m["venue"] == "lighter")["marketId"] == 161
                    elif tool_name == "get_market_candles":
                        assert payload["errors"] == [], payload["errors"]
                        for entry, venue, symbol in zip(payload["results"], ["hyperliquid", "lighter"], ["xyz:SKHX", "SAMSUNGUSD"]):
                            source = json.loads((home / f".fx/market-cache/v1/candle-source-{entry['ticker']}.jsonl").read_text().splitlines()[-1])
                            assert source["venue"] == venue and source["symbol"] == symbol, source
                            assert entry["quote"] == "USDC" and entry["lastTrade"]["price"] == 102, entry
                            for frame in entry["timeframes"].values():
                                assert len(frame["closed"]) == 50 and frame["closed"][0][1:] == [100, 103, 98, 102, 12], frame
                        assert "--coin xyz:SKHX " in commands and '"coin":"xyz:SKHX"' in commands, commands
                        assert "market_id=162" in commands and "market_id=140" not in commands, commands
                    else:
                        assert payload["bestRoute"]["venue"] == "lighter" and payload["bestRoute"]["symbol"] == "SKHYNIXUSD", payload
                        assert payload["bestRoute"]["marketId"] == 161, payload
                        lighter = next(m for m in payload["markets"] if m["venue"] == "lighter")
                        assert lighter["openInterest"]["value"] == 500 and lighter["markPrice"] == 100, lighter
                        assert "--market SKHYNIXUSD --market-type perp" in commands, commands
                        assert any("xyz:SKHX" in gap and "HIP-3" in gap for gap in payload["gaps"]), payload
                elif tool_name == "discover_markets":
                    assert {market["venue"] for entry in payload["results"] for market in entry["markets"]} == {"aster", "binance", "bitget", "gate", "hyperliquid", "kraken", "okx-cex"}, payload
                    assert "lighter" in calls
                    assert bool(payload["errors"]) == (kind == "partial"), payload
                elif tool_name == "compare_trade_routes" and kind == "evm":
                    routes = [r for r in payload["rankedRoutes"] if r.get("chain")]
                    assert {r["provider"] for r in routes} == {"pancakeswap", "uniswap"}, payload
                    assert all(r["effectivePrice"] > 0 and r["gas"] > 0 and r["route"] for r in routes), payload
                    assert all("approval" in r["feeNote"] for r in routes), payload
                    pancake = next(r for r in routes if r["provider"] == "pancakeswap")
                    assert pancake["route"]["protocol"] == "v3" and pancake["route"]["fees"] == [2500], pancake
                    assert len(pancake["route"]["path"]) == 2, pancake
                    assert payload["bestRoute"]["chain"] == "bnb", payload
                elif tool_name == "compare_trade_routes" and kind == "snapshot":
                    assert payload["bestRoute"] is None and payload["rankedRoutes"] == [], payload
                    assert len(payload["markets"]) >= 7, payload
                    assert all("entryEstimate" not in m and "nativeBook" not in m for m in payload["markets"]), payload
                    by_venue = {m["venue"]: m for m in payload["markets"]}
                    assert by_venue["bitget"]["funding"]["value"] == 0, payload
                    assert by_venue["okx-cex"]["openInterest"]["usdValue"] == 10000, payload
                    assert by_venue["gate"]["book"]["bestBid"] == 99, payload
                    kraken_linear = next(m for m in payload["markets"] if m["venue"] == "kraken" and m["symbol"] == "PF_XBTUSD")
                    assert kraken_linear["funding"]["value"] == -0.000003, payload
                    assert kraken_linear["funding"]["unit"] == "ratio", payload
                    assert "snapshot-kraken-funding" in calls, calls
                    assert "route-rates" not in calls, calls
                elif tool_name == "compare_trade_routes":
                    if kind == "inverse":
                        inverse = next(m for m in payload["markets"] if m["symbol"] == "PI_XBTUSD")
                        assert inverse["book"]["status"] == "available", inverse
                        assert inverse["funding"]["unit"] == "ratio", inverse
                        assert inverse["entryEstimate"]["contracts"] == 1000, inverse
                        assert inverse["entryEstimate"]["settlementFee"] == 0.005, inverse
                    if kind == "gate_fractional":
                        gate = next(m for m in payload["markets"] if m["venue"] == "gate")
                        assert gate["entryEstimate"]["status"] == "available", gate
                        assert abs(gate["entryEstimate"]["quantity"] - 0.00003) < 1e-12, gate
                    assert all("nativeBook" not in m for m in payload["markets"]), payload
                    assert any(m.get("entryEstimate", {}).get("estimatedFillPrice") for m in payload["markets"]), payload
                    for market in payload["markets"]:
                        estimate = market.get("entryEstimate", {})
                        if estimate.get("status") == "available":
                            assert estimate["quantityUnit"] == "underlying", market
                            assert estimate["underlying"] == market["underlying"], market
                            assert estimate["exposureMultiplier"] == market["exposureMultiplier"], market
                            assert estimate["priceUnit"] == "reference_currency_per_underlying", market
                    route = payload["bestRoute"]
                    assert route["venue"] and route["symbol"] and route["product"] == "perp", payload
                    assert set(route) <= {"venue", "symbol", "product", "category", "assetId", "pairId", "dex", "marketId", "assetClass", "settlementAsset", "contractType"}, payload
                    ranked = payload["rankedRoutes"]
                    assert ranked and ranked[0] == {**route, "costRank": 1}, payload
                    assert len({r["venue"] for r in ranked}) == len(ranked), payload
                    assert [r["costRank"] for r in ranked] == sorted(r["costRank"] for r in ranked), payload
                    assert all(set(r) <= set(route) | {"costRank", "category", "assetId", "pairId", "dex", "marketId", "assetClass", "settlementAsset", "contractType"} for r in ranked), payload
                    configured = [r for r in ranked if r["venue"] in {"binance", "hyperliquid"}]
                    assert len(configured) == 2 and configured[0]["costRank"] <= configured[1]["costRank"], payload
                    assert isinstance(payload["gaps"], list) and all(isinstance(gap, str) for gap in payload["gaps"]), payload
                    assert not any(c in calls for c in ("route-no-asset", "route-rh", "route-networks")), calls
                    commands = (fixtures / "commands").read_text().splitlines()
                    books = [c for c in commands if c.startswith("binance-cli:") and "order-book" in c]
                    assert any("--symbol BTCUSDT " in c for c in books) == (kind != "quote_usdc"), books
                    assert any("--symbol BTCUSDC " in c for c in books) == (kind in ("quote_usdc", "quote_all")), books
                    assert "route-hl" in calls, calls
                    assert ("route-kraken" in calls) == (kind != "quote_usdc"), calls
                else:
                    for entry in payload["results"]:
                        assert "source" not in entry and "markets" not in entry
                        assert entry["quote"] == "USDT" and entry["lastTrade"]["price"] == 102, entry
                        assert isinstance(entry["asOf"], str) and entry["asOf"].endswith("Z"), entry
                        assert isinstance(entry["lastTrade"]["time"], str) and entry["lastTrade"]["time"].endswith("Z"), entry
                        assert set(entry["timeframes"]) == {"15m", "1h", "4h"}
                        for frame in entry["timeframes"].values():
                            assert len(frame["closed"]) == 50 and len(frame["current"]) == 6, frame
                            assert all(isinstance(row[0], str) and row[0].endswith("Z") for row in frame["closed"] + [frame["current"]]), frame
                    assert calls.count("binance-futures") == 1, calls
                    assert calls.count("candles-15m") == 2, calls
                    for ticker in ("BTC", "CRCL"):
                        source = json.loads((home / f".fx/market-cache/v1/candle-source-{ticker}.jsonl").read_text().splitlines()[-1])
                        assert source["venue"] == "binance" and source["volumeUSD"] == 990000, source
            print(f"Registered {tool_name}: {kind}, references={references}, multiple={multiple} passed; final={len(output['final_output'])} bytes")
        finally:
            server.shutdown()
            server.server_close()
            thread.join()
            marker.unlink(missing_ok=True)


for case in ("success", "partial", "invalid", "denied"):
    exercise(case)

for tool_name in ("discover_markets", "get_market_candles", "compare_trade_routes"):
    exercise("aliases", tool_name)

for case in ("success", "partial", "invalid", "denied"):
    exercise(case, "get_market_candles")

for case in ("success", "gate_fractional", "quote_usdc", "quote_all", "currency_usdc", "invalid", "invalid_quote", "denied"):
    exercise(case, "compare_trade_routes")

exercise("success", references=True)
exercise("partial", references=True)
exercise("success", "get_market_candles", references=True)
exercise("success", "compare_trade_routes", references=True)
exercise("success", references=True, multiple=True)

exercise("snapshot", "compare_trade_routes")

(fixtures / "orderly.json").write_text(json.dumps([
    {"symbol": symbol, "status": "ACTIVE"} for symbol in
    ["PERP_ETH_USDC", "PERP_HOOD_USDC_mythos", "PERP_MSTR_USDC_mythos", "PERP_XAU_USDC", "PERP_1000BONK_USDC"]
]))
exercise("orderly")

# An active inverse instrument must exercise the real quote-contract path.
originals = {name: (fixtures / name).read_text() for name in ("kraken-perp.json", "route-kraken.json")}
try:
    instruments = json.loads(originals["kraken-perp.json"])
    for instrument in instruments["instruments"]:
        if instrument["symbol"] == "PI_XBTUSD":
            instrument.update(postOnly=False, contractSize=1, contractValueTradePrecision=0)
    (fixtures / "kraken-perp.json").write_text(json.dumps(instruments))
    (fixtures / "route-kraken.json").write_text(json.dumps({"result":"success", "orderBook":{"asks":[[100,10000]],"bids":[[99,10000]]}}))
    exercise("inverse", "compare_trade_routes")
finally:
    for name, content in originals.items():
        (fixtures / name).write_text(content)

# Exercise the embedded EVM workers through the registered binary tool, not only sourced shell functions.
import time
assets = json.loads((fixtures / "binance-assets.json").read_text())
for asset in assets["data"]:
    asset["ml"] = 1
(fixtures / "binance-assets.json").write_text(json.dumps(assets))
(fixtures / "route-networks.json").write_text(json.dumps({"data": [{"coin": "CRCLB", "networkList": [{"network": "BSC", "contractAddress": "0x" + "1" * 40}]}]}))
(fixtures / "route-rh.json").write_text(json.dumps({"assets": [{"tokenSymbol": "CRCL", "status": "ASSET_STATUS_ACTIVE", "currentMultiplier": 1, "deployments": [{"chainId": 4663, "contractAddress": "0x" + "2" * 40}]}]}))
stats = json.loads((fixtures / "stats-binance-spot.json").read_text())
books = json.loads((fixtures / "route-rates.json").read_text())
for symbol, price in [("BNBUSDT", 500), ("ETHUSDT", 2000)]:
    stats.append({"symbol": symbol, "count": 100, "closeTime": int(time.time() * 1000)})
    books.append({"symbol": symbol, "bidPrice": str(price), "askPrice": str(price), "bidQty": "10", "askQty": "10"})
(fixtures / "stats-binance-spot.json").write_text(json.dumps(stats))
(fixtures / "route-rates.json").write_text(json.dumps(books))
kraken_pairs = json.loads((fixtures / "kraken-spot.json").read_text())
kraken_pairs["USDGUSD"] = {"altname": "USDGUSD", "wsname": "USDG/USD", "base": "USDG", "status": "online", "aclass_base": "currency"}
(fixtures / "kraken-spot.json").write_text(json.dumps(kraken_pairs))
kraken_prices = json.loads((fixtures / "stats-kraken.json").read_text())
kraken_prices["USDGUSD"] = {"a": ["1.002"], "b": ["1"], "v": ["1", "10"]}
(fixtures / "stats-kraken.json").write_text(json.dumps(kraken_prices))
exercise("evm", "compare_trade_routes")
