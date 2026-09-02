const std = @import("std");
const command_replay_store = @import("../../core/session/command_replay_store.zig");
const types = @import("../../core/shared/types.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const rank_venue_costs = @import("rank_venue_costs.zig");
const result_reader = @import("tool_result_reader.zig");

const Allocator = std.mem.Allocator;
const max_rows = 4096;
const max_candles = 20;

pub const Input = struct {
    json: []u8,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.json);
        self.* = .{ .json = &.{} };
    }
};

const Candle = struct {
    openTime: i64,
    open: f64,
    high: f64,
    low: f64,
    close: f64,
    volume: ?f64,
};

const Evidence = struct {
    source: []const u8,
    detail: []const u8,
};

const Timeframes = struct {
    @"15m": ?[]const Candle,
    @"1h": ?[]const Candle,
    @"4h": ?[]const Candle,
};

const Cost = struct {
    method: []const u8,
    venue: []const u8,
    symbol: []const u8,
    product: []const u8,
    quote: []const u8,
    bestBid: f64,
    bestAsk: f64,
    bestPrice: f64,
    publicTakerFeeBps: f64,
    fullSpreadBps: f64,
    sideSpreadCostBps: f64,
    estimatedCostBps: f64,
    feeSourceUrl: []const u8,
    feeAsOf: []const u8,
    asOf: i64,
    feeBasis: []const u8,
};

const Output = struct {
    venue: []const u8,
    symbol: []const u8,
    product: []const u8,
    quote: []const u8,
    tradeReady: bool,
    summary: []const u8,
    evidence: []const Evidence,
    timeframes: Timeframes,
    cost: Cost,
    alternatives: []const rank_venue_costs.RankedCandidate,
    excluded: []const rank_venue_costs.ExcludedCandidate,
};

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "finalize_market_result arguments must be valid JSON") };
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, "finalize_market_result arguments must be an object") };
    }
    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{ .json = try ctx.allocator.dupe(u8, args_json) };
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

pub fn validate(_: tool_dispatch.DispatchContext, _: tool_dispatch.ToolInput) tool_dispatch.DispatchError!?[]u8 {
    return null;
}

pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const result = finalize(ctx, erased.as(Input).json) catch |err| {
        return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "finalize_market_result failed: {s}", .{@errorName(err)}) };
    };
    return .{ .success = result };
}

fn finalize(ctx: tool_dispatch.DispatchContext, input_json: []const u8) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    var arena_ctx = ctx;
    arena_ctx.allocator = arena_state.allocator();
    const temporary = try finalizeArena(arena_ctx, input_json);
    return ctx.allocator.dupe(u8, temporary);
}

