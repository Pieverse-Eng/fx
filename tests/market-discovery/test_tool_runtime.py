"""Exercise the registered tool with a local gateway and fixture venue CLIs."""
import json
import os
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

binary = str(Path(sys.argv[1]).resolve())
fixtures = Path(sys.argv[2]).resolve()


def exercise(kind, tool_name="discover_markets"):
    with tempfile.TemporaryDirectory(prefix="fx-discovery-runtime-") as directory:
        home = Path(directory)
        (home / ".fx").mkdir()
        (home / ".fx.json").write_text(json.dumps({"context": True, "max_tool_result_bytes": 32768}))
        if kind == "denied":
            (home / ".fx/settings.json").write_text(json.dumps({"permission": {tool_name: "deny"}}))
        requests = []
        failures = []
        args = {"tickers": ["BTC", "CRCL"]}
        if kind == "invalid":
            args["venues"] = ["binance"]
        (fixtures / "calls").write_text("")
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
                            assert set(schema["properties"]) == ({"tickers", "product", "quote"} if tool_name == "discover_markets" else {"tickers"}), schema
                            assert schema["required"] == ["tickers"]
                        delta = {"role": "assistant", "tool_calls": [{"index": 0, "id": "discovery-1", "type": "function", "function": {"name": tool_name, "arguments": json.dumps(args)}}]}
                        reason = "tool_calls"
                    else:
                        delta = {"role": "assistant", "content": "DISCOVERY_TEST_OK"}
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
        try:
            result = subprocess.run([binary, "ask", "--auto", "--json", "--no-save", "--", "Find available BTC and CRCL markets."], cwd=home, env=env, text=True, capture_output=True, timeout=40)
            assert not failures, failures
            assert result.returncode == 0, (result.returncode, result.stderr)
            assert not any(text in result.stderr.lower() for text in ("panic:", "segmentation fault", "error:", "assertion failed")), result.stderr
            assert len(requests) == 2, requests
            output = json.loads(result.stdout)
            assert output["output"].strip() == "DISCOVERY_TEST_OK", output
            assert [call["name"] for call in output["tool_calls"]] == [tool_name], output
            calls = (fixtures / "calls").read_text().splitlines()
            if kind in ("invalid", "denied"):
                assert not calls, calls
            else:
                if tool_name == "discover_markets":
                    assert len(calls) == 19 and len(set(calls)) == 19, calls
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
                        if isinstance(candidate, dict) and set(candidate) == ({"results", "errors"} if tool_name == "discover_markets" else {"columns", "results", "errors"}):
                            payload = candidate
                            break
                    except ValueError:
                        pass
                assert payload is not None, content
                assert [entry["ticker"] for entry in payload["results"]] == ["BTC", "CRCL"]
                if tool_name == "discover_markets":
                    assert {market["venue"] for entry in payload["results"] for market in entry["markets"]} == {"aster", "binance", "bitget", "gate", "hyperliquid", "kraken", "okx-cex"}, payload
                    assert "lighter" in calls
                    assert bool(payload["errors"]) == (kind == "partial"), payload
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
            print(f"Registered {tool_name}: {kind} passed")
        finally:
            server.shutdown()
            server.server_close()
            thread.join()
            marker.unlink(missing_ok=True)


for case in ("success", "partial", "invalid", "denied"):
    exercise(case)

for case in ("success", "partial", "invalid", "denied"):
    exercise(case, "get_market_candles")
