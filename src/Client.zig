//! A TypeSafe API client.
//!
//! A `Client` holds the resolved configuration and a `std.http.Client` with
//! its keep-alive connection pool. Build one per program and share it:
//! calls from many tasks or threads can run on the same client at the same
//! time, because the connection pool is guarded by a mutex and each call
//! creates its own request.
//!
//! ```zig
//! var client: typesafe.Client = try .initFromEnv(init.gpa, init.io, init.environ_map, .{});
//! defer client.deinit();
//!
//! var result = try client.ask("Help! My payouts have been failing for 3 days.", questions, .{});
//! defer result.deinit();
//! ```
//!
//! After the first request, a client must not be moved or copied: open
//! connections point back at it. Keep it in one place, as above, and pass
//! `*Client` around.
//!
//! Each call makes up to `retry.max_retries + 1` attempts. Each attempt is
//! bounded by `timeout`, which covers connecting, the TLS handshake, sending
//! the request and reading the whole response. The timeout needs an `Io` that
//! can run tasks concurrently, as `std.Io.Threaded` and the evented
//! implementations can; without concurrency, requests run without it.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const errors = @import("errors.zig");
const Error = errors.Error;
const InitError = errors.InitError;
const Retry = @import("Retry.zig");
const Diagnostics = @import("Diagnostics.zig");
const hook = @import("hooks.zig");
const json = @import("json.zig");
const question = @import("question.zig");
const wire = @import("wire.zig");
const dynamic = @import("dynamic.zig");
const dynamic_wire = @import("dynamic_wire.zig");

const log = std.log.scoped(.typesafe);

const Client = @This();

/// Backs every allocation the client makes, from whichever task or thread
/// calls it. Must be thread-safe, as `std.http.Client` requires.
gpa: Allocator,
io: Io,
/// The underlying HTTP client, exposed for tuning this client does not wrap,
/// such as `connection_pool.free_size`, before the first request.
///
/// Do not configure an HTTPS proxy: `std.http.Client` in Zig 0.16 does not
/// run TLS inside a proxy tunnel, so the API key would travel in plaintext.
/// Calls fail with `error.InvalidRequest` while `https_proxy` is set.
http: std.http.Client,
/// The API base URL, without a trailing slash.
base_url: []const u8,
/// The model asked when a call does not name one.
model: []const u8,
/// The limit for each attempt, or `null` for none.
timeout: ?Io.Duration,
retry: Retry,
max_response_bytes: usize,
extra_headers: []const std.http.Header,
hooks: hook.Hooks,
authorization: []const u8,
/// Owns `base_url`, `model`, `authorization` and `extra_headers`.
strings: std.heap.ArenaAllocator,

/// This package's version, from `build.zig.zon`.
pub const version: []const u8 = build_options.version;

/// Sent as `User-Agent` and `X-TypeSafe-SDK`. The format matches TypeSafe's
/// official SDKs, but the name is this package's own: it is not one of them,
/// and its traffic should not be attributed to them.
pub const sdk_identifier = "typesafe-zig/" ++ version;

/// Sent as `X-TypeSafe-Runtime`, such as `zig/0.16.0 (linux; x86_64)`.
pub const runtime_identifier = std.fmt.comptimePrint("zig/{s} ({s}; {s})", .{
    builtin.zig_version_string,
    @tagName(builtin.os.tag),
    @tagName(builtin.cpu.arch),
});

/// The API base URL used when neither the option nor `TYPESAFE_BASE_URL` sets one.
pub const default_base_url = "https://api.typesafe.ai";
/// The model used when neither the option nor `TYPESAFE_DEFAULT_MODEL` sets one.
pub const default_model = "jev-latest";
/// The per-attempt timeout of TypeSafe's official SDKs.
pub const default_timeout: Io.Duration = .fromSeconds(10);
/// The default limit on a response body: 16 MiB.
pub const default_max_response_bytes = 16 * 1024 * 1024;

/// The environment variables `initFromEnv` reads.
pub const env_api_key = "TYPESAFE_API_KEY";
/// `TYPESAFE_BASE_URL`, read by `initFromEnv`.
pub const env_base_url = "TYPESAFE_BASE_URL";
/// `TYPESAFE_DEFAULT_MODEL`, read by `initFromEnv`.
pub const env_model = "TYPESAFE_DEFAULT_MODEL";

/// Headers the client sets itself. Extra headers cannot override them.
pub const reserved_headers = [_][]const u8{
    "accept",
    "accept-encoding",
    "authorization",
    "connection",
    "content-length",
    "content-type",
    "host",
    "transfer-encoding",
    "user-agent",
    "x-typesafe-retry-count",
    "x-typesafe-runtime",
    "x-typesafe-sdk",
};

/// Options for `init` and `initFromEnv`.
pub const Options = struct {
    /// Sent as `Authorization: Bearer <key>`. Required by `init`;
    /// `initFromEnv` falls back to `TYPESAFE_API_KEY`.
    api_key: ?[]const u8 = null,
    /// Defaults to `https://api.typesafe.ai`; `initFromEnv` falls back to
    /// `TYPESAFE_BASE_URL` first.
    base_url: ?[]const u8 = null,
    /// The model for calls that do not name one. Defaults to `jev-latest`
    /// (`jev-preview` is also available); `initFromEnv` falls back to
    /// `TYPESAFE_DEFAULT_MODEL` first.
    model: ?[]const u8 = null,
    /// The limit for each attempt: connect, TLS handshake, send and receive.
    /// `null` or `Io.Duration.max` disables it. At most `max_timeout`.
    timeout: ?Io.Duration = default_timeout,
    retry: Retry = .{},
    /// The largest response body accepted. A larger one fails with
    /// `error.ResponseTooLarge`.
    max_response_bytes: usize = default_max_response_bytes,
    /// Extra request headers, such as a team or tracing header. Copied by
    /// `init`. The headers the client sets itself (`reserved_headers`) are
    /// rejected with `error.ReservedHeader`.
    extra_headers: []const std.http.Header = &.{},
    hooks: hook.Hooks = .{},
};

/// Options for one `ask` or `askDynamic` call. Unset fields use the client's
/// configuration.
pub const AskOptions = struct {
    /// The model for this call, such as `jev-preview`.
    model: ?[]const u8 = null,
    /// The limit for each attempt of this call, or `null` for the client's.
    /// `Io.Duration.max` disables it for this call. At most `max_timeout`.
    timeout: ?Io.Duration = null,
    /// The retry policy for this call, such as `.disabled`.
    retry: ?Retry = null,
    /// Headers added after the client's extra headers.
    extra_headers: []const std.http.Header = &.{},
    /// Filled with the details of a failure. See `Diagnostics`.
    diagnostics: ?*Diagnostics = null,
    /// Passed to the hooks untouched, for example a trace span.
    user_data: ?*anyopaque = null,
};

