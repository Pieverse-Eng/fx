const std = @import("std");
const dispatch = @import("../../core/tooling/tool_dispatch.zig");
const public_command = @import("public_market_command.zig");
const script = @embedFile("get-market-candles.sh") ++ "\nFX_MARKET_MODE=candles\n" ++ @embedFile("discover-markets.sh");

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
        const failure = try ctx.allocator.dupe(u8, "Pass only tickers: an array of 1 to 16 alphanumeric base tickers, not names, pairs, or commands.");
        parsed.deinit();
        return .{ .failure = failure };
    }
    const input = try ctx.allocator.create(Input);
    input.* = .{ .parsed = parsed };
    return .{ .input = .{ .ptr = input, .deinit_fn = Input.deinit } };
}

fn validInput(value: std.json.Value) bool {
    if (value != .object or value.object.count() != 1) return false;
    const tickers = value.object.get("tickers") orelse return false;
    if (tickers != .array or tickers.array.items.len == 0 or tickers.array.items.len > 16) return false;
    for (tickers.array.items) |ticker| {
        if (ticker != .string or ticker.string.len == 0 or ticker.string.len > 32) return false;
        for (ticker.string) |char| if (!std.ascii.isAlphanumeric(char)) return false;
    }
    return true;
}

pub fn call(ctx: dispatch.DispatchContext, erased: dispatch.ToolInput) dispatch.DispatchError!dispatch.ToolResult {
    const cmd = command(ctx.allocator, ctx.workspace_root, erased.as(Input)) catch return error.OutOfMemory;
    defer ctx.allocator.free(cmd);
    return public_command.execute(ctx, cmd);
}

fn command(alloc: std.mem.Allocator, workspace: []const u8, input: *Input) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try public_command.prefix(alloc, &out.writer, workspace);
    try public_command.writeQuoted(&out.writer, script);
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
