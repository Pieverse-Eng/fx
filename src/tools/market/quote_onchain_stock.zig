const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../../core/shared/io.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");

const Allocator = std.mem.Allocator;
const max_http_body_bytes = 4 * 1024 * 1024;

pub const Input = struct {
    json: []u8,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.json);
        self.* = .{ .json = &.{} };
    }
};

const Deployment = struct {
    issuer: []const u8,
    token_symbol: []const u8,
    chain: []const u8,
    contract: []const u8,
    input_symbol: []const u8,
    input_contract: []const u8,
    input_decimals: ?u8,
    multiplier: f64,
    provider: Provider,
};

const Provider = enum { bitget_wallet, platform_dflow, platform_okx_dex };

const QuoteTask = struct {
    arena_state: std.heap.ArenaAllocator,
    deployment: Deployment,
    reference_notional: f64,
    reference_usd_rate: f64,
    now_ms: i64,
    result: ?RankedQuote = null,
    failure: ?[]const u8 = null,

    fn deinit(self: *QuoteTask) void {
        self.arena_state.deinit();
    }
};

const RankedQuote = struct {
    issuer: []const u8,
    token_symbol: []const u8,
    chain: []const u8,
    contract: []const u8,
    input_asset: []const u8,
    input_contract: []const u8,
    provider: []const u8,
    route: []const u8,
    amount_in: f64,
    amount_out: f64,
    exposure_shares: f64,
    gas_reference: f64,
    effective_reference_per_share: f64,
    rank: usize = 0,
};

const QuoteOutput = struct {
    issuer: []const u8,
    tokenSymbol: []const u8,
    chain: []const u8,
    contract: []const u8,
    inputAsset: []const u8,
    inputContract: []const u8,
    provider: []const u8,
    route: []const u8,
    amountIn: f64,
    amountOut: f64,
    exposureShares: f64,
    gasReference: f64,
    effectiveReferencePerShare: f64,
    totalCostRank: usize,
};

const Excluded = struct {
    issuer: []const u8,
    chain: []const u8,
    reason: []const u8,
};

const Output = struct {
    method: []const u8 = "exact_input_public_quote_plus_external_gas",
    ticker: []const u8,
    side: []const u8 = "buy",
    referenceNotional: f64,
    referenceCurrency: []const u8,
    quotedAt: i64,
    selected: ?QuoteOutput,
    candidates: []const QuoteOutput,
    excluded: []const Excluded,
};

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "quote_onchain_stock arguments must be valid JSON") };
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, "quote_onchain_stock arguments must be an object") };
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
    if (ctx.cancel_flag) |flag| if (flag.load(.acquire)) return error.Cancelled;
    const result = quote(ctx.allocator, erased.as(Input).json, io_mod.milliTimestamp()) catch |err| {
        return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "quote_onchain_stock failed: {s}", .{@errorName(err)}) };
    };
    return .{ .success = result };
}

fn quote(alloc: Allocator, input_json: []const u8, now_ms: i64) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var parsed = try std.json.parseFromSlice(std.json.Value, arena, input_json, .{});
    defer parsed.deinit();
    const root = try requireObject(parsed.value);
    const ticker_raw = try requireString(try requireField(root, "ticker"));
    const ticker = try canonicalTicker(arena, ticker_raw);
    const side = try requireString(try requireField(root, "side"));
    if (!std.mem.eql(u8, side, "buy")) return error.UnsupportedSide;
    const notional = try numeric(try requireField(root, "referenceNotional"));
    if (!std.math.isFinite(notional) or notional <= 0) return error.InvalidNotional;
    const currency = try requireString(try requireField(root, "referenceCurrency"));
    if (!std.ascii.eqlIgnoreCase(currency, "USD") and
        !std.ascii.eqlIgnoreCase(currency, "USDT") and
        !std.ascii.eqlIgnoreCase(currency, "USDC")) return error.UnsupportedReferenceCurrency;
    const reference_usd_rate = try currencyUsdRate(arena, currency);

    var deployments: std.ArrayList(Deployment) = .empty;
    var excluded: std.ArrayList(Excluded) = .empty;
    try discoverXstocks(arena, ticker, &deployments, &excluded);
    try discoverBstocks(arena, ticker, &deployments, &excluded);
    try discoverRobinhood(arena, ticker, &deployments, &excluded);

    const tasks = try arena.alloc(QuoteTask, deployments.items.len);
    var initialized_tasks: usize = 0;
    defer for (tasks[0..initialized_tasks]) |*task| task.deinit();
    for (deployments.items, tasks) |deployment, *task| {
        task.* = .{
            .arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .deployment = deployment,
            .reference_notional = notional,
            .reference_usd_rate = reference_usd_rate,
            .now_ms = now_ms,
        };
        initialized_tasks += 1;
    }

    const io = io_mod.getIo();
    var quote_group: std.Io.Group = .init;
    defer quote_group.cancel(io);
    for (tasks) |*task| quote_group.async(io, runQuoteTask, .{task});
    try quote_group.await(io);

    var quotes: std.ArrayList(RankedQuote) = .empty;
    for (tasks) |task| {
        if (task.result) |ranked| {
            try quotes.append(arena, ranked);
        } else {
            try excluded.append(arena, .{
                .issuer = task.deployment.issuer,
                .chain = task.deployment.chain,
                .reason = task.failure orelse "QuoteUnavailable",
            });
        }
    }

    std.mem.sort(RankedQuote, quotes.items, {}, quoteLessThan);
    const outputs = try arena.alloc(QuoteOutput, quotes.items.len);
    for (quotes.items, 0..) |*item, index| {
        item.rank = index + 1;
        outputs[index] = quoteOutput(item.*);
    }
    const output = Output{
        .ticker = ticker,
        .referenceNotional = notional,
        .referenceCurrency = currency,
        .quotedAt = now_ms,
        .selected = if (outputs.len == 0) null else outputs[0],
        .candidates = outputs,
        .excluded = excluded.items,
    };
    var writer: std.Io.Writer.Allocating = .init(arena);
    defer writer.deinit();
    try std.json.Stringify.value(output, .{}, &writer.writer);
    return alloc.dupe(u8, try writer.toOwnedSlice());
}

