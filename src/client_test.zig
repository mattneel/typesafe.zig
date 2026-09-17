//! Integration tests: the client against a loopback `MockServer`.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;

const Client = @import("Client.zig");
const Diagnostics = @import("Diagnostics.zig");
const Retry = @import("Retry.zig");
const hooks = @import("hooks.zig");
const question = @import("question.zig");
const dynamic = @import("dynamic.zig");
const MockServer = @import("testing.zig").MockServer;

const Team = enum { billing, technical, sales };

const questions = .{
    .is_urgent = question.noul("Does this convey urgency?", .{
        .yes = "Explicitly time-sensitive",
        .no = "No urgency expressed",
    }),
    .department = question.choice(Team, "Which team should handle this?", .{
        .billing = "Payments, invoicing, refunds",
        .technical = "Bugs, outages, integrations",
    }),
    .frustration = question.score("How frustrated is the customer?", .{ "Calm", "Frustrated", "Very angry" }),
};

const answers: question.Answers(@TypeOf(questions)) = .{
    .is_urgent = .{ .noul = 0.95 },
    .department = .{
        .choice = .billing,
        .probabilities = .{ .billing = 0.85, .technical = 0.15, .sales = 0 },
        .confidence = 0.77,
    },
    .frustration = .{ .score = 1.04, .probabilities = .{ 0, 0.96, 0.04 }, .confidence = 0.93 },
};

const state = "Help! My payouts have been failing for 3 days.";

/// Retries without delays, so tests stay fast.
const fast_retry: Retry = .{ .backoff_initial_ms = 1, .backoff_max_ms = 1, .jitter = 0 };

const Harness = struct {
    server: *MockServer,
    client: Client,

    fn init(options: Client.Options) !*Harness {
        const gpa = testing.allocator;
        const harness = try gpa.create(Harness);
        errdefer gpa.destroy(harness);
        harness.server = try .create(gpa, testing.io);
        errdefer harness.server.destroy();
        var resolved = options;
        if (resolved.api_key == null) resolved.api_key = "ts_test_key";
        if (resolved.base_url == null) resolved.base_url = harness.server.url();
        harness.client = try .init(gpa, testing.io, resolved);
        return harness;
    }

    fn deinit(harness: *Harness) void {
        harness.client.deinit();
        harness.server.destroy();
        testing.allocator.destroy(harness);
    }
};

test "ask sends the request and decodes typed answers" {
    const h = try Harness.init(.{ .extra_headers = &.{.{ .name = "x-team", .value = "support" }} });
    defer h.deinit();
    try h.server.enqueueAnswers(questions, answers, .{ .model = "jev-1.13.0", .request_id = "req_abc" });

    var result = try h.client.ask(state, questions, .{});
    defer result.deinit();

    try testing.expectEqualStrings("jev-1.13.0", result.model);
    try testing.expectEqualStrings("req_abc", result.request_id.?);
    try testing.expectEqual(1, result.attempts);
    try testing.expectEqual(100, result.usage.input_tokens);
    try testing.expectEqual(0.95, result.answers.is_urgent.noul);
    try testing.expectEqual(Team.billing, result.answers.department.choice);
    try testing.expectEqual(0.15, result.answers.department.probability(.technical));
    try testing.expectEqual([3]f64{ 0, 0.96, 0.04 }, result.answers.frustration.probabilities);
    try testing.expectEqual(1, result.answers.frustration.expectedLevel());
    try testing.expectEqualStrings("Frustrated", result.answers.frustration.legend[1].string);
    try testing.expectEqualStrings("jev-1.13.0", result.raw.object.get("model").?.string);

    try testing.expectEqual(1, h.server.requestCount());
    const request = h.server.request(0);
    try testing.expectEqual(std.http.Method.POST, request.method);
    try testing.expectEqualStrings("/v1/systemone", request.target);
    try testing.expectEqualStrings("Bearer ts_test_key", request.header("authorization").?);
    try testing.expectEqualStrings("application/json", request.header("content-type").?);
    try testing.expectEqualStrings("application/json", request.header("accept").?);
    try testing.expectEqualStrings(Client.sdk_identifier, request.header("user-agent").?);
    try testing.expectEqualStrings(Client.sdk_identifier, request.header("x-typesafe-sdk").?);
    try testing.expectEqualStrings(Client.runtime_identifier, request.header("x-typesafe-runtime").?);
    try testing.expectEqualStrings("support", request.header("x-team").?);
    try testing.expectEqual(null, request.header("x-typesafe-retry-count"));

    try testing.expectEqualStrings(
        \\{"state":"Help! My payouts have been failing for 3 days.","model":"jev-latest","questions":{"is_urgent":{"type":"noul","instructions":"Does this convey urgency?","criteria":{"true":"Explicitly time-sensitive","false":"No urgency expressed"}},"department":{"type":"choice","instructions":"Which team should handle this?","criteria":{"billing":"Payments, invoicing, refunds","technical":"Bugs, outages, integrations","sales":null}},"frustration":{"type":"score","instructions":"How frustrated is the customer?","criteria":["Calm","Frustrated","Very angry"]}}}
    , request.body);
}

