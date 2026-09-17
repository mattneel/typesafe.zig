# Concurrency

There are two ways to do more work with TypeSafe: ask more questions per request, and send more
requests at once. Use the first wherever you can, and the second for the many independent states
that remain.

## Many questions, one request

Every question in a request sees the same state and is answered independently. One question's
answer does not affect another's, so batching does not change results. What batching changes is
cost and latency:

- The state is usually most of the input tokens. One request pays for it once, while N
  single-question requests pay for it N times.
- The questions in a request are evaluated in parallel, so adding questions barely changes
  response time.

TypeSafe's [Parallel questions](https://docs.typesafe.ai/cookbooks/parallel_questions)
cookbook measured this with 13 questions over a 54,000-character document. One batched call was
12.2x cheaper and 10x faster than 13 single-question calls, with no change in the answers.

In practice, build one questions struct per kind of state and send it whole:

```zig
const Team = enum { billing, technical, sales, other };

const questions = .{
    .refund_requested = typesafe.noul("Does the customer request a refund?", .{}),
    .is_urgent = typesafe.noul("Does this convey urgency?", .{}),
    .mentions_competitor = typesafe.noul("Does the customer mention switching to a competitor?", .{}),
    .department = typesafe.choice(Team, "Which team should handle this?", .{
        .billing = "Payments, invoicing, refunds",
        .technical = "Bugs, outages, integrations",
        .sales = "Pricing, upgrades, new accounts",
    }),
    .frustration = typesafe.score("How frustrated is the customer?", .{ "Calm", "Frustrated", "Very angry" }),
};

var result = try client.ask(ticket_body, questions, .{});
defer result.deinit();
```