/// Options for one `listModels` call. Unset fields use the client's
/// configuration.
pub const ListModelsOptions = struct {
    /// The limit for each attempt of this call, or `null` for the client's.
    /// `Io.Duration.max` disables it for this call. At most `max_timeout`.
    timeout: ?Io.Duration = null,
    /// The retry policy for this call, or `null` for the client's.
    retry: ?Retry = null,
    /// Headers added after the client's extra headers.
    extra_headers: []const std.http.Header = &.{},
    /// Filled with the details of a failure. See `Diagnostics`.
    diagnostics: ?*Diagnostics = null,
    /// Passed to the hooks untouched.
    user_data: ?*anyopaque = null,
};

/// Builds a client from explicit options. Performs no I/O.
///
/// `gpa` must be thread-safe. `options.api_key` is required.
pub fn init(gpa: Allocator, io: Io, options: Options) InitError!Client {
    return initResolved(
        gpa,
        io,
        options,
        options.api_key orelse return error.MissingApiKey,
        options.base_url orelse default_base_url,
        options.model orelse default_model,
    );
}

/// Builds a client, resolving `api_key`, `base_url` and `model` from, in
/// order: the option, the `TYPESAFE_API_KEY`, `TYPESAFE_BASE_URL` or
/// `TYPESAFE_DEFAULT_MODEL` environment variable, then the default. Blank
/// environment values are ignored. A missing key is `error.MissingApiKey`
/// here, never at request time. Performs no I/O.
///
/// In a `pub fn main(init: std.process.Init)` program, pass
/// `init.environ_map`. The values are copied.
pub fn initFromEnv(gpa: Allocator, io: Io, environ_map: *const std.process.Environ.Map, options: Options) InitError!Client {
    return initResolved(
        gpa,
        io,
        options,
        options.api_key orelse envValue(environ_map, env_api_key) orelse return error.MissingApiKey,
        options.base_url orelse envValue(environ_map, env_base_url) orelse default_base_url,
        options.model orelse envValue(environ_map, env_model) orelse default_model,
    );
}

fn envValue(environ_map: *const std.process.Environ.Map, name: []const u8) ?[]const u8 {
    const value = std.mem.trim(u8, environ_map.get(name) orelse return null, " \t\r\n");
    return if (value.len == 0) null else value;
}

fn initResolved(
    gpa: Allocator,
    io: Io,
    options: Options,
    api_key: []const u8,
    base_url: []const u8,
    model: []const u8,
) InitError!Client {
    if (!isValidApiKey(api_key)) return error.InvalidApiKey;
    if (!isValidModel(model)) return error.InvalidModel;
    const timeout: ?Io.Duration = if (options.timeout) |t| try resolveTimeout(t) else null;
    if (!options.retry.isValid()) return error.InvalidRetry;
    if (options.max_response_bytes == 0) return error.InvalidMaxResponseBytes;
    for (options.extra_headers) |header| try validateHeader(header);

    var strings: std.heap.ArenaAllocator = .init(gpa);
    errdefer strings.deinit();
    const arena = strings.allocator();

    const normalized_base_url = try normalizeBaseUrl(arena, base_url);
    const authorization = try std.fmt.allocPrint(arena, "Bearer {s}", .{api_key});
    const model_copy = try arena.dupe(u8, model);
    const headers = try arena.alloc(std.http.Header, options.extra_headers.len);
    for (headers, options.extra_headers) |*copy, header| {
        copy.* = .{ .name = try arena.dupe(u8, header.name), .value = try arena.dupe(u8, header.value) };
    }

    return .{
        .gpa = gpa,
        .io = io,
        .http = .{ .allocator = gpa, .io = io },
        .base_url = normalized_base_url,
        .model = model_copy,
        .timeout = timeout,
        .retry = options.retry,
        .max_response_bytes = options.max_response_bytes,
        .extra_headers = headers,
        .hooks = options.hooks,
        .authorization = authorization,
        .strings = strings,
    };
}

/// Closes pooled connections and frees the client. Every call must have
/// returned.
pub fn deinit(client: *Client) void {
    client.http.deinit();
    client.strings.deinit();
    client.* = undefined;
}

/// The result of `ask`: one typed answer per question, plus the model that
/// answered and token usage. Call `deinit` to free it.
pub fn Result(comptime Questions: type) type {
    return struct {
        /// Answers with the same field names as the questions struct.
        answers: question.Answers(Questions),
        /// The concrete model that answered, such as `jev-1.13.0`, even when
        /// the call asked for an alias such as `jev-latest`.
        model: []const u8,
        usage: wire.Usage,
        /// The `x-typesafe-request-id` response header. Quote it when
        /// contacting support.
        request_id: ?[]const u8,
        /// Attempts made, including the first.
        attempts: u32,
        /// The whole decoded response body, including fields and answers
        /// this version of the client does not know.
        raw: std.json.Value,
        /// Owns every string and JSON value above.
        arena: *std.heap.ArenaAllocator,

        /// Frees the arena this result owns: `model`, `answers`, `raw`,
        /// `request_id` and every Score legend. Copy out the plain numbers and
        /// enums you need first.
        pub fn deinit(result: @This()) void {
            const gpa = result.arena.child_allocator;
            result.arena.deinit();
            gpa.destroy(result.arena);
        }
    };
}

/// The result of `listModels`. Call `deinit` to free it.
pub const Models = struct {
    models: []const wire.Model,
    request_id: ?[]const u8,
    attempts: u32,
    raw: std.json.Value,
    arena: *std.heap.ArenaAllocator,

    /// Returns the model named `name`, if the account has it.
    pub fn find(models: Models, name: []const u8) ?wire.Model {
        for (models.models) |model| {
            if (std.mem.eql(u8, model.name, name)) return model;
        }
        return null;
    }

    /// Frees the arena this result owns: `models`, `raw` and `request_id`.
    pub fn deinit(models: Models) void {
        const gpa = models.arena.child_allocator;
        models.arena.deinit();
        gpa.destroy(models.arena);
    }
};

/// Asks `questions` about `state` in one `POST /v1/systemone` request.
///
/// `state` is the content to judge: a string, or any value `std.json` can
/// write as an object or array (a struct, a slice, a `std.json.Value`, a
/// `typesafe.RawJson`), sent as JSON structure rather than stringified.
///
/// `questions` is a struct literal of questions built with
/// `typesafe.noul`, `typesafe.choice` and `typesafe.score`. Its field names
/// are the question ids; the result's `answers` has the same field names,
/// each with the question's answer type. The ids are not shown to the model.
///
/// Prefer one call carrying many questions over many calls: it is cheaper
/// and faster. For the same questions over many states, run calls
/// concurrently on one client.
///
/// Returns `error.InvalidRequest` before sending anything when the request
/// cannot be encoded, and the errors in `typesafe.Error` otherwise. Pass
/// `options.diagnostics` for the details.
pub fn ask(client: *Client, state: anytype, questions: anytype, options: AskOptions) Error!Result(@TypeOf(questions)) {
    const Questions = @TypeOf(questions);
    var call = try Call.begin(client, .{
        .operation = .ask,
        .method = .POST,
        .path = "/v1/systemone",
        .model = options.model,
        .question_count = @typeInfo(Questions).@"struct".fields.len,
        .timeout = options.timeout,
        .retry = options.retry,
        .extra_headers = options.extra_headers,
        .diagnostics = options.diagnostics,
        .user_data = options.user_data,
    });
    defer call.deinit();
    const result = askTyped(&call, state, questions);
    call.finish(if (result) |_| null else |err| err);
    return result;
}