test "ask honours per-call model, headers and a base URL with a path" {
    const gpa = testing.allocator;
    const server: *MockServer = try .create(gpa, testing.io);
    defer server.destroy();
    const base_url = try std.fmt.allocPrint(gpa, "{s}/proxy/", .{server.url()});
    defer gpa.free(base_url);
    var client: Client = try .init(gpa, testing.io, .{ .api_key = "k", .base_url = base_url, .model = "jev-latest" });
    defer client.deinit();

    try server.enqueueAnswers(questions, answers, .{});
    var result = try client.ask(.{ .ticket = .{ .subject = "Payouts", .body = state } }, questions, .{
        .model = "jev-preview",
        .extra_headers = &.{.{ .name = "x-trace", .value = "t-1" }},
    });
    defer result.deinit();

    const request = server.request(0);
    try testing.expectEqualStrings("/proxy/v1/systemone", request.target);
    try testing.expectEqualStrings("t-1", request.header("x-trace").?);
    try testing.expect(std.mem.startsWith(u8, request.body,
        \\{"state":{"ticket":{"subject":"Payouts","body":"Help! My payouts have been failing for 3 days."}},"model":"jev-preview",
    ));
}

test "retries a rate limit, honouring retry-after-ms, and marks retried attempts" {
    const Recorder = struct {
        retries: u32 = 0,
        delay_ms: i64 = 0,
        starts: u32 = 0,
        ends: u32 = 0,
        end_attempts: u32 = 0,
        end_err: ?anyerror = null,
        end_status: ?std.http.Status = null,
        end_tokens: ?u64 = null,

        fn onStart(context: ?*anyopaque, event: *const hooks.RequestStart) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.starts += 1;
            std.debug.assert(event.question_count == 3);
        }
        fn onRetry(context: ?*anyopaque, event: *const hooks.RetryEvent) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.retries += 1;
            self.delay_ms = event.delay.toMilliseconds();
            std.debug.assert(event.err == error.RateLimited);
        }
        fn onEnd(context: ?*anyopaque, event: *const hooks.RequestEnd) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.ends += 1;
            self.end_attempts = event.attempts;
            self.end_err = event.err;
            self.end_status = event.status;
            self.end_tokens = event.input_tokens;
        }
    };
    var recorder: Recorder = .{};
    const h = try Harness.init(.{ .hooks = .{
        .context = &recorder,
        .onRequestStart = Recorder.onStart,
        .onRetry = Recorder.onRetry,
        .onRequestEnd = Recorder.onEnd,
    } });
    defer h.deinit();

    try h.server.enqueueError(.too_many_requests, .{ .error_type = "rate_limit_error", .retry_after_ms = 20 });
    try h.server.enqueueAnswers(questions, answers, .{});

    const started: Io.Clock.Timestamp = .now(testing.io, .awake);
    var result = try h.client.ask(state, questions, .{});
    defer result.deinit();
    // The requested delay is waited out, not just reported to the hook.
    try testing.expect(started.untilNow(testing.io).raw.toMilliseconds() >= 15);

    try testing.expectEqual(2, result.attempts);
    try testing.expectEqual(2, h.server.requestCount());
    try testing.expectEqual(null, h.server.request(0).header("x-typesafe-retry-count"));
    try testing.expectEqualStrings("1", h.server.request(1).header("x-typesafe-retry-count").?);
    try testing.expectEqualStrings(h.server.request(0).body, h.server.request(1).body);

    try testing.expectEqual(1, recorder.starts);
    try testing.expectEqual(1, recorder.retries);
    try testing.expectEqual(20, recorder.delay_ms);
    try testing.expectEqual(1, recorder.ends);
    try testing.expectEqual(2, recorder.end_attempts);
    try testing.expectEqual(null, recorder.end_err);
    try testing.expectEqual(std.http.Status.ok, recorder.end_status.?);
    try testing.expectEqual(100, recorder.end_tokens);
}

test "retries a retryable status whose error body is over max_response_bytes" {
    // Small enough that the scripted error page is unreadable, large enough
    // that the scripted answers are not.
    const h = try Harness.init(.{ .retry = fast_retry, .max_response_bytes = 1024 });
    defer h.deinit();
    const big = "x" ** 4096;

    // A gateway error page larger than the limit is retried, because the
    // status, not the unreadable body, says whether the server may recover.
    try h.server.enqueue(.{ .status = .bad_gateway, .body = big });
    try h.server.enqueueAnswers(questions, answers, .{});
    var result = try h.client.ask(state, questions, .{});
    defer result.deinit();
    try testing.expectEqual(2, result.attempts);
    try testing.expectEqual(2, h.server.requestCount());

    // A 2xx body over the limit is still too large, and is not retried.
    try h.server.enqueue(.{ .status = .ok, .body = big });
    try testing.expectError(error.ResponseTooLarge, h.client.ask(state, questions, .{}));
    try testing.expectEqual(3, h.server.requestCount());
}

