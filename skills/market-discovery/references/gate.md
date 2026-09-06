# Gate market discovery

```bash
bash <skill-dir>/scripts/gate-markets.sh CRCL
bash <skill-dir>/scripts/gate-markets.sh BTC --quote USDC --product spot
bash <skill-dir>/scripts/gate-markets.sh BTC --quote ALL
```

Replace `<skill-dir>` with this skill's absolute directory. Default quote: USDT.

The helper queries `gate-cli cex spot market pairs --format json` and `gate-cli cex futures market contracts --settle usdt --format json` in parallel when both products are requested. Scope: Spot and USDT-settled perpetuals. ALL removes the Spot quote filter but does not expand perpetual settlement coverage. An explicit unsupported perpetual quote is reported as a coverage gap.

Match exact base tickers and catalog-listed denomination prefixes. Stock Spot candidates include X suffixes with xStock names and ON suffixes with Ondo tokenized names. A G-suffix candidate triggers one `gate-cli cex spot market currency --currency <BASE> --format json` lookup; require stocks/gstocks classification. Stock perpetual X-suffix candidates require `contract_type: stocks`. Preserve the exact pair or contract, such as CRCLX_USDT; the same symbol can exist in both Spot and perpetuals.

Do not automatically include leveraged tokens such as CRCL3L or CRCL3S when searching CRCL. They can be queried by their explicit base ticker and are labeled separately. Retain base names, market type, and scheduled delisting times. Tradable Spot is unrestricted; buyable and sellable mean buy-only and sell-only. Untradable Spot and non-trading or delisting perpetuals are excluded.

Official contracts: https://www.gate.com/docs/developers/apiv4/en/spot/ and https://www.gate.com/docs/developers/apiv4/en/futures/

Unless the caller specifies a quote or requests all quotes, omit `--quote`. Pass an explicit quote with `--quote <CURRENCY>` or disable the filter with `--quote ALL`. `--product` accepts `spot`, `perpetual`, or `all` (default). State the quote and product scope in the answer; do not equate USD, USDT, and USDC.

Preserve exact symbols, product types, restrictions, and supplied order specifications. Naming matches identify catalog candidates, not issuer backing or equivalent economic exposure. Do not infer quantity conversions from ticker prefixes. Check `errors` even when some markets were found: incomplete coverage returns partial results and a nonzero exit code, not a verified absence. Public availability does not establish liquidity, costs, balances, or account readiness. Helpers require Bash 4+, the venue CLI, jq, and GNU timeout; copy the shared `scripts/catalog-common.sh` with them.
