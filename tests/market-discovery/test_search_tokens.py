"""Drive the registered token tool through fx ask, with fixture or live public HTTP."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


BINARY = str(Path(sys.argv[1]).resolve())
LIVE = "--live" in sys.argv[2:]
TOKEN = {"name": "Cash Cat", "symbol": "CASHCAT", "chain": "robinhood",
         "contract": "0x020bfC650A365f8BB26819deAAbF3E21291018b4"}


def exercise(kind, arguments):
    with tempfile.TemporaryDirectory(prefix="fx-token-search-") as directory:
        root = Path(directory)
        (root / ".fx").mkdir()
        if kind == "denied":
            (root / ".fx/settings.json").write_text(json.dumps({"permission": {"search_tokens": "deny"}}))
        if not LIVE:
            # Inspect the actual argv after shell expansion and validate the signed HTTP body.
            stub = root / "curl"
            stub.write_text("#!" + sys.executable + "\n" + '''
import hashlib, json, os, sys
from pathlib import Path
args = sys.argv[1:]
assert args[0] == '-q'
assert 'https://copenapi.bgwapi.io/market/v3/coin/search' in args
raw = args[args.index('--data-raw') + 1]
body = json.loads(raw)
headers = dict(args[i+1].split(': ', 1) for i, arg in enumerate(args) if arg == '-H')
signed = 'POST/market/v3/coin/search' + raw + headers['X-TIMESTAMP']
assert headers['X-SIGN'] == '0x' + hashlib.sha256(signed.encode()).hexdigest()
assert headers['token'] == 'toc_agent'
Path('request.json').write_text(raw)
kind = os.environ['TOKEN_TEST_KIND']
if kind == 'transport': sys.exit(28)
if kind == 'malformed':
    print('{')
    sys.exit(0)
if kind == 'provider':
    print('{"status":429,"msg":"rate limited"}')
    sys.exit(0)
first = {"name":"Cash Cat","symbol":"CASHCAT","chain":"robinhood","contract":"0x020bfC650A365f8BB26819deAAbF3E21291018b4","price":123,"icon":"unused"}
second = {"name":"Second","symbol":"CASHCAT","chain":"robinhood","contract":"0xOther"}
print(json.dumps({"status":0,"data":{"list": [] if kind == 'empty' else [first, second]}}))
''')
            stub.chmod(0o755)

        requests, failures = [], []

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
                            spec = tools["search_tokens"]
                            assert "Stocks and stock-linked tokens are out of scope" in spec["description"]
                            assert set(spec["parameters"]["properties"]) == {"query", "chain", "limit"}
                            assert spec["parameters"]["required"] == ["query"]
                        delta = {"role": "assistant", "tool_calls": [{"index": 0, "id": "search-1", "type": "function", "function": {"name": "search_tokens", "arguments": json.dumps(arguments)}}]}
                        reason = "tool_calls"
                    else:
                        delta = {"role": "assistant", "content": "TOKEN_TEST_OK"}
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
        env = {"PATH": ("" if LIVE else str(root) + os.pathsep) + os.environ["PATH"],
               "HOME": str(root), "LANG": "C.UTF-8", "TOKEN_TEST_KIND": kind,
               "FX_PROVIDER": "pieverse", "FX_PIEVERSE_API_KEY": "local-fixture",
               "FX_MODEL": "pieverse/test/model", "FX_DISABLE_KEYCHAIN": "1", "FX_SKIP_ONBOARDING": "1",
               "FX_PIEVERSE_BASE_URL": f"http://127.0.0.1:{server.server_port}/v1"}
        if LIVE:
            for key, value in os.environ.items():
                if key.lower().endswith("_proxy") or key in ("CURL_CA_BUNDLE", "SSL_CERT_FILE", "SSL_CERT_DIR"):
                    env[key] = value
            for key in ("no_proxy", "NO_PROXY"):
                env[key] = env.get(key, "") + ",127.0.0.1,localhost"
        try:
            proc = subprocess.run([BINARY, "ask", "--auto", "--json", "--no-save", "--", "Find the chain and contract for cashcat."], cwd=root, env=env, text=True, capture_output=True, timeout=50)
            assert not failures, failures
            assert proc.returncode == 0, (proc.returncode, proc.stderr)
            assert not any(text in proc.stderr.lower() for text in ("panic:", "segmentation fault", "error:", "assertion failed")), proc.stderr
            assert len(requests) == 2, requests
            output = json.loads(proc.stdout)
            assert output["output"].strip() == "TOKEN_TEST_OK", output
            assert [call["name"] for call in output["tool_calls"]] == ["search_tokens"], output
            content = [m["content"] for m in requests[1]["messages"] if m.get("role") == "tool"][-1]
            if kind in ("invalid", "denied"):
                assert not (root / "request.json").exists()
                assert "results" not in content, content
            elif kind in ("transport", "provider", "malformed"):
                assert "failed" in content.lower(), content
                assert '"results":[]' not in content, content
            else:
                payload = None
                for offset, char in enumerate(content):
                    if char != "{":
                        continue
                    try:
                        candidate, _ = json.JSONDecoder().raw_decode(content[offset:])
                        if isinstance(candidate, dict) and set(candidate) == {"results"}:
                            payload = candidate
                            break
                    except ValueError:
                        pass
                assert payload is not None, content
                results = payload["results"]
                assert len(results) <= arguments.get("limit", 1), payload
                if LIVE:
                    assert results, payload
                    assert all(set(t) == {"name", "symbol", "chain", "contract"} for t in results), payload
                    if "chain" in arguments:
                        assert all(t["chain"] == arguments["chain"] for t in results), payload
                    print("Live result:", json.dumps(payload))
                else:
                    expected_body = {"keyword": arguments["query"], "limit": arguments.get("limit", 1)}
                    if "chain" in arguments:
                        expected_body["chain"] = arguments["chain"]
                    assert json.loads((root / "request.json").read_text()) == expected_body
                    assert not (root / "INJECTED").exists()
                    if kind == "empty":
                        assert results == [], payload
                    else:
                        assert results[0] == TOKEN, payload
                        assert len(results) == arguments.get("limit", 1), payload
            print(f"Registered search_tokens: {kind} passed")
        finally:
            server.shutdown()
            server.server_close()
            thread.join()


exercise("default", {"query": "cashcat"})
exercise("filtered", {"query": "cashcat", "chain": "robinhood", "limit": 2})
if LIVE:
    exercise("bnb", {"query": "marscoin", "chain": "bnb", "limit": 3})
    exercise("sol", {"query": "bonk", "chain": "sol", "limit": 1})
else:
    exercise("escaping", {"query": "Cash Cat';touch INJECTED; $(touch INJECTED) `touch INJECTED`"})
    for case in ("empty", "transport", "provider", "malformed", "denied"):
        exercise(case, {"query": "cashcat"})
    exercise("invalid", {"query": "cashcat", "limit": 0})
