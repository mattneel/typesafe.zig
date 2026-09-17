//! Details behind an error from `Client.ask`, `Client.askDynamic` or
//! `Client.listModels`.
//!
//! Zig errors carry no payload, so the client fills an optional
//! `Diagnostics` passed in the call options, the same shape
//! `std.json.Diagnostics` uses. Callers that only want the error pass nothing
//! and pay nothing.
//!
//! ```zig
//! var diagnostics: typesafe.Diagnostics = .init(gpa);
//! defer diagnostics.deinit();
//!
//! var result = client.ask(state, questions, .{ .diagnostics = &diagnostics }) catch |err| {
//!     std.log.err("{f}", .{diagnostics});
//!     return err;
//! };
//! defer result.deinit();
//! ```
//!
//! A call resets the diagnostics when it starts. On failure, the fields
//! describe the final attempt; `attempts` counts every attempt. Strings are
//! owned by the diagnostics and stay valid until the next call that uses it,
//! `reset`, or `deinit`. One `Diagnostics` must not be shared by calls running
//! at the same time.

const std = @import("std");
const errors = @import("errors.zig");

const Diagnostics = @This();

arena: std.heap.ArenaAllocator,

/// The error the call returned, or `null` when it succeeded.
err: ?errors.Error = null,
/// The request method and URL, such as `POST https://api.typesafe.ai/v1/systemone`.
method: ?std.http.Method = null,
url: ?[]const u8 = null,
/// The HTTP status of the final response, or `null` when no response arrived.
status: ?std.http.Status = null,
/// The `x-typesafe-request-id` response header. Quote it when contacting support.
request_id: ?[]const u8 = null,
/// The server's error category, such as `authentication_error` or
/// `api_usage_error`, from `detail.error_type` in the error body.
error_type: ?[]const u8 = null,
/// A human-readable description: the server's message for an HTTP error,
/// or what failed for a client-side or decoding error.
message: ?[]const u8 = null,
/// The raw response body of an error response or an undecodable 2xx
/// response, capped at `max_body_bytes`.
body: ?[]const u8 = null,
/// For `InvalidRequest` and `InvalidResponse`: the path to the offending
/// value, such as `questions.department.criteria` or `answers.tone.confidence`.
path: ?[]const u8 = null,
/// The server's requested wait, from the `retry-after-ms` or `Retry-After`
/// header of the final response.
retry_after_ms: ?u64 = null,
/// Attempts made, including the first. `0` when the call failed before
/// sending anything.
attempts: u32 = 0,
/// The underlying error behind a transport or body failure, such as
/// `error.ConnectionRefused` for `ConnectionFailed` or `error.ResponseTruncated`
/// for a body cut short. Its name is useful in logs; the set of possible
/// values depends on the standard library version.
cause: ?anyerror = null,

/// The most body bytes kept in `body`.
pub const max_body_bytes = 64 * 1024;

/// `gpa` backs the strings the diagnostics hold. It must be thread-safe if
/// the call runs its request on another thread, which is the case whenever
/// timeouts are enforced.
pub fn init(gpa: std.mem.Allocator) Diagnostics {
    return .{ .arena = .init(gpa) };
}

/// Frees the strings the diagnostics hold. Frees nothing else, so it is safe
/// to call on a diagnostics that has not been used yet.
pub fn deinit(diagnostics: *Diagnostics) void {
    diagnostics.arena.deinit();
    diagnostics.* = undefined;
}

/// Clears every field and frees the strings, keeping up to 64 KiB of the
/// allocated capacity for reuse.
pub fn reset(diagnostics: *Diagnostics) void {
    _ = diagnostics.arena.reset(.{ .retain_with_limit = 64 * 1024 });
    diagnostics.* = .{ .arena = diagnostics.arena };
}

/// Stores a copy of `value`. When copying fails for lack of memory, the
/// field is left `null`: diagnostics never turn one error into another.
pub fn setString(diagnostics: *Diagnostics, comptime field: []const u8, value: []const u8) void {
    @field(diagnostics, field) = diagnostics.arena.allocator().dupe(u8, value) catch null;
}

/// Stores a formatted string, or leaves the field `null` when out of memory.
pub fn setPrint(diagnostics: *Diagnostics, comptime field: []const u8, comptime fmt: []const u8, args: anytype) void {
    @field(diagnostics, field) = std.fmt.allocPrint(diagnostics.arena.allocator(), fmt, args) catch null;
}

