const std = @import("std");
const io_mod = @import("../../core/shared/io.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");

const Allocator = std.mem.Allocator;
const max_candidates = 16;

pub const Input = struct {
    json: []u8,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.json);
        self.* = .{ .json = &.{} };
    }
};

const Side = enum { buy, sell };

const Candidate = struct {
    id: []const u8,
    best_bid: f64,
    best_ask: f64,
    taker_fee_bps: f64,
    mid: f64,
    full_spread_bps: f64,
    spread_cost_bps: f64,
    estimated_cost_bps: f64,
    fee_rank: usize = 0,
    spread_rank: usize = 0,
    total_cost_rank: usize = 0,
};

const CandidateOutput = struct {
    id: []const u8,
    bestBid: f64,
    bestAsk: f64,
    bestPrice: f64,
    mid: f64,
    takerFeeBps: f64,
    fullSpreadBps: f64,
    spreadCostBps: f64,
    estimatedCostBps: f64,
    feeRank: usize,
    spreadRank: usize,
    totalCostRank: usize,
};

const Output = struct {
    method: []const u8 = "public_taker_fee_plus_half_spread",
    side: []const u8,
    calculatedAt: i64,
    selected: CandidateOutput,
    candidates: []const CandidateOutput,
};

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "calculate_venue_costs arguments must be valid JSON") };
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, "calculate_venue_costs arguments must be an object") };
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
    const result = calculate(ctx.allocator, erased.as(Input).json, io_mod.milliTimestamp()) catch |err| {
        return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "calculate_venue_costs failed: {s}", .{@errorName(err)}) };
    };
    return .{ .success = result };
}

fn calculate(alloc: Allocator, input_json: []const u8, now_ms: i64) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var parsed = try std.json.parseFromSlice(std.json.Value, arena, input_json, .{});
    defer parsed.deinit();
    const root = try requireObject(parsed.value);
    const side_text = try requireString(try requireField(root, "side"));
    const side = std.meta.stringToEnum(Side, side_text) orelse return error.InvalidSide;
    const values = try requireArray(try requireField(root, "candidates"));
    if (values.items.len < 2) return error.TooFewCandidates;
    if (values.items.len > max_candidates) return error.TooManyCandidates;

    const candidates = try arena.alloc(Candidate, values.items.len);
    for (values.items, 0..) |value, index| {
        const item = try requireObject(value);
        const id = try requireString(try requireField(item, "id"));
        if (id.len == 0 or id.len > 160) return error.InvalidCandidateId;
        for (candidates[0..index]) |existing| {
            if (std.mem.eql(u8, existing.id, id)) return error.DuplicateCandidateId;
        }

        const best_bid = try numeric(try requireField(item, "bestBid"));
        const best_ask = try numeric(try requireField(item, "bestAsk"));
        const taker_fee_bps = try numeric(try requireField(item, "takerFeeBps"));
        if (!std.math.isFinite(best_bid) or !std.math.isFinite(best_ask) or best_bid <= 0 or best_ask <= best_bid) return error.InvalidBook;
        if (!std.math.isFinite(taker_fee_bps) or taker_fee_bps < 0) return error.InvalidFee;

        const mid = (best_bid + best_ask) / 2;
        const full_spread_bps = (best_ask - best_bid) / mid * 10_000;
        const spread_cost_bps = switch (side) {
            .buy => (best_ask - mid) / mid * 10_000,
            .sell => (mid - best_bid) / mid * 10_000,
        };
        const estimated_cost_bps = taker_fee_bps + spread_cost_bps;
        if (!std.math.isFinite(mid) or !std.math.isFinite(full_spread_bps) or
            !std.math.isFinite(spread_cost_bps) or !std.math.isFinite(estimated_cost_bps)) return error.InvalidCost;

        candidates[index] = .{
            .id = id,
            .best_bid = best_bid,
            .best_ask = best_ask,
            .taker_fee_bps = taker_fee_bps,
            .mid = mid,
            .full_spread_bps = full_spread_bps,
            .spread_cost_bps = spread_cost_bps,
            .estimated_cost_bps = estimated_cost_bps,
        };
    }

    const indexes = try arena.alloc(usize, candidates.len);
    for (indexes, 0..) |*item, index| item.* = index;
    std.mem.sort(usize, indexes, candidates, feeLessThan);
    for (indexes, 0..) |candidate_index, rank| candidates[candidate_index].fee_rank = rank + 1;
    std.mem.sort(usize, indexes, candidates, spreadLessThan);
    for (indexes, 0..) |candidate_index, rank| candidates[candidate_index].spread_rank = rank + 1;
    std.mem.sort(usize, indexes, candidates, totalLessThan);
    for (indexes, 0..) |candidate_index, rank| candidates[candidate_index].total_cost_rank = rank + 1;

    const outputs = try arena.alloc(CandidateOutput, candidates.len);
    for (indexes, 0..) |candidate_index, output_index| outputs[output_index] = candidateOutput(candidates[candidate_index], side);
    const output = Output{
        .side = @tagName(side),
        .calculatedAt = now_ms,
        .selected = outputs[0],
        .candidates = outputs,
    };

    var writer: std.Io.Writer.Allocating = .init(arena);
    defer writer.deinit();
    try std.json.Stringify.value(output, .{}, &writer.writer);
    return alloc.dupe(u8, try writer.toOwnedSlice());
}

