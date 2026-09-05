const std = @import("std");

pub const max_input_bytes = 16 * 1024 * 1024;
pub const max_records = 50;

/// A view over command output, never a command or an authority grant.
pub const Filter = struct {
    json_pointer: []const u8,
    contains: []const []const u8,

    pub fn validate(self: Filter) !void {
        if (self.json_pointer.len > 512 or
            (self.json_pointer.len != 0 and self.json_pointer[0] != '/')) return error.InvalidJsonPointer;
        var i: usize = 0;
        while (i < self.json_pointer.len) : (i += 1) {
            if (self.json_pointer[i] != '~') continue;
            i += 1;
            if (i == self.json_pointer.len or
                (self.json_pointer[i] != '0' and self.json_pointer[i] != '1')) return error.InvalidJsonPointer;
        }
        if (self.contains.len == 0 or self.contains.len > 32) return error.InvalidKeywords;
        for (self.contains) |keyword| {
            if (std.mem.trim(u8, keyword, " \t\r\n").len == 0 or keyword.len > 128) return error.InvalidKeywords;
        }
    }
};

fn resolve(alloc: std.mem.Allocator, root: *std.json.Value, pointer: []const u8) !*std.json.Value {
    if (pointer.len == 0) return root;
    var current = root;
    var parts = std.mem.splitScalar(u8, pointer[1..], '/');
    while (parts.next()) |part| {
        var token: std.ArrayList(u8) = .empty;
        defer token.deinit(alloc);
        var i: usize = 0;
        while (i < part.len) : (i += 1) {
            if (part[i] == '~') {
                i += 1;
                try token.append(alloc, if (part[i] == '0') '~' else '/');
            } else try token.append(alloc, part[i]);
        }
        current = switch (current.*) {
            .object => |*object| object.getPtr(token.items) orelse return error.PathNotFound,
            .array => |*array| blk: {
                if (token.items.len == 0 or (token.items.len > 1 and token.items[0] == '0')) return error.PathNotFound;
                const index = std.fmt.parseInt(usize, token.items, 10) catch return error.PathNotFound;
                if (index >= array.items.len) return error.PathNotFound;
                break :blk &array.items[index];
            },
            else => return error.PathNotFound,
        };
    }
    return current;
}

fn matches_text(text: []const u8, keywords: []const []const u8) bool {
    for (keywords) |keyword| {
        if (keyword.len > text.len) continue;
        for (0..text.len - keyword.len + 1) |i| {
            if (std.ascii.eqlIgnoreCase(text[i .. i + keyword.len], keyword)) return true;
        }
    }
    return false;
}

fn matches(value: std.json.Value, keywords: []const []const u8, depth: usize) !bool {
    if (depth > 64) return error.NestingLimit;
    switch (value) {
        .string, .number_string => |text| return matches_text(text, keywords),
        .array => |array| for (array.items) |item| {
            if (try matches(item, keywords, depth + 1)) return true;
        },
        .object => |object| {
            var it = object.iterator();
            while (it.next()) |entry| {
                if (matches_text(entry.key_ptr.*, keywords) or try matches(entry.value_ptr.*, keywords, depth + 1)) return true;
            }
        },
        else => {},
    }
    return false;
}

fn render(alloc: std.mem.Allocator, root: std.json.Value, matched: usize, returned: usize) ![]u8 {
    return std.json.Stringify.valueAlloc(alloc, .{
        .filter = .{
            .status = "complete",
            .matched = matched,
            .returned = returned,
            .truncated = returned < matched,
        },
        .output = root,
    }, .{});
}

/// Caller owns the result. Keeps the original envelope and complete matching
/// records, including dictionary keys. It never interprets API success or identity.
pub fn project(alloc: std.mem.Allocator, stdout: []const u8, filter: Filter, max_bytes: usize) ![]u8 {
    try filter.validate();
    if (stdout.len > max_input_bytes) return error.InputLimit;
    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    var scanner = std.json.Scanner.initCompleteInput(scratch, stdout);
    defer scanner.deinit();
    var depth: usize = 0;
    while (true) {
        const token = scanner.next() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidJson,
        };
        switch (token) {
            .object_begin, .array_begin => {
                depth += 1;
                if (depth > 64) return error.NestingLimit;
            },
            .object_end, .array_end => depth -= 1,
            .end_of_document => break,
            else => {},
        }
    }
    var root = std.json.parseFromSliceLeaky(std.json.Value, scratch, stdout, .{
        .allocate = .alloc_always,
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    const target = try resolve(scratch, &root, filter.json_pointer);
    const original = target.*;
    target.* = switch (original) {
        .array => .{ .array = std.array_list.Managed(std.json.Value).init(scratch) },
        .object => .{ .object = .{} },
        else => return error.ExpectedCollection,
    };
    // Reserve counters before adding records. Large unrelated envelope fields
    // must not silently disappear just to make the filtered result fit.
    const empty = try render(scratch, root, std.math.maxInt(usize), std.math.maxInt(usize));
    if (empty.len > max_bytes) return error.EnvelopeLimit;
    var used_bytes = empty.len;
    var matched: usize = 0;
    var returned: usize = 0;
    const count = switch (original) {
        .array => |a| a.items.len,
        .object => |o| o.count(),
        else => unreachable,
    };
    for (0..count) |i| {
        const key: ?[]const u8 = if (original == .object) original.object.keys()[i] else null;
        const item = if (original == .array) original.array.items[i] else original.object.values()[i];
        if (!(if (key) |k| matches_text(k, filter.contains) else false) and
            !try matches(item, filter.contains, 0)) continue;
        matched += 1;
        if (returned == max_records) continue;
        const encoded = try std.json.Stringify.valueAlloc(scratch, item, .{});
        const encoded_key = if (key) |k| try std.json.Stringify.valueAlloc(scratch, k, .{}) else "";
        const size = encoded.len + encoded_key.len + 2;
        if (size > max_bytes - used_bytes) continue;
        if (key) |k| {
            try target.object.put(scratch, k, item);
        } else try target.array.append(item);
        used_bytes += size;
        returned += 1;
    }
    return render(alloc, root, matched, returned);
}

test "output filter preserves envelope and whole records for multiple tickers" {
    const alloc = std.testing.allocator;
    const result = try project(alloc,
        \\{"code":"00000","data":[{"symbol":"BTCUSDT"},{"symbol":"RIRENUSDT","status":"online"},{"symbol":"RAPLDUSDT"}]}
    , .{ .json_pointer = "/data", .contains = &.{ "iren", "apld", "hut" } }, 4096);
    defer alloc.free(result);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, result, .{});
    defer parsed.deinit();
    const output = parsed.value.object.get("output").?.object;
    try std.testing.expectEqualStrings("00000", output.get("code").?.string);
    try std.testing.expectEqual(@as(usize, 2), output.get("data").?.array.items.len);
    try std.testing.expectEqual(@as(i64, 2), parsed.value.object.get("filter").?.object.get("matched").?.integer);
    try std.testing.expect(std.mem.find(u8, result, "BTCUSDT") == null);
}