Ask questions you might not need, too. A question whose answer only matters for some inputs,
such as `mentions_competitor`, costs only its own few tokens. Your code reads it when it is
relevant. TypeSafe calls this [speculative fan-out](https://docs.typesafe.ai/patterns/fan-out).

The limit is the request's token budget, which the state and questions share. The TypeSafe docs
put it at around 32,000 tokens, roughly 150,000 characters of English text (see
[Ask multiple questions together](https://docs.typesafe.ai/primitives)). `result.usage` reports
the `input_tokens` and `output_tokens` of each call, each a `?u64`.

## Many states, many requests

When the same questions run over many states, such as a backlog of tickets, send one request per
state and run them concurrently on one client with a `std.Io.Group`. This is the shape of
`examples/batch.zig`:

```zig
const Outcome = union(enum) {
    pending,
    answered: typesafe.Answers(@TypeOf(questions)),
    failed: typesafe.Error,
};

fn classify(client: *typesafe.Client, text: []const u8, outcome: *Outcome) std.Io.Cancelable!void {
    var result = client.ask(text, questions, .{}) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => {
            outcome.* = .{ .failed = err };
            return;
        },
    };
    defer result.deinit();
    outcome.* = .{ .answered = result.answers };
}

fn classifyAll(client: *typesafe.Client, io: std.Io, texts: []const []const u8, outcomes: []Outcome) !void {
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    for (texts, outcomes) |text, *outcome| {
        try group.concurrent(io, classify, .{ client, text, outcome });
    }
    try group.await(io);
}
```

Notes on this pattern:

- **Share one client.** Calls from many tasks or threads can run on the same `Client` at the same
  time: each call creates its own request, and the connection pool is guarded by a mutex. Build
  it once and pass `*Client` to every task.
- **Do not move the client.** After its first request, open connections point back at the
  client, so it must not be moved or copied. Keep it in a `var` that outlives every call, not in
  a container that can reallocate, and call `deinit` only after every call has returned.
- **Handle errors per item.** A group task must return something that coerces to
  `std.Io.Cancelable!void`, so a task handles `typesafe.Error` itself and returns only
  `error.Canceled`. A rate limit or a timeout on one ticket should not lose the rest of the batch.
  Writing each outcome to its own slot keeps results in input order.
- **Copy the answers out.** The answers struct holds numbers and enums, so it stays valid after
  `result.deinit()`. A Score answer's `legend` is the exception: it lives in the result's arena.
- **Cancel on early return.** `defer group.cancel(io)` stops the tasks already started if the
  loop returns early, for example when `group.concurrent` fails with
  `error.ConcurrencyUnavailable`. After `group.await` returns, `cancel` does nothing.
- **Use a thread-safe allocator.** The client allocates from whichever task calls it, so the
  `gpa` passed to `Client.init` must be thread-safe, as `std.http.Client` requires. `init.gpa` in
  a `std.process.Init` main is, and so is `std.testing.allocator`.

## Connection pool

The client's `std.http.Client` keeps idle keep-alive connections and reuses them for later calls,
which saves a TCP and TLS handshake per call. It keeps up to 32 idle connections by default
(`client.http.connection_pool.free_size`). It does not cap open connections: each request in
flight holds its own, and when a connection is released while 32 are already idle, the least
recently used idle one is closed. Bounding your concurrency also bounds connections (see
[Limiting concurrency](#limiting-concurrency)).

Only a request whose response was read to the end returns its connection to the pool. An attempt
that times out or is canceled (even partway through sending its body), fails to write, or
receives a body that is larger than `max_response_bytes` or cut short closes its connection, so a
later request never lands in the middle of an unfinished one.

A server can close an idle keep-alive connection at any time. When a request fails on a pooled
connection because the server had already closed it, the client sends the request again at once
on another pooled connection or a new one. That does not count as an attempt, waits for no
backoff delay and fires no `onRetry` hook.

## Timeouts need an Io with concurrency

The `timeout` limits each attempt, from connecting to reading the last byte. The client enforces
it by racing the request against a timer with `std.Io.Select`, which runs two concurrent tasks
per attempt. `std.Io.Threaded`, the `Io` in `std.process.Init` and `std.testing.io`, does this with
threads.

When the `Io` cannot start another concurrent task (a single-threaded build, or an
`Io.Threaded` at its `concurrent_limit`), the attempt runs without a timeout, and the client logs
a `.warn` message on the `typesafe` scope. Limit concurrency in your own code, as below, rather
than by starving the `Io`.

A call can override the client's timeout with `.timeout` in its options. `null`, the default,
uses the client's, and `std.Io.Duration.max` turns the limit off for that call:

```zig
var result = try client.ask(report, questions, .{ .timeout = .fromSeconds(60) });
```

A timeout that is not positive or is longer than `Client.max_timeout` (one year) fails the call
with `error.InvalidOption`.

## Cancelation

Canceling the task that called the client cancels the request. The in-flight attempt is
abandoned, its connection is closed, and `ask` returns `error.Canceled`. A cancel during a retry
delay returns `error.Canceled` too. It is never retried.

`group.cancel(io)` cancels every task in a group. For a single call, run it with
`io.concurrent` and cancel its future:

```zig
fn askUrgent(client: *typesafe.Client, text: []const u8) typesafe.Error!f64 {
    var result = try client.ask(text, questions, .{});
    defer result.deinit();
    return result.answers.is_urgent.noul;
}

var task = try io.concurrent(askUrgent, .{ &client, text });
// ...the caller decides it no longer needs the answer.
if (task.cancel(io)) |urgent| {
    std.log.info("finished before the cancel: {d:.2}", .{urgent});
} else |err| switch (err) {
    error.Canceled => {},
    else => return err,
}
```

In your own task functions, pass `error.Canceled` up instead of treating it as a failed item, as
`classify` above does, so cancelation reaches the group.

## Rate limits and retries

A 429 (`RateLimited`) or 529 (`Overloaded`) response is retried by the client's `Retry` policy:
2 retries by default, with exponential backoff from 500 ms to 5 s and up to 25% jitter. When the
response carries `retry-after-ms` or `Retry-After`, the client waits that long instead, and a
requested wait longer than `max_retry_after_ms` (60 s) falls back to the backoff delay. Before
each retry the client checks the budget: when the elapsed time plus the next delay would reach
`budget_ms` (30 s), it stops and returns the error.

Under sustained high concurrency, some calls can still run out of retries or budget and fail with
`error.RateLimited` or `error.Overloaded`. That is a signal to lower concurrency, not to add more
retries. `Diagnostics.retry_after_ms` holds the server's requested wait if you want to schedule
the item for later.

Retries show pressure before errors appear. `result.attempts` counts attempts including the
first, and the `onRetry` hook fires before each retry:

```zig
const Pressure = struct {
    retries: std.atomic.Value(u64) = .init(0),

    fn onRetry(context: ?*anyopaque, event: *const typesafe.hooks.RetryEvent) void {
        const pressure: *Pressure = @ptrCast(@alignCast(context.?));
        _ = pressure.retries.fetchAdd(1, .monotonic);
        std.log.warn("retrying after {t} in {f}", .{ event.err, event.delay });
    }
};

var pressure: Pressure = .{};
var client: typesafe.Client = try .init(gpa, io, .{
    .api_key = key,
    .hooks = .{ .context = &pressure, .onRetry = Pressure.onRetry },
});
```

A rising share of calls with retries means the batch is running too hot. See
[Observability](observability.md).

For a background backfill, you can trade latency for fewer failures with a more patient policy:

```zig
var client: typesafe.Client = try .init(gpa, io, .{
    .api_key = key,
    .retry = .{ .max_retries = 5, .backoff_max_ms = 10_000, .budget_ms = 120_000 },
});
```

## Limiting concurrency

Starting one task per item runs every call at once. To cap the number in flight, take a permit
from a `std.Io.Semaphore` before starting each task, and give it back when the task finishes:

```zig
fn classifyLimited(
    client: *typesafe.Client,
    io: std.Io,
    semaphore: *std.Io.Semaphore,
    text: []const u8,
    outcome: *Outcome,
) std.Io.Cancelable!void {
    defer semaphore.post(io);
    return classify(client, text, outcome);
}

fn classifyAllLimited(client: *typesafe.Client, io: std.Io, texts: []const []const u8, outcomes: []Outcome, max_in_flight: usize) !void {
    var semaphore: std.Io.Semaphore = .{ .permits = max_in_flight };
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    for (texts, outcomes) |text, *outcome| {
        try semaphore.wait(io);
        group.concurrent(io, classifyLimited, .{ client, io, &semaphore, text, outcome }) catch |err| {
            semaphore.post(io);
            return err;
        };
    }
    try group.await(io);
}
```

Because the loop waits for a permit before it starts a task, at most `max_in_flight` calls run
at once, however long the input is, and so at most that many requests and connections are open.
`semaphore.wait` returns `error.Canceled` if the waiting task is canceled.

Pick the limit deliberately. Start low, watch retries and `RateLimited` errors, and raise it
gradually. Staying at or below 32 lets every connection go back to the pool between calls.