fn finalizeArena(ctx: tool_dispatch.DispatchContext, input_json: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, ctx.allocator, input_json, .{});
    defer parsed.deinit();
    const root = try requireObject(parsed.value);
    const market = try requireObject(try requireField(root, "market"));
    const ranking_source = try requireObject(try requireField(root, "ranking"));
    if (ranking_source.get("resultId")) |result_id| {
        if (result_id != .null) return error.InvalidRankingSource;
    }
    const ranking_json = try result_reader.readCurrentTurnToolResult(ctx, ranking_source, "rank_venue_costs");
    defer ctx.allocator.free(ranking_json);
    var ranking = try std.json.parseFromSlice(rank_venue_costs.Output, ctx.allocator, ranking_json, .{ .ignore_unknown_fields = false });
    defer ranking.deinit();
    if (!ranking.value.feesIncluded or
        !std.mem.eql(u8, ranking.value.method, "public_taker_fee_plus_spread") or
        !std.mem.eql(u8, ranking.value.feeBasis, "public_base_taker"))
        return error.InvalidRankingResult;
    const selected = ranking.value.selected orelse return error.NoRankedMarket;

    const venue = try requireString(try requireField(market, "venue"));
    const symbol = try requireString(try requireField(market, "symbol"));
    const product = try requireString(try requireField(market, "product"));
    const quote = try requireString(try requireField(market, "quote"));
    if (!std.mem.eql(u8, venue, selected.venue) or
        !std.mem.eql(u8, symbol, selected.symbol) or
        !std.mem.eql(u8, product, selected.product) or
        !std.mem.eql(u8, quote, selected.quote))
        return error.MarketDoesNotMatchRanking;
    const candles = try requireObject(try requireField(root, "candles"));
    const sources = try requireObject(try requireField(candles, "sources"));
    const fields = try requireObject(try requireField(candles, "fields"));
    const rows_pointer = try requireString(try requireField(candles, "rows"));
    const time_unit = try requireString(try requireField(candles, "timeUnit"));
    if (!std.mem.eql(u8, time_unit, "ms") and !std.mem.eql(u8, time_unit, "s")) return error.InvalidTimeUnit;

    const evidence_values = try requireArray(try requireField(root, "evidence"));
    if (evidence_values.items.len > 8) return error.TooManyEvidenceItems;
    const evidence = try ctx.allocator.alloc(Evidence, evidence_values.items.len);
    for (evidence_values.items, 0..) |value, index| {
        const item = try requireObject(value);
        evidence[index] = .{
            .source = try requireString(try requireField(item, "source")),
            .detail = try requireString(try requireField(item, "detail")),
        };
    }

    const output = Output{
        .venue = venue,
        .symbol = symbol,
        .product = product,
        .quote = quote,
        .tradeReady = try requireBool(try requireField(market, "tradeReady")),
        .summary = try requireString(try requireField(root, "summary")),
        .evidence = evidence,
        .timeframes = .{
            .@"15m" = try extractTimeframe(ctx, sources, fields, rows_pointer, time_unit, "15m"),
            .@"1h" = try extractTimeframe(ctx, sources, fields, rows_pointer, time_unit, "1h"),
            .@"4h" = try extractTimeframe(ctx, sources, fields, rows_pointer, time_unit, "4h"),
        },
        .cost = .{
            .method = ranking.value.method,
            .venue = selected.venue,
            .symbol = selected.symbol,
            .product = selected.product,
            .quote = selected.quote,
            .bestBid = selected.bestBid,
            .bestAsk = selected.bestAsk,
            .bestPrice = selected.bestPrice,
            .publicTakerFeeBps = selected.publicTakerFeeBps,
            .fullSpreadBps = selected.fullSpreadBps,
            .sideSpreadCostBps = selected.sideSpreadCostBps,
            .estimatedCostBps = selected.estimatedCostBps,
            .feeSourceUrl = selected.feeSourceUrl,
            .feeAsOf = selected.feeAsOf,
            .asOf = selected.asOf,
            .feeBasis = ranking.value.feeBasis,
        },
        .alternatives = ranking.value.alternatives,
        .excluded = ranking.value.excluded,
    };

    var writer: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer writer.deinit();
    try std.json.Stringify.value(output, .{}, &writer.writer);
    return writer.toOwnedSlice();
}

