const std = @import("std");
const io_mod = @import("../../core/shared/io.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");

const Allocator = std.mem.Allocator;
const max_candidates = 16;
const max_levels = 200;

pub const Input = struct {
    json: []u8,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.json);
        self.* = .{ .json = &.{} };
    }
};

const Side = enum { buy, sell };
const BookOrder = enum { descending, ascending };

const Level = struct {
    price: f64,
    size: f64,
};

const Candidate = struct {
    id: []const u8,
    quote_currency: []const u8,
    quote_to_reference_rate: f64,
    quote_notional: f64,
    base_size_per_unit: f64,
    best_bid: f64,
    best_ask: f64,
    mid: f64,
    estimated_fill_price: f64,
    taker_fee_bps: f64,
    additional_fee_bps: f64,
    full_spread_bps: f64,
    side_spread_cost_bps: f64,
    depth_slippage_bps: f64,
    estimated_cost_bps: f64,
    estimated_cost_quote: f64,
    estimated_cost_reference: f64,
    total_cost_rank: usize = 0,
};

const CandidateOutput = struct {
    id: []const u8,
    quoteCurrency: []const u8,
    quoteToReferenceRate: f64,
    quoteNotional: f64,
    baseSizePerUnit: f64,
    bestBid: f64,
    bestAsk: f64,
    mid: f64,
    estimatedFillPrice: f64,
    takerFeeBps: f64,
    additionalFeeBps: f64,
    fullSpreadBps: f64,
    sideSpreadCostBps: f64,
    depthSlippageBps: f64,
    estimatedCostBps: f64,
    estimatedCostQuote: f64,
    estimatedCostReference: f64,
    totalCostRank: usize,
};

const ExcludedOutput = struct {
    id: []const u8,
    reason: []const u8,
};

