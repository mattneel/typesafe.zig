//! Observability callbacks.
//!
//! Zig has no telemetry library to emit events into, so the client calls
//! plain function pointers instead. Attach a metrics library, a tracer or a
//! logger without the client knowing about it:
//!
//! ```zig
//! const Metrics = struct {
//!     requests: std.atomic.Value(u64) = .init(0),
//!
//!     fn onRequestEnd(context: ?*anyopaque, event: *const typesafe.hooks.RequestEnd) void {
//!         const metrics: *Metrics = @ptrCast(@alignCast(context.?));
//!         _ = metrics.requests.fetchAdd(1, .monotonic);
//!         std.log.info("typesafe {t} took {f} over {d} attempts", .{ event.operation, event.duration, event.attempts });
//!     }
//! };
//!
//! var metrics: Metrics = .{};
//! var client: typesafe.Client = try .init(gpa, io, .{
//!     .api_key = key,
//!     .hooks = .{ .context = &metrics, .onRequestEnd = Metrics.onRequestEnd },
//! });
//! ```
//!
//! Callbacks run on the task that called the client, synchronously, so keep
//! them short. They must be thread-safe when the client is shared between
//! threads. Strings in an event are valid only during the callback.

const std = @import("std");
const errors = @import("errors.zig");

/// Function pointers the client calls around each call. Every pointer is
/// optional; `context` is passed through to each one untouched.
pub const Hooks = struct {
    context: ?*anyopaque = null,
    /// Called once when a call starts, before its options are validated and
    /// its request body is encoded.
    onRequestStart: ?*const fn (context: ?*anyopaque, event: *const RequestStart) void = null,
    /// Called before sleeping ahead of each retry.
    onRetry: ?*const fn (context: ?*anyopaque, event: *const RetryEvent) void = null,
    /// Called once when a call finishes, successfully or not, after every
    /// `onRequestStart`. Only running out of memory before the call starts
    /// skips both.
    onRequestEnd: ?*const fn (context: ?*anyopaque, event: *const RequestEnd) void = null,
};

/// The API operation a call performs.
pub const Operation = enum {
    /// `POST /v1/systemone`
    ask,
    /// `GET /v1/models`
    list_models,
};

/// A call that has started, before its options are validated and its body encoded.
pub const RequestStart = struct {
    operation: Operation,
    method: std.http.Method,
    url: []const u8,
    /// The model the call asks, or `null` for `list_models`.
    model: ?[]const u8,
    /// The number of questions, or 0 for `list_models`.
    question_count: usize,
    /// `AskOptions.user_data` or `ListModelsOptions.user_data` of the call.
    user_data: ?*anyopaque,
};

/// An attempt that failed and the delay before the next one.
pub const RetryEvent = struct {
    operation: Operation,
    method: std.http.Method,
    url: []const u8,
    /// The attempt that failed, starting at 1.
    attempt: u32,
    /// The error the attempt failed with.
    err: errors.Error,
    /// The status of the failed attempt, or `null` for a transport failure.
    status: ?std.http.Status,
    /// How long the client waits before the next attempt.
    delay: std.Io.Duration,
    user_data: ?*anyopaque,
};

/// A call that finished, successfully or not.
pub const RequestEnd = struct {
    operation: Operation,
    method: std.http.Method,
    url: []const u8,
    model: ?[]const u8,
    question_count: usize,
    /// The error the call returns, or `null` on success.
    err: ?errors.Error,
    /// The status of the final response, or `null` when none arrived.
    status: ?std.http.Status,
    /// The `x-typesafe-request-id` of the final response.
    request_id: ?[]const u8,
    /// Attempts made, including the first.
    attempts: u32,
    /// Wall time from the start of the call, including retry delays.
    duration: std.Io.Duration,
    /// Token usage reported by a successful `ask`.
    input_tokens: ?u64,
    output_tokens: ?u64,
    user_data: ?*anyopaque,
};
