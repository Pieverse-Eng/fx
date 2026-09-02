const std = @import("std");
const builtin_skills = @import("../../builtins/skills.zig");
const io_mod = @import("../../core/shared/io.zig");
const types = @import("../../core/shared/types.zig");
const skill_runtime = @import("../../core/skills/skill_runtime.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const result_reader = @import("tool_result_reader.zig");

const Allocator = std.mem.Allocator;
const max_candidates = 16;
const max_book_levels = 4096;
const max_skill_bytes = 256 * 1024;
const max_fee_age_ms = 45 * std.time.ms_per_day;

pub const Input = struct {
    json: []u8,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.json);
        self.* = .{ .json = &.{} };
    }
};

const Side = enum { buy, sell };

const PublicFee = struct {
    bps: f64,
    source_url: []const u8,
    as_of: []const u8,
};

pub const RankedCandidate = struct {
    venue: []const u8,
    symbol: []const u8,
    product: []const u8,
    quote: []const u8,
    bestBid: f64,
    bestAsk: f64,
    bestPrice: f64,
    publicTakerFeeBps: f64,
    fullSpreadBps: f64,
    sideSpreadCostBps: f64,
    estimatedCostBps: f64,
    feeSourceUrl: []const u8,
    feeAsOf: []const u8,
    asOf: i64,
};

pub const ExcludedCandidate = struct {
    venue: []const u8,
    symbol: []const u8,
    reason: []const u8,
};

pub const Output = struct {
    method: []const u8 = "public_taker_fee_plus_spread",
    selected: ?RankedCandidate,
    alternatives: []const RankedCandidate,
    excluded: []const ExcludedCandidate,
    feesIncluded: bool = true,
    feeBasis: []const u8 = "public_base_taker",
};

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "rank_venue_costs arguments must be valid JSON") };
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, "rank_venue_costs arguments must be an object") };
    }
    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{ .json = try ctx.allocator.dupe(u8, args_json) };
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

pub fn validate(_: tool_dispatch.DispatchContext, _: tool_dispatch.ToolInput) tool_dispatch.DispatchError!?[]u8 {
    return null;
}

pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const result = rank(ctx, erased.as(Input).json) catch |err| {
        return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "rank_venue_costs failed: {s}", .{@errorName(err)}) };
    };
    return .{ .success = result };
}

fn rank(ctx: tool_dispatch.DispatchContext, input_json: []const u8) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    var arena_ctx = ctx;
    arena_ctx.allocator = arena_state.allocator();
    const result = try rankArena(arena_ctx, input_json);
    return ctx.allocator.dupe(u8, result);
}

fn rankArena(ctx: tool_dispatch.DispatchContext, input_json: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, ctx.allocator, input_json, .{});
    defer parsed.deinit();
    const root = try result_reader.requireObject(parsed.value);
    const side_text = try result_reader.requireString(try result_reader.requireField(root, "side"));
    const side: Side = if (std.mem.eql(u8, side_text, "buy"))
        .buy
    else if (std.mem.eql(u8, side_text, "sell"))
        .sell
    else
        return error.InvalidSide;
    const candidates = try result_reader.requireArray(try result_reader.requireField(root, "candidates"));
    if (candidates.items.len == 0 or candidates.items.len > max_candidates) return error.InvalidCandidateCount;

    var discovery = try builtin_skills.loadVisibleSkillsForTool(ctx.allocator, ctx.workspace_root, ctx.skills_dir);
    defer discovery.deinit(ctx.allocator);

    var ranked: std.ArrayList(RankedCandidate) = .empty;
    var excluded: std.ArrayList(ExcludedCandidate) = .empty;
    for (candidates.items) |candidate_value| {
        const candidate = try result_reader.requireObject(candidate_value);
        const venue = try boundedIdentity(try result_reader.requireString(try result_reader.requireField(candidate, "venue")));
        const symbol = try boundedIdentity(try result_reader.requireString(try result_reader.requireField(candidate, "symbol")));
        const product = try boundedProduct(try result_reader.requireString(try result_reader.requireField(candidate, "product")));
        const quote = try boundedIdentity(try result_reader.requireString(try result_reader.requireField(candidate, "quote")));
        const book = try result_reader.requireObject(try result_reader.requireField(candidate, "book"));

        const item = rankCandidate(ctx, discovery.skills, side, venue, symbol, product, quote, book) catch |err| {
            try excluded.append(ctx.allocator, .{
                .venue = venue,
                .symbol = symbol,
                .reason = exclusionReason(err),
            });
            continue;
        };
        for (ranked.items) |existing| {
            if (std.mem.eql(u8, existing.venue, item.venue) and std.mem.eql(u8, existing.symbol, item.symbol))
                return error.DuplicateCandidate;
        }
        try ranked.append(ctx.allocator, item);
    }
    std.mem.sort(RankedCandidate, ranked.items, {}, rankedLessThan);

    const selected: ?RankedCandidate = if (ranked.items.len == 0) null else ranked.items[0];
    const alternatives = if (ranked.items.len > 1) ranked.items[1..] else ranked.items[0..0];
    const output = Output{
        .selected = selected,
        .alternatives = alternatives,
        .excluded = excluded.items,
    };
    var writer: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer writer.deinit();
    try std.json.Stringify.value(output, .{}, &writer.writer);
    return writer.toOwnedSlice();
}