const Output = struct {
    method: []const u8 = "reference_notional_taker_fee_plus_spread_and_depth",
    side: []const u8,
    referenceNotional: f64,
    referenceCurrency: []const u8,
    calculatedAt: i64,
    selected: CandidateOutput,
    candidates: []const CandidateOutput,
    excluded: []const ExcludedOutput,
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
    const reference_notional = try numeric(try requireField(root, "referenceNotional"));
    if (!std.math.isFinite(reference_notional) or reference_notional <= 0) return error.InvalidNotional;
    const reference_currency = try requireString(try requireField(root, "referenceCurrency"));
    if (reference_currency.len == 0 or reference_currency.len > 32) return error.InvalidQuoteCurrency;
    const values = try requireArray(try requireField(root, "candidates"));
    if (values.items.len < 2) return error.TooFewCandidates;
    if (values.items.len > max_candidates) return error.TooManyCandidates;

    const candidates = try arena.alloc(Candidate, values.items.len);
    const excluded = try arena.alloc(ExcludedOutput, values.items.len);
    const seen_ids = try arena.alloc([]const u8, values.items.len);
    var candidate_count: usize = 0;
    var excluded_count: usize = 0;
    var seen_count: usize = 0;
    for (values.items) |value| {
        const item = try requireObject(value);
        const id = try requireString(try requireField(item, "id"));
        if (id.len == 0 or id.len > 160) return error.InvalidCandidateId;
        for (seen_ids[0..seen_count]) |existing_id| {
            if (std.mem.eql(u8, existing_id, id)) return error.DuplicateCandidateId;
        }
        seen_ids[seen_count] = id;
        seen_count += 1;

        const quote_currency = try requireString(try requireField(item, "quoteCurrency"));
        if (quote_currency.len == 0 or quote_currency.len > 32) return error.InvalidQuoteCurrency;
        const quote_to_reference_rate = try numeric(try requireField(item, "quoteToReferenceRate"));
        if (!std.math.isFinite(quote_to_reference_rate) or quote_to_reference_rate <= 0)
            return error.InvalidQuoteConversion;
        if (std.ascii.eqlIgnoreCase(quote_currency, reference_currency) and quote_to_reference_rate != 1)
            return error.InvalidQuoteConversion;
        const quote_notional = reference_notional / quote_to_reference_rate;
        if (!std.math.isFinite(quote_notional) or quote_notional <= 0) return error.InvalidQuoteConversion;

        const bids = try parseLevels(arena, try requireField(item, "bids"), .descending);
        const asks = try parseLevels(arena, try requireField(item, "asks"), .ascending);
        const best_bid = bids[0].price;
        const best_ask = asks[0].price;
        if (best_bid >= best_ask) return error.InvalidBook;
        const taker_fee_bps = try nonNegativeFinite(try requireField(item, "takerFeeBps"));
        const additional_fee_bps = try nonNegativeFinite(try requireField(item, "additionalFeeBps"));
        const base_size_per_unit = try positiveFinite(try requireField(item, "baseSizePerUnit"));

        const mid = (best_bid + best_ask) / 2;
        const base_quantity = quote_notional / mid;
        const estimated_fill_price = (switch (side) {
            .buy => fillPrice(asks, base_quantity, base_size_per_unit),
            .sell => fillPrice(bids, base_quantity, base_size_per_unit),
        }) catch |err| switch (err) {
            error.InsufficientDepth => {
                excluded[excluded_count] = .{ .id = id, .reason = "insufficient_depth" };
                excluded_count += 1;
                continue;
            },
            else => return err,
        };
        const full_spread_bps = (best_ask - best_bid) / mid * 10_000;
        const side_spread_cost_bps = switch (side) {
            .buy => (best_ask - mid) / mid * 10_000,
            .sell => (mid - best_bid) / mid * 10_000,
        };
        const depth_slippage_bps = @max(0, switch (side) {
            .buy => (estimated_fill_price - best_ask) / mid * 10_000,
            .sell => (best_bid - estimated_fill_price) / mid * 10_000,
        });
        const estimated_cost_bps = taker_fee_bps + additional_fee_bps + side_spread_cost_bps + depth_slippage_bps;
        const estimated_cost_quote = quote_notional * estimated_cost_bps / 10_000;
        const estimated_cost_reference = estimated_cost_quote * quote_to_reference_rate;
        inline for (&.{ mid, estimated_fill_price, full_spread_bps, side_spread_cost_bps, depth_slippage_bps, estimated_cost_bps, estimated_cost_quote, estimated_cost_reference }) |number| {
            if (!std.math.isFinite(number) or number < 0) return error.InvalidCost;
        }

        candidates[candidate_count] = .{
            .id = id,
            .quote_currency = quote_currency,
            .quote_to_reference_rate = quote_to_reference_rate,
            .quote_notional = quote_notional,
            .base_size_per_unit = base_size_per_unit,
            .best_bid = best_bid,
            .best_ask = best_ask,
            .mid = mid,
            .estimated_fill_price = estimated_fill_price,
            .taker_fee_bps = taker_fee_bps,
            .additional_fee_bps = additional_fee_bps,
            .full_spread_bps = full_spread_bps,
            .side_spread_cost_bps = side_spread_cost_bps,
            .depth_slippage_bps = depth_slippage_bps,
            .estimated_cost_bps = estimated_cost_bps,
            .estimated_cost_quote = estimated_cost_quote,
            .estimated_cost_reference = estimated_cost_reference,
        };
        candidate_count += 1;
    }

    if (candidate_count == 0) return error.InsufficientDepth;
    const ranked_candidates = candidates[0..candidate_count];

    const indexes = try arena.alloc(usize, ranked_candidates.len);
    for (indexes, 0..) |*item, index| item.* = index;
    std.mem.sort(usize, indexes, ranked_candidates, totalLessThan);
    for (indexes, 0..) |candidate_index, rank| ranked_candidates[candidate_index].total_cost_rank = rank + 1;

    const outputs = try arena.alloc(CandidateOutput, ranked_candidates.len);
    for (indexes, 0..) |candidate_index, output_index| outputs[output_index] = candidateOutput(ranked_candidates[candidate_index]);
    const output = Output{
        .side = @tagName(side),
        .referenceNotional = reference_notional,
        .referenceCurrency = reference_currency,
        .calculatedAt = now_ms,
        .selected = outputs[0],
        .candidates = outputs,
        .excluded = excluded[0..excluded_count],
    };

    var writer: std.Io.Writer.Allocating = .init(arena);
    defer writer.deinit();
    try std.json.Stringify.value(output, .{}, &writer.writer);
    return alloc.dupe(u8, try writer.toOwnedSlice());
}

