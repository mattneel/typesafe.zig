//! Lists the models and aliases available to your account.
//!
//!     TYPESAFE_API_KEY=... zig build run -Dexample=list_models

const std = @import("std");
const typesafe = @import("typesafe");

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout_writer.interface;
    defer out.flush() catch {};

    var client: typesafe.Client = try .initFromEnv(init.gpa, init.io, init.environ_map, .{});
    defer client.deinit();

    var models = try client.listModels(.{});
    defer models.deinit();

    for (models.models) |model| {
        try out.print("{s:<14} {s:<34} {s}\n", .{ model.name, model.release_date, model.description });
    }
}