fn runQuoteTask(task: *QuoteTask) std.Io.Cancelable!void {
    const arena = task.arena_state.allocator();
    task.result = switch (task.deployment.provider) {
        .bitget_wallet => quoteBitget(arena, task.deployment, task.reference_notional, task.reference_usd_rate, task.now_ms),
        .platform_dflow => quotePlatformDflow(arena, task.deployment, task.reference_notional, task.reference_usd_rate),
        .platform_okx_dex => quotePlatformOkxDex(arena, task.deployment, task.reference_notional, task.reference_usd_rate),
    } catch |err| {
        task.failure = @errorName(err);
        return;
    };
}

fn discoverXstocks(arena: Allocator, ticker: []const u8, deployments: *std.ArrayList(Deployment), excluded: *std.ArrayList(Excluded)) !void {
    const symbol = try std.fmt.allocPrint(arena, "{s}x", .{ticker});
    const url = try std.fmt.allocPrint(arena, "https://api.xstocks.fi/api/v2/public/assets/{s}", .{symbol});
    const body = fetch(arena, .GET, url, null, &.{}) catch |err| {
        try excluded.append(arena, .{ .issuer = "xstocks", .chain = "all", .reason = try errorReason(arena, err) });
        return;
    };
    var parsed = std.json.parseFromSlice(std.json.Value, arena, body, .{}) catch {
        try excluded.append(arena, .{ .issuer = "xstocks", .chain = "all", .reason = "invalid_catalog_response" });
        return;
    };
    defer parsed.deinit();
    const root = requireObject(parsed.value) catch return;
    const underlying = optionalString(root, "underlyingSymbol") orelse if (root.get("underlying")) |value|
        optionalString(requireObject(value) catch return, "symbol")
    else
        null;
    if (underlying == null or !std.ascii.eqlIgnoreCase(underlying.?, ticker)) {
        try excluded.append(arena, .{ .issuer = "xstocks", .chain = "all", .reason = "identity_not_verified" });
        return;
    }
    if (optionalBool(root, "isTradingHalted") orelse false) {
        try excluded.append(arena, .{ .issuer = "xstocks", .chain = "all", .reason = "trading_halted" });
        return;
    }
    const nodes = root.get("deployments") orelse return;
    const array = requireArray(nodes) catch return;
    for (array.items) |item_value| {
        const item = requireObject(item_value) catch continue;
        const network = optionalString(item, "network") orelse continue;
        const provider: Provider = if (std.mem.eql(u8, network, "XLayer"))
            .platform_okx_dex
        else if (std.mem.eql(u8, network, "Solana"))
            .platform_dflow
        else if (std.mem.eql(u8, network, "Ethereum"))
            .bitget_wallet
        else
            continue;
        if (!(optionalBool(item, "supportsAtomicSwaps") orelse false)) continue;
        const contract = optionalString(item, "address") orelse continue;
        const stablecoins_value = item.get("stablecoins") orelse continue;
        const stablecoins = requireArray(stablecoins_value) catch continue;
        const stablecoin = chooseUsdStablecoin(stablecoins.items, provider) orelse continue;
        const multiplier_url = try std.fmt.allocPrint(arena, "https://api.xstocks.fi/api/v2/public/assets/{s}/multiplier?network={s}", .{ symbol, network });
        const multiplier_body = fetch(arena, .GET, multiplier_url, null, &.{}) catch continue;
        var multiplier_parsed = std.json.parseFromSlice(std.json.Value, arena, multiplier_body, .{}) catch continue;
        defer multiplier_parsed.deinit();
        const multiplier = numeric((requireObject(multiplier_parsed.value) catch continue).get("currentMultiplier") orelse continue) catch continue;
        if (!std.math.isFinite(multiplier) or multiplier <= 0) continue;
        try deployments.append(arena, .{
            .issuer = "xstocks",
            .token_symbol = optionalString(root, "symbol") orelse symbol,
            .chain = network,
            .contract = contract,
            .input_symbol = stablecoin.symbol,
            .input_contract = stablecoin.contract,
            .input_decimals = stablecoin.decimals,
            .multiplier = multiplier,
            .provider = provider,
        });
    }
}

const Stablecoin = struct { symbol: []const u8, contract: []const u8, decimals: ?u8 };

