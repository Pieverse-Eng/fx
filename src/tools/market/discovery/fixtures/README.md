# Discovery fixtures

`stocks.json` contains selected public catalog records captured on 2026-09-06
for NVDA, TSLA, and AAPL. Unused fields and unrelated listings were removed;
CLI response envelopes were reconstructed around the retained records.

The records exercise all seven CLI adapters, stock aliases, Kraken response-key
aliases, Gate leveraged tokens and xStocks contracts, and product restrictions.
They are historical parser fixtures, not a source of current listings or fees.
Hyperliquid joins and duplicate display names are tested with synthetic catalogs
in `discover_markets.zig`.
