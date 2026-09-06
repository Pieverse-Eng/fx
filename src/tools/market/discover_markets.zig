const std = @import("std");
const dispatch = @import("../../core/tooling/tool_dispatch.zig");
const io_mod = @import("../../core/shared/io.zig");
const t = @import("discovery/types.zig");
const adapters = @import("discovery/adapters.zig");
const runner = @import("discovery/runner.zig");
pub const Input = struct {
    arena: std.heap.ArenaAllocator,
    request: t.Request,
};
fn canonical(alloc: t.Allocator, value: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > 16) return error.InvalidTicker;
    const out = try alloc.dupe(u8, trimmed);
    for (out) |*c| {
        if (!std.ascii.isAlphanumeric(c.*) and c.* != '.' and c.* != '-') return error.InvalidTicker;
        c.* = std.ascii.toUpper(c.*);
    }
    return out;
}
pub fn parseRequest(alloc: t.Allocator, json: []const u8) !t.Request {
    const parsed = try std.json.parseFromSlice(t.Value, alloc, json, .{ .allocate = .alloc_always });
    const root = parsed.value;
    if (root != .object) return error.InvalidInput;
    for (root.object.keys()) |key| if (!std.mem.eql(u8, key, "tickers") and !std.mem.eql(u8, key, "product")) return error.UnknownArgument;
    const values = try t.records(root, "tickers");
    if (values.len == 0 or values.len > 8) return error.InvalidTickerCount;
    var pairs: std.ArrayList(t.Pair) = .empty;
    for (values) |v| {
        if (v != .string) return error.InvalidTicker;
        var parts = std.mem.splitScalar(u8, v.string, '/');
        const ticker = try canonical(alloc, parts.first());
        const quote = if (parts.next()) |part| try canonical(alloc, part) else "USDT";
        if (parts.next() != null) return error.InvalidPair;
        for (pairs.items) |old| {
            if (t.eq(old.ticker, ticker) and t.eq(old.quote, quote)) break;
        } else try pairs.append(alloc, .{ .ticker = ticker, .quote = quote });
    }
    const product = if (t.field(root, "product")) |v| blk: {
        if (v != .string) return error.InvalidProduct;
        break :blk std.meta.stringToEnum(t.Product, v.string) orelse return error.InvalidProduct;
    } else .all;
    return .{ .pairs = try pairs.toOwnedSlice(alloc), .product = product };
}
pub fn decode(ctx: dispatch.DispatchContext, json: []const u8) dispatch.DispatchError!dispatch.DecodeResult {
    const input = try ctx.allocator.create(Input);
    input.* = .{ .arena = .init(ctx.allocator), .request = undefined };
    input.request = parseRequest(input.arena.allocator(), json) catch |err| {
        input.arena.deinit();
        ctx.allocator.destroy(input);
        return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "discover_markets: {s}. Supply 1-8 base tickers or BASE/QUOTE pairs (a bare ticker means BASE/USDT), and product spot/future/all.", .{@errorName(err)}) };
    };
    return .{ .input = .{ .ptr = input, .deinit_fn = deinitInput } };
}
fn deinitInput(ptr: *anyopaque, alloc: t.Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.arena.deinit();
    alloc.destroy(input);
}
pub fn validate(_: dispatch.DispatchContext, _: dispatch.ToolInput) dispatch.DispatchError!?[]u8 {
    return null;
}
pub fn readsOnly(_: dispatch.ToolInput) bool {
    return true;
}
pub fn isIrreversible(_: dispatch.ToolInput) bool {
    return false;
}
pub fn call(ctx: dispatch.DispatchContext, input: dispatch.ToolInput) dispatch.DispatchError!dispatch.ToolResult {
    const result = discover(ctx, input.as(Input).request) catch |err| {
        if (err == error.Cancelled or err == error.Canceled) return error.Cancelled;
        return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "discover_markets failed: {s}. No absence conclusion can be drawn. For ResultTooLarge, request fewer pairs or narrow the product.", .{@errorName(err)}) };
    };
    return .{ .success = result };
}
fn discover(ctx: dispatch.DispatchContext, request: t.Request) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tasks: std.ArrayList(runner.Task) = .empty;
    for (runner.jobs) |job| if (runner.needed(job.source, request.product)) {
        try tasks.append(alloc, .{ .job = job, .catalog = .{ .source = job.source } });
    };
    defer for (tasks.items) |*task| task.arena.deinit();
    var batch = runner.Batch{ .tasks = tasks.items, .cwd = ctx.workspace_root, .cancel = ctx.cancel_flag };
    var group: std.Io.Group = .init;
    defer group.cancel(io_mod.getIo());
    for (0..@min(8, tasks.items.len)) |_| group.async(io_mod.getIo(), runner.Batch.worker, .{&batch});
    try group.await(io_mod.getIo());
    if (ctx.cancel_flag) |flag| if (flag.load(.acquire)) return error.Cancelled;
    const catalogs = try alloc.alloc(t.Catalog, tasks.items.len);
    for (tasks.items, catalogs) |task, *catalog| catalog.* = task.catalog;
    var output = try aggregate(alloc, request, catalogs, io_mod.milliTimestamp());
    const limit = @min(ctx.max_tool_result_bytes, 512 * 1024);
    var json = try std.json.Stringify.valueAlloc(ctx.allocator, output, .{ .emit_null_optional_fields = false });
    if (json.len > limit) {
        ctx.allocator.free(json);
        // Specifications are ancillary. Never truncate market identities or pretend partial output is complete.
        for (@constCast(output.markets)) |*market| market.specifications = null;
        output.specificationsOmitted = true;
        json = try std.json.Stringify.valueAlloc(ctx.allocator, output, .{ .emit_null_optional_fields = false });
        if (json.len > limit) {
            ctx.allocator.free(json);
            return error.ResultTooLarge;
        }
    }
    return json;
}
pub fn aggregate(alloc: t.Allocator, request: t.Request, catalogs: []const t.Catalog, now: i64) !t.Output {
    var ctx = adapters.Context{ .alloc = alloc, .request = request, .catalogs = catalogs };
    var coverage: std.ArrayList(t.Coverage) = .empty;
    for (catalogs) |catalog| {
        var failure = catalog.failure;
        if (failure == null) adapters.parse(&ctx, catalog) catch |err| {
            failure = @errorName(err);
        };
        try coverage.append(alloc, .{ .venue = t.venue(catalog.source), .source = catalog.source, .status = if (failure == null) .complete else .@"error", .detail = failure });
        if (failure) |reason| try ctx.gaps.append(alloc, .{ .venue = t.venue(catalog.source), .reason = try std.fmt.allocPrint(alloc, "{s}: {s}; this source was not fully checked.", .{ @tagName(catalog.source), reason }) });
    }
    for (request.pairs) |pair| {
        for (ctx.markets.items) |market| {
            if (t.eq(market.ticker, pair.ticker) and t.eq(market.quote orelse "", pair.quote)) break;
        } else {
            try ctx.gaps.append(alloc, .{ .ticker = pair.ticker, .quote = pair.quote, .reason = "No available matching pair in completed catalogs; consult coverage for incomplete sources and supported products." });
        }
    }
    std.mem.sort(t.Market, ctx.markets.items, {}, less);
    return .{ .markets = try ctx.markets.toOwnedSlice(alloc), .coverage = try coverage.toOwnedSlice(alloc), .unresolved = try ctx.gaps.toOwnedSlice(alloc), .checkedAt = now };
}
fn less(_: void, a: t.Market, b: t.Market) bool {
    if (!std.mem.eql(u8, a.ticker, b.ticker)) return std.mem.lessThan(u8, a.ticker, b.ticker);
    if (a.venue != b.venue) return std.mem.lessThan(u8, @tagName(a.venue), @tagName(b.venue));
    if (a.product != b.product) return @intFromEnum(a.product) < @intFromEnum(b.product);
    if (!std.mem.eql(u8, a.symbol, b.symbol)) return std.mem.lessThan(u8, a.symbol, b.symbol);
    return std.mem.lessThan(u8, a.marketId orelse "", b.marketId orelse "");
}
test "discover_markets rejects executable input and normalizes a basket" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const req = try parseRequest(a, "{\"tickers\":[\" nvda \",\"NVDA/usdt\",\"NVDA / usdc\",\"BRK.B\"],\"product\":\"all\"}");
    try std.testing.expectEqual(@as(usize, 3), req.pairs.len);
    try std.testing.expectEqualStrings("NVDA", req.pairs[0].ticker);
    try std.testing.expectEqualStrings("USDT", req.pairs[0].quote);
    try std.testing.expectEqualStrings("NVDA", req.pairs[1].ticker);
    try std.testing.expectEqualStrings("USDC", req.pairs[1].quote);
    try std.testing.expectEqualStrings("BRK.B", req.pairs[2].ticker);
    try std.testing.expectError(error.InvalidTicker, parseRequest(a, "{\"tickers\":[\"BTC;env\"]}"));
    try std.testing.expectError(error.UnknownArgument, parseRequest(a, "{\"tickers\":[\"BTC\"],\"command\":\"env\"}"));
    try std.testing.expectError(error.InvalidTickerCount, parseRequest(a, "{\"tickers\":[]}"));
    try std.testing.expectError(error.InvalidProduct, parseRequest(a, "{\"tickers\":[\"BTC\"],\"product\":\"options\"}"));
    for ([_][]const u8{ "BTC/", "/USDC", "BTC/USDC;env" }) |invalid| {
        const json = try std.fmt.allocPrint(a, "{{\"tickers\":[\"{s}\"]}}", .{invalid});
        try std.testing.expectError(error.InvalidTicker, parseRequest(a, json));
    }
    try std.testing.expectError(error.InvalidPair, parseRequest(a, "{\"tickers\":[\"BTC/USDC/USD\"]}"));
    try std.testing.expectError(error.UnknownArgument, parseRequest(a, "{\"tickers\":[\"BTC\"],\"quote\":\"USDC\"}"));
}