fn askTyped(call: *Call, state: anytype, questions: anytype) Error!Result(@TypeOf(questions)) {
    const Questions = @TypeOf(questions);
    const gpa = call.client.gpa;

    var failure: json.Failure = .{};
    const body = wire.encodeAsk(gpa, state, call.model.?, questions, &failure) catch |err| {
        if (err == error.InvalidRequest) call.noteEncodeFailure(&failure);
        return err;
    };
    defer gpa.free(body);

    const response = try call.send(body);
    defer gpa.free(response.body);

    const arena = try createArena(gpa);
    errdefer destroyArena(arena);
    const root = try call.parseBody(arena.allocator(), response);

    var dec: json.Decoder = .{};
    const decoded = wire.decodeAsk(Questions, &dec, root) catch |err| {
        call.noteDecodeFailure(&dec.failure, response);
        return err;
    };
    call.input_tokens = decoded.usage.input_tokens;
    call.output_tokens = decoded.usage.output_tokens;

    return .{
        .answers = decoded.answers,
        .model = decoded.model,
        .usage = decoded.usage,
        .request_id = try call.request_id.dupe(arena.allocator()),
        .attempts = call.attempts,
        .raw = root,
        .arena = arena,
    };
}

/// Asks questions defined at run time, such as options loaded from a
/// database. See `typesafe.dynamic`.
///
/// Returns `error.InvalidRequest` before sending anything when a question is
/// invalid (no questions, a duplicate id, a Choice without options, a Score
/// with fewer than two levels); `options.diagnostics` names the offending
/// question.
pub fn askDynamic(client: *Client, state: anytype, questions: []const dynamic.Question, options: AskOptions) Error!dynamic.Result {
    var call = try Call.begin(client, .{
        .operation = .ask,
        .method = .POST,
        .path = "/v1/systemone",
        .model = options.model,
        .question_count = questions.len,
        .timeout = options.timeout,
        .retry = options.retry,
        .extra_headers = options.extra_headers,
        .diagnostics = options.diagnostics,
        .user_data = options.user_data,
    });
    defer call.deinit();
    const result = askDynamicInner(&call, state, questions);
    call.finish(if (result) |_| null else |err| err);
    return result;
}

fn askDynamicInner(call: *Call, state: anytype, questions: []const dynamic.Question) Error!dynamic.Result {
    const gpa = call.client.gpa;

    var failure: json.Failure = .{};
    const body = dynamic_wire.encodeRequest(gpa, state, call.model.?, questions, &failure) catch |err| {
        if (err == error.InvalidRequest) call.noteEncodeFailure(&failure);
        return err;
    };
    defer gpa.free(body);

    const response = try call.send(body);
    defer gpa.free(response.body);

    const arena = try createArena(gpa);
    errdefer destroyArena(arena);
    const root = try call.parseBody(arena.allocator(), response);

    var dec: json.Decoder = .{};
    const decoded = dynamic_wire.decodeResponse(arena.allocator(), &dec, questions, root) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.InvalidResponse => |e| {
            call.noteDecodeFailure(&dec.failure, response);
            return e;
        },
    };
    call.input_tokens = decoded.usage.input_tokens;
    call.output_tokens = decoded.usage.output_tokens;

    return .{
        .answers = decoded.answers,
        .model = decoded.model,
        .usage = decoded.usage,
        .request_id = try call.request_id.dupe(arena.allocator()),
        .attempts = call.attempts,
        .raw = root,
        .arena = arena,
    };
}

/// Lists the models and aliases available to your account
/// (`GET /v1/models`).
pub fn listModels(client: *Client, options: ListModelsOptions) Error!Models {
    var call = try Call.begin(client, .{
        .operation = .list_models,
        .method = .GET,
        .path = "/v1/models",
        .model = null,
        .question_count = 0,
        .timeout = options.timeout,
        .retry = options.retry,
        .extra_headers = options.extra_headers,
        .diagnostics = options.diagnostics,
        .user_data = options.user_data,
    });
    defer call.deinit();
    const result = listModelsInner(&call);
    call.finish(if (result) |_| null else |err| err);
    return result;
}

fn listModelsInner(call: *Call) Error!Models {
    const gpa = call.client.gpa;
    const response = try call.send(null);
    defer gpa.free(response.body);

    const arena = try createArena(gpa);
    errdefer destroyArena(arena);
    const root = try call.parseBody(arena.allocator(), response);

    var dec: json.Decoder = .{};
    const models = wire.decodeModels(arena.allocator(), &dec, root) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.InvalidResponse => |e| {
            call.noteDecodeFailure(&dec.failure, response);
            return e;
        },
    };
    return .{
        .models = models,
        .request_id = try call.request_id.dupe(arena.allocator()),
        .attempts = call.attempts,
        .raw = root,
        .arena = arena,
    };
}

fn createArena(gpa: Allocator) Allocator.Error!*std.heap.ArenaAllocator {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = .init(gpa);
    return arena;
}

fn destroyArena(arena: *std.heap.ArenaAllocator) void {
    const gpa = arena.child_allocator;
    arena.deinit();
    gpa.destroy(arena);
}

/// A copy of the `x-typesafe-request-id` header that needs no allocation.
const RequestId = struct {
    buffer: [128]u8 = undefined,
    len: ?u8 = null,

    fn set(id: *RequestId, value: []const u8) void {
        const n = @min(value.len, id.buffer.len);
        @memcpy(id.buffer[0..n], value[0..n]);
        id.len = @intCast(n);
    }

    fn get(id: *const RequestId) ?[]const u8 {
        return id.buffer[0 .. id.len orelse return null];
    }

    fn dupe(id: *const RequestId, allocator: Allocator) Allocator.Error!?[]const u8 {
        return try allocator.dupe(u8, id.get() orelse return null);
    }
};

/// A 2xx response body, owned by the caller.
const Response = struct {
    status: std.http.Status,
    body: []u8,
};

/// What one attempt produced: a complete response of any status, or a
/// failure before one arrived.
const Outcome = union(enum) {
    response: struct {
        status: std.http.Status,
        body: []u8,
        request_id: RequestId,
        retry_after_ms: ?u64,
    },
    failure: struct {
        err: Error,
        cause: anyerror,
        status: ?std.http.Status = null,
        request_id: RequestId = .{},
    },

    fn deinit(outcome: Outcome, gpa: Allocator) void {
        switch (outcome) {
            .response => |response| gpa.free(response.body),
            .failure => {},
        }
    }

    fn fail(err: anyerror) Outcome {
        return .{ .failure = .{ .err = classify(err), .cause = err } };
    }
};

