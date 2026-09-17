# Observability

The client gives you three ways to see what it is doing. `Diagnostics` holds the details behind
one failed call. Hooks are function pointers called around every call, for metrics, tracing and
logs. And the client logs retries, schema mismatches and warnings through `std.log`. This guide
covers all three, and the request ids that tie a call to TypeSafe's side.

## Diagnostics

Zig errors carry no payload, so every call returns a bare `typesafe.Error`. To get the status,
the server's message and the rest, pass a `*Diagnostics` in the call options, the same pattern
as `std.json.Diagnostics`. Calls that pass nothing pay nothing.

```zig
var diagnostics: typesafe.Diagnostics = .init(gpa);
defer diagnostics.deinit();

var result = client.ask(ticket.body, questions, .{ .diagnostics = &diagnostics }) catch |err| {
    std.log.err("{f}", .{diagnostics});
    return err;
};
defer result.deinit();
```

| Field | Type | Meaning |
| --- | --- | --- |
| `err` | `?typesafe.Error` | the error the call returned, or `null` when it succeeded |
| `method` | `?std.http.Method` | the request method |
| `url` | `?[]const u8` | the full request URL |
| `status` | `?std.http.Status` | the status of the final response, or `null` when no response arrived |
| `request_id` | `?[]const u8` | the `x-typesafe-request-id` header of the final response |
| `error_type` | `?[]const u8` | the server's error category from `detail.error_type`, such as `authentication_error` or `api_usage_error` |
| `message` | `?[]const u8` | the server's message for an HTTP error, or what failed for a client-side or decoding error |
| `body` | `?[]const u8` | the body of an error response or an undecodable 2xx response, capped at `Diagnostics.max_body_bytes` (64 KiB) |
| `path` | `?[]const u8` | for `InvalidRequest`, `InvalidOption` and `InvalidResponse`, the path to the offending value or option, such as `state.ticket.text`, `timeout` or `answers.tone.confidence` |
| `retry_after_ms` | `?u64` | the wait the final response asked for, from `retry-after-ms` or `Retry-After` |
| `attempts` | `u32` | attempts made, including the first; `0` when the call failed before sending |
| `cause` | `?anyerror` | the underlying error behind a transport failure, such as `error.ConnectionRefused` behind `ConnectionFailed`, or `error.ResponseTruncated` when a closed connection cut a body short |

Most `cause` values come from the Zig standard library, and the set depends on its version, so
use the name in logs rather than switching on it.

### When fields are set

- A call resets the diagnostics when it starts. `reset()` does the same by hand: it clears every
  field and frees the strings, keeping up to 64 KiB of the allocated capacity for reuse.
- On failure, the fields describe the final attempt, and `attempts` counts every attempt.
- After a success, `err`, `message`, `body`, `path`, `error_type`, `retry_after_ms` and `cause`
  are `null`, `status` and `request_id` describe the final, successful response, and `attempts`
  counts every attempt, including failed ones that were retried.
- Strings belong to the diagnostics. They stay valid until the next call that uses it, `reset`,
  or `deinit`.
- A call whose own options are invalid fails with `InvalidOption`, `attempts` 0, and `path`
  naming the option: `model`, `timeout`, `retry`, `extra_headers`, or `base_url` when
  `client.http.https_proxy` is set for an `https` base URL.
- Only the first `Diagnostics.max_body_bytes` (64 KiB) of an error body are parsed for the
  server's message and error type. For a longer JSON body that usually finds no message, and
  `message` quotes the start of the body instead.

One `Diagnostics` can serve many calls in sequence, but calls running at the same time must not
share one. Give each task its own. The allocator passed to `init` backs its strings and must be
thread-safe when the call runs its request on another thread, which is the case whenever
timeouts are enforced.

### Formatting

`{f}` renders one log-ready line:

```text
BadRequest (HTTP 400): Unknown model: jev-0.0.1 [POST https://api.typesafe.ai/v1/systemone, request_id: req_01a0ad38e5c7716995a9123a240934ac]
InvalidResponse (HTTP 200): missing required field at answers.is_urgent [POST https://api.typesafe.ai/v1/systemone]
Timeout: no complete response within 10s [POST https://api.typesafe.ai/v1/systemone, attempts: 3, cause: Timeout]
ConnectionFailed: ConnectionRefused [POST http://localhost:8080/v1/systemone, attempts: 3]
```

