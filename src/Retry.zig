//! Retry policy for TypeSafe calls.
//!
//! The defaults match TypeSafe's official Python and JavaScript SDKs, so a
//! call behaves the same in every language: two retries after the first
//! attempt, exponential backoff from 500 ms to a 5 s cap with up to 25%
//! jitter, retries on 408, 429 and every 5xx (including 529 Overloaded) plus
//! connection failures and timeouts, `Retry-After` honoured, and a 30 s budget
//! for the whole call.
//!
//! Only transient failures are retried. Evaluating questions has no side
//! effects on the server, which is what makes retrying a `POST` safe.
//!
//! ```zig
//! // A client with more patience
//! var client: typesafe.Client = try .init(gpa, io, .{
//!     .api_key = key,
//!     .retry = .{ .max_retries = 4, .budget_ms = 60_000 },
//! });
//!
//! // No retries for one call
//! var result = try client.ask(state, questions, .{ .retry = .disabled });
//! ```

const std = @import("std");
const errors = @import("errors.zig");

const Retry = @This();

/// Retries after the first attempt. `0` disables retries.
max_retries: u32 = 2,
/// First backoff delay in milliseconds, doubled on each retry. `0` disables
/// backoff.
backoff_initial_ms: u32 = 500,
/// Upper bound for a single backoff delay in milliseconds.
backoff_max_ms: u32 = 5_000,
/// Fraction of each backoff delay randomly subtracted, from 0 to 1.
jitter: f64 = 0.25,
/// Wait for the server's `retry-after-ms` or `Retry-After` header when a
/// retryable response carries one.
respect_retry_after: bool = true,
/// Longest server-requested delay to honour. A longer one falls back to the
/// backoff delay, as in the JavaScript SDK.
max_retry_after_ms: u64 = 60_000,
/// Retry connection failures, TLS failures and timeouts.
retry_transport_errors: bool = true,
/// Total time budget for one call in milliseconds, covering every attempt and
/// every delay. Before a retry, the policy stops when the elapsed time plus
/// the next delay would reach the budget. `null` disables the budget.
budget_ms: ?u64 = 30_000,
/// Decides which HTTP error statuses are retried, replacing the default of
/// 408, 429 and every 5xx. For example, to also stop retrying 501:
///
/// ```zig
/// fn retryable(status: std.http.Status) bool {
///     return status != .not_implemented and typesafe.Retry.isRetryableStatusByDefault(status);
/// }
/// ```
isRetryableStatus: ?*const fn (status: std.http.Status) bool = null,

/// The default policy.
pub const default: Retry = .{};

/// A policy that never retries.
pub const disabled: Retry = .{ .max_retries = 0 };

/// The longest delay `parseRetryAfter` reports: one year, in milliseconds.
pub const max_delay_ms: u64 = 365 * std.time.ms_per_day;

/// Returns whether the policy's fields are in range: `jitter` between 0 and 1.
pub fn isValid(policy: Retry) bool {
    return policy.jitter >= 0 and policy.jitter <= 1;
}

/// Returns `true` when `err` is a kind of failure the policy retries,
/// ignoring the retry count and the budget. For an HTTP error status, the
/// client asks `retriesStatus` instead, which differs only when
/// `isRetryableStatus` is set.
///
/// Use it to build your own escalation, for example sending a case that still
/// fails to a slower fallback.
pub fn isRetryable(policy: Retry, err: errors.Error) bool {
    return switch (err) {
        error.RequestTimeout,
        error.RateLimited,
        error.Overloaded,
        error.ServerError,
        => true,
        error.ConnectionFailed,
        error.TlsFailure,
        error.Timeout,
        => policy.retry_transport_errors,
        error.InvalidRequest,
        error.BadRequest,
        error.Unauthorized,
        error.PermissionDenied,
        error.NotFound,
        error.Unprocessable,
        error.UnexpectedStatus,
        error.InvalidResponse,
        error.ResponseTooLarge,
        error.Canceled,
        error.OutOfMemory,
        => false,
    };
}

