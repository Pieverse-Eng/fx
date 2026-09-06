const std = @import("std");
const builtin = @import("builtin");
const dispatch = @import("../../core/tooling/tool_dispatch.zig");
const runner = @import("../../core/execution/command_runner.zig");
const output_content = @import("../../core/tooling/command_output_content.zig");
const types = @import("../../core/shared/types.zig");

const script = @embedFile("discover-markets.sh");
const max_output_bytes = 1024 * 1024;

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

const Capture = struct {
    stdout: std.Io.Writer.Allocating,

    fn append(ptr: *anyopaque, _: ?types.ToolLifecycleId, stream: output_content.Stream, chunk: []const u8) !void {
        const self: *Capture = @ptrCast(@alignCast(ptr));
        if (stream != .stdout) return;
        if (self.stdout.written().len + chunk.len > max_output_bytes) return error.OutputTooLarge;
        try self.stdout.writer.writeAll(chunk);
    }
};

pub fn call(ctx: dispatch.DispatchContext, erased: dispatch.ToolInput) dispatch.DispatchError!dispatch.ToolResult {
    if (comptime !std.process.can_spawn or builtin.os.tag == .windows) {
        return .{ .failure = try ctx.allocator.dupe(u8, "discover_markets requires a native host with Bash 4+, jq, GNU timeout, curl, and the venue CLIs.") };
    } else {
        if (ctx.captured_command_host != .native) return .{ .failure = try ctx.allocator.dupe(u8, "discover_markets requires native venue CLI execution.") };
        var arena = std.heap.ArenaAllocator.init(ctx.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        const cmd = command(alloc, erased.as(Input)) catch return error.OutOfMemory;
        var capture = Capture{ .stdout = .init(alloc) };
        // Reuse FX's finite timeout, cancellation and process-group cleanup.
        const result = runner.executeCommandInEnvironment(.{
            .max_command_output_bytes = 4096,
            .timeout_ms = 90_000,
            .cancel_flag = ctx.cancel_flag,
            .callback_projection = .raw,
            .output_chunk_ctx = &capture,
            .on_output_chunk = Capture.append,
        }, alloc, cmd, ctx.workspace_root, .{ .clean = "/bin/bash" }) catch |err| {
            return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "Market discovery failed: {s}. Coverage is unresolved.", .{@errorName(err)}) };
        };
        if (result.cancelled) return error.Cancelled;
        const status = result.command_result orelse return .{ .failure = try ctx.allocator.dupe(u8, "Market discovery returned no execution status.") };
        if (status.timed_out or status.output_incomplete or status.termination_indeterminate or status.signal != null or status.exit_code == null or status.exit_code.? > 1) {
            return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "Market discovery did not finish successfully; coverage is unresolved. {s}", .{result.output}) };
        }
        const text = std.mem.trim(u8, capture.stdout.written(), " \r\n\t");
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, text, .{}) catch {
            return .{ .failure = try ctx.allocator.dupe(u8, "Market discovery returned incomplete or invalid JSON; coverage is unresolved.") };
        };
        if (parsed.value != .object or parsed.value.object.get("results") == null or parsed.value.object.get("errors") == null) return .{ .failure = try ctx.allocator.dupe(u8, "Market discovery returned an invalid result shape.") };
        // Exit 1 preserves useful results alongside per-venue coverage errors.
        return .{ .success = try ctx.allocator.dupe(u8, text) };
    }
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
