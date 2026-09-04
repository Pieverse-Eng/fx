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
    multiplier: f64,
    provider: Provider,
};

const Provider = enum { bitget_wallet, okx_onchainos };

const RankedQuote = struct {
    issuer: []const u8,
    token_symbol: []const u8,
    chain: []const u8,
    contract: []const u8,
    input_asset: []const u8,
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

    var quotes: std.ArrayList(RankedQuote) = .empty;
    for (deployments.items) |deployment| {
        const ranked = switch (deployment.provider) {
            .bitget_wallet => quoteBitget(arena, deployment, notional, reference_usd_rate, now_ms) catch |err| {
                try excluded.append(arena, .{ .issuer = deployment.issuer, .chain = deployment.chain, .reason = try errorReason(arena, err) });
                continue;
            },
            .okx_onchainos => quoteOkx(arena, deployment, notional, reference_usd_rate) catch |err| {
                try excluded.append(arena, .{ .issuer = deployment.issuer, .chain = deployment.chain, .reason = try errorReason(arena, err) });
                continue;
            },
        };
        try quotes.append(arena, ranked);
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
        const provider: Provider = if (std.mem.eql(u8, network, "XLayer")) .okx_onchainos else if (std.mem.eql(u8, network, "Solana") or std.mem.eql(u8, network, "Ethereum")) .bitget_wallet else continue;
        if (!(optionalBool(item, "supportsAtomicSwaps") orelse false)) continue;
        const contract = optionalString(item, "address") orelse continue;
        const stablecoins_value = item.get("stablecoins") orelse continue;
        const stablecoins = requireArray(stablecoins_value) catch continue;
        const stablecoin = chooseUsdStablecoin(stablecoins.items, provider) orelse continue;
        var multiplier: f64 = 1;
        if (std.mem.eql(u8, network, "Solana")) {
            const multiplier_url = try std.fmt.allocPrint(arena, "https://api.xstocks.fi/api/v2/public/assets/{s}/multiplier?network=Solana", .{symbol});
            const multiplier_body = fetch(arena, .GET, multiplier_url, null, &.{}) catch continue;
            var multiplier_parsed = std.json.parseFromSlice(std.json.Value, arena, multiplier_body, .{}) catch continue;
            defer multiplier_parsed.deinit();
            multiplier = numeric((requireObject(multiplier_parsed.value) catch continue).get("currentMultiplier") orelse continue) catch continue;
        }
        if (!std.math.isFinite(multiplier) or multiplier <= 0) continue;
        try deployments.append(arena, .{
            .issuer = "xstocks",
            .token_symbol = optionalString(root, "symbol") orelse symbol,
            .chain = network,
            .contract = contract,
            .input_symbol = stablecoin.symbol,
            .input_contract = stablecoin.contract,
            .multiplier = multiplier,
            .provider = provider,
        });
    }
}

const Stablecoin = struct { symbol: []const u8, contract: []const u8 };

fn chooseUsdStablecoin(values: []const std.json.Value, provider: Provider) ?Stablecoin {
    const preferred: []const []const u8 = switch (provider) {
        .bitget_wallet => &.{ "USDT", "USDC", "USDG" },
        .okx_onchainos => &.{ "USDC", "USDG", "USDT" },
    };
    for (preferred) |wanted| for (values) |value| {
        const item = requireObject(value) catch continue;
        const currency = optionalString(item, "currency") orelse continue;
        const symbol = optionalString(item, "symbol") orelse continue;
        const contract = optionalString(item, "address") orelse continue;
        if (std.ascii.eqlIgnoreCase(currency, "USD") and std.ascii.eqlIgnoreCase(symbol, wanted))
            return .{ .symbol = symbol, .contract = contract };
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
    for (values.items) |value| {
        const item = requireObject(value) catch continue;
        const underlying = optionalString(item, "uq") orelse continue;
        if (!std.ascii.eqlIgnoreCase(underlying, ticker) or !(optionalBool(item, "trading") orelse false)) continue;
        if (!hasString(item.get("tags") orelse continue, "bStocks")) continue;
        symbol = optionalString(item, "assetCode");
        if (symbol != null) break;
    }
    if (symbol == null) return;

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
                .multiplier = 1,
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

fn quoteOkx(arena: Allocator, deployment: Deployment, reference_notional: f64, reference_usd_rate: f64) !RankedQuote {
    const input_usd_rate = try currencyUsdRate(arena, deployment.input_symbol);
    const input_amount = reference_notional * reference_usd_rate / input_usd_rate;
    const amount = try std.fmt.allocPrint(arena, "{d}", .{input_amount});
    const result = try std.process.run(arena, io_mod.getIo(), .{
        .argv = &.{ "onchainos", "swap", "quote", "--from", deployment.input_contract, "--to", deployment.contract, "--readable-amount", amount, "--chain", "xlayer" },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(64 * 1024),
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(20_000) } },
    });
    switch (result.term) {
        .exited => |code| if (code != 0) return error.QuoteUnavailable,
        else => return error.QuoteUnavailable,
    }
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, result.stdout, .{});
    defer parsed.deinit();
    const root = try requireObject(parsed.value);
    if (!(optionalBool(root, "ok") orelse false)) return error.QuoteUnavailable;
    const data = try requireArray(root.get("data") orelse return error.QuoteUnavailable);
    if (data.items.len == 0) return error.NoExecutableRoute;
    const quote_item = try requireObject(data.items[0]);
    const raw_out = try numeric(quote_item.get("toTokenAmount") orelse return error.QuoteUnavailable);
    const to_token = try requireObject(quote_item.get("toToken") orelse return error.QuoteUnavailable);
    const decimals = try numeric(to_token.get("decimal") orelse return error.QuoteUnavailable);
    const amount_out = raw_out / std.math.pow(f64, 10, decimals);
    const gas_usd = numeric(quote_item.get("tradeFee") orelse return error.MissingUsdGasCost) catch return error.MissingUsdGasCost;
    const exposure = amount_out * deployment.multiplier;
    if (!std.math.isFinite(exposure) or exposure <= 0 or !std.math.isFinite(gas_usd) or gas_usd < 0) return error.InvalidQuote;
    return .{
        .issuer = deployment.issuer,
        .token_symbol = deployment.token_symbol,
        .chain = deployment.chain,
        .contract = deployment.contract,
        .input_asset = deployment.input_symbol,
        .provider = "okx_onchainos",
        .route = "okx_aggregator",
        .amount_in = input_amount,
        .amount_out = amount_out,
        .exposure_shares = exposure,
        .gas_reference = gas_usd / reference_usd_rate,
        .effective_reference_per_share = (input_amount * input_usd_rate + gas_usd) / reference_usd_rate / exposure,
    };
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
        .multiplier = 1,
        .provider = .bitget_wallet,
    };
    const body =
        \\{"status":0,"data":{"quoteResults":[{"market":{"label":"route-a"},"outAmount":"0.98","gasFees":{"gasFeeAmountInUsd":"0.10"}},{"market":{"label":"route-b"},"outAmount":"0.99","gasFees":{"gasFeeAmountInUsd":"0.05"}}]}}
    ;
    const result = try parseBitgetQuote(arena, body, deployment, 100, 1, 1);
    try std.testing.expectEqualStrings("route-b", result.route);
    try std.testing.expectApproxEqAbs(@as(f64, 100.05 / 0.99), result.effective_reference_per_share, 0.000001);
}

test "rejects unsafe ticker characters" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(error.InvalidTicker, canonicalTicker(arena_state.allocator(), "CRCL;rm"));
}
