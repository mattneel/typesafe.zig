# Installation

`typesafe` is a Zig package with an empty dependency table. It needs Zig 0.16.0 or later and
nothing else: no C toolchain, no system libraries, no vendored code. Adding it is three lines —
one command, one `build.zig` edit, one import.

## 1. Add the dependency

```console
$ zig fetch --save git+https://github.com/mattneel/typesafe.zig#v0.1.0
```

`zig fetch --save` downloads the package, records its content hash in `build.zig.zon`, and adds
the entry with the key the package's own manifest asks for:

```zig
.dependencies = .{
    .typesafe = .{
        .url = "git+https://github.com/mattneel/typesafe.zig#v0.1.0",
        .hash = "typesafe-0.1.0-...",
    },
},
```

Pin a tag, as above, for a released version. Pin a commit instead
(`#<commit-sha>`) to follow `master` between releases. The hash is of the package contents, not of
the URL, so a tag that moved would be caught by the build rather than silently accepted.

The first `zig fetch` puts the package in Zig's global cache. Later builds reuse it, so `zig build`
does not need the network again, and nothing is copied into your repository.

## 2. Wire it into `build.zig`

A dependency is not visible to your code until a module imports it. For an executable:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const typesafe = b.dependency("typesafe", .{ .target = target, .optimize = optimize });

    const exe = b.addExecutable(.{
        .name = "my-app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "typesafe", .module = typesafe.module("typesafe") }},
        }),
    });
    b.installArtifact(exe);
}
```

The same three lines attach it anywhere else it is needed — a library module, a test module, an
example:

```zig
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "typesafe", .module = typesafe.module("typesafe") }},
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the tests");
    test_step.dependOn(&run_tests.step);
```

`typesafe.module("typesafe")` is the module the package exposes; the name on the left of the
`imports` entry is what `@import` in your code uses, and can be anything.

Pass `.target` and `.optimize` through as above unless you have a reason not to: they are what let
the package build for the same target and mode as the rest of your program, which is what keeps
cross-compilation working.

## 3. Import it

```zig
const typesafe = @import("typesafe");
```

## 4. Give it a key

Get a key from the [TypeSafe quick start](https://docs.typesafe.ai/introduction/quickstart), then
either export it and let the client find it:

```console
$ export TYPESAFE_API_KEY=ts_...
```

```zig
var client: typesafe.Client = try .initFromEnv(init.gpa, init.io, init.environ_map, .{});
defer client.deinit();
```

or pass it, and any other setting you want to override, explicitly:

```zig
var client: typesafe.Client = try .init(init.gpa, init.io, .{ .api_key = key });
defer client.deinit();
```

`initFromEnv` reads `TYPESAFE_API_KEY`, `TYPESAFE_BASE_URL` and `TYPESAFE_DEFAULT_MODEL`; a blank
value counts as unset, and an explicit option beats the environment. Both functions resolve their
configuration at build time of the *client*, not of the program, so the environment is read when
`main` runs — a missing key is `error.MissingApiKey` there, never in the middle of a request.

A key is a secret: read it from the environment or your own secret store rather than committing
it, and note that the client sends it only to the configured base URL's host, because redirects
are never followed.

## 5. Make one call

The whole flow, in a file you can run:

```zig
const std = @import("std");
const typesafe = @import("typesafe");

const Team = enum { billing, technical, sales };

pub fn main(init: std.process.Init) !void {
    var client: typesafe.Client = try .initFromEnv(init.gpa, init.io, init.environ_map, .{});
    defer client.deinit();

    const questions = .{
        .is_urgent = typesafe.noul("Does this convey urgency?", .{}),
        .department = typesafe.choice(Team, "Which team should handle this?", .{
            .billing = "Payments, invoicing, refunds",
        }),
        .frustration = typesafe.score("How frustrated is the customer?", .{ "Calm", "Frustrated", "Very angry" }),
    };

    var result = try client.ask("Help! My payouts have been failing for 3 days.", questions, .{});
    defer result.deinit();

    std.debug.print("{s} answered: urgent {d:.2}, {t} at {d:.2}, frustration {d:.2}\n", .{
        result.model,
        result.answers.is_urgent.noul,
        result.answers.department.choice,
        result.answers.department.confidence,
        result.answers.frustration.score,
    });
}
```

```console
$ zig build run
jev-1.13.0 answered: urgent 0.95, billing at 0.87, frustration 1.04
```

The model is named exactly because `jev-latest` resolved to it; the numbers move a little between
calls, which is the reason the client hands you probabilities rather than verdicts.

From here, [Questions](questions.md) covers the three primitives and what the compiler checks,
[Confidence and thresholds](confidence.md) how to turn the numbers into a decision, and
[Testing your code](testing.md) how to exercise it offline.

## Build options

The package has one build option. The hourly reload of the system root certificates and the clock
reads `std.http.Client` fields that std does not promise to keep, so it can be turned off:

```zig
const typesafe = b.dependency("typesafe", .{
    .target = target,
    .optimize = optimize,
    .tls_trust_refresh = false,
});
```

On the command line the same option is `-Dtls-trust-refresh=false` when building the package's own
workflows. With it off, the package stays on std's supported surface at the cost of verifying
certificates against the roots and the clock loaded at the first HTTPS request, which matters for
a client that runs longer than a certificate's validity window.

## Troubleshooting

**`error: no module named 'typesafe' available within module ...`**
The import was not added to the module that contains the `@import`. Every module that uses the
package needs its own `imports` entry — the executable, the test, the library.

**`invalid option: -Dsomething`**
An unknown name was passed to `b.dependency`. The package declares only `tls_trust_refresh`; the
`target` and `optimize` arguments every dependency takes are handled by the build system itself.

**`error.MissingApiKey`**
The environment variable is not visible to the running program. It is read when the client is
initialised, so `TYPESAFE_API_KEY=... zig build run` works while exporting it in a different shell
does not. Pass `.api_key` explicitly if you would rather not depend on the environment.

**Building for another target fails**
It should not: there is nothing platform-specific outside the standard library, and examples are
cross-compiled for Windows, macOS, Linux and RISC-V in CI. Check that `.target` is the one you
intended — passing `target` in the `dependency(...)` arguments is what makes the package follow
your build.

**A fetched tag will not resolve**
Tags are immutable and content-hashed; a version that does not exist yet cannot be fetched. Use a
commit while a release is in preparation, or fetch without a fragment
(`git+https://github.com/mattneel/typesafe.zig`) for the default branch.

## Requirements, and what is not needed

- Zig 0.16.0 or newer. The package declares `.minimum_zig_version = "0.16.0"`; an older
  toolchain says so rather than failing somewhere inside a build.
- Nothing else. No `libcurl`, no OpenSSL, no mbedTLS, no C compiler, no `pkg-config`, no vendored
  JSON library. TLS, HTTP, JSON and concurrency all come from `std`.
- The API reference for every public declaration is generated from the doc comments and published
  with this book under `/api/`; `zig build docs` produces the same thing locally.
