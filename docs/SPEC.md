# typesafe.zig — package spec

Status: draft · Last updated 2026-09-16 · Repo: `mattneel/typesafe.zig` · Zig 0.16.0

## Summary

`typesafe.zig` is a Zig 0.16.0 client for TypeSafe's System One API (the Jev model). Questions are Zig values: a `noul`, a `choice` over an enum you define, a `score` over a fixed list of levels. One `ask` sends them with your state and returns a struct whose fields are typed answers: the Choice answer *is* your enum, its probabilities are a struct with one `f64` per enum tag, the Score answer carries a fixed-size probability array. Nothing is stringly typed on this side of the wire. The package uses the standard library only: `std.http.Client`, `std.json`, `std.Io`.

The core was prototyped against Zig 0.16.0 on 2026-09-16: comptime answer-type generation with `@Struct`, byte-for-byte wire encoding through `std.json.Stringify`, decoding through `std.json.parseFromSlice`, a loopback `std.http.Server` stub driven by `std.testing.io`, and a live HTTPS POST to api.typesafe.ai. Two things only showed up under test (a TLS flush gotcha and `io.async` versus `io.concurrent`); they are called out where they apply.

Design principles:

- Code owns the workflow. The client returns judgments as data (probabilities, distributions, confidence); thresholds and policy stay in the caller's code.
- Types come from the caller. Questions are comptime values and the answer struct is derived from them, so a misspelled question name, a missing level or an unknown option is a compile error rather than a runtime surprise.
- Explicit allocator and `Io`, passed in. No globals, no hidden threads, no process state; the client is one struct.
- Standard library only. Zig has no package registry, every dependency is a hash the user has to trust, and `std` already covers HTTPS, JSON and concurrency.
- Small surface: `Client.init`, `Client.ask`, `Client.listModels`, three question constructors, one error set with a diagnostics struct.

Naming: repo `mattneel/typesafe.zig`, package name `.typesafe` in `build.zig.zon`, module `typesafe` (`@import("typesafe")`). The `.zig` suffix is a repo convention; the package name drops it, as `zig init` recommends.

## API surface the client must cover

