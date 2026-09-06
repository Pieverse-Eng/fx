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

- `results`: one entry per input ticker, containing matching markets with the venue, exact symbol, product, trading state, and supplied specifications. Preserve symbols, casing, prefixes, market/asset IDs, and Hyperliquid Spot pair IDs for follow-ups; never invent a BTCUSDC symbol for a venue that returns BTC.
- `venues`: each venue's scope, public sources, query duration, and complete/incomplete status. A null scope currency means all currencies within that venue's supported products.
- `errors`: query failures or unresolved coverage. Exit code 1 can accompany useful partial results. Report these gaps; an error is not evidence that a market is absent. Empty matches apply only to the reported scope.

Keep products and restrictions distinct. Kraken post_only means resting limit orders only; limit_only, reduce_only, and one-sided markets retain their restrictions. Hyperliquid Spot `listed` means catalog presence, not verified liquidity. Do not combine linear and inverse contracts or leveraged tokens as equivalent exposure. Gate leveraged tokens require their explicit base ticker.

Naming candidates and catalog matches do not independently prove issuer backing or economic equivalence. Retain the supplied asset names/classification and report ambiguity where needed. Do not infer quantity conversion from ticker prefixes or raw multipliers. Availability does not establish liquidity, execution cost, jurisdiction eligibility, or account readiness.

Requires Bash 4+, jq, GNU timeout, and the selected venue CLIs: binance-cli, bgc, gate-cli, kraken, okx, and purr. Aster and Hyperliquid also use curl. Calls access public data only; they do not access wallets or submit orders.
