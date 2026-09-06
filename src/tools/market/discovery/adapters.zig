const std = @import("std");
const t = @import("types.zig");
const s = t.string;
const f = t.field;
pub const Context = struct {
    alloc: t.Allocator,
    request: t.Request,
    catalogs: []const t.Catalog,
    markets: std.ArrayList(t.Market) = .empty,
    gaps: std.ArrayList(t.Gap) = .empty,
    pub fn catalog(self: *Context, source: t.Source) ?t.Value {
        for (self.catalogs) |c| if (c.source == source and c.failure == null) return c.data;
        return null;
    }
    fn stock(self: *Context, ticker: []const u8) bool {
        if (self.catalog(.kraken_assets)) |data| if (data == .object) {
            var it = data.object.iterator();
            while (it.next()) |e| {
                const r = e.value_ptr.*;
                if (!t.eq(s(r, "aclass") orelse "", "tokenized_asset") or !t.eq(s(r, "status") orelse "", "enabled")) continue;
                const name = s(r, "altname") orelse continue;
                if (name.len == ticker.len + 1 and name[name.len - 1] == 'x' and t.eq(name[0 .. name.len - 1], ticker)) return true;
            }
        };
        if (self.catalog(.binance_assets)) |data| {
            if (!t.eq(s(data, "code") orelse "", "000000") or t.boolean(data, "success") == false) return false;
            const records = t.records(data, "data") catch return false;
            for (records) |r| if (t.eq(s(r, "uq") orelse "", ticker) and hasTag(r, "bStocks")) return true;
        }
        return false;
    }
    fn match(self: *Context, market: t.Market, base: []const u8, ticker: []const u8) ?[]const u8 {
        const venue = market.venue;
        if (t.eq(base, ticker)) return "underlying";
        if (venue == .kraken and t.eq(ticker, "BTC") and (t.eq(base, "XBT") or t.eq(base, "XXBT"))) return "underlying";
        if (t.eq(ticker, "BTC")) for ([_][]const u8{ "WBTC", "UBTC", "TBTC", "cbBTC" }) |alias| {
            if (t.eq(base, alias)) return "wrapped";
        };
        if (venue == .binance) if (self.catalog(.binance_assets)) |data| {
            if (!t.eq(s(data, "code") orelse "", "000000") or t.boolean(data, "success") == false) return null;
            const records = t.records(data, "data") catch return null;
            for (records) |r| {
                if (t.eq(s(r, "uq") orelse "", ticker) and hasTag(r, "bStocks") and t.boolean(r, "trading") == true and t.boolean(r, "delisted") == false and t.eq(s(r, "assetCode") orelse "", base)) return "tokenized_stock";
            }
        };
        const metadata = market.specifications orelse .null;
        const local_stock = (venue == .bitget and t.eq(s(metadata, "symbolType") orelse "", "stock")) or
            (venue == .@"okx-cex" and t.eq(s(metadata, "instCategory") orelse "", "3")) or
            (venue == .kraken and t.eq(s(metadata, "aclass_base") orelse "", "tokenized_asset"));
        if (!local_stock and !self.stock(ticker)) return null;
        if (venue == .bitget and base.len == ticker.len + 1 and base[0] == 'r' and t.eq(base[1..], ticker)) return "tokenized_stock";
        if (venue == .@"okx-cex" and base.len == ticker.len + 1 and base[0] == 'X' and t.eq(base[1..], ticker)) return "tokenized_stock";
        if (base.len > ticker.len and t.eq(base[0..ticker.len], ticker)) {
            const suffix = base[ticker.len..];
            if ((venue == .kraken or venue == .gate or venue == .hyperliquid) and t.eq(suffix, "X")) return "tokenized_stock";
            if (venue == .gate) {
                if (t.eq(suffix, "ON") or t.eq(suffix, "G")) return "tokenized_stock";
                if (t.eq(suffix, "3L") or t.eq(suffix, "3S")) return "leveraged_token";
            }
        }
        return null;
    }
    fn add(self: *Context, base: []const u8, market: t.Market) !void {
        if (self.request.product != .all and self.request.product != market.product) return;
        for (self.request.pairs) |pair| {
            const ticker = pair.ticker;
            const exposure = self.match(market, base, ticker) orelse continue;
            if (market.quote) |actual| {
                if (!t.eq(actual, pair.quote)) continue;
            } else {
                try self.gaps.append(self.alloc, .{ .ticker = ticker, .quote = pair.quote, .venue = market.venue, .symbol = market.symbol, .reason = "Listing quote currency unavailable; cannot match the requested pair." });
                continue;
            }
            const available = for ([_][]const u8{ "TRADING", "online", "tradable", "active", "live", "post_only", "limit_only", "buyable", "sellable" }) |status| {
                if (t.eq(market.status, status)) break true;
            } else false;
            if (!available) {
                if (market.status.len == 0 or t.eq(market.status, "unknown")) try self.gaps.append(self.alloc, .{ .ticker = ticker, .quote = pair.quote, .venue = market.venue, .symbol = market.symbol, .reason = "Listing trading status is unavailable." });
                continue;
            }
            var value = market;
            value.ticker = ticker;
            value.exposure = exposure;
            if (t.eq(market.status, "post_only")) value.restrictions = &.{"Resting limit orders only; no immediate execution."};
            if (t.eq(market.status, "limit_only")) value.restrictions = &.{"Limit orders only."};
            if (t.eq(market.status, "buyable")) value.restrictions = &.{"Buy orders only."};
            if (t.eq(market.status, "sellable")) value.restrictions = &.{"Sell orders only."};
            if (t.eq(exposure, "leveraged_token")) value.restrictions = &.{"Leveraged token; not equivalent to unleveraged stock exposure."};
            if (value.base == null) value.base = base;
            for (self.markets.items) |existing| {
                if (t.eq(existing.ticker, ticker) and existing.venue == value.venue and existing.product == value.product and std.mem.eql(u8, existing.symbol, value.symbol) and std.mem.eql(u8, existing.marketId orelse "", value.marketId orelse "")) break;
            } else try self.markets.append(self.alloc, value);
        }
    }
};
fn hasTag(r: t.Value, tag: []const u8) bool {
    const tags = t.records(r, "tags") catch return false;
    for (tags) |v| if (v == .string and t.eq(v.string, tag)) return true;
    return false;
}
fn required(r: t.Value, key: []const u8) ![]const u8 {
    return s(r, key) orelse error.MissingListingField;
}
fn normalizeQuote(raw: []const u8) []const u8 {
    if (t.eq(raw, "ZUSD")) return "USD";
    if (t.eq(raw, "ZEUR")) return "EUR";
    if (t.eq(raw, "XXBT") or t.eq(raw, "XBT")) return "BTC";
    if (t.eq(raw, "ZGBP")) return "GBP";
    if (t.eq(raw, "ZJPY")) return "JPY";
    if (t.eq(raw, "ZCAD")) return "CAD";
    if (t.eq(raw, "ZAUD")) return "AUD";
    return raw;
}
fn baseFromPair(pair: []const u8, separator: u8) ![]const u8 {
    const pos = std.mem.findScalar(u8, pair, separator) orelse return error.InvalidListingSymbol;
    return pair[0..pos];
}
fn quotedPair(pair: []const u8, separator: u8) ![]const u8 {
    const pos = std.mem.findScalar(u8, pair, separator) orelse return error.InvalidListingSymbol;
    return pair[pos + 1 ..];
}
pub fn parse(ctx: *Context, c: t.Catalog) !void {
    const data = c.data orelse return error.CatalogUnavailable;
    // Shape/status checks are venue-specific: CLI envelopes differ from HTTP API envelopes.
    switch (c.source) {
        .aster, .binance_spot, .binance_future => try binanceStyle(ctx, c.source, data),
        .binance_assets => {
            if (!t.eq(s(data, "code") orelse "", "000000") or t.boolean(data, "success") == false) return error.ApiError;
            _ = try t.records(data, "data");
        },
        .bitget_spot, .bitget_usdt, .bitget_usdc => try bitget(ctx, c.source, data),
        .gate_spot, .gate_future => try gate(ctx, c.source, data),
        .kraken_assets => {
            if (data != .object or f(data, "error") != null) return error.InvalidCatalogShape;
        },
        .kraken_spot, .kraken_xstocks => try krakenSpot(ctx, data),
        .kraken_future => try krakenFuture(ctx, data),
        .lighter => try lighter(ctx, data),
        .okx_spot, .okx_future => try okx(ctx, data),
        .hyper_dexs => {
            _ = try t.array(data);
        },
        .hyper_perps => try hyperPerps(ctx, data),
        .hyper_spot => try hyperSpot(ctx, data),
    }
}
fn binanceStyle(ctx: *Context, source: t.Source, data: t.Value) !void {
    if (f(data, "code") != null) return error.ApiError;
    for (try t.records(data, "symbols")) |r| {
        const product: t.Product = if (source == .binance_spot) .spot else .future;
        if (product == .spot and t.boolean(r, "isSpotTradingAllowed") != true) continue;
        try ctx.add(try required(r, "baseAsset"), .{
            .ticker = "",
            .venue = t.venue(source),
            .symbol = try required(r, "symbol"),
            .product = product,
            .quote = try required(r, "quoteAsset"),
            .status = try required(r, "status"),
            .contractType = s(r, "contractType"),
            .specifications = try t.subset(ctx.alloc, r, &.{ "filters", "pricePrecision", "quantityPrecision", "marginAsset", "underlyingType", "underlyingSubType", "tags" }),
        });
    }
}
fn bitget(ctx: *Context, source: t.Source, data: t.Value) !void {
    if (f(data, "error") != null or f(data, "code") != null) return error.ApiError;
    const category = switch (source) {
        .bitget_spot => "SPOT",
        .bitget_usdt => "USDT-FUTURES",
        .bitget_usdc => "USDC-FUTURES",
        else => unreachable,
    };
    for (try t.records(data, "data")) |r| {
        if (!t.eq(try required(r, "category"), category)) return error.UnexpectedProduct;
        try ctx.add(try required(r, "baseCoin"), .{
            .ticker = "",
            .venue = .bitget,
            .symbol = try required(r, "symbol"),
            .product = if (source == .bitget_spot) .spot else .future,
            .quote = try required(r, "quoteCoin"),
            .status = try required(r, "status"),
            .contractType = s(r, "type"),
            .specifications = try t.subset(ctx.alloc, r, &.{ "minOrderQty", "minOrderAmount", "pricePrecision", "quantityPrecision", "takerFeeRate", "makerFeeRate", "symbolType", "isRwa" }),
        });
    }
}
fn gate(ctx: *Context, source: t.Source, data: t.Value) !void {
    for (try t.array(data)) |r| {
        const spot = source == .gate_spot;
        const symbol = try required(r, if (spot) "id" else "name");
        const base = if (spot) try required(r, "base") else try baseFromPair(symbol, '_');
        // Direct contract catalogs have no separate underlying field. Match complete base tokens, not substrings.
        try ctx.add(base, .{
            .ticker = "",
            .venue = .gate,
            .symbol = symbol,
            .product = if (spot) .spot else .future,
            .quote = if (spot) try required(r, "quote") else try quotedPair(symbol, '_'),
            .status = if (t.boolean(r, "in_delisting") == true) "delisting" else try required(r, if (spot) "trade_status" else "status"),
            .contractType = if (spot) null else "perpetual",
            .specifications = try t.subset(ctx.alloc, r, &.{ "base_name", "min_base_amount", "min_quote_amount", "amount_precision", "precision", "fee", "quanto_multiplier", "order_price_round", "order_size_min", "taker_fee_rate", "type" }),
        });
    }
}
fn krakenSpot(ctx: *Context, data: t.Value) !void {
    if (data != .object or f(data, "error") != null) return error.InvalidCatalogShape;
    var it = data.object.iterator();
    while (it.next()) |entry| {
        const r = entry.value_ptr.*;
        const base = if (s(r, "wsname")) |pair| try baseFromPair(pair, '/') else try required(r, "base");
        try ctx.add(base, .{
            .ticker = "",
            .venue = .kraken,
            .symbol = try required(r, "altname"),
            .product = .spot,
            .quote = normalizeQuote(try required(r, "quote")),
            .status = try required(r, "status"),
            .specifications = try t.subset(ctx.alloc, r, &.{ "wsname", "ordermin", "costmin", "tick_size", "lot_decimals", "pair_decimals", "fees", "aclass_base", "execution_venue" }),
        });
    }
}
fn krakenFuture(ctx: *Context, data: t.Value) !void {
    if (!t.eq(s(data, "result") orelse "", "success")) return error.ApiError;
    for (try t.records(data, "instruments")) |r| {
        const symbol = try required(r, "symbol");
        const status = if (t.boolean(r, "isExpired") == true or t.boolean(r, "tradeable") == false) "inactive" else if (t.boolean(r, "isExpired") == false and t.boolean(r, "tradeable") == true) "active" else "unknown";
        try ctx.add(try required(r, "base"), .{
            .ticker = "",
            .venue = .kraken,
            .symbol = symbol,
            .product = .future,
            .quote = try required(r, "quote"),
            .status = status,
            .contractType = if (std.mem.startsWith(u8, symbol, "PF_") or std.mem.startsWith(u8, symbol, "PI_")) "perpetual" else "delivery",
            .specifications = try t.subset(ctx.alloc, r, &.{ "type", "contractSize", "tickSize", "contractValueTradePrecision", "lastTradingTime", "openingDate" }),
        });
    }
}
fn lighter(ctx: *Context, data: t.Value) !void {
    if (t.integer(data, "code") != 200) return error.ApiError;
    for (try t.records(data, "order_books")) |r| {
        const kind = try required(r, "market_type");
        if (!t.eq(kind, "spot") and !t.eq(kind, "perp")) return error.UnexpectedProduct;
        const spot = t.eq(kind, "spot");
        const symbol = try required(r, "symbol");
        const base = if (spot) try baseFromPair(symbol, '/') else symbol;
        try ctx.add(base, .{
            .ticker = "",
            .venue = .lighter,
            .symbol = symbol,
            .product = if (spot) .spot else .future,
            // purr queries Lighter mainnet, whose perpetual quote asset is USDC:
            // https://apidocs.lighter.xyz/docs/trading (Handle price and size).
            // This is a product rule, not a mapping of the catalog's placeholder asset IDs.
            .quote = if (spot) try quotedPair(symbol, '/') else "USDC",
            .status = try required(r, "status"),
            .marketId = try t.text(ctx.alloc, f(r, "market_id") orelse return error.MissingListingField),
            .contractType = if (spot) null else "perpetual",
            .specifications = try t.subset(ctx.alloc, r, &.{ "base_asset_id", "quote_asset_id", "min_base_amount", "min_quote_amount", "supported_size_decimals", "supported_price_decimals", "taker_fee", "maker_fee", "multiplier" }),
        });
    }
}
fn okx(ctx: *Context, data: t.Value) !void {
    for (try t.array(data)) |r| {
        // Preopen entries can omit product fields; they are not available markets.
        if (!t.eq(try required(r, "state"), "live")) continue;
        const kind = try required(r, "instType");
        if (!t.eq(kind, "SPOT") and !t.eq(kind, "SWAP")) return error.UnexpectedProduct;
        const spot = t.eq(kind, "SPOT");
        const base = if (spot) try required(r, "baseCcy") else try baseFromPair(try required(r, "instFamily"), '-');
        const quote = if (spot) try required(r, "quoteCcy") else try quotedPair(try required(r, "instFamily"), '-');
        try ctx.add(base, .{
            .ticker = "",
            .venue = .@"okx-cex",
            .symbol = try required(r, "instId"),
            .product = if (spot) .spot else .future,
            .quote = quote,
            .status = try required(r, "state"),
            .contractType = if (spot) null else "perpetual",
            .specifications = try t.subset(ctx.alloc, r, &.{ "instFamily", "ctType", "ctVal", "ctValCcy", "settleCcy", "minSz", "lotSz", "tickSz", "instCategory" }),
        });
    }
}
fn hyperPerps(ctx: *Context, data: t.Value) !void {
    const metas = try t.array(data);
    const dexs = try t.array(ctx.catalog(.hyper_dexs) orelse return error.MissingDexCatalog);
    if (metas.len != dexs.len) return error.InconsistentDexCatalogs;
    for (metas, 0..) |meta, dex_index| {
        if (dex_index > 0 and s(dexs[dex_index], "name") == null) return error.MissingDexIdentity;
        const quote: ?[]const u8 = if (t.integer(meta, "collateralToken")) |id| blk: {
            if (ctx.catalog(.hyper_spot)) |spot| {
                for (try t.records(spot, "tokens")) |token| if (t.integer(token, "index") == id) break :blk s(token, "name");
            }
            break :blk null;
        } else null;
        for (try t.records(meta, "universe"), 0..) |r, index| {
            const symbol = try required(r, "name");
            const pos = std.mem.findScalar(u8, symbol, ':');
            const base = if (pos) |n| symbol[n + 1 ..] else symbol;
            try ctx.add(base, .{
                .ticker = "",
                .venue = .hyperliquid,
                .symbol = symbol,
                .product = .future,
                .quote = quote,
                .status = if (t.boolean(r, "isDelisted") == true) "inactive" else "active",
                .contractType = "perpetual",
                .assetId = if (dex_index == 0) index else 100000 + dex_index * 10000 + index,
                .specifications = try t.subset(ctx.alloc, r, &.{ "szDecimals", "maxLeverage", "onlyIsolated" }),
            });
        }
    }
}
fn tokenById(tokens: []const t.Value, id: usize) ?t.Value {
    for (tokens) |token| if (t.integer(token, "index") == id) return token;
    return null;
}
fn hyperSpot(ctx: *Context, data: t.Value) !void {
    const tokens = try t.records(data, "tokens");
    for (try t.records(data, "universe")) |r| {
        const ids = try t.records(r, "tokens");
        if (ids.len != 2 or ids[0] != .integer or ids[1] != .integer or ids[0].integer < 0 or ids[1].integer < 0) return error.InvalidSpotTokenIds;
        const base = tokenById(tokens, @intCast(ids[0].integer)) orelse return error.MissingSpotToken;
        const quote = tokenById(tokens, @intCast(ids[1].integer)) orelse return error.MissingSpotToken;
        const base_name = try required(base, "name");
        try ctx.add(base_name, .{
            .ticker = "",
            .venue = .hyperliquid,
            .symbol = try std.fmt.allocPrint(ctx.alloc, "{s}/{s}", .{ base_name, try required(quote, "name") }),
            .product = .spot,
            .quote = try required(quote, "name"),
            .status = "active",
            .marketId = try required(r, "name"),
            .assetId = 10000 + (t.integer(r, "index") orelse return error.MissingListingField),
            .specifications = try t.subset(ctx.alloc, base, &.{ "fullName", "szDecimals", "weiDecimals", "evmContract" }),
        });
    }
}