test "retries overload and server errors until the retries run out" {
    const h = try Harness.init(.{ .retry = fast_retry });
    defer h.deinit();
    try h.server.enqueueError(@enumFromInt(529), .{ .message = "Overloaded" });
    try h.server.enqueueError(.bad_gateway, .{});
    try h.server.enqueueError(.service_unavailable, .{ .message = "still down", .request_id = "req_last" });

    var diagnostics: Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();
    try testing.expectError(error.ServerError, h.client.ask(state, questions, .{ .diagnostics = &diagnostics }));
    try testing.expectEqual(3, h.server.requestCount());
    try testing.expectEqualStrings("2", h.server.request(2).header("x-typesafe-retry-count").?);
    try testing.expectEqual(error.ServerError, diagnostics.err.?);
    try testing.expectEqual(3, diagnostics.attempts);
    try testing.expectEqual(std.http.Status.service_unavailable, diagnostics.status.?);
    try testing.expectEqualStrings("still down", diagnostics.message.?);
    try testing.expectEqualStrings("req_last", diagnostics.request_id.?);

    // Recovers when a later attempt succeeds.
    try h.server.enqueueError(@enumFromInt(529), .{});
    try h.server.enqueueAnswers(questions, answers, .{});
    var result = try h.client.ask(state, questions, .{});
    defer result.deinit();
    try testing.expectEqual(2, result.attempts);
}

test "does not retry client errors and reports the server's message" {
    const h = try Harness.init(.{});
    defer h.deinit();
    var diagnostics: Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();

    try h.server.enqueueError(.unauthorized, .{
        .error_type = "authentication_error",
        .message = "Cannot authenticate with the server. Please check your API key and try again.",
        .request_id = "req_401",
    });
    try testing.expectError(error.Unauthorized, h.client.ask(state, questions, .{ .diagnostics = &diagnostics }));
    try testing.expectEqual(1, h.server.requestCount());
    try testing.expectEqual(1, diagnostics.attempts);
    try testing.expectEqualStrings("authentication_error", diagnostics.error_type.?);
    try testing.expectEqualStrings("req_401", diagnostics.request_id.?);
    try testing.expectEqual(std.http.Method.POST, diagnostics.method.?);
    try testing.expect(std.mem.endsWith(u8, diagnostics.url.?, "/v1/systemone"));
    var line: std.Io.Writer.Allocating = .init(testing.allocator);
    defer line.deinit();
    try line.writer.print("{f}", .{diagnostics});
    try testing.expect(std.mem.startsWith(u8, line.written(), "Unauthorized (HTTP 401): Cannot authenticate with the server."));
    try testing.expect(std.mem.endsWith(u8, line.written(), "/v1/systemone, request_id: req_401]"));

    try h.server.enqueue(.{
        .status = @enumFromInt(422),
        .body =
        \\{"detail":[{"type":"too_short","loc":["body","questions"],"msg":"Dictionary should have at least 1 item after validation, not 0"}]}
        ,
    });
    try testing.expectError(error.Unprocessable, h.client.ask(state, questions, .{ .diagnostics = &diagnostics }));
    try testing.expectEqualStrings("questions: Dictionary should have at least 1 item after validation, not 0", diagnostics.message.?);

    try h.server.enqueueError(.bad_request, .{ .error_type = "api_usage_error", .message = "Unknown model: nope" });
    try testing.expectError(error.BadRequest, h.client.ask(state, questions, .{ .model = "nope", .diagnostics = &diagnostics }));
    try testing.expectEqualStrings("Unknown model: nope", diagnostics.message.?);

    try h.server.enqueue(.{ .status = .forbidden, .body = "" });
    try testing.expectError(error.PermissionDenied, h.client.ask(state, questions, .{ .diagnostics = &diagnostics }));
    try testing.expectEqualStrings("HTTP 403 with no body", diagnostics.message.?);

    try testing.expectEqual(4, h.server.requestCount());
}

test "never follows redirects" {
    const h = try Harness.init(.{});
    defer h.deinit();
    try h.server.enqueue(.{ .status = .found, .headers = &.{.{ .name = "location", .value = "https://evil.example/steal" }} });
    var diagnostics: Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();
    try testing.expectError(error.UnexpectedStatus, h.client.ask(state, questions, .{ .diagnostics = &diagnostics }));
    try testing.expectEqual(std.http.Status.found, diagnostics.status.?);
    try testing.expectEqual(1, h.server.requestCount());
}