fn rankCandidate(
    ctx: tool_dispatch.DispatchContext,
    skills: []const skill_runtime.Skill,
    side: Side,
    venue: []const u8,
    symbol: []const u8,
    product: []const u8,
    quote: []const u8,
    book: std.json.ObjectMap,
) !RankedCandidate {
    const skill = uniqueSkill(skills, venue) orelse return error.VenueSkillUnavailable;
    const fee = try loadPublicFee(ctx, skill, product);
    const source = try result_reader.requireField(book, "source");
    const stdout = try result_reader.readTerminalStdout(ctx, source);
    defer ctx.allocator.free(stdout);
    const trimmed = std.mem.trim(u8, stdout, " \t\r\n");
    var parsed = try std.json.parseFromSlice(std.json.Value, ctx.allocator, trimmed, .{});
    defer parsed.deinit();

    if (book.get("identityPointer")) |pointer_value| {
        if (pointer_value != .null) {
            const identity = try result_reader.requireString(try result_reader.resolvePointer(
                ctx.allocator,
                parsed.value,
                try result_reader.requireString(pointer_value),
            ));
            if (!std.ascii.eqlIgnoreCase(identity, symbol)) return error.MarketIdentityMismatch;
        }
    }

    const bids = try result_reader.requireArray(try result_reader.resolvePointer(
        ctx.allocator,
        parsed.value,
        try result_reader.requireString(try result_reader.requireField(book, "bidsPointer")),
    ));
    const asks = try result_reader.requireArray(try result_reader.resolvePointer(
        ctx.allocator,
        parsed.value,
        try result_reader.requireString(try result_reader.requireField(book, "asksPointer")),
    ));
    const price_pointer = try result_reader.requireString(try result_reader.requireField(book, "pricePointer"));
    const size_pointer = try result_reader.requireString(try result_reader.requireField(book, "sizePointer"));
    const best_bid = try validateBookSide(ctx.allocator, bids, price_pointer, size_pointer, .buy);
    const best_ask = try validateBookSide(ctx.allocator, asks, price_pointer, size_pointer, .sell);
    if (best_bid >= best_ask) return error.CrossedBook;

    const mid = (best_bid + best_ask) / 2.0;
    const full_spread_bps = (best_ask - best_bid) / mid * 10_000.0;
    const side_spread_bps = switch (side) {
        .buy => (best_ask - mid) / mid * 10_000.0,
        .sell => (mid - best_bid) / mid * 10_000.0,
    };
    const estimated_cost_bps = fee.bps + side_spread_bps;
    if (!std.math.isFinite(estimated_cost_bps) or estimated_cost_bps < 0) return error.InvalidCost;
    return .{
        .venue = venue,
        .symbol = symbol,
        .product = product,
        .quote = quote,
        .bestBid = best_bid,
        .bestAsk = best_ask,
        .bestPrice = if (side == .buy) best_ask else best_bid,
        .publicTakerFeeBps = fee.bps,
        .fullSpreadBps = full_spread_bps,
        .sideSpreadCostBps = side_spread_bps,
        .estimatedCostBps = estimated_cost_bps,
        .feeSourceUrl = fee.source_url,
        .feeAsOf = fee.as_of,
        .asOf = io_mod.milliTimestamp(),
    };
}

