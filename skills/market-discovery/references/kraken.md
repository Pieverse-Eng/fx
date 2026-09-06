# Kraken market discovery

```bash
bash <skill-dir>/scripts/kraken-markets.sh CRCL
bash <skill-dir>/scripts/kraken-markets.sh BTC --quote USDT --product spot
bash <skill-dir>/scripts/kraken-markets.sh BTC --quote ALL
```

Replace `<skill-dir>` with this skill's absolute directory. Default quote: USD, covering USD Spot/xStocks and USD-quoted perpetuals. For perpetuals, quote is the contract price denomination, not a claim about accepted collateral or settlement currency.

Independent public queries run in parallel:

- `kraken pairs -o json`: ordinary Spot.
- `kraken pairs --asset-class tokenized_asset -o json`: tokenized Spot.
- `kraken futures instruments -o json`: contract specifications.
- `kraken futures tickers -o json`: current perpetual classification and suspended state.

Match Spot using `wsname` base and quote, but return `altname` exactly, including lowercase x. BTC/XBT and DOGE/XDG are canonical aliases; never strip arbitrary X/Z prefixes from tickers. For tokenized_asset pairs, the lowercase x suffix is a candidate mapping, such as CRCL to CRCLxUSD. Deduplicate identical altname/product/status records returned under alias keys.

Spot online, post_only, limit_only, and reduce_only markets remain visible with their restrictions. Post-only means resting limit orders only. Perpetuals require tradeable, unexpired PF_ or PI_ metadata joined to a non-suspended perpetual ticker. Preserve linear/flexible versus inverse contract types; do not treat them as interchangeable routes. Dated futures are outside the helper's scope. A missing status ticker is unresolved coverage.

Use exact symbols in subsequent commands; for xStocks Spot also supply `--asset-class tokenized_asset`. Preserve venue platform/country restrictions as metadata without deciding account readiness.

Official contracts: https://docs.kraken.com/api-reference/instrument-details/get-instruments and https://docs.kraken.com/api/docs/rest-api/get-tradable-asset-pairs/

Unless the caller specifies a quote or requests all quotes, omit `--quote`. Pass an explicit quote with `--quote <CURRENCY>` or disable the filter with `--quote ALL`. `--product` accepts `spot`, `perpetual`, or `all` (default). State the quote and product scope in the answer; do not equate USD, USDT, and USDC.

Preserve exact symbols, product types, restrictions, and supplied order specifications. Naming matches identify catalog candidates, not issuer backing or equivalent economic exposure. Do not infer quantity conversions from ticker prefixes. Check `errors` even when some markets were found: incomplete coverage returns partial results and a nonzero exit code, not a verified absence. Public availability does not establish liquidity, costs, balances, or account readiness. Helpers require Bash 4+, the venue CLI, jq, and GNU timeout; copy the shared `scripts/catalog-common.sh` with them.