test "retry budget stops a retry whose delay would exceed it" {
    const h = try Harness.init(.{ .retry = .{ .budget_ms = 50 } });
    defer h.deinit();
    try h.server.enqueueError(.too_many_requests, .{ .retry_after_ms = 100 });
    var diagnostics: Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();
    try testing.expectError(error.RateLimited, h.client.ask(state, questions, .{ .diagnostics = &diagnostics }));
    try testing.expectEqual(1, h.server.requestCount());
    try testing.expectEqual(100, diagnostics.retry_after_ms.?);
}

test "a per-call retry policy replaces the client's" {
    const h = try Harness.init(.{ .retry = fast_retry });
    defer h.deinit();
    try h.server.enqueueError(.service_unavailable, .{});
    try testing.expectError(error.ServerError, h.client.ask(state, questions, .{ .retry = .disabled }));
    try testing.expectEqual(1, h.server.requestCount());
}

test "an attempt that exceeds the timeout fails with Timeout" {
    const h = try Harness.init(.{ .timeout = .fromMilliseconds(100), .retry = .disabled });
    defer h.deinit();
    try h.server.enqueueAnswers(questions, answers, .{ .delay = .fromSeconds(5) });

    var diagnostics: Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();
    const started: Io.Clock.Timestamp = .now(testing.io, .awake);
    try testing.expectError(error.Timeout, h.client.ask(state, questions, .{ .diagnostics = &diagnostics }));
    const elapsed_ms = started.untilNow(testing.io).raw.toMilliseconds();
    try testing.expect(elapsed_ms < 2000);
    try testing.expectEqual(error.Timeout, diagnostics.cause.?);
    try testing.expectEqualStrings("no complete response within 100ms", diagnostics.message.?);
}

test "a timed-out attempt is retried" {
    // Replies are matched to requests in arrival order, so the timeout leaves
    // the server ample time to read the first request even on a loaded machine.
    const h = try Harness.init(.{ .timeout = .fromMilliseconds(1500), .retry = fast_retry });
    defer h.deinit();
    try h.server.enqueueAnswers(questions, answers, .{ .delay = .fromSeconds(30) });
    try h.server.enqueueAnswers(questions, answers, .{ .request_id = "req_second" });

    var result = try h.client.ask(state, questions, .{});
    defer result.deinit();
    try testing.expectEqual(2, result.attempts);
    try testing.expectEqualStrings("req_second", result.request_id.?);
}

test "a dropped connection is retried" {
    const h = try Harness.init(.{ .retry = fast_retry });
    defer h.deinit();
    try h.server.enqueue(.{ .drop = true });
    try h.server.enqueueAnswers(questions, answers, .{});

    var result = try h.client.ask(state, questions, .{});
    defer result.deinit();
    try testing.expectEqual(2, result.attempts);
}

test "an unreachable server fails with ConnectionFailed" {
    const gpa = testing.allocator;
    // Port 1 is privileged, so no test server running alongside can take it.
    var client: Client = try .init(gpa, testing.io, .{ .api_key = "k", .base_url = "http://127.0.0.1:1", .retry = .disabled });
    defer client.deinit();

    var diagnostics: Diagnostics = .init(gpa);
    defer diagnostics.deinit();
    try testing.expectError(error.ConnectionFailed, client.ask(state, questions, .{ .diagnostics = &diagnostics }));
    try testing.expectEqual(error.ConnectionRefused, diagnostics.cause.?);
    try testing.expectEqual(null, diagnostics.status);
    try testing.expectEqual(1, diagnostics.attempts);
}

test "a 2xx body that does not match the schema is InvalidResponse with a path" {
    const h = try Harness.init(.{});
    defer h.deinit();
    var diagnostics: Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();

    const body =
        \\{"model":"jev-1.13.0","answers":{"is_urgent":{"type":"noul","noul":0.9},"department":{"type":"choice","choice":"legal","probabilities":{},"confidence":1}}}
    ;
    try h.server.enqueue(.{ .body = body, .headers = &.{.{ .name = "x-typesafe-request-id", .value = "req_bad" }} });
    try testing.expectError(error.InvalidResponse, h.client.ask(state, questions, .{ .diagnostics = &diagnostics }));
    try testing.expectEqualStrings("answers.department.choice", diagnostics.path.?);
    try testing.expectEqualStrings("\"legal\" is not an option of the question", diagnostics.message.?);
    try testing.expectEqualStrings(body, diagnostics.body.?);
    try testing.expectEqualStrings("req_bad", diagnostics.request_id.?);
    try testing.expectEqual(std.http.Status.ok, diagnostics.status.?);

    try h.server.enqueue(.{ .body = "<html>gateway</html>" });
    try testing.expectError(error.InvalidResponse, h.client.ask(state, questions, .{ .diagnostics = &diagnostics }));
    try testing.expect(std.mem.startsWith(u8, diagnostics.message.?, "response body is not valid JSON"));
}

