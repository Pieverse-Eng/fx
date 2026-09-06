# Bitget market discovery

```bash
bash <skill-dir>/scripts/bitget-markets.sh CRCL
bash <skill-dir>/scripts/bitget-markets.sh BTC --quote USDC
bash <skill-dir>/scripts/bitget-markets.sh BTC --quote ALL --product spot
```

Replace `<skill-dir>` with this skill's absolute directory. Default quote: USDT.

The helper runs `bgc market --action instruments --category <CATEGORY>` for independent catalogs in parallel. Scope: SPOT, USDT-FUTURES, and USDC-FUTURES. It queries only futures categories compatible with the requested quote. Coin-margined and dated contracts are outside this helper's scope; ALL includes both supported futures categories and all Spot quotes.

Match official `baseCoin` and `quoteCoin`. Stock Spot may use an r-prefixed base, such as rCRCL, with `symbolType: stock`; retain the actual symbol RCRCLUSDT. Match exact and catalog-listed 1000, 1000000, and 1M denomination candidates. Futures must have `type: perpetual`; USDC contracts may use symbols such as BTCPERP.

Return online markets and explicitly restricted markets (`limit_open`, `limit_close`, `restrictedAPI`) with restrictions. Exclude offline and not-yet-open listed markets. Retain category for later CLI calls and preserve raw price/quantity increments; they are not underlying-asset multipliers.

Official contract: https://www.bitget.com/api-doc/uta/public/Instruments

Unless the caller specifies a quote or requests all quotes, omit `--quote`. Pass an explicit quote with `--quote <CURRENCY>` or disable the filter with `--quote ALL`. `--product` accepts `spot`, `perpetual`, or `all` (default). State the quote and product scope in the answer; do not equate USD, USDT, and USDC.

Preserve exact symbols, product types, restrictions, and supplied order specifications. Naming matches identify catalog candidates, not issuer backing or equivalent economic exposure. Do not infer quantity conversions from ticker prefixes. Check `errors` even when some markets were found: incomplete coverage returns partial results and a nonzero exit code, not a verified absence. Public availability does not establish liquidity, costs, balances, or account readiness. Helpers require Bash 4+, the venue CLI, jq, and GNU timeout; copy the shared `scripts/catalog-common.sh` with them.
