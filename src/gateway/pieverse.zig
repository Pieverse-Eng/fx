const std = @import("std");
const io_mod = @import("../core/shared/io.zig");
const secret = @import("../core/auth/secret.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const model_tool_schema = @import("../core/tooling/model_tool_schema.zig");
const types = @import("../core/shared/types.zig");
const gateway_client = @import("client.zig");

const Allocator = std.mem.Allocator;
const default_base_url = "https://ai.pieverse.io/v1";
const base_url_env = "FX_PIEVERSE_BASE_URL";
const max_error_body_bytes: usize = 1024 * 1024;
const max_sse_line_bytes: usize = 32 * 1024 * 1024;
const max_sse_aggregate_bytes: usize = 64 * 1024 * 1024;
const max_sse_events: usize = 100_000;
const max_tool_calls: usize = 128;
const max_tool_identity_bytes: usize = 1024;
const max_tool_arguments_bytes: usize = 4 * 1024 * 1024;
const transfer_buffer_bytes: usize = 256 * 1024;
const connect_timeout_ms: i64 = 30_000;

pub const agent_stream_provider = stream_provider.Provider{
    .stream_fn = streamCompletion,
};

pub fn fallbackModelCapabilities(_: []const u8) @import("../core/config/model_capabilities.zig").Capabilities {
    return .{
        .supports_reasoning = true,
        .supports_tool_use = true,
        .supports_vision = false,
        .parallel_tool_calls = true,
    };
}

fn validateModel(model: []const u8) !void {
    if (model.len == 0 or model.len > 1024) return error.InvalidPieverseModel;
    for (model) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return error.InvalidPieverseModel;
    }
}

pub fn buildRequest(alloc: Allocator, request: stream_provider.RequestData) ![]u8 {
    try validateModel(request.model);
    if (request.verified_images != null or request.vision_mode == .required) {
        return error.PieverseVisionUnsupported;
    }
    if (request.budget) |budget| {
        if (budget.cancel_flag) |flag| if (flag.load(.seq_cst)) return error.Cancelled;
        _ = budget.deadline;
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"model\":");
    try std.json.Stringify.value(request.model, .{}, writer);
    try writer.writeAll(",\"messages\":[");
    try writeMessages(writer, request.messages);
    try writer.writeAll("],\"stream\":true,\"stream_options\":{\"include_usage\":true}");

    const tool_count = try writeTools(writer, alloc, request.tools);
    if (tool_count > 0 or request.tool_choice != .auto) {
        try writer.writeAll(",\"tool_choice\":");
        try std.json.Stringify.value(request.tool_choice.label(), .{}, writer);
    }
    if (request.provider_options.parallel_tool_calls) |enabled| {
        try writer.writeAll(",\"parallel_tool_calls\":");
        try writer.writeAll(if (enabled) "true" else "false");
    }
    if (request.provider_options.reasoning) |effort| {
        try writer.writeAll(",\"reasoning_effort\":");
        try std.json.Stringify.value(effort.label(), .{}, writer);
    }
    if (request.max_output_tokens) |limit| {
        try writer.print(",\"max_completion_tokens\":{d}", .{limit});
    }
    if (request.response_format) |format| {
        if (format.schema != .object) return error.InvalidStructuredResponseSchema;
        try writer.writeAll(",\"response_format\":{\"type\":\"json_schema\",\"json_schema\":{\"name\":");
        try std.json.Stringify.value(format.name, .{}, writer);
        try writer.writeAll(",\"description\":");
        try std.json.Stringify.value(format.description, .{}, writer);
        try writer.writeAll(",\"schema\":");
        try std.json.Stringify.value(format.schema, .{}, writer);
        try writer.writeAll(",\"strict\":true}}");
    }
    try writer.writeByte('}');
    return out.toOwnedSlice();
}