The line starts with the error name, then the status when a response arrived. The message comes
next, or the name of `cause` when there is no message, then ` at` and the path when there is
one. The brackets hold the method and URL, the request id, `attempts` when there was more than
one, and `cause` when a message is also present. A diagnostics with no error starts with `ok`.

## Hooks

`Client.Options.hooks` takes a `typesafe.Hooks`: a `context` pointer and three optional function
pointers. Zig has no standard telemetry library to emit events into, so a metrics library, a
tracer or a logger attaches here without the client knowing about it:

```zig
const Metrics = struct {
    calls: std.atomic.Value(u64) = .init(0),
    failures: std.atomic.Value(u64) = .init(0),
    retries: std.atomic.Value(u64) = .init(0),
    input_tokens: std.atomic.Value(u64) = .init(0),

    fn onRetry(context: ?*anyopaque, event: *const typesafe.hooks.RetryEvent) void {
        const metrics: *Metrics = @ptrCast(@alignCast(context.?));
        _ = metrics.retries.fetchAdd(1, .monotonic);
        std.log.info("typesafe {t}: attempt {d} failed with {t}, retrying in {f}", .{
            event.operation, event.attempt, event.err, event.delay,
        });
    }

    fn onRequestEnd(context: ?*anyopaque, event: *const typesafe.hooks.RequestEnd) void {
        const metrics: *Metrics = @ptrCast(@alignCast(context.?));
        _ = metrics.calls.fetchAdd(1, .monotonic);
        if (event.input_tokens) |tokens| _ = metrics.input_tokens.fetchAdd(tokens, .monotonic);

        if (event.err) |err| {
            _ = metrics.failures.fetchAdd(1, .monotonic);
            std.log.warn("typesafe {t} failed with {t} in {f} ({d} attempts, request_id: {s})", .{
                event.operation, err, event.duration, event.attempts, event.request_id orelse "-",
            });
        } else {
            std.log.info("typesafe {t} ok in {f} ({d} attempts, request_id: {s})", .{
                event.operation, event.duration, event.attempts, event.request_id orelse "-",
            });
        }
    }
};

var metrics: Metrics = .{};
var client: typesafe.Client = try .init(gpa, io, .{
    .api_key = key,
    .hooks = .{ .context = &metrics, .onRetry = Metrics.onRetry, .onRequestEnd = Metrics.onRequestEnd },
});
```

| Hook | Event | Called |
| --- | --- | --- |
| `onRequestStart` | `hooks.RequestStart` | once per call, before the call's options are validated and its request body is encoded |
| `onRetry` | `hooks.RetryEvent` | before sleeping ahead of each retry |
| `onRequestEnd` | `hooks.RequestEnd` | once per call, when it finishes, successfully or not |

Every call that fires `onRequestStart` fires `onRequestEnd`. A call whose own options are invalid
(an empty `model`, a timeout that is not positive or longer than a year, a reserved header, an
HTTPS proxy) ends with `err` set to `InvalidOption`; a request that fails to encode ends with
`InvalidRequest`. Both have 0 attempts. Only running out of memory before the call starts skips both hooks.

A request sent again because its pooled keep-alive connection had been closed by the server is
not a retry: it fires no `onRetry` and does not count as an attempt.

### Events

Every event has `operation` (`.ask` or `.list_models`), `method`, `url` and `user_data`.

| Event | Other fields |
| --- | --- |
| `RequestStart` | `model` (`?[]const u8`, `null` for `list_models`), `question_count` (0 for `list_models`) |
| `RetryEvent` | `attempt` (the attempt that failed, starting at 1), `err`, `status` (`null` for a transport failure), `delay` (`std.Io.Duration`) |
| `RequestEnd` | `model`, `question_count`, `err` (`null` on success), `status` of the final response, `request_id`, `attempts`, `duration` (`std.Io.Duration`), `input_tokens` and `output_tokens` (`?u64`) |