test isRetryable {
    const policy: Retry = .{};
    try std.testing.expect(policy.isRetryable(error.Overloaded));
    try std.testing.expect(policy.isRetryable(error.RateLimited));
    try std.testing.expect(policy.isRetryable(error.ServerError));
    try std.testing.expect(policy.isRetryable(error.RequestTimeout));
    try std.testing.expect(policy.isRetryable(error.Timeout));
    try std.testing.expect(policy.isRetryable(error.ConnectionFailed));
    try std.testing.expect(!policy.isRetryable(error.Unauthorized));
    try std.testing.expect(!policy.isRetryable(error.Unprocessable));
    try std.testing.expect(!policy.isRetryable(error.InvalidResponse));
    try std.testing.expect(!policy.isRetryable(error.Canceled));

    const no_transport: Retry = .{ .retry_transport_errors = false };
    try std.testing.expect(!no_transport.isRetryable(error.Timeout));
    try std.testing.expect(!no_transport.isRetryable(error.TlsFailure));
    try std.testing.expect(no_transport.isRetryable(error.ServerError));
}

/// Returns `true` when the policy retries a response with the non-2xx
/// `status`, ignoring the retry count and the budget.
pub fn retriesStatus(policy: Retry, status: std.http.Status) bool {
    if (policy.isRetryableStatus) |isRetryableStatusFn| return isRetryableStatusFn(status);
    return isRetryableStatusByDefault(status);
}

/// The default retryable statuses: 408, 429 and every 5xx.
pub fn isRetryableStatusByDefault(status: std.http.Status) bool {
    const err = errors.fromStatus(status) orelse return false;
    return (Retry{}).isRetryable(err);
}

test retriesStatus {
    const policy: Retry = .{};
    try std.testing.expect(policy.retriesStatus(.request_timeout));
    try std.testing.expect(policy.retriesStatus(@enumFromInt(529)));
    try std.testing.expect(policy.retriesStatus(.not_implemented));
    try std.testing.expect(!policy.retriesStatus(.conflict));
    try std.testing.expect(!policy.retriesStatus(.ok));

    const custom: Retry = .{ .isRetryableStatus = struct {
        fn retryable(status: std.http.Status) bool {
            return status == .conflict;
        }
    }.retryable };
    try std.testing.expect(custom.retriesStatus(.conflict));
    try std.testing.expect(!custom.retriesStatus(.service_unavailable));
}

/// Returns the backoff delay in milliseconds before retry number `retry`
/// (zero-based), without jitter: `backoff_initial_ms` doubled `retry` times,
/// capped at `backoff_max_ms`.
pub fn backoffMs(policy: Retry, retry: u32) u64 {
    if (policy.backoff_initial_ms == 0 or policy.backoff_max_ms == 0) return 0;
    // Capping the shift keeps a large retry count from overflowing.
    const shift: u6 = @intCast(@min(retry, 32));
    const exponential = @as(u64, policy.backoff_initial_ms) << shift;
    return @min(exponential, policy.backoff_max_ms);
}

test backoffMs {
    const policy: Retry = .{};
    const expected = [_]u64{ 500, 1000, 2000, 4000, 5000, 5000 };
    for (expected, 0..) |ms, retry| {
        try std.testing.expectEqual(ms, policy.backoffMs(@intCast(retry)));
    }
    try std.testing.expectEqual(5000, policy.backoffMs(std.math.maxInt(u32)));
    try std.testing.expectEqual(0, (Retry{ .backoff_initial_ms = 0 }).backoffMs(3));
}

/// Returns the delay in milliseconds before retry number `retry`
/// (zero-based): the backoff delay with up to `jitter` of it randomly
/// subtracted.
pub fn delayMs(policy: Retry, retry: u32, random: std.Random) u64 {
    const base = policy.backoffMs(retry);
    // `!(x > 0)` also rejects NaN.
    if (base == 0 or !(policy.jitter > 0)) return base;
    const jitter = @min(policy.jitter, 1);
    const scaled = @as(f64, @floatFromInt(base)) * (1 - random.float(f64) * jitter);
    return @intFromFloat(@round(scaled));
}

test delayMs {
    var prng: std.Random.DefaultPrng = .init(0x7e57);
    const random = prng.random();
    const policy: Retry = .{};
    // Every sample stays within the jitter window, and the samples spread
    // across it: a policy that stopped applying jitter would keep passing the
    // bounds alone.
    var lowest: u64 = std.math.maxInt(u64);
    var highest: u64 = 0;
    for (0..200) |_| {
        const delay = policy.delayMs(1, random);
        try std.testing.expect(delay >= 750 and delay <= 1000);
        lowest = @min(lowest, delay);
        highest = @max(highest, delay);
    }
    try std.testing.expect(lowest < 800);
    try std.testing.expect(highest > 950);
    const exact: Retry = .{ .jitter = 0 };
    try std.testing.expectEqual(2000, exact.delayMs(2, random));
}