test "a response larger than max_response_bytes is rejected" {
    const h = try Harness.init(.{ .max_response_bytes = 64 });
    defer h.deinit();
    try h.server.enqueueAnswers(questions, answers, .{});
    try testing.expectError(error.ResponseTooLarge, h.client.ask(state, questions, .{}));

    // The client still works afterwards.
    try h.server.enqueue(.{ .body = "{\"models\":[]}" });
    var models = try h.client.listModels(.{});
    defer models.deinit();
    try testing.expectEqual(0, models.models.len);
}

test "invalid requests fail before anything is sent" {
    const h = try Harness.init(.{});
    defer h.deinit();
    var diagnostics: Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();

    const bad_state: []const u8 = "caf\xe9";
    try testing.expectError(error.InvalidRequest, h.client.ask(.{ .text = bad_state }, questions, .{ .diagnostics = &diagnostics }));
    try testing.expectEqualStrings("state.text", diagnostics.path.?);
    try testing.expectEqualStrings("string is not valid UTF-8", diagnostics.message.?);
    try testing.expectEqual(0, diagnostics.attempts);

    try testing.expectError(error.InvalidRequest, h.client.ask(state, questions, .{
        .extra_headers = &.{.{ .name = "Authorization", .value = "Bearer stolen" }},
        .diagnostics = &diagnostics,
    }));
    try testing.expectEqualStrings("cannot override reserved header \"Authorization\"", diagnostics.message.?);

    try testing.expectError(error.InvalidRequest, h.client.ask(state, questions, .{ .model = "", .diagnostics = &diagnostics }));
    try testing.expectEqualStrings("model", diagnostics.path.?);

    try testing.expectEqual(0, h.server.requestCount());
}

test "listModels" {
    const h = try Harness.init(.{});
    defer h.deinit();
    try h.server.enqueue(.{
        .body = @embedFile("testdata/responses/recorded_models.json"),
        .headers = &.{.{ .name = "x-typesafe-request-id", .value = "req_models" }},
    });

    var models = try h.client.listModels(.{});
    defer models.deinit();
    try testing.expectEqual(2, models.models.len);
    try testing.expectEqualStrings("jev-preview", models.find("jev-preview").?.name);
    try testing.expectEqual(null, models.find("jev-0"));
    try testing.expectEqualStrings("req_models", models.request_id.?);

    const request = h.server.request(0);
    try testing.expectEqual(std.http.Method.GET, request.method);
    try testing.expectEqualStrings("/v1/models", request.target);
    try testing.expectEqual(null, request.header("content-type"));
    try testing.expectEqualStrings("", request.body);
}

test "askDynamic" {
    const h = try Harness.init(.{});
    defer h.deinit();
    try h.server.enqueueAnswers(questions, answers, .{});

    const dynamic_questions = [_]dynamic.Question{
        .{ .id = "is_urgent", .spec = .{ .noul = .{
            .instructions = .{ .string = "Does this convey urgency?" },
            .yes = .{ .string = "Explicitly time-sensitive" },
            .no = .{ .string = "No urgency expressed" },
        } } },
        .choice("department", "Which team should handle this?", .{ .described = &.{
            .{ .name = "billing", .description = .{ .string = "Payments, invoicing, refunds" } },
            .{ .name = "technical", .description = .{ .string = "Bugs, outages, integrations" } },
            .{ .name = "sales" },
        } }),
        .score("frustration", "How frustrated is the customer?", .{ .text = &.{ "Calm", "Frustrated", "Very angry" } }),
    };
    var result = try h.client.askDynamic(state, &dynamic_questions, .{});
    defer result.deinit();

    try testing.expectEqual(0.95, result.get("is_urgent").?.noul.noul);
    const department = result.get("department").?.choice;
    try testing.expectEqualStrings("billing", department.choice);
    try testing.expectEqual(0.15, department.probability("technical").?);
    try testing.expectEqual(1, result.get("frustration").?.score.maxLevel());
    try testing.expectEqual(null, result.get("missing"));

    // The dynamic request is byte-for-byte the typed one.
    try h.server.enqueueAnswers(questions, answers, .{});
    var typed = try h.client.ask(state, questions, .{});
    defer typed.deinit();
    try testing.expectEqualStrings(h.server.request(1).body, h.server.request(0).body);

    var diagnostics: Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();
    const invalid = [_]dynamic.Question{.score("s", "Rate", .{ .text = &.{"only one"} })};
    try testing.expectError(error.InvalidRequest, h.client.askDynamic(state, &invalid, .{ .diagnostics = &diagnostics }));
    try testing.expectEqualStrings("questions.s.criteria", diagnostics.path.?);
    try testing.expectEqual(2, h.server.requestCount());
}