fn parseLevels(alloc: Allocator, value: std.json.Value, order: BookOrder) ![]const Level {
    const values = try requireArray(value);
    if (values.items.len == 0 or values.items.len > max_levels) return error.InvalidBookDepth;
    const levels = try alloc.alloc(Level, values.items.len);
    for (values.items, 0..) |raw, index| {
        const item = try requireObject(raw);
        const level = Level{
            .price = try numeric(try requireField(item, "price")),
            .size = try numeric(try requireField(item, "size")),
        };
        if (!std.math.isFinite(level.price) or !std.math.isFinite(level.size) or level.price <= 0 or level.size <= 0) return error.InvalidBook;
        if (index > 0) {
            const previous = levels[index - 1].price;
            if ((order == .descending and level.price > previous) or
                (order == .ascending and level.price < previous)) return error.UnsortedBook;
        }
        levels[index] = level;
    }
    return levels;
}

fn fillPrice(levels: []const Level, base_quantity: f64, base_size_per_unit: f64) !f64 {
    var remaining = base_quantity;
    var quote_total: f64 = 0;
    for (levels) |level| {
        const available_base = level.size * base_size_per_unit;
        if (!std.math.isFinite(available_base) or available_base <= 0) return error.InvalidBook;
        const filled = @min(remaining, available_base);
        quote_total += filled * level.price;
        remaining -= filled;
        if (remaining <= base_quantity * 1e-12) return quote_total / base_quantity;
    }
    return error.InsufficientDepth;
}

fn candidateOutput(candidate: Candidate) CandidateOutput {
    return .{
        .id = candidate.id,
        .quoteCurrency = candidate.quote_currency,
        .quoteToReferenceRate = candidate.quote_to_reference_rate,
        .quoteNotional = candidate.quote_notional,
        .baseSizePerUnit = candidate.base_size_per_unit,
        .bestBid = candidate.best_bid,
        .bestAsk = candidate.best_ask,
        .mid = candidate.mid,
        .estimatedFillPrice = candidate.estimated_fill_price,
        .takerFeeBps = candidate.taker_fee_bps,
        .additionalFeeBps = candidate.additional_fee_bps,
        .fullSpreadBps = candidate.full_spread_bps,
        .sideSpreadCostBps = candidate.side_spread_cost_bps,
        .depthSlippageBps = candidate.depth_slippage_bps,
        .estimatedCostBps = candidate.estimated_cost_bps,
        .estimatedCostQuote = candidate.estimated_cost_quote,
        .estimatedCostReference = candidate.estimated_cost_reference,
        .totalCostRank = candidate.total_cost_rank,
    };
}

