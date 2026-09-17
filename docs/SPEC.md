# typesafe.zig — package spec

Status: implemented in v0.1.0 (unreleased) · Last updated 2026-09-17 · Repo: `mattneel/typesafe.zig` · Zig 0.16.0

This file started as the design draft for the package. It now describes the package as built:
every claim below is checked against the source, the offline suite, and live traffic against
`api.typesafe.ai`. Where the built client settled on something other than the draft, this file
states what it does and why.

## Summary

`typesafe.zig` is a Zig 0.16.0 client for TypeSafe's System One API (the Jev model). Questions
are Zig values: a `noul`, a `choice` over an enum you define, a `score` over a fixed list of
levels. One `ask` sends them with your state and returns a struct whose fields are typed answers:
the Choice answer *is* your enum, its probabilities are a struct with one `f64` per enum tag, the
Score answer carries a fixed-size probability array. Nothing is stringly typed on this side of
the wire. The package uses the standard library only: `std.http.Client`, `std.json`, `std.Io`.

The core was built and validated on Zig 0.16.0: comptime answer-type generation with `@Struct`,
byte-for-byte wire encoding against the request fixtures shared with the Elixir client, decoding
through a path-tracking decoder, a loopback `std.http.Server` stub (`typesafe.testing.MockServer`)
driven by `std.testing.io`, and live HTTPS traffic against api.typesafe.ai. Two things only showed
up under test (a TLS flush gotcha and `io.async` versus `io.concurrent`); they are called out
where they apply.

Beyond the core, 0.1.0 ships the pieces the workflow needs: questions defined at run time
(`typesafe.dynamic`), observability callbacks (`typesafe.hooks`), a public loopback server for
downstream tests (`typesafe.testing`), and the guides under `docs/guides/`.

Design principles:

- Code owns the workflow. The client returns judgments as data (probabilities, distributions,
  confidence); thresholds and policy stay in the caller's code.
- Types come from the caller. Questions are comptime values and the answer struct is derived from
  them, so a misspelled question name, a missing level or an unknown option is a compile error
  rather than a runtime surprise.
- Explicit allocator and `Io`, passed in. No globals, no hidden threads, no process state; the
  client is one struct.
- Standard library only. Zig has no package registry, every dependency is a hash the user has to
  trust, and `std` already covers HTTPS, JSON and concurrency.
- Small surface, in layers: the five entry points (`Client.init`, `initFromEnv`, `deinit`, `ask`,
  `listModels`) plus three question constructors cover the API; `askDynamic`, `hooks` and
  `testing` are separate opt-in modules that the core does not depend on. Anything the API does
  not have a use for yet is left out rather than stubbed.

Naming: repo `mattneel/typesafe.zig`, package name `.typesafe` in `build.zig.zon`, module
`typesafe` (`@import("typesafe")`). The `.zig` suffix is a repo convention; the package name drops
it, as `zig init` recommends. The client identifies itself as `typesafe-zig/<version>`: it sends
the same header set, in the same format, as TypeSafe's official SDKs, under its own name, so its
traffic is not attributed to them.

## API surface the client covers