`model` is the model the call asked for, such as `jev-latest`. The concrete version that
answered is `result.model`. `duration` is the wall time from the start of the call, including
retry delays, and `{f}` formats it, as in `1.204s`. Token counts are set only by a successful
`ask`.

### Context and user data

`context` is set once on the client and passed to every hook call, which suits a metrics
registry or a logger. `user_data` is set per call, in `AskOptions` or `ListModelsOptions`, and
passed through untouched, which suits a trace span or your own record id:

```zig
const CallContext = struct {
    ticket_id: u64,
};

fn onRequestStart(context: ?*anyopaque, event: *const typesafe.hooks.RequestStart) void {
    _ = context;
    const call: *const CallContext = @ptrCast(@alignCast(event.user_data orelse return));
    std.log.info("ticket {d}: asking {d} questions", .{ call.ticket_id, event.question_count });
}

fn classify(client: *typesafe.Client, ticket: Ticket) !void {
    var call: CallContext = .{ .ticket_id = ticket.id };
    var result = try client.ask(ticket.body, questions, .{ .user_data = &call });
    defer result.deinit();
}
```

### Rules for callbacks

- Callbacks run synchronously on the task that called the client, so their time adds to the
  call. Keep them short.
- When the client is shared between tasks or threads, callbacks can run on several of them at
  the same time, so they must be thread-safe. Use `std.atomic.Value`, as above, or a mutex for
  shared state.
- Strings in an event, such as `url` and `request_id`, are valid only during the callback. Copy
  what you keep.
- Whatever `context` and `user_data` point to must outlive the calls that use them.

## Logging

The client logs through `std.log.scoped(.typesafe)`. At `.debug`:

- each retry, with the failed attempt, the error and the delay;
- a retry skipped because the delay would reach the retry budget;
- a 2xx response that does not match the API schema, with the path and the problem.

At `.warn`:

- an attempt sent, or waited on, without the timeout because the `Io` cannot run a task or timer
  concurrently;
- a failure to reload the system root certificates during the hourly refresh. The client keeps
  the certificates it already has.

```text
debug(typesafe): POST https://api.typesafe.ai/v1/systemone: attempt 1 failed with RateLimited; retrying in 512 ms
debug(typesafe): POST https://api.typesafe.ai/v1/systemone: response does not match the API schema at answers.is_urgent: missing required field
warning(typesafe): POST https://api.typesafe.ai/v1/systemone: the Io cannot run a task concurrently; sending without the timeout
```

Log lines never include the API key, the state or the questions.

Whether a message prints depends on the build mode. The default `std.options.log_level` is
`.debug` in Debug builds and `.info` in release builds, so `.warn` messages print in both and
`.debug` messages only in Debug builds. Set a level for the `typesafe` scope in your root source
file to change that for this client alone:

```zig
pub const std_options: std.Options = .{
    .log_scope_levels = &.{.{ .scope = .typesafe, .level = .debug }},
};
```

A scope level replaces `log_level` for that scope, so `.level = .debug` shows the messages in a
release build, and `.level = .info` hides them in a Debug build. To send them to your own logger,
set `std_options.logFn`. Under `zig build test`, the test runner prints only messages at
`std.testing.log_level` or more severe, which is `.warn` by default.

This client does not read `TYPESAFE_LOG_LEVEL`, the environment variable TypeSafe's official
Python and JavaScript SDKs use.

## Request ids

TypeSafe returns an id with each response in the `x-typesafe-request-id` header. Quote it, with
the model that answered, when contacting TypeSafe support. The client exposes it in four places:

| Where | When |
| --- | --- |
| `result.request_id` | after a successful `ask` or `askDynamic` |
| `models.request_id` | after a successful `listModels` |
| `diagnostics.request_id` | after any call, from the final response |
| `RequestEnd.request_id` | in the end hook, success or failure |

Each is `null` when no response arrived, such as after a connection failure or a timeout, or
when the response carried no id. The result's copy lives in its arena, so duplicate it before
`deinit` if you store it:

```zig
var result = try client.ask(text, questions, .{});
defer result.deinit();
const request_id = if (result.request_id) |id| try gpa.dupe(u8, id) else null;
```
