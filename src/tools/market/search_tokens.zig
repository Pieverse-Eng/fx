const std = @import("std");
const builtin = @import("builtin");
const dispatch = @import("../../core/tooling/tool_dispatch.zig");
const runner = @import("../../core/execution/command_runner.zig");
const io_mod = @import("../../core/shared/io.zig");
const types = @import("../../core/shared/types.zig");
const output_content = @import("../../core/tooling/command_output_content.zig");
const public_command = @import("public_market_command.zig");

const endpoint = "https://copenapi.bgwapi.io/market/v3/coin/search";
const path = "/market/v3/coin/search";
const candidate_limit = 20;
const supplemental_chains = [_][]const u8{ "bnb", "sol", "robinhood" };
const Params = struct { query: []const u8, chain: ?[]const u8 = null };
const Input = struct {
    parsed: std.json.Parsed(Params),

    fn deinit(ptr: *anyopaque, alloc: std.mem.Allocator) void {
        const input: *Input = @ptrCast(@alignCast(ptr));
        input.parsed.deinit();
        alloc.destroy(input);
    }
};

pub fn decode(ctx: dispatch.DispatchContext, arguments: []const u8) dispatch.DispatchError!dispatch.DecodeResult {
    const parsed = std.json.parseFromSlice(Params, ctx.allocator, arguments, .{ .allocate = .alloc_always }) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "Pass query and optional chain.") };
    };
    errdefer parsed.deinit();
    const params = parsed.value;
    const query = std.mem.trim(u8, params.query, " \t\r\n");
    var valid = query.len > 0 and params.query.len <= 256 and std.unicode.utf8ValidateSlice(params.query);
    for (params.query) |char| if (char < 0x20 or char == 0x7f) {
        valid = false;
    };
    if (params.chain) |chain| {
        valid = valid and chain.len > 0 and chain.len <= 32;
        for (chain) |char| if (!std.ascii.isAlphanumeric(char) and char != '-' and char != '_') {
            valid = false;
        };
    }
    if (!valid) {
        const failure = try ctx.allocator.dupe(u8, "Use a nonempty query (up to 256 bytes) and an optional chain code.");
        parsed.deinit();
        return .{ .failure = failure };
    }
    const input = try ctx.allocator.create(Input);
    input.* = .{ .parsed = parsed };
    return .{ .input = .{ .ptr = input, .deinit_fn = Input.deinit } };
}

fn command(alloc: std.mem.Allocator, params: Params, timestamp: i64) ![]u8 {
    const body = try std.json.Stringify.valueAlloc(alloc, .{ .keyword = params.query, .limit = candidate_limit, .chain = params.chain, .order_by = "liquidity" }, .{ .emit_null_optional_fields = false });
    defer alloc.free(body);
    const signed = try std.fmt.allocPrint(alloc, "POST{s}{s}{d}", .{ path, body, timestamp });
    defer alloc.free(signed);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(signed, &digest, .{});
    const signature = std.fmt.bytesToHex(digest, .lower);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    // Fixed public endpoint and headers; no wallet credentials or user shell fragments.
    try out.writer.writeAll("exec curl -q -fsS --proto '=https' --connect-timeout 10 --max-time 30 --max-filesize 1048576 " ++ endpoint ++
        " -H 'Content-Type: application/json' -H 'channel: toc_agent' -H 'brand: toc_agent'" ++
        " -H 'clientversion: 10.0.0' -H 'language: en' -H 'token: toc_agent'");
    try out.writer.print(" -H 'X-SIGN: 0x{s}' -H 'X-TIMESTAMP: {d}' --data-raw ", .{ signature, timestamp });
    try public_command.writeQuoted(&out.writer, body);
    return out.toOwnedSlice();
}

const Token = struct {
    name: []const u8,
    symbol: []const u8,
    chain: []const u8,
    contract: []const u8,
    twitter: ?[]const u8,
    website: ?[]const u8,
    telegram: ?[]const u8,
};

fn socialLink(value: std.json.Value, key: []const u8) ?[]const u8 {
    const field = value.object.get(key) orelse return null;
    if (field != .string or std.mem.trim(u8, field.string, " \t\r\n").len == 0) return null;
    return field.string;
}

fn tokenField(value: std.json.Value, key: []const u8) ![]const u8 {
    if (value != .object) return error.InvalidResponse;
    const field = value.object.get(key) orelse return error.InvalidResponse;
    if (field != .string or field.string.len == 0) return error.InvalidResponse;
    return field.string;
}