fn totalLessThan(candidates: []Candidate, lhs: usize, rhs: usize) bool {
    const left = candidates[lhs];
    const right = candidates[rhs];
    if (left.estimated_cost_bps != right.estimated_cost_bps) return left.estimated_cost_bps < right.estimated_cost_bps;
    if (left.depth_slippage_bps != right.depth_slippage_bps) return left.depth_slippage_bps < right.depth_slippage_bps;
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

fn nonNegativeFinite(value: std.json.Value) !f64 {
    const number = try numeric(value);
    if (!std.math.isFinite(number) or number < 0) return error.InvalidFee;
    return number;
}

fn positiveFinite(value: std.json.Value) !f64 {
    const number = try numeric(value);
    if (!std.math.isFinite(number) or number <= 0) return error.InvalidSizeMultiplier;
    return number;
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

test "ranks quote-notional fills by fee spread and depth" {
    const now_ms: i64 = 1_788_369_158_545;
    const input =
        \\{"side":"buy","referenceNotional":"100","referenceCurrency":"USDT","candidates":[{"id":"shallow-low-fee","quoteCurrency":"USDT","quoteToReferenceRate":"1","baseSizePerUnit":"1","bids":[{"price":"99","size":"10"}],"asks":[{"price":"101","size":"0.2"},{"price":"104","size":"10"}],"takerFeeBps":"1","additionalFeeBps":"0"},{"id":"deep-higher-fee","quoteCurrency":"USDT","quoteToReferenceRate":"1","baseSizePerUnit":"1","bids":[{"price":"99.9","size":"10"}],"asks":[{"price":"100.1","size":"10"}],"takerFeeBps":"5","additionalFeeBps":"0"}]}
    ;
    const result = try calculate(std.testing.allocator, input, now_ms);
    defer std.testing.allocator.free(result);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("deep-higher-fee", root.get("selected").?.object.get("id").?.string);
    try std.testing.expectEqual(now_ms, root.get("calculatedAt").?.integer);
    try std.testing.expectEqual(@as(f64, 0), try numeric(root.get("selected").?.object.get("depthSlippageBps").?));
}

test "sell fills consume descending bids" {
    const input =
        \\{"side":"sell","referenceNotional":"100","referenceCurrency":"USD","candidates":[{"id":"venue-b","quoteCurrency":"USD","quoteToReferenceRate":"1","baseSizePerUnit":"1","bids":[{"price":"100","size":"0.4"},{"price":"99","size":"10"}],"asks":[{"price":"101","size":"10"}],"takerFeeBps":"2","additionalFeeBps":"0"},{"id":"venue-a","quoteCurrency":"USD","quoteToReferenceRate":"1","baseSizePerUnit":"1","bids":[{"price":"100","size":"10"}],"asks":[{"price":"101","size":"10"}],"takerFeeBps":"2","additionalFeeBps":"0"}]}
    ;
    const result = try calculate(std.testing.allocator, input, 1);
    defer std.testing.allocator.free(result);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("venue-a", parsed.value.object.get("selected").?.object.get("id").?.string);
}

test "includes public and additional execution fees" {
    const input =
        \\{"side":"buy","referenceNotional":"100","referenceCurrency":"USDT","candidates":[{"id":"lower-base-higher-total","quoteCurrency":"USDT","quoteToReferenceRate":"1","baseSizePerUnit":"1","bids":[{"price":"99","size":"2"}],"asks":[{"price":"101","size":"2"}],"takerFeeBps":"2","additionalFeeBps":"3"},{"id":"higher-base-lower-total","quoteCurrency":"USDT","quoteToReferenceRate":"1","baseSizePerUnit":"1","bids":[{"price":"99","size":"2"}],"asks":[{"price":"101","size":"2"}],"takerFeeBps":"4","additionalFeeBps":"0"}]}
    ;
    const result = try calculate(std.testing.allocator, input, 1);
    defer std.testing.allocator.free(result);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    const selected = parsed.value.object.get("selected").?.object;
    try std.testing.expectEqualStrings("higher-base-lower-total", selected.get("id").?.string);
    try std.testing.expectApproxEqAbs(@as(f64, 104), try numeric(selected.get("estimatedCostBps").?), 0.000001);
}

test "excludes insufficient depth and rejects unsorted books" {
    const insufficient =
        \\{"side":"buy","referenceNotional":"100","referenceCurrency":"USD","candidates":[{"id":"a","quoteCurrency":"USD","quoteToReferenceRate":"1","baseSizePerUnit":"1","bids":[{"price":"99","size":"1"}],"asks":[{"price":"100","size":"0.1"}],"takerFeeBps":"1","additionalFeeBps":"0"},{"id":"b","quoteCurrency":"USD","quoteToReferenceRate":"1","baseSizePerUnit":"1","bids":[{"price":"99","size":"2"}],"asks":[{"price":"100","size":"2"}],"takerFeeBps":"1","additionalFeeBps":"0"}]}
    ;
    const result = try calculate(std.testing.allocator, insufficient, 1);
    defer std.testing.allocator.free(result);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("b", parsed.value.object.get("selected").?.object.get("id").?.string);
    const excluded = parsed.value.object.get("excluded").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), excluded.len);
    try std.testing.expectEqualStrings("a", excluded[0].object.get("id").?.string);
    try std.testing.expectEqualStrings("insufficient_depth", excluded[0].object.get("reason").?.string);
    const unsorted =
        \\{"side":"buy","referenceNotional":"100","referenceCurrency":"USD","candidates":[{"id":"a","quoteCurrency":"USD","quoteToReferenceRate":"1","baseSizePerUnit":"1","bids":[{"price":"99","size":"1"},{"price":"100","size":"1"}],"asks":[{"price":"101","size":"1"}],"takerFeeBps":"1","additionalFeeBps":"0"},{"id":"b","quoteCurrency":"USD","quoteToReferenceRate":"1","baseSizePerUnit":"1","bids":[{"price":"99","size":"1"}],"asks":[{"price":"101","size":"1"}],"takerFeeBps":"1","additionalFeeBps":"0"}]}
    ;
    try std.testing.expectError(error.UnsortedBook, calculate(std.testing.allocator, unsorted, 1));
}