fn chooseUsdStablecoin(values: []const std.json.Value, provider: Provider) ?Stablecoin {
    const preferred: []const []const u8 = switch (provider) {
        .bitget_wallet => &.{ "USDT", "USDC", "USDG" },
        .platform_dflow => &.{ "USDC", "USDG", "USDT" },
        .platform_okx_dex => &.{ "USDC", "USDG", "USDT" },
    };
    for (preferred) |wanted| for (values) |value| {
        const item = requireObject(value) catch continue;
        const currency = optionalString(item, "currency") orelse continue;
        const symbol = optionalString(item, "symbol") orelse continue;
        const contract = optionalString(item, "address") orelse continue;
        if (std.ascii.eqlIgnoreCase(currency, "USD") and std.ascii.eqlIgnoreCase(symbol, wanted))
            return .{ .symbol = symbol, .contract = contract, .decimals = decimalPlaces(item, "decimals") };
    };
    return null;
}

fn discoverBstocks(arena: Allocator, ticker: []const u8, deployments: *std.ArrayList(Deployment), excluded: *std.ArrayList(Excluded)) !void {
    const assets_body = fetch(arena, .GET, "https://www.binance.com/bapi/asset/v2/public/asset/asset/get-all-asset", null, &.{}) catch |err| {
        try excluded.append(arena, .{ .issuer = "bstocks", .chain = "BNB Smart Chain", .reason = try errorReason(arena, err) });
        return;
    };
    var assets_parsed = std.json.parseFromSlice(std.json.Value, arena, assets_body, .{}) catch return;
    defer assets_parsed.deinit();
    const assets_root = requireObject(assets_parsed.value) catch return;
    const values = requireArray(assets_root.get("data") orelse return) catch return;
    var symbol: ?[]const u8 = null;
    var multiplier: ?f64 = null;
    for (values.items) |value| {
        const item = requireObject(value) catch continue;
        const underlying = optionalString(item, "uq") orelse continue;
        if (!std.ascii.eqlIgnoreCase(underlying, ticker) or !(optionalBool(item, "trading") orelse false)) continue;
        if (!hasString(item.get("tags") orelse continue, "bStocks")) continue;
        const candidate_symbol = optionalString(item, "assetCode") orelse continue;
        const candidate_multiplier = numeric(item.get("ml") orelse continue) catch continue;
        if (!std.math.isFinite(candidate_multiplier) or candidate_multiplier <= 0) continue;
        symbol = candidate_symbol;
        multiplier = candidate_multiplier;
        break;
    }
    if (symbol == null or multiplier == null) return;

    const networks_body = fetch(arena, .GET, "https://www.binance.com/bapi/capital/v1/public/capital/getNetworkCoinAll", null, &.{}) catch return;
    var networks_parsed = std.json.parseFromSlice(std.json.Value, arena, networks_body, .{}) catch return;
    defer networks_parsed.deinit();
    const network_assets = requireArray((requireObject(networks_parsed.value) catch return).get("data") orelse return) catch return;
    for (network_assets.items) |value| {
        const asset = requireObject(value) catch continue;
        const coin = optionalString(asset, "coin") orelse continue;
        if (!std.mem.eql(u8, coin, symbol.?)) continue;
        const networks = requireArray(asset.get("networkList") orelse return) catch return;
        for (networks.items) |network_value| {
            const network = requireObject(network_value) catch continue;
            if (!std.mem.eql(u8, optionalString(network, "network") orelse continue, "BSC")) continue;
            const contract = optionalString(network, "contractAddress") orelse continue;
            try deployments.append(arena, .{
                .issuer = "bstocks",
                .token_symbol = symbol.?,
                .chain = "BNB Smart Chain",
                .contract = contract,
                .input_symbol = "USDT",
                .input_contract = "0x55d398326f99059fF775485246999027B3197955",
                .input_decimals = 18,
                .multiplier = multiplier.?,
                .provider = .bitget_wallet,
            });
        }
    }
}

fn discoverRobinhood(arena: Allocator, ticker: []const u8, deployments: *std.ArrayList(Deployment), excluded: *std.ArrayList(Excluded)) !void {
    const body = fetch(arena, .GET, "https://api.robinhood.com/rhj/assets", null, &.{}) catch |err| {
        try excluded.append(arena, .{ .issuer = "robinhood", .chain = "Robinhood Chain", .reason = try errorReason(arena, err) });
        return;
    };
    var parsed = std.json.parseFromSlice(std.json.Value, arena, body, .{}) catch return;
    defer parsed.deinit();
    const values = requireArray((requireObject(parsed.value) catch return).get("assets") orelse return) catch return;
    for (values.items) |value| {
        const item = requireObject(value) catch continue;
        const symbol = optionalString(item, "tokenSymbol") orelse continue;
        if (!std.ascii.eqlIgnoreCase(symbol, ticker)) continue;
        if (!std.mem.eql(u8, optionalString(item, "status") orelse continue, "ASSET_STATUS_ACTIVE")) continue;
        const multiplier = numeric(item.get("currentMultiplier") orelse continue) catch continue;
        const chain_deployments = requireArray(item.get("deployments") orelse continue) catch continue;
        for (chain_deployments.items) |deployment_value| {
            const deployment = requireObject(deployment_value) catch continue;
            if ((optionalInteger(deployment, "chainId") orelse 0) != 4663) continue;
            try deployments.append(arena, .{
                .issuer = "robinhood",
                .token_symbol = symbol,
                .chain = "Robinhood Chain",
                .contract = optionalString(deployment, "contractAddress") orelse continue,
                .input_symbol = "USDG",
                .input_contract = "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168",
                .input_decimals = null,
                .multiplier = multiplier,
                .provider = .bitget_wallet,
            });
        }
    }
}

