# OKX CEX market discovery

Run the bundled helper using this skill's absolute directory:

```bash
bash <skill-dir>/scripts/okx-markets.sh CRCL
bash <skill-dir>/scripts/okx-markets.sh BTC --quote USDC --product spot
bash <skill-dir>/scripts/okx-markets.sh BTC --quote ALL
```

Unless the caller specifies a quote currency or requests all available quote currencies, omit `--quote`; the script defaults to USDT. Pass `--quote <CURRENCY>` for a caller-specified quote or `--quote ALL` for all quotes. `--product` accepts `spot`, `perpetual`, or `all` (default).

Scope is OKX global public Spot and linear SWAP markets. Inverse swaps, dated futures, options, and DEX routes are not covered. The script reuses `okx market filter`, `instruments-by-category`, and `instruments` with `jq`; it requires Bash 4+ and GNU timeout. No CLI upgrade is required from 1.4.4.

Independent Spot, SWAP, and category-3 Spot discovery queries run concurrently. Exact instrument metadata supplies live state and trading specifications. Stock token Spot can use a different base currency: CRCL is the underlying ticker, while XCRCL-USDT has baseCcy XCRCL. The X-prefixed candidate is accepted only from actual category-3 Spot metadata; never infer a listing from a constructed symbol or strip X from ordinary crypto assets.

Return exact `markets[].symbol` and distinguish stock token Spot from ordinary shares and perpetuals. Preserve product, quote, state, and returned trading specifications. State the quote scope; no USDT match does not establish absence under other quote currencies.

Check `errors` even when markets are returned. Failed queries, malformed responses, or a filter total larger than its returned rows mean unresolved coverage, not absence. The helper exits nonzero with partial results on query errors. Only live markets are returned; public availability does not establish account eligibility or execution readiness.
