//! Strict JSON encoding for request bodies and path-tracking decoding for
//! response bodies.
//!
//! `std.json.Stringify` silently renders a string that is not valid UTF-8 as
//! an array of numbers, and writes a non-finite float as a token the API
//! cannot parse. The `Encoder` here rejects both with a path to the offending
//! value, so a bad request fails before it is sent with an error that points
//! at the problem.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;

/// Pre-encoded JSON text, sent verbatim.
///
/// Use it for state or question content that is already JSON, such as a
/// document loaded from a database. The client validates the text before
/// sending it and fails with `error.InvalidRequest` when it is not a single
/// valid JSON value.
pub const RawJson = struct {
    text: []const u8,

    /// Writes the text as-is. Only `Encoder` validates it; plain
    /// `std.json.Stringify` trusts it.
    pub fn jsonStringify(self: RawJson, jws: *Stringify) Stringify.Error!void {
        try jws.beginWriteRaw();
        defer jws.endWriteRaw();
        try jws.writer.writeAll(self.text);
    }
};

/// The deepest nesting the encoder and decoder accept, matching the limit of
/// `std.json.Stringify`.
pub const max_depth = 256;

/// Where and why encoding or decoding failed.
pub const Failure = struct {
    message_buf: [256]u8 = undefined,
    message_len: usize = 0,
    path_buf: [512]u8 = undefined,
    path_len: usize = 0,

    /// A human-readable description of the problem.
    pub fn message(failure: *const Failure) []const u8 {
        return failure.message_buf[0..failure.message_len];
    }

    /// The path to the offending value, such as `answers.tone.confidence` or
    /// `state.messages[0].text`. Empty for the document root.
    pub fn path(failure: *const Failure) []const u8 {
        return failure.path_buf[0..failure.path_len];
    }

    fn setMessage(failure: *Failure, comptime fmt: []const u8, args: anytype) void {
        var w: std.Io.Writer = .fixed(&failure.message_buf);
        w.print(fmt, args) catch {
            failure.message_len = markTruncated(&failure.message_buf);
            return;
        };
        failure.message_len = w.end;
    }

    fn setPath(failure: *Failure, segments: []const Segment) void {
        var w: std.Io.Writer = .fixed(&failure.path_buf);
        writePath(&w, segments) catch {
            failure.path_len = markTruncated(&failure.path_buf);
            return;
        };
        failure.path_len = w.end;
    }

    /// Ends a full buffer with an ellipsis, cutting on a UTF-8 character
    /// boundary, and returns the new length.
    fn markTruncated(buffer: []u8) usize {
        const ellipsis = "...";
        const cut = utf8Boundary(buffer, buffer.len - ellipsis.len);
        @memcpy(buffer[cut..][0..ellipsis.len], ellipsis);
        return cut + ellipsis.len;
    }
};

/// Returns the largest index at most `index` that does not split a UTF-8
/// character in `text`.
pub fn utf8Boundary(text: []const u8, index: usize) usize {
    if (index >= text.len) return text.len;
    var cut = index;
    while (cut > 0 and (text[cut] & 0xC0) == 0x80) cut -= 1;
    return cut;
}

test utf8Boundary {
    const text = "aé€";
    try std.testing.expectEqual(1, utf8Boundary(text, 1));
    try std.testing.expectEqual(1, utf8Boundary(text, 2));
    try std.testing.expectEqual(3, utf8Boundary(text, 3));
    try std.testing.expectEqual(3, utf8Boundary(text, 5));
    try std.testing.expectEqual(text.len, utf8Boundary(text, 99));
}

const Segment = union(enum) {
    key: []const u8,
    index: usize,
};

fn writePath(w: *std.Io.Writer, segments: []const Segment) std.Io.Writer.Error!void {
    for (segments, 0..) |segment, i| switch (segment) {
        .key => |key| {
            if (i != 0) try w.writeByte('.');
            try w.writeAll(key);
        },
        .index => |index| try w.print("[{d}]", .{index}),
    };
}