/// Maps the wide error sets of `std.http.Client` and `std.Io` onto `Error`.
fn classify(err: anyerror) Error {
    return switch (err) {
        error.Canceled => error.Canceled,
        error.OutOfMemory => error.OutOfMemory,
        error.ResponseTooLarge => error.ResponseTooLarge,
        error.InvalidResponse => error.InvalidResponse,
        error.Timeout => error.Timeout,
        error.TlsInitializationFailed, error.CertificateBundleLoadFailure => error.TlsFailure,
        error.HttpContentEncodingUnsupported => error.InvalidResponse,
        // A proxy was configured after the call's own check; not transient.
        error.TlsProxyUnsupported => error.InvalidRequest,
        else => if (std.mem.startsWith(u8, @errorName(err), "Tls") or
            std.mem.startsWith(u8, @errorName(err), "Certificate"))
            error.TlsFailure
        else
            error.ConnectionFailed,
    };
}

test classify {
    try std.testing.expectEqual(error.ConnectionFailed, classify(error.ConnectionRefused));
    try std.testing.expectEqual(error.ConnectionFailed, classify(error.HttpChunkTruncated));
    try std.testing.expectEqual(error.TlsFailure, classify(error.TlsInitializationFailed));
    try std.testing.expectEqual(error.TlsFailure, classify(error.TlsAlert));
    try std.testing.expectEqual(error.Timeout, classify(error.Timeout));
    try std.testing.expectEqual(error.Canceled, classify(error.Canceled));
}

