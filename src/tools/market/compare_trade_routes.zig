const std = @import("std");
const dispatch = @import("../../core/tooling/tool_dispatch.zig");
const public_command = @import("public_market_command.zig");
const script = "route_math=$(cat <<'FX_ROUTE_MATH'\n" ++ @embedFile("route_math.jq") ++ "\nFX_ROUTE_MATH\n)\n" ++ @embedFile("get-market-candles.sh") ++ "\n" ++ @embedFile("onchain-routes.sh") ++ "\n" ++ @embedFile("compare-trade-routes.sh") ++ "\nFX_MARKET_MODE=routes\n" ++ @embedFile("discover-markets.sh");
const Input = struct {
    parsed: std.json.Parsed(std.json.Value),
    fn deinit(ptr: *anyopaque, alloc: std.mem.Allocator) void {
        const self: *Input = @ptrCast(@alignCast(ptr));
        self.parsed.deinit();
        alloc.destroy(self);
    }
};
fn choice(value: std.json.Value, values: []const []const u8) bool {
    if (value != .string) return false;
    for (values) |v| if (std.mem.eql(u8, value.string, v)) return true;
    return false;
}
fn inputError(value: std.json.Value) ?[]const u8 {
    if (value != .object) return "Pass ticker, product, amount, optional currency/quote, and direction for perps.";
    const a = value.object;
    for (a.keys()) |key| {
        var known = false;
        for ([_][]const u8{ "ticker", "product", "amount", "currency", "quote", "direction" }) |k| if (std.mem.eql(u8, key, k)) {
            known = true;
        };
        if (!known) return "Unknown comparison parameter.";
    }
    const ticker = a.get("ticker") orelse return "ticker is required.";
    if (ticker != .string or ticker.string.len == 0 or ticker.string.len > 32) return "Use one base ticker.";
    for (ticker.string) |c| if (!std.ascii.isAlphanumeric(c)) return "Use one alphanumeric base ticker.";
    const product = a.get("product") orelse return "product is required: spot or perp.";
    if (!choice(product, &.{ "spot", "perp" })) return "product must be spot or perp.";
    const amount = a.get("amount") orelse return "amount is required.";
    if (amount != .string or amount.string.len == 0 or amount.string.len > 32) return "amount must be a positive decimal string.";
    for (amount.string) |c| if (!std.ascii.isDigit(c) and c != '.') return "amount must be a positive decimal string.";
    const n = std.fmt.parseFloat(f64, amount.string) catch return "Invalid amount.";
    if (!std.math.isFinite(n) or n <= 0 or n > 1_000_000_000) return "amount must be positive and no greater than 1000000000.";
    if (a.get("currency")) |c| if (!choice(c, &.{ "USD", "USDT", "USDC" })) return "currency must be USD, USDT, or USDC; default USDT.";
    if (a.get("quote")) |q| {
        if (q != .string or q.string.len == 0 or q.string.len > 32) return "quote must be a currency ticker or ALL.";
        for (q.string) |c| if (!std.ascii.isAlphanumeric(c)) return "quote must be a currency ticker or ALL.";
    }
    if (std.mem.eql(u8, product.string, "perp")) {
        if (!choice(a.get("direction") orelse return "Perps require direction: long or short.", &.{ "long", "short" })) return "Perps require direction: long or short.";
    } else if (a.get("direction") != null) return "Spot comparison supports buys only; omit direction.";
    return null;
}
pub fn decode(ctx: dispatch.DispatchContext, args: []const u8) dispatch.DispatchError!dispatch.DecodeResult {
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args, .{ .allocate = .alloc_always }) catch return .{ .failure = try ctx.allocator.dupe(u8, "Invalid comparison JSON.") };
    errdefer parsed.deinit();
    if (inputError(parsed.value)) |msg| {
        const failure = try ctx.allocator.dupe(u8, msg);
        parsed.deinit();
        return .{ .failure = failure };
    }
    const input = try ctx.allocator.create(Input);
    input.* = .{ .parsed = parsed };
    return .{ .input = .{ .ptr = input, .deinit_fn = Input.deinit } };
}
pub fn call(ctx: dispatch.DispatchContext, erased: dispatch.ToolInput) dispatch.DispatchError!dispatch.ToolResult {
    const a = erased.as(Input).parsed.value.object;
    var program: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer program.deinit();
    var json: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer json.deinit();
    std.json.Stringify.value(erased.as(Input).parsed.value, .{}, &json.writer) catch return error.OutOfMemory;
    program.writer.writeAll("route_input=") catch return error.OutOfMemory;
    public_command.writeQuoted(&program.writer, json.written()) catch return error.OutOfMemory;
    program.writer.writeAll("\n") catch return error.OutOfMemory;
    program.writer.writeAll(script) catch return error.OutOfMemory;
    var cmd: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer cmd.deinit();
    public_command.prefix(ctx.allocator, &cmd.writer, ctx.workspace_root) catch return error.OutOfMemory;
    public_command.writeQuoted(&cmd.writer, program.written()) catch return error.OutOfMemory;
    cmd.writer.print(" compare-trade-routes {s} --product {s}", .{ a.get("ticker").?.string, if (std.mem.eql(u8, a.get("product").?.string, "perp")) "perpetual" else "spot" }) catch return error.OutOfMemory;
    if (a.get("quote")) |q| cmd.writer.print(" --quote {s}", .{q.string}) catch return error.OutOfMemory;
    return public_command.execute(ctx, cmd.written(), .comparison);
}
pub fn readsOnly(_: dispatch.ToolInput) bool {
    return true;
}
pub fn isIrreversible(_: dispatch.ToolInput) bool {
    return false;
}
test "comparison validates budget product and direction" {
    const alloc = std.testing.allocator;
    for ([_][]const u8{ "{}", "{\"ticker\":\"BTC\",\"product\":\"perp\",\"amount\":\"1000\"}", "{\"ticker\":\"BTC\",\"product\":\"spot\",\"amount\":\"-1\"}", "{\"ticker\":\"$(id)\",\"product\":\"spot\",\"amount\":\"1000\"}" }) |s| {
        const r = try decode(.{ .allocator = alloc }, s);
        try std.testing.expect(r == .failure);
        alloc.free(r.failure);
    }
    for ([_][]const u8{ "{\"ticker\":\"CRCL\",\"product\":\"spot\",\"amount\":\"1000\"}", "{\"ticker\":\"BTC\",\"product\":\"perp\",\"direction\":\"short\",\"amount\":\"1000\",\"currency\":\"USD\"}" }) |s| {
        const r = try decode(.{ .allocator = alloc }, s);
        try std.testing.expect(r == .input);
        r.input.deinit(alloc);
    }
}