fn writeMessages(writer: *std.Io.Writer, messages: []const types.ChatMessage) !void {
    for (messages, 0..) |message, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.writeAll("{\"role\":");
        try std.json.Stringify.value(@tagName(message.role), .{}, writer);
        switch (message.role) {
            .system, .user => {
                try writer.writeAll(",\"content\":");
                try std.json.Stringify.value(message.content orelse "", .{}, writer);
            },
            .assistant => {
                try writer.writeAll(",\"content\":");
                if (message.content) |content| {
                    try std.json.Stringify.value(content, .{}, writer);
                } else {
                    try writer.writeAll("null");
                }
                if (message.tool_calls.len > 0) {
                    try writer.writeAll(",\"tool_calls\":[");
                    for (message.tool_calls, 0..) |call, call_index| {
                        if (call_index > 0) try writer.writeByte(',');
                        try writer.writeAll("{\"id\":");
                        try std.json.Stringify.value(call.id, .{}, writer);
                        try writer.writeAll(",\"type\":\"function\",\"function\":{\"name\":");
                        try std.json.Stringify.value(call.name, .{}, writer);
                        try writer.writeAll(",\"arguments\":");
                        try std.json.Stringify.value(call.arguments_json, .{}, writer);
                        try writer.writeAll("}}");
                    }
                    try writer.writeByte(']');
                }
            },
            .tool => {
                try writer.writeAll(",\"tool_call_id\":");
                try std.json.Stringify.value(message.tool_call_id orelse "", .{}, writer);
                try writer.writeAll(",\"content\":");
                try std.json.Stringify.value(message.content orelse "", .{}, writer);
            },
        }
        try writer.writeByte('}');
    }
}

fn writeTools(writer: *std.Io.Writer, alloc: Allocator, tools: stream_provider.ToolSelection) !usize {
    var count: usize = 0;
    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    try encoded.writer.writeAll(",\"tools\":[");
    for (tools.advertised_names) |name| {
        const tool = tools.advertisedFunction(name) orelse continue;
        if (count > 0) try encoded.writer.writeByte(',');
        try writeStaticTool(&encoded.writer, alloc, tool);
        count += 1;
    }
    for (tools.additional_functions) |tool| {
        if (containsName(tools.advertised_names, tool.name)) continue;
        if (count > 0) try encoded.writer.writeByte(',');
        try writeStaticTool(&encoded.writer, alloc, tool);
        count += 1;
    }
    for (tools.selected_dynamic) |tool| {
        if (containsName(tools.advertised_names, tool.name)) continue;
        if (count > 0) try encoded.writer.writeByte(',');
        try encoded.writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":");
        try std.json.Stringify.value(tool.name, .{}, &encoded.writer);
        try encoded.writer.writeAll(",\"description\":");
        try model_tool_schema.writeCappedDescriptionJsonString(alloc, &encoded.writer, tool.description);
        try encoded.writer.writeAll(",\"parameters\":");
        try std.json.Stringify.value(tool.input_schema, .{}, &encoded.writer);
        try encoded.writer.writeAll("}}");
        count += 1;
    }
    try encoded.writer.writeByte(']');
    if (count > 0) try writer.writeAll(encoded.written());
    return count;
}

fn writeStaticTool(writer: *std.Io.Writer, alloc: Allocator, tool: model_tool_schema.FunctionSchema) !void {
    try writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":");
    try std.json.Stringify.value(tool.name, .{}, writer);
    try writer.writeAll(",\"description\":");
    try model_tool_schema.writeCappedDescriptionJsonString(alloc, writer, tool.description);
    try writer.writeAll(",\"parameters\":");
    try model_tool_schema.writeObjectSchema(alloc, writer, tool.input_schema);
    try writer.writeAll("}}");
}

fn containsName(names: []const []const u8, candidate: []const u8) bool {
    for (names) |name| if (std.mem.eql(u8, name, candidate)) return true;
    return false;
}

fn streamCompletion(_: ?*anyopaque, alloc: Allocator, request: stream_provider.ModelRequest) !stream_provider.Result {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (request.credential.source != .pieverse_api_key) return error.PieverseCredentialRequired;
    const payload = try buildRequest(alloc, request.data());
    defer alloc.free(payload);
    return streamPrepared(alloc, request, payload) catch |err| {
        if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
        request.attempt_evidence.network_failure = gateway_client.networkFailureEvidence(err, request.delivery.load());
        return err;
    };
}

