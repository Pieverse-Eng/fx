"""Fixed AgentKey HTTP workflow for a host-issued research capability.

No wallet configuration, upstream key, redirects, retries or arbitrary endpoints.
The platform enforces operation scope and the cumulative per-run credit ceiling.
"""
import json
import os
import re
import sys
import urllib.error
import urllib.request
from decimal import Decimal

MAX_BYTES = 1024 * 1024


class ContractError(Exception):
    def __init__(self, detail):
        self.detail = detail


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def credits(value):
    if not isinstance(value, str) or len(value) > 20 or not re.fullmatch(r"\d+(?:\.\d{1,6})?", value):
        raise ContractError({"code": "INVALID_MAX_CREDITS"})
    return Decimal(value)


def request(base, token, path, body=None, executing=False):
    req = urllib.request.Request(base + path,
        data=None if body is None else json.dumps(body, separators=(",", ":")).encode(),
        headers={"Content-Type": "application/json", "X-Pieverse-AgentKey-Research": token},
        method="GET" if body is None else "POST")
    request_id = None
    try:
        # No proxy environment or redirect can carry the capability elsewhere.
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        with opener.open(req, timeout=100 if executing else 30) as response:
            request_id = response.headers.get("X-AgentKey-Request-Id")
            raw = response.read(MAX_BYTES + 1)
            if len(raw) > MAX_BYTES:
                raise ValueError("Response exceeds limit")
            return json.loads(raw)
    except urllib.error.HTTPError as error:
        request_id = error.headers.get("X-AgentKey-Request-Id")
        raw = error.read(MAX_BYTES + 1)
        try:
            detail = json.loads(raw) if len(raw) <= MAX_BYTES else {}
            if not isinstance(detail, dict): detail = {}
        except ValueError:
            detail = {}
        raise ContractError({"code": detail.get("code", "AGENTKEY_HTTP_ERROR"), "status": error.code,
            "error": detail.get("error"), "requestId": request_id,
            "executionAttempted": executing, "automaticRetry": False}) from None
    except (OSError, ValueError) as error:
        raise ContractError({"code": "AGENTKEY_EXECUTION_UNCERTAIN" if executing else "AGENTKEY_REQUEST_FAILED",
            "requestId": request_id, "executionAttempted": executing, "automaticRetry": False}) from error


def run(operation, args):
    base = os.environ.get("FX_AGENTKEY_BASE_URL", "").rstrip("/")
    token = os.environ.get("FX_AGENTKEY_RESEARCH_TOKEN", "")
    if not base or not token:
        raise ContractError({"code": "AGENTKEY_RESEARCH_NOT_CONFIGURED"})
    if operation == "discover":
        return request(base, token, "/discover", args)
    if operation == "describe":
        return request(base, token, "/describe", args)
    if operation == "request":
        return request(base, token, "/requests/" + args["requestId"])
    try:
        params = json.loads(args["params_json"])
        if not isinstance(params, (dict, list)):
            raise ValueError()
    except (TypeError, ValueError):
        raise ContractError({"code": "AGENTKEY_INVALID_PARAMS", "executionAttempted": False}) from None
    quote = request(base, token, "/describe", {"name": args["name"]})
    try:
        name = quote["execute_as"]["name"]
        version = quote["price"]["version"]
        price = quote["price"]["credits"]
        if not isinstance(name, str) or not re.fullmatch(r"ak-v1-[a-f0-9]{64}", version):
            raise ValueError()
        ceiling = args.get("maxCredits", price)
        if credits(price) > credits(ceiling):
            raise ContractError({"code": "AGENTKEY_PRICE_EXCEEDS_LIMIT", "executionAttempted": False})
    except (KeyError, TypeError, ValueError):
        raise ContractError({"code": "AGENTKEY_INVALID_QUOTE", "executionAttempted": False}) from None
    return request(base, token, "/execute", {"name": name, "params": params,
        "priceVersion": version, "maxCredits": ceiling}, executing=True)


if __name__ == "__main__":
    try:
        result = run(sys.argv[1], json.loads(sys.argv[2]))
    except ContractError as error:
        result = error.detail
    json.dump(result, sys.stdout, separators=(",", ":"), allow_nan=False)
