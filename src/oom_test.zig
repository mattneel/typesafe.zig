//! Allocation-failure tests: every allocation on the encode, decode and
//! request paths is made to fail in turn, and each must return
//! `error.OutOfMemory` without leaking.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;

const Client = @import("Client.zig");
const json = @import("json.zig");
const question = @import("question.zig");
const wire = @import("wire.zig");
const dynamic = @import("dynamic.zig");
const dynamic_wire = @import("dynamic_wire.zig");
const MockServer = @import("testing.zig").MockServer;

const Team = enum { billing, technical, sales };

const questions = .{
    .is_urgent = question.noul("Does this convey urgency?", .{ .yes = "Explicitly time-sensitive" }),
    .department = question.choice(Team, .{ .task = "Route the ticket", .notes = .{"Prefer billing"} }, .{
        .billing = "Payments, invoicing, refunds",
    }),
    .frustration = question.score("How frustrated is the customer?", .{ "Calm", "Frustrated", "Very angry" }),
};

const answers: question.Answers(@TypeOf(questions)) = .{
    .is_urgent = .{ .noul = 0.95 },
    .department = .{ .choice = .billing, .probabilities = .{ .billing = 0.85, .technical = 0.15, .sales = 0 }, .confidence = 0.77 },
    .frustration = .{ .score = 1.04, .probabilities = .{ 0, 0.96, 0.04 }, .confidence = 0.93 },
};

const dynamic_questions = [_]dynamic.Question{
    .noul("is_urgent", "Does this convey urgency?"),
    .choice("department", "Which team?", .{ .names = &.{ "billing", "technical", "sales" } }),
    .score("frustration", "How frustrated?", .{ .text = &.{ "Calm", "Frustrated", "Very angry" } }),
};

fn encodeTyped(allocator: std.mem.Allocator) !void {
    var failure: json.Failure = .{};
    const body = try wire.encodeAsk(allocator, .{ .ticket = .{ .text = "Payouts failing" } }, "jev-latest", questions, &failure);
    allocator.free(body);
}

fn encodeDynamic(allocator: std.mem.Allocator) !void {
    var failure: json.Failure = .{};
    const body = try dynamic_wire.encodeRequest(allocator, "Payouts failing", "jev-latest", &dynamic_questions, &failure);
    allocator.free(body);
}

fn decodeBoth(allocator: std.mem.Allocator, body: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), body, .{});
    var dec: json.Decoder = .{};
    _ = try wire.decodeAsk(@TypeOf(questions), &dec, root);
    _ = try dynamic_wire.decodeResponse(arena.allocator(), &dec, &dynamic_questions, root);
}

fn parseError(allocator: std.mem.Allocator) !void {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    _ = try wire.parseErrorBody(arena.allocator(), @enumFromInt(422),
        \\{"detail":[{"type":"too_short","loc":["body","questions"],"msg":"Dictionary should have at least 1 item"}]}
    );
}

test "encoding and decoding survive every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, encodeTyped, .{});
    try testing.checkAllAllocationFailures(testing.allocator, encodeDynamic, .{});
    try testing.checkAllAllocationFailures(testing.allocator, parseError, .{});

    const body = try wire.encodeAnswers(testing.allocator, questions, answers, .{});
    defer testing.allocator.free(body);
    try testing.checkAllAllocationFailures(testing.allocator, decodeBoth, .{body});
}

fn askAgainstServer(allocator: std.mem.Allocator, body: []const u8) !void {
    // The server uses the real allocator; only the client's allocations fail.
    const server: *MockServer = try .create(testing.allocator, testing.io);
    defer server.destroy();
    try server.enqueue(.{ .body = body });

    var client: Client = try .init(allocator, testing.io, .{
        .api_key = "ts_test_key",
        .base_url = server.url(),
        .retry = .disabled,
        .extra_headers = &.{.{ .name = "x-team", .value = "support" }},
    });
    defer client.deinit();

    var result = try client.ask("Payouts failing", questions, .{});
    result.deinit();
}

fn askDynamicAgainstServer(allocator: std.mem.Allocator, body: []const u8) !void {
    const server: *MockServer = try .create(testing.allocator, testing.io);
    defer server.destroy();
    try server.enqueue(.{ .body = body });

    var client: Client = try .init(allocator, testing.io, .{ .api_key = "ts_test_key", .base_url = server.url(), .retry = .disabled });
    defer client.deinit();

    var result = try client.askDynamic("Payouts failing", &dynamic_questions, .{});
    result.deinit();
}

test "ask and askDynamic survive every allocation failure" {
    const body = try wire.encodeAnswers(testing.allocator, questions, answers, .{});
    defer testing.allocator.free(body);
    try testing.checkAllAllocationFailures(testing.allocator, askAgainstServer, .{body});
    try testing.checkAllAllocationFailures(testing.allocator, askDynamicAgainstServer, .{body});
}
