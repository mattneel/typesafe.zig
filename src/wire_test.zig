//! Wire-format tests against the request and response fixtures shared with
//! the Elixir client, plus regression tests for the strict encoder.

const std = @import("std");
const testing = std.testing;
const json = @import("json.zig");
const question = @import("question.zig");
const wire = @import("wire.zig");

const noul = question.noul;
const choice = question.choice;
const score = question.score;

const ticket = "Help! My payouts have been failing for 3 days.";

fn expectRequest(comptime fixture: []const u8, state: anytype, questions: anytype) !void {
    const gpa = testing.allocator;
    var failure: json.Failure = .{};
    const body = wire.encodeAsk(gpa, state, "jev-latest", questions, &failure) catch |err| {
        std.debug.print("encode failed at {s}: {s}\n", .{ failure.path(), failure.message() });
        return err;
    };
    defer gpa.free(body);

    var expected = try std.json.parseFromSlice(std.json.Value, gpa, @embedFile("testdata/requests/" ++ fixture), .{});
    defer expected.deinit();
    const normalized = try std.json.Stringify.valueAlloc(gpa, expected.value, .{});
    defer gpa.free(normalized);
    try testing.expectEqualStrings(normalized, body);
}

test "request fixture: noul" {
    try expectRequest("noul.json", ticket, .{ .is_urgent = noul("Does this convey urgency?", .{}) });
}

test "request fixture: noul with criteria" {
    try expectRequest("noul_criteria.json", ticket, .{
        .is_urgent = noul("Does this convey urgency?", .{ .yes = "Explicitly time-sensitive", .no = "No urgency expressed" }),
    });
}

test "request fixture: choice" {
    const Team = enum { billing, technical, sales };
    try expectRequest("choice.json", ticket, .{
        .department = choice(Team, "Which team should handle this?", .{
            .billing = "Payments, invoicing, refunds",
            .technical = "Bugs, outages, integrations",
            .sales = "Pricing, upgrades, new accounts",
        }),
    });
}

test "request fixture: score" {
    try expectRequest("score.json", ticket, .{
        .frustration = score("How frustrated is the customer?", .{ "Calm", "Frustrated", "Very angry" }),
    });
}

test "request fixture: structured choice rubric" {
    const Department = enum { billing, orders, account };
    try expectRequest(
        "structured_choice_rubric.json",
        "I ordered the standing desk two weeks ago and tracking still says label created. Was I even charged?",
        .{
            .department = choice(Department, .{
                .question = "Which team should handle this message?",
                .focus = "Classify the customer's primary request, not every topic mentioned.",
            }, .{
                .billing = .{
                    .what = "Charges, invoices, refunds, or subscriptions",
                    .not_for = "Order tracking or account access",
                    .examples = .{ "I was charged twice", "Where is my refund?" },
                },
                .orders = .{
                    .what = "Order status, delivery, cancellation, or returns",
                    .not_for = "Charges or account access",
                    .examples = .{ "Where is my package?", "Cancel my order" },
                },
                .account = .{
                    .what = "Login, password, profile, or security",
                    .not_for = "Charges or delivery",
                    .examples = .{ "I can't log in", "Change my email" },
                },
            }),
        },
    );
}

test "request fixture: structured noul criteria" {
    try expectRequest("structured_noul_criteria.json", .{
        .sender = .{ .display_name = "Beaver Dam Builders Ltd.", .email = "donotreply@payroll.example" },
        .message = "Your Q3 bonus is ready. Reply with your login password so we can verify your identity and release the funds.",
    }, .{
        .requests_credentials = noul(.{
            .question = "Does the `message` ask the recipient to disclose a sensitive credential?",
            .inspect = "message",
            .focus = "Look for a request to send the credential itself, not a request to change or reset it.",
        }, .{
            .yes = .{
                .what = "Asks the recipient to reply with, type, or send a password, PIN, one-time code, or other security sensitive answer",
                .examples = .{ "Reply with your password", "Send us the 6-digit code you just received" },
            },
            .no = .{
                .what = "No sensitive credential is requested",
                .examples = .{ "Reset your password from the settings page", "Your statement is ready" },
            },
        }),
    });
}