/// A `std.json.Stringify` wrapper that validates every value it writes and
/// tracks the path to it.
///
/// It exposes the subset of the `Stringify` API that question types use
/// (`beginObject`, `objectField`, `write`, ...), so a type's
/// `writeTypesafeJson` method can target either one.
pub const Encoder = struct {
    stringify: Stringify,
    /// Used only to validate `RawJson` text.
    allocator: Allocator,
    frames: [max_depth]Frame = undefined,
    depth: usize = 0,
    failure: Failure = .{},

    pub const Error = error{ InvalidRequest, OutOfMemory };

    const Frame = struct {
        kind: enum { object, array },
        /// The current object key, or the index of the next array element.
        key: ?[]const u8 = null,
        index: usize = 0,
    };

    /// `writer` must be an allocating writer: its only failure mode is
    /// running out of memory.
    pub fn init(allocator: Allocator, writer: *std.Io.Writer) Encoder {
        return .{ .allocator = allocator, .stringify = .{ .writer = writer } };
    }

    pub fn beginObject(enc: *Encoder) Error!void {
        try enc.push(.object);
        enc.stringify.beginObject() catch return error.OutOfMemory;
    }

    pub fn endObject(enc: *Encoder) Error!void {
        enc.stringify.endObject() catch return error.OutOfMemory;
        enc.pop();
    }

    pub fn beginArray(enc: *Encoder) Error!void {
        try enc.push(.array);
        enc.stringify.beginArray() catch return error.OutOfMemory;
    }

    pub fn endArray(enc: *Encoder) Error!void {
        enc.stringify.endArray() catch return error.OutOfMemory;
        enc.pop();
    }

    /// Writes an object key. `name` must outlive the next `write`.
    pub fn objectField(enc: *Encoder, name: []const u8) Error!void {
        if (!std.unicode.utf8ValidateSlice(name)) {
            return enc.fail("object key is not valid UTF-8", .{});
        }
        if (enc.depth == 0 or enc.frames[enc.depth - 1].kind != .object) {
            return enc.fail("object field written outside an object", .{});
        }
        enc.frames[enc.depth - 1].key = name;
        enc.stringify.objectField(name) catch return error.OutOfMemory;
    }

    /// Records a failure at the current path and returns `error.InvalidRequest`.
    pub fn fail(enc: *Encoder, comptime fmt: []const u8, args: anytype) error{InvalidRequest} {
        enc.failure.setMessage(fmt, args);
        var segments: [max_depth]Segment = undefined;
        enc.failure.setPath(enc.currentPath(&segments));
        return error.InvalidRequest;
    }

    fn currentPath(enc: *const Encoder, buffer: *[max_depth]Segment) []const Segment {
        var len: usize = 0;
        for (enc.frames[0..enc.depth]) |frame| switch (frame.kind) {
            .object => if (frame.key) |key| {
                buffer[len] = .{ .key = key };
                len += 1;
            },
            .array => {
                buffer[len] = .{ .index = frame.index };
                len += 1;
            },
        };
        return buffer[0..len];
    }

    fn push(enc: *Encoder, kind: @FieldType(Frame, "kind")) Error!void {
        if (enc.depth == max_depth) {
            return enc.fail("value is nested more than {d} levels deep", .{max_depth});
        }
        enc.frames[enc.depth] = .{ .kind = kind };
        enc.depth += 1;
    }

    fn pop(enc: *Encoder) void {
        enc.depth -= 1;
        enc.valueDone();
    }

    fn valueDone(enc: *Encoder) void {
        if (enc.depth == 0) return;
        const frame = &enc.frames[enc.depth - 1];
        switch (frame.kind) {
            .array => frame.index += 1,
            .object => frame.key = null,
        }
    }

    /// Writes any value `std.json.Stringify` supports, rejecting strings
    /// that are not valid UTF-8, floats that are not finite, and nesting
    /// deeper than `max_depth`.
    ///
    /// `std.json.Value` (and its `ObjectMap` and `Array`) is walked and
    /// checked like any other value. Types with a
    /// `writeTypesafeJson(self, writer)` method are written through it, with
    /// this encoder as the writer. Other types with a `jsonStringify` method
    /// are delegated to that method, unchecked; they must not nest deeper
    /// than the remaining depth.
    pub fn write(enc: *Encoder, value: anytype) Error!void {
        const T = @TypeOf(value);
        if (T == RawJson) return enc.writeRaw(value.text);
        if (T == std.json.Value) return enc.writeValue(value);
        if (T == std.json.ObjectMap) return enc.writeObjectMap(value);
        if (T == std.json.Array) return enc.writeValues(value.items);

        switch (@typeInfo(T)) {
            .bool, .int, .comptime_int, .null, .enum_literal => return enc.primitive(value),
            .float => {
                if (!std.math.isFinite(value)) {
                    return enc.fail("number is not finite: {d}", .{value});
                }
                return enc.primitive(value);
            },
            .comptime_float => return enc.primitive(@as(f64, value)),
            .optional => {
                if (value) |payload| return enc.write(payload);
                return enc.primitive(null);
            },
            .error_set => return enc.primitive(value),
            .@"enum" => {
                if (std.meta.hasFn(T, "writeTypesafeJson")) return enc.custom(value);
                if (std.meta.hasFn(T, "jsonStringify")) return enc.delegate(value);
                return enc.primitive(value);
            },
            .@"union" => |info| {
                if (std.meta.hasFn(T, "writeTypesafeJson")) return enc.custom(value);
                if (std.meta.hasFn(T, "jsonStringify")) return enc.delegate(value);
                if (info.tag_type == null) {
                    @compileError("typesafe: cannot encode untagged union " ++ @typeName(T) ++ " as JSON");
                }
                try enc.beginObject();
                switch (value) {
                    inline else => |payload, tag| {
                        try enc.objectField(@tagName(tag));
                        if (@TypeOf(payload) == void) {
                            try enc.beginObject();
                            try enc.endObject();
                        } else {
                            try enc.write(payload);
                        }
                    },
                }
                return enc.endObject();
            },
            .@"struct" => |info| {
                if (std.meta.hasFn(T, "writeTypesafeJson")) return enc.custom(value);
                if (std.meta.hasFn(T, "jsonStringify")) return enc.delegate(value);
                if (info.is_tuple) {
                    try enc.beginArray();
                    inline for (info.fields) |field| {
                        if (field.type != void) try enc.write(@field(value, field.name));
                    }
                    return enc.endArray();
                }
                try enc.beginObject();
                inline for (info.fields) |field| {
                    if (field.type != void) {
                        try enc.objectField(field.name);
                        try enc.write(@field(value, field.name));
                    }
                }
                return enc.endObject();
            },
            .pointer => |ptr| switch (ptr.size) {
                .one => switch (@typeInfo(ptr.child)) {
                    .array => |array| return enc.write(@as([]const array.child, value)),
                    else => return enc.write(value.*),
                },
                .slice, .many => {
                    if (ptr.size == .many and ptr.sentinel() == null) {
                        @compileError("typesafe: cannot encode " ++ @typeName(T) ++ " as JSON: many-item pointer without a sentinel");
                    }
                    const slice = if (ptr.size == .many) std.mem.span(value) else value;
                    if (ptr.child == u8) return enc.string(slice);
                    try enc.beginArray();
                    for (slice) |item| try enc.write(item);
                    return enc.endArray();
                },
                else => @compileError("typesafe: cannot encode " ++ @typeName(T) ++ " as JSON"),
            },
            .array => return enc.write(&value),
            .vector => |info| {
                const array: [info.len]info.child = value;
                return enc.write(&array);
            },
            else => @compileError("typesafe: cannot encode " ++ @typeName(T) ++ " as JSON"),
        }
    }

    /// Writes a JSON string, rejecting text that is not valid UTF-8.
    pub fn string(enc: *Encoder, text: []const u8) Error!void {
        if (!std.unicode.utf8ValidateSlice(text)) {
            return enc.fail("string is not valid UTF-8", .{});
        }
        return enc.primitive(text);
    }

    fn primitive(enc: *Encoder, value: anytype) Error!void {
        enc.stringify.write(value) catch return error.OutOfMemory;
        enc.valueDone();
    }

    fn custom(enc: *Encoder, value: anytype) Error!void {
        const depth = enc.depth;
        try value.writeTypesafeJson(enc);
        std.debug.assert(enc.depth == depth);
    }

    fn writeValue(enc: *Encoder, value: std.json.Value) Error!void {
        switch (value) {
            .null => return enc.primitive(null),
            .bool => |b| return enc.primitive(b),
            .integer => |i| return enc.primitive(i),
            .float => |f| return enc.write(f),
            .number_string => |text| {
                if (!isJsonNumber(text)) return enc.fail("number_string is not a JSON number", .{});
                enc.stringify.beginWriteRaw() catch return error.OutOfMemory;
                enc.stringify.writer.writeAll(text) catch return error.OutOfMemory;
                enc.stringify.endWriteRaw();
                enc.valueDone();
            },
            .string => |text| return enc.string(text),
            .array => |array| return enc.writeValues(array.items),
            .object => |map| return enc.writeObjectMap(map),
        }
    }

    fn writeValues(enc: *Encoder, values: []const std.json.Value) Error!void {
        try enc.beginArray();
        for (values) |item| try enc.writeValue(item);
        return enc.endArray();
    }

    fn writeObjectMap(enc: *Encoder, map: std.json.ObjectMap) Error!void {
        try enc.beginObject();
        for (map.keys(), map.values()) |key, item| {
            try enc.objectField(key);
            try enc.writeValue(item);
        }
        return enc.endObject();
    }

    fn delegate(enc: *Encoder, value: anytype) Error!void {
        value.jsonStringify(&enc.stringify) catch |err| return enc.delegateFailed(@TypeOf(value), err);
        enc.valueDone();
    }

    fn delegateFailed(enc: *Encoder, comptime T: type, err: anyerror) Error {
        if (err == error.WriteFailed) return error.OutOfMemory;
        return enc.fail("jsonStringify of {s} failed: {s}", .{ @typeName(T), @errorName(err) });
    }

    fn writeRaw(enc: *Encoder, text: []const u8) Error!void {
        // Validating and scanning in one pass: the text must be a single
        // valid JSON value, and it must not nest deeper than the encoder and
        // decoder accept.
        var scanner: std.json.Scanner = .initCompleteInput(enc.allocator, text);
        defer scanner.deinit();
        var depth: usize = 0;
        while (true) {
            const token = scanner.next() catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return enc.fail("raw JSON is not a single valid JSON value", .{}),
            };
            switch (token) {
                .array_begin, .object_begin => {
                    depth += 1;
                    if (depth > max_depth) {
                        return enc.fail("raw JSON is nested more than {d} levels deep", .{max_depth});
                    }
                },
                .array_end, .object_end => depth -= 1,
                .end_of_document => break,
                else => {},
            }
        }
        enc.stringify.beginWriteRaw() catch return error.OutOfMemory;
        enc.stringify.writer.writeAll(text) catch return error.OutOfMemory;
        enc.stringify.endWriteRaw();
        enc.valueDone();
    }
};