/// Returns the delay before the next retry: the server's requested delay when
/// the policy honours it and it is within `max_retry_after_ms`, otherwise the
/// jittered backoff delay.
pub fn nextDelayMs(policy: Retry, retry: u32, retry_after_ms: ?u64, random: std.Random) u64 {
    if (policy.respect_retry_after) {
        if (retry_after_ms) |ms| {
            if (ms <= policy.max_retry_after_ms) return ms;
        }
    }
    return policy.delayMs(retry, random);
}

test nextDelayMs {
    var prng: std.Random.DefaultPrng = .init(1);
    const random = prng.random();
    const policy: Retry = .{ .jitter = 0 };
    try std.testing.expectEqual(1500, policy.nextDelayMs(0, 1500, random));
    try std.testing.expectEqual(500, policy.nextDelayMs(0, null, random));
    // Longer than max_retry_after_ms: back off instead.
    try std.testing.expectEqual(1000, policy.nextDelayMs(1, 120_000, random));
    const ignore: Retry = .{ .jitter = 0, .respect_retry_after = false };
    try std.testing.expectEqual(500, ignore.nextDelayMs(0, 1500, random));
}

/// Parses the `retry-after-ms` and `Retry-After` response header values into
/// a delay in milliseconds.
///
/// `retry-after-ms` wins when both hold a valid delay. `Retry-After` may hold
/// seconds (fractions such as `0.5` are accepted) or an HTTP date in any of
/// the three formats of RFC 9110: IMF-fixdate (`Sun, 06 Nov 1994 08:49:37 GMT`),
/// RFC 850 (`Sunday, 06-Nov-94 08:49:37 GMT`) or asctime
/// (`Sun Nov  6 08:49:37 1994`). A date in the past means no wait.
/// `now_ms` is the current Unix time in milliseconds, used for dates.
///
/// Returns `null` when neither value holds a valid, non-negative delay.
/// Delays are capped at `max_delay_ms`.
pub fn parseRetryAfter(retry_after_ms: ?[]const u8, retry_after: ?[]const u8, now_ms: i64) ?u64 {
    if (retry_after_ms) |text| {
        if (parseDelay(text, 1)) |ms| return ms;
    }
    const text = retry_after orelse return null;
    if (parseDelay(text, std.time.ms_per_s)) |ms| return ms;
    const date_s = parseHttpDate(std.mem.trim(u8, text, " \t"), now_ms) orelse return null;
    const date_ms = @as(i128, date_s) * std.time.ms_per_s;
    const delay = date_ms - now_ms;
    if (delay <= 0) return 0;
    return @intCast(@min(delay, max_delay_ms));
}

test parseRetryAfter {
    const now_ms: i64 = 784_111_777_000; // Sun, 06 Nov 1994 08:49:37 GMT
    const expectEqual = std.testing.expectEqual;

    try expectEqual(1500, parseRetryAfter("1500", null, now_ms));
    try expectEqual(2000, parseRetryAfter(null, "2", now_ms));
    try expectEqual(500, parseRetryAfter(null, "0.5", now_ms));
    try expectEqual(500, parseRetryAfter(null, ".5", now_ms));
    try expectEqual(1500, parseRetryAfter("1500", "9", now_ms));
    try expectEqual(9000, parseRetryAfter("soon", " 9 ", now_ms));
    try expectEqual(null, parseRetryAfter(null, null, now_ms));
    try expectEqual(null, parseRetryAfter("-1", "-2", now_ms));
    try expectEqual(null, parseRetryAfter("1e3", "nan", now_ms));
    try expectEqual(null, parseRetryAfter("", "", now_ms));
    try expectEqual(max_delay_ms, parseRetryAfter("99999999999999999999999", null, now_ms));

    try expectEqual(30_000, parseRetryAfter(null, "Sun, 06 Nov 1994 08:50:07 GMT", now_ms));
    try expectEqual(30_000, parseRetryAfter(null, "Sunday, 06-Nov-94 08:50:07 GMT", now_ms));
    try expectEqual(30_000, parseRetryAfter(null, "Sun Nov  6 08:50:07 1994", now_ms));
    try expectEqual(0, parseRetryAfter(null, "Sat, 05 Nov 1994 08:49:37 GMT", now_ms));
    try expectEqual(null, parseRetryAfter(null, "Sun, 31 Feb 1994 08:49:37 GMT", now_ms));
    try expectEqual(null, parseRetryAfter(null, "Sun, 06 Nov 1994 24:00:00 GMT", now_ms));
    try expectEqual(null, parseRetryAfter(null, "Sun, 06 Nov 1994 08:49:37 UTC", now_ms));
}