test "discover_markets filters each requested pair without mixing quotes or hiding missing pairs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const catalog = try std.json.parseFromSlice(t.Value, a,
        \\{"symbols":[
        \\{"symbol":"BTCUSDT","baseAsset":"BTC","quoteAsset":"USDT","status":"TRADING","isSpotTradingAllowed":true},
        \\{"symbol":"BTCUSDC","baseAsset":"BTC","quoteAsset":"USDC","status":"TRADING","isSpotTradingAllowed":true},
        \\{"symbol":"ETHUSDT","baseAsset":"ETH","quoteAsset":"USDT","status":"TRADING","isSpotTradingAllowed":true},
        \\{"symbol":"ETHUSDC","baseAsset":"ETH","quoteAsset":"USDC","status":"TRADING","isSpotTradingAllowed":true}]}
    , .{});
    const request = try parseRequest(a, "{\"tickers\":[\"btc\",\"eth/usdc\",\"btc/eur\"],\"product\":\"spot\"}");
    const output = try aggregate(a, request, &.{.{ .source = .binance_spot, .data = catalog.value }}, 1);
    try std.testing.expectEqual(@as(usize, 2), output.markets.len);
    try std.testing.expectEqualStrings("BTCUSDT", output.markets[0].symbol);
    try std.testing.expectEqualStrings("ETHUSDC", output.markets[1].symbol);
    try std.testing.expectEqual(@as(usize, 1), output.unresolved.len);
    try std.testing.expectEqualStrings("BTC", output.unresolved[0].ticker.?);
    try std.testing.expectEqualStrings("EUR", output.unresolved[0].quote.?);
    const both = try parseRequest(a, "{\"tickers\":[\"BTC\",\"BTC/USDC\"]}");
    const both_output = try aggregate(a, both, &.{.{ .source = .binance_spot, .data = catalog.value }}, 1);
    try std.testing.expectEqual(@as(usize, 2), both_output.markets.len);
    try std.testing.expectEqual(@as(usize, 0), both_output.unresolved.len);
}

