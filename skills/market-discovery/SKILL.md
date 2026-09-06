---
name: market-discovery
description: Find exact venue trading symbols from base tickers. Currently supports Aster perpetual contracts, with an optional quote-asset filter.
---

# Market discovery

Select the venue reference matching the requested scope and read it before querying. Load only the references needed for the request.

| Venue | Products | Reference |
| --- | --- | --- |
| Aster | Perpetual contracts | [references/aster.md](references/aster.md) |

For requests spanning supported venues, run independent venue queries in parallel and combine their results. Keep unsupported venues or products explicit as coverage gaps.
