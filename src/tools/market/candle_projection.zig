const std = @import("std");

/// Indicator history remains in the retained original. Preserve exact numeric
/// lexemes and requested bounded indicator series in the model's compact view.
pub fn project(alloc: std.mem.Allocator, json: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json, .{ .parse_numbers = false }) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const rows = parsed.value.object.getPtr("results") orelse return null;
    if (rows.* != .array) return null;
    var changed = false;
    for (rows.array.items) |*row| {
        if (row.* != .object) continue;
        const indicators = row.object.get("indicators") orelse continue;
        if (indicators != .array or indicators.array.items.len == 0) continue;
        const frames = row.object.getPtr("timeframes") orelse continue;
        if (frames.* != .object) continue;
        for (frames.object.values()) |*frame| {
            if (frame.* != .object) continue;
            // put may grow the map, so reacquire the closed pointer afterwards.
            const original = frame.object.get("closed") orelse continue;
            if (original != .array or original.array.items.len <= 2) continue;
            try frame.object.put(parsed.arena.allocator(), "retainedClosedCandles", .{ .integer = @intCast(original.array.items.len) });
            frame.object.getPtr("closed").?.array.items = original.array.items[original.array.items.len - 2 ..];
            changed = true;
        }
    }
    return if (changed) try std.json.Stringify.valueAlloc(alloc, parsed.value, .{}) else null;
}

test "indicator views preserve exact values and gaps without dumping input history" {
    const alloc = std.testing.allocator;
    const original = "{\"results\":[{\"market\":{\"symbol\":\"BTCUSDT\"},\"indicators\":[{\"name\":\"sma\",\"value\":1.2300,\"gaps\":[\"missing bar\"]}],\"timeframes\":{\"1h\":{\"closed\":[[1],[2],[9007199254740993]],\"current\":[4]}}}]}";
    const view = (try project(alloc, original)).?;
    defer alloc.free(view);
    try std.testing.expect(std.mem.find(u8, view, "\"closed\":[[2],[9007199254740993]]") != null);
    try std.testing.expect(std.mem.find(u8, view, "\"value\":1.2300") != null);
    try std.testing.expect(std.mem.find(u8, view, "missing bar") != null);
    try std.testing.expect(std.mem.find(u8, view, "\"retainedClosedCandles\":3") != null);
    try std.testing.expectEqual(null, try project(alloc, "{\"results\":[{\"timeframes\":{\"1h\":{\"closed\":[[1],[2],[3]]}}}]}"));
}