/// Returns `true` when `text` is exactly one JSON number (RFC 8259 grammar).
pub fn isJsonNumber(text: []const u8) bool {
    var i: usize = 0;
    if (i < text.len and text[i] == '-') i += 1;
    if (i == text.len) return false;
    if (text[i] == '0') {
        i += 1;
    } else if (std.ascii.isDigit(text[i])) {
        while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
    } else return false;
    if (i < text.len and text[i] == '.') {
        i += 1;
        const start = i;
        while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
        if (i == start) return false;
    }
    if (i < text.len and (text[i] == 'e' or text[i] == 'E')) {
        i += 1;
        if (i < text.len and (text[i] == '+' or text[i] == '-')) i += 1;
        const start = i;
        while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
        if (i == start) return false;
    }
    return i == text.len;
}

test isJsonNumber {
    for ([_][]const u8{ "0", "-0", "12", "1.5", "-1.5e10", "2E-3", "123456789012345678901234567890" }) |ok| {
        try std.testing.expect(isJsonNumber(ok));
    }
    for ([_][]const u8{ "", "-", "01", "1.", ".5", "1e", "+1", "12abc", "nan", "1 2", "0x10" }) |bad| {
        try std.testing.expect(!isJsonNumber(bad));
    }
}

/// Encodes `value` with the strict encoder. On `error.InvalidRequest`,
/// `failure` describes the problem. Caller owns the returned slice.
pub fn encodeAlloc(allocator: Allocator, value: anytype, failure: *Failure) Encoder.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var enc: Encoder = .init(allocator, &out.writer);
    enc.write(value) catch |err| {
        failure.* = enc.failure;
        return err;
    };
    return out.toOwnedSlice() catch error.OutOfMemory;
}

