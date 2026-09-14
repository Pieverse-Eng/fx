const std = @import("std");
const tool_dispatch = @import("tool_dispatch.zig");

/// Effective tool registry and the named subsets used by agent roles.
pub const ToolSet = struct {
    registry: tool_dispatch.Registry,
    order: []const []const u8,
    read_only_tool_names: []const []const u8,
};

pub const empty = ToolSet{
    .registry = .{},
    .order = &.{},
    .read_only_tool_names = &.{},
};

/// Caller-owned selection of existing tools. An empty JSON array grants no tools.
pub const Selection = struct {
    tools: []tool_dispatch.Tool,
    names: [][]const u8,
    read_only_names: [][]const u8,

    pub fn init(alloc: std.mem.Allocator, source: ToolSet, json: []const u8) !Selection {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, json, .{}) catch |err| {
            if (err == error.OutOfMemory) return err;
            return error.InvalidToolSelection;
        };
        defer parsed.deinit();
        if (parsed.value != .array or parsed.value.array.items.len > source.registry.tools.len)
            return error.InvalidToolSelection;
        const entries = parsed.value.array.items;
        const tools = try alloc.alloc(tool_dispatch.Tool, entries.len);
        errdefer alloc.free(tools);
        const names = try alloc.alloc([]const u8, entries.len);
        errdefer alloc.free(names);
        var read_only: std.ArrayList([]const u8) = .empty;
        errdefer read_only.deinit(alloc);
        for (entries, 0..) |entry, index| {
            if (entry != .string) return error.InvalidToolSelection;
            const tool = source.registry.lookup(entry.string) orelse return error.InvalidToolSelection;
            for (names[0..index]) |prior| {
                if (std.mem.eql(u8, prior, tool.name)) return error.InvalidToolSelection;
            }
            tools[index] = tool.*;
            names[index] = tool.name;
            for (source.read_only_tool_names) |name| {
                if (std.mem.eql(u8, name, tool.name)) {
                    try read_only.append(alloc, tool.name);
                    break;
                }
            }
        }
        return .{ .tools = tools, .names = names, .read_only_names = try read_only.toOwnedSlice(alloc) };
    }

    pub fn deinit(self: *Selection, alloc: std.mem.Allocator) void {
        alloc.free(self.tools);
        alloc.free(self.names);
        alloc.free(self.read_only_names);
    }

    pub fn toolSet(self: *const Selection) ToolSet {
        return .{
            .registry = .{ .tools = self.tools },
            .order = self.names,
            .read_only_tool_names = self.read_only_names,
        };
    }
};