fn extractTimeframe(
    ctx: tool_dispatch.DispatchContext,
    sources: std.json.ObjectMap,
    fields: std.json.ObjectMap,
    rows_pointer: []const u8,
    time_unit: []const u8,
    timeframe: []const u8,
) !?[]const Candle {
    const source_value = try requireField(sources, timeframe);
    if (source_value == .null) return null;
    const stdout = try result_reader.readTerminalStdout(ctx, source_value);
    defer ctx.allocator.free(stdout);
    const trimmed = std.mem.trim(u8, stdout, " \t\r\n");
    var parsed = try std.json.parseFromSlice(std.json.Value, ctx.allocator, trimmed, .{});
    defer parsed.deinit();
    const rows_value = try result_reader.resolvePointer(ctx.allocator, parsed.value, rows_pointer);
    const rows = try requireArray(rows_value);
    if (rows.items.len == 0) return null;
    if (rows.items.len > max_rows) return error.TooManyCandleRows;

    var normalized: std.ArrayList(Candle) = .empty;
    defer normalized.deinit(ctx.allocator);
    for (rows.items) |row| {
        const raw_time = try result_reader.resolvePointer(ctx.allocator, row, try requireString(try requireField(fields, "time")));
        var open_time = try numericTimestamp(raw_time);
        if (std.mem.eql(u8, time_unit, "s")) open_time = try std.math.mul(i64, open_time, 1000);
        const volume_value = if (fields.get("volume")) |pointer_value|
            if (pointer_value == .null) null else try result_reader.resolvePointer(ctx.allocator, row, try requireString(pointer_value))
        else
            null;
        const candle = Candle{
            .openTime = open_time,
            .open = try numeric(try result_reader.resolvePointer(ctx.allocator, row, try requireString(try requireField(fields, "open")))),
            .high = try numeric(try result_reader.resolvePointer(ctx.allocator, row, try requireString(try requireField(fields, "high")))),
            .low = try numeric(try result_reader.resolvePointer(ctx.allocator, row, try requireString(try requireField(fields, "low")))),
            .close = try numeric(try result_reader.resolvePointer(ctx.allocator, row, try requireString(try requireField(fields, "close")))),
            .volume = if (volume_value) |value| try nullableNumeric(value) else null,
        };
        if (candle.openTime <= 0 or candle.open <= 0 or candle.high <= 0 or candle.low <= 0 or candle.close <= 0 or
            candle.high < candle.low or candle.high < @max(candle.open, candle.close) or candle.low > @min(candle.open, candle.close))
            return error.InvalidCandle;
        try normalized.append(ctx.allocator, candle);
    }
    std.mem.sort(Candle, normalized.items, {}, candleLessThan);
    var unique: std.ArrayList(Candle) = .empty;
    defer unique.deinit(ctx.allocator);
    for (normalized.items) |candle| {
        if (unique.items.len > 0 and unique.items[unique.items.len - 1].openTime == candle.openTime) {
            unique.items[unique.items.len - 1] = candle;
        } else {
            try unique.append(ctx.allocator, candle);
        }
    }
    const start = if (unique.items.len > max_candles) unique.items.len - max_candles else 0;
    return try ctx.allocator.dupe(Candle, unique.items[start..]);
}

fn candleLessThan(_: void, left: Candle, right: Candle) bool {
    return left.openTime < right.openTime;
}