/// The state of one API call across its attempts.
const Call = struct {
    client: *Client,
    operation: hook.Operation,
    method: std.http.Method,
    /// Owned.
    url: []u8,
    model: ?[]const u8,
    question_count: usize,
    timeout: ?Io.Duration,
    retry: Retry,
    /// The fixed identification headers, then client and call extra headers,
    /// then one slot for `x-typesafe-retry-count`. Owned.
    headers: []std.http.Header,
    retry_count_buffer: [16]u8 = undefined,
    diagnostics: ?*Diagnostics,
    user_data: ?*anyopaque,
    started: Io.Clock.Timestamp,

    attempts: u32 = 0,
    status: ?std.http.Status = null,
    request_id: RequestId = .{},
    input_tokens: ?u64 = null,
    output_tokens: ?u64 = null,

    const fixed_headers = [_]std.http.Header{
        .{ .name = "accept", .value = "application/json" },
        .{ .name = "x-typesafe-sdk", .value = sdk_identifier },
        .{ .name = "x-typesafe-runtime", .value = runtime_identifier },
    };

    const Spec = struct {
        operation: hook.Operation,
        method: std.http.Method,
        path: []const u8,
        model: ?[]const u8,
        question_count: usize,
        timeout: ?Io.Duration,
        retry: ?Retry,
        extra_headers: []const std.http.Header,
        diagnostics: ?*Diagnostics,
        user_data: ?*anyopaque,
    };

    /// Prepares the request, fires the start hook and validates the call
    /// options. A validation failure fires the end hook too, so every call
    /// that gets this far emits exactly one start and one end event.
    fn begin(client: *Client, spec: Spec) Error!Call {
        const gpa = client.gpa;
        const diagnostics = spec.diagnostics;
        if (diagnostics) |d| {
            d.reset();
            d.method = spec.method;
        }
        errdefer if (diagnostics) |d| {
            // Validation sets its own error; only running out of memory gets here unset.
            if (d.err == null) d.err = error.OutOfMemory;
        };

        const url = try std.mem.concat(gpa, u8, &.{ client.base_url, spec.path });
        errdefer gpa.free(url);
        if (diagnostics) |d| d.setString("url", url);

        const headers = try gpa.alloc(std.http.Header, fixed_headers.len + client.extra_headers.len + spec.extra_headers.len + 1);
        errdefer gpa.free(headers);
        @memcpy(headers[0..fixed_headers.len], &fixed_headers);
        @memcpy(headers[fixed_headers.len..][0..client.extra_headers.len], client.extra_headers);
        @memcpy(headers[fixed_headers.len + client.extra_headers.len ..][0..spec.extra_headers.len], spec.extra_headers);

        var call: Call = .{
            .client = client,
            .operation = spec.operation,
            .method = spec.method,
            .url = url,
            .model = switch (spec.operation) {
                .ask => spec.model orelse client.model,
                .list_models => null,
            },
            .question_count = spec.question_count,
            .timeout = client.timeout,
            .retry = spec.retry orelse client.retry,
            .headers = headers,
            .diagnostics = diagnostics,
            .user_data = spec.user_data,
            .started = .now(client.io, .awake),
        };

        if (client.hooks.onRequestStart) |onRequestStart| {
            onRequestStart(client.hooks.context, &.{
                .operation = call.operation,
                .method = call.method,
                .url = call.url,
                .model = call.model,
                .question_count = call.question_count,
                .user_data = call.user_data,
            });
        }

        call.validate(spec) catch |err| {
            call.finish(err);
            return err;
        };
        return call;
    }

    fn validate(call: *Call, spec: Spec) error{InvalidRequest}!void {
        const client = call.client;
        const diagnostics = call.diagnostics;
        if (spec.model) |model| {
            if (!isValidModel(model)) return invalidOption(diagnostics, "model", "model must be a non-empty UTF-8 string");
        }
        if (spec.timeout) |timeout| {
            call.timeout = resolveTimeout(timeout) catch {
                return invalidOption(diagnostics, "timeout", "timeout must be positive and at most one year");
            };
        }
        if (spec.retry) |retry| {
            if (!retry.isValid()) return invalidOption(diagnostics, "retry", "retry jitter must be between 0 and 1");
        }
        for (spec.extra_headers) |header| {
            validateHeader(header) catch |err| {
                if (diagnostics) |d| {
                    d.setString("path", "extra_headers");
                    d.setPrint("message", "{s} header \"{s}\"", .{
                        if (err == error.ReservedHeader) "cannot override reserved" else "invalid",
                        header.name,
                    });
                }
                return error.InvalidRequest;
            };
        }
        // std.http.Client in Zig 0.16 does not run TLS inside a proxy tunnel:
        // an HTTPS request through a proxy would send the API key in plaintext.
        if (!std.http.Client.disable_tls and std.mem.startsWith(u8, client.base_url, "https:") and
            client.http.https_proxy != null)
        {
            return invalidOption(diagnostics, "base_url", "HTTPS requests through a proxy are not supported: " ++
                "std.http.Client would not encrypt the proxied connection");
        }
    }

    fn deinit(call: *Call) void {
        const gpa = call.client.gpa;
        gpa.free(call.headers);
        gpa.free(call.url);
    }

    /// Records the final outcome in the diagnostics and fires the end hook.
    fn finish(call: *Call, err: ?Error) void {
        if (call.diagnostics) |d| {
            if (err == null) {
                // Details of an attempt that failed before a retry succeeded
                // do not describe the call.
                d.error_type = null;
                d.message = null;
                d.body = null;
                d.path = null;
                d.retry_after_ms = null;
                d.cause = null;
                d.status = call.status;
                d.request_id = if (call.request_id.get()) |id| d.arena.allocator().dupe(u8, id) catch null else null;
            }
            d.err = err;
            d.attempts = call.attempts;
        }
        const client = call.client;
        if (client.hooks.onRequestEnd) |onRequestEnd| {
            onRequestEnd(client.hooks.context, &.{
                .operation = call.operation,
                .method = call.method,
                .url = call.url,
                .model = call.model,
                .question_count = call.question_count,
                .err = err,
                .status = call.status,
                .request_id = call.request_id.get(),
                .attempts = call.attempts,
                .duration = call.started.untilNow(client.io).raw,
                .input_tokens = call.input_tokens,
                .output_tokens = call.output_tokens,
                .user_data = call.user_data,
            });
        }
    }

    fn elapsedMs(call: *const Call) u64 {
        const ms = call.started.untilNow(call.client.io).raw.toMilliseconds();
        return @intCast(@max(ms, 0));
    }

    /// Sends the request with retries and returns a 2xx response. Every
    /// other outcome becomes an error, with the diagnostics describing the
    /// final attempt.
    fn send(call: *Call, body: ?[]u8) Error!Response {
        const gpa = call.client.gpa;
        var retries: u32 = 0;
        while (true) : (retries += 1) {
            const outcome = call.attempt(body, retries);
            call.attempts += 1;
            switch (outcome) {
                .response => |response| {
                    call.status = response.status;
                    call.request_id = response.request_id;
                    const err = errors.fromStatus(response.status) orelse {
                        return .{ .status = response.status, .body = response.body };
                    };
                    call.noteHttpError(response.status, response.body, response.retry_after_ms);
                    gpa.free(response.body);
                    if (!try call.shouldRetry(err, response.status, response.retry_after_ms, retries)) return err;
                },
                .failure => |failure| {
                    call.status = failure.status;
                    call.request_id = failure.request_id;
                    call.noteFailure(failure.err, failure.cause, failure.status);
                    if (!try call.shouldRetry(failure.err, failure.status, null, retries)) return failure.err;
                },
            }
        }
    }

    /// Decides whether to retry after a failed attempt and, if so, fires the
    /// retry hook and sleeps for the delay.
    fn shouldRetry(call: *Call, err: Error, status: ?std.http.Status, retry_after_ms: ?u64, retries: u32) Error!bool {
        const policy = call.retry;
        if (retries >= policy.max_retries) return false;
        // An HTTP error status goes through the policy's status predicate;
        // transport and body failures through the error classification. A
        // response whose body was too large to read also carries a status, and
        // that status decides whether retrying is worthwhile: a 429 or 502
        // with an oversized error page is retried, a 2xx one is not.
        const status_error = if (status) |s| errors.fromStatus(s) else null;
        const status_governs = status_error != null and (status_error.? == err or err == error.ResponseTooLarge);
        const retryable = if (status_governs)
            policy.retriesStatus(status.?)
        else
            policy.isRetryable(err);
        if (!retryable) return false;

        const client = call.client;
        const io = client.io;
        const random: std.Random.IoSource = .{ .io = io };
        const delay_ms = policy.nextDelayMs(retries, retry_after_ms, random.interface());
        if (policy.budget_ms) |budget_ms| {
            const elapsed_ms = call.elapsedMs();
            if (elapsed_ms +| delay_ms >= budget_ms) {
                log.debug("{s} {s}: not retrying {t}: {d} ms elapsed plus a {d} ms delay reaches the {d} ms budget", .{
                    @tagName(call.method), call.url, err, elapsed_ms, delay_ms, budget_ms,
                });
                return false;
            }
        }

        const delay: Io.Duration = .fromMilliseconds(@intCast(@min(delay_ms, std.math.maxInt(i64))));
        log.debug("{s} {s}: attempt {d} failed with {t}; retrying in {d} ms", .{
            @tagName(call.method), call.url, call.attempts, err, delay_ms,
        });
        if (client.hooks.onRetry) |onRetry| {
            onRetry(client.hooks.context, &.{
                .operation = call.operation,
                .method = call.method,
                .url = call.url,
                .attempt = call.attempts,
                .err = err,
                .status = status,
                .delay = delay,
                .user_data = call.user_data,
            });
        }
        try io.sleep(delay, .awake);
        return true;
    }

    /// Runs one attempt, racing it against the timeout when there is one.
    fn attempt(call: *Call, body: ?[]u8, retries: u32) Outcome {
        const io = call.client.io;
        const last = call.headers.len - 1;
        if (retries > 0) {
            call.headers[last] = .{
                .name = "x-typesafe-retry-count",
                .value = std.fmt.bufPrint(&call.retry_count_buffer, "{d}", .{retries}) catch unreachable,
            };
        }
        const headers = if (retries > 0) call.headers else call.headers[0..last];

        const timeout = call.timeout orelse return perform(call, body, headers);

        const Race = union(enum) {
            attempt: Outcome,
            timeout: Io.Cancelable!void,
        };
        var buffer: [2]Race = undefined;
        var select: Io.Select(Race) = .init(io, &buffer);
        select.concurrent(.attempt, perform, .{ call, body, headers }) catch |err| switch (err) {
            error.ConcurrencyUnavailable => {
                log.warn("{s} {s}: the Io cannot run a task concurrently; sending without the timeout", .{
                    @tagName(call.method), call.url,
                });
                return perform(call, body, headers);
            },
        };
        const deadline: Io.Timeout = .{ .duration = .{ .raw = timeout, .clock = .awake } };
        select.concurrent(.timeout, Io.Timeout.sleep, .{ deadline, io }) catch |err| switch (err) {
            error.ConcurrencyUnavailable => {
                log.warn("{s} {s}: the Io cannot run a timer concurrently; waiting without the timeout", .{
                    @tagName(call.method), call.url,
                });
            },
        };

        const first = select.await() catch |err| switch (err) {
            error.Canceled => {
                cancelRace(Race, &select, call.client.gpa);
                return .fail(error.Canceled);
            },
        };
        cancelRace(Race, &select, call.client.gpa);
        return switch (first) {
            .attempt => |outcome| outcome,
            .timeout => |slept| if (slept) |_| .{ .failure = .{ .err = error.Timeout, .cause = error.Timeout } } else |err| .fail(err),
        };
    }

    fn cancelRace(comptime Race: type, select: *Io.Select(Race), gpa: Allocator) void {
        while (select.cancel()) |leftover| switch (leftover) {
            // A response that completed while the timer won is discarded.
            .attempt => |outcome| outcome.deinit(gpa),
            .timeout => {},
        };
    }

    fn perform(call: *const Call, body: ?[]u8, headers: []const std.http.Header) Outcome {
        const pool_size = call.client.http.connection_pool.free_size;
        var stale: usize = 0;
        while (true) {
            return performOrFail(call, body, headers) catch |err| {
                // A pooled keep-alive connection the server has since closed
                // fails before any response arrives. That is not a failed
                // attempt: try again at once, on another pooled connection or
                // a new one. Every request is safe to repeat.
                if (err == error.StaleConnection and stale <= pool_size) {
                    stale += 1;
                    continue;
                }
                return .fail(if (err == error.StaleConnection) error.ConnectionResetByPeer else err);
            };
        }
    }

    fn performOrFail(call: *const Call, body: ?[]u8, headers: []const std.http.Header) anyerror!Outcome {
        const client = call.client;
        const gpa = client.gpa;
        const uri = try std.Uri.parse(call.url);
        const https = std.mem.eql(u8, uri.scheme, "https");
        if (https) try refreshTrust(client);

        const pooled = findPooledConnection(client, uri);
        var request = client.http.request(call.method, uri, .{
            // Redirects are returned, never followed, so the key stays on the base URL's host.
            .redirect_behavior = .unhandled,
            .headers = .{
                .authorization = .{ .override = client.authorization },
                .user_agent = .{ .override = sdk_identifier },
                .content_type = if (body != null) .{ .override = "application/json" } else .omit,
            },
            .extra_headers = headers,
            .connection = pooled,
        }) catch |err| {
            // The pooled connection was taken out of the pool but never used.
            if (pooled) |connection| client.http.connection_pool.release(connection, client.io);
            return err;
        };
        defer request.deinit();
        const connection = request.connection.?;

        // Only a request whose response was read to the end leaves its
        // connection reusable. Anything else (a timeout or cancel mid-write, a
        // write error, an oversized or truncated body) closes it, so a later
        // request never lands in the middle of an unfinished one. Declared
        // after `request.deinit`, so it runs first.
        var complete = false;
        defer if (!complete) {
            connection.closing = true;
        };

        if (https and (connection.protocol != .tls or connection.proxied)) {
            return error.TlsProxyUnsupported;
        }

        // `sendBodyComplete` and `sendBodiless` flush both the TLS layer and
        // the socket. Ending a streamed body flushes only the TLS layer, which
        // leaves the request unsent and `receiveHead` waiting forever.
        if (body) |bytes| {
            request.sendBodyComplete(bytes) catch |err| return staleOr(pooled != null, writeError(connection, err));
        } else {
            request.sendBodiless() catch |err| return staleOr(pooled != null, writeError(connection, err));
        }

        var response = request.receiveHead(&.{}) catch |err| return staleOr(pooled != null, switch (err) {
            error.ReadFailed => readError(connection),
            error.WriteFailed => writeError(connection, err),
            else => |e| e,
        });
        const head = response.head;

        // Header strings are invalidated once the body is read.
        var request_id: RequestId = .{};
        var retry_after_ms_text: ?[]const u8 = null;
        var retry_after_text: ?[]const u8 = null;
        var it = head.iterateHeaders();
        while (it.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "x-typesafe-request-id")) {
                request_id.set(header.value);
            } else if (std.ascii.eqlIgnoreCase(header.name, "retry-after-ms")) {
                retry_after_ms_text = header.value;
            } else if (std.ascii.eqlIgnoreCase(header.name, "retry-after")) {
                retry_after_text = header.value;
            }
        }
        const now_ms: i64 = @intCast(Io.Clock.real.now(client.io).toMilliseconds());
        const retry_after_ms = Retry.parseRetryAfter(retry_after_ms_text, retry_after_text, now_ms);
        const status = head.status;
        const content_encoding = head.content_encoding;

        const too_large: Outcome = .{ .failure = .{
            .err = error.ResponseTooLarge,
            .cause = error.ResponseTooLarge,
            .status = status,
            .request_id = request_id,
        } };
        // An oversized body is not drained: the deferred `closing` drops the connection.
        if (head.content_length) |length| {
            if (length > client.max_response_bytes) return too_large;
        }

        var transfer_buffer: [64]u8 = undefined;
        const reader = response.reader(&transfer_buffer);
        // One byte over the limit tells a body of exactly the limit from a larger one.
        const raw = reader.allocRemaining(gpa, .limited(client.max_response_bytes +| 1)) catch |err| switch (err) {
            error.StreamTooLong => return too_large,
            error.OutOfMemory => |e| return e,
            error.ReadFailed => return response.bodyErr() orelse readError(connection),
        };
        // A connection closed partway through a body reads as a short body;
        // the reader still expecting more tells them apart.
        const truncated = switch (request.reader.state) {
            .body_remaining_content_length, .body_remaining_chunk_len => true,
            else => false,
        };
        if (truncated) {
            gpa.free(raw);
            return .{ .failure = .{
                .err = error.ConnectionFailed,
                .cause = error.ResponseTruncated,
                .status = status,
                .request_id = request_id,
            } };
        }
        complete = true;

        const decoded = decompress(gpa, raw, content_encoding, client.max_response_bytes) catch |err| {
            gpa.free(raw);
            return .{ .failure = .{
                .err = if (err == error.StreamTooLong) error.ResponseTooLarge else classify(err),
                .cause = err,
                .status = status,
                .request_id = request_id,
            } };
        };
        return .{ .response = .{
            .status = status,
            .body = decoded,
            .request_id = request_id,
            .retry_after_ms = retry_after_ms,
        } };
    }

    fn readError(connection: *std.http.Client.Connection) anyerror {
        return connection.getReadError() orelse error.ReadFailed;
    }

    /// Returns `error.StaleConnection` for a failure on a reused connection
    /// that means the peer had closed it before this request, and `err`
    /// otherwise.
    fn staleOr(reused: bool, err: anyerror) anyerror {
        if (!reused) return err;
        return switch (err) {
            error.HttpConnectionClosing,
            error.EndOfStream,
            error.ConnectionResetByPeer,
            error.BrokenPipe,
            error.SocketUnconnected,
            error.NotOpenForReading,
            => error.StaleConnection,
            else => err,
        };
    }

    /// Takes an idle pooled connection for `uri`, if there is one, so the
    /// caller knows the request runs on a reused connection. Returns `null`
    /// when a proxy is configured, leaving the choice to `std.http.Client`.
    fn findPooledConnection(client: *Client, uri: std.Uri) ?*std.http.Client.Connection {
        const protocol = std.http.Client.Protocol.fromUri(uri) orelse return null;
        const proxy = switch (protocol) {
            .plain => client.http.http_proxy,
            .tls => client.http.https_proxy,
        };
        if (proxy != null) return null;
        var host_buffer: [Io.net.HostName.max_len]u8 = undefined;
        const host = uri.getHost(&host_buffer) catch return null;
        return client.http.connection_pool.findConnection(client.io, .{
            .host = host,
            .port = uri.port orelse switch (protocol) {
                .plain => 80,
                .tls => 443,
            },
            .protocol = protocol,
        });
    }

    /// `std.http.Client` reads the clock and the system's root certificates
    /// once, at its first HTTPS request, and checks every later certificate
    /// against that time. A long-running client would then reject
    /// certificates issued after it started and accept ones that have since
    /// expired, so the time and roots are refreshed hourly.
    fn refreshTrust(client: *Client) Io.Cancelable!void {
        if (std.http.Client.disable_tls) return;
        const http = &client.http;
        const io = client.io;
        const now = Io.Clock.real.now(io);
        {
            try http.ca_bundle_lock.lockShared(io);
            defer http.ca_bundle_lock.unlockShared(io);
            // `null` means none loaded yet: the request loads them itself.
            const loaded = http.now orelse return;
            if (loaded.durationTo(now).nanoseconds < trust_refresh_interval.nanoseconds) return;
        }

        var bundle: std.crypto.Certificate.Bundle = .empty;
        defer bundle.deinit(client.gpa);
        bundle.rescan(client.gpa, io, now) catch |err| switch (err) {
            error.Canceled => |e| return e,
            // Keep the roots already loaded; the handshake reports any problem.
            else => {
                log.warn("could not reload the system root certificates: {t}", .{err});
                return;
            },
        };
        try http.ca_bundle_lock.lock(io);
        defer http.ca_bundle_lock.unlock(io);
        if (http.now) |loaded| {
            if (loaded.durationTo(now).nanoseconds < trust_refresh_interval.nanoseconds) return;
        }
        std.mem.swap(std.crypto.Certificate.Bundle, &http.ca_bundle, &bundle);
        // Certificate verification reads the bundle under this lock, but
        // `std.http.Client` reads `now` for a new TLS connection without it.
        // A handshake starting on another task during this hourly write could
        // see a torn timestamp; std offers no lock to prevent that. `now` is
        // never set back to null, which that unlocked read would not survive.
        http.now = now;
    }

    fn writeError(connection: *std.http.Client.Connection, err: anyerror) anyerror {
        if (err != error.WriteFailed) return err;
        return connection.stream_writer.err orelse error.WriteFailed;
    }

    /// Parses a 2xx body as JSON into `arena`.
    fn parseBody(call: *Call, arena: Allocator, response: Response) Error!std.json.Value {
        return std.json.parseFromSliceLeaky(std.json.Value, arena, response.body, .{
            .allocate = .alloc_always,
            .max_value_len = response.body.len,
        }) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => {
                if (call.noteResponse(response)) |d| {
                    d.setPrint("message", "response body is not valid JSON: {t}", .{err});
                }
                return error.InvalidResponse;
            },
        };
    }

    fn noteEncodeFailure(call: *Call, failure: *const json.Failure) void {
        const d = call.diagnostics orelse return;
        d.setString("message", failure.message());
        d.setString("path", failure.path());
    }

    fn noteDecodeFailure(call: *Call, failure: *const json.Failure, response: Response) void {
        log.debug("{s} {s}: response does not match the API schema at {s}: {s}", .{
            @tagName(call.method), call.url, failure.path(), failure.message(),
        });
        const d = call.noteResponse(response) orelse return;
        d.setString("message", failure.message());
        d.setString("path", failure.path());
    }

    /// Records the status, request id and body of a 2xx response that could
    /// not be decoded.
    fn noteResponse(call: *Call, response: Response) ?*Diagnostics {
        const d = call.diagnostics orelse return null;
        // Clear what an earlier failed attempt left behind.
        d.error_type = null;
        d.message = null;
        d.path = null;
        d.retry_after_ms = null;
        d.cause = null;
        d.status = response.status;
        d.request_id = if (call.request_id.get()) |id| d.arena.allocator().dupe(u8, id) catch null else null;
        d.setBody(response.body);
        return d;
    }

    fn noteHttpError(call: *Call, status: std.http.Status, body: []const u8, retry_after_ms: ?u64) void {
        const d = call.diagnostics orelse return;
        d.status = status;
        d.request_id = if (call.request_id.get()) |id| d.arena.allocator().dupe(u8, id) catch null else null;
        d.retry_after_ms = retry_after_ms;
        d.cause = null;
        d.path = null;
        d.message = null;
        d.error_type = null;
        d.setBody(body);

        // Parse into scratch memory and keep only the strings, so a large
        // error body does not grow the diagnostics by its whole JSON tree.
        var scratch: std.heap.ArenaAllocator = .init(call.client.gpa);
        defer scratch.deinit();
        const parsed = wire.parseErrorBody(scratch.allocator(), status, body[0..@min(body.len, Diagnostics.max_body_bytes)]) catch return;
        d.setString("message", parsed.message);
        if (parsed.error_type) |error_type| d.setString("error_type", error_type);
    }

    fn noteFailure(call: *Call, err: Error, cause: anyerror, status: ?std.http.Status) void {
        const d = call.diagnostics orelse return;
        d.status = status;
        d.request_id = if (call.request_id.get()) |id| d.arena.allocator().dupe(u8, id) catch null else null;
        d.retry_after_ms = null;
        d.error_type = null;
        d.body = null;
        d.path = null;
        d.cause = cause;
        d.message = switch (err) {
            error.Timeout => if (call.timeout) |t|
                std.fmt.allocPrint(d.arena.allocator(), "no complete response within {f}", .{t}) catch null
            else
                null,
            error.ResponseTooLarge => std.fmt.allocPrint(d.arena.allocator(), "response body exceeds {d} bytes", .{
                call.client.max_response_bytes,
            }) catch null,
            else => null,
        };
    }
};

