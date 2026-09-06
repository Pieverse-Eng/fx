---
name: market-discovery
description: Find available markets for asset names or tickers across eight supported trading venues, returning exact trading symbols, products, and restrictions.
---

# Market discovery

Resolve names to candidate base tickers, using the workspace's research-scope rules. Then call the bundled script once with all related tickers. It queries venues concurrently, reuses each catalog across assets, and groups results by ticker. Do not write separate loops for tickers or venues.

Use the absolute skill directory supplied when this skill is loaded:

```bash
bash <skill-dir>/scripts/discover-markets.sh IREN APLD HUT
bash <skill-dir>/scripts/discover-markets.sh BTC ETH --venues binance,hyperliquid
bash <skill-dir>/scripts/discover-markets.sh BTC --product spot --quote USDC
```

## Inputs and scope

- Positional inputs are base tickers, not company names or trading pairs. Matching is case-insensitive; duplicate inputs are queried once.
- `--venues`: comma-separated venue IDs; omitted means all eight. IDs: `aster`, `binance`, `bitget`, `gate`, `hyperliquid`, `kraken`, `lighter`, `okx-cex` (`okx` is also accepted).
- `--product`: `spot`, `perpetual`, or `all` (default). Respect the caller's explicit product constraints.
- `--quote`: an explicit currency, or `ALL` for all currencies within supported products. Omit it unless the caller specifies a currency or requests all currencies; each venue then uses its default below. Never substitute USD, USDT, USDC, or USDT0 for each other.

| Venue | Supported products | Default currency |
| --- | --- | --- |
| Aster | Perpetuals | All quotes |
| Binance | Spot/bStocks, USDⓈ-M perpetuals | USDT |
| Bitget | Spot, USDT/USDC perpetuals | USDT |
| Gate | Spot, USDT-settled perpetuals | USDT |
| Hyperliquid | Spot, native perpetuals, HIP-3 | USDC |
| Kraken | Spot/xStocks, linear and inverse perpetuals | USD |
| Lighter | Spot, perpetuals | USDC |
| OKX CEX | Spot/stock tokens, linear swaps | USDT |

For Hyperliquid perpetuals the currency filter selects collateral; for Lighter perpetuals it selects settlement. For Kraken perpetuals it selects price denomination, not collateral. Spot filters its quote asset. Dated futures and other unlisted product categories are outside this script's coverage. Aster matches exact venue base tickers: PEPE does not automatically match 1000PEPE.

## Results

- `results`: one entry per input ticker. Every market returns `venue`, the exact `symbol`, and `product` (`spot` or `perp`). Preserve symbols, casing, and prefixes; never invent a BTCUSDC symbol for a venue that returns BTC.
- Order routing fields appear only where needed: Bitget `category`; Gate perpetual `settlementAsset`; Hyperliquid `assetId` and applicable `dex`; Kraken xStocks `assetClass`; Lighter `marketId`. Pass `symbol` as OKX `instId`, Gate pair/contract, or the other venue's symbol. Use Hyperliquid `assetId` as `--asset` and Lighter `marketId` as `--market-id`.
- `restrictions` appears only for restricted markets, including post-only, one-sided, and isolated-only trading.
- `errors`: query failures or unresolved coverage, identified by venue. Exit code 1 can accompany useful partial results. Report these gaps; an error is not evidence that a market is absent. Empty matches without errors mean no match within the requested venues/products/currencies and the defaults above, not absence from every market.

The response contains only `results` and `errors`; it does not repeat query scope, venue coverage records, or timestamps.

Keep products and restrictions distinct. Resting limit orders only means post-only; it does not permit immediate execution. Gate leveraged tokens require their explicit base ticker.

This result identifies markets for subsequent venue workflows. Order quantities, prices, and direction come from the caller; current sizing rules and account state belong to the execution workflow. Specifications, precision, minimum amounts, and contract multipliers are not returned. For follow-up data that needs a different identifier, use the venue's market-resolution command. Availability does not establish liquidity, execution cost, jurisdiction eligibility, or account readiness.

Requires Bash 4+, jq, GNU timeout, and the selected venue CLIs: binance-cli, bgc, gate-cli, kraken, okx, and purr. Aster and Hyperliquid also use curl. Calls access public data only; they do not access wallets or submit orders.