const OpenedRequest = struct {
    request: ?std.http.Client.Request,
    pub fn deinit(self: *OpenedRequest, _: Allocator) void {
        if (self.request) |*request| request.deinit();
        self.request = null;
    }
    pub fn take(self: *OpenedRequest) std.http.Client.Request {
        const request = self.request.?;
        self.request = null;
        return request;
    }
};

const OpenRequestOperation = struct {
    client: *std.http.Client,
    uri: std.Uri,
    auth_header: []const u8,
    extra_headers: []const std.http.Header,
    pub fn run(self: *@This()) !OpenedRequest {
        return .{ .request = try self.client.request(.POST, self.uri, .{
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .authorization = .{ .override = self.auth_header },
                .accept_encoding = .omit,
                .user_agent = .{ .override = gateway_client.user_agent },
            },
            .extra_headers = self.extra_headers,
            .keep_alive = false,
            .redirect_behavior = .unhandled,
        }) };
    }
};

fn endpointAlloc(alloc: Allocator) ![]u8 {
    const raw = io_mod.getenv(base_url_env) orelse default_base_url;
    const base = std.mem.trimEnd(u8, std.mem.trim(u8, raw, " \t\r\n"), "/");
    if (base.len == 0) return error.InvalidPieverseBaseUrl;
    return std.fmt.allocPrint(alloc, "{s}/chat/completions", .{base});
}

fn streamPrepared(alloc: Allocator, request: stream_provider.ModelRequest, payload: []const u8) !stream_provider.Result {
    const endpoint = try endpointAlloc(alloc);
    defer alloc.free(endpoint);
    const uri = std.Uri.parse(endpoint) catch return error.InvalidPieverseBaseUrl;
    const auth_header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{request.credential.secret});
    defer secret.zeroAndFree(alloc, auth_header);
    var extra_headers_buf: [2]std.http.Header = undefined;
    var extra_count: usize = 0;
    extra_headers_buf[extra_count] = .{ .name = "accept", .value = "text/event-stream" };
    extra_count += 1;
    if (request.session_id) |session_id| if (session_id.len > 0) {
        extra_headers_buf[extra_count] = .{ .name = "x-client-request-id", .value = session_id };
        extra_count += 1;
    };

    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();
    var operation = OpenRequestOperation{
        .client = &client,
        .uri = uri,
        .auth_header = auth_header,
        .extra_headers = extra_headers_buf[0..extra_count],
    };
    const connect_deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(connect_timeout_ms),
    });
    try request.admission.admit();
    var opened = try gateway_client.runBoundedHttpOperation(OpenedRequest, alloc, request.cancel_flag, connect_deadline, &operation);
    var http_request = opened.take();
    defer http_request.deinit();
    var cancel_watch_done = std.atomic.Value(bool).init(false);
    const cancel_watcher = if (http_request.connection) |connection|
        try gateway_client.spawnHttpCancelWatcher(&cancel_watch_done, request.cancel_flag, connection.stream_writer.stream)
    else
        null;
    defer {
        cancel_watch_done.store(true, .seq_cst);
        if (cancel_watcher) |thread| thread.join();
    }
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    http_request.transfer_encoding = .{ .content_length = payload.len };
    var send_buffer: [8192]u8 = undefined;
    request.delivery.markPossiblySent();
    var body_writer = try http_request.sendBodyUnflushed(&send_buffer);
    try body_writer.writer.writeAll(payload);
    try body_writer.end();
    if (http_request.connection) |connection| try connection.flush();
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;

    var response = try http_request.receiveHead(&.{});
    if (response.head.status != .ok) {
        var transfer: [16 * 1024]u8 = undefined;
        const reader = response.reader(&transfer);
        const body = reader.allocRemaining(alloc, .limited(max_error_body_bytes)) catch |err| switch (err) {
            error.StreamTooLong => try alloc.dupe(u8, "Pieverse error response exceeded the local limit"),
            else => return err,
        };
        return .{ .failed = .{
            .kind = failureKind(response.head.status),
            .detail = body,
            .ownership = .owned,
        } };
    }

    var transfer_buffer: [transfer_buffer_bytes]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    var events = request.events;
    const completion = try consumeSse(alloc, reader, &events, request.cancel_flag, request.content_capture_limit);
    return .{
        .completed = .{
            .completion = completion,
            // Pieverse returns exact token counts, but billing remains owned by the
            // gateway and is not projected as an fx-local cost record.
            .usage = .{ .unavailable = .possibly_billed },
            .ownership = .owned,
        },
    };
}

