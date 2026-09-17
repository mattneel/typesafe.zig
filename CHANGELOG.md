# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). While the version is 0.x,
any change to an answer type or the wire format is at least a minor version bump.

## [Unreleased]

## [0.1.0] - Unreleased

First release: an unofficial community Zig client for TypeSafe's System One API (the Jev model).
It is not an official TypeSafe SDK and is not affiliated with or endorsed by TypeSafe.

Install it with `zig fetch --save git+https://github.com/mattneel/typesafe.zig#v0.1.0`. It
requires Zig 0.16.0 or later and uses only the standard library.

### Added

- `typesafe.Client` with `init` and `initFromEnv`. Options resolve from the explicit option, then
  `TYPESAFE_API_KEY`, `TYPESAFE_BASE_URL` or `TYPESAFE_DEFAULT_MODEL` (blank values ignored),
  then the default. Invalid configuration is an `InitError` at init, never at request time. The
  base URL's scheme is lowercased; IPv6 literal hosts, which `std.http.Client` 0.16 cannot
  connect to, and hosts over 255 bytes are `InvalidBaseUrl`.
- `Client.ask` for `POST /v1/systemone` with typed questions built by `typesafe.noul`,
  `typesafe.choice` and `typesafe.score`. The answers struct is derived from the questions at
  compile time: a Choice answer is the caller's enum with one probability field per tag, and a
  Score answer has a `[N]f64` of probabilities. Missing questions, unknown options, non-enum
  option types, Scores with fewer than two levels, levels given as a string instead of a tuple,
  booleans or numbers as instructions, descriptions, Noul criteria or levels (including through
  an optional or a pointer), and a Noul with `null` instructions and no non-`null` criteria are
  compile errors. The comptime helpers raise `@setEvalBranchQuota` for you, so question sets of
  a few dozen questions and Scores with dozens of levels compile as they are; an unusually large
  set can still reach the comptime branch limit, which the compiler reports and names
  `@setEvalBranchQuota` for.
- `Client.askDynamic` and `typesafe.dynamic` for questions defined at run time, validated before
  sending. `dynamic.Json` values report their JSON type with `kind()` and absence with
  `isEmpty()`.
- `Client.listModels` for `GET /v1/models`.
- JSON structure for state, instructions, descriptions, levels and criteria: struct literals,
  tuples, slices, `std.json.Value` and `typesafe.RawJson`. A strict encoder, which walks
  `std.json.Value` too, rejects invalid UTF-8, non-finite numbers, invalid `number_string`
  values, nesting over 256 levels, invalid raw JSON, a Noul whose instructions and criteria are
  all empty at run time and a `null` Score level with `error.InvalidRequest` and a path to the
  value. Types with their own `jsonStringify` are written by it unchecked; a
  `writeTypesafeJson` method has the encoder check a type's contents.
- Strict, forward-compatible decoding in one pass over the response bytes (no intermediate
  `std.json.Value` tree), with field paths in errors, such as
  `answers.tone.confidence: expected a number from 0 to 1`. Answer strings point into the
  response body, which the result keeps as `body`. Unknown answers and fields are skipped, keys
  may arrive in any order, a repeated key keeps its last value, and a body that is not valid
  JSON, ends early or carries trailing data is `error.InvalidResponse`. gzip and deflate response bodies are decoded; any other content encoding is
  `error.InvalidResponse`.
- Answer helpers: `NoulAnswer.isYes`, `ChoiceAnswer.probability`, `ranked` and `margin`, and
  `ScoreAnswer.probability`, `expectedLevel`, `maxLevel` and `ranked`. Dynamic answers have `probability`,
  `ranked` and `margin` (Choice) and `expectedLevel` and `maxLevel` (Score). `margin` is rounded
  to 10 decimal places, as in the Elixir client.
- `typesafe.Error`, one error set for every call, and `typesafe.Diagnostics`, an optional
  out-parameter with the status, request id, server error type and message, body, field path,
  `retry_after_ms`, attempt count and underlying cause, plus a one-line `{f}` format. On failure
  it describes the final attempt; after a success it holds only the final response's status and
  request id and the attempt count.
- `typesafe.Retry`, a retry policy with the same defaults as TypeSafe's official Python and
  JavaScript SDKs: 2 retries, exponential backoff from 500 ms to 5 s with 25% jitter, retries on
  408, 429, 5xx and transport errors, `retry-after-ms` and `Retry-After` (seconds or any RFC 9110
  HTTP date), and a 30 s budget per call. `isRetryableStatus` replaces the default retryable
  statuses, and `retriesStatus` and `isRetryableStatusByDefault` expose the status decision.
- A per-attempt timeout (10 s by default, at most one year, disabled with `null` or
  `Io.Duration.max`) enforced with `std.Io.Select`, and cancelation through `std.Io`: canceling
  the calling task cancels the request.
- Connection handling: only a response read to the end returns its connection to the pool; a
  pooled connection the server has closed is replaced without using an attempt; a body cut short
  by a closed connection is a retryable `error.ConnectionFailed`; a body of exactly
  `max_response_bytes` is accepted. A long-running client reloads the clock and system root
  certificates it checks TLS certificates against every hour, behind
  `-Dtls-trust-refresh` (on by default; `.tls_trust_refresh = false` through `b.dependency`
  leaves it out). HTTPS through a proxy is refused
  with `error.InvalidOption`, because `std.http.Client` 0.16 would not encrypt the proxied
  connection. Per-call option and header mistakes are `error.InvalidOption` too, with the option
  in `Diagnostics.path`; `error.InvalidRequest` is only for a request that cannot be encoded.
- Identification headers in the format of TypeSafe's official SDKs (`User-Agent`,
  `X-TypeSafe-SDK`, `X-TypeSafe-Runtime`, `X-TypeSafe-Retry-Count`), identifying this client as
  `typesafe-zig/<version>`. Redirects are never followed.
- `typesafe.Hooks` for observability: request start, retry and request end events with status,
  request id, attempts, duration, token usage and error. Every call that fires the start event,
  including one rejected for invalid options, fires the end event.
- Logging through `std.log.scoped(.typesafe)`: retries and schema mismatches at `.debug`, requests
  sent without a timeout and failed root certificate reloads at `.warn`.
- `typesafe.testing.MockServer`, a loopback HTTP server with scripted replies (answers, API
  errors, delays, dropped connections, unread request bodies, truncated bodies, connections
  closed after a reply) and recorded requests, for testing code that uses the client.
- Examples (`route_ticket`, `structured`, `batch`, `dynamic`, `list_models`), guides (questions,
  confidence, concurrency, testing, observability) and an API reference generated with
  `zig build docs`.

[Unreleased]: https://github.com/mattneel/typesafe.zig/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/mattneel/typesafe.zig/releases/tag/v0.1.0
