const std = @import("std");
const command_replay_store = @import("../../core/session/command_replay_store.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");

const Allocator = std.mem.Allocator;
const max_source_bytes = 2 * 1024 * 1024;
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

const Output = struct {
    venue: []const u8,
    symbol: []const u8,
    product: []const u8,
    quote: []const u8,
    tradeReady: bool,
    summary: []const u8,
    evidence: []const Evidence,
    timeframes: Timeframes,
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
        .venue = try requireString(try requireField(market, "venue")),
        .symbol = try requireString(try requireField(market, "symbol")),
        .product = try requireString(try requireField(market, "product")),
        .quote = try requireString(try requireField(market, "quote")),
        .tradeReady = try requireBool(try requireField(market, "tradeReady")),
        .summary = try requireString(try requireField(root, "summary")),
        .evidence = evidence,
        .timeframes = .{
            .@"15m" = try extractTimeframe(ctx, sources, fields, rows_pointer, time_unit, "15m"),
            .@"1h" = try extractTimeframe(ctx, sources, fields, rows_pointer, time_unit, "1h"),
            .@"4h" = try extractTimeframe(ctx, sources, fields, rows_pointer, time_unit, "4h"),
        },
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
    const handle = try requireString(source_value);
    const stdout = try readCapturedStdout(ctx, handle);
    defer ctx.allocator.free(stdout);
    const trimmed = std.mem.trim(u8, stdout, " \t\r\n");
    var parsed = try std.json.parseFromSlice(std.json.Value, ctx.allocator, trimmed, .{});
    defer parsed.deinit();
    const rows_value = try resolvePointer(ctx.allocator, parsed.value, rows_pointer);
    const rows = try requireArray(rows_value);
    if (rows.items.len == 0) return null;
    if (rows.items.len > max_rows) return error.TooManyCandleRows;

    var normalized: std.ArrayList(Candle) = .empty;
    defer normalized.deinit(ctx.allocator);
    for (rows.items) |row| {
        const raw_time = try resolvePointer(ctx.allocator, row, try requireString(try requireField(fields, "time")));
        var open_time = try numericTimestamp(raw_time);
        if (std.mem.eql(u8, time_unit, "s")) open_time = try std.math.mul(i64, open_time, 1000);
        const volume_value = if (fields.get("volume")) |pointer_value|
            if (pointer_value == .null) null else try resolvePointer(ctx.allocator, row, try requireString(pointer_value))
        else
            null;
        const candle = Candle{
            .openTime = open_time,
            .open = try numeric(try resolvePointer(ctx.allocator, row, try requireString(try requireField(fields, "open")))),
            .high = try numeric(try resolvePointer(ctx.allocator, row, try requireString(try requireField(fields, "high")))),
            .low = try numeric(try resolvePointer(ctx.allocator, row, try requireString(try requireField(fields, "low")))),
            .close = try numeric(try resolvePointer(ctx.allocator, row, try requireString(try requireField(fields, "close")))),
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

fn readCapturedStdout(ctx: tool_dispatch.DispatchContext, handle: []const u8) ![]u8 {
    var reader = if (ctx.session_child_capability) |capability|
        try command_replay_store.Reader.openHandle(ctx.allocator, capability, handle)
    else if (ctx.ephemeral_command_replay) |store|
        try command_replay_store.Reader.openEphemeralHandle(ctx.allocator, store, handle)
    else
        return error.NoCommandReplayStore;
    defer reader.deinit();
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(ctx.allocator);
    while (try reader.next(ctx.allocator)) |frame| {
        defer ctx.allocator.free(frame.payload);
        if (frame.stream != .stdout) continue;
        if (output.items.len + frame.payload.len > max_source_bytes) return error.CandleSourceTooLarge;
        try output.appendSlice(ctx.allocator, frame.payload);
    }
    return output.toOwnedSlice(ctx.allocator);
}

fn resolvePointer(alloc: Allocator, root: std.json.Value, pointer: []const u8) !std.json.Value {
    if (pointer.len == 0) return root;
    if (pointer[0] != '/') return error.InvalidJsonPointer;
    var current = root;
    var parts = std.mem.splitScalar(u8, pointer[1..], '/');
    while (parts.next()) |encoded| {
        const token = try decodePointerToken(alloc, encoded);
        defer alloc.free(token);
        current = switch (current) {
            .object => |object| object.get(token) orelse return error.JsonPointerNotFound,
            .array => |array| blk: {
                const index = std.fmt.parseInt(usize, token, 10) catch return error.InvalidJsonPointer;
                if (index >= array.items.len) return error.JsonPointerNotFound;
                break :blk array.items[index];
            },
            else => return error.JsonPointerNotFound,
        };
    }
    return current;
}

fn decodePointerToken(alloc: Allocator, encoded: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var index: usize = 0;
    while (index < encoded.len) : (index += 1) {
        if (encoded[index] != '~') {
            try out.append(alloc, encoded[index]);
            continue;
        }
        index += 1;
        if (index >= encoded.len) return error.InvalidJsonPointer;
        try out.append(alloc, switch (encoded[index]) {
            '0' => '~',
            '1' => '/',
            else => return error.InvalidJsonPointer,
        });
    }
    return out.toOwnedSlice(alloc);
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

test "JSON pointer supports array and object candle rows" {
    const alloc = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, "{\"data\":[[\"1\",\"2\"]],\"a/b\":3}", .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("2", (try resolvePointer(alloc, parsed.value, "/data/0/1")).string);
    try std.testing.expectEqual(@as(i64, 3), (try resolvePointer(alloc, parsed.value, "/a~1b")).integer);
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
        "{{\"market\":{{\"venue\":\"demo\",\"symbol\":\"BTCUSD\",\"product\":\"perpetual\",\"quote\":\"USD\",\"tradeReady\":true}},\"summary\":\"verified\",\"evidence\":[{{\"source\":\"demo\",\"detail\":\"exact listing\"}}],\"candles\":{{\"sources\":{{\"15m\":\"{s}\",\"1h\":\"{s}\",\"4h\":\"{s}\"}},\"rows\":\"/data\",\"fields\":{{\"time\":\"/0\",\"open\":\"/1\",\"high\":\"/2\",\"low\":\"/3\",\"close\":\"/4\",\"volume\":\"/5\"}},\"timeUnit\":\"ms\"}}}}",
        .{ handles[0], handles[1], handles[2] },
    );
    const result = try finalize(.{ .allocator = alloc, .ephemeral_command_replay = &store }, args);
    defer alloc.free(result);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, result, .{});
    defer parsed.deinit();
    const timeframes = parsed.value.object.get("timeframes").?.object;
    const candles = timeframes.get("15m").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), candles.len);
    try std.testing.expectEqual(@as(i64, 1000), candles[0].object.get("openTime").?.integer);
    try std.testing.expectEqual(@as(i64, 2000), candles[1].object.get("openTime").?.integer);
    try std.testing.expectEqual(true, parsed.value.object.get("tradeReady").?.bool);
}