fn failureKind(status: std.http.Status) stream_provider.FailureKind {
    return switch (status) {
        .bad_request => .invalid_request,
        .unauthorized => .unauthorized,
        .forbidden, .payment_required => .forbidden,
        .payload_too_large => .request_too_large,
        .too_many_requests => .rate_limited,
        .internal_server_error => .server_error,
        .bad_gateway => .bad_gateway,
        .service_unavailable => .unavailable,
        .gateway_timeout => .gateway_timeout,
        else => .provider_error,
    };
}

const SseReader = struct {
    pending_line: std.ArrayList(u8) = .empty,
    aggregate_bytes: usize = 0,
    terminal_seen: bool = false,

    fn deinit(self: *SseReader, alloc: Allocator) void {
        self.pending_line.deinit(alloc);
    }
    fn release(self: *SseReader) void {
        self.pending_line.clearRetainingCapacity();
    }
    fn next(self: *SseReader, alloc: Allocator, reader: anytype) !?[]const u8 {
        while (true) {
            const line = try self.readLine(alloc, reader) orelse return null;
            self.aggregate_bytes = std.math.add(usize, self.aggregate_bytes, line.len) catch return error.PieverseResourceLimitExceeded;
            if (self.aggregate_bytes > max_sse_aggregate_bytes) return error.PieverseResourceLimitExceeded;
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == ':') {
                self.release();
                continue;
            }
            if (!std.mem.startsWith(u8, trimmed, "data:")) {
                self.release();
                continue;
            }
            const data = std.mem.trim(u8, trimmed["data:".len..], " \t");
            if (std.mem.eql(u8, data, "[DONE]")) {
                self.terminal_seen = true;
                return null;
            }
            return data;
        }
    }
    fn readLine(self: *SseReader, alloc: Allocator, reader: anytype) !?[]const u8 {
        while (true) {
            const fragment = reader.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => {
                    const buffered = reader.buffered();
                    if (buffered.len == 0) return error.PieverseSseReadStalled;
                    if (buffered.len > max_sse_line_bytes - self.pending_line.items.len) return error.PieverseSseEventTooLarge;
                    try self.pending_line.appendSlice(alloc, buffered);
                    reader.tossBuffered();
                    continue;
                },
                error.ReadFailed => return error.ReadFailed,
            } orelse {
                if (self.pending_line.items.len > 0) return self.pending_line.items;
                return null;
            };
            if (fragment.len > max_sse_line_bytes - self.pending_line.items.len) return error.PieverseSseEventTooLarge;
            if (self.pending_line.items.len == 0) return fragment;
            try self.pending_line.appendSlice(alloc, fragment);
            return self.pending_line.items;
        }
    }
};

const ToolAccumulator = struct {
    index: usize,
    id: std.ArrayList(u8) = .empty,
    name: std.ArrayList(u8) = .empty,
    arguments: std.ArrayList(u8) = .empty,
    announced: bool = false,
    fn deinit(self: *ToolAccumulator, alloc: Allocator) void {
        self.id.deinit(alloc);
        self.name.deinit(alloc);
        self.arguments.deinit(alloc);
    }
};

