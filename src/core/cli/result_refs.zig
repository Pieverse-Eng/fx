const std = @import("std");
const Allocator = std.mem.Allocator;

pub const prompt =
    \\# Result reference output
    \\Result references are enabled for this JSON request. When returning tool JSON,
    \\return only {"result_refs":["call_id", "another_call_id"]}, using the exact
    \\tool call IDs from this request, in the desired result order. Select all relevant
    \\JSON object or array results, including earlier calls and reported errors/gaps.
    \\Do not copy their payloads into the final answer or rerun tools to reproduce them.
    \\FX retains the original results and assembles final_output without model rewriting.
    \\Do not reference calls from previous requests or non-JSON results. If there are
    \\no relevant JSON tool results, follow the ordinary response instructions.
;

/// Per-request originals, independent of model context truncation. The caller
/// serializes access when tool execution is parallel; no state is persisted.
pub const Store = struct {
    const Entry = struct { id: []u8, json: []u8 };
    const max_bytes = 8 * 1024 * 1024;
    const max_entries = 256;

    entries: std.ArrayList(Entry) = .empty,
    bytes: usize = 0,
    failure: ?anyerror = null,

    pub fn deinit(self: *Store, alloc: Allocator) void {
        for (self.entries.items) |entry| {
            alloc.free(entry.id);
            alloc.free(entry.json);
        }
        self.entries.deinit(alloc);
    }

    pub fn capture(self: *Store, alloc: Allocator, id: []const u8, json: []const u8) void {
        self.capture_checked(alloc, id, json) catch |err| {
            self.failure = err;
        };
    }

    fn capture_checked(self: *Store, alloc: Allocator, id: []const u8, json: []const u8) !void {
        const trimmed = std.mem.trim(u8, json, " \r\n\t");
        if (trimmed.len == 0 or (trimmed[0] != '{' and trimmed[0] != '[')) return;
        if (json.len +| id.len > max_bytes - self.bytes or self.entries.items.len >= max_entries)
            return error.ResultReferenceLimitExceeded;
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, json, .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return, // Only complete JSON objects/arrays are referenceable.
        };
        defer parsed.deinit();
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.id, id)) return error.DuplicateResultCallId;
        }
        const owned_id = try alloc.dupe(u8, id);
        errdefer alloc.free(owned_id);
        const owned_json = try alloc.dupe(u8, json);
        errdefer alloc.free(owned_json);
        try self.entries.append(alloc, .{ .id = owned_id, .json = owned_json });
        self.bytes += id.len + json.len;
    }

    /// Returns caller-owned assembled JSON, or null for an ordinary response.
    pub fn resolve(self: *const Store, alloc: Allocator, text: []const u8) !?[]u8 {
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, text, .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                const trimmed = std.mem.trimStart(u8, text, " \r\n\t");
                if (trimmed.len > 0 and trimmed[0] == '{' and
                    std.mem.startsWith(u8, std.mem.trimStart(u8, trimmed[1..], " \r\n\t"), "\"result_refs\""))
                    return error.InvalidResultReferences;
                return null;
            },
        };
        defer parsed.deinit();
        if (parsed.value != .object) return null;
        const refs = parsed.value.object.get("result_refs") orelse return null;
        if (parsed.value.object.count() != 1 or refs != .array or refs.array.items.len == 0 or refs.array.items.len > max_entries)
            return error.InvalidResultReferences;
        if (self.failure) |err| return err;

        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(alloc);
        const multiple = refs.array.items.len > 1;
        if (multiple) try output.append(alloc, '[');
        for (refs.array.items, 0..) |ref, index| {
            if (ref != .string or ref.string.len == 0) return error.InvalidResultReferences;
            for (refs.array.items[0..index]) |previous| {
                if (std.mem.eql(u8, previous.string, ref.string)) return error.DuplicateResultReference;
            }
            const json = for (self.entries.items) |entry| {
                if (std.mem.eql(u8, entry.id, ref.string)) break entry.json;
            } else return error.UnknownResultReference;
            if (index > 0) try output.append(alloc, ',');
            try output.appendSlice(alloc, json);
        }
        if (multiple) try output.append(alloc, ']');
        return try output.toOwnedSlice(alloc);
    }
};

test "result references retain original JSON and explicit gaps in selected order" {
    const alloc = std.testing.allocator;
    var store: Store = .{};
    defer store.deinit(alloc);
    store.capture(alloc, "markets", " {\"results\":[], \"errors\":[\"unavailable\"]} ");
    store.capture(alloc, "candles", "[1.2300,9007199254740993]");
    const single = (try store.resolve(alloc, "{\"result_refs\":[\"markets\"]}")).?;
    defer alloc.free(single);
    try std.testing.expectEqualStrings(" {\"results\":[], \"errors\":[\"unavailable\"]} ", single);
    const multiple = (try store.resolve(alloc, "{\"result_refs\":[\"candles\",\"markets\"]}")).?;
    defer alloc.free(multiple);
    try std.testing.expectEqualStrings("[[1.2300,9007199254740993], {\"results\":[], \"errors\":[\"unavailable\"]} ]", multiple);
}

test "result references reject invalid, duplicate, unknown and previous-run references" {
    const alloc = std.testing.allocator;
    var store: Store = .{};
    defer store.deinit(alloc);
    store.capture(alloc, "ok", "{}");
    store.capture(alloc, "text", "not JSON");
    for ([_][]const u8{ "{\"result_refs\":[]}", "{\"result_refs\":[1]}", "{\"result_refs\":\"ok\"}", "{\"result_refs\":[\"ok\"],\"extra\":1}", "{\"result_refs\":" }) |input| {
        try std.testing.expectError(error.InvalidResultReferences, store.resolve(alloc, input));
    }
    try std.testing.expectError(error.UnknownResultReference, store.resolve(alloc, "{\"result_refs\":[\"text\"]}"));
    try std.testing.expectError(error.DuplicateResultReference, store.resolve(alloc, "{\"result_refs\":[\"ok\",\"ok\"]}"));
    var fresh: Store = .{};
    try std.testing.expectError(error.UnknownResultReference, fresh.resolve(alloc, "{\"result_refs\":[\"ok\"]}"));
    try std.testing.expectEqual(null, try store.resolve(alloc, "ordinary answer"));
    try std.testing.expectEqual(null, try store.resolve(alloc, "{\"results\":[]}"));
}

test "result references own large originals and fail explicitly on capture limits" {
    const alloc = std.testing.allocator;
    var store: Store = .{};
    defer store.deinit(alloc);
    const source = try alloc.alloc(u8, 100_000);
    @memset(source, ' ');
    source[0] = '[';
    source[source.len - 1] = ']';
    store.capture(alloc, "large", source);
    alloc.free(source);
    const output = (try store.resolve(alloc, "{\"result_refs\":[\"large\"]}")).?;
    defer alloc.free(output);
    try std.testing.expectEqual(100_000, output.len);
    store.bytes = Store.max_bytes;
    store.capture(alloc, "overflow", "{}");
    try std.testing.expectError(error.ResultReferenceLimitExceeded, store.resolve(alloc, "{\"result_refs\":[\"large\"]}"));
}