fn invalidOption(diagnostics: ?*Diagnostics, path: []const u8, message: []const u8) error{InvalidRequest} {
    if (diagnostics) |d| {
        d.err = error.InvalidRequest;
        d.setString("path", path);
        d.setString("message", message);
    }
    return error.InvalidRequest;
}

/// Decompresses a response body. `std.http.Client` offers `gzip` and
/// `deflate`; the API does not compress today, and this keeps a server that
/// starts to from breaking decoding. On success, `raw` is freed.
fn decompress(gpa: Allocator, raw: []u8, encoding: std.http.ContentEncoding, limit: usize) ![]u8 {
    switch (encoding) {
        .identity => return raw,
        .gzip, .deflate => {
            const buffer = try gpa.alloc(u8, std.compress.flate.max_window_len);
            defer gpa.free(buffer);
            var input: Io.Reader = .fixed(raw);
            var state: std.http.Decompress = undefined;
            const reader = std.http.Decompress.init(&state, &input, buffer, encoding);
            // One byte over the limit tells a body of exactly the limit from a larger one.
            const out = reader.allocRemaining(gpa, .limited(limit +| 1)) catch |err| switch (err) {
                error.ReadFailed => return error.InvalidResponse,
                else => |e| return e,
            };
            gpa.free(raw);
            return out;
        },
        // Never offered, so `receiveHead` rejects them first.
        .zstd, .compress => return error.InvalidResponse,
    }
}