/// Reads a decoded `std.json.Value` tree, tracking the path so a mismatch can
/// be reported as, say, `answers.tone.confidence: expected a number from 0 to 1`.
pub const Decoder = struct {
    segments: [max_depth]Segment = undefined,
    depth: usize = 0,
    failure: Failure = .{},

    pub const Error = error{InvalidResponse};

    pub fn pushKey(dec: *Decoder, key: []const u8) void {
        std.debug.assert(dec.depth < max_depth);
        dec.segments[dec.depth] = .{ .key = key };
        dec.depth += 1;
    }

    pub fn pushIndex(dec: *Decoder, index: usize) void {
        std.debug.assert(dec.depth < max_depth);
        dec.segments[dec.depth] = .{ .index = index };
        dec.depth += 1;
    }

    pub fn pop(dec: *Decoder) void {
        dec.depth -= 1;
    }

    /// Records a failure at the current path and returns `error.InvalidResponse`.
    pub fn fail(dec: *Decoder, comptime fmt: []const u8, args: anytype) error{InvalidResponse} {
        dec.failure.setMessage(fmt, args);
        dec.failure.setPath(dec.segments[0..dec.depth]);
        return error.InvalidResponse;
    }

    /// Returns the object map of `value`. The map is a shallow copy that
    /// shares storage with `value`, for reading only.
    pub fn object(dec: *Decoder, value: std.json.Value) Error!std.json.ObjectMap {
        return switch (value) {
            .object => |map| map,
            else => dec.fail("expected an object, got {s}", .{kindName(value)}),
        };
    }

    /// Returns the member `name` of `map`, failing when it is missing.
    /// The path is not extended; callers push the key when descending.
    pub fn field(dec: *Decoder, map: std.json.ObjectMap, name: []const u8) Error!std.json.Value {
        return map.get(name) orelse {
            dec.pushKey(name);
            defer dec.pop();
            return dec.fail("missing required field", .{});
        };
    }

    pub fn string(dec: *Decoder, value: std.json.Value) Error![]const u8 {
        return switch (value) {
            .string => |s| s,
            else => dec.fail("expected a string, got {s}", .{kindName(value)}),
        };
    }

    pub fn number(dec: *Decoder, value: std.json.Value) Error!f64 {
        const result: f64 = switch (value) {
            .integer => |i| @floatFromInt(i),
            .float => |f| f,
            .number_string => |s| std.fmt.parseFloat(f64, s) catch return dec.fail("expected a number", .{}),
            else => return dec.fail("expected a number, got {s}", .{kindName(value)}),
        };
        if (!std.math.isFinite(result)) return dec.fail("expected a finite number", .{});
        return result;
    }

    /// A number from 0 to 1 inclusive.
    pub fn probability(dec: *Decoder, value: std.json.Value) Error!f64 {
        const p = try dec.number(value);
        if (p < 0 or p > 1) return dec.fail("expected a number from 0 to 1, got {d}", .{p});
        return p;
    }

    /// A non-negative integer, or `null` for a JSON `null`.
    pub fn optionalCount(dec: *Decoder, value: std.json.Value) Error!?u64 {
        return switch (value) {
            .null => null,
            .integer => |i| if (i >= 0) @intCast(i) else dec.fail("expected a non-negative integer, got {d}", .{i}),
            else => dec.fail("expected a non-negative integer, got {s}", .{kindName(value)}),
        };
    }
};