One endpoint does the work: `POST https://api.typesafe.ai/v1/systemone` takes `state`, `model` and a `questions` map and returns one answer per question id, plus `usage` ([HTTP API reference](https://docs.typesafe.ai/api.md)). A second, `GET /v1/models`, returns `{"models": [{"name", "description", "release_date"}]}`; it is missing from the HTTP reference but both of TypeSafe's own SDKs call it, per the path constants in [typesafe-sdk 0.6.0](https://pypi.org/project/typesafe-sdk/) and [@typesafe-ai/sdk 0.6.0](https://www.npmjs.com/package/@typesafe-ai/sdk).

| Field | Request | Response |
| --- | --- | --- |
| `state` | string, object or array; the content to judge | not echoed |
| `model` | string, default `jev-latest` | string, model that answered |
| `questions` | map of caller-chosen id to Question; ids are not sent to the model | `answers`: same ids to Answer |
| `usage` | n/a | `input_tokens`, `output_tokens` (integers, may be absent) |

The three question types and their answers ([primitives](https://docs.typesafe.ai/primitives.md)):

| Type | `instructions` | `criteria` | Answer fields |
| --- | --- | --- | --- |
| `noul` | string, object or array | optional `{true, false}` descriptions | `noul` float 0 to 1 |
| `choice` | string, object or array | required map of option to description or `null` | `choice` (top option), `probabilities` map summing to 1, `confidence` 0 to 1 |
| `score` | string, object or array | required ordered array of at least 2 levels | `score` float (may land between levels), `legend` map `"0"`.. to level text, `probabilities` keyed by level string, `confidence` 0 to 1 |

Wire details the package must honour:

- Every `instructions` value, Choice option description, Score level and Noul `true`/`false` entry accepts JSON structure: string, object, array or null ([advanced structure](https://docs.typesafe.ai/primitives/advanced.md)).
- Auth is `Authorization: Bearer <key>`; the response carries `x-typesafe-request-id`, which the vendor SDKs surface on every response and error ([exceptions](https://docs.typesafe.ai/sdk/python/api/exceptions.md)).
- Identification headers both vendor SDKs send, read from their 0.6.0 sources: `User-Agent: typesafe-sdk/<version>`, `X-TypeSafe-SDK: typesafe-sdk/<version>`, `X-TypeSafe-Runtime: <runtime>/<version> (<platform>; <arch>)`, and `X-TypeSafe-Retry-Count: <n>` on every retried attempt. This client sends the same set.
- Defaults ([constants](https://docs.typesafe.ai/sdk/python/api/constants.md)): base URL `https://api.typesafe.ai`, model `jev-latest`, 10 s per HTTP operation, env vars `TYPESAFE_API_KEY`, `TYPESAFE_BASE_URL`, `TYPESAFE_DEFAULT_MODEL`, `TYPESAFE_LOG_LEVEL`. Explicit options beat env vars, which beat defaults; blank env values are ignored.
- Documented errors: 401 (bad key), 422 (validation, body names the offending field), 429 (rate limit), 529 (overloaded). The vendor SDKs also map 400, 403, 404 and other 5xx, and read `Retry-After` and `retry-after-ms`. Error body shape, verified with a live unauthenticated POST on 2026-09-16: `{"detail":{"error_type":"authentication_error","message":"..."}}`.
- Retry policy ([retries](https://docs.typesafe.ai/sdk/python/api/retries.md)): 2 retries after the first attempt, backoff 0.5 s doubling to a 5 s cap with 25% jitter, retry on 408, 429 and 500 to 599 plus connection and timeout errors, honour `Retry-After`, 30 s total budget per call. This client uses the same numbers so behaviour matches across languages.
- Client-side validation the vendor SDKs perform before sending: at least one question; Score criteria is a list of at least two entries. Here both are compile errors.
- Transport facts from the probe: api.typesafe.ai negotiates TLS 1.3 and answers HTTP/1.1; `std.http.Client` speaks HTTP/1.1 and TLS 1.2/1.3, so no extra layer is needed.

## Toolchain and dependencies

No third-party packages. The `build.zig.zon` `dependencies` table is empty and stays empty; every capability below is `std` in Zig 0.16.0 (released 2026-04-13, the current stable as of this writing per [ziglang.org/download](https://ziglang.org/download/)).

| Component | What it provides here | Notes |
| --- | --- | --- |
| Zig 0.16.0 | `std.Io` as an interface, `@Struct` and the other type-building builtins, `Io.net` without ws2_32 on Windows | `.minimum_zig_version = "0.16.0"`; nothing older is supported, the `Io` API alone rules that out |
| `std.http.Client` | HTTP/1.1 over TLS via `std.crypto.tls`, keep-alive connection pool (32 free connections by default), proxies through `initDefaultProxies` | Thread-safe for opening connections; individual `Request`s are not, one per task |
| `std.json` | `Stringify.valueAlloc` with per-type `jsonStringify`, `parseFromSliceLeaky` with `ignore_unknown_fields`, `std.json.Value` for structured entries | No allocation on the encode side beyond the output buffer |
| `std.Io` | `Io.Threaded` for real programs, `std.testing.io` in tests, `io.concurrent`, `Io.Select`, `Io.Timeout`, `std.Random.IoSource` for retry jitter | Cancelation works through the same interface (`error.Canceled`) |
| `std.crypto.Certificate.Bundle` | System root certificates, rescanned on the client's first HTTPS request | Verified: the std TLS client completes the handshake with api.typesafe.ai |
| Dev tooling | `zig build test`, `zig build test --test-timeout 30s` (new in 0.16), `zig fmt --check`, autodoc via `Compile.getEmittedDocs` | CI uses [mlugg/setup-zig@v2](https://github.com/mlugg/setup-zig) |

Consumption:

```sh
zig fetch --save git+https://github.com/mattneel/typesafe.zig#v0.1.0
```

```zig
// build.zig
const typesafe = b.dependency("typesafe", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("typesafe", typesafe.module("typesafe"));
```

Considered and left out: libcurl or mbedTLS through `@cImport` (needs a C toolchain, breaks plain `zig build` cross-compilation, and buys nothing since the std TLS handshake with the API works), third-party HTTP or JSON packages (nothing `std` lacks for this API), a logging or metrics dependency (a hooks struct plus `std.log.scoped(.typesafe)` covers it), HTTP/2 (the API accepts HTTP/1.1; `std.http.Client` has no HTTP/2 and the API's JSON bodies are small).

## Package layout and public API

```
typesafe.zig/
├── build.zig               module, test step, docs step, examples step
├── build.zig.zon           .name = .typesafe, .version, .fingerprint, .minimum_zig_version = "0.16.0", .paths
├── src/
│   ├── typesafe.zig        root: re-exports Client, noul/choice/score, Entry, Error, Diagnostics, Retry, Result
│   ├── Client.zig          Client struct: init, initFromEnv, deinit, ask, listModels
│   ├── question.zig        Noul, Choice(Options), Score(levels), Entry, Answers(Questions), Request(Questions)
│   ├── wire.zig            encode request, decode response, error body parsing
│   ├── retry.zig           Retry policy struct, delay computation, retryable classification
│   ├── errors.zig          Error set, Diagnostics
│   └── test/
│       ├── StubServer.zig  loopback std.http.Server for tests
│       └── live.zig        smoke test gated on TYPESAFE_API_KEY
├── examples/route_ticket.zig
├── README.md · CHANGELOG.md · LICENSE (MIT)
└── .github/workflows/ci.yml
```

The main call, in the form the README opens with:

```zig
const std = @import("std");
const typesafe = @import("typesafe");

const Team = enum { billing, technical, sales };

pub fn main(init: std.process.Init) !void {
    var client: typesafe.Client = try .initFromEnv(init.gpa, init.io, init.minimal.environ);
    defer client.deinit();

    const questions = .{
        .is_urgent = typesafe.noul("Does this convey urgency?"),
        .department = typesafe.choice(Team, "Which team should handle this?"),
        .frustration = typesafe.score(&.{ "Calm", "Frustrated", "Very angry" }, "How frustrated is the customer?"),
    };

    var result = try client.ask("Help! My payouts have been failing for 3 days.", questions, .{});
    defer result.deinit();

    const a = result.value.answers;
    _ = a.is_urgent.noul;                        // f64, 0.92
    _ = a.department.choice;                     // Team.technical
    _ = a.department.probability(.technical);    // f64, 0.85
    _ = a.frustration.score;                     // f64, 1.6
    _ = a.frustration.probabilityArray()[2];     // f64, 0.65
}
```

Public declarations:

| Declaration | Signature and rules |
| --- | --- |
| `Client.init(gpa, io, Options) Error!Client` | Validates options, builds the `std.http.Client`, precomputes the identification headers. `Options.api_key` is required; `base_url`, `model`, `timeout`, `retry`, `max_response_bytes`, `extra_headers`, `hooks` have defaults |
| `Client.initFromEnv(gpa, io, environ) Error!Client` | Same, reading `TYPESAFE_API_KEY`, `TYPESAFE_BASE_URL`, `TYPESAFE_DEFAULT_MODEL` from a `std.process.Environ` (`init.minimal.environ` in a `std.process.Init` main). Empty values count as unset. A missing key is `error.MissingApiKey` here, never at request time |
| `Client.ask(client, state: anytype, questions: anytype, AskOptions) Error!Result(@TypeOf(questions))` | `state` is encoded with `std.json`: a `[]const u8` stays a JSON string, a struct or slice becomes structure. `questions` is an anonymous struct literal; its field names are the question ids, echoed back as the answer field names. Per-call `AskOptions`: `model`, `timeout`, `retry`, `diagnostics: ?*Diagnostics` |
| `Client.listModels(client, gpa, ListOptions) Error!std.json.Parsed([]Model)` | `GET /v1/models`; `Model` has `name`, `description`, `release_date` |
| `noul(instructions) Noul` | `Noul{ .instructions, .criteria = null }`; `criteria` is `?struct { true: Entry, false: Entry }` |
| `choice(comptime Options: type, instructions) Choice(Options)` | `Options` must be an enum with at least one tag, checked with `@compileError`; `.descriptions` is `std.enums.EnumFieldStruct(Options, ?Entry, null)` so each option can carry a description |
| `score(comptime levels: []const []const u8, instructions) Score(levels)` | Fewer than two levels is a `@compileError`; the answer type is sized by `levels.len` |
| `Entry` | `union(enum) { text: []const u8, json: std.json.Value }` with a `jsonStringify` that writes either; every instructions, description and level field accepts one, and the constructors take a `[]const u8` for the common case |
| `Result(Questions)` | `value: Response(Questions)` (`model`, `answers: Answers(Questions)`, `usage: ?Usage`), `request_id: ?[]const u8`, `status: std.http.Status`, an owning `std.heap.ArenaAllocator`, `deinit()` |
| `Retry` | Policy struct with the vendor defaults; see Client and transport |
| `Error`, `Diagnostics` | See Errors |

Every public declaration has a doc comment and a `test` block next to it, so `zig build docs` and `zig build test` cover the same surface.

## Questions, answers and the wire

The whole type story is a few comptime functions. This is the prototype that passed on Zig 0.16.0, trimmed to the parts that matter:

```zig
pub fn Choice(comptime Options: type) type {
    return struct {
        instructions: Entry,
        descriptions: std.enums.EnumFieldStruct(Options, ?Entry, null) = .{},

        pub const Answer = struct {
            choice: Options,                                        // std.json parses enums by tag name
            probabilities: std.enums.EnumFieldStruct(Options, f64, null), // one f64 field per tag
            confidence: f64,

            pub fn probability(a: @This(), option: Options) f64 {
                inline for (std.meta.fields(Options)) |f|
                    if (option == @field(Options, f.name)) return @field(a.probabilities, f.name);
                unreachable;
            }
        };

        pub fn jsonStringify(self: @This(), jws: *std.json.Stringify) !void { ... } // {"type":"choice","instructions":...,"criteria":{tag:desc,...}}
    };
}

/// A struct with fields "0".."N-1" of T, so a JSON object keyed by level index parses without allocation.
fn Indexed(comptime N: usize, comptime T: type) type {
    comptime var names: [N][]const u8 = undefined;
    comptime var types: [N]type = undefined;
    comptime var attrs: [N]std.builtin.Type.StructField.Attributes = undefined;
    inline for (0..N) |i| { names[i] = std.fmt.comptimePrint("{d}", .{i}); types[i] = T; attrs[i] = .{}; }
    return @Struct(.auto, null, &names, &types, &attrs);
}

/// The struct of typed answers with the same field names as the questions struct.
pub fn Answers(comptime Questions: type) type {
    const qfields = std.meta.fields(Questions);
    if (qfields.len == 0) @compileError("ask needs at least one question");
    comptime var names: [qfields.len][]const u8 = undefined;
    comptime var types: [qfields.len]type = undefined;
    comptime var attrs: [qfields.len]std.builtin.Type.StructField.Attributes = undefined;
    inline for (qfields, 0..) |f, i| { names[i] = f.name; types[i] = f.type.Answer; attrs[i] = .{}; }
    return @Struct(.auto, null, &names, &types, &attrs);
}

pub fn Response(comptime Questions: type) type {
    return struct { model: []const u8, answers: Answers(Questions), usage: ?Usage = null };
}
```

Rules:

- Encoding goes through `std.json.Stringify.valueAlloc(gpa, Request(Q){ .state, .model, .questions }, .{})`. Each question type's `jsonStringify` writes `type`, `instructions` and `criteria` in the documented shape; Noul omits `criteria` when null; Choice writes one key per enum tag with its description or `null`; Score writes the level array. The test suite checks the output byte-for-byte against the request JSON in the API reference.
- Decoding is `std.json.parseFromSliceLeaky(Response(Q), arena, body, .{ .ignore_unknown_fields = true })`. The `type` discriminator in each answer is an unknown field and is ignored; the question type already fixes the answer type. New fields the API adds later are ignored the same way, so a newer server never breaks an older client.
- Score `legend` and `probabilities` arrive as objects keyed `"0"`, `"1"`, ...; they parse into `Indexed(levels.len, T)` structs whose field names are exactly those strings, with no map allocation. `probabilityArray()` and `legendArray()` give `[N]f64` and `[N][]const u8` views; `expectedLevel()` returns the rounded index.
- Choice `probabilities` parse into `EnumFieldStruct(Options, f64)`, so a probability the server omitted for one of your options is `error.MissingField` from `std.json`, surfaced as `error.InvalidResponse` with the field path in `Diagnostics`.
- Keys round-trip by construction: question ids are struct field names and options are enum tags, so `result.value.answers.department.choice == .technical` and there is nothing to map back.
- Compile-time checks replace the vendor SDKs' runtime ones: no questions, fewer than two Score levels, a Choice over a non-enum or an empty enum, and a questions field whose type has no `Answer` declaration all fail with a named `@compileError`.
- Memory: `Result` owns an arena. The response body, every string in the answers and the request id live in it; `result.deinit()` frees everything at once. The request body is freed before the response is read.

## Client and transport

`Client` wraps one `std.http.Client` plus the resolved options and the precomputed header values. It is safe to share between tasks and threads because `std.http.Client` guards its connection pool with an `Io.Mutex`; each `ask` creates its own `Request`, which is what `std.http` requires.

Request path, as validated against the live API:

```zig
var req = try client.http.request(.POST, client.systemone_uri, .{
    .headers = .{
        .authorization = .{ .override = client.auth_header },        // "Bearer <key>"
        .user_agent = .{ .override = "typesafe-sdk/" ++ version },   // same value the vendor SDKs send
        .content_type = .{ .override = "application/json" },
    },
    .extra_headers = &.{
        .{ .name = "x-typesafe-sdk", .value = "typesafe-sdk/" ++ version },
        .{ .name = "x-typesafe-runtime", .value = runtime },          // "zig/0.16.0 (linux; x86_64)", built at comptime from builtin
        .{ .name = "x-typesafe-retry-count", .value = retry_count },  // only on attempts after the first
    },
    .redirect_behavior = .not_allowed,                                // the API never redirects; keeps the key off other hosts
});
defer req.deinit();
try req.sendBodyComplete(body);      // sets content-length and flushes BOTH the TLS layer and the socket
var response = try req.receiveHead(&redirect_buf);
const bytes = try response.reader(&transfer_buf).allocRemaining(arena, .limited(client.max_response_bytes));
```

The flush gotcha: on a TLS connection `BodyWriter.end()` flushes only the TLS writer, not the underlying socket writer. A request sent with `sendBody` + `writeAll` + `end()` hangs forever in `receiveHead` against api.typesafe.ai (reproduced 2026-09-16); `sendBodyComplete` flushes both layers, and any streaming path must call `req.connection.?.flush()` after `end()`. The test suite covers this only indirectly (the loopback stub is plain HTTP), so the code comment and the live smoke test are the guards.

`version` comes from `build.zig.zon` (`const manifest = @import("build.zig.zon")` in `build.zig`, passed in through `b.addOptions()`), so the user agent and `x-typesafe-sdk` can never disagree with the tag. `runtime` is `std.fmt.comptimePrint("zig/{s} ({s}; {s})", .{ builtin.zig_version_string, @tagName(builtin.os.tag), @tagName(builtin.cpu.arch) })`.

Timeouts: `Options.timeout: Io.Timeout = .{ .duration = .fromSeconds(10) }`. The one-shot request runs under an `Io.Select` racing the request task (spawned with `io.concurrent`) against `timeout.sleep(io)`; whichever finishes first wins and the other is canceled, which is what the 0.16 `Io` cancelation model is for. When the `Io` cannot provide concurrency (`-fsingle-threaded`, or an implementation that returns `error.ConcurrencyUnavailable`), the client falls back to the connect timeout only and says so in the doc comment; there is no per-read timeout in `std.http.Client` itself.

Retry, a `Retry` struct with the vendor defaults: `max_retries: u8 = 2`, `backoff_initial_ms: u32 = 500`, `backoff_max_ms: u32 = 5000`, `jitter: f32 = 0.25`, `retry_on_transport_errors: bool = true`, `respect_retry_after: bool = true`, `budget_ms: u32 = 30_000`. `ask` loops: a retryable status (408, 429, 500–599, so 529 Overloaded is included) or a transport error (`error.ConnectionRefused`, `error.ConnectionResetByPeer`, `error.TlsFailure`, `error.Timeout`, ...) sleeps for `retry-after-ms` or `Retry-After` when present, else `min(initial × 2ⁿ, max)` with ±25% jitter from a `std.Random.IoSource`, then re-sends with `x-typesafe-retry-count: n`. The loop stops when the next delay would cross `budget_ms` measured with `Io.Clock.awake`. `Retry{ .max_retries = 0 }` disables it. Retrying the POST is safe because evaluation has no side effects.

Configuration (`Client.Options`), resolved as explicit option, then env var (only in `initFromEnv`), then default:

| Option | Env var | Default |
| --- | --- | --- |
| `api_key` | `TYPESAFE_API_KEY` | none; `error.MissingApiKey` |
| `base_url` | `TYPESAFE_BASE_URL` | `https://api.typesafe.ai` |
| `model` | `TYPESAFE_DEFAULT_MODEL` | `jev-latest` |
| `timeout` | none | 10 s |
| `retry` | none | the defaults above |
| `max_response_bytes` | none | 16 MiB; exceeding it is `error.ResponseTooLarge` |
| `extra_headers` | none | none; `authorization`, `content-type`, `user-agent`, `x-typesafe-*` are reserved and rejected with `error.ReservedHeader` |
| `hooks` | none | null |

`TYPESAFE_LOG_LEVEL` is not mirrored; Zig programs set `std.options.log_level` and `log_scope_levels`. The client logs through `std.log.scoped(.typesafe)`: retries at `.debug` (the vendor SDKs log them at info under a default `warn` threshold, so they are silent by default there too), decode failures at `.warn`.

Observability: there is no telemetry library in Zig, so `Options.hooks: ?*const Hooks` holds two optional function pointers, `onRequestStart(ctx, RequestInfo)` and `onRequestEnd(ctx, RequestInfo, Outcome)`, where `Outcome` carries `status`, `request_id`, `attempts`, `duration: Io.Duration` and `usage`. A metrics library or a test can attach without the client knowing about it.

Concurrency guidance for the README: prefer one `ask` carrying many questions (the docs measure batching a 13-question job as 12.2× cheaper and 10× faster than separate calls). For the same questions over many states, spawn one `ask` per state into an `Io.Group` and share the `Client`; the pool reuses connections and the group cancels everything on the first `try` failure.

## Errors

Zig errors carry no payload, so the design is a small error set plus an optional out-parameter, the same shape `std.json.Diagnostics` uses.

```zig
pub const Error = error{
    MissingApiKey, ReservedHeader,            // Client.init
    BadRequest, Unauthorized, PermissionDenied, NotFound, Unprocessable,
    RateLimited, Overloaded, ServerError, UnexpectedStatus,
    InvalidResponse, ResponseTooLarge,
    ConnectionFailed, TlsFailure, Timeout, Canceled, ConcurrencyUnavailable,
    OutOfMemory,
};

pub const Diagnostics = struct {
    status: ?std.http.Status = null,
    request_id: ?[]const u8 = null,      // x-typesafe-request-id
    error_type: ?[]const u8 = null,      // body.detail.error_type, e.g. "authentication_error"
    message: ?[]const u8 = null,         // body.detail.message
    body: ?[]const u8 = null,            // raw body, capped at max_response_bytes
    field_path: ?[]const u8 = null,      // InvalidResponse: "answers.tone.confidence"
    retry_after_ms: ?u64 = null,
    attempts: u8 = 0,
    arena: std.heap.ArenaAllocator,      // owns the strings above; caller calls deinit()
};
```

| Error | Trigger | Retried by default |
| --- | --- | --- |
| `BadRequest` | HTTP 400 | no |
| `Unauthorized` | HTTP 401 | no |
| `PermissionDenied` | HTTP 403 | no |
| `NotFound` | HTTP 404 | no |
| `Unprocessable` | HTTP 422; `Diagnostics.message` carries the server's field detail | no |
| `RateLimited` | HTTP 429 | yes |
| `Overloaded` | HTTP 529 | yes |
| `ServerError` | any other 5xx | yes |
| `UnexpectedStatus` | any other non-2xx | no |
| `Timeout` | connect or overall timeout elapsed | yes |
| `ConnectionFailed`, `TlsFailure` | `std.http.Client` connect and handshake failures, collapsed from its larger error sets | yes |
| `InvalidResponse` | 2xx whose body did not parse into `Response(Q)` | no |
| `ResponseTooLarge` | body exceeded `max_response_bytes` | no |
| `Canceled` | the `Io` canceled the task | no |

Behaviour:

- `ask` returns the error; when `AskOptions.diagnostics` is set, it is filled before returning, including after retries (final attempt's status, `attempts` total). Callers that only want the error pass nothing and pay nothing.
- The error body is parsed as `{"detail":{"error_type","message"}}`, the shape observed live; a body that does not fit is kept raw in `Diagnostics.body`.
- `std.http.Client` error sets are wide; the client maps them to the four transport errors above and logs the original error name at `.debug`, so the public error set stays small and stable across Zig versions.
- `Retry.isRetryable(err)` is public for callers who implement their own escalation, such as sending an uncertain or failed case to a reasoning model.

## Testing

Everything runs with `zig build test`, offline, against a loopback `std.http.Server`. The pattern that works on 0.16.0 (validated) is:

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

Two details that cost time: `io.async` may run the callee inline before returning, which deadlocks on `accept`, so the server task must use `io.concurrent`; and the stub must drain the request body (`request.readerExpectNone(&buf).discardRemaining()`) before `respond`, or the client's keep-alive bookkeeping is wrong.

| Layer | What is covered | How |
| --- | --- | --- |
| Wire encoding | Each constructor's JSON equals the request JSON in the API reference byte-for-byte; `Entry.json` passes structure through untouched | `std.testing.expectEqualStrings` on `Stringify.valueAlloc` output, fixtures inlined as multiline string literals |
| Answer decoding | Every documented response decodes into typed structs; `"0"`-keyed maps land in `Indexed`; unknown fields ignored; a missing probability is `InvalidResponse` with a field path | Fixtures in `src/test/fixtures.zig` |
| Comptime checks | Fewer than two levels, empty enum, no questions | Documented in doc comments; Zig has no negative-compilation test in `std.testing`, so these are checked by hand at review |
| Client | Auth and identification headers, `content-length`, no redirect following, `x-typesafe-retry-count` only on retries | `StubServer` records request heads and bodies for assertions |
| Retries | 429 then 200 succeeds and honours `retry-after-ms`; 529 retried; 401 not retried; budget stops a further attempt; `max_retries = 0` disables | `StubServer` scripted with a status sequence; tests pass a `Retry` with zero backoff |
| Timeouts | A server that sleeps past the deadline yields `error.Timeout` and cancels cleanly | `StubServer` with `io.sleep`; `zig build test --test-timeout 30s` in CI guards against a hang regressing |
| Errors | Each status maps to its error; `Diagnostics` filled with status, request id, `error_type`, `message` | `StubServer` returning the live-observed error body shape |
| Hooks | Start and end hooks fire once per `ask` with attempts and usage | A test hook counting calls |
| Live | `POST /v1/systemone` and `GET /v1/models` with a real key | `src/test/live.zig`; returns `error.SkipZigTest` when `TYPESAFE_API_KEY` is unset, so it is skipped by default and on forks |

`StubServer` is not part of the public module (it lives under `src/test/`), but the README shows the same twelve lines so downstream users can stub the client in their own tests without a mocking library.

## Docs, quality and release

`build.zig` defines four steps: the `typesafe` module, `test` (unit tests plus the live test file), `docs` (autodoc from `getEmittedDocs`, installed to `zig-out/docs`), and `examples` (builds `examples/route_ticket.zig` against the module so the README example is compiled on every CI run).

`build.zig.zon`:

```zig
.{
    .name = .typesafe,
    .version = "0.1.0",
    .fingerprint = 0x..., // generated once by `zig build`, then never changed
    .minimum_zig_version = "0.16.0",
    .dependencies = .{},
    .paths = .{ "build.zig", "build.zig.zon", "src", "LICENSE", "README.md" },
}
```

Quality gates, in `.github/workflows/ci.yml` on every push and PR, matrix `ubuntu-latest`, `macos-latest`, `windows-latest` with `mlugg/setup-zig@v2` pinned to `0.16.0`:

| Job | Command |
| --- | --- |
| Format | `zig fmt --check .` |
| Test | `zig build test --test-timeout 30s --summary all` in Debug and ReleaseSafe |
| Examples and docs | `zig build examples docs` |
| Live | `zig build test -Dlive` on a schedule with a repo secret; the `live` file is compiled always but skips without the key |

Documentation: doc comments on every public declaration, rendered with `zig build docs` and published to GitHub Pages from `zig-out/docs`; the README holds install, the ticket-routing example, the stub-server pattern, error handling with `Diagnostics`, and a link per TypeSafe docs concept (state, questions and structure, confidence and thresholds, batching) rather than restating them.

Versioning and publishing: SemVer with `v0.x` tags; consumers pin with `zig fetch --save git+https://github.com/mattneel/typesafe.zig#v0.1.0`, which records the content hash, so a moved tag would be caught. Any change to an answer struct's fields is at least a minor bump with a CHANGELOG entry in Keep a Changelog format. The `.fingerprint` is generated once and committed; the `.version` in the manifest is the single source for the user agent. Release checklist in `RELEASING.md`: bump `.version` and CHANGELOG, `zig build test docs examples`, tag, push, confirm `zig fetch` of the tag from a scratch project resolves and builds.

## Roadmap and decisions

0.1.0 is the core above; later items, ordered by value:

1. `typesafe.dynamic`: questions built at run time (options loaded from a database, levels from a config file) with `std.json.Value` answers. The comptime API cannot express option sets that are not known when the program is compiled, and taxonomy-style apps need this.
2. `Client.askMany`: one question set over a slice of states, fanned out through an `Io.Group` with a concurrency limit, results returned in input order with per-item errors.
3. A `typesafe` CLI (`examples/cli.zig`): pipe state in, questions from a `.zon` file, JSON out, for trying questions from the shell.
4. Response streaming into a caller-provided `Io.Writer` for very large states, once a use case for it appears.

Decisions settled while writing this, with the evidence:

| Decision | Evidence |
| --- | --- |
| Answer types generated with `@Struct` from the questions struct | Prototype compiled and its encode/decode tests passed on Zig 0.16.0 |
| `sendBodyComplete` (or an explicit `connection.flush()`) for every request | `sendBody` + `end()` alone hung in `receiveHead` against api.typesafe.ai; `Connection.flush` flushes the TLS writer and the socket writer, `BodyWriter.end` only the former |
| Stub server task spawned with `io.concurrent` | `io.async` deadlocked the loopback test; `io.concurrent` passed |
| Error bodies parsed as `detail.error_type` / `detail.message` | Live 401 response on 2026-09-16 |
| `std` TLS is sufficient; no C TLS library | `client.fetch` and the manual request path both completed the TLS 1.3 handshake with api.typesafe.ai |
| Models endpoint `GET /v1/models` returning `{"models": [...]}` | Path constants and schema in typesafe-sdk 0.6.0; same string in the JS bundle |
| Send `X-TypeSafe-SDK`, `X-TypeSafe-Runtime`, `X-TypeSafe-Retry-Count` and `User-Agent: typesafe-sdk/<version>` | Both vendor SDK sources build exactly these headers |
| Retries logged at `.debug` | Vendor SDKs log retries at info under a default `warn` level |
| No HTTP/2 | `std.http.Client` is HTTP/1.1 only and the API accepts it; bodies are small |
| Diagnostics as an optional out-parameter rather than a payload-carrying error | Zig errors are integers; `std.json.Diagnostics` is the established shape |