test "request fixture: structured score levels" {
    try expectRequest(
        "structured_score_levels.json",
        "Fixed the null check in the payment handler. Also refactored the retry loop while I was in there, and bumped the SDK version since the old one had that timeout bug.",
        .{
            .pr_scope = score(.{
                .question = "How focused is this pull request description on a single change?",
                .note = "Judge the number of independent changes, not the size of any one change.",
            }, .{
                .{
                    .summary = "One change, clearly stated",
                    .signals = .{ "A single fix or feature", "Nothing described as \"also\" or \"while I was in there\"" },
                },
                .{
                    .summary = "One main change plus a small related tweak",
                    .signals = .{ "A primary change and one minor adjacent edit", "The tweak supports the main change" },
                },
                .{
                    .summary = "Several independent changes bundled together",
                    .signals = .{ "Two or more unrelated fixes or features", "Changes that could each be their own PR" },
                },
            }),
        },
    );
}

test "request fixture: structured taxonomy" {
    const Department = enum { @"Sporting Goods", @"Home & Kitchen", @"Baby & Toddler" };
    try expectRequest("structured_taxonomy.json", "32oz plastic bottle with a flip straw lid. Fits most bike cages.", .{
        .department = choice(Department, "Which top-level department does this product belong to?", .{
            .@"Sporting Goods" = .{
                .Cycling = .{ "Bike Bottles & Cages", "Bike Lights", "Helmets" },
                .Fitness = .{ "Yoga Mats", "Resistance Bands" },
                .Outdoor = .{ "Tents", "Sleeping Bags", "Hydration Packs" },
            },
            .@"Home & Kitchen" = .{
                .Drinkware = .{ "Water Bottles", "Travel Mugs", "Tumblers" },
                .Cookware = .{ "Pots & Pans", "Bakeware" },
            },
            .@"Baby & Toddler" = .{ "Sippy Cups", "Bottle Warmers", "Bibs" },
        }),
    });
}

fn decodeFixture(comptime Questions: type, comptime fixture: []const u8, arena: std.mem.Allocator) !wire.Decoded(Questions) {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, @embedFile("testdata/responses/" ++ fixture), .{});
    var dec: json.Decoder = .{};
    return wire.decodeAsk(Questions, &dec, root) catch |err| {
        std.debug.print("decode failed at {s}: {s}\n", .{ dec.failure.path(), dec.failure.message() });
        return err;
    };
}

test "response fixtures: noul, choice, score and a recorded live response" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Team = enum { billing, technical, sales };

    const noul_q = .{ .is_urgent = noul("Urgent?", .{}) };
    const n = try decodeFixture(@TypeOf(noul_q), "noul.json", a);
    try testing.expectEqual(0.92, n.answers.is_urgent.noul);

    const choice_q = .{ .department = choice(Team, "Team?", .{}) };
    const c = try decodeFixture(@TypeOf(choice_q), "choice.json", a);
    try testing.expectEqual(Team.technical, c.answers.department.choice);
    try testing.expectEqual(0.77, c.answers.department.margin());

    const score_q = .{ .frustration = score("Frustration?", .{ "Calm", "Frustrated", "Very angry" }) };
    const s = try decodeFixture(@TypeOf(score_q), "score.json", a);
    try testing.expectEqual(2, s.answers.frustration.expectedLevel());

    const live_q = .{
        .department = choice(Team, "Team?", .{}),
        .frustration = score("Frustration?", .{ "Calm", "Frustrated", "Very angry" }),
        .is_urgent = noul("Urgent?", .{}),
    };
    const live = try decodeFixture(@TypeOf(live_q), "recorded_systemone.json", a);
    try testing.expectEqualStrings("jev-1.13.0", live.model);
    try testing.expectEqual(Team.billing, live.answers.department.choice);
    try testing.expectEqual(0.72, live.answers.department.margin());
    try testing.expectEqual(1, live.answers.frustration.maxLevel());
    try testing.expectEqual(414, live.usage.input_tokens);
}