/// The longest timeout accepted. `Io.Duration.max` means no timeout.
pub const max_timeout: Io.Duration = .fromSeconds(365 * std.time.s_per_day);

/// How often a long-running client reloads the clock and root certificates
/// it checks TLS certificates against.
const trust_refresh_interval: Io.Duration = .fromSeconds(std.time.s_per_hour);

fn resolveTimeout(timeout: Io.Duration) error{InvalidTimeout}!?Io.Duration {
    if (timeout.nanoseconds == Io.Duration.max.nanoseconds) return null;
    if (timeout.nanoseconds <= 0 or timeout.nanoseconds > max_timeout.nanoseconds) return error.InvalidTimeout;
    return timeout;
}

fn isValidApiKey(key: []const u8) bool {
    if (key.len == 0) return false;
    for (key) |c| if (c < 0x21 or c > 0x7e) return false;
    return true;
}

fn isValidModel(model: []const u8) bool {
    return model.len > 0 and std.unicode.utf8ValidateSlice(model);
}

fn validateHeader(header: std.http.Header) error{ InvalidHeader, ReservedHeader }!void {
    if (header.name.len == 0) return error.InvalidHeader;
    for (header.name) |c| {
        const token = std.ascii.isAlphanumeric(c) or std.mem.findScalar(u8, "!#$%&'*+-.^_`|~", c) != null;
        if (!token) return error.InvalidHeader;
    }
    for (header.value) |c| {
        if (c == '\r' or c == '\n' or c == 0 or (c < 0x20 and c != '\t') or c == 0x7f) return error.InvalidHeader;
    }
    for (reserved_headers) |reserved| {
        if (std.ascii.eqlIgnoreCase(header.name, reserved)) return error.ReservedHeader;
    }
}