fn askOne(client: *Client, results: *std.atomic.Value(u32)) Io.Cancelable!void {
    var result = client.ask(state, questions, .{}) catch |err| {
        std.log.err("concurrent ask failed: {t}", .{err});
        return;
    };
    defer result.deinit();
    if (result.answers.department.choice == .billing) _ = results.fetchAdd(1, .monotonic);
}

test "many concurrent calls share one client" {
    const h = try Harness.init(.{});
    defer h.deinit();
    const calls = 12;
    for (0..calls) |_| try h.server.enqueueAnswers(questions, answers, .{ .delay = .fromMilliseconds(20) });

    var successes: std.atomic.Value(u32) = .init(0);
    var group: Io.Group = .init;
    for (0..calls) |_| try group.concurrent(testing.io, askOne, .{ &h.client, &successes });
    try group.await(testing.io);

    try testing.expectEqual(calls, successes.load(.monotonic));
    try testing.expectEqual(calls, h.server.requestCount());
}

fn askForCancel(client: *Client) anyerror!void {
    var result = try client.ask(state, questions, .{});
    result.deinit();
}

test "canceling the calling task cancels the request" {
    const h = try Harness.init(.{ .timeout = .fromSeconds(30) });
    defer h.deinit();
    try h.server.enqueueAnswers(questions, answers, .{ .delay = .fromSeconds(30) });

    var task = try testing.io.concurrent(askForCancel, .{&h.client});
    // Let the request reach the server before canceling.
    while (h.server.requestCount() == 0) try testing.io.sleep(.fromMilliseconds(5), .awake);
    const started: Io.Clock.Timestamp = .now(testing.io, .awake);
    try testing.expectError(error.Canceled, task.cancel(testing.io));
    try testing.expect(started.untilNow(testing.io).raw.toMilliseconds() < 2000);
}

test "a gzip-compressed body is decompressed" {
    const gpa = testing.allocator;
    const h = try Harness.init(.{});
    defer h.deinit();

    const json_body = try @import("wire.zig").encodeAnswers(gpa, questions, answers, .{});
    defer gpa.free(json_body);

    var compressed: std.Io.Writer.Allocating = .init(gpa);
    defer compressed.deinit();
    try compressed.ensureUnusedCapacity(64);
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    var compressor: std.compress.flate.Compress = try .init(&compressed.writer, window, .gzip, .default);
    try compressor.writer.writeAll(json_body);
    try compressor.finish();

    try h.server.enqueue(.{
        .body = compressed.written(),
        .headers = &.{.{ .name = "content-encoding", .value = "gzip" }},
    });
    var result = try h.client.ask(state, questions, .{});
    defer result.deinit();
    try testing.expectEqual(Team.billing, result.answers.department.choice);
}

test "a short non-JSON error body stays readable in the diagnostics" {
    const h = try Harness.init(.{ .retry = .disabled });
    defer h.deinit();
    var diagnostics: Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();

    try h.server.enqueue(.{ .status = .bad_gateway, .body = "upstream connect error", .content_type = "text/plain" });
    try testing.expectError(error.ServerError, h.client.ask(state, questions, .{ .diagnostics = &diagnostics }));
    // The response body is freed by now; the message must be a copy.
    try testing.expectEqualStrings("upstream connect error", diagnostics.message.?);

    try h.server.enqueue(.{ .status = .bad_request, .body = "{\"detail\":{\"error_type\":\"x\"}}" });
    try testing.expectError(error.BadRequest, h.client.ask(state, questions, .{ .diagnostics = &diagnostics }));
    try testing.expectEqualStrings("{\"detail\":{\"error_type\":\"x\"}}", diagnostics.message.?);
    try testing.expectEqualStrings("x", diagnostics.error_type.?);
}

test "a request cut off mid-upload never shares its connection with the next one" {
    const gpa = testing.allocator;
    const h = try Harness.init(.{ .timeout = .fromMilliseconds(300), .retry = .disabled });
    defer h.deinit();

    // A state far larger than the socket buffers, which the server never reads.
    const big = try gpa.alloc(u8, 32 * 1024 * 1024);
    defer gpa.free(big);
    @memset(big, 'x');
    try h.server.enqueue(.{ .read_body = false, .delay = .fromSeconds(5) });
    try testing.expectError(error.Timeout, h.client.ask(big, questions, .{}));

    // The next call must open a fresh connection and succeed, not write into
    // the unfinished body of the first.
    try h.server.enqueueAnswers(questions, answers, .{});
    var result = try h.client.ask(state, questions, .{});
    defer result.deinit();
    try testing.expectEqual(1, result.attempts);
    try testing.expectEqualStrings("/v1/systemone", h.server.request(1).target);
}