fn quoteBitget(arena: Allocator, deployment: Deployment, reference_notional: f64, reference_usd_rate: f64, now_ms: i64) !RankedQuote {
    const chain = if (std.mem.eql(u8, deployment.chain, "BNB Smart Chain")) "bnb" else if (std.mem.eql(u8, deployment.chain, "Solana")) "sol" else if (std.mem.eql(u8, deployment.chain, "Ethereum")) "eth" else if (std.mem.eql(u8, deployment.chain, "Robinhood Chain")) "robinhood" else return error.UnsupportedChain;
    const address = if (std.mem.eql(u8, chain, "sol")) "11111111111111111111111111111111" else "0x0000000000000000000000000000000000000001";
    const input_usd_rate = try bitgetTokenUsdRate(arena, chain, deployment.input_contract, now_ms);
    const input_amount = reference_notional * reference_usd_rate / input_usd_rate;
    const body_value = .{
        .fromAddress = address,
        .fromChain = chain,
        .fromSymbol = deployment.input_symbol,
        .fromContract = deployment.input_contract,
        .fromAmount = try std.fmt.allocPrint(arena, "{d}", .{input_amount}),
        .toChain = chain,
        .toSymbol = deployment.token_symbol,
        .toContract = deployment.contract,
        .tab_type = "swap",
        .publicKey = "",
        .slippage = "",
        .toAddress = address,
        .requestId = try std.fmt.allocPrint(arena, "{d}", .{now_ms}),
    };
    const response = try postBitget(arena, "/swap-go/swapx/quote", body_value, now_ms);
    return parseBitgetQuote(arena, response, deployment, input_amount, input_usd_rate, reference_usd_rate);
}

fn parseBitgetQuote(arena: Allocator, body: []const u8, deployment: Deployment, input_amount: f64, input_usd_rate: f64, reference_usd_rate: f64) !RankedQuote {
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, body, .{});
    defer parsed.deinit();
    const root = try requireObject(parsed.value);
    if ((optionalInteger(root, "status") orelse -1) != 0) return error.QuoteUnavailable;
    const data = try requireObject(root.get("data") orelse return error.QuoteUnavailable);
    const results = try requireArray(data.get("quoteResults") orelse return error.QuoteUnavailable);
    var best: ?RankedQuote = null;
    for (results.items) |value| {
        const item = requireObject(value) catch continue;
        const amount_out = numeric(item.get("outAmount") orelse continue) catch continue;
        const gas = if (item.get("gasFees")) |gas_value| blk: {
            const gas_object = requireObject(gas_value) catch break :blk 0;
            break :blk numeric(gas_object.get("gasFeeAmountInUsd") orelse break :blk 0) catch 0;
        } else 0;
        const exposure = amount_out * deployment.multiplier;
        if (!std.math.isFinite(exposure) or exposure <= 0 or !std.math.isFinite(gas) or gas < 0) continue;
        const effective = (input_amount * input_usd_rate + gas) / reference_usd_rate / exposure;
        const market = if (item.get("market")) |market_value| requireObject(market_value) catch null else null;
        const route = if (market) |m| optionalString(m, "label") orelse optionalString(m, "protocol") orelse "unknown" else "unknown";
        const candidate = RankedQuote{
            .issuer = deployment.issuer,
            .token_symbol = deployment.token_symbol,
            .chain = deployment.chain,
            .contract = deployment.contract,
            .input_asset = deployment.input_symbol,
            .input_contract = deployment.input_contract,
            .provider = "bitget_wallet",
            .route = route,
            .amount_in = input_amount,
            .amount_out = amount_out,
            .exposure_shares = exposure,
            .gas_reference = gas / reference_usd_rate,
            .effective_reference_per_share = effective,
        };
        if (best == null or candidate.effective_reference_per_share < best.?.effective_reference_per_share) best = candidate;
    }
    return best orelse error.NoExecutableRoute;
}

fn quotePlatformDflow(arena: Allocator, deployment: Deployment, reference_notional: f64, reference_usd_rate: f64) !RankedQuote {
    const quote_url = io_mod.getenv("FX_PLATFORM_DFLOW_QUOTE_URL") orelse return error.QuoteBrokerUnavailable;
    const capability = io_mod.getenv("FX_PLATFORM_QUOTE_TOKEN") orelse return error.QuoteBrokerUnavailable;
    if (quote_url.len == 0 or capability.len == 0) return error.QuoteBrokerUnavailable;
    const input_decimals = deployment.input_decimals orelse return error.MissingTokenDecimals;
    const input_usd_rate = try currencyUsdRate(arena, deployment.input_symbol);
    const input_amount = reference_notional * reference_usd_rate / input_usd_rate;
    const raw_amount = try rawTokenAmount(arena, input_amount, input_decimals);
    const body_value = .{
        .inputMint = deployment.input_contract,
        .outputMint = deployment.contract,
        .amount = raw_amount,
    };
    var body_writer: std.Io.Writer.Allocating = .init(arena);
    defer body_writer.deinit();
    try std.json.Stringify.value(body_value, .{}, &body_writer.writer);
    const payload = try body_writer.toOwnedSlice();
    const headers = [_]std.http.Header{
        .{ .name = "x-pieverse-market-quote-capability", .value = capability },
    };
    const response = try fetch(arena, .POST, quote_url, payload, &headers);
    const sol_usd_rate = try marketUsdRate(arena, "SOL");
    return parsePlatformDflowQuote(arena, response, deployment, input_usd_rate, reference_usd_rate, sol_usd_rate, raw_amount);
}

