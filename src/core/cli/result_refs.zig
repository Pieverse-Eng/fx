const std = @import("std");
const Allocator = std.mem.Allocator;

pub const prompt =
    \\# Result reference output
    \\Result references are enabled for this JSON request. When returning tool JSON,
    \\return only {"result_refs":["call_id", "another_call_id"]}, using the exact
    \\result_ref values from the "FX result reference:" lines in tool output, in the
    \\desired result order. Copy these values exactly; never invent IDs or infer them
    \\from tool names, call order, or provider metadata. Select all relevant
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

    /// Capture before annotating. Only retained results receive a model-visible
    /// reference. The caller owns the annotation using output_alloc; originals
    /// remain owned by the store. Serialize access with capture/resolve.
    pub fn captureForModel(self: *Store, store_alloc: Allocator, output_alloc: Allocator, id: []const u8, json: []const u8) !?[]u8 {
        const count = self.entries.items.len;
        self.capture(store_alloc, id, json);
        if (self.entries.items.len == count) return null;
        var output = std.Io.Writer.Allocating.init(output_alloc);
        defer output.deinit();
        try output.writer.writeAll("FX result reference: ");
        try std.json.Stringify.value(.{ .result_ref = id }, .{}, &output.writer);
        try output.writer.writeAll("\n");
        try output.writer.writeAll(json);
        return try output.toOwnedSlice();
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

test "result references expose exact escaped IDs in model text without altering originals" {
    const alloc = std.testing.allocator;
    var store: Store = .{};
    defer store.deinit(alloc);
    const id = "call_U3SlTnjI93cBmb9Bw7TlvJIo\"\\\n";
    const original = " {\"results\":[],\"errors\":[\"missing venue\"]} ";
    const model_output = (try store.captureForModel(alloc, alloc, id, original)).?;
    defer alloc.free(model_output);
    const prefix = "FX result reference: ";
    try std.testing.expect(std.mem.startsWith(u8, model_output, prefix));
    const end = std.mem.findScalar(u8, model_output, '\n').?;
    const reference = try std.json.parseFromSlice(struct { result_ref: []const u8 }, alloc, model_output[prefix.len..end], .{});
    defer reference.deinit();
    try std.testing.expectEqualStrings(id, reference.value.result_ref);
    try std.testing.expectEqualStrings(original, model_output[end + 1 ..]);
    var answer = std.Io.Writer.Allocating.init(alloc);
    defer answer.deinit();
    try std.json.Stringify.value(.{ .result_refs = .{reference.value.result_ref} }, .{}, &answer.writer);
    const resolved = (try store.resolve(alloc, answer.written())).?;
    defer alloc.free(resolved);
    try std.testing.expectEqualStrings(original, resolved);
    try std.testing.expectError(error.UnknownResultReference, store.resolve(alloc, "{\"result_refs\":[\"call_1\"]}"));
    try std.testing.expectEqual(null, try store.captureForModel(alloc, alloc, "text", "non-JSON output"));
    store.bytes = Store.max_bytes;
    try std.testing.expectEqual(null, try store.captureForModel(alloc, alloc, "overflow", "{}"));
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
