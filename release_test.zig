//! Release hygiene, run by `zig build test`.
//!
//! The version a consumer installs and the version the client reports are
//! written down in two places, both by hand, both at release time: `.version`
//! in `build.zig.zon` and the install snippet in `README.md`. A release that
//! updates one and not the other is quiet about it - the client goes on
//! identifying itself as the previous release, or the README points at a tag
//! that was never cut - and nothing else in the suite notices, because the
//! tests that send the identity compare it against the identity itself.
//!
//! This module is rooted at the package root rather than under `src/` so that
//! `@embedFile` can reach `README.md`, which is outside the library's module.

const std = @import("std");
const typesafe = @import("typesafe");

test "the README installs the version the client reports" {
    const readme = @embedFile("README.md");
    const prefix = "typesafe.zig#v";

    var checked: usize = 0;
    var rest: []const u8 = readme;
    while (std.mem.indexOf(u8, rest, prefix)) |at| {
        rest = rest[at + prefix.len ..];
        const end = for (rest, 0..) |c, i| {
            if (!isTagByte(c)) break i;
        } else rest.len;
        try std.testing.expectEqualStrings(typesafe.version, rest[0..end]);
        checked += 1;
    }
    // A README that lost its install snippet would otherwise pass by having
    // nothing to check.
    try std.testing.expect(checked > 0);
}

/// The characters a `vX.Y.Z` tag may hold, including the `-` and `+` that
/// prerelease and build metadata use.
fn isTagByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or c == '+';
}