fn parsePlatformDflowQuote(arena: Allocator, body: []const u8, deployment: Deployment, input_usd_rate: f64, reference_usd_rate: f64, sol_usd_rate: f64, expected_raw_amount: []const u8) !RankedQuote {
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, body, .{});
    defer parsed.deinit();
    const root = try requireObject(parsed.value);
    if (!(optionalBool(root, "ok") orelse false)) return error.QuoteUnavailable;
    const quote_item = try requireObject(root.get("data") orelse return error.QuoteUnavailable);
    if (!std.mem.eql(u8, optionalString(quote_item, "inputMint") orelse return error.InvalidQuote, deployment.input_contract) or
        !std.mem.eql(u8, optionalString(quote_item, "outputMint") orelse return error.InvalidQuote, deployment.contract) or
        !std.mem.eql(u8, optionalString(quote_item, "inAmount") orelse return error.InvalidQuote, expected_raw_amount)) return error.InvalidQuote;

    const raw_out = try numeric(quote_item.get("outAmount") orelse return error.QuoteUnavailable);
    const output_decimals = try numeric(quote_item.get("outputMintDecimals") orelse return error.InvalidQuote);
    if (!std.math.isFinite(output_decimals) or output_decimals < 0 or output_decimals > 30 or @floor(output_decimals) != output_decimals) return error.InvalidQuote;
    const amount_out = raw_out / std.math.pow(f64, 10, output_decimals);
    const exposure = amount_out * deployment.multiplier;
    if (!std.math.isFinite(exposure) or exposure <= 0) return error.InvalidQuote;

    const priority_lamports = if (quote_item.get("prioritizationFeeLamports")) |value| numeric(value) catch return error.InvalidQuote else 0;
    if (!std.math.isFinite(priority_lamports) or priority_lamports < 0) return error.InvalidQuote;
    if (!std.math.isFinite(sol_usd_rate) or sol_usd_rate <= 0) return error.ConversionUnavailable;
    const gas_usd = (priority_lamports + 5000) / 1_000_000_000 * sol_usd_rate;
    const actual_input_amount = (std.fmt.parseFloat(f64, expected_raw_amount) catch return error.InvalidQuote) / std.math.pow(f64, 10, @floatFromInt(deployment.input_decimals.?));
    return .{
        .issuer = deployment.issuer,
        .token_symbol = deployment.token_symbol,
        .chain = deployment.chain,
        .contract = deployment.contract,
        .input_asset = deployment.input_symbol,
        .input_contract = deployment.input_contract,
        .provider = "dflow",
        .route = optionalString(quote_item, "route") orelse "dflow",
        .amount_in = actual_input_amount,
        .amount_out = amount_out,
        .exposure_shares = exposure,
        .gas_reference = gas_usd / reference_usd_rate,
        .effective_reference_per_share = (actual_input_amount * input_usd_rate + gas_usd) / reference_usd_rate / exposure,
    };
}

fn quotePlatformOkxDex(arena: Allocator, deployment: Deployment, reference_notional: f64, reference_usd_rate: f64) !RankedQuote {
    const quote_url = io_mod.getenv("FX_PLATFORM_QUOTE_URL") orelse return error.QuoteBrokerUnavailable;
    const capability = io_mod.getenv("FX_PLATFORM_QUOTE_TOKEN") orelse return error.QuoteBrokerUnavailable;
    if (quote_url.len == 0 or capability.len == 0) return error.QuoteBrokerUnavailable;
    const input_decimals = deployment.input_decimals orelse return error.MissingTokenDecimals;
    const input_usd_rate = try currencyUsdRate(arena, deployment.input_symbol);
    const input_amount = reference_notional * reference_usd_rate / input_usd_rate;
    const raw_amount = try rawTokenAmount(arena, input_amount, input_decimals);
    const body_value = .{
        .fromTokenAddress = deployment.input_contract,
        .toTokenAddress = deployment.contract,
        .amount = raw_amount,
    };
    var body_writer: std.Io.Writer.Allocating = .init(arena);
    defer body_writer.deinit();
    try std.json.Stringify.value(body_value, .{}, &body_writer.writer);
    const payload = try body_writer.toOwnedSlice();
    const headers = [_]std.http.Header{
        .{ .name = "x-pieverse-market-quote-capability", .value = capability },
    };
    const response = try fetch(arena, .POST, quote_url, payload, &headers);
    return parsePlatformOkxQuote(arena, response, deployment, input_usd_rate, reference_usd_rate, raw_amount);
}