/// Stores the body, truncated to `max_body_bytes`.
pub fn setBody(diagnostics: *Diagnostics, body: []const u8) void {
    diagnostics.setString("body", body[0..@min(body.len, max_body_bytes)]);
}

/// Writes one log-ready line, such as:
///
/// ```text
/// BadRequest (HTTP 400): Unknown model: jev-0.0.1 [POST https://api.typesafe.ai/v1/systemone, request_id: req_0123]
/// ```
///
/// `attempts` is included when there was more than one, and `cause` when
/// there is both a message and an underlying error.
pub fn format(diagnostics: Diagnostics, w: *std.Io.Writer) std.Io.Writer.Error!void {
    if (diagnostics.err) |err| {
        try w.writeAll(@errorName(err));
    } else {
        try w.writeAll("ok");
    }
    if (diagnostics.status) |status| try w.print(" (HTTP {d})", .{@intFromEnum(status)});
    try w.writeAll(": ");
    if (diagnostics.message) |message| {
        try w.writeAll(message);
    } else if (diagnostics.cause) |cause| {
        try w.writeAll(@errorName(cause));
    } else {
        try w.writeAll(defaultMessage(diagnostics.err));
    }
    if (diagnostics.path) |path| {
        if (path.len > 0) try w.print(" at {s}", .{path});
    }

    var first = true;
    if (diagnostics.method) |method| {
        try separator(w, &first);
        try w.print("{s} {s}", .{ @tagName(method), diagnostics.url orelse "" });
    }
    if (diagnostics.request_id) |request_id| {
        try separator(w, &first);
        try w.print("request_id: {s}", .{request_id});
    }
    if (diagnostics.attempts > 1) {
        try separator(w, &first);
        try w.print("attempts: {d}", .{diagnostics.attempts});
    }
    if (diagnostics.cause) |cause| {
        if (diagnostics.message != null) {
            try separator(w, &first);
            try w.print("cause: {s}", .{@errorName(cause)});
        }
    }
    if (!first) try w.writeByte(']');
}

fn separator(w: *std.Io.Writer, first: *bool) std.Io.Writer.Error!void {
    try w.writeAll(if (first.*) " [" else ", ");
    first.* = false;
}

fn defaultMessage(err: ?errors.Error) []const u8 {
    const e = err orelse return "request succeeded";
    return switch (e) {
        error.InvalidRequest => "invalid request",
        error.InvalidResponse => "invalid response",
        error.Timeout => "request timed out",
        error.ConnectionFailed => "connection failed",
        error.TlsFailure => "TLS handshake failed",
        error.ResponseTooLarge => "response body too large",
        error.Canceled => "request canceled",
        error.OutOfMemory => "out of memory",
        else => "request failed",
    };
}

test format {
    const gpa = std.testing.allocator;
    var diagnostics: Diagnostics = .init(gpa);
    defer diagnostics.deinit();

    diagnostics.err = error.BadRequest;
    diagnostics.method = .POST;
    diagnostics.setString("url", "https://api.typesafe.ai/v1/systemone");
    diagnostics.status = .bad_request;
    diagnostics.setString("request_id", "req_0123");
    diagnostics.setString("message", "Unknown model: jev-0.0.1");
    diagnostics.attempts = 1;
    try std.testing.expectFmt(
        "BadRequest (HTTP 400): Unknown model: jev-0.0.1 [POST https://api.typesafe.ai/v1/systemone, request_id: req_0123]",
        "{f}",
        .{diagnostics},
    );

    diagnostics.reset();
    try std.testing.expectEqual(null, diagnostics.url);
    diagnostics.err = error.InvalidResponse;
    diagnostics.setString("message", "expected a number from 0 to 1, got 1.5");
    diagnostics.setString("path", "answers.tone.confidence");
    diagnostics.attempts = 3;
    try std.testing.expectFmt(
        "InvalidResponse: expected a number from 0 to 1, got 1.5 at answers.tone.confidence [attempts: 3]",
        "{f}",
        .{diagnostics},
    );

    diagnostics.reset();
    diagnostics.err = error.ConnectionFailed;
    diagnostics.cause = error.ConnectionRefused;
    try std.testing.expectFmt("ConnectionFailed: ConnectionRefused", "{f}", .{diagnostics});
}
