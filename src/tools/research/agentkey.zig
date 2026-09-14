const std = @import("std");
const builtin = @import("builtin");
const dispatch = @import("../../core/tooling/tool_dispatch.zig");
const runner = @import("../../core/execution/command_runner.zig");
const output_content = @import("../../core/tooling/command_output_content.zig");
const types = @import("../../core/shared/types.zig");
const shell_quote = @import("../market/public_market_command.zig");

const Operation = enum { discover, describe, execute, request };
const Input = struct {
    operation: Operation,
    parsed: std.json.Parsed(std.json.Value),
    fn deinit(ptr: *anyopaque, alloc: std.mem.Allocator) void {
        const self: *Input = @ptrCast(@alignCast(ptr));
        self.parsed.deinit();
        alloc.destroy(self);
    }
};
fn text(value: std.json.Value, max: usize) bool {
    return value == .string and value.string.len > 0 and value.string.len <= max;
}
fn valid(operation: Operation, value: std.json.Value) bool {
    if (value != .object) return false;
    const object = value.object;
    for (object.keys()) |key| {
        const known = switch (operation) {
            .discover => std.mem.eql(u8, key, "query") or std.mem.eql(u8, key, "prefix"),
            .describe => std.mem.eql(u8, key, "name"),
            .execute => std.mem.eql(u8, key, "name") or std.mem.eql(u8, key, "params_json") or std.mem.eql(u8, key, "maxCredits"),
            .request => std.mem.eql(u8, key, "requestId"),
        };
        if (!known) return false;
    }
    switch (operation) {
        .discover => {
            if (object.get("query")) |q| if (!text(q, 2000)) return false;
            if (object.get("prefix")) |p| if (!text(p, 200)) return false;
        },
        .describe, .execute => {
            if (!text(object.get("name") orelse return false, 200)) return false;
            if (operation == .execute) {
                const params = object.get("params_json") orelse return false;
                if (!text(params, 48 * 1024)) return false;
                if (object.get("maxCredits")) |ceiling| {
                    if (!text(ceiling, 20)) return false;
                    for (ceiling.string) |char| if (!std.ascii.isDigit(char) and char != '.') return false;
                }
            }
        },
        .request => {
            const id = object.get("requestId") orelse return false;
            if (id != .string or id.string.len != 64) return false;
            for (id.string) |char| if (!std.ascii.isDigit(char) and !(char >= 'a' and char <= 'f')) return false;
        },
    }
    return true;
}
fn decode(ctx: dispatch.DispatchContext, args: []const u8, operation: Operation) dispatch.DispatchError!dispatch.DecodeResult {
    if (args.len > 48 * 1024) return .{ .failure = try ctx.allocator.dupe(u8, "AgentKey arguments exceed the bounded request limit.") };
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args, .{ .allocate = .alloc_always }) catch
        return .{ .failure = try ctx.allocator.dupe(u8, "AgentKey requires valid JSON arguments.") };
    errdefer parsed.deinit();
    if (!valid(operation, parsed.value)) {
        const message = try ctx.allocator.dupe(u8, "Invalid AgentKey arguments; follow the tool schema. Credentials and URLs are not arguments.");
        parsed.deinit();
        return .{ .failure = message };
    }
    const input = try ctx.allocator.create(Input);
    input.* = .{ .operation = operation, .parsed = parsed };
    return .{ .input = .{ .ptr = input, .deinit_fn = Input.deinit } };
}
pub fn decodeDiscover(ctx: dispatch.DispatchContext, args: []const u8) dispatch.DispatchError!dispatch.DecodeResult {
    return decode(ctx, args, .discover);
}
pub fn decodeDescribe(ctx: dispatch.DispatchContext, args: []const u8) dispatch.DispatchError!dispatch.DecodeResult {
    return decode(ctx, args, .describe);
}
pub fn decodeExecute(ctx: dispatch.DispatchContext, args: []const u8) dispatch.DispatchError!dispatch.DecodeResult {
    return decode(ctx, args, .execute);
}
pub fn decodeRequest(ctx: dispatch.DispatchContext, args: []const u8) dispatch.DispatchError!dispatch.DecodeResult {
    return decode(ctx, args, .request);
}

const Capture = struct {
    stdout: std.Io.Writer.Allocating,
    fn append(ptr: *anyopaque, _: ?types.ToolLifecycleId, stream: output_content.Stream, chunk: []const u8) !void {
        const self: *Capture = @ptrCast(@alignCast(ptr));
        if (stream != .stdout) return;
        if (self.stdout.written().len + chunk.len > 1024 * 1024) return error.OutputTooLarge;
        try self.stdout.writer.writeAll(chunk);
    }
};
pub fn call(ctx: dispatch.DispatchContext, erased: dispatch.ToolInput) dispatch.DispatchError!dispatch.ToolResult {
    if (comptime !std.process.can_spawn or builtin.os.tag == .windows) {
        return .{ .failure = try ctx.allocator.dupe(u8, "AgentKey research requires a native host with Python 3.") };
    } else {
        if (ctx.captured_command_host != .native) return .{ .failure = try ctx.allocator.dupe(u8, "AgentKey research requires native execution.") };
        const input = erased.as(Input);
        var program: std.Io.Writer.Allocating = .init(ctx.allocator);
        defer program.deinit();
        program.writer.writeAll("exec python3 -c ") catch return error.OutOfMemory;
        shell_quote.writeQuoted(&program.writer, @embedFile("agentkey.py")) catch return error.OutOfMemory;
        program.writer.print(" {s} ", .{@tagName(input.operation)}) catch return error.OutOfMemory;
        const args = std.json.Stringify.valueAlloc(ctx.allocator, input.parsed.value, .{}) catch return error.OutOfMemory;
        defer ctx.allocator.free(args);
        shell_quote.writeQuoted(&program.writer, args) catch return error.OutOfMemory;
        var arena = std.heap.ArenaAllocator.init(ctx.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var capture = Capture{ .stdout = .init(alloc) };
        const result = runner.executeCommandInEnvironment(.{
            .max_command_output_bytes = 4096,
            .timeout_ms = 140_000,
            .cancel_flag = ctx.cancel_flag,
            .callback_projection = .raw,
            .output_chunk_ctx = &capture,
            .on_output_chunk = Capture.append,
        }, alloc, program.written(), ctx.workspace_root, .{ .clean = "/bin/bash" }) catch
            return .{ .failure = try ctx.allocator.dupe(u8, "AgentKey transport failed; execution may be indeterminate. Do not repeat a paid request.") };
        if (result.cancelled) return error.Cancelled;
        const status = result.command_result orelse return .{ .failure = try ctx.allocator.dupe(u8, "AgentKey execution status unavailable; do not repeat execute.") };
        if (status.exit_code == null or status.exit_code.? != 0 or status.timed_out or status.output_incomplete or status.termination_indeterminate or status.signal != null)
            return .{ .failure = try ctx.allocator.dupe(u8, "AgentKey response unavailable; do not repeat execute. Recover a known receipt once.") };
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, capture.stdout.written(), .{}) catch
            return .{ .failure = try ctx.allocator.dupe(u8, "AgentKey returned invalid JSON; do not repeat execute.") };
        if (parsed.value != .object) return .{ .failure = try ctx.allocator.dupe(u8, "AgentKey returned an invalid response.") };
        return .{ .success = try ctx.allocator.dupe(u8, capture.stdout.written()) };
    }
}
pub fn readsOnly(_: dispatch.ToolInput) bool {
    return true;
}
pub fn isIrreversible(_: dispatch.ToolInput) bool {
    return false;
}