fn validateBookSide(
    alloc: Allocator,
    levels: std.json.Array,
    price_pointer: []const u8,
    size_pointer: []const u8,
    side: Side,
) !f64 {
    if (levels.items.len == 0 or levels.items.len > max_book_levels) return error.InvalidBookDepth;
    var previous: ?f64 = null;
    for (levels.items) |level| {
        const price = try result_reader.numeric(try result_reader.resolvePointer(alloc, level, price_pointer));
        const size = try result_reader.numeric(try result_reader.resolvePointer(alloc, level, size_pointer));
        if (price <= 0 or size <= 0) return error.InvalidBookLevel;
        if (previous) |prior| switch (side) {
            .buy => if (price > prior) return error.UnsortedBook,
            .sell => if (price < prior) return error.UnsortedBook,
        };
        previous = price;
    }
    return result_reader.numeric(try result_reader.resolvePointer(alloc, levels.items[0], price_pointer));
}

fn uniqueSkill(skills: []const skill_runtime.Skill, name: []const u8) ?skill_runtime.Skill {
    var found: ?skill_runtime.Skill = null;
    for (skills) |skill| {
        if (!std.mem.eql(u8, skill.name, name)) continue;
        if (found != null) return null;
        found = skill;
    }
    return found;
}

fn loadPublicFee(ctx: tool_dispatch.DispatchContext, skill: skill_runtime.Skill, product: []const u8) !PublicFee {
    var opened = switch (try skill_runtime.openValidatedSkillCandidate(ctx.allocator, skill)) {
        .current => |candidate| candidate,
        else => return error.VenueSkillUnavailable,
    };
    defer opened.deinit();
    var file = try opened.openResource("SKILL.md");
    defer file.close(io_mod.getIo());
    const content = try io_mod.readFileToEnd(ctx.allocator, &file, max_skill_bytes);
    defer ctx.allocator.free(content);
    return parsePublicFee(ctx.allocator, content, product, io_mod.milliTimestamp());
}

fn parsePublicFee(alloc: Allocator, content: []const u8, product: []const u8, now_ms: i64) !PublicFee {
    var lines = std.mem.splitScalar(u8, content, '\n');
    if (!std.mem.eql(u8, lines.next() orelse return error.InvalidFeeMetadata, "---")) return error.InvalidFeeMetadata;
    var in_pieverse = false;
    var in_market_cost = false;
    var in_product = false;
    var market_search = false;
    var fee_text: ?[]const u8 = null;
    var source_url: ?[]const u8 = null;
    var as_of: ?[]const u8 = null;
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (std.mem.eql(u8, line, "---")) break;
        if (line.len > 0 and line[0] != ' ') {
            in_pieverse = false;
            in_market_cost = false;
            in_product = false;
        }
        if (std.mem.eql(u8, line, "  pieverse:")) {
            in_pieverse = true;
            continue;
        }
        if (!in_pieverse) continue;
        if (std.mem.eql(u8, line, "    marketSearch: true")) {
            market_search = true;
            continue;
        }
        if (std.mem.eql(u8, line, "    marketCost:")) {
            in_market_cost = true;
            in_product = false;
            continue;
        }
        if (in_market_cost and std.mem.startsWith(u8, line, "      ") and !std.mem.startsWith(u8, line, "        ")) {
            const candidate = std.mem.trim(u8, line[6..], " :\t\r");
            in_product = std.mem.eql(u8, candidate, product);
            continue;
        }
        if (in_market_cost and line.len > 0 and !std.mem.startsWith(u8, line, "      ")) {
            in_market_cost = false;
            in_product = false;
        }
        if (!in_product or !std.mem.startsWith(u8, line, "        ")) continue;
        const field = std.mem.trim(u8, line[8..], " \t\r");
        if (std.mem.startsWith(u8, field, "publicTakerFeeBps:"))
            fee_text = std.mem.trim(u8, field[18..], " \t")
        else if (std.mem.startsWith(u8, field, "sourceUrl:"))
            source_url = std.mem.trim(u8, field[10..], " \t")
        else if (std.mem.startsWith(u8, field, "asOf:"))
            as_of = std.mem.trim(u8, field[5..], " \t");
    }
    if (!market_search) return error.NotMarketSearchSkill;
    const fee = std.fmt.parseFloat(f64, fee_text orelse return error.FeeUnavailable) catch return error.InvalidFeeMetadata;
    if (!std.math.isFinite(fee) or fee < 0 or fee > 10_000) return error.InvalidFeeMetadata;
    const source = source_url orelse return error.FeeUnavailable;
    if (!std.mem.startsWith(u8, source, "https://") or source.len > 2048) return error.InvalidFeeMetadata;
    const date = as_of orelse return error.FeeUnavailable;
    if (date.len != 10) return error.InvalidFeeMetadata;
    const timestamp = try std.fmt.allocPrint(alloc, "{s}T00:00:00Z", .{date});
    defer alloc.free(timestamp);
    const fee_time = types.parseGatewayTimestamp(timestamp) catch return error.InvalidFeeMetadata;
    if (fee_time > now_ms + std.time.ms_per_day or now_ms - fee_time > max_fee_age_ms) return error.StaleFeeMetadata;
    return .{
        .bps = fee,
        .source_url = try alloc.dupe(u8, source),
        .as_of = try alloc.dupe(u8, date),
    };
}

