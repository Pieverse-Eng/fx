# Lighter market discovery

Use this skill's absolute directory:

```bash
bash <skill-dir>/scripts/lighter-markets.sh BTC
bash <skill-dir>/scripts/lighter-markets.sh ETH --product spot
bash <skill-dir>/scripts/lighter-markets.sh PEPE --quote ALL
```

Unless the caller specifies a currency or requests all currencies, omit `--quote`; the script defaults to USDC. Use `--quote <CURRENCY>` for an explicit currency or `--quote ALL` to remove the filter. For Spot this filters the quote asset; for perpetuals it filters the settlement asset. The current public Lighter mainnet uses USDC settlement for perpetuals. `--product` accepts `spot`, `perpetual`, or `all` (default).

The helper runs `purr lighter markets --market-type all` once and filters the complete public catalog locally. Do not use `--market <TICKER>` for multi-product discovery: the CLI requires a single matching market and can reject a ticker such as ETH as ambiguous. Requires Bash 4+, purr, jq, and GNU timeout; no wallet or integration enablement is needed.

Match candidate base tickers case-insensitively, plus catalog-listed `1000` denomination prefixes for perpetuals. Only `active` records are returned. This is not a general alias or issuer resolver; do not infer backing or quantity conversion from names. The returned multiplier is raw venue metadata, not a derived conversion to the requested underlying.

Preserve exact `symbol` and `marketId`. A perpetual symbol is `BTC`, not an invented `BTCUSDC`; Spot symbols include their quote, such as `ETH/USDC`. Use `--market-id <marketId>` for subsequent Lighter CLI queries to avoid ambiguity. Precision and minimum order fields are retained when supplied by the venue. Perpetual `quoteAsset` is null; `settlementAsset` is USDC under this mainnet contract, not inferred from the catalog's placeholder asset IDs.

State the currency and product scope used. Check `errors`: an unavailable or malformed catalog exits nonzero, not as a verified absence. Availability does not establish liquidity, execution costs, or account readiness.
