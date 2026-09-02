const std = @import("std");
const command_replay_store = @import("../../core/session/command_replay_store.zig");
const types = @import("../../core/shared/types.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");

const Allocator = std.mem.Allocator;
const max_source_bytes = 2 * 1024 * 1024;

pub fn readTerminalStdout(ctx: tool_dispatch.DispatchContext, source: std.json.Value) ![]u8 {
    return switch (source) {
        .string => |handle| readCapturedStdout(ctx, handle),
        .object => |object| readCurrentTurnTerminalStdout(ctx, object),
        else => error.InvalidToolResultSource,
    };
}

pub fn readCurrentTurnToolResult(
    ctx: tool_dispatch.DispatchContext,
    source: std.json.ObjectMap,
    expected_tool: []const u8,
) ![]u8 {
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
        if (call_index >= assistant.tool_calls.len) return error.ToolCallNotFound;
        const source_call = assistant.tool_calls[call_index];
        if (!std.mem.eql(u8, source_call.name, expected_tool)) return error.InvalidSourceTool;
        const result = findToolResult(ctx.current_turn_messages, message_index + 1, source_call.id) orelse
            return error.ToolResultNotFound;
        if (result.tool_name) |name| {
            if (!std.mem.eql(u8, name, expected_tool)) return error.InvalidSourceTool;
        }
        if (result.tool_result_status) |status| {
            if (status != .success) return error.SourceToolFailed;
        }
        return ctx.allocator.dupe(u8, result.content orelse return error.ToolResultMissing);
    }
    return error.ToolCallNotFound;
}

fn readCurrentTurnTerminalStdout(ctx: tool_dispatch.DispatchContext, source: std.json.ObjectMap) ![]u8 {
    const result_id = if (source.get("resultId")) |value|
        if (value == .null) null else try requireString(value)
    else
        null;
    const result = try readCurrentTurnToolResult(ctx, source, "terminal");
    defer ctx.allocator.free(result);
    if (result_id) |id| return batchChildStdout(ctx.allocator, result, id);
    return envelopeStdout(ctx.allocator, result);
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
        if (!std.mem.eql(u8, try requireString(try requireField(item, "status")), "success")) return error.SourceToolFailed;
        return envelopeStdout(alloc, try requireString(try requireField(item, "output")));
    }
    return error.BatchResultNotFound;
}

fn envelopeStdout(alloc: Allocator, content: []const u8) ![]u8 {
    const open = "<stdout>\n";
    const close = "\n</stdout>";
    const start = if (std.mem.find(u8, content, open)) |index| index + open.len else 0;
    const end = if (std.mem.findPos(u8, content, start, close)) |index| index else content.len;
    if (end < start) return error.InvalidCommandEnvelope;
    return alloc.dupe(u8, content[start..end]);
}

pub fn readCapturedStdout(ctx: tool_dispatch.DispatchContext, handle: []const u8) ![]u8 {
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
        if (output.items.len + frame.payload.len > max_source_bytes) return error.SourceTooLarge;
        try output.appendSlice(ctx.allocator, frame.payload);
    }
    return output.toOwnedSlice(ctx.allocator);
}

pub fn resolvePointer(alloc: Allocator, root: std.json.Value, pointer: []const u8) !std.json.Value {
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

pub fn requireField(object: std.json.ObjectMap, name: []const u8) !std.json.Value {
    return object.get(name) orelse error.MissingField;
}

pub fn requireObject(value: std.json.Value) !std.json.ObjectMap {
    return if (value == .object) value.object else error.ExpectedObject;
}

pub fn requireArray(value: std.json.Value) !std.json.Array {
    return if (value == .array) value.array else error.ExpectedArray;
}

pub fn requireString(value: std.json.Value) ![]const u8 {
    return if (value == .string) value.string else error.ExpectedString;
}

pub fn numeric(value: std.json.Value) !f64 {
    const number: f64 = switch (value) {
        .integer => |item| @floatFromInt(item),
        .float => |item| item,
        .string => |text| std.fmt.parseFloat(f64, text) catch return error.InvalidNumber,
        else => return error.InvalidNumber,
    };
    if (!std.math.isFinite(number)) return error.InvalidNumber;
    return number;
}

pub fn nonNegativeIndex(value: std.json.Value) !usize {
    if (value != .integer or value.integer < 0) return error.InvalidToolCallIndex;
    return std.math.cast(usize, value.integer) orelse error.InvalidToolCallIndex;
}

test "JSON pointer resolves escaped object keys and arrays" {
    const alloc = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, "{\"data\":[[\"1\",\"2\"]],\"a/b\":3}", .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("2", (try resolvePointer(alloc, parsed.value, "/data/0/1")).string);
    try std.testing.expectEqual(@as(i64, 3), (try resolvePointer(alloc, parsed.value, "/a~1b")).integer);
}
