//! Asks the same questions about many states concurrently on one client.
//!
//! One request carrying many questions is the cheapest shape. For the same
//! questions over many states, run one `ask` per state in an `Io.Group` and
//! share the client: its connection pool reuses TLS connections.
//!
//!     TYPESAFE_API_KEY=... zig build run -Dexample=batch

const std = @import("std");
const typesafe = @import("typesafe");

const Sentiment = enum { positive, neutral, negative };

const questions = .{
    .sentiment = typesafe.choice(Sentiment, "What is the overall sentiment of this review?", .{}),
    .mentions_shipping = typesafe.noul("Does the review mention shipping or delivery?", .{}),
};

const Outcome = union(enum) {
    pending,
    answered: typesafe.Answers(@TypeOf(questions)),
    failed: typesafe.Error,
};

fn classify(client: *typesafe.Client, review: []const u8, outcome: *Outcome) std.Io.Cancelable!void {
    var result = client.ask(review, questions, .{}) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => {
            outcome.* = .{ .failed = err };
            return;
        },
    };
    defer result.deinit();
    // The answers struct holds only numbers and enums, so it outlives the result.
    outcome.* = .{ .answered = result.answers };
}

pub fn main(init: std.process.Init) !void {
    const reviews = [_][]const u8{
        "Arrived two days early and works perfectly.",
        "The box was crushed and the charger is missing.",
        "It does what it says. Nothing more, nothing less.",
        "Customer service replaced it without any fuss. Great experience!",
        "Took five weeks to arrive and stopped working after a day.",
    };

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout_writer.interface;
    defer out.flush() catch {};

    var client: typesafe.Client = try .initFromEnv(init.gpa, init.io, init.environ_map, .{});
    defer client.deinit();

    var outcomes: [reviews.len]Outcome = @splat(.pending);
    var group: std.Io.Group = .init;
    defer group.cancel(init.io);
    for (&reviews, &outcomes) |review, *outcome| {
        try group.concurrent(init.io, classify, .{ &client, review, outcome });
    }
    try group.await(init.io);

    // Results are printed in input order, whatever order the calls finished in.
    for (reviews, outcomes) |review, outcome| switch (outcome) {
        .pending => unreachable,
        .answered => |answers| try out.print("{t:<8} shipping={d:.2}  {s}\n", .{
            answers.sentiment.choice,
            answers.mentions_shipping.noul,
            review,
        }),
        .failed => |err| try out.print("failed: {t}  {s}\n", .{ err, review }),
    };
}