const Reducer = struct {
    content: std.ArrayList(u8) = .empty,
    tools: std.ArrayList(ToolAccumulator) = .empty,
    generation_id: ?[]u8 = null,
    finish_reason: ?types.ProviderFinishReason = null,
    usage: types.Usage = .{},
    event_count: usize = 0,

    fn deinit(self: *Reducer, alloc: Allocator) void {
        self.content.deinit(alloc);
        for (self.tools.items) |*tool| tool.deinit(alloc);
        self.tools.deinit(alloc);
        if (self.generation_id) |id| alloc.free(id);
    }

    fn applyJson(self: *Reducer, alloc: Allocator, json_text: []const u8, events: *stream_provider.EventSink, cancel_flag: *std.atomic.Value(bool), content_capture_limit: ?usize) !void {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        self.event_count += 1;
        if (self.event_count > max_sse_events) return error.PieverseResourceLimitExceeded;
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_text, .{}) catch return error.InvalidPieverseEvent;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidPieverseEvent;
        const root = parsed.value.object;
        if (root.get("error") != null) return error.PieverseResponseFailed;
        if (self.generation_id == null) if (stringField(root, "id")) |id| {
            if (id.len > max_tool_identity_bytes) return error.PieverseResourceLimitExceeded;
            self.generation_id = try alloc.dupe(u8, id);
        };
        parseUsage(root, &self.usage);
        const choices_value = root.get("choices") orelse return;
        if (choices_value != .array) return error.InvalidPieverseEvent;
        for (choices_value.array.items) |choice_value| {
            if (choice_value != .object) return error.InvalidPieverseEvent;
            const choice = choice_value.object;
            if (stringField(choice, "finish_reason")) |reason| self.finish_reason = types.ProviderFinishReason.parse_legacy(reason) orelse .other;
            const delta_value = choice.get("delta") orelse continue;
            if (delta_value != .object) return error.InvalidPieverseEvent;
            const delta = delta_value.object;
            if (stringField(delta, "reasoning_content") orelse stringField(delta, "reasoning")) |reasoning| {
                if (reasoning.len > 0) events.emit(.{ .reasoning_delta = reasoning });
            }
            if (stringField(delta, "content")) |content| if (content.len > 0) {
                events.emit(.{ .content_delta = content });
                try appendCaptured(&self.content, alloc, content, content_capture_limit);
            };
            const tool_values = delta.get("tool_calls") orelse continue;
            if (tool_values != .array) return error.InvalidPieverseEvent;
            for (tool_values.array.items) |tool_value| try self.applyToolDelta(alloc, tool_value, events);
        }
    }

    fn applyToolDelta(self: *Reducer, alloc: Allocator, value: std.json.Value, events: *stream_provider.EventSink) !void {
        if (value != .object) return error.InvalidPieverseEvent;
        const object = value.object;
        const raw_index = integerField(object, "index") orelse return error.InvalidPieverseEvent;
        if (raw_index < 0) return error.InvalidPieverseEvent;
        const index: usize = @intCast(raw_index);
        var tool = try self.toolAt(alloc, index);
        if (stringField(object, "id")) |id| try appendLimited(&tool.id, alloc, id, max_tool_identity_bytes);
        if (object.get("function")) |function_value| {
            if (function_value != .object) return error.InvalidPieverseEvent;
            if (stringField(function_value.object, "name")) |name| try appendLimited(&tool.name, alloc, name, max_tool_identity_bytes);
            if (!tool.announced and tool.id.items.len > 0 and tool.name.items.len > 0) {
                events.emit(.{ .tool_started = .{ .id = tool.id.items, .name = tool.name.items } });
                tool.announced = true;
            }
            if (stringField(function_value.object, "arguments")) |arguments| if (arguments.len > 0) {
                if (!tool.announced) return error.PieverseToolArgumentsBeforeIdentity;
                try appendLimited(&tool.arguments, alloc, arguments, max_tool_arguments_bytes);
                events.emit(.{ .tool_input_delta = arguments });
            };
        }
    }

    fn toolAt(self: *Reducer, alloc: Allocator, index: usize) !*ToolAccumulator {
        for (self.tools.items) |*tool| if (tool.index == index) return tool;
        if (self.tools.items.len >= max_tool_calls) return error.PieverseResourceLimitExceeded;
        try self.tools.append(alloc, .{ .index = index });
        return &self.tools.items[self.tools.items.len - 1];
    }

    fn finish(self: *Reducer, alloc: Allocator) !types.ModelCompletion {
        const content: ?[]const u8 = if (self.content.items.len > 0) try self.content.toOwnedSlice(alloc) else null;
        errdefer if (content) |value| alloc.free(value);
        const calls: []types.ToolCall = if (self.tools.items.len > 0)
            try alloc.alloc(types.ToolCall, self.tools.items.len)
        else
            &.{};
        var initialized: usize = 0;
        errdefer {
            for (calls[0..initialized]) |call| {
                alloc.free(call.id);
                alloc.free(call.name);
                alloc.free(call.arguments_json);
            }
            if (calls.len > 0) alloc.free(calls);
        }
        for (self.tools.items, 0..) |*tool, index| {
            if (!tool.announced) return error.IncompletePieverseToolCall;
            const id = try tool.id.toOwnedSlice(alloc);
            errdefer alloc.free(id);
            const name = try tool.name.toOwnedSlice(alloc);
            errdefer alloc.free(name);
            const arguments = try tool.arguments.toOwnedSlice(alloc);
            errdefer alloc.free(arguments);
            calls[index] = .{
                .id = id,
                .name = name,
                .arguments_json = arguments,
                .argument_integrity = try types.ToolArgumentIntegrity.classifySerialized(alloc, arguments),
            };
            initialized += 1;
        }
        const generation_id = self.generation_id;
        self.generation_id = null;
        return .{
            .content = content,
            .tool_calls = calls,
            .generation_id = generation_id,
            .finish_reason = self.finish_reason orelse if (calls.len > 0) .tool_calls else .stop,
            .usage = self.usage,
        };
    }
};

