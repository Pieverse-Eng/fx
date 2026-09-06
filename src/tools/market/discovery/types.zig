const std = @import("std");
pub const Allocator = std.mem.Allocator;
pub const Value = std.json.Value;
pub const Product = enum { spot, future, all };
pub const Venue = enum { aster, binance, bitget, gate, hyperliquid, kraken, lighter, @"okx-cex" };
pub const Source = enum {
    aster,
    binance_spot,
    binance_future,
    binance_assets,
    bitget_spot,
    bitget_usdt,
    bitget_usdc,
    gate_spot,
    gate_future,
    kraken_spot,
    kraken_assets,
    kraken_xstocks,
    kraken_future,
    lighter,
    okx_spot,
    okx_future,
    hyper_dexs,
    hyper_perps,
    hyper_spot,
};
pub const Request = struct { tickers: []const []const u8, product: Product, quote: ?[]const u8 = null };
pub const Market = struct {
    ticker: []const u8,
    venue: Venue,
    symbol: []const u8,
    product: Product,
    base: ?[]const u8 = null,
    quote: ?[]const u8 = null,
    status: []const u8,
    marketId: ?[]const u8 = null,
    assetId: ?usize = null,
    contractType: ?[]const u8 = null,
    exposure: []const u8 = "underlying",
    restrictions: []const []const u8 = &.{},
    specifications: ?Value = null,
};
pub const Coverage = struct { venue: Venue, source: Source, status: enum { complete, @"error" }, detail: ?[]const u8 = null };
pub const Gap = struct { ticker: ?[]const u8 = null, venue: ?Venue = null, symbol: ?[]const u8 = null, reason: []const u8 };
pub const Catalog = struct { source: Source, data: ?Value = null, failure: ?[]const u8 = null };
pub const Output = struct {
    markets: []const Market,
    coverage: []const Coverage,
    unresolved: []const Gap,
    checkedAt: i64,
    specificationsOmitted: bool = false,
    // Scope describes adapter coverage, not everything a venue might support.
    scope: []const u8 = "Public spot catalogs and supported futures catalogs: Aster FAPI, Binance USD-M, Bitget USDT/USDC, Gate USDT, Kraken Futures, Hyperliquid all perpetual DEXs, Lighter, OKX SWAP. No direct brokerage stocks, options, or account eligibility checks.",
};
pub fn venue(source: Source) Venue {
    return switch (source) {
        .aster => .aster,
        .binance_spot, .binance_future, .binance_assets => .binance,
        .bitget_spot, .bitget_usdt, .bitget_usdc => .bitget,
        .gate_spot, .gate_future => .gate,
        .kraken_spot, .kraken_assets, .kraken_xstocks, .kraken_future => .kraken,
        .lighter => .lighter,
        .okx_spot, .okx_future => .@"okx-cex",
        .hyper_dexs, .hyper_perps, .hyper_spot => .hyperliquid,
    };
}
pub fn field(v: Value, key: []const u8) ?Value {
    return if (v == .object) v.object.get(key) else null;
}
pub fn string(v: Value, key: []const u8) ?[]const u8 {
    const x = field(v, key) orelse return null;
    return if (x == .string) x.string else null;
}
pub fn boolean(v: Value, key: []const u8) ?bool {
    const x = field(v, key) orelse return null;
    return if (x == .bool) x.bool else null;
}
pub fn integer(v: Value, key: []const u8) ?usize {
    const x = field(v, key) orelse return null;
    return if (x == .integer and x.integer >= 0) @intCast(x.integer) else null;
}
pub fn eq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}
pub fn array(v: Value) ![]const Value {
    if (v != .array) return error.InvalidCatalogShape;
    return v.array.items;
}
pub fn records(v: Value, key: []const u8) ![]const Value {
    return array(field(v, key) orelse return error.MissingCatalogRecords);
}
pub fn text(alloc: Allocator, v: Value) !?[]const u8 {
    return switch (v) {
        .string => v.string,
        .integer => try std.fmt.allocPrint(alloc, "{d}", .{v.integer}),
        else => null,
    };
}
pub fn subset(alloc: Allocator, v: Value, keys: []const []const u8) !?Value {
    var obj: std.json.ObjectMap = .{};
    for (keys) |key| if (field(v, key)) |value| {
        try obj.put(alloc, key, value);
    };
    return if (obj.count() == 0) null else .{ .object = obj };
}
