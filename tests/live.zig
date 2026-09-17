//! Live tests against api.typesafe.ai. They make billable requests (fractions
//! of a cent each) and need `TYPESAFE_API_KEY`:
//!
//!     TYPESAFE_API_KEY=... zig build test-live
//!
//! `zig build test` never runs them. CI runs them on a schedule with a
//! repository secret. Every test that needs `TYPESAFE_API_KEY` is skipped when
//! it is unset, so running the step without one reports skips, not failures.

const std = @import("std");
const testing = std.testing;
const typesafe = @import("typesafe");

const Team = enum { billing, technical, sales };

const ticket = "Help! My payouts have been failing for 3 days.";

fn liveClient(options: typesafe.Client.Options) !typesafe.Client {
    const gpa = testing.allocator;
    var environ_map = try testing.environ.createMap(gpa);
    defer environ_map.deinit();
    return typesafe.Client.initFromEnv(gpa, testing.io, &environ_map, options) catch |err| {
        if (err == error.MissingApiKey) return error.SkipZigTest;
        return err;
    };
}

fn expectProbability(p: f64) !void {
    try testing.expect(p >= 0 and p <= 1);
}

test "asks all three question types in one request" {
    var client = try liveClient(.{});
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

    var diagnostics: typesafe.Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();
    var result = client.ask(ticket, questions, .{ .diagnostics = &diagnostics }) catch |err| {
        std.debug.print("\n{f}\n", .{diagnostics});
        return err;
    };
    defer result.deinit();

    try testing.expect(std.mem.startsWith(u8, result.model, "jev-"));
    try testing.expect(std.mem.startsWith(u8, result.request_id.?, "req_"));
    try testing.expect(result.usage.input_tokens.? > 0);

    const answers = result.answers;
    try expectProbability(answers.is_urgent.noul);
    try testing.expect(answers.is_urgent.isYes(0.5));

    const department = answers.department;
    var total: f64 = 0;
    for (department.ranked()) |entry| {
        try expectProbability(entry.probability);
        total += entry.probability;
    }
    try testing.expectApproxEqAbs(1.0, total, 0.05);
    try expectProbability(department.confidence);
    try testing.expectEqual(department.ranked()[0].option, department.choice);
    try testing.expectEqual(Team.billing, department.choice);

    const frustration = answers.frustration;
    try testing.expect(frustration.score >= 0 and frustration.score <= 2);
    try testing.expectEqualStrings("Calm", frustration.legend[0].string);
    try testing.expectEqualStrings("Very angry", frustration.legend[2].string);
    for (frustration.probabilities) |p| try expectProbability(p);
}

test "passes structured state, instructions and criteria through as JSON" {
    var client = try liveClient(.{});
    defer client.deinit();

    const Route = enum { billing, technical, other };
    const questions = .{
        .route = typesafe.choice(Route, .{ .task = "Route the ticket", .notes = .{"Prefer billing for charges"} }, .{
            .billing = .{ .covers = .{ "refunds", "charges" } },
            .technical = .{ "bugs", "outages" },
        }),
        .severity = typesafe.score(.{ "Rate", "severity" }, .{ .{ .level = "low" }, .{"medium"}, "high" }),
        .refund = typesafe.noul(null, .{ .yes = .{ .asks_for = "refund" }, .no = null }),
    };
    const state = .{ .messages = .{.{ .role = "user", .text = "Please refund my duplicate charge" }} };

    var result = try client.ask(state, questions, .{});
    defer result.deinit();

    try testing.expectEqual(Route.billing, result.answers.route.choice);
    const legend = result.answers.severity.legend;
    try testing.expectEqualStrings("low", legend[0].object.get("level").?.string);
    try testing.expectEqualStrings("medium", legend[1].array.items[0].string);
    try testing.expectEqualStrings("high", legend[2].string);
    try testing.expect(result.answers.refund.noul > 0.5);
}

test "option names that are not identifiers round-trip" {
    var client = try liveClient(.{});
    defer client.deinit();

    const Department = enum { @"Sporting Goods", @"Home & Kitchen", @"Baby & Toddler" };
    const questions = .{
        .department = typesafe.choice(Department, "Which top-level department does this product belong to?", .{
            .@"Sporting Goods" = .{ .Cycling = .{ "Bike Bottles & Cages", "Bike Lights", "Helmets" } },
            .@"Home & Kitchen" = .{ .Drinkware = .{ "Water Bottles", "Travel Mugs", "Tumblers" } },
            .@"Baby & Toddler" = .{ "Sippy Cups", "Bottle Warmers", "Bibs" },
        }),
    };
    var result = try client.ask("32oz plastic bottle with a flip straw lid. Fits most bike cages.", questions, .{});
    defer result.deinit();
    try testing.expect(result.answers.department.choice != .@"Baby & Toddler");
}

test "asks dynamic questions" {
    var client = try liveClient(.{});
    defer client.deinit();

    const questions = [_]typesafe.dynamic.Question{
        .noul("is_urgent", "Does this convey urgency?"),
        .choice("department", "Which team should handle this?", .{ .names = &.{ "billing", "technical", "sales" } }),
        .score("frustration", "How frustrated is the customer?", .{ .text = &.{ "Calm", "Frustrated", "Very angry" } }),
    };
    var result = try client.askDynamic(ticket, &questions, .{ .model = "jev-preview" });
    defer result.deinit();

    try expectProbability(result.get("is_urgent").?.noul.noul);
    const department = result.get("department").?.choice;
    try testing.expectEqualStrings("billing", department.choice);
    try testing.expectEqual(3, department.probabilities.len);
    try testing.expectEqual(3, result.get("frustration").?.score.probabilities.len);
}