test "a keep-alive connection the server closed is replaced without using a retry" {
    const h = try Harness.init(.{ .retry = .disabled });
    defer h.deinit();
    try h.server.enqueue(.{ .body = "{\"models\":[]}", .close_after = true });
    try h.server.enqueue(.{ .body = "{\"models\":[]}" });

    var first = try h.client.listModels(.{});
    first.deinit();
    // The server closed the pooled connection; the call still succeeds.
    var second = try h.client.listModels(.{});
    defer second.deinit();
    try testing.expectEqual(1, second.attempts);
    try testing.expectEqual(2, h.server.requestCount());
}

test "a body cut short by a closed connection is a retryable ConnectionFailed" {
    const h = try Harness.init(.{ .retry = fast_retry });
    defer h.deinit();
    var diagnostics: Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();

    try h.server.enqueue(.{ .body = "{\"models\":[{\"name\":\"jev-latest\"}]}", .truncate_body_to = 10 });
    try h.server.enqueue(.{ .body = "{\"models\":[]}" });
    var models = try h.client.listModels(.{ .diagnostics = &diagnostics });
    defer models.deinit();
    try testing.expectEqual(2, models.attempts);

    try h.server.enqueue(.{ .body = "{\"models\":[]}", .truncate_body_to = 3 });
    try testing.expectError(error.ConnectionFailed, h.client.listModels(.{ .retry = .disabled, .diagnostics = &diagnostics }));
    try testing.expectEqual(error.ResponseTruncated, diagnostics.cause.?);
}

test "max_response_bytes accepts a body of exactly that size" {
    const body = "{\"models\":[]}";
    const h = try Harness.init(.{ .max_response_bytes = body.len });
    defer h.deinit();
    try h.server.enqueue(.{ .body = body });
    var models = try h.client.listModels(.{});
    models.deinit();

    try h.server.enqueue(.{ .body = body ++ " " });
    try testing.expectError(error.ResponseTooLarge, h.client.listModels(.{}));
}

test "an unsupported content encoding is InvalidResponse, not retried" {
    const h = try Harness.init(.{ .retry = fast_retry });
    defer h.deinit();
    try h.server.enqueue(.{ .body = "{\"models\":[]}", .headers = &.{.{ .name = "content-encoding", .value = "zstd" }} });
    try testing.expectError(error.InvalidResponse, h.client.listModels(.{}));
    try testing.expectEqual(1, h.server.requestCount());
}

test "diagnostics describe the call, not an earlier failed attempt, after a retry succeeds" {
    const h = try Harness.init(.{ .retry = fast_retry });
    defer h.deinit();
    var diagnostics: Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();

    try h.server.enqueueError(.service_unavailable, .{ .message = "slow down", .request_id = "req_first" });
    try h.server.enqueueAnswers(questions, answers, .{ .request_id = "req_second" });
    var result = try h.client.ask(state, questions, .{ .diagnostics = &diagnostics });
    defer result.deinit();

    try testing.expectEqual(null, diagnostics.err);
    try testing.expectEqual(null, diagnostics.message);
    try testing.expectEqual(2, diagnostics.attempts);
    try testing.expectEqual(std.http.Status.ok, diagnostics.status.?);
    try testing.expectEqualStrings("req_second", diagnostics.request_id.?);
}

test "a custom retryable status predicate replaces the default" {
    const retry_conflicts: Retry = .{
        .backoff_initial_ms = 1,
        .jitter = 0,
        .isRetryableStatus = struct {
            fn retryable(status: std.http.Status) bool {
                return status == .conflict;
            }
        }.retryable,
    };
    const h = try Harness.init(.{ .retry = retry_conflicts });
    defer h.deinit();

    try h.server.enqueue(.{ .status = .conflict, .body = "{}" });
    try h.server.enqueue(.{ .body = "{\"models\":[]}" });
    var models = try h.client.listModels(.{});
    models.deinit();
    try testing.expectEqual(2, h.server.requestCount());

    try h.server.enqueue(.{ .status = .service_unavailable, .body = "{}" });
    try testing.expectError(error.ServerError, h.client.listModels(.{}));
    try testing.expectEqual(3, h.server.requestCount());
}

test "hooks see calls rejected for invalid options" {
    const Counter = struct {
        starts: u32 = 0,
        ends: u32 = 0,
        last_err: ?anyerror = null,
        fn onStart(context: ?*anyopaque, _: *const hooks.RequestStart) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.starts += 1;
        }
        fn onEnd(context: ?*anyopaque, event: *const hooks.RequestEnd) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.ends += 1;
            self.last_err = event.err;
        }
    };
    var counter: Counter = .{};
    const h = try Harness.init(.{ .hooks = .{ .context = &counter, .onRequestStart = Counter.onStart, .onRequestEnd = Counter.onEnd } });
    defer h.deinit();

    try testing.expectError(error.InvalidRequest, h.client.ask(state, questions, .{ .model = "" }));
    try testing.expectEqual(1, counter.starts);
    try testing.expectEqual(1, counter.ends);
    try testing.expectEqual(error.InvalidRequest, counter.last_err.?);
}