test "converts venue-native contract size to base-asset depth" {
    const input =
        \\{"side":"buy","referenceNotional":"100","referenceCurrency":"USD","candidates":[{"id":"contracts","quoteCurrency":"USD","quoteToReferenceRate":"1","baseSizePerUnit":"0.01","bids":[{"price":"99","size":"200"}],"asks":[{"price":"100","size":"50"},{"price":"102","size":"100"}],"takerFeeBps":"1","additionalFeeBps":"0"},{"id":"base-units","quoteCurrency":"USD","quoteToReferenceRate":"1","baseSizePerUnit":"1","bids":[{"price":"96","size":"2"}],"asks":[{"price":"104","size":"2"}],"takerFeeBps":"1","additionalFeeBps":"0"}]}
    ;
    const result = try calculate(std.testing.allocator, input, 1);
    defer std.testing.allocator.free(result);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    const selected = parsed.value.object.get("selected").?.object;
    try std.testing.expectEqualStrings("contracts", selected.get("id").?.string);
    try std.testing.expectApproxEqAbs(@as(f64, 0.01), try numeric(selected.get("baseSizePerUnit").?), 0.000001);
    try std.testing.expect(try numeric(selected.get("estimatedFillPrice").?) > 101);
}

test "compares books quoted in different currencies at one reference notional" {
    const input =
        \\{"side":"buy","referenceNotional":"100","referenceCurrency":"USDC","candidates":[{"id":"usdc-market","quoteCurrency":"USDC","quoteToReferenceRate":"1","baseSizePerUnit":"1","bids":[{"price":"99","size":"2"}],"asks":[{"price":"101","size":"2"}],"takerFeeBps":"5","additionalFeeBps":"0"},{"id":"usdt-market","quoteCurrency":"USDT","quoteToReferenceRate":"0.999","baseSizePerUnit":"1","bids":[{"price":"99.9","size":"2"}],"asks":[{"price":"100.1","size":"2"}],"takerFeeBps":"4","additionalFeeBps":"0"}]}
    ;
    const result = try calculate(std.testing.allocator, input, 1);
    defer std.testing.allocator.free(result);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    const selected = parsed.value.object.get("selected").?.object;
    try std.testing.expectEqualStrings("usdt-market", selected.get("id").?.string);
    try std.testing.expectEqualStrings("USDT", selected.get("quoteCurrency").?.string);
    try std.testing.expectApproxEqAbs(@as(f64, 0.999), try numeric(selected.get("quoteToReferenceRate").?), 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 100.1001001), try numeric(selected.get("quoteNotional").?), 0.000001);
}

test "same-currency candidates require an identity conversion rate" {
    const input =
        \\{"side":"buy","referenceNotional":"100","referenceCurrency":"USD","candidates":[{"id":"a","quoteCurrency":"USD","quoteToReferenceRate":"0.999","baseSizePerUnit":"1","bids":[{"price":"99","size":"2"}],"asks":[{"price":"101","size":"2"}],"takerFeeBps":"1","additionalFeeBps":"0"},{"id":"b","quoteCurrency":"USD","quoteToReferenceRate":"1","baseSizePerUnit":"1","bids":[{"price":"99","size":"2"}],"asks":[{"price":"101","size":"2"}],"takerFeeBps":"1","additionalFeeBps":"0"}]}
    ;
    try std.testing.expectError(error.InvalidQuoteConversion, calculate(std.testing.allocator, input, 1));
}