fn parsePlatformOkxQuote(arena: Allocator, body: []const u8, deployment: Deployment, input_usd_rate: f64, reference_usd_rate: f64, expected_raw_amount: []const u8) !RankedQuote {
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, body, .{});
    defer parsed.deinit();
    const root = try requireObject(parsed.value);
    if (!(optionalBool(root, "ok") orelse false)) return error.QuoteUnavailable;
    const quote_item = try requireObject(root.get("data") orelse return error.QuoteUnavailable);
    if (!std.mem.eql(u8, optionalString(quote_item, "chainIndex") orelse return error.InvalidQuote, "196")) return error.InvalidQuote;
    if (!std.mem.eql(u8, optionalString(quote_item, "fromTokenAmount") orelse return error.InvalidQuote, expected_raw_amount)) return error.InvalidQuote;
    const from_token = try requireObject(quote_item.get("fromToken") orelse return error.InvalidQuote);
    const to_token = try requireObject(quote_item.get("toToken") orelse return error.QuoteUnavailable);
    if (!addressesEqual(optionalString(from_token, "address") orelse return error.InvalidQuote, deployment.input_contract) or
        !addressesEqual(optionalString(to_token, "address") orelse return error.InvalidQuote, deployment.contract)) return error.InvalidQuote;
    const from_decimals = try numeric(from_token.get("decimals") orelse return error.InvalidQuote);
    if (from_decimals != @as(f64, @floatFromInt(deployment.input_decimals.?))) return error.InvalidQuote;
    const raw_out = try numeric(quote_item.get("toTokenAmount") orelse return error.QuoteUnavailable);
    const decimals = try numeric(to_token.get("decimals") orelse return error.QuoteUnavailable);
    if (!std.math.isFinite(decimals) or decimals < 0 or decimals > 30 or @floor(decimals) != decimals) return error.InvalidQuote;
    const amount_out = raw_out / std.math.pow(f64, 10, decimals);
    const gas_usd = numeric(quote_item.get("tradeFeeUsd") orelse return error.MissingUsdGasCost) catch return error.MissingUsdGasCost;
    const exposure = amount_out * deployment.multiplier;
    if (!std.math.isFinite(exposure) or exposure <= 0 or !std.math.isFinite(gas_usd) or gas_usd < 0) return error.InvalidQuote;
    const actual_input_amount = (std.fmt.parseFloat(f64, expected_raw_amount) catch return error.InvalidQuote) / std.math.pow(f64, 10, @floatFromInt(deployment.input_decimals.?));
    const route = try joinedProtocols(arena, quote_item.get("protocols"));
    return .{
        .issuer = deployment.issuer,
        .token_symbol = deployment.token_symbol,
        .chain = deployment.chain,
        .contract = deployment.contract,
        .input_asset = deployment.input_symbol,
        .input_contract = deployment.input_contract,
        .provider = "okx_dex",
        .route = route,
        .amount_in = actual_input_amount,
        .amount_out = amount_out,
        .exposure_shares = exposure,
        .gas_reference = gas_usd / reference_usd_rate,
        .effective_reference_per_share = (actual_input_amount * input_usd_rate + gas_usd) / reference_usd_rate / exposure,
    };
}

fn rawTokenAmount(arena: Allocator, amount: f64, decimals: u8) ![]const u8 {
    if (!std.math.isFinite(amount) or amount <= 0 or decimals > 30) return error.InvalidTokenAmount;
    const scaled = amount * std.math.pow(f64, 10, @floatFromInt(decimals));
    if (!std.math.isFinite(scaled) or scaled < 1 or scaled > @as(f64, @floatFromInt(std.math.maxInt(u128)))) return error.InvalidTokenAmount;
    const raw: u128 = @intFromFloat(@round(scaled));
    return std.fmt.allocPrint(arena, "{d}", .{raw});
}

fn addressesEqual(left: []const u8, right: []const u8) bool {
    return std.ascii.eqlIgnoreCase(left, right);
}

fn joinedProtocols(arena: Allocator, value: ?std.json.Value) ![]const u8 {
    const array = requireArray(value orelse return "okx_aggregator") catch return "okx_aggregator";
    var output: std.Io.Writer.Allocating = .init(arena);
    defer output.deinit();
    for (array.items) |item| {
        if (item != .string or item.string.len == 0) continue;
        if (output.writer.end != 0) try output.writer.writeAll(" + ");
        try output.writer.writeAll(item.string);
    }
    if (output.writer.end == 0) return "okx_aggregator";
    return output.toOwnedSlice();
}

fn currencyUsdRate(arena: Allocator, currency: []const u8) !f64 {
    if (std.ascii.eqlIgnoreCase(currency, "USD")) return 1;
    if (!std.ascii.eqlIgnoreCase(currency, "USDT") and !std.ascii.eqlIgnoreCase(currency, "USDC"))
        return error.UnsupportedReferenceCurrency;
    const symbol = try std.fmt.allocPrint(arena, "{s}USD", .{currency});
    const url = try std.fmt.allocPrint(arena, "https://api.binance.com/api/v3/ticker/price?symbol={s}", .{symbol});
    const body = try fetch(arena, .GET, url, null, &.{});
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, body, .{});
    defer parsed.deinit();
    const rate = try numeric((try requireObject(parsed.value)).get("price") orelse return error.ConversionUnavailable);
    if (!std.math.isFinite(rate) or rate <= 0) return error.ConversionUnavailable;
    return rate;
}

fn marketUsdRate(arena: Allocator, asset: []const u8) !f64 {
    const symbol = try std.fmt.allocPrint(arena, "{s}USDT", .{asset});
    const url = try std.fmt.allocPrint(arena, "https://api.binance.com/api/v3/ticker/price?symbol={s}", .{symbol});
    const body = try fetch(arena, .GET, url, null, &.{});
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, body, .{});
    defer parsed.deinit();
    const rate = try numeric((try requireObject(parsed.value)).get("price") orelse return error.ConversionUnavailable);
    if (!std.math.isFinite(rate) or rate <= 0) return error.ConversionUnavailable;
    return rate;
}