fn consumeSse(alloc: Allocator, reader: anytype, events: *stream_provider.EventSink, cancel_flag: *std.atomic.Value(bool), content_capture_limit: ?usize) !types.ModelCompletion {
    var reducer: Reducer = .{};
    defer reducer.deinit(alloc);
    var sse: SseReader = .{};
    defer sse.deinit(alloc);
    while (try sse.next(alloc, reader)) |json_text| {
        try reducer.applyJson(alloc, json_text, events, cancel_flag, content_capture_limit);
        sse.release();
    }
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (!sse.terminal_seen or reducer.finish_reason == null) return error.PieverseStreamIncomplete;
    return reducer.finish(alloc);
}

fn appendCaptured(list: *std.ArrayList(u8), alloc: Allocator, bytes: []const u8, limit: ?usize) !void {
    const cap = limit orelse return list.appendSlice(alloc, bytes);
    if (list.items.len >= cap) return;
    try list.appendSlice(alloc, bytes[0..@min(bytes.len, cap - list.items.len)]);
}

fn appendLimited(list: *std.ArrayList(u8), alloc: Allocator, bytes: []const u8, limit: usize) !void {
    if (bytes.len > limit -| list.items.len) return error.PieverseResourceLimitExceeded;
    try list.appendSlice(alloc, bytes);
}

fn parseUsage(root: std.json.ObjectMap, usage: *types.Usage) void {
    const value = root.get("usage") orelse return;
    if (value != .object) return;
    usage.input_tokens = unsignedField(value.object, "prompt_tokens") orelse usage.input_tokens;
    usage.output_tokens = unsignedField(value.object, "completion_tokens") orelse usage.output_tokens;
    if (value.object.get("prompt_tokens_details")) |details| if (details == .object) {
        usage.cache_read_tokens = unsignedField(details.object, "cached_tokens") orelse usage.cache_read_tokens;
    };
    if (value.object.get("completion_tokens_details")) |details| if (details == .object) {
        usage.reasoning_tokens = unsignedField(details.object, "reasoning_tokens") orelse usage.reasoning_tokens;
    };
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}
fn integerField(object: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = object.get(key) orelse return null;
    return if (value == .integer) value.integer else null;
}
fn unsignedField(object: std.json.ObjectMap, key: []const u8) ?u64 {
    const value = integerField(object, key) orelse return null;
    return if (value >= 0) @intCast(value) else null;
}

