# Testing

Code that uses the client can be tested at two levels. Decision logic written as a pure function
of the answers struct needs no server at all. Code that makes the call runs against
`typesafe.testing.MockServer`, a loopback HTTP server that plays scripted replies and records the
requests it receives. Both run offline under `zig build test`, with answers you choose and no
mocking library.

## Testing decisions without a server

Keep the logic that turns answers into actions in a function that takes
`typesafe.Answers(@TypeOf(questions))`, and test it with answer structs you build by hand. Such
tests cover every threshold and branch, including rare confidence bands:

```zig
const std = @import("std");
const typesafe = @import("typesafe");

pub const Team = enum { billing, technical, sales };

pub const questions = .{
    .is_urgent = typesafe.noul("Does this convey urgency?", .{}),
    .department = typesafe.choice(Team, "Which team should handle this?", .{
        .billing = "Payments, invoicing, refunds",
        .technical = "Bugs, outages, integrations",
    }),
};

pub const Route = enum { page_on_call, team_queue, triage };

pub fn decide(answers: typesafe.Answers(@TypeOf(questions))) Route {
    const department = answers.department;
    if (department.confidence < 0.6 or department.margin() < 0.2) return .triage;
    if (answers.is_urgent.isYes(0.8)) return .page_on_call;
    return .team_queue;
}

pub fn routeTicket(client: *typesafe.Client, text: []const u8) typesafe.Error!Route {
    var result = try client.ask(.{ .ticket = text }, questions, .{});
    defer result.deinit();
    return decide(result.answers);
}

test "a split between two teams goes to triage" {
    try std.testing.expectEqual(Route.triage, decide(.{
        .is_urgent = .{ .noul = 0.97 },
        .department = .{
            .choice = .billing,
            .probabilities = .{ .billing = 0.52, .technical = 0.48, .sales = 0 },
            .confidence = 0.41,
        },
    }));
}
```

A `ScoreAnswer` literal needs `score`, `probabilities` and `confidence`. Its `legend` defaults to
nulls, so leave it out unless the code under test reads it. The
[Confidence guide](confidence.md) shows a larger router built the same way.

## Setup

A test that makes calls creates a `MockServer`, points a client at `server.url()`, and scripts
one reply per request:

```zig
test "urgent tickets page the on-call" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const server: *typesafe.testing.MockServer = try .create(gpa, io);
    defer server.destroy();
    try server.enqueueAnswers(questions, .{
        .is_urgent = .{ .noul = 0.97 },
        .department = .{
            .choice = .billing,
            .probabilities = .{ .billing = 0.9, .technical = 0.1, .sales = 0 },
            .confidence = 0.85,
        },
    }, .{});

    var client: typesafe.Client = try .init(gpa, io, .{
        .api_key = "test",
        .base_url = server.url(),
        .retry = .disabled,
    });
    defer client.deinit();

    try std.testing.expectEqual(Route.page_on_call, try routeTicket(&client, "Payouts failing for 3 days!"));
}
```

- `std.testing.allocator` checks for leaks, so a test fails if a result is not freed. It is
  thread-safe, which the client and the server both need.
- `std.testing.io` is a `std.Io.Threaded`. The server runs its accept loop and each connection as
  concurrent tasks, so it needs an `Io` that supports concurrency.
- `api_key = "test"` is never checked. The key only goes to the loopback server.
- `.retry = .disabled` makes an error reply fail the call at once, instead of waiting out backoff
  delays. It matters for mistakes too: a request with no scripted reply gets a 500, which the
  default policy would retry twice.
- `defer` runs in reverse order, so the client is freed before the server is destroyed.
  `destroy` stops the server, closes open connections, and frees the recorded requests.

`MockServer` has no configuration of its own:

| Call | What it does |
| --- | --- |
| `create(gpa, io)` | starts a server on an ephemeral loopback port |
| `destroy()` | stops the server and frees everything |
| `url()` | the base URL to pass as `base_url`, such as `http://127.0.0.1:41234` |
| `enqueue(reply)` | adds any reply to the end of the script |
| `enqueueAnswers(questions, answers, options)` | adds a successful `ask` reply |
| `enqueueError(status, options)` | adds an API error reply |
| `requestCount()` | the number of requests received so far |
| `request(index)` | recorded request number `index`, starting at 0 |