fn bitgetTokenUsdRate(arena: Allocator, chain: []const u8, contract: []const u8, now_ms: i64) !f64 {
    const payload = .{ .list = &.{.{ .chain = chain, .contract = contract }} };
    const body = try postBitget(arena, "/market/v3/coin/batchGetBaseInfo", payload, now_ms);
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, body, .{});
    defer parsed.deinit();
    const root = try requireObject(parsed.value);
    if ((optionalInteger(root, "status") orelse -1) != 0) return error.ConversionUnavailable;
    const data = try requireObject(root.get("data") orelse return error.ConversionUnavailable);
    const values = try requireArray(data.get("list") orelse return error.ConversionUnavailable);
    if (values.items.len == 0) return error.ConversionUnavailable;
    const rate = try numeric((try requireObject(values.items[0])).get("price") orelse return error.ConversionUnavailable);
    if (!std.math.isFinite(rate) or rate <= 0) return error.ConversionUnavailable;
    return rate;
}

fn postBitget(arena: Allocator, path: []const u8, body_value: anytype, now_ms: i64) ![]u8 {
    var body_writer: std.Io.Writer.Allocating = .init(arena);
    defer body_writer.deinit();
    try std.json.Stringify.value(body_value, .{}, &body_writer.writer);
    const payload = try body_writer.toOwnedSlice();
    const timestamp = try std.fmt.allocPrint(arena, "{d}", .{now_ms});
    const signing = try std.fmt.allocPrint(arena, "POST{s}{s}{s}", .{ path, payload, timestamp });
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(signing, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    const signature = try std.fmt.allocPrint(arena, "0x{s}", .{hex});
    const headers = [_]std.http.Header{
        .{ .name = "channel", .value = "toc_agent" },
        .{ .name = "brand", .value = "toc_agent" },
        .{ .name = "clientversion", .value = "10.0.0" },
        .{ .name = "language", .value = "en" },
        .{ .name = "token", .value = "toc_agent" },
        .{ .name = "X-SIGN", .value = signature },
        .{ .name = "X-TIMESTAMP", .value = timestamp },
    };
    const url = try std.fmt.allocPrint(arena, "https://copenapi.bgwapi.io{s}", .{path});
    return fetch(arena, .POST, url, payload, &headers);
}

fn fetch(arena: Allocator, method: std.http.Method, url: []const u8, payload: ?[]const u8, headers: []const std.http.Header) ![]u8 {
    var client: std.http.Client = .{ .allocator = arena, .io = io_mod.getIo() };
    defer client.deinit();
    var environ = if (builtin.is_test)
        try std.process.Environ.createMap(std.testing.environ, arena)
    else
        try io_mod.cloneEnvironMap(arena);
    defer environ.deinit();
    try client.initDefaultProxies(arena, &environ);
    const buffer = try arena.alloc(u8, max_http_body_bytes + 1);
    var response_writer = std.Io.Writer.fixed(buffer);
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = payload,
        .headers = .{
            .content_type = if (payload != null) .{ .override = "application/json" } else .default,
            .accept_encoding = .omit,
            .user_agent = .{ .override = "fx-market-research/1" },
        },
        .extra_headers = headers,
        .response_writer = &response_writer,
    });
    if (result.status.class() != .success) return error.HttpStatus;
    return response_writer.buffered();
}

fn canonicalTicker(arena: Allocator, value: []const u8) ![]const u8 {
    if (value.len == 0 or value.len > 16) return error.InvalidTicker;
    const output = try arena.alloc(u8, value.len);
    for (value, 0..) |byte, index| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '-') return error.InvalidTicker;
        output[index] = std.ascii.toUpper(byte);
    }
    return output;
}

fn quoteLessThan(_: void, left: RankedQuote, right: RankedQuote) bool {
    if (left.effective_reference_per_share != right.effective_reference_per_share)
        return left.effective_reference_per_share < right.effective_reference_per_share;
    if (!std.mem.eql(u8, left.chain, right.chain)) return std.mem.lessThan(u8, left.chain, right.chain);
    return std.mem.lessThan(u8, left.issuer, right.issuer);
}

fn quoteOutput(value: RankedQuote) QuoteOutput {
    return .{
        .issuer = value.issuer,
        .tokenSymbol = value.token_symbol,
        .chain = value.chain,
        .contract = value.contract,
        .inputAsset = value.input_asset,
        .inputContract = value.input_contract,
        .provider = value.provider,
        .route = value.route,
        .amountIn = value.amount_in,
        .amountOut = value.amount_out,
        .exposureShares = value.exposure_shares,
        .gasReference = value.gas_reference,
        .effectiveReferencePerShare = value.effective_reference_per_share,
        .totalCostRank = value.rank,
    };
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

fn optionalString(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn optionalBool(object: std.json.ObjectMap, name: []const u8) ?bool {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .bool => |item| item,
        else => null,
    };
}

fn optionalInteger(object: std.json.ObjectMap, name: []const u8) ?i64 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .integer => |item| item,
        else => null,
    };
}

