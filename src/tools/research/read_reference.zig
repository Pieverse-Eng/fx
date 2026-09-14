const std = @import("std");
const dispatch = @import("../../core/tooling/tool_dispatch.zig");
const io_mod = @import("../../core/shared/io.zig");

const Params = struct { id: []const u8 };
const Input = struct {
    parsed: std.json.Parsed(Params),
    fn deinit(ptr: *anyopaque, alloc: std.mem.Allocator) void {
        const self: *Input = @ptrCast(@alignCast(ptr));
        self.parsed.deinit();
        alloc.destroy(self);
    }
};
pub fn decode(ctx: dispatch.DispatchContext, args: []const u8) dispatch.DispatchError!dispatch.DecodeResult {
    const parsed = std.json.parseFromSlice(Params, ctx.allocator, args, .{ .allocate = .alloc_always }) catch
        return .{ .failure = try ctx.allocator.dupe(u8, "Supply an approved reference id, not a file path.") };
    errdefer parsed.deinit();
    if (parsed.value.id.len == 0 or parsed.value.id.len > 256) {
        const failure = try ctx.allocator.dupe(u8, "Invalid reference id.");
        parsed.deinit();
        return .{ .failure = failure };
    }
    const input = try ctx.allocator.create(Input);
    input.* = .{ .parsed = parsed };
    return .{ .input = .{ .ptr = input, .deinit_fn = Input.deinit } };
}
pub fn call(ctx: dispatch.DispatchContext, erased: dispatch.ToolInput) dispatch.DispatchError!dispatch.ToolResult {
    const id = erased.as(Input).parsed.value.id;
    const config = io_mod.getenv("FX_REFERENCE_FILES") orelse return .{ .failure = try ctx.allocator.dupe(u8, "No reference access was granted for this request.") };
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, config, .{}) catch
        return .{ .failure = try ctx.allocator.dupe(u8, "Invalid host reference configuration.") };
    defer parsed.deinit();
    const path = if (parsed.value == .object) parsed.value.object.get(id) else null;
    if (path == null or path.? != .string or !std.fs.path.isAbsolute(path.?.string))
        return .{ .failure = try ctx.allocator.dupe(u8, "Reference is not allowed in this request.") };
    // The host supplies exact files, never a directory or a model-provided path.
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path.?.string, .{}) catch
        return .{ .failure = try ctx.allocator.dupe(u8, "Approved reference is unavailable.") };
    defer file.close(io_mod.getIo());
    const contents = io_mod.readFileToEnd(ctx.allocator, &file, 1024 * 1024) catch
        return .{ .failure = try ctx.allocator.dupe(u8, "Reference is unreadable or exceeds the bounded limit.") };
    defer ctx.allocator.free(contents);
    if (!std.unicode.utf8ValidateSlice(contents)) return .{ .failure = try ctx.allocator.dupe(u8, "Reference is not UTF-8 text.") };
    // Cross-request artifacts carry an expiry. Knowledge files are plain text.
    if (std.json.parseFromSlice(std.json.Value, ctx.allocator, contents, .{})) |artifact| {
        defer artifact.deinit();
        if (artifact.value == .object) {
            if (artifact.value.object.get("expiresAt")) |expires| {
                if (expires != .integer or expires.integer <= io_mod.milliTimestamp())
                    return .{ .failure = try ctx.allocator.dupe(u8, "Reference expired; request fresh evidence.") };
            }
        }
    } else |_| {}
    return .{ .success = std.json.Stringify.valueAlloc(ctx.allocator, .{ .referenceId = id, .content = contents }, .{}) catch return error.OutOfMemory };
}
pub fn readsOnly(_: dispatch.ToolInput) bool {
    return true;
}
pub fn isIrreversible(_: dispatch.ToolInput) bool {
    return false;
}
