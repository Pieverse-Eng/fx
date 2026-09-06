# Hyperliquid market discovery

Use this skill's absolute directory:

```bash
bash <skill-dir>/scripts/hyperliquid-markets.sh BTC
bash <skill-dir>/scripts/hyperliquid-markets.sh BTC --quote USDH --product spot
bash <skill-dir>/scripts/hyperliquid-markets.sh CRCL --quote ALL
```

Unless the caller specifies a currency or requests all currencies, omit `--quote`; the script defaults to USDC. For Spot, this filters the quote asset. For perpetuals, it filters the collateral asset, not the oracle price denomination. Pass the caller's currency with `--quote <CURRENCY>`, or `--quote ALL` to disable the filter. Do not silently substitute USDT0 for USDT. `--product` accepts `spot`, `perpetual`, or `all` (default).

The helper reuses `purr hyperliquid search` and `markets` against public mainnet data. Independent initial queries and DEX metadata lookups run concurrently. When search reaches its ten-result cap, public Info `perpDexs` and `allPerpMetas` recover full perpetual coverage. Spot is filtered from the full public catalog. Requires Bash 4+, purr, jq, curl, and GNU timeout; no wallet access or integration enablement is needed.

Inputs are candidate base tickers. Exact names are matched, plus Hyperliquid k-prefixed denomination candidates for perpetuals, U-prefixed Spot names with Unit metadata, and X-suffixed Spot names with xStock metadata. These naming candidates are not a general alias resolver. BTC dominance (BTCD) is not BTC; delisted perpetuals are excluded. Identical tickers alone do not establish issuer backing or equivalence across products; inspect the retained token names and report ambiguity when needed.

Preserve exact `symbol`, `dex`, `assetId`, and `szDecimals`. For Spot, also retain `pairId` (such as @142) for subsequent CLI queries; the symbol may be UBTC/USDC, not BTC/USDC. Spot `status: listed` means catalog presence, not verified liquidity. For perpetuals, `quoteAsset` is null and `collateralAsset` holds the verified collateral currency; never invent a BTCUSDC symbol. Preserve isolated-margin restrictions. Do not infer quantity conversion from ticker prefixes.

State the currency and product scope used. Check `errors` even if some markets were found; failed metadata or incomplete coverage exits nonzero with partial results. No match under USDC does not establish absence under other currencies. This helper discovers markets only; it does not verify balances, liquidity, execution costs, or account readiness.