fn requireField(object: std.json.ObjectMap, name: []const u8) !std.json.Value {
    return object.get(name) orelse error.MissingField;
}
fn requireObject(value: std.json.Value) !std.json.ObjectMap {
    return if (value == .object) value.object else error.ExpectedObject;
}
fn requireArray(value: std.json.Value) !std.json.Array {
    return if (value == .array) value.array else error.ExpectedArray;
}
fn requireString(value: std.json.Value) ![]const u8 {
    return if (value == .string) value.string else error.ExpectedString;
}
fn requireBool(value: std.json.Value) !bool {
    return if (value == .bool) value.bool else error.ExpectedBoolean;
}
fn numericTimestamp(value: std.json.Value) !i64 {
    return switch (value) {
        .integer => |number| number,
        .float => |number| if (std.math.isFinite(number) and number >= 0 and number <= @as(f64, @floatFromInt(std.math.maxInt(i64)))) @intFromFloat(number) else error.InvalidNumber,
        .string => |text| std.fmt.parseInt(i64, text, 10) catch error.InvalidNumber,
        else => error.InvalidNumber,
    };
}
fn numeric(value: std.json.Value) !f64 {
    const number: f64 = switch (value) {
        .integer => |item| @floatFromInt(item),
        .float => |item| item,
        .string => |text| std.fmt.parseFloat(f64, text) catch return error.InvalidNumber,
        else => return error.InvalidNumber,
    };
    if (!std.math.isFinite(number)) return error.InvalidNumber;
    return number;
}
fn nullableNumeric(value: std.json.Value) !?f64 {
    if (value == .null) return null;
    const value_number = try numeric(value);
    if (value_number < 0) return error.InvalidNumber;
    return value_number;
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

const test_ranking_output =
    \\{"method":"public_taker_fee_plus_spread","selected":{"venue":"demo","symbol":"BTCUSD","product":"perpetual","quote":"USD","bestBid":99,"bestAsk":101,"bestPrice":101,"publicTakerFeeBps":5,"fullSpreadBps":200,"sideSpreadCostBps":100,"estimatedCostBps":105,"feeSourceUrl":"https://demo.example/fees","feeAsOf":"2026-09-03","asOf":1788369158545},"alternatives":[],"excluded":[],"feesIncluded":true,"feeBasis":"public_base_taker"}
;

fn testRankingMessages() [2]types.ChatMessage {
    const calls = struct {
        const value = [_]types.ToolCall{
            .{ .id = "call_rank", .name = "rank_venue_costs", .arguments_json = "{}" },
        };
    }.value;
    return .{
        .{ .role = .assistant, .tool_calls = &calls },
        .{ .role = .tool, .content = test_ranking_output, .tool_call_id = "call_rank", .tool_name = "rank_venue_costs", .tool_result_status = .success },
    };
}

test "finalizer reads replay handles and emits normalized market result" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io_mod = @import("../../core/shared/io.zig");
    const temp_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(temp_path);
    var store = command_replay_store.EphemeralStore.initForTesting(alloc, temp_path);
    defer store.deinit();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const raw = "{\"data\":[[\"2000\",\"2\",\"4\",\"1\",\"3\",\"8\"],[\"1000\",\"1\",\"3\",\"0.5\",\"2\",\"7\"]]}";
    var handles: [3][]const u8 = undefined;
    for (&handles) |*handle| {
        const capture = try command_replay_store.Capture.createEphemeral(arena, 0, &store);
        try capture.appendAcceptedRequired(arena, .stdout, raw);
        const descriptor = (try capture.retainRequired(arena)) orelse return error.TestExpectedReplay;
        handle.* = descriptor.handle;
    }
    const args = try std.fmt.allocPrint(
        arena,
        "{{\"market\":{{\"venue\":\"demo\",\"symbol\":\"BTCUSD\",\"product\":\"perpetual\",\"quote\":\"USD\",\"tradeReady\":true}},\"ranking\":{{\"sourceToolCall\":0,\"resultId\":null}},\"summary\":\"verified\",\"evidence\":[{{\"source\":\"demo\",\"detail\":\"exact listing\"}}],\"candles\":{{\"sources\":{{\"15m\":\"{s}\",\"1h\":\"{s}\",\"4h\":\"{s}\"}},\"rows\":\"/data\",\"fields\":{{\"time\":\"/0\",\"open\":\"/1\",\"high\":\"/2\",\"low\":\"/3\",\"close\":\"/4\",\"volume\":\"/5\"}},\"timeUnit\":\"ms\"}}}}",
        .{ handles[0], handles[1], handles[2] },
    );
    const messages = testRankingMessages();
    const result = try finalize(.{ .allocator = alloc, .ephemeral_command_replay = &store, .current_turn_messages = &messages }, args);
    defer alloc.free(result);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, result, .{});
    defer parsed.deinit();
    const timeframes = parsed.value.object.get("timeframes").?.object;
    const candles = timeframes.get("15m").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), candles.len);
    try std.testing.expectEqual(@as(i64, 1000), candles[0].object.get("openTime").?.integer);
    try std.testing.expectEqual(@as(i64, 2000), candles[1].object.get("openTime").?.integer);
    try std.testing.expectEqual(true, parsed.value.object.get("tradeReady").?.bool);
    try std.testing.expectEqual(@as(f64, 105), try result_reader.numeric(parsed.value.object.get("cost").?.object.get("estimatedCostBps").?));
}