Replies are consumed in order, one per request, whichever call makes it. A retried call consumes
one reply per attempt, and a request the client sends again on a new connection (see
[dropped connections](#scripting-retries-timeouts-and-dropped-connections)) consumes one more.

## Scripting answers

`enqueueAnswers` encodes answers the way the API sends them. Its `answers` argument has the type
`typesafe.Answers(@TypeOf(questions))`, so a renamed, added or retyped question is a compile
error in the test rather than a silent mismatch. Score legends are taken from the questions'
levels.

Set `confidence` to the value the code path under test needs. There is no placeholder: TypeSafe
does not publish how confidence is derived, and the mock does not guess.

The options set what the rest of the response carries, for code that logs or stores it:

| Option | Default |
| --- | --- |
| `model` | `"jev-test"` |
| `usage` | `.{ .input_tokens = 100, .output_tokens = 10 }` |
| `request_id` | `"req_mock"`, sent as `x-typesafe-request-id` |
| `delay` | `.zero`; wait this long before replying |

Answers you reuse across tests can live in a container-level constant. Give it a name other than
`answers` if a function in the same file has an `answers` parameter, because Zig rejects the
shadowing:

```zig
const billing_ticket: typesafe.Answers(@TypeOf(questions)) = .{
    .is_urgent = .{ .noul = 0.9 },
    .department = .{
        .choice = .billing,
        .probabilities = .{ .billing = 0.9, .technical = 0.1, .sales = 0 },
        .confidence = 0.85,
    },
};
```

## Scripting errors

`enqueueError` replies with a status and the body shape the API uses for authentication and
usage errors, `{"detail": {"error_type": ..., "message": ...}}`. Its options are `error_type`
(default `"api_error"`), `message` (`"mock error"`), `request_id` (`"req_mock"`) and
`retry_after_ms`, which sets the `retry-after-ms` header:

```zig
try server.enqueueError(.too_many_requests, .{ .error_type = "rate_limit_error", .retry_after_ms = 1200 });

var diagnostics: typesafe.Diagnostics = .init(gpa);
defer diagnostics.deinit();
try std.testing.expectError(error.RateLimited, client.ask("Hello", questions, .{ .diagnostics = &diagnostics }));
try std.testing.expectEqual(1200, diagnostics.retry_after_ms.?);
try std.testing.expectEqualStrings("rate_limit_error", diagnostics.error_type.?);
```

For any other reply, `enqueue` takes a `MockServer.Reply`:

| Field | Default | Use |
| --- | --- | --- |
| `status` | `.ok` | any `std.http.Status`, such as `@enumFromInt(422)` |
| `body` | `""` | the response body, copied |
| `headers` | none | extra response headers, such as `retry-after` |
| `content_type` | `"application/json"` | the `content-type` header |
| `delay` | `.zero` | wait this long before replying |
| `drop` | `false` | close the connection without replying |
| `read_body` | `true` | `false` leaves the request body unread and closes the connection after `delay` without replying, like a server that stops reading mid-upload; the recorded body is empty |
| `truncate_body_to` | `null` | send only this many body bytes, with a `content-length` for the whole body, then close the connection |
| `close_after` | `false` | close the connection right after replying, although the reply allows keep-alive, like a server whose idle timeout expired |

```zig
try server.enqueue(.{
    .status = @enumFromInt(422),
    .body =
    \\{"detail":[{"loc":["body","questions"],"msg":"Field required"}]}
    ,
});
try std.testing.expectError(error.Unprocessable, client.ask("Hello", questions, .{ .diagnostics = &diagnostics }));
try std.testing.expectEqualStrings("questions: Field required", diagnostics.message.?);
```

## Scripting retries, timeouts and dropped connections

To test retries, build a client with retries on and no backoff. When a scripted error carries
`retry_after_ms`, also set `.respect_retry_after = false`, or the client waits that long:

```zig
try server.enqueueError(@enumFromInt(529), .{ .error_type = "overloaded_error" });
try server.enqueueAnswers(questions, billing_ticket, .{});

var client: typesafe.Client = try .init(gpa, io, .{
    .api_key = "test",
    .base_url = server.url(),
    .retry = .{ .backoff_initial_ms = 0 },
});
defer client.deinit();

var result = try client.ask("Hello", questions, .{});
defer result.deinit();
try std.testing.expectEqual(2, result.attempts);
```

A reply's `delay` longer than the client's `timeout` fails the attempt with `error.Timeout`, and
`drop` fails it with `error.ConnectionFailed`. Both errors are retryable, so with retries on, the
client moves on to the next scripted reply. With retries off, each call sees its error:

```zig
try server.enqueueAnswers(questions, billing_ticket, .{ .delay = .fromSeconds(5) });
try server.enqueue(.{ .drop = true });

var client: typesafe.Client = try .init(gpa, io, .{
    .api_key = "test",
    .base_url = server.url(),
    .timeout = .fromMilliseconds(100),
    .retry = .disabled,
});
defer client.deinit();

try std.testing.expectError(error.Timeout, client.ask("Hello", questions, .{}));
try std.testing.expectError(error.ConnectionFailed, client.ask("Hello", questions, .{}));
```

The timeout needs an `Io` with concurrency, which `std.testing.io` has. `destroy` cancels a reply
that is still waiting out its delay, so a long delay does not slow down the end of the test.

The timed-out attempt closes its connection, so the `drop` above arrives on a new one. A failure
on a pooled keep-alive connection is different: the client takes it for a connection the server
closed while idle and sends the request again at once on a new connection, without counting an
attempt. So a `drop` reply that lands on a reused connection does not fail the call. The request
is recorded twice and consumes the next scripted reply too. `close_after` tests that case
deliberately:

```zig
try server.enqueue(.{ .body = "{\"models\":[]}", .close_after = true });
try server.enqueueAnswers(questions, billing_ticket, .{});

var models = try client.listModels(.{});
models.deinit();

// The server closed the pooled connection; the call still succeeds on its first attempt.
var result = try client.ask("Hello", questions, .{});
defer result.deinit();
try std.testing.expectEqual(1, result.attempts);
```

`truncate_body_to` cuts a response short, which fails the attempt with a retryable
`error.ConnectionFailed` whose diagnostics `cause` is `error.ResponseTruncated`:

```zig
try server.enqueue(.{ .body = "{\"models\":[]}", .truncate_body_to = 5 });
try std.testing.expectError(error.ConnectionFailed, client.listModels(.{ .diagnostics = &diagnostics }));
try std.testing.expectEqual(error.ResponseTruncated, diagnostics.cause.?);
```

`read_body = false` with a `delay` longer than the timeout, and a request body larger than the
socket buffers, tests a call that times out while still sending.

## Asserting on requests

The server records every request: `method`, `target` (the path), `headers` and `body`.
`header(name)` looks a header up without regard to case. Parse the body to check the state and
questions your code built:

```zig
try std.testing.expectEqual(1, server.requestCount());
const request = server.request(0);
try std.testing.expectEqual(std.http.Method.POST, request.method);
try std.testing.expectEqualStrings("/v1/systemone", request.target);
try std.testing.expectEqualStrings("Bearer test", request.header("authorization").?);

const body = try std.json.parseFromSlice(std.json.Value, gpa, request.body, .{});
defer body.deinit();
const state = body.value.object.get("state").?;
try std.testing.expectEqualStrings("The API returns 500 on every request.", state.object.get("ticket").?.string);
try std.testing.expectEqualStrings("jev-latest", body.value.object.get("model").?.string);
```

Retried attempts carry an `x-typesafe-retry-count` header, so after one retry
`server.request(1).header("x-typesafe-retry-count")` is `"1"`. Recorded requests stay valid until
`destroy`.

`GET /v1/models` works the same way: `enqueue` a reply whose body is
`{"models": [{"name": ..., "description": ..., "release_date": ...}]}` and call
`client.listModels(.{})`.

## Live tests

The library's own live tests make real, billable requests to api.typesafe.ai. `zig build test`
never runs them:

```sh
TYPESAFE_API_KEY=... zig build test-live
```

For live tests of your own, keep them in a separate build step, and read the key from the
environment with `std.testing.environ`:

```zig
fn liveClient() !typesafe.Client {
    const gpa = std.testing.allocator;
    var environ_map = try std.testing.environ.createMap(gpa);
    defer environ_map.deinit();
    return typesafe.Client.initFromEnv(gpa, std.testing.io, &environ_map, .{});
}
```

`initFromEnv` fails with `error.MissingApiKey` when `TYPESAFE_API_KEY` is unset or blank. The
environment is read at run time, so set `has_side_effects = true` on the step's `Run` so the build
system never serves a cached result, as this repository's `build.zig` does. Assert on shapes and
ranges rather than exact probabilities, which can shift between model versions.
