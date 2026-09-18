# typesafe.zig

Zig client for TypeSafe's [System One API](https://docs.typesafe.ai/concepts/system-one) and its
Jev model. Ask typed Noul, Choice and Score questions about your application's state in one
request, and get back a struct of answers whose types come from your questions at compile time.

This is an unofficial community client. It is not an official TypeSafe SDK, and it is not
affiliated with or endorsed by TypeSafe.

```zig
const std = @import("std");
const typesafe = @import("typesafe");

const Team = enum { billing, technical, sales };

const questions = .{
    .is_urgent = typesafe.noul("Does this convey urgency?", .{
        .yes = "Explicitly time-sensitive",
        .no = "No urgency expressed",
    }),
    .department = typesafe.choice(Team, "Which team should handle this?", .{
        .billing = "Payments, invoicing, refunds",
        .technical = "Bugs, outages, integrations",
    }),
    .frustration = typesafe.score("How frustrated is the customer?", .{ "Calm", "Frustrated", "Very angry" }),
};

pub fn main(init: std.process.Init) !void {
    var client: typesafe.Client = try .initFromEnv(init.gpa, init.io, init.environ_map, .{});
    defer client.deinit();

    var result = try client.ask("Help! My payouts have been failing for 3 days.", questions, .{});
    defer result.deinit();

    const answers = result.answers;
    _ = answers.is_urgent.noul; //                     f64: 0.95
    _ = answers.department.choice; //                  Team: .billing
    _ = answers.department.probabilities.technical; // f64: 0.12
    _ = answers.department.confidence; //              f64: 0.79
    _ = answers.frustration.score; //                  f64: 1.04
    _ = answers.frustration.probabilities[2]; //       f64: 0.04
}
```

The client returns judgments as data. Thresholds and policy stay in your code.

Nothing on this side of the wire is stringly typed. A Choice answer's `choice` is your enum,
its probabilities are a struct with one `f64` per tag, and a Score answer's probabilities are a
`[3]f64`. A misspelled question id, an option that is not in the enum, or a Score with one level
is a compile error.

## Contents