fn decimalPlaces(object: std.json.ObjectMap, name: []const u8) ?u8 {
    const value = object.get(name) orelse return null;
    const number: i64 = switch (value) {
        .integer => |item| item,
        .string => |text| std.fmt.parseInt(i64, text, 10) catch return null,
        else => return null,
    };
    if (number < 0 or number > 30) return null;
    return @intCast(number);
}

fn numeric(value: std.json.Value) !f64 {
    return switch (value) {
        .integer => |number| @floatFromInt(number),
        .float => |number| number,
        .string => |text| std.fmt.parseFloat(f64, text) catch return error.ExpectedNumber,
        else => error.ExpectedNumber,
    };
}

fn hasString(value: std.json.Value, wanted: []const u8) bool {
    const array = requireArray(value) catch return false;
    for (array.items) |item| if (item == .string and std.ascii.eqlIgnoreCase(item.string, wanted)) return true;
    return false;
}

fn errorReason(arena: Allocator, err: anyerror) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}", .{@errorName(err)});
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

test "parses and ranks Bitget quotes by exact input plus gas" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const deployment = Deployment{
        .issuer = "bstocks",
        .token_symbol = "CRCLB",
        .chain = "BNB Smart Chain",
        .contract = "0xstock",
        .input_symbol = "USDT",
        .input_contract = "0xusdt",
        .input_decimals = 6,
        .multiplier = 1.25,
        .provider = .bitget_wallet,
    };
    const body =
        \\{"status":0,"data":{"quoteResults":[{"market":{"label":"route-a"},"outAmount":"0.98","gasFees":{"gasFeeAmountInUsd":"0.10"}},{"market":{"label":"route-b"},"outAmount":"0.99","gasFees":{"gasFeeAmountInUsd":"0.05"}}]}}
    ;
    const result = try parseBitgetQuote(arena, body, deployment, 100, 1, 1);
    try std.testing.expectEqualStrings("route-b", result.route);
    try std.testing.expectApproxEqAbs(@as(f64, 0.99 * 1.25), result.exposure_shares, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 100.05 / (0.99 * 1.25)), result.effective_reference_per_share, 0.000001);
}

test "parses a scoped platform X Layer quote" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const deployment = Deployment{
        .issuer = "xstocks",
        .token_symbol = "CRCLx",
        .chain = "XLayer",
        .contract = "0xfebded1b0986a8ee107f5ab1a1c5a813491deceb",
        .input_symbol = "USDC",
        .input_contract = "0xb6ceceab302e2e4948951ee7843fc24e92933061",
        .input_decimals = 6,
        .multiplier = 1,
        .provider = .platform_okx_dex,
    };
    const body =
        \\{"ok":true,"data":{"chainIndex":"196","fromTokenAmount":"100000000","toTokenAmount":"981218606619704013","tradeFeeUsd":"0.00061514543395727","estimateGasFee":"334258","priceImpactPercent":"0.01","fromToken":{"address":"0xb6ceceab302e2e4948951ee7843fc24e92933061","symbol":"USDC","decimals":6},"toToken":{"address":"0xfebded1b0986a8ee107f5ab1a1c5a813491deceb","symbol":"CRCLx","decimals":18},"protocols":["Uniswap V3","xStocks wrap V2"]}}
    ;
    const result = try parsePlatformOkxQuote(arena, body, deployment, 1, 1, "100000000");
    try std.testing.expectEqualStrings("okx_dex", result.provider);
    try std.testing.expectEqualStrings("Uniswap V3 + xStocks wrap V2", result.route);
    try std.testing.expectApproxEqAbs(@as(f64, 0.981218606619704013), result.amount_out, 0.000000000001);
    try std.testing.expectApproxEqAbs(@as(f64, 100.00061514543396 / 0.981218606619704013), result.effective_reference_per_share, 0.000000001);
}

test "parses a scoped platform DFlow quote in atomic token units" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const deployment = Deployment{
        .issuer = "xstocks",
        .token_symbol = "CRCLx",
        .chain = "Solana",
        .contract = "XsueG8BtpquVJX9LVLLEGuViXUungE6WmK5YZ3p3bd1",
        .input_symbol = "USDC",
        .input_contract = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v",
        .input_decimals = 6,
        .multiplier = 1,
        .provider = .platform_dflow,
    };
    const body =
        \\{"ok":true,"data":{"inputMint":"EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v","inAmount":"100000000","outputMint":"XsueG8BtpquVJX9LVLLEGuViXUungE6WmK5YZ3p3bd1","outAmount":"98121860","outputMintDecimals":8,"prioritizationFeeLamports":"10000","route":"Jupiter"}}
    ;
    const result = try parsePlatformDflowQuote(arena, body, deployment, 1, 1, 100, "100000000");
    try std.testing.expectEqualStrings("dflow", result.provider);
    try std.testing.expectEqualStrings("Jupiter", result.route);
    try std.testing.expectApproxEqAbs(@as(f64, 0.98121860), result.amount_out, 0.000000001);
    try std.testing.expect(result.gas_reference > 0);
    try std.testing.expect(result.effective_reference_per_share > @as(f64, 100) / 0.98121860);
}

test "converts readable token amounts to exact raw units" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const raw = try rawTokenAmount(arena_state.allocator(), 100.125, 6);
    try std.testing.expectEqualStrings("100125000", raw);
}

test "rejects unsafe ticker characters" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(error.InvalidTicker, canonicalTicker(arena_state.allocator(), "CRCL;rm"));
}
