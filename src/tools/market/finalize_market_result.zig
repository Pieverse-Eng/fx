const std = @import("std");
const command_replay_store = @import("../../core/session/command_replay_store.zig");
const types = @import("../../core/shared/types.zig");
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

const OnchainRoute = struct {
    issuer: []const u8,
    tokenSymbol: []const u8,
    chain: []const u8,
    contract: []const u8,
    inputAsset: []const u8,
    inputContract: []const u8,
    provider: []const u8,
    route: []const u8,
    amountIn: f64,
    amountOut: f64,
    exposureShares: f64,
    gasReference: f64,
    effectiveReferencePerShare: f64,
    referenceNotional: f64,
    referenceCurrency: []const u8,
    quotedAt: i64,
};

const Output = struct {
    venue: []const u8,
    symbol: []const u8,
    product: []const u8,
    quote: []const u8,
    summary: []const u8,
    evidence: []const Evidence,
    timeframes: Timeframes,
    onchainRoute: ?OnchainRoute,
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
        .summary = try requireString(try requireField(root, "summary")),
        .evidence = evidence,
        .onchainRoute = try parseOnchainRoute(ctx, root.get("onchainRoute") orelse return error.MissingField),
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

fn parseOnchainRoute(ctx: tool_dispatch.DispatchContext, value: std.json.Value) !?OnchainRoute {
    if (value == .null) return null;
    const source = try requireObject(value);
    const raw = try readCurrentTurnToolResult(ctx, source, "quote_onchain_stock");
    var parsed = try std.json.parseFromSlice(std.json.Value, ctx.allocator, raw, .{});
    defer parsed.deinit();
    const root = try requireObject(parsed.value);
    const route_value = root.get("selected") orelse return error.OnchainQuoteMissingSelection;
    if (route_value == .null) return error.OnchainQuoteMissingSelection;
    const route = try requireObject(route_value);
    const amount_in = try positiveNumeric(try requireField(route, "amountIn"));
    const amount_out = try positiveNumeric(try requireField(route, "amountOut"));
    const exposure_shares = try positiveNumeric(try requireField(route, "exposureShares"));
    const gas_reference = try nonNegativeNumeric(try requireField(route, "gasReference"));
    const effective = try positiveNumeric(try requireField(route, "effectiveReferencePerShare"));
    return .{
        .issuer = try ownedString(ctx.allocator, try requireField(route, "issuer")),
        .tokenSymbol = try ownedString(ctx.allocator, try requireField(route, "tokenSymbol")),
        .chain = try ownedString(ctx.allocator, try requireField(route, "chain")),
        .contract = try ownedString(ctx.allocator, try requireField(route, "contract")),
        .inputAsset = try ownedString(ctx.allocator, try requireField(route, "inputAsset")),
        .inputContract = try ownedString(ctx.allocator, try requireField(route, "inputContract")),
        .provider = try ownedString(ctx.allocator, try requireField(route, "provider")),
        .route = try ownedString(ctx.allocator, try requireField(route, "route")),
        .amountIn = amount_in,
        .amountOut = amount_out,
        .exposureShares = exposure_shares,
        .gasReference = gas_reference,
        .effectiveReferencePerShare = effective,
        .referenceNotional = try positiveNumeric(try requireField(root, "referenceNotional")),
        .referenceCurrency = try ownedString(ctx.allocator, try requireField(root, "referenceCurrency")),
        .quotedAt = try positiveInteger(try requireField(root, "quotedAt")),
    };
}

fn readCurrentTurnToolResult(ctx: tool_dispatch.DispatchContext, source: std.json.ObjectMap, expected_tool: []const u8) ![]const u8 {
    const call_index = try nonNegativeIndex(try requireField(source, "sourceToolCall"));
    var message_index = ctx.current_turn_messages.len;
    while (message_index > 0) {
        message_index -= 1;
        const assistant = ctx.current_turn_messages[message_index];
        if (assistant.role != .assistant or assistant.tool_calls.len == 0) continue;
        var has_expected_tool = false;
        for (assistant.tool_calls) |candidate_call| {
            if (std.mem.eql(u8, candidate_call.name, expected_tool)) {
                has_expected_tool = true;
                break;
            }
        }
        if (!has_expected_tool) continue;
        if (call_index >= assistant.tool_calls.len) return error.OnchainQuoteToolCallNotFound;
        const source_call = assistant.tool_calls[call_index];
        if (!std.mem.eql(u8, source_call.name, expected_tool)) return error.InvalidOnchainQuoteSourceTool;
        const result = findToolResult(ctx.current_turn_messages, message_index + 1, source_call.id) orelse
            return error.OnchainQuoteToolResultNotFound;
        if (result.tool_name) |name| {
            if (!std.mem.eql(u8, name, expected_tool)) return error.InvalidOnchainQuoteSourceTool;
        }
        if (result.tool_result_status) |status| {
            if (status != .success) return error.OnchainQuoteToolFailed;
        }
        return result.content orelse return error.OnchainQuoteToolResultMissing;
    }
    return error.OnchainQuoteToolCallNotFound;
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
    const stdout = switch (source_value) {
        .string => |handle| try readCapturedStdout(ctx, handle),
        .object => |source| try readCurrentTurnStdout(ctx, source),
        else => return error.InvalidCandleSource,
    };
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

fn readCurrentTurnStdout(ctx: tool_dispatch.DispatchContext, source: std.json.ObjectMap) ![]u8 {
    const call_index = try nonNegativeIndex(try requireField(source, "sourceToolCall"));
    const result_id = if (source.get("resultId")) |value|
        if (value == .null) null else try requireString(value)
    else
        null;

    var message_index = ctx.current_turn_messages.len;
    while (message_index > 0) {
        message_index -= 1;
        const assistant = ctx.current_turn_messages[message_index];
        if (assistant.role != .assistant or assistant.tool_calls.len == 0) continue;
        var has_terminal = false;
        for (assistant.tool_calls) |candidate_call| {
            if (std.mem.eql(u8, candidate_call.name, "terminal")) {
                has_terminal = true;
                break;
            }
        }
        // The most recent assistant batch normally contains this finalizer call.
        // Sources are indexed against the preceding batch that ran terminal tools.
        if (!has_terminal) continue;
        if (call_index >= assistant.tool_calls.len) return error.CandleToolCallNotFound;
        const source_call = assistant.tool_calls[call_index];
        if (!std.mem.eql(u8, source_call.name, "terminal")) return error.InvalidCandleSourceTool;
        const result = findToolResult(ctx.current_turn_messages, message_index + 1, source_call.id) orelse
            return error.CandleToolResultNotFound;
        if (result.tool_name) |name| {
            if (!std.mem.eql(u8, name, "terminal")) return error.InvalidCandleSourceTool;
        }
        if (result.tool_result_status) |status| {
            if (status != .success) return error.CandleToolFailed;
        }
        if (result_id) |id| return batchChildStdout(ctx.allocator, result.content orelse return error.CandleToolResultMissing, id);
        if (result.tool_result_memory) |memory| {
            if (memory.command_output_replay) |replay| switch (replay) {
                .available => |descriptor| return readCapturedStdout(ctx, descriptor.handle),
                .unavailable => {},
            };
        }
        return envelopeStdout(ctx.allocator, result.content orelse return error.CandleToolResultMissing);
    }
    return error.CandleToolCallNotFound;
}

fn findToolResult(messages: []const types.ChatMessage, start: usize, call_id: []const u8) ?types.ChatMessage {
    for (messages[start..]) |message| {
        if (message.role == .assistant) break;
        if (message.role != .tool) continue;
        if (message.tool_call_id) |candidate| {
            if (std.mem.eql(u8, candidate, call_id)) return message;
        }
    }
    return null;
}

fn batchChildStdout(alloc: Allocator, content: []const u8, result_id: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, content, .{});
    defer parsed.deinit();
    const results = try requireArray(parsed.value);
    for (results.items) |value| {
        const item = try requireObject(value);
        if (!std.mem.eql(u8, try requireString(try requireField(item, "id")), result_id)) continue;
        if (!std.mem.eql(u8, try requireString(try requireField(item, "status")), "success")) return error.CandleToolFailed;
        return envelopeStdout(alloc, try requireString(try requireField(item, "output")));
    }
    return error.CandleBatchResultNotFound;
}

fn envelopeStdout(alloc: Allocator, content: []const u8) ![]u8 {
    const open = "<stdout>\n";
    const close = "\n</stdout>";
    const start = if (std.mem.indexOf(u8, content, open)) |index| index + open.len else 0;
    const end = if (std.mem.indexOfPos(u8, content, start, close)) |index| index else content.len;
    if (end < start) return error.InvalidCommandEnvelope;
    return alloc.dupe(u8, content[start..end]);
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
fn ownedString(alloc: Allocator, value: std.json.Value) ![]const u8 {
    return alloc.dupe(u8, try requireString(value));
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
fn positiveNumeric(value: std.json.Value) !f64 {
    const number = try numeric(value);
    if (number <= 0) return error.InvalidNumber;
    return number;
}
fn nonNegativeNumeric(value: std.json.Value) !f64 {
    const number = try numeric(value);
    if (number < 0) return error.InvalidNumber;
    return number;
}
fn positiveInteger(value: std.json.Value) !i64 {
    if (value != .integer or value.integer <= 0) return error.InvalidNumber;
    return value.integer;
}
fn nullableNumeric(value: std.json.Value) !?f64 {
    if (value == .null) return null;
    const value_number = try numeric(value);
    if (value_number < 0) return error.InvalidNumber;
    return value_number;
}

fn nonNegativeIndex(value: std.json.Value) !usize {
    if (value != .integer or value.integer < 0) return error.InvalidToolCallIndex;
    return std.math.cast(usize, value.integer) orelse error.InvalidToolCallIndex;
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

test "onchain execution route is loaded from the quote tool result" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const calls = [_]types.ToolCall{
        .{ .id = "call_quote", .name = "quote_onchain_stock", .arguments_json = "{}" },
    };
    const quote_result =
        \\{"ticker":"CRCL","referenceNotional":100,"referenceCurrency":"USD","quotedAt":1788451200000,"selected":{"issuer":"xstocks","tokenSymbol":"CRCLx","chain":"Solana","contract":"mint","inputAsset":"USDC","inputContract":"usdc-mint","provider":"dflow","route":"dflow","amountIn":"100","amountOut":"0.98","exposureShares":"0.98","gasReference":"0.01","effectiveReferencePerShare":"102.05"}}
    ;
    const messages = [_]types.ChatMessage{
        .{ .role = .assistant, .tool_calls = &calls },
        .{ .role = .tool, .content = quote_result, .tool_call_id = "call_quote", .tool_name = "quote_onchain_stock", .tool_result_status = .success },
    };
    var source = try std.json.parseFromSlice(std.json.Value, arena, "{\"sourceToolCall\":0}", .{});
    defer source.deinit();
    const route = (try parseOnchainRoute(.{ .allocator = arena, .current_turn_messages = &messages }, source.value)).?;
    try std.testing.expectEqualStrings("CRCLx", route.tokenSymbol);
    try std.testing.expectEqual(@as(f64, 0.98), route.exposureShares);
    try std.testing.expectEqual(@as(f64, 100), route.referenceNotional);
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
        "{{\"market\":{{\"venue\":\"demo\",\"symbol\":\"BTCUSD\",\"product\":\"perpetual\",\"quote\":\"USD\"}},\"onchainRoute\":null,\"summary\":\"verified\",\"evidence\":[{{\"source\":\"demo\",\"detail\":\"exact listing\"}}],\"candles\":{{\"sources\":{{\"15m\":\"{s}\",\"1h\":\"{s}\",\"4h\":\"{s}\"}},\"rows\":\"/data\",\"fields\":{{\"time\":\"/0\",\"open\":\"/1\",\"high\":\"/2\",\"low\":\"/3\",\"close\":\"/4\",\"volume\":\"/5\"}},\"timeUnit\":\"ms\"}}}}",
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
    try std.testing.expect(parsed.value.object.get("tradeReady") == null);
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
    const messages = [_]types.ChatMessage{
        .{ .role = .assistant, .tool_calls = &calls },
        .{ .role = .tool, .content = output, .tool_call_id = "call_15m", .tool_name = "terminal", .tool_result_status = .success },
        .{ .role = .tool, .content = output, .tool_call_id = "call_1h", .tool_name = "terminal", .tool_result_status = .success },
        .{ .role = .tool, .content = output, .tool_call_id = "call_4h", .tool_name = "terminal", .tool_result_status = .success },
        .{ .role = .assistant, .tool_calls = &finalizer_calls },
    };
    const args =
        \\{"market":{"venue":"demo","symbol":"BTCUSD","product":"perpetual","quote":"USD"},"onchainRoute":null,"summary":"verified","evidence":[],"candles":{"sources":{"15m":{"sourceToolCall":0,"resultId":null},"1h":{"sourceToolCall":1,"resultId":null},"4h":{"sourceToolCall":2,"resultId":null}},"rows":"","fields":{"time":"/0","open":"/1","high":"/2","low":"/3","close":"/4","volume":"/5"},"timeUnit":"ms"}}
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
    };
    const args =
        \\{"market":{"venue":"demo","symbol":"BTCUSD","product":"perpetual","quote":"USD"},"onchainRoute":null,"summary":"verified","evidence":[],"candles":{"sources":{"15m":{"sourceToolCall":0,"resultId":"15m"},"1h":{"sourceToolCall":0,"resultId":"1h"},"4h":{"sourceToolCall":0,"resultId":"4h"}},"rows":"","fields":{"time":"/0","open":"/1","high":"/2","low":"/3","close":"/4","volume":"/5"},"timeUnit":"ms"}}
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
