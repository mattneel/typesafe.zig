//! Routes a support ticket: urgency, owning team and customer frustration in
//! one request, with thresholds and policy in this program's code.
//!
//!     TYPESAFE_API_KEY=... zig build run -Dexample=route_ticket -- "My payouts have been failing for 3 days"

const std = @import("std");
const typesafe = @import("typesafe");

const Team = enum { billing, technical, sales };

const questions = .{
    .is_urgent = typesafe.noul("Does this convey urgency?", .{
        .yes = "Explicitly time-sensitive, or blocking the customer's business",
        .no = "No urgency expressed",
    }),
    .department = typesafe.choice(Team, "Which team should handle this?", .{
        .billing = "Payments, invoicing, refunds",
        .technical = "Bugs, outages, integrations",
        .sales = "Pricing, upgrades, new accounts",
    }),
    .frustration = typesafe.score("How frustrated is the customer?", .{ "Calm", "Frustrated", "Very angry" }),
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const text = if (args.len > 1) args[1] else "Help! My payouts have been failing for 3 days.";

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout_writer.interface;
    defer out.flush() catch {};

    var client: typesafe.Client = try .initFromEnv(init.gpa, init.io, init.environ_map, .{});
    defer client.deinit();

    var diagnostics: typesafe.Diagnostics = .init(init.gpa);
    defer diagnostics.deinit();

    var result = client.ask(text, questions, .{ .diagnostics = &diagnostics }) catch |err| {
        std.log.err("{f}", .{diagnostics});
        return err;
    };
    defer result.deinit();

    const answers = result.answers;
    try out.print("ticket: {s}\n", .{text});
    try out.print("model: {s}, request: {s}\n\n", .{ result.model, result.request_id orelse "-" });

    try out.print("urgent: {d:.2}\n", .{answers.is_urgent.noul});
    for (answers.department.ranked()) |entry| {
        try out.print("department {t}: {d:.2}\n", .{ entry.option, entry.probability });
    }
    try out.print("frustration score: {d:.2} (confidence {d:.2})\n\n", .{
        answers.frustration.score,
        answers.frustration.confidence,
    });

    // Policy lives here, not in the model: route confident answers
    // automatically and send uncertain ones to a person.
    const department = answers.department;
    if (department.confidence < 0.6 or department.margin() < 0.2) {
        try out.print("decision: triage queue (the model is unsure between teams)\n", .{});
    } else if (answers.is_urgent.isYes(0.8) or answers.frustration.expectedLevel() == 2) {
        try out.print("decision: page the {t} on-call\n", .{department.choice});
    } else {
        try out.print("decision: {t} queue\n", .{department.choice});
    }
}