fn boundedIdentity(value: []const u8) ![]const u8 {
    if (value.len == 0 or value.len > 128) return error.InvalidIdentity;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidIdentity;
    return value;
}

fn boundedProduct(value: []const u8) ![]const u8 {
    if (value.len == 0 or value.len > 64) return error.InvalidProduct;
    for (value) |byte| switch (byte) {
        'a'...'z', '0'...'9', '-' => {},
        else => return error.InvalidProduct,
    };
    return value;
}

fn exclusionReason(err: anyerror) []const u8 {
    return switch (err) {
        error.VenueSkillUnavailable => "venue skill unavailable or ambiguous",
        error.NotMarketSearchSkill => "venue skill is not enabled for market search",
        error.FeeUnavailable => "public base taker fee unavailable for product",
        error.StaleFeeMetadata => "public base taker fee evidence is stale",
        error.InvalidFeeMetadata => "public base taker fee metadata is invalid",
        error.MarketIdentityMismatch => "order book market identity does not match candidate",
        error.CrossedBook => "order book is crossed or locked",
        error.InvalidBookDepth, error.InvalidBookLevel, error.UnsortedBook => "order book is invalid",
        error.SourceToolFailed => "order book command failed",
        error.ToolCallNotFound, error.ToolResultNotFound, error.ToolResultMissing, error.BatchResultNotFound => "order book result unavailable",
        else => "order book could not be normalized",
    };
}

fn rankedLessThan(_: void, left: RankedCandidate, right: RankedCandidate) bool {
    if (left.estimatedCostBps != right.estimatedCostBps) return left.estimatedCostBps < right.estimatedCostBps;
    const venue_order = std.mem.order(u8, left.venue, right.venue);
    if (venue_order != .eq) return venue_order == .lt;
    return std.mem.lessThan(u8, left.symbol, right.symbol);
}

fn writeTempFile(tmp: *std.testing.TmpDir, sub_path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(sub_path)) |parent| {
        try tmp.dir.createDirPath(io_mod.getIo(), parent);
    }
    var file = try tmp.dir.createFile(std.testing.io, sub_path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), content);
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

test "public fee parser selects an exact product and rejects stale evidence" {
    const content =
        \\---
        \\name: demo
        \\metadata:
        \\  pieverse:
        \\    marketSearch: true
        \\    marketCost:
        \\      perpetual:
        \\        publicTakerFeeBps: 4.5
        \\        sourceUrl: https://demo.example/fees
        \\        asOf: 2026-09-03
        \\---
    ;
    const now = try types.parseGatewayTimestamp("2026-09-04T00:00:00Z");
    const fee = try parsePublicFee(std.testing.allocator, content, "perpetual", now);
    defer std.testing.allocator.free(fee.source_url);
    defer std.testing.allocator.free(fee.as_of);
    try std.testing.expectApproxEqAbs(@as(f64, 4.5), fee.bps, 0.00001);
    try std.testing.expectError(error.FeeUnavailable, parsePublicFee(std.testing.allocator, content, "spot", now));
    const stale_now = try types.parseGatewayTimestamp("2026-12-01T00:00:00Z");
    try std.testing.expectError(error.StaleFeeMetadata, parsePublicFee(std.testing.allocator, content, "perpetual", stale_now));
}

