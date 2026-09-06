# Binance market discovery

Run the bundled script with a candidate base ticker, using this skill's absolute directory:

```bash
bash <skill-dir>/scripts/binance-markets.sh CRCL
bash <skill-dir>/scripts/binance-markets.sh BTC --quote USDC --product spot
bash <skill-dir>/scripts/binance-markets.sh BTC --quote ALL
```

Unless the caller specifies a quote currency or requests all available quote currencies, omit `--quote`; the script defaults to USDT. When the caller specifies a quote currency, pass `--quote <CURRENCY>`. When the caller requests all quote currencies, pass `--quote ALL`.

`--product` accepts `spot`, `perpetual`, or `all` (default). Upper/lowercase ticker and quote input is accepted. Scope is Spot and USDⓈ-M perpetuals, not COIN-M, dated futures, options, or direct stocks.

State the quote scope in the answer. No matches for one quote currency does not establish absence under other quote currencies.

The script uses existing `binance-cli` and `jq`. It fetches independent catalogs concurrently and filters locally, returning exact symbols rather than full catalogs. Spot uses `exchange-info`; perpetuals use `exchange-information`. For Spot, it also joins the public Binance asset catalog's active bStocks `uq` to `assetCode`, then to Spot `baseAsset`. It never guesses a `B` suffix.

Read `markets`, preserving symbol, product, quote, status, and `representation`. Tokenized stock Spot is not ordinary shares; perpetuals are derivatives. `sources` and `queriedAt` describe the catalog snapshot, not a price quote. Only currently `TRADING` markets are returned.

Both Spot and perpetual discovery match the complete input ticker and candidates prefixed with `1000`, `1000000`, or `1M` against actual catalog base assets. For example, PEPE can return 1000PEPE contracts, and BABYDOGE can return 1MBABYDOGE Spot or contracts. Input prefixes are never stripped; 1INCH and 0G remain complete tickers. Preserve the returned `baseAsset` and symbol: denomination-prefixed markets must not be treated as one unit of the unprefixed asset, and quantity or price conversions require the actual product specifications. These are supported naming candidates, not a general asset-alias resolver.

Check `errors` before claiming absence: a failed catalog leaves that coverage unresolved even when other markets were found. Nonzero exit may still include partial results. An empty successful result means no matching active market within these products and any supplied quote filter. The script does not check balances, account eligibility, quotes, or execution costs.