test "timeouts: Io.Duration.max disables, anything above max_timeout is rejected" {
    const gpa = testing.allocator;
    var unlimited: Client = try .init(gpa, testing.io, .{ .api_key = "k", .timeout = .max });
    defer unlimited.deinit();
    try testing.expectEqual(null, unlimited.timeout);

    const too_long: Io.Duration = .{ .nanoseconds = Client.max_timeout.nanoseconds + 1 };
    try testing.expectError(error.InvalidTimeout, Client.init(gpa, testing.io, .{ .api_key = "k", .timeout = too_long }));

    const h = try Harness.init(.{});
    defer h.deinit();
    var diagnostics: Diagnostics = .init(gpa);
    defer diagnostics.deinit();
    try testing.expectError(error.InvalidRequest, h.client.listModels(.{ .timeout = too_long, .diagnostics = &diagnostics }));
    try testing.expectEqualStrings("timeout", diagnostics.path.?);
    try h.server.enqueue(.{ .body = "{\"models\":[]}" });
    var models = try h.client.listModels(.{ .timeout = .max });
    models.deinit();
}

test "base URLs std.http.Client cannot use are rejected at init" {
    const gpa = testing.allocator;
    var upper: Client = try .init(gpa, testing.io, .{ .api_key = "k", .base_url = "HTTPS://api.typesafe.ai/" });
    defer upper.deinit();
    try testing.expectEqualStrings("https://api.typesafe.ai", upper.base_url);

    try testing.expectError(error.InvalidBaseUrl, Client.init(gpa, testing.io, .{ .api_key = "k", .base_url = "http://[::1]:8080" }));
    try testing.expectError(error.InvalidBaseUrl, Client.init(gpa, testing.io, .{ .api_key = "k", .base_url = "http://" ++ "a" ** 300 }));
    try testing.expectError(error.InvalidBaseUrl, Client.init(gpa, testing.io, .{ .api_key = "k", .base_url = "http://" ++ "%61" ** 280 }));
}

test "an HTTPS base URL refuses to run through a proxy" {
    const gpa = testing.allocator;
    var client: Client = try .init(gpa, testing.io, .{ .api_key = "k", .base_url = "https://127.0.0.1:1", .retry = .disabled });
    defer client.deinit();
    var proxy: std.http.Client.Proxy = .{
        .protocol = .plain,
        .host = try .init("127.0.0.1"),
        .authorization = null,
        .port = 3128,
        .supports_connect = true,
    };
    client.http.https_proxy = &proxy;

    var diagnostics: Diagnostics = .init(gpa);
    defer diagnostics.deinit();
    try testing.expectError(error.InvalidRequest, client.ask(state, questions, .{ .diagnostics = &diagnostics }));
    try testing.expect(std.mem.startsWith(u8, diagnostics.message.?, "HTTPS requests through a proxy are not supported"));
    try testing.expectEqual(0, diagnostics.attempts);
}

test "withExtra sends additional wire fields" {
    const h = try Harness.init(.{});
    defer h.deinit();
    const extended = .{
        .is_urgent = question.withExtra(question.noul("Does this convey urgency?", .{}), .{ .future_field = .{ .enabled = true } }),
    };
    try h.server.enqueueAnswers(extended, .{ .is_urgent = .{ .noul = 0.5 } }, .{});
    var result = try h.client.ask(state, extended, .{});
    defer result.deinit();
    try testing.expectEqual(0.5, result.answers.is_urgent.noul);
    try testing.expect(std.mem.endsWith(u8, h.server.request(0).body,
        \\"questions":{"is_urgent":{"type":"noul","instructions":"Does this convey urgency?","future_field":{"enabled":true}}}}
    ));
}

test "diagnostics after a retried error and an undecodable response hold only the final attempt" {
    const h = try Harness.init(.{ .retry = fast_retry });
    defer h.deinit();
    var diagnostics: Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();

    try h.server.enqueueError(.too_many_requests, .{ .error_type = "rate_limit_error", .retry_after_ms = 1, .request_id = "req_429" });
    try h.server.enqueue(.{ .body = "{\"models\":\"nope\"}" });
    try testing.expectError(error.InvalidResponse, h.client.listModels(.{ .diagnostics = &diagnostics }));
    try testing.expectEqual(null, diagnostics.error_type);
    try testing.expectEqual(null, diagnostics.retry_after_ms);
    try testing.expectEqual(null, diagnostics.request_id);
    try testing.expectEqual(std.http.Status.ok, diagnostics.status.?);
    try testing.expectEqualStrings("models", diagnostics.path.?);
    try testing.expectEqual(2, diagnostics.attempts);
}