- [Installation](#installation)
- [Questions](#questions)
- [What you get back](#what-you-get-back)
- [Configuration](#configuration)
- [Errors and diagnostics](#errors-and-diagnostics)
- [Retries and timeouts](#retries-and-timeouts)
- [Concurrency](#concurrency)
- [Questions defined at run time](#questions-defined-at-run-time)
- [Observability](#observability)
- [Testing your code](#testing-your-code)
- [Guides and examples](#guides-and-examples)
- [Development](#development)

## Installation

Requirements: Zig 0.16.0 or later. The package uses the standard library only (`std.http`,
`std.json`, `std.Io`), with no C dependencies, so it cross-compiles like any Zig code.

```sh
zig fetch --save git+https://github.com/mattneel/typesafe.zig#v0.1.0
```

```zig
// build.zig
const typesafe = b.dependency("typesafe", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("typesafe", typesafe.module("typesafe"));
```

Get an API key from the [TypeSafe quick start](https://docs.typesafe.ai/introduction/quickstart)
and export it as `TYPESAFE_API_KEY`.

## Questions

A question is a small, focused judgment about the state you send. Build questions with the three
constructors and put them in a struct literal. Its field names are the question ids, and the
answers come back under the same names. The ids are not shown to the model, so write the whole
question in the instructions.

| Primitive | Build with | Criteria | Answer |
| --- | --- | --- | --- |
| [Noul](https://docs.typesafe.ai/primitives/noul) | `typesafe.noul(instructions, criteria)` | `.{}`, or `.yes` and `.no` descriptions | `NoulAnswer`: probability of yes |
| [Choice](https://docs.typesafe.ai/primitives/choice) | `typesafe.choice(Enum, instructions, descriptions)` | the enum's tags, each optionally described | `ChoiceAnswer(Enum)`: top option, probabilities, confidence |
| [Score](https://docs.typesafe.ai/primitives/score) | `typesafe.score(instructions, levels)` | an ordered tuple or array of at least two levels | `ScoreAnswer(N)`: weighted score, probabilities, confidence |

```zig
const Tone = enum { calm, frustrated, hostile, other };

const questions = .{
    // Noul: yes/no. Criteria are optional.
    .wants_refund = typesafe.noul("Does the customer request a refund?", .{}),

    // Choice: options are the enum's tags, sent in declaration order. Options left out of the
    // descriptions struct are sent without a description.
    .tone = typesafe.choice(Tone, "What is the tone of the message?", .{
        .hostile = "Insults, threats or strong language",
        .other = "None of the above",
    }),

    // Score: a level's position is its value, so this score runs from 0 to 2.
    .effort = typesafe.score("How much agent effort does this ticket need?", .{ "None", "Low", "High" }),
};
```

Option names that are not Zig identifiers use `@"..."` tags, such as
`enum { @"Home & Kitchen", @"Sporting Goods" }`. Option order is part of what the model reads, so
keep an enum's order stable between calls whose answers you compare.

### Structured JSON

State, instructions, descriptions, levels and criteria all accept JSON structure, which is sent
as JSON objects and arrays, never stringified. Anything `std.json` can write works: struct
literals, tuples, slices, your own structs, `std.json.Value`, and `typesafe.RawJson` for
pre-encoded text. See [State](https://docs.typesafe.ai/concepts/state) and
[Advanced: structure](https://docs.typesafe.ai/primitives/advanced).

```zig
const state = .{
    .ticket = .{ .subject = "Duplicate charge", .text = "I was charged twice for order A-104." },
    .refund_policy = "Duplicate charges are eligible for a refund.",
};

const Resolution = enum { refund, investigate, reply_only };

const questions = .{
    .policy_supports_refund = typesafe.noul("Does `refund_policy` support a refund for `ticket.text`?", .{}),
    .resolution = typesafe.choice(Resolution, .{
        .task = "Pick the resolution for this ticket",
        .constraints = .{"Follow `refund_policy`"},
    }, .{
        .refund = .{ .action = "Refund the duplicate charge", .requires = .{ "a duplicate charge", "the policy allows it" } },
        .investigate = .{ .action = "Send to the payments team" },
    }),
    .effort = typesafe.score("How much agent effort does this ticket need?", .{
        .{ .level = "none", .example = "An automated reply" },
        .{ .level = "low", .example = "One action in the admin panel" },
        .{ .level = "high", .example = "An investigation across systems" },
    }),
};

var result = try client.ask(state, questions, .{});
```

Values can be known at run time: any field of a struct literal can hold a runtime string or
number. Only the shape of the questions (ids, enum options, level count) must be known at compile
time. When even that comes from data, use [dynamic questions](#questions-defined-at-run-time).

The client validates what it encodes before sending, including the contents of a
`std.json.Value`. A string that is not valid UTF-8, a NaN or infinite float, invalid `RawJson`,
nesting deeper than 256 levels, a state that is not a string, object or array, a Noul whose
instructions and criteria all turn out empty at run time, or a `null` Score level fails with
`error.InvalidRequest`, and the diagnostics name the offending path, such as
`state.ticket.text`. The one exception is any other type with a `jsonStringify` method, such as
one of your own: the client writes it with that method, unchecked. See the
[Questions guide](docs/guides/questions.md) for how to have such a type checked too.

## What you get back

`client.ask` returns a `typesafe.Result(@TypeOf(questions))`. Call `deinit` to free it.

| Field | Type | Meaning |
| --- | --- | --- |
| `answers` | `typesafe.Answers(@TypeOf(questions))` | one typed answer per question, under the same field names |
| `model` | `[]const u8` | the concrete model that answered, such as `jev-1.13.0`, even when you asked for `jev-latest` |
| `usage` | `typesafe.Usage` | `input_tokens` and `output_tokens`, each `?u64` |
| `request_id` | `?[]const u8` | the `x-typesafe-request-id` header; quote it when contacting support |
| `attempts` | `u32` | attempts made, including the first |
| `body` | `[]const u8` | the response body as the server sent it, for fields this version does not know |

| Answer | Fields | Helpers |
| --- | --- | --- |
| `NoulAnswer` | `noul: f64` | `isYes(threshold)` |
| `ChoiceAnswer(E)` | `choice: E`, `probabilities` (one `f64` field per tag), `confidence: f64` | `probability(tag)`, `ranked()`, `margin()` |
| `ScoreAnswer(N)` | `score: f64`, `probabilities: [N]f64`, `confidence: f64`, `legend: [N]std.json.Value` | `probability(level)`, `expectedLevel()`, `maxLevel()`, `ranked()` |

`ranked()` returns a fixed-size array sorted from most to least likely, `margin()` is the top
probability minus the second (rounded to 10 decimal places, so 0.3 minus 0.2 is exactly 0.1),
`expectedLevel()` rounds the score to the nearest level, and
`maxLevel()` is the most likely level. See the [Confidence guide](docs/guides/confidence.md) for
how to turn these into decisions.

Noul and Choice answers, and a Score answer's `score`, `probabilities` and `confidence`, are plain
numbers and enums: copy them out and keep them after `deinit`. Everything that points into
memory lives in the result's arena and is freed by `deinit`: `model`, `request_id`, `body`, and a
Score answer's `legend`.

Decoding is strict about what the client relies on and lenient about everything else. Every
question must come back with an answer of its type, and probabilities must lie between 0 and 1.
Answers you did not ask for and fields this version does not know are ignored, so a newer server
never breaks an older client.

## Configuration

A client holds its configuration and a keep-alive connection pool. Build one per program and
share it. After its first request a client must not be moved or copied, because open connections
point back at it, so keep it in a `var` and pass `*Client`.

```zig
// Explicit options
var client: typesafe.Client = try .init(gpa, io, .{
    .api_key = key,
    .model = "jev-preview",
    .timeout = .fromSeconds(20),
    .retry = .{ .max_retries = 4, .budget_ms = 60_000 },
    .extra_headers = &.{.{ .name = "x-team", .value = "support" }},
});

// Or resolved from the environment: explicit option, then TYPESAFE_* variable, then default.
var client: typesafe.Client = try .initFromEnv(init.gpa, init.io, init.environ_map, .{});
```

| Option | Env var (`initFromEnv`) | Default | Description |
| --- | --- | --- | --- |
| `api_key` | `TYPESAFE_API_KEY` | required | Sent as `Authorization: Bearer <key>`. Missing: `error.MissingApiKey` at init, never at request time. |
| `base_url` | `TYPESAFE_BASE_URL` | `https://api.typesafe.ai` | An `http` or `https` URL, optionally with a path prefix. No credentials, query or fragment. The host cannot be an IPv6 literal such as `[::1]`, which `std.http.Client` 0.16 cannot connect to, or longer than 255 bytes. |
| `model` | `TYPESAFE_DEFAULT_MODEL` | `jev-latest` | `jev-preview` is also available; `client.listModels` lists them. |
| `timeout` | | 10 s | Limit for each attempt: connect, TLS handshake, send and receive. `null` or `Io.Duration.max` disables it. At most `Client.max_timeout` (one year). |
| `retry` | | `Retry{}` | See [Retries and timeouts](#retries-and-timeouts). |
| `max_response_bytes` | | 16 MiB | A larger body fails with `error.ResponseTooLarge`. |
| `extra_headers` | | none | Added to every request. Headers the client sets itself are rejected with `error.ReservedHeader`. |
| `hooks` | | none | See [Observability](#observability). |

Blank environment values are ignored. `init` performs no I/O, and every invalid option is an
`InitError` (`InvalidBaseUrl`, `InvalidApiKey`, `InvalidHeader`, ...). `gpa` must be thread-safe,
as `std.http.Client` requires; `init.gpa` in a `std.process.Init` main is.

Each call takes options that override the client's for that call: `model`, `timeout`, `retry`,
`extra_headers`, plus `diagnostics` and `user_data`. An unset (`null`) per-call option uses the
client's value; to turn the timeout off for one call, pass `.timeout = .max`. An invalid per-call
option, such as an empty `model`, a reserved header or a timeout above `Client.max_timeout`,
fails the call with `error.InvalidOption`, and the diagnostics `path` names the option.

```zig
var result = try client.ask(state, questions, .{ .model = "jev-preview", .retry = .disabled });
```

For tuning the client does not wrap, such as `connection_pool.free_size`, `client.http` is the
underlying `std.http.Client`. Do not give it an HTTPS proxy: `std.http.Client` in Zig 0.16 does
not run TLS inside a proxy tunnel, so the API key would travel in plaintext. While
`client.http.https_proxy` is set and the base URL is `https`, every call fails with
`error.InvalidOption` and the diagnostics `path` is `base_url`. Each attempt also refuses to send
over a connection that is not TLS or that goes through a proxy.

The client identifies itself with `User-Agent` and `X-TypeSafe-SDK: typesafe-zig/<version>`
and `X-TypeSafe-Runtime: zig/<version> (<os>; <arch>)`, the header format TypeSafe's official
SDKs use, under its own name. Redirects are never followed, so the API key only goes to the
base URL's host.

`std.http.Client` reads the clock and the system's root certificates once, at its first HTTPS
request, and checks every later certificate against them. A long-running client reloads both
before an HTTPS request once they are an hour old, so a certificate issued after the client
started is accepted and one that has since expired is not. That refresh reads `std.http.Client`
fields std does not promise to keep; build with `-Dtls-trust-refresh=false` (or
`.tls_trust_refresh = false` through `b.dependency`) to leave it out and stay on std's supported
surface.

## Errors and diagnostics

Every call returns `typesafe.Error`. Zig errors carry no payload, so pass a `Diagnostics` to get
the details behind one:

```zig
var diagnostics: typesafe.Diagnostics = .init(gpa);
defer diagnostics.deinit();

var result = client.ask(ticket.body, questions, .{ .diagnostics = &diagnostics }) catch |err| switch (err) {
    error.RateLimited, error.Overloaded => return scheduleRetry(ticket, diagnostics.retry_after_ms),
    // A bug in how the request was built: fail loudly.
    error.InvalidRequest, error.BadRequest, error.Unprocessable => {
        std.log.err("{f}", .{diagnostics});
        return err;
    },
    else => {
        std.log.warn("{f}", .{diagnostics});
        return sendToReviewQueue(ticket);
    },
};
defer result.deinit();
```

`{f}` renders one log-ready line:

```text
BadRequest (HTTP 400): Unknown model: jev-0.0.1 [POST https://api.typesafe.ai/v1/systemone, request_id: req_01a0ad38e5c7716995a9123a240934ac]
```

| Error | Trigger | Retried by default |
| --- | --- | --- |
| `InvalidRequest` | The request could not be encoded (invalid UTF-8, NaN, invalid or too deep `RawJson`, an empty Noul, a `null` Score level, a state that is not a string, object or array) | no |
| `InvalidOption` | A per-call option is invalid (an empty model, a reserved header, a timeout above `Client.max_timeout`, an HTTPS base URL with a proxy); the diagnostics `path` names the option | no |
| `BadRequest` | HTTP 400, such as an unknown model | no |
| `Unauthorized` | HTTP 401 | no |
| `PermissionDenied` | HTTP 403 | no |
| `NotFound` | HTTP 404 | no |
| `RequestTimeout` | HTTP 408 | yes |
| `Unprocessable` | HTTP 422; the message names the field | no |
| `RateLimited` | HTTP 429 | yes |
| `Overloaded` | HTTP 529 | yes |
| `ServerError` | Any other 5xx | yes |
| `UnexpectedStatus` | Any other non-2xx, including redirects | no |
| `ConnectionFailed` | DNS, connect, reset, a malformed HTTP response, or a body cut short by a closed connection | yes |
| `TlsFailure` | TLS handshake or certificate loading | yes |
| `Timeout` | An attempt exceeded the timeout | yes |
| `InvalidResponse` | A 2xx body that does not match the API schema, or a body in an unsupported content encoding | no |
| `ResponseTooLarge` | The body exceeded `max_response_bytes` | no |
| `Canceled` | The calling task was canceled | no |
| `OutOfMemory` | An allocation failed | no |

`Diagnostics` fields: `err`, `method`, `url`, `status`, `request_id`, `error_type` (such as
`authentication_error`), `message`, `body`, `path` (such as `answers.tone.confidence`),
`retry_after_ms`, `attempts`, and `cause`, the underlying error behind a transport failure, such
as `error.ConnectionRefused`. A call resets them when it starts. On failure they describe the
final attempt. After a success, `err`, `message`, `body`, `path`, `error_type`, `retry_after_ms`
and `cause` are `null`, `status` and `request_id` describe the successful response, and
`attempts` counts every attempt.

## Retries and timeouts

The default policy matches TypeSafe's official Python and JavaScript SDKs: 2 retries after the
first attempt, exponential backoff from 500 ms to a 5 s cap with up to 25% jitter, retries on
408, 429 and every 5xx (including 529 Overloaded) plus connection failures, TLS failures and
timeouts,
`retry-after-ms` and `Retry-After` honoured (up to 60 s), and a 30 s budget for the whole call.
Retried attempts carry `X-TypeSafe-Retry-Count`. Retrying a `POST` is safe because asking
questions has no side effects.

```zig
.retry = .{ .max_retries = 4, .budget_ms = 60_000 }, // per client
.retry = .disabled,                                   // per call
```

To choose which HTTP error statuses are retried, set `isRetryableStatus`. It replaces the
default list for non-2xx responses; transport errors still follow `retry_transport_errors`:

```zig
fn retryable(status: std.http.Status) bool {
    return status != .not_implemented and typesafe.Retry.isRetryableStatusByDefault(status);
}

.retry = .{ .isRetryableStatus = retryable },
```

For your own escalation logic, such as sending a case that still fails to a slower fallback,
`client.retry.isRetryable(err)` classifies an error the way the default status list and
`retry_transport_errors` do, and `client.retry.retriesStatus(status)` applies the policy's
`isRetryableStatus` to a status.

A pooled keep-alive connection that the server has closed is not a failed attempt. The client
sends the request again at once on another connection, without a delay and without counting an
attempt.

The `timeout` bounds each attempt from connect to the last byte of the response. It is enforced
by racing the request against a timer with `Io.Select`, and the losing request is canceled and
its connection closed. That needs an `Io` that can run tasks concurrently, such as
`std.Io.Threaded` (the default in `std.process.Init`). Without concurrency, requests run without
a timeout, and the client logs a warning. Canceling the task that called the client cancels the
request too, and the call returns `error.Canceled`.

## Concurrency

One request carrying many questions is the cheapest and fastest shape: the TypeSafe docs measure
a 13-question batch as 12.2× cheaper and 10× faster than separate calls. For the same questions
over many states, run the calls concurrently on one client and let the connection pool reuse
connections:

```zig
fn classify(client: *typesafe.Client, review: []const u8, out: *?typesafe.Answers(@TypeOf(questions))) std.Io.Cancelable!void {
    var result = client.ask(review, questions, .{}) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => return,
    };
    defer result.deinit();
    out.* = result.answers;
}

var group: std.Io.Group = .init;
defer group.cancel(io);
for (reviews, outputs) |review, *out| try group.concurrent(io, classify, .{ &client, review, out });
try group.await(io);
```

A `Client` is safe to share between tasks and threads. See the
[Concurrency guide](docs/guides/concurrency.md) and `examples/batch.zig`.

## Questions defined at run time

When the options or levels are not known at compile time, such as a taxonomy loaded from a
database, build `typesafe.dynamic.Question` values and call `askDynamic`. Answers come back keyed
by id and option name strings, and the questions are validated at run time instead.

```zig
const dynamic = typesafe.dynamic;

const questions = [_]dynamic.Question{
    .noul("is_urgent", "Does this convey urgency?"),
    .choice("department", "Which department should handle this?", .{ .names = department_names }),
    .score("frustration", "How frustrated is the customer?", .{ .text = &.{ "Calm", "Frustrated", "Very angry" } }),
};

var result = try client.askDynamic(ticket_text, &questions, .{});
defer result.deinit();

const department = result.get("department").?.choice;
std.log.info("{s} ({d:.2})", .{ department.choice, department.probability(department.choice).? });
```

Instructions, descriptions, criteria, `.json` levels and extra field values take a
`dynamic.Json`: `.null`, `.{ .string = ... }`, `.{ .value = std.json.Value }` or
`.{ .raw = "{...}" }`. An invalid set of questions (none, a duplicate id, a Choice without
options, a Score with fewer than two levels, a level that is not a string, object or array) fails
with `error.InvalidRequest` before anything is sent, and the diagnostics name the question. See
`examples/dynamic.zig`.

## Observability

`Client.Options.hooks` takes function pointers called when a call starts, before each retry, and
when it ends. The end event carries the operation, status, request id, attempt count, duration,
token usage and error, so a metrics library or tracer can attach without the client knowing
about it:

```zig
fn onRequestEnd(context: ?*anyopaque, event: *const typesafe.hooks.RequestEnd) void {
    const metrics: *Metrics = @ptrCast(@alignCast(context.?));
    metrics.record(event.operation, event.duration, event.attempts, event.err);
}

var client: typesafe.Client = try .init(gpa, io, .{
    .api_key = key,
    .hooks = .{ .context = &metrics, .onRequestEnd = onRequestEnd },
});
```

The client also logs through `std.log.scoped(.typesafe)`. Retries, retries skipped because of the
budget, and schema mismatches are logged at `.debug`, which Debug builds print by default; in
release builds, raise the `.typesafe` scope with `std_options.log_scope_levels`. Requests sent
without the timeout because the `Io` cannot run a task or timer concurrently, and a failure to
reload the system root certificates, are logged at `.warn`. See the
[Observability guide](docs/guides/observability.md).

## Testing your code

`typesafe.testing.MockServer` is a loopback HTTP server that plays scripted replies and records
requests, so code that uses the client can be tested offline, with no mocking library:

```zig
test "urgent billing tickets page the on-call" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const server: *typesafe.testing.MockServer = try .create(gpa, io);
    defer server.destroy();
    try server.enqueueAnswers(questions, .{
        .is_urgent = .{ .noul = 0.97 },
        .department = .{ .choice = .billing, .probabilities = .{ .billing = 0.9, .technical = 0.1, .sales = 0 }, .confidence = 0.85 },
        .frustration = .{ .score = 1.2, .probabilities = .{ 0.1, 0.6, 0.3 }, .confidence = 0.7 },
    }, .{});

    var client: typesafe.Client = try .init(gpa, io, .{ .api_key = "test", .base_url = server.url(), .retry = .disabled });
    defer client.deinit();

    try std.testing.expectEqual(.page_on_call, try routeTicket(&client, "Payouts failing for 3 days!"));
    try std.testing.expectEqualStrings("/v1/systemone", server.request(0).target);
}
```

`enqueueError` scripts API errors (with `retry_after_ms` for rate limits), and `enqueue` scripts
any reply, including delays that trip timeouts, dropped connections, request bodies left unread,
truncated bodies and connections closed after a reply. Decision logic written
as a pure function of the answers struct needs no server at all. See the
[Testing guide](docs/guides/testing.md).

## Guides and examples

- [Questions](docs/guides/questions.md): the three primitives, structure, ids, validation
- [Confidence](docs/guides/confidence.md): probabilities, confidence and thresholds in your code
- [Concurrency](docs/guides/concurrency.md): many questions per request, many requests at once
- [Testing](docs/guides/testing.md): `MockServer` and testing decision logic
- [Observability](docs/guides/observability.md): diagnostics, hooks and logging

Examples, each runnable with `zig build run -Dexample=<name>`:

- `route_ticket`: urgency, team and frustration with thresholds in code
- `structured`: invoice field verification with structured state, instructions and levels
- `batch`: many states concurrently on one client
- `dynamic`: a taxonomy loaded at run time
- `list_models`: the models available to your account

These pages are published together at <https://mattneel.github.io/typesafe.zig/>, built by
`book/build.sh`: the guides and the design notes as a book, with the API reference — generated
from the doc comments — at `/api/`. To read them locally, `zig build docs` serves the API
reference from `zig-out/docs` on its own.

## Development

```sh
zig build test                      # offline unit and integration tests
TYPESAFE_API_KEY=... zig build test-live   # live tests against api.typesafe.ai (billable)
zig build examples docs fmt         # examples, API reference, format check
zig build ci                        # every offline gate

book/build.sh                       # the documentation site into zig-out/site
mdbook serve zig-out/book-src       # preview the book while editing (run build.sh once first)
```

The book's chapters are this README, the guides, the design notes, the changelog and the release
checklist, so there is no second copy of anything to keep in step. A push to `master` that
touches them publishes the site; `book/build.sh` is the whole of that build.

Links: [TypeSafe documentation](https://docs.typesafe.ai) ·
[HTTP API reference](https://docs.typesafe.ai/api) · [Changelog](CHANGELOG.md) ·
[Elixir client](https://github.com/mattneel/typesafe)

## License

MIT. See the `LICENSE` file.