test "encoder: std.json.Value is checked for depth, UTF-8 and numbers" {
    const gpa = testing.allocator;
    var failure: json.Failure = .{};

    // 300 nested arrays exceed the 256-level limit: an error, not a panic.
    const deep = "[" ** 300 ++ "]" ** 300;
    var parsed_deep = try std.json.parseFromSlice(std.json.Value, gpa, deep, .{});
    defer parsed_deep.deinit();
    try testing.expectError(error.InvalidRequest, json.encodeAlloc(gpa, .{ .state = parsed_deep.value }, &failure));
    try testing.expectEqualStrings("value is nested more than 256 levels deep", failure.message());

    // 200 levels are fine.
    const ok = "[" ** 200 ++ "]" ** 200;
    var parsed_ok = try std.json.parseFromSlice(std.json.Value, gpa, ok, .{});
    defer parsed_ok.deinit();
    const encoded = try json.encodeAlloc(gpa, parsed_ok.value, &failure);
    defer gpa.free(encoded);
    try testing.expectEqualStrings(ok, encoded);

    var map: std.json.ObjectMap = .empty;
    defer map.deinit(gpa);
    try map.put(gpa, "text", .{ .string = "caf\xe9" });
    try testing.expectError(error.InvalidRequest, json.encodeAlloc(gpa, .{ .state = std.json.Value{ .object = map } }, &failure));
    try testing.expectEqualStrings("state.text", failure.path());
    try testing.expectEqualStrings("string is not valid UTF-8", failure.message());

    try testing.expectError(error.InvalidRequest, json.encodeAlloc(gpa, std.json.Value{ .float = std.math.inf(f64) }, &failure));
    try testing.expectError(error.InvalidRequest, json.encodeAlloc(gpa, std.json.Value{ .number_string = "12abc" }, &failure));
    const big = try json.encodeAlloc(gpa, std.json.Value{ .number_string = "123456789012345678901234567890" }, &failure);
    defer gpa.free(big);
    try testing.expectEqualStrings("123456789012345678901234567890", big);
}

test "encoder: an entry that is a non-exhaustive enum must have a name" {
    const gpa = testing.allocator;
    var failure: json.Failure = .{};

    const Stage = enum(u8) { open, closed, _ };
    const named = try wire.encodeAsk(gpa, ticket, "jev-latest", .{ .a = noul(@as(Stage, .open), .{}) }, &failure);
    defer gpa.free(named);
    try testing.expect(std.mem.find(u8, named, "\"instructions\":\"open\"") != null);

    // A value the enum does not declare would be written as a number, which
    // the API never accepts for an entry.
    try testing.expectError(error.InvalidRequest, wire.encodeAsk(
        gpa,
        ticket,
        "jev-latest",
        .{ .a = noul(@as(Stage, @enumFromInt(9)), .{}) },
        &failure,
    ));
    try testing.expectEqualStrings("questions.a.instructions", failure.path());
    try testing.expectEqualStrings("noul instructions must be a string, object, array or null, got a number", failure.message());
}

test "encoder: truncated failure messages stay valid UTF-8" {
    const gpa = testing.allocator;
    var failure: json.Failure = .{};
    const name = "a" ++ "é" ** 200;
    const Q = .{ .x = question.noul("x", .{}) };
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        gpa,
        "{\"model\":\"m\",\"answers\":{\"x\":{\"type\":\"" ++ name ++ "\"}}}",
        .{},
    );
    defer parsed.deinit();
    var dec: json.Decoder = .{};
    try testing.expectError(error.InvalidResponse, wire.decodeAsk(@TypeOf(Q), &dec, parsed.value));
    try testing.expect(std.unicode.utf8ValidateSlice(dec.failure.message()));
    try testing.expect(std.mem.endsWith(u8, dec.failure.message(), "..."));
    _ = &failure;
}