test "book side validation accepts arrays and objects" {
    const alloc = std.testing.allocator;
    var arrays = try std.json.parseFromSlice(std.json.Value, alloc, "[[\"100\",\"2\"],[\"99\",\"3\"]]", .{});
    defer arrays.deinit();
    try std.testing.expectEqual(@as(f64, 100), try validateBookSide(alloc, arrays.value.array, "/0", "/1", .buy));

    var objects = try std.json.parseFromSlice(std.json.Value, alloc, "[{\"px\":\"101\",\"sz\":\"2\"},{\"px\":\"102\",\"sz\":\"3\"}]", .{});
    defer objects.deinit();
    try std.testing.expectEqual(@as(f64, 101), try validateBookSide(alloc, objects.value.array, "/px", "/sz", .sell));
}

test "ranker reads terminal batch children and public skill fees" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cheap_skill =
        \\---
        \\name: cheap
        \\description: cheap venue
        \\metadata:
        \\  pieverse:
        \\    marketSearch: true
        \\    marketCost:
        \\      perpetual:
        \\        publicTakerFeeBps: 4
        \\        sourceUrl: https://cheap.example/fees
        \\        asOf: 2026-09-03
        \\---
    ;
    const expensive_skill =
        \\---
        \\name: expensive
        \\description: expensive venue
        \\metadata:
        \\  pieverse:
        \\    marketSearch: true
        \\    marketCost:
        \\      perpetual:
        \\        publicTakerFeeBps: 8
        \\        sourceUrl: https://expensive.example/fees
        \\        asOf: 2026-09-03
        \\---
    ;
    try writeTempFile(&tmp, "workspace/.fx/skills/cheap/SKILL.md", cheap_skill);
    try writeTempFile(&tmp, "workspace/.fx/skills/expensive/SKILL.md", expensive_skill);
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx/skills");

    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const skills_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/.fx/skills");
    defer alloc.free(skills_dir);

    const calls = [_]types.ToolCall{
        .{ .id = "call_books", .name = "terminal", .arguments_json = "{}" },
    };
    const batch_output =
        \\[{"id":"cheap-book","status":"success","output":"exit_code=0\n<stdout>\n{\"bids\":[[\"99.9\",\"2\"]],\"asks\":[[\"100.1\",\"2\"]]}\n</stdout>\n"},{"id":"expensive-book","status":"success","output":"exit_code=0\n<stdout>\n{\"levels\":[[{\"px\":\"99.9\",\"sz\":\"2\"}],[{\"px\":\"100.1\",\"sz\":\"2\"}]]}\n</stdout>\n"}]
    ;
    const messages = [_]types.ChatMessage{
        .{ .role = .assistant, .tool_calls = &calls },
        .{ .role = .tool, .content = batch_output, .tool_call_id = "call_books", .tool_name = "terminal", .tool_result_status = .success },
    };
    const args =
        \\{"side":"buy","candidates":[{"venue":"cheap","symbol":"BTCUSD","product":"perpetual","quote":"USD","book":{"source":{"sourceToolCall":0,"resultId":"cheap-book"},"bidsPointer":"/bids","asksPointer":"/asks","pricePointer":"/0","sizePointer":"/1","identityPointer":null}},{"venue":"expensive","symbol":"BTCUSD","product":"perpetual","quote":"USD","book":{"source":{"sourceToolCall":0,"resultId":"expensive-book"},"bidsPointer":"/levels/0","asksPointer":"/levels/1","pricePointer":"/px","sizePointer":"/sz","identityPointer":null}}]}
    ;
    const result = try rank(.{
        .allocator = alloc,
        .workspace_root = workspace,
        .skills_dir = skills_dir,
        .current_turn_messages = &messages,
    }, args);
    defer alloc.free(result);
    var parsed = try std.json.parseFromSlice(Output, alloc, result, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("cheap", parsed.value.selected.?.venue);
    try std.testing.expectApproxEqAbs(@as(f64, 14), parsed.value.selected.?.estimatedCostBps, 0.00001);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.alternatives.len);
    try std.testing.expectEqualStrings("expensive", parsed.value.alternatives[0].venue);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.excluded.len);
}