test "finalizer reads ordinary terminal results from the current turn" {
    const alloc = std.testing.allocator;
    const calls = [_]types.ToolCall{
        .{ .id = "call_15m", .name = "terminal", .arguments_json = "{}" },
        .{ .id = "call_1h", .name = "terminal", .arguments_json = "{}" },
        .{ .id = "call_4h", .name = "terminal", .arguments_json = "{}" },
    };
    const output = "exit_code=0\n<stdout>\n[[2000,\"2\",\"4\",\"1\",\"3\",\"8\"],[1000,\"1\",\"3\",\"0.5\",\"2\",\"7\"]]\n</stdout>\n";
    const finalizer_calls = [_]types.ToolCall{
        .{ .id = "call_finalize", .name = "finalize_market_result", .arguments_json = "{}" },
    };
    const rank_calls = [_]types.ToolCall{
        .{ .id = "call_rank", .name = "rank_venue_costs", .arguments_json = "{}" },
    };
    const messages = [_]types.ChatMessage{
        .{ .role = .assistant, .tool_calls = &calls },
        .{ .role = .tool, .content = output, .tool_call_id = "call_15m", .tool_name = "terminal", .tool_result_status = .success },
        .{ .role = .tool, .content = output, .tool_call_id = "call_1h", .tool_name = "terminal", .tool_result_status = .success },
        .{ .role = .tool, .content = output, .tool_call_id = "call_4h", .tool_name = "terminal", .tool_result_status = .success },
        .{ .role = .assistant, .tool_calls = &rank_calls },
        .{ .role = .tool, .content = test_ranking_output, .tool_call_id = "call_rank", .tool_name = "rank_venue_costs", .tool_result_status = .success },
        .{ .role = .assistant, .tool_calls = &finalizer_calls },
    };
    const args =
        \\{"market":{"venue":"demo","symbol":"BTCUSD","product":"perpetual","quote":"USD","tradeReady":true},"ranking":{"sourceToolCall":0,"resultId":null},"summary":"verified","evidence":[],"candles":{"sources":{"15m":{"sourceToolCall":0,"resultId":null},"1h":{"sourceToolCall":1,"resultId":null},"4h":{"sourceToolCall":2,"resultId":null}},"rows":"","fields":{"time":"/0","open":"/1","high":"/2","low":"/3","close":"/4","volume":"/5"},"timeUnit":"ms"}}
    ;
    const result = try finalize(.{ .allocator = alloc, .current_turn_messages = &messages }, args);
    defer alloc.free(result);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, result, .{});
    defer parsed.deinit();
    const candles = parsed.value.object.get("timeframes").?.object.get("15m").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), candles.len);
    try std.testing.expectEqual(@as(i64, 1000), candles[0].object.get("openTime").?.integer);
}

test "finalizer selects terminal batch children without copied candle rows" {
    const alloc = std.testing.allocator;
    const calls = [_]types.ToolCall{
        .{ .id = "call_batch", .name = "terminal", .arguments_json = "{}" },
    };
    const batch_output =
        \\[{"id":"15m","status":"success","output":"exit_code=0\n<stdout>\n[[1000,\"1\",\"3\",\"0.5\",\"2\",\"7\"]]\n</stdout>\n"},{"id":"1h","status":"success","output":"exit_code=0\n<stdout>\n[[2000,\"2\",\"4\",\"1\",\"3\",\"8\"]]\n</stdout>\n"},{"id":"4h","status":"success","output":"exit_code=0\n<stdout>\n[[3000,\"3\",\"5\",\"2\",\"4\",\"9\"]]\n</stdout>\n"}]
    ;
    const messages = [_]types.ChatMessage{
        .{ .role = .assistant, .tool_calls = &calls },
        .{ .role = .tool, .content = batch_output, .tool_call_id = "call_batch", .tool_name = "terminal", .tool_result_status = .success },
        .{ .role = .assistant, .tool_calls = &.{.{ .id = "call_rank", .name = "rank_venue_costs", .arguments_json = "{}" }} },
        .{ .role = .tool, .content = test_ranking_output, .tool_call_id = "call_rank", .tool_name = "rank_venue_costs", .tool_result_status = .success },
    };
    const args =
        \\{"market":{"venue":"demo","symbol":"BTCUSD","product":"perpetual","quote":"USD","tradeReady":true},"ranking":{"sourceToolCall":0,"resultId":null},"summary":"verified","evidence":[],"candles":{"sources":{"15m":{"sourceToolCall":0,"resultId":"15m"},"1h":{"sourceToolCall":0,"resultId":"1h"},"4h":{"sourceToolCall":0,"resultId":"4h"}},"rows":"","fields":{"time":"/0","open":"/1","high":"/2","low":"/3","close":"/4","volume":"/5"},"timeUnit":"ms"}}
    ;
    const result = try finalize(.{ .allocator = alloc, .current_turn_messages = &messages }, args);
    defer alloc.free(result);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, result, .{});
    defer parsed.deinit();
    const timeframes = parsed.value.object.get("timeframes").?.object;
    try std.testing.expectEqual(@as(i64, 1000), timeframes.get("15m").?.array.items[0].object.get("openTime").?.integer);
    try std.testing.expectEqual(@as(i64, 2000), timeframes.get("1h").?.array.items[0].object.get("openTime").?.integer);
    try std.testing.expectEqual(@as(i64, 3000), timeframes.get("4h").?.array.items[0].object.get("openTime").?.integer);
}