fn candidateOutput(candidate: Candidate, side: Side) CandidateOutput {
    return .{
        .id = candidate.id,
        .bestBid = candidate.best_bid,
        .bestAsk = candidate.best_ask,
        .bestPrice = if (side == .buy) candidate.best_ask else candidate.best_bid,
        .mid = candidate.mid,
        .takerFeeBps = candidate.taker_fee_bps,
        .fullSpreadBps = candidate.full_spread_bps,
        .spreadCostBps = candidate.spread_cost_bps,
        .estimatedCostBps = candidate.estimated_cost_bps,
        .feeRank = candidate.fee_rank,
        .spreadRank = candidate.spread_rank,
        .totalCostRank = candidate.total_cost_rank,
    };
}

fn feeLessThan(candidates: []Candidate, lhs: usize, rhs: usize) bool {
    const left = candidates[lhs];
    const right = candidates[rhs];
    if (left.taker_fee_bps != right.taker_fee_bps) return left.taker_fee_bps < right.taker_fee_bps;
    return std.mem.lessThan(u8, left.id, right.id);
}

fn spreadLessThan(candidates: []Candidate, lhs: usize, rhs: usize) bool {
    const left = candidates[lhs];
    const right = candidates[rhs];
    if (left.spread_cost_bps != right.spread_cost_bps) return left.spread_cost_bps < right.spread_cost_bps;
    return std.mem.lessThan(u8, left.id, right.id);
}

fn totalLessThan(candidates: []Candidate, lhs: usize, rhs: usize) bool {
    const left = candidates[lhs];
    const right = candidates[rhs];
    if (left.estimated_cost_bps != right.estimated_cost_bps) return left.estimated_cost_bps < right.estimated_cost_bps;
    if (left.spread_cost_bps != right.spread_cost_bps) return left.spread_cost_bps < right.spread_cost_bps;
    if (left.taker_fee_bps != right.taker_fee_bps) return left.taker_fee_bps < right.taker_fee_bps;
    return std.mem.lessThan(u8, left.id, right.id);
}

fn requireObject(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => error.ExpectedObject,
    };
}

fn requireArray(value: std.json.Value) !std.json.Array {
    return switch (value) {
        .array => |array| array,
        else => error.ExpectedArray,
    };
}

fn requireField(object: std.json.ObjectMap, name: []const u8) !std.json.Value {
    return object.get(name) orelse error.MissingField;
}

fn requireString(value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |text| text,
        else => error.ExpectedString,
    };
}

fn numeric(value: std.json.Value) !f64 {
    return switch (value) {
        .integer => |number| @floatFromInt(number),
        .float => |number| number,
        .string => |text| std.fmt.parseFloat(f64, text) catch return error.ExpectedNumber,
        else => error.ExpectedNumber,
    };
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

test "ranks fee spread and combined execution cost independently" {
    const now_ms: i64 = 1_788_369_158_545;
    const input =
        \\{"side":"buy","candidates":[{"id":"wide-low-fee","bestBid":"99","bestAsk":"101","takerFeeBps":"1"},{"id":"tight-high-fee","bestBid":"99.99","bestAsk":"100.01","takerFeeBps":"5"},{"id":"winner","bestBid":"99.98","bestAsk":"100.02","takerFeeBps":"2"}]}
    ;
    const result = try calculate(std.testing.allocator, input, now_ms);
    defer std.testing.allocator.free(result);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("winner", root.get("selected").?.object.get("id").?.string);
    try std.testing.expectEqual(now_ms, root.get("calculatedAt").?.integer);
    const candidates = root.get("candidates").?.array.items;
    try std.testing.expectEqual(@as(i64, 1), candidates[0].object.get("totalCostRank").?.integer);
    try std.testing.expectEqual(@as(i64, 2), candidates[0].object.get("feeRank").?.integer);
    try std.testing.expectEqual(@as(i64, 2), candidates[0].object.get("spreadRank").?.integer);
}

test "uses candidate id as the final deterministic tie breaker" {
    const now_ms: i64 = 1_788_369_158_545;
    const input =
        \\{"side":"sell","candidates":[{"id":"venue-b","bestBid":"99","bestAsk":"101","takerFeeBps":"2"},{"id":"venue-a","bestBid":"99","bestAsk":"101","takerFeeBps":"2"}]}
    ;
    const result = try calculate(std.testing.allocator, input, now_ms);
    defer std.testing.allocator.free(result);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("venue-a", parsed.value.object.get("selected").?.object.get("id").?.string);
}

test "rejects invalid candidate evidence" {
    const now_ms: i64 = 1_788_369_158_545;
    const crossed =
        \\{"side":"buy","candidates":[{"id":"a","bestBid":"101","bestAsk":"100","takerFeeBps":"1"},{"id":"b","bestBid":"99","bestAsk":"100","takerFeeBps":"1"}]}
    ;
    try std.testing.expectError(error.InvalidBook, calculate(std.testing.allocator, crossed, now_ms));
}