test "Pieverse request uses OpenAI chat completions tools and tenant model id" {
    const schema = model_tool_schema.FunctionSchema{
        .name = "market_search",
        .description = "Search configured trading venues",
        .input_schema = .{},
    };
    const body = try buildRequest(std.testing.allocator, .{
        .model = "pieverse/auto/paid",
        .messages = &.{
            .{ .role = .system, .content = "Research markets." },
            .{ .role = .user, .content = "Find BTC." },
        },
        .tools = .{
            .advertised_names = &.{"market_search"},
            .advertised_functions = &.{schema},
        },
        .tool_choice = .auto,
        .provider_options = .{ .parallel_tool_calls = true },
    });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.find(u8, body, "\"model\":\"pieverse/auto/paid\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"stream_options\":{\"include_usage\":true}") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"function\":{\"name\":\"market_search\"") != null);
}

test "Pieverse reducer assembles content tool deltas finish reason and usage" {
    const Capture = struct {
        content_events: usize = 0,
        tool_starts: usize = 0,
        tool_deltas: usize = 0,
        fn emit(raw: *anyopaque, event: stream_provider.Event) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            switch (event) {
                .content_delta => self.content_events += 1,
                .tool_started => self.tool_starts += 1,
                .tool_input_delta => self.tool_deltas += 1,
                .reasoning_delta => {},
            }
        }
    };
    var capture: Capture = .{};
    var sink = stream_provider.EventSink{ .context = &capture, .emit_fn = Capture.emit };
    var cancel = std.atomic.Value(bool).init(false);
    var reducer: Reducer = .{};
    defer reducer.deinit(std.testing.allocator);
    try reducer.applyJson(std.testing.allocator, "{\"id\":\"chatcmpl_1\",\"choices\":[{\"delta\":{\"content\":\"hello\"},\"finish_reason\":null}]}", &sink, &cancel, null);
    const tool_start =
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"market_search","arguments":"{\"q\":"}}]},"finish_reason":null}]}
    ;
    const tool_finish =
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"BTC\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":12,"completion_tokens":7}}
    ;
    try reducer.applyJson(std.testing.allocator, tool_start, &sink, &cancel, null);
    try reducer.applyJson(std.testing.allocator, tool_finish, &sink, &cancel, null);
    const completion = try reducer.finish(std.testing.allocator);
    defer {
        if (completion.content) |content| std.testing.allocator.free(content);
        if (completion.generation_id) |id| std.testing.allocator.free(id);
        for (completion.tool_calls) |call| {
            std.testing.allocator.free(call.id);
            std.testing.allocator.free(call.name);
            std.testing.allocator.free(call.arguments_json);
        }
        std.testing.allocator.free(completion.tool_calls);
    }
    try std.testing.expectEqualStrings("hello", completion.content.?);
    try std.testing.expectEqualStrings("{\"q\":\"BTC\"}", completion.tool_calls[0].arguments_json);
    try std.testing.expectEqual(types.ProviderFinishReason.tool_calls, completion.finish_reason.?);
    try std.testing.expectEqual(@as(?u64, 12), completion.usage.input_tokens);
    try std.testing.expectEqual(@as(usize, 1), capture.tool_starts);
    try std.testing.expectEqual(@as(usize, 2), capture.tool_deltas);
}

fn consumeTestSse(bytes: []const u8) !types.ModelCompletion {
    const Capture = struct {
        fn emit(_: *anyopaque, _: stream_provider.Event) void {}
    };
    var reader: std.Io.Reader = .fixed(bytes);
    var context: u8 = 0;
    var sink = stream_provider.EventSink{ .context = &context, .emit_fn = Capture.emit };
    var cancel = std.atomic.Value(bool).init(false);
    return consumeSse(std.testing.allocator, &reader, &sink, &cancel, null);
}

test "Pieverse SSE rejects a truncated stream" {
    const truncated =
        \\data: {"choices":[{"delta":{"content":"TRUNCATED"},"finish_reason":null}]}
        \\
    ;
    try std.testing.expectError(error.PieverseStreamIncomplete, consumeTestSse(truncated));
}

test "Pieverse SSE rejects provider error frames" {
    const failed =
        \\data: {"error":{"message":"upstream failed"}}
        \\
        \\data: [DONE]
        \\
    ;
    try std.testing.expectError(error.PieverseResponseFailed, consumeTestSse(failed));
}
