const std = @import("std");
const builtin = @import("builtin");
const dispatch = @import("../../core/tooling/tool_dispatch.zig");
const runner = @import("../../core/execution/command_runner.zig");
const output_content = @import("../../core/tooling/command_output_content.zig");
const types = @import("../../core/shared/types.zig");
const max_output_bytes = 1024 * 1024;

pub fn writeQuoted(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeByte('\'');
    for (value) |char| {
        if (char == '\'') try writer.writeAll("'\\''") else try writer.writeByte(char);
    }
    try writer.writeByte('\'');
}

pub fn prefix(alloc: std.mem.Allocator, writer: *std.Io.Writer, workspace: []const u8) !void {
    try writer.writeAll("FX_MARKET_CACHE_DIR=");
    var path: std.Io.Writer.Allocating = .init(alloc);
    defer path.deinit();
    try path.writer.print("{s}/.fx/market-cache/v1", .{workspace});
    try writeQuoted(writer, path.written());
    try writer.writeAll(" exec bash --noprofile --norc -c ");
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

pub fn execute(ctx: dispatch.DispatchContext, cmd: []const u8, shape: enum { markets, comparison }) dispatch.DispatchError!dispatch.ToolResult {
    if (comptime !std.process.can_spawn or builtin.os.tag == .windows) {
        return .{ .failure = try ctx.allocator.dupe(u8, "Public market tools require a native host with Bash 4+, jq, GNU timeout, curl, and the venue CLIs.") };
    } else {
        if (ctx.captured_command_host != .native) return .{ .failure = try ctx.allocator.dupe(u8, "Public market tools require native venue CLI execution.") };
        var arena = std.heap.ArenaAllocator.init(ctx.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var capture = Capture{ .stdout = .init(alloc) };
        // Reuse FX's finite timeout, cancellation and process-group cleanup.
        const result = runner.executeCommandInEnvironment(.{
            .max_command_output_bytes = 4096,
            .timeout_ms = 180_000,
            .cancel_flag = ctx.cancel_flag,
            .callback_projection = .raw,
            .output_chunk_ctx = &capture,
            .on_output_chunk = Capture.append,
        }, alloc, cmd, ctx.workspace_root, .{ .clean = "/bin/bash" }) catch |err| {
            return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "Public market query failed: {s}. Coverage is unresolved.", .{@errorName(err)}) };
        };
        if (result.cancelled) return error.Cancelled;
        const status = result.command_result orelse return .{ .failure = try ctx.allocator.dupe(u8, "Public market query returned no execution status.") };
        if (status.timed_out or status.output_incomplete or status.termination_indeterminate or status.signal != null or status.exit_code == null or status.exit_code.? > 1) {
            return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "Public market query did not finish successfully; coverage is unresolved. {s}", .{result.output}) };
        }
        const text = std.mem.trim(u8, capture.stdout.written(), " \r\n\t");
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, text, .{}) catch {
            return .{ .failure = try ctx.allocator.dupe(u8, "Public market query returned incomplete or invalid JSON; coverage is unresolved.") };
        };
        const valid_shape = valid: {
            if (parsed.value != .object) break :valid false;
            const object = parsed.value.object;
            switch (shape) {
                .markets => break :valid object.get("results") != null and object.get("errors") != null,
                .comparison => {
                    const route = object.get("bestRoute") orelse break :valid false;
                    const ranked_routes = object.get("rankedRoutes") orelse break :valid false;
                    const gaps = object.get("gaps") orelse break :valid false;
                    break :valid object.get("markets") != null and (route == .object or route == .null) and ranked_routes == .array and gaps == .array;
                },
            }
        };
        if (!valid_shape) return .{ .failure = try ctx.allocator.dupe(u8, "Public market query returned an invalid result shape.") };
        // Exit 1 preserves useful results alongside per-venue coverage errors.
        return .{ .success = try ctx.allocator.dupe(u8, text) };
    }
}
