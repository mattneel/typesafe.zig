//! The request side of a call: one `Call` per `Client.ask`, `askDynamic` or
//! `listModels`, the retry loop, the timeout race, and the validation that
//! runs before anything is sent.
//!
//! Split out of `Client.zig` so the client's configuration and its result
//! types read on their own.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Client = @import("Client.zig");
const errors = @import("errors.zig");
const Error = errors.Error;
const Retry = @import("Retry.zig");
const Diagnostics = @import("Diagnostics.zig");
const hook = @import("hooks.zig");
const json = @import("json.zig");
const wire = @import("wire.zig");

const log = std.log.scoped(.typesafe);

/// A copy of the `x-typesafe-request-id` header that needs no allocation.
pub const RequestId = struct {
    buffer: [128]u8 = undefined,
    len: ?u8 = null,

    pub fn set(id: *RequestId, value: []const u8) void {
        const n = @min(value.len, id.buffer.len);
        @memcpy(id.buffer[0..n], value[0..n]);
        id.len = @intCast(n);
    }

    pub fn get(id: *const RequestId) ?[]const u8 {
        return id.buffer[0 .. id.len orelse return null];
    }

    pub fn dupe(id: *const RequestId, allocator: Allocator) Allocator.Error!?[]const u8 {
        return try allocator.dupe(u8, id.get() orelse return null);
    }
};

/// A 2xx response body, owned by the caller.
pub const Response = struct {
    status: std.http.Status,
    body: []u8,
};

/// What one attempt produced: a complete response of any status, or a
/// failure before one arrived.
pub const Outcome = union(enum) {
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

    pub fn deinit(outcome: Outcome, gpa: Allocator) void {
        switch (outcome) {
            .response => |response| gpa.free(response.body),
            .failure => {},
        }
    }

    pub fn fail(err: anyerror) Outcome {
        return .{ .failure = .{ .err = classify(err), .cause = err } };
    }
};