One endpoint does the work: `POST https://api.typesafe.ai/v1/systemone` takes `state`, `model` and
a `questions` map and returns one answer per question id, plus `usage`
([HTTP API reference](https://docs.typesafe.ai/api.md)). A second, `GET /v1/models`, returns
`{"models": [{"name", "description", "release_date"}]}`; it is missing from the HTTP reference but
both of TypeSafe's own SDKs call it, per the path constants in
[typesafe-sdk 0.6.0](https://pypi.org/project/typesafe-sdk/) and
[@typesafe-ai/sdk 0.6.0](https://www.npmjs.com/package/@typesafe-ai/sdk).

| Field | Request | Response |
| --- | --- | --- |
| `state` | string, object or array; the content to judge | not echoed |
| `model` | string, default `jev-latest` | string, model that answered |
| `questions` | map of caller-chosen id to Question; ids are not sent to the model | `answers`: same ids to Answer |
| `usage` | n/a | `input_tokens`, `output_tokens` (integers, may be absent) |

The three question types and their answers
([primitives](https://docs.typesafe.ai/primitives.md)):

| Type | `instructions` | `criteria` | Answer fields |
| --- | --- | --- | --- |
| `noul` | string, object or array | optional `{true, false}` descriptions | `noul` float 0 to 1 |
| `choice` | string, object or array | required map of option to description or `null` | `choice` (top option), `probabilities` map summing to 1, `confidence` 0 to 1 |
| `score` | string, object or array | required ordered array of at least 2 levels | `score` float (may land between levels), `legend` map `"0"`.. to level text, `probabilities` keyed by level string, `confidence` 0 to 1 |

Wire details the package honours:

- Every `instructions` value, Choice option description, Score level and Noul `true`/`false` entry
  accepts JSON structure: string, object, array or null
  ([advanced structure](https://docs.typesafe.ai/primitives/advanced.md)). In Zig this is any value
  the package's encoder can write — a struct literal, a tuple, a slice, a `std.json.Value`, a
  `typesafe.RawJson` — plus `null`. Booleans and bare numbers are rejected, at compile time where
  the type is known and at run time where it is not.
- Auth is `Authorization: Bearer <key>`; the response carries `x-typesafe-request-id`, which the
  vendor SDKs surface on every response and error
  ([exceptions](https://docs.typesafe.ai/sdk/python/api/exceptions.md)). This client exposes it as
  `Result.request_id`, `Models.request_id` and `Diagnostics.request_id`.
- Identification headers, in the format both vendor SDKs use, under this package's own name:
  `User-Agent: typesafe-zig/<version>`, `X-TypeSafe-SDK: typesafe-zig/<version>`,
  `X-TypeSafe-Runtime: zig/<version> (<os>; <arch>)`, `X-TypeSafe-Retry-Count: <n>` on every
  retried attempt, and `Accept: application/json`. A request with a body also sends
  `Content-Type: application/json`.
- Defaults ([constants](https://docs.typesafe.ai/sdk/python/api/constants.md)): base URL
  `https://api.typesafe.ai`, model `jev-latest`, 10 s per HTTP operation, env vars
  `TYPESAFE_API_KEY`, `TYPESAFE_BASE_URL`, `TYPESAFE_DEFAULT_MODEL`. Explicit options beat env
  vars, which beat defaults; blank env values are ignored. `TYPESAFE_LOG_LEVEL` is not mirrored:
  Zig programs set `std.options.log_level` and `log_scope_levels` instead.
- Documented errors: 401 (bad key), 422 (validation, body names the offending field), 429 (rate
  limit), 529 (overloaded). The vendor SDKs also map 400, 403, 404 and other 5xx, and read
  `Retry-After` and `retry-after-ms`; this client maps the same set. Error body shape, verified
  with a live unauthenticated POST: `{"detail":{"error_type":"authentication_error","message":"..."}}`.
  FastAPI-style validation bodies (`{"detail":[{"loc":...,"msg":...}]}`) and `{"detail":"Not Found"}`
  are also understood, and the location segments are joined into a readable message.
- Retry policy ([retries](https://docs.typesafe.ai/sdk/python/api/retries.md)): 2 retries after the
  first attempt, backoff 0.5 s doubling to a 5 s cap with 25% jitter, retry on 408, 429 and 500 to
  599 plus connection and timeout errors, honour `Retry-After` (seconds, fractional seconds, or any
  of the three RFC 9110 date formats) and `retry-after-ms`, 30 s total budget per call. This client
  uses the same numbers so behaviour matches across languages, and refuses a server-requested delay
  longer than 60 s, falling back to backoff as the JavaScript SDK does.
- Client-side validation the vendor SDKs perform before sending: at least one question; Score
  criteria is a list of at least two entries. Here both are compile errors.
- Transport facts from the probe: api.typesafe.ai negotiates TLS 1.3 and answers HTTP/1.1;
  `std.http.Client` speaks HTTP/1.1 and TLS 1.2/1.3, so no extra layer is needed.

## Toolchain and dependencies

No third-party packages. The `build.zig.zon` `dependencies` table is empty and stays empty; every
capability below is `std` in Zig 0.16.0 (released 2026-04-13, the current stable as of this
writing per [ziglang.org/download](https://ziglang.org/download/)).

| Component | What it provides here | Notes |
| --- | --- | --- |
| Zig 0.16.0 | `std.Io` as an interface, `@Struct` and the other type-building builtins, `Io.net` without ws2_32 on Windows | `.minimum_zig_version = "0.16.0"`; nothing older is supported, the `Io` API alone rules that out |
| `std.http.Client` | HTTP/1.1 over TLS via `std.crypto.tls`, keep-alive connection pool (32 free connections by default), proxies | Thread-safe for opening connections; individual `Request`s are not, one per task. Exposed as `client.http` for tuning |
| `std.json` | `Stringify` for the encode side, `Value` plus a strict path-tracking decoder for the response side, `std.json.Value` for structured entries | The request body is built by the package's own validating `Encoder`, which wraps `Stringify` |
| `std.Io` | `Io.Threaded` for real programs, `std.testing.io` in tests, `io.concurrent`, `Io.Select`, `Io.Timeout`, `std.Random.IoSource` for retry jitter | Cancelation works through the same interface (`error.Canceled`) |
| `std.crypto.Certificate.Bundle` | System root certificates, rescanned on the client's first HTTPS request and hourly thereafter | Verified: the std TLS client completes the handshake with api.typesafe.ai |
| Dev tooling | `zig build test`, `zig build test --test-timeout 60s`, `zig build fmt`, autodoc via `Compile.getEmittedDocs` | CI uses [mlugg/setup-zig@v2](https://github.com/mlugg/setup-zig) |

Consumption:

```sh
zig fetch --save git+https://github.com/mattneel/typesafe.zig#v0.1.0
```

```zig
// build.zig
const typesafe = b.dependency("typesafe", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("typesafe", typesafe.module("typesafe"));
```

Considered and left out: libcurl or mbedTLS through `@cImport` (needs a C toolchain, breaks plain
`zig build` cross-compilation, and buys nothing since the std TLS handshake with the API works),
third-party HTTP or JSON packages (nothing `std` lacks for this API), a logging or metrics
dependency (a hooks struct plus `std.log.scoped(.typesafe)` covers it), HTTP/2 (the API accepts
HTTP/1.1; `std.http.Client` has no HTTP/2 and the API's JSON bodies are small).

## Package layout and public API

```
typesafe.zig/
├── build.zig               module, test step, live-test step, examples step, docs step, fmt, ci
├── build.zig.zon           .name = .typesafe, .version, .fingerprint, .minimum_zig_version = "0.16.0", .paths
├── src/
│   ├── typesafe.zig        root: re-exports Client, noul/choice/score, answer types, Error, Diagnostics, Retry, hooks, dynamic, testing
│   ├── Client.zig          Client struct: configuration, init, initFromEnv, deinit, ask, askDynamic, listModels, Result, Models
│   ├── request.zig         one Call per ask or listModels: validation, headers, the retry loop, the timeout race, the TLS refresh
│   ├── question.zig        Noul, Choice(Option), Score(levels), Answers(Questions) and the comptime checks
│   ├── answer.zig          NoulAnswer, ChoiceAnswer(Option), ScoreAnswer(levels) and their helpers
│   ├── wire.zig            encode request, decode response, error body parsing, test-response encoder
│   ├── json.zig            the validating Encoder, the streaming path-tracking Reader, RawJson, Failure
│   ├── Retry.zig           Retry policy struct, backoff and delay arithmetic, Retry-After parsing, retryable classification
│   ├── errors.zig          Error set, InitError set, status mapping
│   ├── Diagnostics.zig     Diagnostics struct, init/deinit/reset, `{f}` formatting
│   ├── hooks.zig           Hooks and the start, retry and end events
│   ├── dynamic.zig         questions built at run time (Question, Options, Levels, Json, Result)
│   ├── dynamic_wire.zig    encoding and decoding for dynamic questions
│   ├── testing.zig         MockServer: scripted replies and recorded requests
│   ├── client_test.zig     client integration tests against MockServer
│   ├── wire_test.zig       wire-format tests against the shared fixtures, encoder regressions
│   ├── oom_test.zig        allocation-failure and leak tests
│   └── testdata/           request and response fixtures shared with the Elixir client
├── tests/live.zig          smoke tests against api.typesafe.ai, skipped without TYPESAFE_API_KEY
├── examples/               route_ticket, structured, batch, dynamic, list_models
├── docs/guides/            questions, confidence, concurrency, testing, observability
├── README.md · CHANGELOG.md · RELEASING.md · LICENSE (MIT)
└── .github/workflows/ci.yml · live.yml
```

The main call, in the form the README opens with:

```zig
const std = @import("std");
const typesafe = @import("typesafe");

const Team = enum { billing, technical, sales };

pub fn main(init: std.process.Init) !void {
    var client: typesafe.Client = try .initFromEnv(init.gpa, init.io, init.environ_map, .{});
    defer client.deinit();

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

    var result = try client.ask("Help! My payouts have been failing for 3 days.", questions, .{});
    defer result.deinit();

    const a = result.answers;
    _ = a.is_urgent.noul;                          // f64, 0.95
    _ = a.is_urgent.isYes(0.5);                    // bool
    _ = a.department.choice;                       // Team.technical
    _ = a.department.probability(.technical);      // f64, 0.12
    _ = a.frustration.score;                       // f64, 1.04
    _ = a.frustration.probabilities[2];            // f64, 0.04
}
```

Public declarations:

| Declaration | Signature and rules |
| --- | --- |
| `Client.init(gpa, io, Options) InitError!Client` | Validates options, builds the `std.http.Client`, precomputes the identification headers. `Options.api_key` is required; `base_url`, `model`, `timeout`, `retry`, `max_response_bytes`, `extra_headers`, `hooks` have defaults |
| `Client.initFromEnv(gpa, io, environ_map, Options) InitError!Client` | Same, reading `TYPESAFE_API_KEY`, `TYPESAFE_BASE_URL` and `TYPESAFE_DEFAULT_MODEL` from a `*const std.process.Environ.Map` (`init.environ_map` in a `std.process.Init` main). Empty values count as unset. A missing key is `error.MissingApiKey` here, never at request time. The fourth parameter is the explicit options, which win over the environment |
| `Client.deinit(client)` | Closes pooled connections and frees the client. Every call must have returned |
| `Client.ask(client, state, questions, AskOptions) Error!Result(@TypeOf(questions))` | `state` is a string or anything the encoder writes as an object or array. `questions` is an anonymous struct literal; its field names are the question ids, echoed back as the answer field names. Per-call `AskOptions`: `model`, `timeout`, `retry`, `extra_headers`, `diagnostics: ?*Diagnostics`, `user_data` |
| `Client.askDynamic(client, state, questions: []const dynamic.Question, AskOptions) Error!dynamic.Result` | Questions built at run time; validated before sending, answered by id |
| `Client.listModels(client, ListModelsOptions) Error!Models` | `GET /v1/models` |
| `noul(instructions, criteria) Noul` | `criteria` is a struct literal with optional `.yes` and `.no` entries, sent as the wire's `true` and `false`; `.{}` for none. A Noul needs instructions or at least one criterion |
| `choice(comptime Options: type, instructions, descriptions) Choice(Options)` | `Options` must be an exhaustive enum with at least one tag, checked with `@compileError`; `descriptions` is a struct literal mapping some or all tags to descriptions, and tags left out are sent as `null` |
| `score(instructions, levels) Score(levels.len)` | `levels` is a tuple or array of at least two entries, known in length at compile time; fewer than two is a `@compileError`, and the answer type is sized by the level count |
| `Answers(Questions)` | The struct of typed answers, built with `@Struct` from the questions struct's field names and each question's `Answer` type |
| `NoulAnswer`, `ChoiceAnswer(Option)`, `ScoreAnswer(N)` | The three answer types, with the helper methods listed under "What you get back" in the README |
| `typesafe.RawJson` | Pre-encoded JSON text, sent verbatim after the encoder validates it (one value, at most 256 levels deep) |
| `Result(Questions)` | `answers`, `model`, `usage` (`?u64` token counts), `request_id`, `attempts`, `body: []const u8` (the response as the server sent it), an owning `std.heap.ArenaAllocator`, `deinit()` |
| `Models` | `models: []const Model`, `request_id`, `attempts`, `body`, an owning arena, `find(name)`, `deinit()` |
| `Retry` | Policy struct with the vendor defaults, plus `isRetryable`, `retriesStatus`, `isRetryableStatusByDefault`, `backoffMs`, `delayMs`, `nextDelayMs`, `parseRetryAfter` and `disabled`; see Client and transport |
| `Error`, `InitError`, `Diagnostics`, `errorFromStatus` | See Errors |
| `hooks.Hooks` | `context` plus `onRequestStart`, `onRetry`, `onRequestEnd` function pointers |
| `dynamic` | `Question`, `Options`, `Levels`, `Json`, `Result`; see README |
| `testing.MockServer` | Loopback server with scripted replies and recorded requests, for testing code that uses the client |

Every public declaration on the module root and on the exported types has a doc comment, so
`zig build docs` and `zig build test` cover the same surface.

## Questions, answers and the wire

The whole type story is a few comptime functions plus one encoder and one decoder. The shape the
implementation settled on:

```zig
/// The struct of typed answers with the same field names as the questions struct.
pub fn Answers(comptime Questions: type) type {
    const fields = comptime checkQuestions(Questions); // at least one, each a question
    var names: [fields.len][]const u8 = undefined;
    var types: [fields.len]type = undefined;
    for (fields, 0..) |field, i| {
        names[i] = field.name;
        types[i] = field.type.Answer;
    }
    return @Struct(.auto, null, &names, &types, &@splat(.{}));
}
```

`ChoiceAnswer(Option).probabilities` is `std.enums.EnumFieldStruct(Option, f64, null)`, one field
per tag; `ScoreAnswer(N).probabilities` is `[N]f64` and its `legend` is `[N]std.json.Value`, so a
`"0"`-keyed legend parses with no map allocation. Question values store their entries through
`Stored(T)`, which normalizes string literals to `[]const u8` so that question types stay small
and nameable, while any other type is kept as it is.

Rules:

- Encoding goes through the package's `json.Encoder`, a `std.json.Stringify` wrapper that tracks
  the path to the value it is writing and validates as it goes. Each question type writes `type`,
  `instructions` and `criteria` in the documented shape; Noul omits `criteria` when it has none;
  Choice writes one key per enum tag with its description or `null`; Score writes the level array.
  The suite checks the output byte-for-byte against the shared request fixtures.
- Decoding is one pass over the response bytes with a pull reader built on `std.json.Scanner`
  (`json.Reader`), which tracks the path to the value it is reading, so a failure names it. The
  `type` discriminator in each answer is checked against the question's kind, so a mismatched
  answer is caught rather than silently accepted. Answers the request did not ask for, and fields
  this version does not know, are skipped, so a newer server never breaks an older client.
  Strings and numbers point into the response body unless they contain escapes, in which case the
  arena owns them; the body itself is kept for the caller as `Result.body`. Keys may arrive in
  any order, and a key repeated in one object keeps its last value. A body that is not valid
  JSON, that ends early or that carries data past the document fails with `error.InvalidResponse`.
  The first problem in document order is the one reported.
- Score `legend` and `probabilities` arrive as objects keyed `"0"`, `"1"`, ...; they are read by
  key, so no map allocation is needed and a missing level is reported at
  `answers.<id>.probabilities.<n>`.
- Choice `probabilities` must carry an entry for every option: a probability the server omitted is
  `error.InvalidResponse` with `answers.<id>.probabilities.<tag>` as the path.
- Every probability is checked to lie between 0 and 1 as it is decoded; a value outside that range
  is `error.InvalidResponse`, not a silently accepted number.
- Keys round-trip by construction: question ids are struct field names and options are enum tags,
  so `result.answers.department.choice == .technical` and there is nothing to map back.
- Compile-time checks replace the vendor SDKs' runtime ones: no questions, a questions value that
  is not a struct literal, fewer than two Score levels, levels whose length is not compile-time
  known, a Choice over a non-enum, a non-exhaustive enum or an empty enum, a description for an
  option the enum does not have, a Noul criterion that is not `.yes` or `.no`, and an entry that
  is a boolean or a number (directly, through an optional such as `??bool`, or behind a pointer
  such as `*bool`) all fail with a named `@compileError`. The comptime helpers raise
  `@setEvalBranchQuota` themselves, so ordinary question sets need no help from the caller; an
  unusually large set can still reach the branch limit, and the compiler names the builtin to
  raise.
- Run-time checks cover what is only known then: a string or object key that is not valid UTF-8, a
  NaN or infinite float, an invalid `std.json.Value` `number_string`, `RawJson` that is not one
  valid value or nests deeper than 256 levels, a selection from a non-exhaustive enum whose value
  has no name, a `null` Score level, a Noul whose instructions and criteria are all empty, and a
  state that is not a string, object or array. Each fails with `error.InvalidRequest` before
  anything is sent, with the path in `Diagnostics.path`.
- Memory: `Result` and `Models` own an arena. The response body, every string in the answers, the
  legends and the request id live in it; `deinit()` frees everything at once. The request body is
  freed before the response is read.

## Client and transport

`Client` wraps one `std.http.Client` plus the resolved options and the precomputed header values.
It is safe to share between tasks and threads because `std.http.Client` guards its connection pool
with an `Io.Mutex`; each call creates its own `Request`, which is what `std.http` requires. After
its first request a client must not be moved or copied: open connections point back at it.

Request path, as validated against the live API:

```zig
var request = client.http.request(call.method, uri, .{
    .redirect_behavior = .unhandled,          // the API never redirects; keeps the key off other hosts
    .headers = .{
        .authorization = .{ .override = client.authorization },   // "Bearer <key>"
        .user_agent = .{ .override = sdk_identifier },            // "typesafe-zig/<version>"
        .content_type = if (body != null) .{ .override = "application/json" } else .omit,
    },
    .extra_headers = headers,                 // accept, x-typesafe-sdk, x-typesafe-runtime, the caller's
    .connection = pooled,                     // an idle pooled connection for this host, if any
});
defer request.deinit();

if (body) |bytes| {
    try request.sendBodyComplete(bytes);      // sets content-length and flushes BOTH the TLS layer and the socket
} else {
    try request.sendBodiless();
}
var response = try request.receiveHead(&.{});
const bytes = try response.reader(&transfer_buffer).allocRemaining(gpa, .limited(client.max_response_bytes +| 1));
```

The flush gotcha: on a TLS connection `BodyWriter.end()` flushes only the TLS writer, not the
underlying socket writer. A request sent with `sendBody` + `writeAll` + `end()` hangs forever in
`receiveHead` against api.typesafe.ai; `sendBodyComplete` flushes both layers, and any streaming
path must call `req.connection.?.flush()` after `end()`.

`version` comes from `build.zig.zon` (`const manifest = @import("build.zig.zon")` in `build.zig`,
passed in through `b.addOptions()`), so the user agent and `x-typesafe-sdk` can never disagree with
the tag. `runtime` is `std.fmt.comptimePrint("zig/{s} ({s}; {s})", .{ builtin.zig_version_string, @tagName(builtin.os.tag), @tagName(builtin.cpu.arch) })`.

Other transport behaviour the suite and live traffic cover:

- A response body is capped at `max_response_bytes` while it is read (one byte over the limit
  distinguishes a body of exactly the limit from a larger one), and the connection is closed
  instead of drained when the limit is hit.
- A body cut short by a closed connection is a retryable `error.ConnectionFailed`, not a silently
  truncated answer; only a response read to the end returns its connection to the pool.
- A pooled keep-alive connection the server has since closed is replaced at once, without a delay
  and without counting an attempt.
- `gzip` and `deflate` response bodies are decoded; any other content encoding, and a compressed
  body that does not decompress, is `error.InvalidResponse`.
- Certificate verification uses the system roots. `std.http.Client` reads the clock and the roots
  once, at its first HTTPS request; a long-running client reloads both hourly, so a certificate
  issued after the client started is accepted and one that has expired is not. That refresh reads
  `std.http.Client` fields std does not promise to keep, so it sits behind a build option,
  `-Dtls-trust-refresh` (`.tls_trust_refresh = false` through `b.dependency`), which is on by
  default. Built with it off, the package touches only std's supported surface, and a client
  running for longer than a certificate's validity window verifies against the roots and the
  clock loaded at its first HTTPS request.
- `std.http.Client` in Zig 0.16 does not run TLS inside a proxy tunnel, so an HTTPS base URL with
  `https_proxy` set is refused with `error.InvalidRequest` rather than sending the key in
  plaintext. Each attempt also refuses a connection that is not TLS or that is proxied.

Timeouts: `Options.timeout: ?Io.Duration = .fromSeconds(10)`, at most `Client.max_timeout` (one
year), with `null` or `Io.Duration.max` disabling it. The attempt runs under an `Io.Select` racing
the request task (spawned with `io.concurrent`) against `timeout.sleep(io)`; whichever finishes
first wins and the other is canceled, which is what the 0.16 `Io` cancelation model is for. When
the `Io` cannot provide concurrency (`-fsingle-threaded`, or an implementation that returns
`error.ConcurrencyUnavailable`), the client logs a warning and sends without the timeout. There is
no per-read timeout in `std.http.Client` itself.

Retry, a `Retry` struct with the vendor defaults: `max_retries: u32 = 2`,
`backoff_initial_ms: u32 = 500`, `backoff_max_ms: u32 = 5000`, `jitter: f64 = 0.25`,
`respect_retry_after: bool = true`, `max_retry_after_ms: u64 = 60_000`,
`retry_transport_errors: bool = true`, `budget_ms: ?u64 = 30_000`, and
`isRetryableStatus: ?*const fn (std.http.Status) bool` to replace the default status list. `ask`
loops: a retryable status (408, 429, 500–599, so 529 Overloaded is included) or a transport error
(`error.ConnectionRefused`, `error.ConnectionResetByPeer`, `error.TlsFailure`, `error.Timeout`,
...) sleeps for `retry-after-ms` or `Retry-After` when present, else `min(initial × 2ⁿ, max)` with
±25% jitter from a `std.Random.IoSource`, then re-sends with `x-typesafe-retry-count: n`. The loop
stops when the next delay would cross `budget_ms`, measured on `Io.Clock.awake`. `Retry.disabled`
(or `.max_retries = 0`) turns it off. Retrying the `POST` is safe because evaluation has no side
effects. A retryable status whose error page is larger than `max_response_bytes` is still retried:
the status, not the unreadable body, decides.

Configuration (`Client.Options`), resolved as explicit option, then env var (only in
`initFromEnv`), then default:

| Option | Env var | Default |
| --- | --- | --- |
| `api_key` | `TYPESAFE_API_KEY` | none; `error.MissingApiKey` |
| `base_url` | `TYPESAFE_BASE_URL` | `https://api.typesafe.ai` |
| `model` | `TYPESAFE_DEFAULT_MODEL` | `jev-latest` |
| `timeout` | none | 10 s |
| `retry` | none | `Retry{}` |
| `max_response_bytes` | none | 16 MiB; exceeding it is `error.ResponseTooLarge` |
| `extra_headers` | none | none; `authorization`, `accept`, `content-type`, `connection`, `host`, `user-agent`, `x-typesafe-*` and friends are reserved and rejected with `error.ReservedHeader` |
| `hooks` | none | `.{}` |

The base URL must be an absolute `http` or `https` URL with a host, without credentials, query or
fragment; an IPv6 literal host, which `std.http.Client` 0.16 cannot connect to, and a host longer
than 255 bytes are rejected at init. Per-call options (`AskOptions`, `ListModelsOptions`)
override the client's for that call; an invalid one fails the call with `error.InvalidRequest` and
names the option in `Diagnostics.path`.

The client logs through `std.log.scoped(.typesafe)`: retries, retries skipped because of the
budget, and schema mismatches at `.debug`; a request sent without a timeout because the `Io`
cannot run a task concurrently, and a failed root-certificate reload, at `.warn`.

Observability: there is no telemetry library in Zig, so `Options.hooks: Hooks` holds a `context`
pointer and three optional function pointers, `onRequestStart(context, *const RequestStart)`,
`onRetry(context, *const RetryEvent)` and `onRequestEnd(context, *const RequestEnd)`. The end event
carries the operation, status, request id, attempt count, duration, token usage, the error, and
`user_data` passed through from the call. A metrics library or a test can attach without the
client knowing about it. Every call that fires the start event fires the end event.

Concurrency guidance for the README: prefer one `ask` carrying many questions (the docs measure
batching a 13-question job as 12.2× cheaper and 10× faster than separate calls). For the same
questions over many states, spawn one `ask` per state into an `Io.Group` and share the `Client`;
the pool reuses connections and the group cancels everything on the first `try` failure.

## Errors

Zig errors carry no payload, so the design is a small error set plus an optional out-parameter,
the same shape `std.json.Diagnostics` uses.

```zig
pub const Error = error{
    InvalidRequest, InvalidOption, BadRequest, Unauthorized, PermissionDenied, NotFound,
    RequestTimeout, Unprocessable, RateLimited, Overloaded, ServerError, UnexpectedStatus,
    ConnectionFailed, TlsFailure, Timeout, InvalidResponse, ResponseTooLarge,
    Canceled, OutOfMemory,
};

/// Configuration mistakes reported by Client.init and Client.initFromEnv.
pub const InitError = error{
    MissingApiKey, InvalidApiKey, InvalidBaseUrl, InvalidModel, InvalidTimeout,
    InvalidRetry, InvalidMaxResponseBytes, InvalidHeader, ReservedHeader, OutOfMemory,
};

pub const Diagnostics = struct {
    arena: std.heap.ArenaAllocator,      // owns the strings below; the caller calls deinit()
    err: ?Error = null,                  // the error the call returned, null on success
    method: ?std.http.Method = null,
    url: ?[]const u8 = null,
    status: ?std.http.Status = null,     // the final response's status
    request_id: ?[]const u8 = null,      // x-typesafe-request-id
    error_type: ?[]const u8 = null,      // body.detail.error_type, e.g. "authentication_error"
    message: ?[]const u8 = null,         // body.detail.message, or what failed locally
    body: ?[]const u8 = null,            // raw body, capped at max_body_bytes (64 KiB)
    path: ?[]const u8 = null,            // InvalidRequest / InvalidOption / InvalidResponse: "answers.tone.confidence"
    retry_after_ms: ?u64 = null,
    attempts: u32 = 0,                   // including the first
    cause: ?anyerror = null,             // the underlying transport or body error
};
```

| Error | Trigger | Retried by default |
| --- | --- | --- |
| `InvalidRequest` | The request could not be encoded: an unencodable value, an empty Noul, a `null` Score level, an invalid dynamic question, a state that is not a string, object or array | no |
| `InvalidOption` | A per-call option is invalid: an empty model, a timeout above `Client.max_timeout`, a reserved extra header, an HTTPS base URL with a proxy configured. `Diagnostics.path` names the option | no |
| `BadRequest` | HTTP 400, such as an unknown model | no |
| `Unauthorized` | HTTP 401, a missing or invalid API key | no |
| `PermissionDenied` | HTTP 403 | no |
| `NotFound` | HTTP 404 | no |
| `RequestTimeout` | HTTP 408 | yes |
| `Unprocessable` | HTTP 422; `Diagnostics.message` carries the server's field detail | no |
| `RateLimited` | HTTP 429 | yes |
| `Overloaded` | HTTP 529 | yes |
| `ServerError` | Any other 5xx | yes |
| `UnexpectedStatus` | Any other non-2xx, including redirects, which are never followed | no |
| `ConnectionFailed` | DNS, connect, reset, a malformed HTTP response, or a body cut short by a closed connection | yes |
| `TlsFailure` | TLS handshake failure or unreadable system certificates | yes |
| `Timeout` | An attempt did not complete within the configured timeout | yes |
| `InvalidResponse` | A 2xx whose body did not parse into `Response(Q)`, or an unsupported content encoding | no |
| `ResponseTooLarge` | The body exceeded `max_response_bytes` | no, unless the status is retryable |
| `Canceled` | The `Io` canceled the calling task | no |
| `OutOfMemory` | An allocation failed | no |

Behaviour:

- `ask` returns the error; when `AskOptions.diagnostics` is set, it is filled before returning,
  including after retries (the final attempt's status, `attempts` in total). Callers that only
  want the error pass nothing and pay nothing. A call resets the diagnostics when it starts; after
  a success it holds the status, request id and attempt count of the call that succeeded.
- The error body is parsed as `{"detail":{"error_type","message"}}`, the shape observed live; a
  body that does not fit that shape is kept raw in `Diagnostics.body` and quoted in `message`.
- `std.http.Client` error sets are wide; the client maps them to the four transport errors above
  and keeps the original name in `Diagnostics.cause`, so the public error set stays small and
  stable across Zig versions. The retry log at `.debug` names the mapped error.
- `Retry.isRetryable(err)` is public for callers who implement their own escalation, such as
  sending an uncertain or failed case to a reasoning model.

## Testing

Everything runs with `zig build test`, offline, against a loopback `std.http.Server`. The pattern
that works on 0.16.0 (validated, and wrapped by `typesafe.testing.MockServer` for downstream
users):

```zig
const io = std.testing.io;
const addr: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
var server = try addr.listen(io, .{ .reuse_address = true });
defer server.deinit(io);
const port = server.socket.address.getPort();

var serve = try io.concurrent(StubServer.serveOnce, .{ io, &server, .ok, stub_body });  // NOT io.async
defer _ = serve.cancel(io) catch {};
// ... run the client against http://127.0.0.1:<port> ...
try serve.await(io);
```

Two details that cost time: `io.async` may run the callee inline before returning, which deadlocks
on `accept`, so the server task must use `io.concurrent`; and the stub must drain the request body
(`request.readerExpectNone(&buf).discardRemaining()`) before `respond`, or the client's keep-alive
bookkeeping is wrong.

| Layer | What is covered | How |
| --- | --- | --- |
| Wire encoding | Each constructor's JSON equals the shared request fixture byte-for-byte; every entry kind (string, object, tuple, `std.json.Value`, `RawJson`) encodes as documented | `std.testing.expectEqualStrings` against `src/testdata/requests/*` |
| Answer decoding | Every documented response decodes into typed structs; `"0"`-keyed maps land in the fixed-size arrays; unknown fields ignored; a missing probability, an out-of-range probability and a mismatched `type` are `InvalidResponse` with a field path | Fixtures in `src/testdata/responses/`, plus inline bodies |
| Encoder and decoder | Invalid UTF-8, non-finite floats, deep nesting (including inside `RawJson`), an unnamed non-exhaustive enum, a key written outside an object, truncated failure messages, a body that is not JSON, one that ends early, one with trailing data, missing fields and mismatched answer types with their paths | `src/wire_test.zig`, `src/json.zig` tests |
| Comptime checks | Fewer than two levels, empty enum, non-exhaustive enum, no questions, boolean or number entries through optionals and pointers | Documented in doc comments; Zig has no negative-compilation test in `std.testing`, so these are checked by hand at review |
| Client | Auth and identification headers, `content-length`, no redirect following, `x-typesafe-retry-count` only on retries, per-call overrides, base-URL and option validation | `MockServer` records request heads and bodies for assertions |
| Retries | 429 then 200 succeeds and honours `retry-after-ms` (and is actually waited out); 529 retried; 401 and 400 not; the budget stops a further attempt; `max_retries = 0` disables; the retry count header restarts per call; a retryable status with an oversized body is retried | `MockServer` scripted with a status sequence; tests pass a `Retry` with zero backoff |
| Timeouts | A server that sleeps past the deadline yields `error.Timeout` and cancels cleanly; `Io.Duration.max` disables; a value above `max_timeout` is rejected | `MockServer` with a delay; CI passes `--test-timeout 60s`, so a hang fails the job |
| Errors | Each status maps to its error; `Diagnostics` filled with status, request id, `error_type`, `message`, `path`, `retry_after_ms`, attempts and cause; a retried call that later fails holds only the final attempt | `MockServer` returning the live-observed error body shape, and the FastAPI validation shape |
| Hooks | Start, retry and end hooks fire once per call with attempts, duration and usage | A test hook counting calls |
| Memory | Every error path frees what it allocated; a leak-checking allocator is used throughout, plus explicit allocation-failure tests | `std.testing.allocator`, `src/oom_test.zig` |
| Live | `POST /v1/systemone`, `GET /v1/models`, structured state, non-identifier option names, dynamic questions, concurrency, hooks, TLS trust refresh and connection reuse with a real key | `tests/live.zig`, run by `zig build test-live`; tests that need `TYPESAFE_API_KEY` skip when it is unset, and CI gates the job on the secret |

`MockServer` is public (`typesafe.testing`), so downstream users stub the client in their own tests
without a mocking library; the README shows the same twelve lines.

## Docs, quality and release

`build.zig` defines the steps: the `typesafe` module, `test` (offline unit and integration tests),
`test-live` (the live file, which skips without `TYPESAFE_API_KEY`), `examples` (builds every
program under `examples/` so the README code cannot rot), `run` (runs one, `-Dexample=<name>`),
`docs` (autodoc from `getEmittedDocs`, installed to `zig-out/docs`), `fmt`, and `ci`, which runs
format, tests, examples and docs in one command.

`build.zig.zon`:

```zig
.{
    .name = .typesafe,
    .version = "0.1.0",
    .fingerprint = 0x50d8d794ef27ec07, // generated once by `zig build`, then never changed
    .minimum_zig_version = "0.16.0",
    .dependencies = .{},
    .paths = .{ "build.zig", "build.zig.zon", "src", "LICENSE", "README.md" },
}
```

Quality gates, in `.github/workflows/ci.yml` on every push and PR, matrix `ubuntu-latest`,
`macos-latest`, `windows-latest` with `mlugg/setup-zig@v2` pinned to `0.16.0`:

| Job | Command |
| --- | --- |
| Test | `zig build test -Doptimize=Debug|ReleaseSafe --test-timeout 60s --summary all`, on all three platforms |
| Format | `zig build fmt` |
| Examples and docs | `zig build examples --summary all`, `zig build docs` |
| Cross-compile | `zig build examples -Dtarget=<target> -Doptimize=ReleaseSafe` for `x86_64-windows-gnu`, `aarch64-macos`, `x86_64-macos`, `aarch64-linux-musl`, `riscv64-linux-musl` |

`.github/workflows/live.yml` runs the live suite plus every example on a daily schedule and on
`workflow_dispatch`, gated on `github.repository == 'mattneel/typesafe.zig'` and on the
`TYPESAFE_API_KEY` secret being set, so forks skip it instead of failing.

Documentation: doc comments on the public surface, rendered with `zig build docs`; the README holds
install, the ticket-routing example, the MockServer pattern, error handling with `Diagnostics`, and
a link per TypeSafe docs concept (state, questions and structure, confidence and thresholds,
batching) rather than restating them; `docs/guides/` holds the longer treatments (questions,
confidence, concurrency, testing, observability).

Versioning and publishing: SemVer with `v0.x` tags; consumers pin with
`zig fetch --save git+https://github.com/mattneel/typesafe.zig#v0.1.0`, which records the content
hash, so a moved tag would be caught. Any change to an answer struct's fields is at least a minor
bump with a CHANGELOG entry in Keep a Changelog format. The `.fingerprint` is generated once and
committed; the `.version` in the manifest is the single source for the user agent. The release
checklist in `RELEASING.md` covers bumping the version and CHANGELOG, running the local checks,
tagging, and verifying `zig fetch` of the tag from a scratch project.

## Roadmap and decisions

0.1.0 is the package above. Later items, ordered by value:

1. `Client.askMany`: one question set over a slice of states, fanned out through an `Io.Group`
   with a concurrency limit, results returned in input order with per-item errors.
2. A `typesafe` CLI (`examples/cli.zig`): pipe state in, questions from a `.zon` file, JSON out,
   for trying questions from the shell.
3. Response streaming into a caller-provided `Io.Writer` for very large states, once a use case
   for it appears.

Shipped early, ahead of the original plan: `typesafe.dynamic` (run-time questions) and
`typesafe.testing.MockServer`, because the guides and the examples needed them and neither adds a
dependency to the core.

Decisions settled while building, with the evidence:

| Decision | Evidence |
| --- | --- |
| Answer types generated with `@Struct` from the questions struct | Prototype compiled and its encode/decode tests passed on Zig 0.16.0 |
| `sendBodyComplete` (or an explicit `connection.flush()`) for every request | `sendBody` + `end()` alone hung in `receiveHead` against api.typesafe.ai; `Connection.flush` flushes the TLS writer and the socket writer, `BodyWriter.end` only the former |
| Stub server task spawned with `io.concurrent` | `io.async` deadlocked the loopback test; `io.concurrent` passed |
| Error bodies parsed as `detail.error_type` / `detail.message` | Live 401 response; the FastAPI validation array shape was added after a live 422 |
| `std` TLS is sufficient; no C TLS library | `client.fetch` and the manual request path both completed the TLS 1.3 handshake with api.typesafe.ai |
| Models endpoint `GET /v1/models` returning `{"models": [...]}` | Path constants and schema in typesafe-sdk 0.6.0; same string in the JS bundle |
| Send `X-TypeSafe-SDK`, `X-TypeSafe-Runtime`, `X-TypeSafe-Retry-Count` and `User-Agent`, formatted like the vendor SDKs but named `typesafe-zig/<version>` | Both vendor SDK sources build exactly these headers; the name is this package's own so its traffic is not attributed to an official SDK |
| A validating encoder instead of a union wrapper for entries | The API takes string, object, array or null in six different places; one generic path with a path-tracked failure covers all of them, while still rejecting booleans and numbers |
| Retries logged at `.debug` | Vendor SDKs log retries at info under a default `warn` level |
| No HTTP/2 | `std.http.Client` is HTTP/1.1 only and the API accepts it; bodies are small |
| Diagnostics as an optional out-parameter rather than a payload-carrying error | Zig errors are integers; `std.json.Diagnostics` is the established shape |
| A retryable status with an oversized body is retried | A gateway error page larger than `max_response_bytes` is common; the status, not the unreadable body, says whether the server may recover |
| Responses are decoded in one pass with a pull reader over `std.json.Scanner`, not into a `std.json.Value` tree first | The tree was built on every call and thrown away except for the legend nodes and the `body` the caller may never read; the reader keeps the field paths in the error messages and lets the answer strings point straight into the response body. The typed decode shrinks what a call allocates to the body itself. `Result.body` gives a caller who needs an unknown field the bytes, which is strictly more useful than a decoded copy |
| `InvalidOption` is separate from `InvalidRequest` | A caller can tell "your data cannot be encoded, look at the state" from "your call is misconfigured, look at the options"; the diagnostics name the option, and neither is retried |
| The comptime budget margin is per level, not per entry | Measured: with either the per-entry margin or the per-level margin the suite builds; with both absent a 100-level Score fails. One margin, proportional to the work, is enough |
| The hourly TLS refresh is behind `-Dtls-trust-refresh` | It is the only code that reads `std.http.Client` fields std does not promise to keep (`ca_bundle`, `ca_bundle_lock`, `now`); a consumer that would rather track std can turn it off, and the suite passes in both configurations |
| `Retry-After` accepts seconds, fractional seconds and the three RFC 9110 date formats, capped at 60 s | RFC 9110 allows all three; the cap matches the JavaScript SDK |