test "discover_markets real stock catalogs preserve exact symbols and all Gate variants" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixture = try std.json.parseFromSlice([]t.Catalog, a, @embedFile("discovery/fixtures/stocks.json"), .{});
    const request = try parseRequest(a, "{\"tickers\":[\"NVDA\",\"NVDA/USD\",\"TSLA\",\"TSLA/USD\",\"AAPL\",\"AAPL/USD\"]}");
    const output = try aggregate(a, request, fixture.value, 1);
    for (output.coverage) |c| try std.testing.expectEqual(.complete, c.status);
    for ([_][]const u8{ "NVDAxUSD", "RNVDAUSDT", "NVDABUSDT", "NVDAX_USDT", "NVDA_USDT", "NVDAG_USDT", "NVDAON_USDT", "XNVDA-USDT", "PF_NVDAXUSD" }) |symbol| {
        for (output.markets) |market| {
            if (std.mem.eql(u8, market.symbol, symbol)) break;
        } else {
            std.debug.print("Missing fixture market: {s}\n", .{symbol});
            return error.TestExpectedMarket;
        }
    }
    var kraken_spot: usize = 0;
    for (output.markets) |market| {
        try std.testing.expect(std.mem.find(u8, market.symbol, "AINVDA") == null);
        if (market.venue == .kraken and market.product == .spot) kraken_spot += 1;
        if (std.mem.eql(u8, market.symbol, "NVDA3L_USDT")) try std.testing.expectEqualStrings("leveraged_token", market.exposure);
        try std.testing.expect(market.quote != null);
    }
    try std.testing.expectEqual(@as(usize, 3), kraken_spot);
    const spot = try aggregate(a, .{ .pairs = &.{.{ .ticker = "NVDA" }}, .product = .spot }, fixture.value, 1);
    for (spot.markets) |market| {
        try std.testing.expectEqual(.spot, market.product);
        try std.testing.expect(t.eq("USDT", market.quote.?));
    }
    var independent: std.ArrayList(t.Catalog) = .empty;
    for (fixture.value) |catalog| if (catalog.source == .bitget_spot or catalog.source == .okx_spot) {
        try independent.append(a, catalog);
    };
    const local_metadata = try aggregate(a, .{ .pairs = &.{.{ .ticker = "NVDA" }}, .product = .spot }, independent.items, 1);
    // A venue's own stock classification works without another venue's issuer catalog.
    try std.testing.expectEqual(@as(usize, 2), local_metadata.markets.len);
}