/// Maps the wide error sets of `std.http.Client` and `std.Io` onto `Error`.
pub fn classify(err: anyerror) Error {
    return switch (err) {
        error.Canceled => error.Canceled,
        error.OutOfMemory => error.OutOfMemory,
        error.ResponseTooLarge => error.ResponseTooLarge,
        error.InvalidResponse => error.InvalidResponse,
        error.Timeout => error.Timeout,
        error.TlsInitializationFailed, error.CertificateBundleLoadFailure => error.TlsFailure,
        error.HttpContentEncodingUnsupported => error.InvalidResponse,
        // A proxy was configured after the call's own check; not transient.
        error.TlsProxyUnsupported => error.InvalidOption,
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
pub const Call = struct {
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
        .{ .name = "x-typesafe-sdk", .value = Client.sdk_identifier },
        .{ .name = "x-typesafe-runtime", .value = Client.runtime_identifier },
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
    pub fn begin(client: *Client, spec: Spec) Error!Call {
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

    pub fn validate(call: *Call, spec: Spec) error{InvalidOption}!void {
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
                return error.InvalidOption;
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

    pub fn deinit(call: *Call) void {
        const gpa = call.client.gpa;
        gpa.free(call.headers);
        gpa.free(call.url);
    }

    /// Records the final outcome in the diagnostics and fires the end hook.
    pub fn finish(call: *Call, err: ?Error) void {
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

    pub fn elapsedMs(call: *const Call) u64 {
        const ms = call.started.untilNow(call.client.io).raw.toMilliseconds();
        return @intCast(@max(ms, 0));
    }

    /// Sends the request with retries and returns a 2xx response. Every
    /// other outcome becomes an error, with the diagnostics describing the
    /// final attempt.
    pub fn send(call: *Call, body: ?[]u8) Error!Response {
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
    pub fn shouldRetry(call: *Call, err: Error, status: ?std.http.Status, retry_after_ms: ?u64, retries: u32) Error!bool {
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
    pub fn attempt(call: *Call, body: ?[]u8, retries: u32) Outcome {
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

    pub fn cancelRace(comptime Race: type, select: *Io.Select(Race), gpa: Allocator) void {
        while (select.cancel()) |leftover| switch (leftover) {
            // A response that completed while the timer won is discarded.
            .attempt => |outcome| outcome.deinit(gpa),
            .timeout => {},
        };
    }

    pub fn perform(call: *const Call, body: ?[]u8, headers: []const std.http.Header) Outcome {
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

    pub fn performOrFail(call: *const Call, body: ?[]u8, headers: []const std.http.Header) anyerror!Outcome {
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
                .user_agent = .{ .override = Client.sdk_identifier },
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

    pub fn readError(connection: *std.http.Client.Connection) anyerror {
        return connection.getReadError() orelse error.ReadFailed;
    }

    /// Returns `error.StaleConnection` for a failure on a reused connection
    /// that means the peer had closed it before this request, and `err`
    /// otherwise.
    pub fn staleOr(reused: bool, err: anyerror) anyerror {
        if (!reused) return err;
        return switch (err) {
            error.HttpConnectionClosing,
            error.EndOfStream,
            error.ConnectionResetByPeer,
            error.BrokenPipe,
            error.SocketUnconnected,
            error.NotOpenForReading,
            // Windows reports a connection the peer had already closed as a
            // bare `error.Unexpected` (NTSTATUS 0xc000013b, LOCAL_DISCONNECT).
            // Only a reused connection is treated this way: on a fresh one the
            // error is the real outcome and is reported as it is.
            error.Unexpected,
            => error.StaleConnection,
            else => err,
        };
    }

    /// Takes an idle pooled connection for `uri`, if there is one, so the
    /// caller knows the request runs on a reused connection. Returns `null`
    /// when a proxy is configured, leaving the choice to `std.http.Client`.
    pub fn findPooledConnection(client: *Client, uri: std.Uri) ?*std.http.Client.Connection {
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
    pub fn refreshTrust(client: *Client) Io.Cancelable!void {
        if (!tls_trust_refresh) return;
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

    pub fn writeError(connection: *std.http.Client.Connection, err: anyerror) anyerror {
        if (err != error.WriteFailed) return err;
        return connection.stream_writer.err orelse error.WriteFailed;
    }

    /// Records a decoding failure in the diagnostics and returns it.
    pub fn decodeFailure(call: *Call, err: json.Reader.Error, reader: *json.Reader, response: Response) Error {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidResponse => {
                call.noteDecodeFailure(&reader.failure, response);
                return error.InvalidResponse;
            },
        };
    }

    pub fn noteEncodeFailure(call: *Call, failure: *const json.Failure) void {
        const d = call.diagnostics orelse return;
        d.setString("message", failure.message());
        d.setString("path", failure.path());
    }

    pub fn noteDecodeFailure(call: *Call, failure: *const json.Failure, response: Response) void {
        log.debug("{s} {s}: response does not match the API schema at {s}: {s}", .{
            @tagName(call.method), call.url, failure.path(), failure.message(),
        });
        const d = call.noteResponse(response) orelse return;
        d.setString("message", failure.message());
        d.setString("path", failure.path());
    }

    /// Records the status, request id and body of a 2xx response that could
    /// not be decoded.
    pub fn noteResponse(call: *Call, response: Response) ?*Diagnostics {
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

    pub fn noteHttpError(call: *Call, status: std.http.Status, body: []const u8, retry_after_ms: ?u64) void {
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

    pub fn noteFailure(call: *Call, err: Error, cause: anyerror, status: ?std.http.Status) void {
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

pub fn invalidOption(diagnostics: ?*Diagnostics, path: []const u8, message: []const u8) error{InvalidOption} {
    if (diagnostics) |d| {
        d.err = error.InvalidOption;
        d.setString("path", path);
        d.setString("message", message);
    }
    return error.InvalidOption;
}

/// Decompresses a response body. `std.http.Client` offers `gzip` and
/// `deflate`; the API does not compress today, and this keeps a server that
/// starts to from breaking decoding. On success, `raw` is freed.
pub fn decompress(gpa: Allocator, raw: []u8, encoding: std.http.ContentEncoding, limit: usize) ![]u8 {
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

/// How often a long-running client reloads the clock and root certificates
/// it checks TLS certificates against.
const trust_refresh_interval: Io.Duration = .fromSeconds(std.time.s_per_hour);

/// Whether a long-running client reloads the system root certificates and its
/// clock hourly. On by default. Turn it off with `-Dtls-trust-refresh=false`
/// on the command line, or by passing `.tls_trust_refresh = false` to
/// `b.dependency("typesafe", ...)`.
///
/// The refresh is the only place this package reads `std.http.Client` fields
/// that std does not promise to keep (`ca_bundle`, `ca_bundle_lock`, `now`).
/// Turning it off keeps the whole package on std's supported surface; the cost
/// is that a client running for longer than a certificate's validity window
/// verifies against the time and roots it loaded at its first HTTPS request.
pub const tls_trust_refresh: bool = build_options.tls_trust_refresh;

pub fn resolveTimeout(timeout: Io.Duration) error{InvalidTimeout}!?Io.Duration {
    if (timeout.nanoseconds == Io.Duration.max.nanoseconds) return null;
    if (timeout.nanoseconds <= 0 or timeout.nanoseconds > Client.max_timeout.nanoseconds) return error.InvalidTimeout;
    return timeout;
}

pub fn isValidApiKey(key: []const u8) bool {
    if (key.len == 0) return false;
    for (key) |c| if (c < 0x21 or c > 0x7e) return false;
    return true;
}

pub fn isValidModel(model: []const u8) bool {
    return model.len > 0 and std.unicode.utf8ValidateSlice(model);
}

pub fn validateHeader(header: std.http.Header) error{ InvalidHeader, ReservedHeader }!void {
    if (header.name.len == 0) return error.InvalidHeader;
    for (header.name) |c| {
        const token = std.ascii.isAlphanumeric(c) or std.mem.findScalar(u8, "!#$%&'*+-.^_`|~", c) != null;
        if (!token) return error.InvalidHeader;
    }
    for (header.value) |c| {
        if (c == '\r' or c == '\n' or c == 0 or (c < 0x20 and c != '\t') or c == 0x7f) return error.InvalidHeader;
    }
    for (Client.reserved_headers) |reserved| {
        if (std.ascii.eqlIgnoreCase(header.name, reserved)) return error.ReservedHeader;
    }
}

/// Checks that `std.http.Client` can connect to the base URL and returns it
/// without a trailing slash and with a lowercase scheme.
pub fn normalizeBaseUrl(arena: Allocator, raw: []const u8) (error{InvalidBaseUrl} || Allocator.Error)![]const u8 {
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
