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
const request = @import("request.zig");
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
/// Calls fail with `error.InvalidOption` while `https_proxy` is set.
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
    if (!request.isValidApiKey(api_key)) return error.InvalidApiKey;
    if (!request.isValidModel(model)) return error.InvalidModel;
    const timeout: ?Io.Duration = if (options.timeout) |t| try request.resolveTimeout(t) else null;
    if (!options.retry.isValid()) return error.InvalidRetry;
    if (options.max_response_bytes == 0) return error.InvalidMaxResponseBytes;
    for (options.extra_headers) |header| try request.validateHeader(header);

    var strings: std.heap.ArenaAllocator = .init(gpa);
    errdefer strings.deinit();
    const arena = strings.allocator();

    const normalized_base_url = try request.normalizeBaseUrl(arena, base_url);
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
/// answered and token usage. request.Call `deinit` to free it.
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
        /// The response body exactly as the server sent it, for fields this
        /// version of the client does not know. It lives in the result's
        /// arena, like everything else the result owns.
        body: []const u8,
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

/// The result of `listModels`. request.Call `deinit` to free it.
pub const Models = struct {
    models: []const wire.Model,
    request_id: ?[]const u8,
    attempts: u32,
    /// The response body exactly as the server sent it. It lives in the
    /// result's arena.
    body: []const u8,
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
    var call = try request.Call.begin(client, .{
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

fn askTyped(call: *request.Call, state: anytype, questions: anytype) Error!Result(@TypeOf(questions)) {
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
    // The decoded strings point into this copy of the body, so it is made
    // before anything is read from it and freed with the arena.
    const response_body = try arena.allocator().dupe(u8, response.body);
    var reader: json.Reader = .init(arena.allocator(), response_body);
    defer reader.deinit();

    const decoded = wire.decodeAsk(Questions, &reader) catch |err| return call.decodeFailure(err, &reader, response);
    reader.endDocument() catch |err| return call.decodeFailure(err, &reader, response);
    call.input_tokens = decoded.usage.input_tokens;
    call.output_tokens = decoded.usage.output_tokens;

    return .{
        .answers = decoded.answers,
        .model = decoded.model,
        .usage = decoded.usage,
        .request_id = try call.request_id.dupe(arena.allocator()),
        .attempts = call.attempts,
        .body = response_body,
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
    var call = try request.Call.begin(client, .{
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

fn askDynamicInner(call: *request.Call, state: anytype, questions: []const dynamic.Question) Error!dynamic.Result {
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
    const response_body = try arena.allocator().dupe(u8, response.body);
    var reader: json.Reader = .init(arena.allocator(), response_body);
    defer reader.deinit();

    const decoded = dynamic_wire.decodeResponse(arena.allocator(), &reader, questions) catch |err|
        return call.decodeFailure(err, &reader, response);
    reader.endDocument() catch |err| return call.decodeFailure(err, &reader, response);
    call.input_tokens = decoded.usage.input_tokens;
    call.output_tokens = decoded.usage.output_tokens;

    return .{
        .answers = decoded.answers,
        .model = decoded.model,
        .usage = decoded.usage,
        .request_id = try call.request_id.dupe(arena.allocator()),
        .attempts = call.attempts,
        .body = response_body,
        .arena = arena,
    };
}

/// Lists the models and aliases available to your account
/// (`GET /v1/models`).
pub fn listModels(client: *Client, options: ListModelsOptions) Error!Models {
    var call = try request.Call.begin(client, .{
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

fn listModelsInner(call: *request.Call) Error!Models {
    const gpa = call.client.gpa;
    const response = try call.send(null);
    defer gpa.free(response.body);

    const arena = try createArena(gpa);
    errdefer destroyArena(arena);
    const response_body = try arena.allocator().dupe(u8, response.body);
    var reader: json.Reader = .init(arena.allocator(), response_body);
    defer reader.deinit();

    const models = wire.decodeModels(arena.allocator(), &reader) catch |err|
        return call.decodeFailure(err, &reader, response);
    reader.endDocument() catch |err| return call.decodeFailure(err, &reader, response);
    return .{
        .models = models,
        .request_id = try call.request_id.dupe(arena.allocator()),
        .attempts = call.attempts,
        .body = response_body,
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

/// The longest timeout accepted. `Io.Duration.max` means no timeout.
pub const max_timeout: Io.Duration = .fromSeconds(365 * std.time.s_per_day);

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
    if (!request.tls_trust_refresh) return; // the build turned it off
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var client: Client = try .init(gpa, io, .{ .api_key = "k" });
    defer client.deinit();
    const now = Io.Clock.real.now(io);

    // Nothing loaded yet: the first HTTPS request loads the clock and roots.
    try request.Call.refreshTrust(&client);
    try std.testing.expectEqual(null, client.http.now);

    // Loaded a minute ago: the fast path leaves the clock alone.
    client.http.now = now.subDuration(.fromSeconds(60));
    const recent = client.http.now.?;
    try request.Call.refreshTrust(&client);
    try std.testing.expectEqual(recent.nanoseconds, client.http.now.?.nanoseconds);

    // Loaded two hours ago: the roots are rescanned and the clock moves
    // forward. On a machine whose system roots cannot be read the refresh
    // keeps what it had, so this only requires that the clock stays set and
    // never moves backwards.
    const stale = now.subDuration(.fromSeconds(2 * std.time.s_per_hour));
    client.http.now = stale;
    try request.Call.refreshTrust(&client);
    try std.testing.expect(client.http.now.?.nanoseconds >= stale.nanoseconds);
}
