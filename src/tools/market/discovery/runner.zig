const std = @import("std");
const builtin = @import("builtin");
const t = @import("types.zig");
const io_mod = @import("../../../core/shared/io.zig");
const commands = @import("../../../core/execution/command_runner.zig");
pub const max_catalog_bytes = 16 * 1024 * 1024;
pub const timeout_ms = 25000;
pub const Job = struct { source: t.Source, command: ?[]const u8 = null, payload: ?[]const u8 = null };
// Constant commands only. No ticker, quote, URL, shell fragment, or environment override comes from tool arguments.
pub const jobs = [_]Job{
    .{ .source = .aster, .command = "python3 /usr/local/lib/fx-market-data/aster_api.py exchange-info" },
    .{ .source = .binance_spot, .command = "binance-cli spot exchange-info --symbol-status TRADING --show-permission-sets false" },
    .{ .source = .bitget_spot, .command = "bgc market --action instruments --category SPOT" },
    .{ .source = .gate_spot, .command = "gate-cli cex spot market pairs --format json" },
    .{ .source = .kraken_spot, .command = "kraken pairs -o json" },
    .{ .source = .lighter, .command = "purr lighter markets --market-type all" },
    .{ .source = .okx_spot, .command = "okx market instruments --instType SPOT --json" },
    .{ .source = .hyper_dexs, .payload = "{\"type\":\"perpDexs\"}" },
    .{ .source = .binance_future, .command = "binance-cli futures-usds exchange-information" },
    .{ .source = .binance_assets, .command = "binance-cli request GET https://www.binance.com/bapi/asset/v2/public/asset/asset/get-all-asset" },
    .{ .source = .bitget_usdt, .command = "bgc market --action instruments --category USDT-FUTURES" },
    .{ .source = .bitget_usdc, .command = "bgc market --action instruments --category USDC-FUTURES" },
    .{ .source = .gate_future, .command = "gate-cli cex futures market contracts --settle usdt --format json" },
    .{ .source = .kraken_assets, .command = "kraken assets --asset-class tokenized_asset -o json" },
    .{ .source = .kraken_xstocks, .command = "kraken pairs --asset-class tokenized_asset -o json" },
    .{ .source = .kraken_future, .command = "kraken futures instruments -o json" },
    .{ .source = .okx_future, .command = "okx market instruments --instType SWAP --json" },
    .{ .source = .hyper_perps, .payload = "{\"type\":\"allPerpMetas\"}" },
    .{ .source = .hyper_spot, .payload = "{\"type\":\"spotMeta\"}" },
};
pub fn needed(source: t.Source, product: t.Product) bool {
    return switch (source) {
        .aster, .binance_future, .bitget_usdt, .bitget_usdc, .gate_future, .kraken_future, .okx_future, .hyper_dexs, .hyper_perps => product != .spot,
        .binance_spot, .bitget_spot, .gate_spot, .kraken_spot, .kraken_xstocks, .okx_spot => product != .future,
        // Authoritative alias catalogs are also needed to match stock-token futures.
        .binance_assets, .kraken_assets, .lighter, .hyper_spot => true,
    };
}
pub const Task = struct {
    job: Job,
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    catalog: t.Catalog,
};
pub const Batch = struct {
    tasks: []Task,
    next: std.atomic.Value(usize) = .init(0),
    cwd: []const u8,
    cancel: ?*std.atomic.Value(bool),
    pub fn worker(self: *Batch) void {
        while (true) {
            const n = self.next.fetchAdd(1, .monotonic);
            if (n >= self.tasks.len) return;
            const task = &self.tasks[n];
            if (self.cancel) |flag| if (flag.load(.acquire)) {
                task.catalog.failure = "Cancelled";
                continue;
            };
            const alloc = task.arena.allocator();
            const raw = fetch(alloc, task.job, self.cwd, self.cancel) catch |err| {
                task.catalog.failure = @errorName(err);
                continue;
            };
            const parsed = std.json.parseFromSlice(t.Value, alloc, raw, .{ .allocate = .alloc_always }) catch |err| {
                task.catalog.failure = @errorName(err);
                continue;
            };
            task.catalog.data = parsed.value;
        }
    }
};
fn fetch(alloc: t.Allocator, job: Job, cwd: []const u8, cancel: ?*std.atomic.Value(bool)) ![]const u8 {
    if (job.command) |command| {
        const result = try commands.executeCommand(.{ .max_command_output_bytes = max_catalog_bytes, .timeout_ms = timeout_ms, .cancel_flag = cancel }, alloc, command, cwd);
        if (result.cancelled) return error.Cancelled;
        const receipt = result.command_result orelse return error.MissingCommandReceipt;
        if (receipt != .foreground) return error.InvalidCommandReceipt;
        const f = receipt.foreground;
        if (f.timed_out) return error.Timeout;
        if (f.exit_code == null or f.exit_code.? != 0) return error.CommandFailed;
        if (f.stdout_bytes > max_catalog_bytes) return error.CatalogTooLarge;
        if (f.stdout_file) |path| {
            var file = try std.Io.Dir.cwd().openFile(io_mod.getIo(), path, .{});
            defer file.close(io_mod.getIo());
            return io_mod.readFileToEnd(alloc, &file, max_catalog_bytes);
        }
        if (f.truncated) return error.IncompleteCatalog;
        const begin = (std.mem.find(u8, result.output, "<stdout>\n") orelse return error.MissingStdout) + 9;
        const end = std.mem.lastIndexOf(u8, result.output, "\n</stdout>") orelse return error.MissingStdout;
        if (end < begin) return error.MissingStdout;
        return result.output[begin..end];
    }
    return httpWithDeadline(alloc, job.payload.?, cancel);
}
const HttpSelection = union(enum) { response: anyerror![]const u8, stopped: anyerror!void };
fn httpWithDeadline(alloc: t.Allocator, payload: []const u8, cancel: ?*std.atomic.Value(bool)) ![]const u8 {
    var buffer: [2]HttpSelection = undefined;
    var select: std.Io.Select(HttpSelection) = .init(io_mod.getIo(), &buffer);
    defer select.cancelDiscard();
    try select.concurrent(.response, http, .{ alloc, payload });
    try select.concurrent(.stopped, deadline, .{cancel});
    return switch (try select.await()) {
        .response => |r| try r,
        .stopped => |r| blk: {
            try r;
            break :blk error.Timeout;
        },
    };
}
fn deadline(cancel: ?*std.atomic.Value(bool)) !void {
    var elapsed: usize = 0;
    while (elapsed < timeout_ms) : (elapsed += 100) {
        if (cancel) |flag| if (flag.load(.acquire)) return error.Cancelled;
        try std.Io.sleep(io_mod.getIo(), .fromMilliseconds(100), .awake);
    }
}
fn http(alloc: t.Allocator, payload: []const u8) ![]const u8 {
    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();
    var env = if (builtin.is_test) try std.process.Environ.createMap(std.testing.environ, alloc) else try io_mod.cloneEnvironMap(alloc);
    defer env.deinit();
    try client.initDefaultProxies(alloc, &env);
    const buffer = try alloc.alloc(u8, max_catalog_bytes);
    var writer = std.Io.Writer.fixed(buffer);
    const response = try client.fetch(.{
        .location = .{ .url = "https://api.hyperliquid.xyz/info" },
        .method = .POST,
        .payload = payload,
        .headers = .{ .content_type = .{ .override = "application/json" }, .accept_encoding = .omit, .user_agent = .{ .override = "fx-market-discovery/1" } },
        .response_writer = &writer,
    });
    if (response.status.class() != .success) return error.HttpStatus;
    return writer.buffered();
}