// Provider ordering can prioritize unrelated matches. Rank exact identities first,
// then reported liquidity, without treating missing liquidity as zero.
fn candidateList(value: std.json.Value) ![]std.json.Value {
    if (value != .object) return error.InvalidResponse;
    const status = value.object.get("status") orelse return error.InvalidResponse;
    if (status != .integer or status.integer != 0) return error.ProviderError;
    const data = value.object.get("data") orelse return error.InvalidResponse;
    if (data != .object) return error.InvalidResponse;
    const list = data.object.get("list") orelse return error.InvalidResponse;
    if (list != .array) return error.InvalidResponse;
    return list.array.items;
}

fn liquidity(value: std.json.Value) ?f64 {
    const field = value.object.get("liquidity") orelse return null;
    const amount: f64 = switch (field) {
        .integer => @floatFromInt(field.integer),
        .float => field.float,
        .string => std.fmt.parseFloat(f64, field.string) catch return null,
        else => return null,
    };
    return if (std.math.isFinite(amount) and amount >= 0) amount else null;
}

fn matchRank(token: Token, query: []const u8) u8 {
    const q = std.mem.trim(u8, query, " $\t\r\n");
    const evm_address = q.len == 42 and std.mem.startsWith(u8, q, "0x");
    if (std.mem.eql(u8, q, token.contract) or
        (evm_address and std.ascii.eqlIgnoreCase(q, token.contract))) return 3;
    // Never replace an explicitly supplied EVM address with a name match.
    if (evm_address) return 0;
    if (std.ascii.eqlIgnoreCase(q, token.symbol) or std.ascii.eqlIgnoreCase(q, token.name)) return 2;
    return 1;
}

fn response(alloc: std.mem.Allocator, text: []const u8, params: Params) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, text, .{});
    defer parsed.deinit();
    const list = try candidateList(parsed.value);
    var best: ?Token = null;
    var best_rank: u8 = 0;
    var best_liquidity: f64 = -1;
    for (list) |entry| {
        const token = Token{
            .name = try tokenField(entry, "name"),
            .symbol = try tokenField(entry, "symbol"),
            .chain = try tokenField(entry, "chain"),
            .contract = try tokenField(entry, "contract"),
            .twitter = socialLink(entry, "twitter"),
            .website = socialLink(entry, "website"),
            .telegram = socialLink(entry, "telegram"),
        };
        if (params.chain) |chain| if (!std.ascii.eqlIgnoreCase(chain, token.chain)) return error.ChainFilterMismatch;
        const rank = matchRank(token, params.query);
        if (rank == 0 or rank < best_rank) continue;
        if (rank > best_rank) {
            best_rank = rank;
            best = null;
            best_liquidity = -1;
        }
        const amount = liquidity(entry) orelse continue;
        if (amount > best_liquidity) {
            best = token;
            best_liquidity = amount;
        }
    }
    if (best) |token| return std.json.Stringify.valueAlloc(alloc, .{ .results = [_]Token{token} }, .{});
    if (best_rank > 0) return error.LiquidityUnavailable;
    return alloc.dupe(u8, "{\"results\":[]}");
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
        return .{ .failure = try ctx.allocator.dupe(u8, "search_tokens requires a native host with curl.") };
    } else {
        if (ctx.captured_command_host != .native) return .{ .failure = try ctx.allocator.dupe(u8, "search_tokens requires native command execution.") };
        var arena = std.heap.ArenaAllocator.init(ctx.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        const params = erased.as(Input).parsed.value;
        var candidates: std.ArrayList(std.json.Value) = .empty;
        // The global catalog can omit platform-chain matches even with a larger
        // limit. Supplement those chains internally; never expose a result limit.
        const count: usize = if (params.chain != null) 1 else 1 + supplemental_chains.len;
        for (0..count) |index| {
            const scope = if (index == 0) params.chain else supplemental_chains[index - 1];
            const cmd = command(alloc, .{ .query = params.query, .chain = scope }, io_mod.milliTimestamp()) catch return error.OutOfMemory;
            var capture = Capture{ .stdout = .init(alloc) };
            const result = runner.executeCommandInEnvironment(.{
                .max_command_output_bytes = 4096,
                .timeout_ms = 35_000,
                .cancel_flag = ctx.cancel_flag,
                .callback_projection = .raw,
                .output_chunk_ctx = &capture,
                .on_output_chunk = Capture.append,
            }, alloc, cmd, ctx.workspace_root, .{ .clean = "/bin/bash" }) catch |err| {
                if (err == error.Cancelled) return error.Cancelled;
                return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "Token search failed: {s}.", .{@errorName(err)}) };
            };
            if (result.cancelled) return error.Cancelled;
            const status = result.command_result orelse return .{ .failure = try ctx.allocator.dupe(u8, "Token search returned no execution status.") };
            if (status.timed_out or status.output_incomplete or status.termination_indeterminate or status.signal != null or status.exit_code != 0) {
                return .{ .failure = try ctx.allocator.dupe(u8, "Token search request failed or timed out; liquidity ranking is unavailable.") };
            }
            const parsed = std.json.parseFromSlice(std.json.Value, alloc, capture.stdout.written(), .{}) catch {
                return .{ .failure = try ctx.allocator.dupe(u8, "Token search response failed: invalid JSON.") };
            };
            const list = candidateList(parsed.value) catch |err| {
                return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "Token search response failed: {s}.", .{@errorName(err)}) };
            };
            if (scope) |chain| for (list) |entry| {
                const actual_chain = tokenField(entry, "chain") catch return .{ .failure = try ctx.allocator.dupe(u8, "Token search response failed: missing chain.") };
                if (!std.ascii.eqlIgnoreCase(chain, actual_chain)) return .{ .failure = try ctx.allocator.dupe(u8, "Token search response failed: chain filter mismatch.") };
            };
            try candidates.appendSlice(alloc, list);
        }
        const combined = try std.json.Stringify.valueAlloc(alloc, .{ .status = 0, .data = .{ .list = candidates.items } }, .{});
        const output = response(ctx.allocator, combined, params) catch |err| {
            return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "Token search response failed: {s}.", .{@errorName(err)}) };
        };
        return .{ .success = output };
    }
}