/// Parses a non-negative decimal number of units (digits with an optional
/// fraction) and scales it to milliseconds.
fn parseDelay(raw: []const u8, ms_per_unit: u64) ?u64 {
    const text = std.mem.trim(u8, raw, " \t");
    if (text.len == 0) return null;
    var seen_dot = false;
    var seen_digit = false;
    for (text) |c| switch (c) {
        '0'...'9' => seen_digit = true,
        '.' => {
            if (seen_dot) return null;
            seen_dot = true;
        },
        else => return null,
    };
    if (!seen_digit) return null;
    const value = std.fmt.parseFloat(f64, text) catch return null;
    const ms = value * @as(f64, @floatFromInt(ms_per_unit));
    if (!std.math.isFinite(ms) or ms >= @as(f64, @floatFromInt(max_delay_ms))) return max_delay_ms;
    return @intFromFloat(@round(ms));
}

const month_names = [_]*const [3]u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

/// Parses an RFC 9110 HTTP date into Unix seconds.
fn parseHttpDate(text: []const u8, now_ms: i64) ?i64 {
    return parseImfFixdate(text) orelse parseRfc850(text, now_ms) orelse parseAsctime(text);
}

/// `Sun, 06 Nov 1994 08:49:37 GMT`
fn parseImfFixdate(text: []const u8) ?i64 {
    var it = std.mem.splitScalar(u8, text, ' ');
    const weekday = it.next() orelse return null;
    if (weekday.len != 4 or weekday[3] != ',' or !isAlpha(weekday[0..3])) return null;
    const day = parseDigits(it.next() orelse return null, 1, 2) orelse return null;
    const month = parseMonth(it.next() orelse return null) orelse return null;
    const year = parseDigits(it.next() orelse return null, 4, 4) orelse return null;
    const time = parseTime(it.next() orelse return null) orelse return null;
    if (!std.mem.eql(u8, it.next() orelse return null, "GMT")) return null;
    if (it.next() != null) return null;
    return unixSeconds(year, month, day, time);
}

/// `Sunday, 06-Nov-94 08:49:37 GMT`
fn parseRfc850(text: []const u8, now_ms: i64) ?i64 {
    var it = std.mem.splitScalar(u8, text, ' ');
    const weekday = it.next() orelse return null;
    if (weekday.len < 7 or weekday.len > 10 or weekday[weekday.len - 1] != ',') return null;
    if (!isAlpha(weekday[0 .. weekday.len - 1])) return null;
    const date = it.next() orelse return null;
    if (date.len != 9 or date[2] != '-' or date[6] != '-') return null;
    const day = parseDigits(date[0..2], 2, 2) orelse return null;
    const month = parseMonth(date[3..6]) orelse return null;
    const short_year = parseDigits(date[7..9], 2, 2) orelse return null;
    const time = parseTime(it.next() orelse return null) orelse return null;
    if (!std.mem.eql(u8, it.next() orelse return null, "GMT")) return null;
    if (it.next() != null) return null;

    // RFC 9110: a two-digit year more than 50 years in the future is in the past.
    const now_year = civilYear(@divFloor(now_ms, std.time.ms_per_s));
    var year = @divFloor(now_year, 100) * 100 + short_year;
    if (year > now_year + 50) year -= 100;
    return unixSeconds(year, month, day, time);
}

/// `Sun Nov  6 08:49:37 1994`
fn parseAsctime(text: []const u8) ?i64 {
    if (text.len < 24) return null;
    if (!isAlpha(text[0..3]) or text[3] != ' ') return null;
    const month = parseMonth(text[4..7]) orelse return null;
    if (text[7] != ' ') return null;
    const day_text = std.mem.trimStart(u8, text[8..10], " ");
    const day = parseDigits(day_text, 1, 2) orelse return null;
    if (text[10] != ' ') return null;
    const time = parseTime(text[11..19]) orelse return null;
    if (text[19] != ' ') return null;
    if (text.len != 24) return null;
    const year = parseDigits(text[20..24], 4, 4) orelse return null;
    return unixSeconds(year, month, day, time);
}

