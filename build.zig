const std = @import("std");
const manifest = @import("build.zig.zon");

/// Example programs under `examples/`, compiled by `zig build examples` and
/// runnable with `zig build run -Dexample=<name>`.
const examples = [_][]const u8{
    "route_ticket",
    "structured",
    "batch",
    "dynamic",
    "list_models",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", manifest.version);

    const typesafe = b.addModule("typesafe", .{
        .root_source_file = b.path("src/typesafe.zig"),
        .target = target,
        .optimize = optimize,
    });
    typesafe.addOptions("build_options", build_options);

    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Skip tests that do not match any filter",
    ) orelse &.{};

    // Unit and integration tests. They run offline against a loopback server.
    const unit_tests = b.addTest(.{
        .name = "typesafe-test",
        .root_module = typesafe,
        .filters = test_filters,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run the offline unit and integration tests");
    test_step.dependOn(&run_unit_tests.step);

    // Live tests against the real API. They need TYPESAFE_API_KEY and make
    // billable requests, so they are a separate step that `test` never runs.
    const live_tests = b.addTest(.{
        .name = "typesafe-live-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/live.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "typesafe", .module = typesafe }},
        }),
        .filters = test_filters,
    });
    const run_live_tests = b.addRunArtifact(live_tests);
    // The live tests read the environment at run time, so never cache a result.
    run_live_tests.has_side_effects = true;
    const live_step = b.step("test-live", "Run the live tests against api.typesafe.ai (needs TYPESAFE_API_KEY)");
    live_step.dependOn(&run_live_tests.step);

    // Examples: compiled on every CI run so the README code cannot rot.
    const examples_step = b.step("examples", "Build the example programs");
    const selected_example = b.option([]const u8, "example", "Example for `zig build run` (default: route_ticket)") orelse "route_ticket";
    const run_step = b.step("run", "Run an example program (select it with -Dexample=<name>)");
    var found_example = false;
    for (examples) |name| {
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "typesafe", .module = typesafe }},
            }),
        });
        const install = b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = "examples" } } });
        examples_step.dependOn(&install.step);

        if (std.mem.eql(u8, name, selected_example)) {
            found_example = true;
            const run = b.addRunArtifact(exe);
            run.has_side_effects = true;
            if (b.args) |args| run.addArgs(args);
            run_step.dependOn(&run.step);
        }
    }
    if (!found_example) {
        run_step.dependOn(&b.addFail(b.fmt("unknown example '{s}'", .{selected_example})).step);
    }

    // API reference, generated from doc comments.
    const docs_object = b.addObject(.{
        .name = "typesafe",
        .root_module = typesafe,
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_object.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate the API reference into zig-out/docs");
    docs_step.dependOn(&install_docs.step);

    const fmt_paths = &.{ "build.zig", "build.zig.zon", "src", "tests", "examples" };
    const fmt = b.addFmt(.{ .paths = fmt_paths, .check = true });
    const fmt_step = b.step("fmt", "Check source formatting");
    fmt_step.dependOn(&fmt.step);

    const ci_step = b.step("ci", "Run every offline quality gate: fmt, test, examples, docs");
    ci_step.dependOn(fmt_step);
    ci_step.dependOn(test_step);
    ci_step.dependOn(examples_step);
    ci_step.dependOn(docs_step);
}