/// Checks that `std.http.Client` can connect to the base URL and returns it
/// without a trailing slash and with a lowercase scheme.
fn normalizeBaseUrl(arena: Allocator, raw: []const u8) (error{InvalidBaseUrl} || Allocator.Error)![]const u8 {
    const trimmed = std.mem.trimEnd(u8, raw, "/");
    for (trimmed) |c| if (c <= 0x20 or c >= 0x7f) return error.InvalidBaseUrl;
    const uri = std.Uri.parse(trimmed) catch return error.InvalidBaseUrl;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) {
        return error.InvalidBaseUrl;
    }
    if (uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) {
        return error.InvalidBaseUrl;
    }
    const host_component = uri.host orelse return error.InvalidBaseUrl;
    var host_buffer: [Io.net.HostName.max_len]u8 = undefined;
    const host = host_component.toRaw(&host_buffer) catch return error.InvalidBaseUrl;
    // std.http.Client 0.16 resolves `[::1]` as a host name, so IPv6 literals cannot connect.
    if (host.len == 0 or host.len > Io.net.HostName.max_len or host[0] == '[') return error.InvalidBaseUrl;

    const normalized = try arena.dupe(u8, trimmed);
    _ = std.ascii.lowerString(normalized[0..uri.scheme.len], uri.scheme);
    return normalized;
}

test "init validates and normalizes options" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var client: Client = try .init(gpa, io, .{ .api_key = "ts_test", .base_url = "https://example.com/api/" });
    defer client.deinit();
    try std.testing.expectEqualStrings("https://example.com/api", client.base_url);
    try std.testing.expectEqualStrings("jev-latest", client.model);
    try std.testing.expectEqualStrings("Bearer ts_test", client.authorization);

    try std.testing.expectError(error.MissingApiKey, Client.init(gpa, io, .{}));
    try std.testing.expectError(error.InvalidApiKey, Client.init(gpa, io, .{ .api_key = "has space" }));
    try std.testing.expectError(error.InvalidApiKey, Client.init(gpa, io, .{ .api_key = "line\r\nbreak" }));
    try std.testing.expectError(error.InvalidBaseUrl, Client.init(gpa, io, .{ .api_key = "k", .base_url = "api.typesafe.ai" }));
    try std.testing.expectError(error.InvalidBaseUrl, Client.init(gpa, io, .{ .api_key = "k", .base_url = "ftp://api.typesafe.ai" }));
    try std.testing.expectError(error.InvalidBaseUrl, Client.init(gpa, io, .{ .api_key = "k", .base_url = "https://user:pw@api.typesafe.ai" }));
    try std.testing.expectError(error.InvalidBaseUrl, Client.init(gpa, io, .{ .api_key = "k", .base_url = "https://api.typesafe.ai?x=1" }));
    try std.testing.expectError(error.InvalidModel, Client.init(gpa, io, .{ .api_key = "k", .model = "" }));
    try std.testing.expectError(error.InvalidTimeout, Client.init(gpa, io, .{ .api_key = "k", .timeout = .zero }));
    try std.testing.expectError(error.InvalidRetry, Client.init(gpa, io, .{ .api_key = "k", .retry = .{ .jitter = 2 } }));
    try std.testing.expectError(error.InvalidMaxResponseBytes, Client.init(gpa, io, .{ .api_key = "k", .max_response_bytes = 0 }));
    try std.testing.expectError(error.ReservedHeader, Client.init(gpa, io, .{
        .api_key = "k",
        .extra_headers = &.{.{ .name = "Authorization", .value = "Bearer other" }},
    }));
    try std.testing.expectError(error.InvalidHeader, Client.init(gpa, io, .{
        .api_key = "k",
        .extra_headers = &.{.{ .name = "x-team", .value = "a\r\nb" }},
    }));
    try std.testing.expectError(error.InvalidHeader, Client.init(gpa, io, .{
        .api_key = "k",
        .extra_headers = &.{.{ .name = "bad name", .value = "v" }},
    }));
}

test "initFromEnv resolves options, then environment, then defaults" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var environ_map: std.process.Environ.Map = .init(gpa);
    defer environ_map.deinit();

    try std.testing.expectError(error.MissingApiKey, Client.initFromEnv(gpa, io, &environ_map, .{}));

    try environ_map.put(env_api_key, " ts_env \n");
    try environ_map.put(env_base_url, "   ");
    try environ_map.put(env_model, "jev-preview");
    {
        var client: Client = try .initFromEnv(gpa, io, &environ_map, .{});
        defer client.deinit();
        try std.testing.expectEqualStrings("Bearer ts_env", client.authorization);
        try std.testing.expectEqualStrings(default_base_url, client.base_url);
        try std.testing.expectEqualStrings("jev-preview", client.model);
    }
    {
        var client: Client = try .initFromEnv(gpa, io, &environ_map, .{ .api_key = "ts_explicit", .model = "jev-latest" });
        defer client.deinit();
        try std.testing.expectEqualStrings("Bearer ts_explicit", client.authorization);
        try std.testing.expectEqualStrings("jev-latest", client.model);
    }
}

test "identification strings" {
    try std.testing.expect(std.mem.startsWith(u8, sdk_identifier, "typesafe-zig/"));
    try std.testing.expect(std.mem.startsWith(u8, runtime_identifier, "zig/"));
}

test "the TLS trust refresh only runs when the loaded time is stale" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var client: Client = try .init(gpa, io, .{ .api_key = "k" });
    defer client.deinit();
    const now = Io.Clock.real.now(io);

    // Nothing loaded yet: the first HTTPS request loads the clock and roots.
    try Call.refreshTrust(&client);
    try std.testing.expectEqual(null, client.http.now);

    // Loaded a minute ago: the fast path leaves the clock alone.
    client.http.now = now.subDuration(.fromSeconds(60));
    const recent = client.http.now.?;
    try Call.refreshTrust(&client);
    try std.testing.expectEqual(recent.nanoseconds, client.http.now.?.nanoseconds);

    // Loaded two hours ago: the roots are rescanned and the clock moves
    // forward. On a machine whose system roots cannot be read the refresh
    // keeps what it had, so this only requires that the clock stays set and
    // never moves backwards.
    const stale = now.subDuration(.fromSeconds(2 * std.time.s_per_hour));
    client.http.now = stale;
    try Call.refreshTrust(&client);
    try std.testing.expect(client.http.now.?.nanoseconds >= stale.nanoseconds);
}
