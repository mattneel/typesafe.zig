//! The error sets returned by the client, and the mapping from HTTP status
//! codes to errors.

const std = @import("std");

/// Every way a request can fail.
///
/// Zig errors carry no payload. Pass a `Diagnostics` in the call options to
/// get the status, request id, server message, offending field path and
/// attempt count behind an error.
///
/// | Error | Trigger | Retried by default |
/// | --- | --- | --- |
/// | `InvalidRequest` | The request failed client-side checks before it was sent (for example a string that is not valid UTF-8, a NaN, an invalid per-call option or header, or an HTTPS base URL with a proxy configured) | no |
/// | `BadRequest` | HTTP 400, for example an unknown model | no |
/// | `Unauthorized` | HTTP 401, a missing or invalid API key | no |
/// | `PermissionDenied` | HTTP 403 | no |
/// | `NotFound` | HTTP 404 | no |
/// | `RequestTimeout` | HTTP 408 | yes |
/// | `Unprocessable` | HTTP 422; the server names the offending field in the diagnostics message | no |
/// | `RateLimited` | HTTP 429 | yes |
/// | `Overloaded` | HTTP 529 | yes |
/// | `ServerError` | Any other 5xx | yes |
/// | `UnexpectedStatus` | Any other non-2xx status, including redirects, which are never followed | no |
/// | `ConnectionFailed` | DNS, connect, reset, broken pipe, a malformed HTTP response, or a body cut short by a closed connection | yes |
/// | `TlsFailure` | TLS handshake failure or unreadable system certificates | yes |
/// | `Timeout` | An attempt did not complete within the configured timeout | yes |
/// | `InvalidResponse` | A 2xx response whose body does not match the API schema, or a response in an unsupported content encoding | no |
/// | `ResponseTooLarge` | The response body exceeded `max_response_bytes` | no |
/// | `Canceled` | The `Io` canceled the calling task | no |
/// | `OutOfMemory` | An allocation failed | no |
pub const Error = error{
    InvalidRequest,
    BadRequest,
    Unauthorized,
    PermissionDenied,
    NotFound,
    RequestTimeout,
    Unprocessable,
    RateLimited,
    Overloaded,
    ServerError,
    UnexpectedStatus,
    ConnectionFailed,
    TlsFailure,
    Timeout,
    InvalidResponse,
    ResponseTooLarge,
    Canceled,
    OutOfMemory,
};

/// Errors from `Client.init` and `Client.initFromEnv`. Each one is a
/// configuration mistake in the calling program, never a network failure:
/// `init` performs no I/O.
pub const InitError = error{
    /// No API key was passed and, for `initFromEnv`, `TYPESAFE_API_KEY` is
    /// unset or blank.
    MissingApiKey,
    /// The API key contains characters that cannot appear in an HTTP header.
    InvalidApiKey,
    /// The base URL is not an absolute `http` or `https` URL with a host, or
    /// it contains credentials, a query or a fragment.
    InvalidBaseUrl,
    /// The model name is empty or not valid UTF-8.
    InvalidModel,
    /// The timeout is not positive, or longer than `Client.max_timeout`.
    InvalidTimeout,
    /// The retry policy has a jitter outside 0 to 1.
    InvalidRetry,
    /// `max_response_bytes` is zero.
    InvalidMaxResponseBytes,
    /// An extra header has an invalid name or a value containing control
    /// characters.
    InvalidHeader,
    /// An extra header tries to set a header the client manages itself, such
    /// as `authorization` or `user-agent`.
    ReservedHeader,
    OutOfMemory,
};

/// Returns the error for a non-2xx status, or `null` for a 2xx status.
pub fn fromStatus(status: std.http.Status) ?Error {
    const code = @intFromEnum(status);
    return switch (code) {
        200...299 => null,
        400 => error.BadRequest,
        401 => error.Unauthorized,
        403 => error.PermissionDenied,
        404 => error.NotFound,
        408 => error.RequestTimeout,
        422 => error.Unprocessable,
        429 => error.RateLimited,
        529 => error.Overloaded,
        500...528, 530...599 => error.ServerError,
        else => error.UnexpectedStatus,
    };
}

test fromStatus {
    const expectEqual = std.testing.expectEqual;
    try expectEqual(null, fromStatus(.ok));
    try expectEqual(null, fromStatus(@enumFromInt(204)));
    try expectEqual(error.BadRequest, fromStatus(.bad_request).?);
    try expectEqual(error.Unauthorized, fromStatus(.unauthorized).?);
    try expectEqual(error.PermissionDenied, fromStatus(.forbidden).?);
    try expectEqual(error.NotFound, fromStatus(.not_found).?);
    try expectEqual(error.RequestTimeout, fromStatus(.request_timeout).?);
    try expectEqual(error.Unprocessable, fromStatus(@enumFromInt(422)).?);
    try expectEqual(error.RateLimited, fromStatus(.too_many_requests).?);
    try expectEqual(error.Overloaded, fromStatus(@enumFromInt(529)).?);
    try expectEqual(error.ServerError, fromStatus(.internal_server_error).?);
    try expectEqual(error.ServerError, fromStatus(.service_unavailable).?);
    try expectEqual(error.ServerError, fromStatus(@enumFromInt(599)).?);
    try expectEqual(error.UnexpectedStatus, fromStatus(.found).?);
    try expectEqual(error.UnexpectedStatus, fromStatus(.conflict).?);
    try expectEqual(error.UnexpectedStatus, fromStatus(@enumFromInt(101)).?);
}