test "questions: empty nouls and null levels found at run time are InvalidRequest" {
    const gpa = testing.allocator;
    var failure: json.Failure = .{};

    var buffer: [8]u8 = undefined;
    const empty = buffer[0..0];
    try testing.expectError(error.InvalidRequest, wire.encodeAsk(gpa, ticket, "jev-latest", .{ .a = noul(empty, .{}) }, &failure));
    try testing.expectEqualStrings("questions.a", failure.path());
    try testing.expectEqualStrings("a noul question needs instructions or criteria", failure.message());

    const missing: ?[]const u8 = null;
    try testing.expectError(error.InvalidRequest, wire.encodeAsk(gpa, ticket, "jev-latest", .{ .a = noul(missing, .{ .yes = missing }) }, &failure));

    // Instructions may be empty when a criterion says what yes means.
    const body = try wire.encodeAsk(gpa, ticket, "jev-latest", .{ .a = noul(empty, .{ .yes = "Asks for a refund" }) }, &failure);
    gpa.free(body);

    const level: ?[]const u8 = null;
    try testing.expectError(error.InvalidRequest, wire.encodeAsk(gpa, ticket, "jev-latest", .{ .s = score("Rate", [_]?[]const u8{ "Low", level }) }, &failure));
    try testing.expectEqualStrings("questions.s.criteria", failure.path());
    try testing.expectEqualStrings("score level 1 must not be null", failure.message());
}

test "questions: withExtra writes its fields after the question's own" {
    const gpa = testing.allocator;
    const Team = enum { billing, other };
    const q = question.withExtra(choice(Team, "Team?", .{}), .{ .hint = "short", .weight = .{ .billing = 2 } });
    try testing.expect(@TypeOf(q).Answer == question.ChoiceAnswer(Team));
    const out = try std.json.Stringify.valueAlloc(gpa, q, .{});
    defer gpa.free(out);
    try testing.expectEqualStrings(
        \\{"type":"choice","instructions":"Team?","criteria":{"billing":null,"other":null},"hint":"short","weight":{"billing":2}}
    , out);

    const s = question.withExtra(score("Rate", .{ "Low", "High" }), .{ .x = true });
    try testing.expectEqualStrings("High", question.scoreLevels(s)[1]);
}

test "answers: margin is rounded to 10 decimal places" {
    const Pair = enum { a, b };
    const answer: question.ChoiceAnswer(Pair) = .{ .choice = .a, .probabilities = .{ .a = 0.3, .b = 0.2 }, .confidence = 0.1 };
    try testing.expectEqual(0.1, answer.margin());
    const split: question.ChoiceAnswer(Pair) = .{ .choice = .a, .probabilities = .{ .a = 0.6, .b = 0.4 }, .confidence = 0.2 };
    try testing.expect(split.margin() >= 0.2);
}

test "quoted error bodies are copies" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var body = "upstream connect error".*;
    const parsed = try wire.parseErrorBody(arena.allocator(), .bad_gateway, &body);
    @memset(&body, 'x');
    try testing.expectEqualStrings("upstream connect error", parsed.message);
}

test "questions: run-time JSON values of the wrong type are InvalidRequest" {
    const gpa = testing.allocator;
    var failure: json.Failure = .{};

    const flag: std.json.Value = .{ .bool = true };
    try testing.expectError(error.InvalidRequest, wire.encodeAsk(gpa, ticket, "jev-latest", .{ .a = noul(flag, .{}) }, &failure));
    try testing.expectEqualStrings("questions.a.instructions", failure.path());
    try testing.expectEqualStrings("noul instructions must be a string, object, array or null, got a boolean", failure.message());

    const Team = enum { billing, other };
    const number: json.RawJson = .{ .text = " 42" };
    try testing.expectError(error.InvalidRequest, wire.encodeAsk(gpa, ticket, "jev-latest", .{ .c = choice(Team, "Team?", .{ .billing = number }) }, &failure));
    try testing.expectEqualStrings("questions.c.criteria.billing", failure.path());

    const raw_null: json.RawJson = .{ .text = "null" };
    try testing.expectError(error.InvalidRequest, wire.encodeAsk(gpa, ticket, "jev-latest", .{ .s = score("Rate", .{ "Low", raw_null }) }, &failure));
    try testing.expectEqualStrings("questions.s.criteria", failure.path());
    try testing.expectEqualStrings("score level 1 must be a string, object or array, got null", failure.message());

    // Structured values are fine.
    const structured: std.json.Value = .{ .string = "Is this urgent?" };
    const body = try wire.encodeAsk(gpa, ticket, "jev-latest", .{ .a = noul(structured, .{ .yes = raw_null }) }, &failure);
    gpa.free(body);
}