fn kindName(value: std.json.Value) []const u8 {
    return switch (value) {
        .null => "null",
        .bool => "a boolean",
        .integer, .float, .number_string => "a number",
        .string => "a string",
        .array => "an array",
        .object => "an object",
    };
}

test "encoder writes structs, tuples, optionals and enums like std.json" {
    const gpa = std.testing.allocator;
    const Color = enum { red, green };
    const value = .{
        .text = "hi",
        .list = .{ 1, "two", 3.5 },
        .nothing = @as(?u8, null),
        .color = Color.green,
        .literal = .blue,
        .nested = .{ .ok = true },
        .slice = @as([]const []const u8, &.{ "a", "b" }),
    };
    var failure: Failure = .{};
    const out = try encodeAlloc(gpa, value, &failure);
    defer gpa.free(out);
    try std.testing.expectEqualStrings(
        \\{"text":"hi","list":[1,"two",3.5],"nothing":null,"color":"green","literal":"blue","nested":{"ok":true},"slice":["a","b"]}
    , out);
}

test "encoder rejects invalid UTF-8 with a path" {
    const gpa = std.testing.allocator;
    const bad: []const u8 = "caf\xe9";
    const value = .{ .messages = .{.{ .role = "user", .text = bad }} };
    var failure: Failure = .{};
    try std.testing.expectError(error.InvalidRequest, encodeAlloc(gpa, value, &failure));
    try std.testing.expectEqualStrings("messages[0].text", failure.path());
    try std.testing.expectEqualStrings("string is not valid UTF-8", failure.message());
}

