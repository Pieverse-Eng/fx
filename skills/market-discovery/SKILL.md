---
name: market-discovery
description: Find where an asset can be traded on supported venues. Use for market availability requests expressed as asset names or tickers. Resolve names to candidate tickers, then follow the relevant venue references.
---

# Market discovery

Resolve supplied asset names to candidate base tickers; use public research when identity is unclear. Then read the relevant venue references and query for exact markets. A candidate ticker alone is not proof of a listing.

For general availability requests without a specified venue, check the supported venues below. Respect explicit venue and product constraints. Distinguish ordinary shares, tokenized assets, and perpetual contracts in the results; a related derivative is not the requested underlying product.

| Venue | Products | Reference |
| --- | --- | --- |
| Aster | Perpetual contracts | [references/aster.md](references/aster.md) |
| Binance | Spot (including bStocks), USDⓈ-M perpetual contracts | [references/binance.md](references/binance.md) |

For requests spanning supported venues, run independent venue queries in parallel and combine their results. Keep unsupported venues or products explicit as coverage gaps.