pub fn readsOnly(_: dispatch.ToolInput) bool {
    return true;
}
pub fn isIrreversible(_: dispatch.ToolInput) bool {
    return false;
}

test "search_tokens validates input and defaults" {
    const alloc = std.testing.allocator;
    for ([_][]const u8{ "{}", "{\"query\":\" \"}", "{\"query\":\"btc\",\"limit\":1}", "{\"query\":\"btc\",\"limit\":21}", "{\"query\":\"btc\",\"limit\":1.5}", "{\"query\":\"btc\",\"chain\":\"\"}", "{\"query\":\"btc\",\"venue\":\"bnb\"}" }) |invalid| {
        const decoded = try decode(.{ .allocator = alloc }, invalid);
        try std.testing.expect(decoded == .failure);
        alloc.free(decoded.failure);
    }
    const decoded = try decode(.{ .allocator = alloc }, "{\"query\":\"cashcat\"}");
    defer decoded.input.deinit(alloc);
    try std.testing.expect(decoded.input.as(Input).parsed.value.chain == null);
    const cmd = try command(alloc, decoded.input.as(Input).parsed.value, 123);
    defer alloc.free(cmd);
    try std.testing.expect(std.mem.endsWith(u8, cmd, "--data-raw '{\"keyword\":\"cashcat\",\"limit\":20,\"order_by\":\"liquidity\"}'"));
}

test "search_tokens prefers exact matches and preserves addresses and rejects incomplete responses" {
    const alloc = std.testing.allocator;
    const fixture = "{\"status\":0,\"data\":{\"list\":[{\"name\":\"First\",\"symbol\":\"A\",\"chain\":\"sol\",\"contract\":\"CaSe\",\"twitter\":\"https://x.com/example\",\"website\":\"https://example.com\",\"telegram\":\"https://t.me/example\",\"price\":1,\"liquidity\":100},{\"name\":\"Second\",\"symbol\":\"B\",\"chain\":\"bnb\",\"contract\":\"0xAB\",\"twitter\":\"\",\"website\":null,\"telegram\":42,\"liquidity\":200}]}}";
    const output = try response(alloc, fixture, .{ .query = "A" });
    defer alloc.free(output);
    try std.testing.expectEqualStrings("{\"results\":[{\"name\":\"First\",\"symbol\":\"A\",\"chain\":\"sol\",\"contract\":\"CaSe\",\"twitter\":\"https://x.com/example\",\"website\":\"https://example.com\",\"telegram\":\"https://t.me/example\"}]}", output);
    const empty = try response(alloc, "{\"status\":0,\"data\":{\"list\":[]}}", .{ .query = "A" });
    defer alloc.free(empty);
    try std.testing.expectEqualStrings("{\"results\":[]}", empty);
    try std.testing.expectError(error.ProviderError, response(alloc, "{\"status\":429}", .{ .query = "A" }));
    try std.testing.expectError(error.InvalidResponse, response(alloc, "{\"status\":0,\"data\":{}}", .{ .query = "A" }));
    try std.testing.expectError(error.InvalidResponse, response(alloc, "{\"status\":0,\"data\":{\"list\":[{}]}}", .{ .query = "A" }));
    try std.testing.expectError(error.ChainFilterMismatch, response(alloc, fixture, .{ .query = "A", .chain = "bnb" }));
}