test "encoder rejects non-finite floats" {
    const gpa = std.testing.allocator;
    const values = [_]f64{ 1.0, std.math.inf(f64) };
    var failure: Failure = .{};
    try std.testing.expectError(error.InvalidRequest, encodeAlloc(gpa, .{ .scores = values }, &failure));
    try std.testing.expectEqualStrings("scores[1]", failure.path());

    const nan: f32 = std.math.nan(f32);
    try std.testing.expectError(error.InvalidRequest, encodeAlloc(gpa, nan, &failure));
    try std.testing.expectEqualStrings("", failure.path());
}

test "encoder validates raw JSON and passes std.json.Value through" {
    const gpa = std.testing.allocator;
    var failure: Failure = .{};

    const good = try encodeAlloc(gpa, .{ .doc = RawJson{ .text = "{\"a\": [1, 2]}" } }, &failure);
    defer gpa.free(good);
    try std.testing.expectEqualStrings("{\"doc\":{\"a\": [1, 2]}}", good);

    try std.testing.expectError(error.InvalidRequest, encodeAlloc(gpa, .{ .doc = RawJson{ .text = "{\"a\":" } }, &failure));
    try std.testing.expectEqualStrings("doc", failure.path());
    try std.testing.expectError(error.InvalidRequest, encodeAlloc(gpa, RawJson{ .text = "1 2" }, &failure));

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, "{\"k\":[true,null]}", .{});
    defer parsed.deinit();
    const out = try encodeAlloc(gpa, .{ .v = parsed.value, .after = 1 }, &failure);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("{\"v\":{\"k\":[true,null]},\"after\":1}", out);
}

test "encoder rejects raw JSON nested deeper than it accepts" {
    const gpa = std.testing.allocator;
    var failure: Failure = .{};
    var deep: [2 * max_depth + 2]u8 = undefined;
    @memset(deep[0 .. max_depth + 1], '[');
    @memset(deep[max_depth + 1 ..], ']');

    // One over the limit, and the limit itself: the bound is inclusive.
    try std.testing.expectError(error.InvalidRequest, encodeAlloc(gpa, .{ .doc = RawJson{ .text = deep[0 .. 2 * (max_depth + 1)] } }, &failure));
    try std.testing.expectEqualStrings("doc", failure.path());
    try std.testing.expectEqualStrings("raw JSON is nested more than 256 levels deep", failure.message());

    const at_limit = try encodeAlloc(gpa, .{ .doc = RawJson{ .text = deep[1 .. 2 * max_depth + 1] } }, &failure);
    defer gpa.free(at_limit);
}

test "encoder refuses an object key outside an object" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var enc: Encoder = .init(gpa, &out.writer);
    try std.testing.expectError(error.InvalidRequest, enc.objectField("orphan"));
}

test "encoder writes tagged unions as single-key objects" {
    const gpa = std.testing.allocator;
    const U = union(enum) { text: []const u8, empty: void };
    var failure: Failure = .{};
    const out = try encodeAlloc(gpa, [_]U{ .{ .text = "x" }, .empty }, &failure);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("[{\"text\":\"x\"},{\"empty\":{}}]", out);
}

test "decoder reports paths" {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, "{\"answers\":{\"tone\":{\"confidence\":1.5}}}", .{});
    defer parsed.deinit();

    var dec: Decoder = .{};
    const root = try dec.object(parsed.value);
    dec.pushKey("answers");
    const answers = try dec.object(try dec.field(root, "answers"));
    dec.pushKey("tone");
    const tone = try dec.object(try dec.field(answers, "tone"));
    dec.pushKey("confidence");
    try std.testing.expectError(error.InvalidResponse, dec.probability(try dec.field(tone, "confidence")));
    try std.testing.expectEqualStrings("answers.tone.confidence", dec.failure.path());
    try std.testing.expectEqualStrings("expected a number from 0 to 1, got 1.5", dec.failure.message());
    dec.pop();

    try std.testing.expectError(error.InvalidResponse, dec.field(tone, "missing"));
    try std.testing.expectEqualStrings("answers.tone.missing", dec.failure.path());
}