test "output filter matches dictionary keys and escaped JSON pointers" {
    const alloc = std.testing.allocator;
    const result = try project(alloc, "{\"a/b\":{\"~\":{\"IRENx\":{\"status\":\"enabled\"},\"BTC\":{}}}}", .{
        .json_pointer = "/a~1b/~0",
        .contains = &.{"iren"},
    }, 4096);
    defer alloc.free(result);
    try std.testing.expect(std.mem.find(u8, result, "IRENx") != null);
    try std.testing.expect(std.mem.find(u8, result, "BTC") == null);
}

test "output filter distinguishes empty matches from invalid input" {
    const alloc = std.testing.allocator;
    const filter = Filter{ .json_pointer = "/data", .contains = &.{"IREN"} };
    try std.testing.expectError(error.InvalidJson, project(alloc, "CLI failed", filter, 4096));
    try std.testing.expectError(error.PathNotFound, project(alloc, "{}", filter, 4096));
    try std.testing.expectError(error.ExpectedCollection, project(alloc, "{\"data\":null}", filter, 4096));
    const result = try project(alloc, "{\"data\":[]}", filter, 4096);
    defer alloc.free(result);
    try std.testing.expect(std.mem.find(u8, result, "\"matched\":0") != null);
    try std.testing.expectError(error.InvalidJsonPointer, (Filter{ .json_pointer = "/~2", .contains = &.{"a"} }).validate());
    try std.testing.expectError(error.InvalidKeywords, (Filter{ .json_pointer = "", .contains = &.{} }).validate());
}

test "output filter reports omitted records without truncating JSON" {
    const alloc = std.testing.allocator;
    const result = try project(alloc, "[{\"symbol\":\"IREN\",\"detail\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}]", .{
        .json_pointer = "",
        .contains = &.{"IREN"},
    }, 150);
    defer alloc.free(result);
    try std.testing.expect(result.len <= 150);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, result, .{});
    defer parsed.deinit();
    const status = parsed.value.object.get("filter").?.object;
    try std.testing.expect(status.get("truncated").?.bool);
    try std.testing.expectEqual(@as(i64, 1), status.get("matched").?.integer);
    try std.testing.expectEqual(@as(i64, 0), status.get("returned").?.integer);
}

fn exercise_projection_allocations(alloc: std.mem.Allocator) !void {
    const result = try project(alloc, "{\"data\":[{\"symbol\":\"IREN\"}]}", .{ .json_pointer = "/data", .contains = &.{"IREN"} }, 4096);
    defer alloc.free(result);
}

test "output filter cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exercise_projection_allocations, .{});
}

test "output filter limits nesting and counts matches beyond returned records" {
    const alloc = std.testing.allocator;
    var text: std.Io.Writer.Allocating = .init(alloc);
    defer text.deinit();
    try text.writer.writeAll("[");
    for (0..60) |i| {
        if (i != 0) try text.writer.writeAll(",");
        try text.writer.writeAll("{\"symbol\":\"IREN\"}");
    }
    try text.writer.writeAll("]");
    const result = try project(alloc, text.written(), .{ .json_pointer = "", .contains = &.{"iren"} }, 4096);
    defer alloc.free(result);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, result, .{});
    defer parsed.deinit();
    const status = parsed.value.object.get("filter").?.object;
    try std.testing.expectEqual(@as(i64, 60), status.get("matched").?.integer);
    try std.testing.expectEqual(@as(i64, 50), status.get("returned").?.integer);
    try std.testing.expect(status.get("truncated").?.bool);
    var deep: [130]u8 = undefined;
    @memset(deep[0..65], '[');
    @memset(deep[65..], ']');
    try std.testing.expectError(error.NestingLimit, project(alloc, &deep, .{ .json_pointer = "", .contains = &.{"iren"} }, 4096));
}