test "lists models" {
    var client = try liveClient(.{});
    defer client.deinit();

    var models = try client.listModels(.{});
    defer models.deinit();
    try testing.expect(models.models.len > 0);
    try testing.expect(models.find("jev-latest") != null);
    try testing.expect(std.mem.startsWith(u8, models.request_id.?, "req_"));
}

test "a bad API key is Unauthorized with a request id" {
    var client = try liveClient(.{ .api_key = "ts_invalid_key", .retry = .disabled });
    defer client.deinit();

    var diagnostics: typesafe.Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();
    const questions = .{ .greeting = typesafe.noul("Is this a greeting?", .{}) };
    try testing.expectError(error.Unauthorized, client.ask("hello", questions, .{ .diagnostics = &diagnostics }));
    try testing.expectEqual(std.http.Status.unauthorized, diagnostics.status.?);
    try testing.expect(std.mem.startsWith(u8, diagnostics.request_id.?, "req_"));
    try testing.expectEqualStrings("authentication_error", diagnostics.error_type.?);
    try testing.expectEqual(1, diagnostics.attempts);
}

test "an unknown model is BadRequest naming the model" {
    var client = try liveClient(.{});
    defer client.deinit();

    var diagnostics: typesafe.Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();
    const questions = .{ .greeting = typesafe.noul("Is this a greeting?", .{}) };
    try testing.expectError(error.BadRequest, client.ask("hello", questions, .{
        .model = "no-such-model",
        .diagnostics = &diagnostics,
    }));
    try testing.expect(std.mem.find(u8, diagnostics.message.?, "no-such-model") != null);
    try testing.expectEqualStrings("api_usage_error", diagnostics.error_type.?);
}

test "a timeout shorter than the round trip fails with Timeout" {
    var client = try liveClient(.{ .timeout = .fromMilliseconds(1), .retry = .disabled });
    defer client.deinit();

    const questions = .{ .greeting = typesafe.noul("Is this a greeting?", .{}) };
    try testing.expectError(error.Timeout, client.ask("hello", questions, .{}));

    // The same client recovers once the timeout allows a round trip.
    var result = try client.ask("hello", questions, .{ .timeout = .fromSeconds(30) });
    defer result.deinit();
    try expectProbability(result.answers.greeting.noul);
}

fn askConcurrently(client: *typesafe.Client, text: []const u8, successes: *std.atomic.Value(u32)) std.Io.Cancelable!void {
    const questions = .{ .greeting = typesafe.noul("Is this a greeting?", .{}) };
    var result = client.ask(text, questions, .{}) catch |err| {
        std.debug.print("\nconcurrent live ask failed: {t}\n", .{err});
        return;
    };
    defer result.deinit();
    _ = successes.fetchAdd(1, .monotonic);
}

test "concurrent calls share one client and its connection pool" {
    var client = try liveClient(.{});
    defer client.deinit();

    const texts = [_][]const u8{ "hello there", "good morning", "the invoice is attached", "hi!", "please advise", "hey team" };
    var successes: std.atomic.Value(u32) = .init(0);
    var group: std.Io.Group = .init;
    for (texts) |text| try group.concurrent(testing.io, askConcurrently, .{ &client, text, &successes });
    try group.await(testing.io);
    try testing.expectEqual(texts.len, successes.load(.monotonic));
}

test "hooks observe a live call" {
    const Counter = struct {
        ends: u32 = 0,
        status: ?std.http.Status = null,
        request_id_ok: bool = false,

        fn onEnd(context: ?*anyopaque, event: *const typesafe.hooks.RequestEnd) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.ends += 1;
            self.status = event.status;
            if (event.request_id) |id| self.request_id_ok = std.mem.startsWith(u8, id, "req_");
        }
    };
    var counter: Counter = .{};
    var client = try liveClient(.{ .hooks = .{ .context = &counter, .onRequestEnd = Counter.onEnd } });
    defer client.deinit();

    var models = try client.listModels(.{});
    defer models.deinit();
    try testing.expectEqual(1, counter.ends);
    try testing.expectEqual(std.http.Status.ok, counter.status.?);
    try testing.expect(counter.request_id_ok);
}

test "a long-running client reloads its TLS trust and keeps reusing connections" {
    var client = try liveClient(.{ .retry = .disabled });
    defer client.deinit();

    var first = try client.listModels(.{});
    first.deinit();
    const loaded = client.http.now.?;

    // Pretend the roots were loaded two hours ago: the next call reloads them.
    client.http.now = loaded.subDuration(.fromSeconds(2 * std.time.s_per_hour));
    for (0..3) |_| {
        var models = try client.listModels(.{});
        models.deinit();
    }
    try testing.expect(client.http.now.?.nanoseconds >= loaded.nanoseconds);

    // A fresh connection verifies the certificate against the reloaded roots.
    const pool = &client.http.connection_pool;
    const criteria: std.http.Client.ConnectionPool.Criteria = .{ .host = try .init("api.typesafe.ai"), .port = 443, .protocol = .tls };
    while (pool.findConnection(testing.io, criteria)) |connection| {
        connection.closing = true;
        pool.release(connection, testing.io);
    }
    var fresh = try client.listModels(.{});
    fresh.deinit();
}
