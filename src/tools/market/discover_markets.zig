const std = @import("std");
const dispatch = @import("../../core/tooling/tool_dispatch.zig");

const public_command = @import("public_market_command.zig");

const script = @embedFile("discover-markets.sh");

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
        return .{ .failure = try ctx.allocator.dupe(u8, "discover_markets requires a JSON object.") };
    };
    errdefer parsed.deinit();
    if (inputError(parsed.value)) |message| {
        const failure = try ctx.allocator.dupe(u8, message);
        parsed.deinit();
        return .{ .failure = failure };
    }
    const input = try ctx.allocator.create(Input);
    input.* = .{ .parsed = parsed };
    return .{ .input = .{ .ptr = input, .deinit_fn = Input.deinit } };
}

fn alphanumeric(value: []const u8) bool {
    if (value.len == 0 or value.len > 32) return false;
    for (value) |char| if (!std.ascii.isAlphanumeric(char)) return false;
    return true;
}

fn inputError(value: std.json.Value) ?[]const u8 {
    if (value != .object) return "discover_markets requires a JSON object.";
    const args = value.object;
    for (args.keys()) |key| {
        if (!oneOf(key, &.{ "tickers", "product", "quote" })) return "Unknown discover_markets argument.";
    }
    const tickers = args.get("tickers") orelse return "tickers is required.";
    if (tickers != .array or tickers.array.items.len == 0 or tickers.array.items.len > 64) return "tickers must contain 1 to 64 base tickers.";
    for (tickers.array.items) |ticker| {
        if (ticker != .string or !alphanumeric(ticker.string)) return "Use alphanumeric base tickers, not names, pairs, or commands.";
    }
    if (args.get("product")) |product| {
        if (product != .string or !oneOf(product.string, &.{ "spot", "perp", "all" })) return "product must be spot, perp, or all.";
    }
    if (args.get("quote")) |quote| {
        if (quote != .string or !alphanumeric(quote.string)) return "quote must be a currency ticker or ALL.";
    }
    return null;
}

fn oneOf(value: []const u8, options: []const []const u8) bool {
    for (options) |option| if (std.mem.eql(u8, value, option)) return true;
    return false;
}

fn command(alloc: std.mem.Allocator, input: *Input) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    // Embed the trusted program; never accept a script path or shell fragment.
    try out.writer.writeAll("exec bash --noprofile --norc -c '");
    for (script) |char| {
        if (char == '\'') try out.writer.writeAll("'\\''") else try out.writer.writeByte(char);
    }
    try out.writer.writeAll("' discover-markets");
    const args = input.parsed.value.object;
    for (args.get("tickers").?.array.items) |ticker| try out.writer.print(" {s}", .{ticker.string});
    if (args.get("product")) |product| try out.writer.print(" --product {s}", .{if (std.mem.eql(u8, product.string, "perp")) "perpetual" else product.string});
    if (args.get("quote")) |quote| try out.writer.print(" --quote {s}", .{quote.string});
    return out.toOwnedSlice();
}

pub fn call(ctx: dispatch.DispatchContext, erased: dispatch.ToolInput) dispatch.DispatchError!dispatch.ToolResult {
    var prefix: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer prefix.deinit();
    const args = command(ctx.allocator, erased.as(Input)) catch return error.OutOfMemory;
    defer ctx.allocator.free(args);
    public_command.prefix(ctx.allocator, &prefix.writer, ctx.workspace_root) catch return error.OutOfMemory;
    // command() already quotes the program; replace only the fixed executable prefix.
    prefix.writer.writeAll(args["exec bash --noprofile --norc -c ".len..]) catch return error.OutOfMemory;
    return public_command.execute(ctx, prefix.written());
}

pub fn readsOnly(_: dispatch.ToolInput) bool {
    return true;
}

pub fn isIrreversible(_: dispatch.ToolInput) bool {
    return false;
}

test "discover_markets validates typed inputs before building a command" {
    const alloc = std.testing.allocator;
    for ([_][]const u8{
        "{}",
        "{\"tickers\":[]}",
        "{\"tickers\":[\"BTC;id\"]}",
        "{\"tickers\":[\"$(id)\"]}",
        "{\"tickers\":[\"BTC/USDT\"]}",
        "{\"tickers\":[\"BTC\"],\"quote\":\"--help\"}",
        "{\"tickers\":[\"BTC\"],\"venues\":[\"binance\"]}",
        "{\"tickers\":[\"BTC\"],\"product\":\"future\"}",
        "{\"tickers\":[\"BTC\"],\"command\":\"id\"}",
    }) |invalid| {
        const decoded = try decode(.{ .allocator = alloc }, invalid);
        try std.testing.expect(decoded == .failure);
        alloc.free(decoded.failure);
    }
    const decoded = try decode(.{ .allocator = alloc }, "{\"tickers\":[\"crcl\",\"BTC\"],\"product\":\"perp\",\"quote\":\"ALL\"}");
    try std.testing.expect(decoded == .input);
    defer decoded.input.deinit(alloc);
    const cmd = try command(alloc, decoded.input.as(Input));
    defer alloc.free(cmd);
    try std.testing.expect(std.mem.endsWith(u8, cmd, "' discover-markets crcl BTC --product perpetual --quote ALL"));
}
