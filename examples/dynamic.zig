//! Classifies products into a taxonomy that is only known at run time, here
//! parsed from JSON as it would be loaded from a database or config file.
//!
//!     TYPESAFE_API_KEY=... zig build run -Dexample=dynamic -- "32oz plastic bottle with a flip straw lid"

const std = @import("std");
const typesafe = @import("typesafe");
const dynamic = typesafe.dynamic;

const taxonomy_json =
    \\{
    \\  "departments": [
    \\    { "name": "Sporting Goods", "covers": ["Cycling", "Fitness", "Outdoor"] },
    \\    { "name": "Home & Kitchen", "covers": ["Drinkware", "Cookware"] },
    \\    { "name": "Baby & Toddler", "covers": ["Sippy Cups", "Bibs"] }
    \\  ]
    \\}
;

const Taxonomy = struct {
    departments: []const struct {
        name: []const u8,
        covers: []const []const u8,
    },
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const product = if (args.len > 1) args[1] else "32oz plastic bottle with a flip straw lid. Fits most bike cages.";

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout_writer.interface;
    defer out.flush() catch {};

    const taxonomy = try std.json.parseFromSliceLeaky(Taxonomy, arena, taxonomy_json, .{});

    // Build one option per department, describing it by what it covers.
    const options = try arena.alloc(dynamic.Option, taxonomy.departments.len);
    for (options, taxonomy.departments) |*option, department| {
        const covers = try std.json.Stringify.valueAlloc(arena, department.covers, .{});
        option.* = .{ .name = department.name, .description = .{ .raw = covers } };
    }

    const questions = [_]dynamic.Question{
        .choice("department", "Which top-level department does this product belong to?", .{ .described = options }),
        .noul("is_reusable", "Is this product meant to be used more than once?"),
    };

    var client: typesafe.Client = try .initFromEnv(init.gpa, init.io, init.environ_map, .{});
    defer client.deinit();

    var diagnostics: typesafe.Diagnostics = .init(init.gpa);
    defer diagnostics.deinit();
    var result = client.askDynamic(product, &questions, .{ .diagnostics = &diagnostics }) catch |err| {
        std.log.err("{f}", .{diagnostics});
        return err;
    };
    defer result.deinit();

    const department = result.get("department").?.choice;
    try out.print("product: {s}\n", .{product});
    for (try department.ranked(arena)) |entry| {
        try out.print("  {s}: {d:.2}\n", .{ entry.option, entry.probability });
    }
    try out.print("department: {s} (margin {d:.2})\n", .{ department.choice, department.margin() });
    try out.print("reusable: {d:.2}\n", .{result.get("is_reusable").?.noul.noul});
}
