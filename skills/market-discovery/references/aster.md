# Aster perpetuals

Run the bundled script through `shell` using the absolute path to `scripts/aster.py` under the skill root (the directory containing `SKILL.md`, one level above this reference). Requires Python 3 with only its standard library; no credentials or installed venue CLI are needed.

```bash
python3 <skill-directory>/scripts/aster.py exchange-info --base-asset CRCL
python3 <skill-directory>/scripts/aster.py exchange-info --base-asset BTC ETH --quote-asset USDT
```

The script fetches the official contract catalog once, normalizes input tickers to uppercase, and locally matches `baseAsset` exactly. It returns only `PERPETUAL` contracts with `status: TRADING`. An omitted quote filter includes all matching quote assets. Group requested tickers into one invocation.

Use the returned `symbol` unchanged for subsequent venue queries. Output includes the source URL, retrieval time, requested filters, and a `markets` array with contract identity and classification fields. A successful empty array means no active exact-base perpetual matches for these filters. API, network, or malformed-response errors exit nonzero and must be reported as unresolved coverage.

Inputs are venue base tickers, not company names or trading pairs. This script does not resolve aliases or contract multipliers: for example, `PEPE` does not match `1000PEPE`. Do not interpret an empty exact-base search as proof that no related exposure exists. Scope is Aster perpetuals; it does not search Spot or other venues.

The official [`exchangeInfo` endpoint](https://asterdex.github.io/aster-api-website/futures-v3/market-data/#exchange-information) has no documented filter parameters. Fetching and filtering happen inside the script, so the agent does not need to inspect the full catalog.