test "discover_markets partial coverage retains restricted pairs without false absence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pairs = try std.json.parseFromSlice(t.Value, a,
        \\{"XETHZUSD":{"base":"XETH","quote":"ZUSD","altname":"ETHUSD","wsname":"ETH/USD","status":"post_only"}}
    , .{});
    const output = try aggregate(a, .{ .pairs = &.{.{ .ticker = "ETH", .quote = "USD" }}, .product = .all }, &.{
        .{ .source = .kraken_spot, .data = pairs.value },
        .{ .source = .gate_spot, .failure = "Timeout" },
        .{ .source = .okx_spot, .data = .{ .null = {} } },
    }, 1);
    try std.testing.expectEqual(@as(usize, 1), output.markets.len);
    try std.testing.expectEqualStrings("ETHUSD", output.markets[0].symbol);
    try std.testing.expectEqual(@as(usize, 1), output.markets[0].restrictions.len);
    try std.testing.expectEqual(.@"error", output.coverage[1].status);
    try std.testing.expectEqual(.@"error", output.coverage[2].status);
    try std.testing.expectEqual(@as(usize, 2), output.unresolved.len);
}

test "discover_markets Hyperliquid joins all DEXs and spot IDs without search truncation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const data = try std.json.parseFromSlice([]t.Catalog, a,
        \\[{"source":"hyper_dexs","data":[null,{"name":"xyz"}]},
        \\{"source":"hyper_perps","data":[{"collateralToken":0,"universe":[{"name":"BTC"}]},{"collateralToken":0,"universe":[{"name":"xyz:BTC"},{"name":"xyz:BTC","isDelisted":true}]}]},
        \\{"source":"hyper_spot","data":{"tokens":[{"name":"USDC","index":0},{"name":"UBTC","index":9}],"universe":[
        \\{"name":"@142","index":142,"tokens":[9,0]},{"name":"@143","index":143,"tokens":[9,0]},{"name":"@144","index":144,"tokens":[9,0]},{"name":"@145","index":145,"tokens":[9,0]},{"name":"@146","index":146,"tokens":[9,0]},{"name":"@147","index":147,"tokens":[9,0]},{"name":"@148","index":148,"tokens":[9,0]},{"name":"@149","index":149,"tokens":[9,0]},{"name":"@150","index":150,"tokens":[9,0]},{"name":"@151","index":151,"tokens":[9,0]},{"name":"@152","index":152,"tokens":[9,0]},{"name":"@153","index":153,"tokens":[9,0]}]}}]
    , .{});
    const output = try aggregate(a, .{ .pairs = &.{.{ .ticker = "BTC", .quote = "USDC" }}, .product = .all }, data.value, 1);
    for (output.coverage) |c| try std.testing.expectEqual(.complete, c.status);
    // Distinct spot market IDs must not be lost even when token display names coincide.
    try std.testing.expectEqual(@as(usize, 14), output.markets.len);
    for (output.markets) |m| {
        try std.testing.expectEqualStrings("USDC", m.quote.?);
        if (t.eq(m.symbol, "xyz:BTC")) try std.testing.expectEqual(@as(?usize, 110000), m.assetId);
        if (m.product == .spot) {
            try std.testing.expect(m.marketId != null);
            try std.testing.expectEqualStrings("wrapped", m.exposure);
        }
    }
}
