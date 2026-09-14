const std = @import("std");
const dispatch = @import("../../core/tooling/tool_dispatch.zig");
const public_command = @import("public_market_command.zig");
const script = @embedFile("market-data.sh") ++ "\n" ++ @embedFile("get-market-candles.sh") ++ "\nFX_MARKET_MODE=candles\n" ++ @embedFile("discover-markets.sh");

const Input = struct {
    parsed: std.json.Parsed(std.json.Value),

    fn deinit(ptr: *anyopaque, alloc: std.mem.Allocator) void {
        const input: *Input = @ptrCast(@alignCast(ptr));
        input.parsed.deinit();
        alloc.destroy(input);
    }
};

pub fn decode(ctx: dispatch.DispatchContext, arguments: []const u8) dispatch.DispatchError!dispatch.DecodeResult {
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, arguments, .{ .allocate = .alloc_always }) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "get_market_candles requires a JSON object containing tickers.") };
    };
    errdefer parsed.deinit();
    if (!validInput(parsed.value)) {
        const failure = try ctx.allocator.dupe(u8, "Invalid candle request. Supply 1-16 base tickers; optional unique intervals: 15m, 1h, 4h; indicators: sma/ema/rsi with integer period 2-200 and series 0-64; an exact market {venue,product,symbol} requires one ticker.");
        parsed.deinit();
        return .{ .failure = failure };
    }
    const input = try ctx.allocator.create(Input);
    input.* = .{ .parsed = parsed };
    return .{ .input = .{ .ptr = input, .deinit_fn = Input.deinit } };
}

fn validInput(value: std.json.Value) bool {
    if (value != .object) return false;
    for (value.object.keys()) |key| {
        if (!oneOf(key, &.{ "tickers", "intervals", "indicators", "market" })) return false;
    }
    const tickers = value.object.get("tickers") orelse return false;
    if (tickers != .array or tickers.array.items.len == 0 or tickers.array.items.len > 16) return false;
    for (tickers.array.items) |ticker| {
        if (ticker != .string or ticker.string.len == 0 or ticker.string.len > 32) return false;
        for (ticker.string) |char| if (!std.ascii.isAlphanumeric(char)) return false;
    }
    if (value.object.get("intervals")) |intervals| {
        if (intervals != .array or intervals.array.items.len == 0 or intervals.array.items.len > 3) return false;
        for (intervals.array.items, 0..) |interval, index| {
            if (interval != .string or !oneOf(interval.string, &.{ "15m", "1h", "4h" })) return false;
            for (intervals.array.items[0..index]) |prior| if (std.mem.eql(u8, prior.string, interval.string)) return false;
        }
    }
    if (value.object.get("indicators")) |indicators| {
        if (indicators != .array or indicators.array.items.len == 0 or indicators.array.items.len > 8) return false;
        for (indicators.array.items) |spec| {
            if (spec != .object) return false;
            for (spec.object.keys()) |key| if (!oneOf(key, &.{ "name", "period", "series" })) return false;
            const name = spec.object.get("name") orelse return false;
            if (name != .string or !oneOf(name.string, &.{ "sma", "ema", "rsi" })) return false;
            const period = spec.object.get("period") orelse return false;
            if (period != .integer or period.integer < 2 or period.integer > 200) return false;
            if (spec.object.get("series")) |series| if (series != .integer or series.integer < 0 or series.integer > 64) return false;
        }
    }
    if (value.object.get("market")) |market| {
        if (market != .object or market.object.count() != 3 or tickers.array.items.len != 1) return false;
        const venue = market.object.get("venue") orelse return false;
        const product = market.object.get("product") orelse return false;
        const symbol = market.object.get("symbol") orelse return false;
        if (venue != .string or venue.string.len == 0 or venue.string.len > 32) return false;
        if (product != .string or !oneOf(product.string, &.{ "spot", "perp" })) return false;
        if (symbol != .string or symbol.string.len == 0 or symbol.string.len > 128) return false;
        for (venue.string) |char| if (!std.ascii.isAlphanumeric(char) and char != '-') return false;
        for (symbol.string) |char| if (!std.ascii.isAlphanumeric(char) and std.mem.findScalar(u8, ":_./-", char) == null) return false;
    }
    return true;
}

fn oneOf(value: []const u8, choices: []const []const u8) bool {
    for (choices) |choice| if (std.mem.eql(u8, value, choice)) return true;
    return false;
}

pub fn call(ctx: dispatch.DispatchContext, erased: dispatch.ToolInput) dispatch.DispatchError!dispatch.ToolResult {
    const cmd = command(ctx.allocator, ctx.workspace_root, erased.as(Input)) catch return error.OutOfMemory;
    defer ctx.allocator.free(cmd);
    return public_command.execute(ctx, cmd, .markets);
}

fn command(alloc: std.mem.Allocator, workspace: []const u8, input: *Input) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try public_command.prefix(alloc, &out.writer, workspace);
    var program: std.Io.Writer.Allocating = .init(alloc);
    defer program.deinit();
    var json: std.Io.Writer.Allocating = .init(alloc);
    defer json.deinit();
    try std.json.Stringify.value(input.parsed.value, .{}, &json.writer);
    try program.writer.writeAll("candle_input=");
    try public_command.writeQuoted(&program.writer, json.written());
    try program.writer.writeAll("\nindicator_python=");
    try public_command.writeQuoted(&program.writer, @embedFile("candle_indicators.py"));
    try program.writer.writeAll("\n");
    try program.writer.writeAll(script);
    try public_command.writeQuoted(&out.writer, program.written());
    try out.writer.writeAll(" get-market-candles --quote ALL");
    for (input.parsed.value.object.get("tickers").?.array.items) |ticker| try out.writer.print(" {s}", .{ticker.string});
    return out.toOwnedSlice();
}

pub fn readsOnly(_: dispatch.ToolInput) bool {
    return true;
}

pub fn isIrreversible(_: dispatch.ToolInput) bool {
    return false;
}

test "get_market_candles accepts only base tickers" {
    const alloc = std.testing.allocator;
    for ([_][]const u8{ "{}", "{\"tickers\":[]}", "{\"tickers\":[\"BTC\"],\"venue\":\"binance\"}", "{\"tickers\":[\"BTC\"],\"product\":\"spot\"}", "{\"tickers\":[\"BTC/USDT\"]}", "{\"tickers\":[\"$(id)\"]}" }) |invalid| {
        const result = try decode(.{ .allocator = alloc }, invalid);
        try std.testing.expect(result == .failure);
        alloc.free(result.failure);
    }
    const result = try decode(.{ .allocator = alloc }, "{\"tickers\":[\"iren\",\"APLD\"]}");
    try std.testing.expect(result == .input);
    defer result.input.deinit(alloc);
    const cmd = try command(alloc, "/tmp/market ' workspace", result.input.as(Input));
    defer alloc.free(cmd);
    try std.testing.expect(std.mem.startsWith(u8, cmd, "FX_MARKET_CACHE_DIR='/tmp/market '\\'' workspace/.fx/market-cache/v1' exec bash"));
    try std.testing.expect(std.mem.endsWith(u8, cmd, " get-market-candles --quote ALL iren APLD"));
}