const Time = struct { hour: i64, minute: i64, second: i64 };

fn parseTime(text: []const u8) ?Time {
    if (text.len != 8 or text[2] != ':' or text[5] != ':') return null;
    const time: Time = .{
        .hour = parseDigits(text[0..2], 2, 2) orelse return null,
        .minute = parseDigits(text[3..5], 2, 2) orelse return null,
        .second = parseDigits(text[6..8], 2, 2) orelse return null,
    };
    if (time.hour > 23 or time.minute > 59 or time.second > 60) return null;
    return time;
}

fn parseMonth(text: []const u8) ?i64 {
    for (month_names, 1..) |name, number| {
        if (std.mem.eql(u8, text, name)) return @intCast(number);
    }
    return null;
}

fn parseDigits(text: []const u8, min_len: usize, max_len: usize) ?i64 {
    if (text.len < min_len or text.len > max_len) return null;
    var value: i64 = 0;
    for (text) |c| {
        if (c < '0' or c > '9') return null;
        value = value * 10 + (c - '0');
    }
    return value;
}

fn isAlpha(text: []const u8) bool {
    for (text) |c| if (!std.ascii.isAlphabetic(c)) return false;
    return true;
}

fn isLeapYear(year: i64) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

fn daysInMonth(year: i64, month: i64) i64 {
    return switch (month) {
        2 => if (isLeapYear(year)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

/// Converts a UTC calendar date and time to Unix seconds, or `null` when the
/// day does not exist in that month.
fn unixSeconds(year: i64, month: i64, day: i64, time: Time) ?i64 {
    if (day < 1 or day > daysInMonth(year, month)) return null;
    return daysFromCivil(year, month, day) * std.time.s_per_day +
        time.hour * std.time.s_per_hour + time.minute * std.time.s_per_min + time.second;
}

/// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's
/// `days_from_civil`).
fn daysFromCivil(year: i64, month: i64, day: i64) i64 {
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = if (month > 2) month - 3 else month + 9;
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146_097 + doe - 719_468;
}

/// The UTC calendar year of a Unix timestamp in seconds.
fn civilYear(unix_s: i64) i64 {
    const z = @divFloor(unix_s, std.time.s_per_day) + 719_468;
    const era = @divFloor(z, 146_097);
    const doe = z - era * 146_097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36_524) - @divFloor(doe, 146_096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const month = if (mp < 10) mp + 3 else mp - 9;
    const year = yoe + era * 400;
    return if (month <= 2) year + 1 else year;
}

test "calendar helpers" {
    try std.testing.expectEqual(0, daysFromCivil(1970, 1, 1));
    try std.testing.expectEqual(11_017, daysFromCivil(2000, 3, 1));
    try std.testing.expectEqual(1994, civilYear(784_111_777));
    try std.testing.expectEqual(1970, civilYear(0));
    try std.testing.expectEqual(1969, civilYear(-1));
    try std.testing.expectEqual(2026, civilYear(1_789_000_000));
    try std.testing.expectEqual(null, unixSeconds(2025, 2, 29, .{ .hour = 0, .minute = 0, .second = 0 }));
    try std.testing.expect(unixSeconds(2024, 2, 29, .{ .hour = 0, .minute = 0, .second = 0 }) != null);
}

test "rfc 850 two-digit years resolve to within 50 years of now" {
    const now_ms: i64 = 1_789_000_000_000; // 2026
    // "76" is 50 years ahead: still the future century.
    const s_2076 = parseRfc850("Sunday, 06-Nov-76 08:49:37 GMT", now_ms).?;
    try std.testing.expectEqual(2076, civilYear(s_2076));
    // "77" would be 51 years ahead, so it is 1977.
    const s_1977 = parseRfc850("Sunday, 06-Nov-77 08:49:37 GMT", now_ms).?;
    try std.testing.expectEqual(1977, civilYear(s_1977));
}

test isValid {
    try std.testing.expect((Retry{}).isValid());
    try std.testing.expect(!(Retry{ .jitter = 1.5 }).isValid());
    try std.testing.expect(!(Retry{ .jitter = -0.1 }).isValid());
    try std.testing.expect(!(Retry{ .jitter = std.math.nan(f64) }).isValid());
}
