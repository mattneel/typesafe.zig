//! The System One wire format: request bodies, response bodies and error
//! bodies.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("json.zig");
const question = @import("question.zig");

/// Token usage reported for one System One request. Both counts may be absent.
pub const Usage = struct {
    /// Billable input tokens.
    input_tokens: ?u64 = null,
    /// Output tokens used to answer the questions.
    output_tokens: ?u64 = null,
};

/// A model or model alias available to your account, as returned by
/// `Client.listModels`. Pass `name` as the `model` option.
pub const Model = struct {
    /// Model name or alias, such as `jev-latest`.
    name: []const u8,
    /// Human-readable description of the model.
    description: []const u8,
    /// Release date as the API sends it: an ISO 8601 date or timestamp.
    release_date: []const u8,
};

/// Encodes a `POST /v1/systemone` body for typed questions. On
/// `error.InvalidRequest`, `failure` names the offending value, with paths
/// rooted at the request (`state.text`, `questions.department.criteria`).
pub fn encodeAsk(
    gpa: Allocator,
    state: anytype,
    model: []const u8,
    questions: anytype,
    failure: *json.Failure,
) json.Encoder.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var enc: json.Encoder = .init(gpa, &out.writer);
    writeAsk(&enc, state, model, questions) catch |err| {
        failure.* = enc.failure;
        return err;
    };
    return out.toOwnedSlice() catch error.OutOfMemory;
}

fn writeAsk(enc: *json.Encoder, state: anytype, model: []const u8, questions: anytype) json.Encoder.Error!void {
    const fields = comptime @typeInfo(@TypeOf(questions)).@"struct".fields;
    try enc.beginObject();
    try writeState(enc, state);
    try enc.objectField("model");
    try enc.string(model);
    try enc.objectField("questions");
    try enc.beginObject();
    inline for (fields) |field| {
        try enc.objectField(field.name);
        try enc.write(@field(questions, field.name));
    }
    try enc.endObject();
    try enc.endObject();
}

/// Writes the `state` member, which must be a JSON string, object or array.
pub fn writeState(enc: *json.Encoder, state: anytype) json.Encoder.Error!void {
    try enc.objectField("state");
    const start = enc.stringify.writer.end;
    try enc.write(state);
    // `Stringify` writes the key's colon when the value starts, so skip it.
    const written = std.mem.trimStart(u8, enc.stringify.writer.buffered()[start..], ": \t\r\n");
    const first = if (written.len > 0) written[0] else 0;
    if (first != '"' and first != '{' and first != '[') {
        // The key was cleared when the value completed; restore it for the path.
        enc.frames[enc.depth - 1].key = "state";
        return enc.fail("state must be a string, object or array", .{});
    }
}

/// The decoded parts of a successful `ask` response.
pub fn Decoded(comptime Questions: type) type {
    return struct {
        model: []const u8,
        answers: question.Answers(Questions),
        usage: Usage,
    };
}

/// Decodes a `POST /v1/systemone` response for typed questions.
///
/// Every question must have an answer of the matching type. Answers the
/// request did not ask for, and fields this version does not know, are
/// ignored, so a newer server never breaks an older client.
pub fn decodeAsk(comptime Questions: type, dec: *json.Decoder, root: std.json.Value) json.Decoder.Error!Decoded(Questions) {
    const top = try dec.object(root);
    const model = try stringField(dec, top, "model");

    const answers_value = try dec.field(top, "answers");
    dec.pushKey("answers");
    const answers_map = try dec.object(answers_value);
    var answers: question.Answers(Questions) = undefined;
    inline for (@typeInfo(Questions).@"struct".fields) |field| {
        const value = try dec.field(answers_map, field.name);
        dec.pushKey(field.name);
        @field(answers, field.name) = try decodeAnswer(field.type, dec, value);
        dec.pop();
    }
    dec.pop();

    return .{
        .model = model,
        .answers = answers,
        .usage = try decodeUsage(dec, top),
    };
}

/// Decodes one answer for question type `Q`, checking the wire `type`.
fn decodeAnswer(comptime Q: type, dec: *json.Decoder, value: std.json.Value) json.Decoder.Error!Q.Answer {
    const map = try dec.object(value);
    try expectType(dec, map, @tagName(Q.kind));
    return switch (Q.kind) {
        .noul => .{ .noul = try probabilityField(dec, map, "noul") },
        .choice => decodeChoice(Q.Answer, dec, map),
        .score => decodeScore(Q.Answer, dec, map),
    };
}

pub fn expectType(dec: *json.Decoder, map: std.json.ObjectMap, expected: []const u8) json.Decoder.Error!void {
    const actual = try stringField(dec, map, "type");
    if (!std.mem.eql(u8, actual, expected)) {
        dec.pushKey("type");
        defer dec.pop();
        return dec.fail("expected a {s} answer, got \"{s}\"", .{ expected, actual });
    }
}

fn decodeChoice(comptime Answer: type, dec: *json.Decoder, map: std.json.ObjectMap) json.Decoder.Error!Answer {
    const Option = @FieldType(Answer, "choice");
    const option_fields = @typeInfo(Option).@"enum".fields;
    @setEvalBranchQuota(1000 + 16 * option_fields.len);
    const choice_text = try stringField(dec, map, "choice");
    const choice: Option = find: {
        inline for (option_fields) |field| {
            if (std.mem.eql(u8, field.name, choice_text)) break :find @field(Option, field.name);
        }
        dec.pushKey("choice");
        defer dec.pop();
        return dec.fail("\"{s}\" is not an option of the question", .{choice_text});
    };

    const probabilities_value = try dec.field(map, "probabilities");
    dec.pushKey("probabilities");
    const probabilities_map = try dec.object(probabilities_value);
    var probabilities: Answer.Probabilities = undefined;
    inline for (option_fields) |field| {
        @field(probabilities, field.name) = try probabilityField(dec, probabilities_map, field.name);
    }
    dec.pop();

    return .{
        .choice = choice,
        .probabilities = probabilities,
        .confidence = try probabilityField(dec, map, "confidence"),
    };
}

fn decodeScore(comptime Answer: type, dec: *json.Decoder, map: std.json.ObjectMap) json.Decoder.Error!Answer {
    const level_count = @typeInfo(@FieldType(Answer, "probabilities")).array.len;
    var answer: Answer = .{
        .score = try numberField(dec, map, "score"),
        .probabilities = undefined,
        .confidence = try probabilityField(dec, map, "confidence"),
    };

    const probabilities_value = try dec.field(map, "probabilities");
    dec.pushKey("probabilities");
    const probabilities_map = try dec.object(probabilities_value);
    inline for (0..level_count) |level| {
        answer.probabilities[level] = try probabilityField(dec, probabilities_map, levelKey(level));
    }
    dec.pop();

    const legend_value = try dec.field(map, "legend");
    dec.pushKey("legend");
    const legend_map = try dec.object(legend_value);
    inline for (0..level_count) |level| {
        answer.legend[level] = try dec.field(legend_map, levelKey(level));
    }
    dec.pop();

    return answer;
}

/// The wire key of a Score level: `"0"`, `"1"`, ...
pub fn levelKey(comptime level: usize) []const u8 {
    return comptime std.fmt.comptimePrint("{d}", .{level});
}

/// Decodes the optional `usage` member of a response object.
pub fn decodeUsage(dec: *json.Decoder, top: std.json.ObjectMap) json.Decoder.Error!Usage {
    const value = top.get("usage") orelse return .{};
    dec.pushKey("usage");
    defer dec.pop();
    if (value == .null) return .{};
    const map = try dec.object(value);
    return .{
        .input_tokens = try optionalCountField(dec, map, "input_tokens"),
        .output_tokens = try optionalCountField(dec, map, "output_tokens"),
    };
}

/// Decodes a `GET /v1/models` response. Strings in the result point into
/// `root`; the slice is allocated with `arena`.
pub fn decodeModels(
    arena: Allocator,
    dec: *json.Decoder,
    root: std.json.Value,
) (json.Decoder.Error || error{OutOfMemory})![]const Model {
    const top = try dec.object(root);
    const list_value = try dec.field(top, "models");
    dec.pushKey("models");
    defer dec.pop();
    const items = switch (list_value) {
        .array => |array| array.items,
        else => return dec.fail("expected an array", .{}),
    };
    const models = try arena.alloc(Model, items.len);
    for (items, models, 0..) |item, *model, index| {
        dec.pushIndex(index);
        defer dec.pop();
        const map = try dec.object(item);
        model.* = .{
            .name = try stringField(dec, map, "name"),
            .description = try stringField(dec, map, "description"),
            .release_date = try stringField(dec, map, "release_date"),
        };
    }
    return models;
}

pub fn stringField(dec: *json.Decoder, map: std.json.ObjectMap, name: []const u8) json.Decoder.Error![]const u8 {
    const value = try dec.field(map, name);
    dec.pushKey(name);
    defer dec.pop();
    return dec.string(value);
}

pub fn numberField(dec: *json.Decoder, map: std.json.ObjectMap, name: []const u8) json.Decoder.Error!f64 {
    const value = try dec.field(map, name);
    dec.pushKey(name);
    defer dec.pop();
    return dec.number(value);
}

pub fn probabilityField(dec: *json.Decoder, map: std.json.ObjectMap, name: []const u8) json.Decoder.Error!f64 {
    const value = try dec.field(map, name);
    dec.pushKey(name);
    defer dec.pop();
    return dec.probability(value);
}

fn optionalCountField(dec: *json.Decoder, map: std.json.ObjectMap, name: []const u8) json.Decoder.Error!?u64 {
    const value = map.get(name) orelse return null;
    dec.pushKey(name);
    defer dec.pop();
    return dec.optionalCount(value);
}

/// What an error response body says.
pub const ErrorBody = struct {
    /// The server's message, or a description of the body when it has none.
    message: []const u8,
    /// `detail.error_type`, such as `authentication_error`.
    error_type: ?[]const u8 = null,
};

/// The most bytes of a body without a message quoted in `ErrorBody.message`.
const max_body_in_message = 200;

/// Extracts a message from an error response body.
///
/// The API sends `{"detail": {"error_type": ..., "message": ...}}` for
/// authentication and usage errors, `{"detail": [{"loc": [...], "msg": ...}]}`
/// for validation errors, and `{"detail": "Not Found"}` for unknown paths.
/// The top-level `error` and `message` members the official SDKs also read are
/// checked first. A body without a message is quoted, truncated to 200 bytes.
/// Strings are allocated with `arena`; none borrow from `body`.
pub fn parseErrorBody(arena: Allocator, status: std.http.Status, body: []const u8) Allocator.Error!ErrorBody {
    if (std.mem.trim(u8, body, " \t\r\n").len == 0) {
        return .{ .message = try std.fmt.allocPrint(arena, "HTTP {d} with no body", .{@intFromEnum(status)}) };
    }
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => return .{ .message = try quoteBody(arena, body) },
    };
    const top = switch (root) {
        .object => |map| map,
        else => return .{ .message = try quoteBody(arena, body) },
    };

    var result: ErrorBody = .{ .message = undefined };
    if (top.get("detail")) |detail| switch (detail) {
        .object => |map| if (map.get("error_type")) |t| switch (t) {
            .string => |s| result.error_type = s,
            else => {},
        },
        else => {},
    };

    for ([_][]const u8{ "error", "message", "detail" }) |name| {
        const candidate = top.get(name) orelse continue;
        if (try messageFrom(arena, candidate)) |message| {
            result.message = message;
            return result;
        }
    }
    result.message = try quoteBody(arena, body);
    return result;
}

fn messageFrom(arena: Allocator, value: std.json.Value) Allocator.Error!?[]const u8 {
    switch (value) {
        .string => |s| return if (s.len > 0) s else null,
        .object => |map| {
            const message = map.get("message") orelse return null;
            return switch (message) {
                .string => |s| if (s.len > 0) s else null,
                else => null,
            };
        },
        .array => |array| return describeValidationErrors(arena, array.items),
        else => return null,
    }
}

/// Joins FastAPI-style validation errors as `questions.a.criteria: msg; ...`,
/// dropping the leading `body` location segment.
fn describeValidationErrors(arena: Allocator, items: []const std.json.Value) Allocator.Error!?[]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    var count: usize = 0;
    for (items) |item| {
        const map = switch (item) {
            .object => |m| m,
            else => continue,
        };
        const msg = switch (map.get("msg") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (count > 0) w.writeAll("; ") catch return error.OutOfMemory;
        count += 1;

        var location_len: usize = 0;
        if (map.get("loc")) |loc| switch (loc) {
            .array => |segments| for (segments.items) |segment| {
                switch (segment) {
                    .string => |s| {
                        if (location_len == 0 and std.mem.eql(u8, s, "body")) continue;
                        if (location_len > 0) w.writeByte('.') catch return error.OutOfMemory;
                        w.writeAll(s) catch return error.OutOfMemory;
                    },
                    .integer => |i| {
                        if (location_len > 0) w.writeByte('.') catch return error.OutOfMemory;
                        w.print("{d}", .{i}) catch return error.OutOfMemory;
                    },
                    else => continue,
                }
                location_len += 1;
            },
            else => {},
        };
        if (location_len > 0) w.writeAll(": ") catch return error.OutOfMemory;
        w.writeAll(msg) catch return error.OutOfMemory;
    }
    if (count == 0) return null;
    return out.written();
}

fn quoteBody(arena: Allocator, body: []const u8) Allocator.Error![]const u8 {
    if (body.len <= max_body_in_message) return arena.dupe(u8, body);
    // Cut on a UTF-8 boundary so the message stays valid text.
    var end: usize = max_body_in_message;
    while (end > 0 and (body[end] & 0xC0) == 0x80) end -= 1;
    return std.fmt.allocPrint(arena, "{s}...", .{body[0..end]});
}

/// Options for `encodeAnswers`.
pub const ResponseOptions = struct {
    model: []const u8 = "jev-test",
    usage: Usage = .{ .input_tokens = 100, .output_tokens = 10 },
};

/// Encodes a successful `POST /v1/systemone` response body carrying
/// `answers` for `questions`, as the API would send it. Score legends are
/// taken from the questions' levels. Caller owns the returned slice.
pub fn encodeAnswers(
    gpa: Allocator,
    questions: anytype,
    answers: question.Answers(@TypeOf(questions)),
    options: ResponseOptions,
) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var jws: std.json.Stringify = .{ .writer = &out.writer };
    writeAnswers(&jws, questions, answers, options) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeAnswers(
    jws: *std.json.Stringify,
    questions: anytype,
    answers: question.Answers(@TypeOf(questions)),
    options: ResponseOptions,
) std.json.Stringify.Error!void {
    try jws.beginObject();
    try jws.objectField("model");
    try jws.write(options.model);
    try jws.objectField("answers");
    try jws.beginObject();
    inline for (@typeInfo(@TypeOf(questions)).@"struct".fields) |field| {
        const Q = field.type;
        const answer = @field(answers, field.name);
        try jws.objectField(field.name);
        try jws.beginObject();
        try jws.objectField("type");
        try jws.write(@tagName(Q.kind));
        switch (Q.kind) {
            .noul => {
                try jws.objectField("noul");
                try jws.write(answer.noul);
            },
            .choice => {
                try jws.objectField("choice");
                try jws.write(@tagName(answer.choice));
                try jws.objectField("probabilities");
                try jws.write(answer.probabilities);
                try jws.objectField("confidence");
                try jws.write(answer.confidence);
            },
            .score => {
                const levels = @field(questions, field.name).levels;
                try jws.objectField("score");
                try jws.write(answer.score);
                try jws.objectField("legend");
                try jws.beginObject();
                inline for (0..answer.probabilities.len) |level| {
                    try jws.objectField(levelKey(level));
                    try jws.write(levels[level]);
                }
                try jws.endObject();
                try jws.objectField("probabilities");
                try jws.beginObject();
                inline for (0..answer.probabilities.len) |level| {
                    try jws.objectField(levelKey(level));
                    try jws.write(answer.probabilities[level]);
                }
                try jws.endObject();
                try jws.objectField("confidence");
                try jws.write(answer.confidence);
            },
        }
        try jws.endObject();
    }
    try jws.endObject();
    try jws.objectField("usage");
    try jws.write(options.usage);
    try jws.endObject();
}

const Team = enum { billing, technical, sales };

const mixed_questions = .{
    .department = question.choice(Team, "Which team should handle this", .{
        .billing = "Payment or subscription issues",
        .technical = "Bugs or integration problems",
        .sales = "Pricing or account questions",
    }),
    .is_urgent = question.noul("The message conveys urgency or time-sensitivity", .{}),
    .frustration = question.score("How frustrated the customer appears", .{
        "Calm, just stating facts",
        "Frustrated but civil",
        "Very angry, strong language",
    }),
};

fn expectJsonEqual(expected: []const u8, actual: []const u8) !void {
    const gpa = std.testing.allocator;
    var expected_parsed = try std.json.parseFromSlice(std.json.Value, gpa, expected, .{});
    defer expected_parsed.deinit();
    const normalized = try std.json.Stringify.valueAlloc(gpa, expected_parsed.value, .{});
    defer gpa.free(normalized);
    try std.testing.expectEqualStrings(normalized, actual);
}

test "encodeAsk matches the mixed request fixture byte for byte" {
    const gpa = std.testing.allocator;
    var failure: json.Failure = .{};
    const body = try encodeAsk(
        gpa,
        "Our API integration started returning 500 errors on every request about 20 minutes ago, and we can't process any customer orders until this is fixed.",
        "jev-latest",
        mixed_questions,
        &failure,
    );
    defer gpa.free(body);
    try expectJsonEqual(@embedFile("testdata/requests/mixed.json"), body);
}

test "encodeAsk sends structured state, instructions and criteria as JSON" {
    const gpa = std.testing.allocator;
    const Customer = enum { @"Beaver Logistics", @"Dam Logistics", @"Beaver Dam Logistics", Beaver, Dam };
    const questions = .{
        .invoice_number_is_correct = question.noul(.{
            .field = .{ .name = "invoice_number", .type = "string", .description = "The identifier printed on the invoice." },
            .extracted_value = "4471",
            .question = "Does `extracted_value` match the `field` as it appears in `source_text`?",
        }, .{}),
        .customer_name = question.choice(Customer, .{
            .field = .{ .name = "customer_name", .type = "string", .description = "The organization the invoice was issued to." },
            .question = "Which option is the value of `field` in `source_text`?",
        }, .{}),
        .amount_due = question.score(.{
            .field = .{ .name = "amount_due", .type = "number", .unit = "USD", .description = "The total the invoice asks to be paid." },
            .question = "How large is the `field` value in `source_text`?",
        }, .{ "Under $1,000", "$1,000 to $10,000", "$10,000 to $100,000", "$100,000 to $1,000,000", "Over $1,000,000" }),
        .payment_terms = question.score(.{
            .field = .{ .name = "payment_terms", .type = "integer", .unit = "days", .description = "Days allowed for payment, from terms such as \"net 30\"." },
            .question = "How many days does the `field` in `source_text` allow for payment?",
        }, .{ "Due on receipt", "Net 10", "Net 30", "Net 60", "Net 90" }),
    };
    const state = .{ .source_text = "Invoice #4471 issued March 3, 2026 to Beaver Dam Logistics for $12,840.00, net 30." };
    var failure: json.Failure = .{};
    const body = try encodeAsk(gpa, state, "jev-latest", questions, &failure);
    defer gpa.free(body);
    try expectJsonEqual(@embedFile("testdata/requests/structured_instructions.json"), body);
}

test "encodeAsk rejects state that is not a string, object or array" {
    const gpa = std.testing.allocator;
    var failure: json.Failure = .{};
    const questions = .{ .a = question.noul("Is this a greeting?", .{}) };
    try std.testing.expectError(error.InvalidRequest, encodeAsk(gpa, @as(u32, 42), "jev-latest", questions, &failure));
    try std.testing.expectEqualStrings("state", failure.path());
    try std.testing.expectEqualStrings("state must be a string, object or array", failure.message());

    try std.testing.expectError(error.InvalidRequest, encodeAsk(gpa, @as(?[]const u8, null), "jev-latest", questions, &failure));

    const bad = "caf\xe9";
    const bad_questions = .{ .a = question.noul(@as([]const u8, bad), .{}) };
    try std.testing.expectError(error.InvalidRequest, encodeAsk(gpa, "hello", "jev-latest", bad_questions, &failure));
    try std.testing.expectEqualStrings("questions.a.instructions", failure.path());
}

test "decodeAsk decodes the mixed response fixture" {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, @embedFile("testdata/responses/mixed.json"), .{});
    defer parsed.deinit();
    var dec: json.Decoder = .{};
    const decoded = try decodeAsk(@TypeOf(mixed_questions), &dec, parsed.value);
    try std.testing.expectEqualStrings("jev-1.13.0", decoded.model);
    try std.testing.expectEqual(0.92, decoded.answers.is_urgent.noul);
    try std.testing.expectEqual(Team.technical, decoded.answers.department.choice);
    try std.testing.expectEqual(0.85, decoded.answers.department.probabilities.technical);
    try std.testing.expectEqual(0.82, decoded.answers.department.confidence);
    try std.testing.expectEqual(1.6, decoded.answers.frustration.score);
    try std.testing.expectEqual([3]f64{ 0.05, 0.3, 0.65 }, decoded.answers.frustration.probabilities);
    try std.testing.expectEqualStrings("Very angry", decoded.answers.frustration.legend[2].string);
    try std.testing.expectEqual(312, decoded.usage.input_tokens);
    try std.testing.expectEqual(48, decoded.usage.output_tokens);
}

test "decodeAsk accepts integer probabilities, extra fields, and missing usage" {
    const gpa = std.testing.allocator;
    const Tone = enum { calm, angry };
    const questions = .{
        .is_spam = question.noul("Is this spam?", .{}),
        .tone = question.choice(Tone, "Tone?", .{}),
        .urgency = question.score("Urgency?", .{ "Can wait", "This week", "Today" }),
    };
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, @embedFile("testdata/responses/integer_probabilities.json"), .{});
    defer parsed.deinit();
    var dec: json.Decoder = .{};
    const decoded = try decodeAsk(@TypeOf(questions), &dec, parsed.value);
    try std.testing.expectEqual(1, decoded.answers.is_spam.noul);
    try std.testing.expectEqual(Tone.calm, decoded.answers.tone.choice);
    try std.testing.expectEqual(2, decoded.answers.urgency.score);
    try std.testing.expectEqual(0, decoded.usage.output_tokens);

    const extra = .{
        .is_urgent = question.noul("Urgent?", .{}),
        .department = question.choice(Team, "Team?", .{}),
        .frustration = question.score("Frustration?", .{ "Calm", "Frustrated", "Very angry" }),
    };
    var extra_parsed = try std.json.parseFromSlice(std.json.Value, gpa, @embedFile("testdata/responses/extra_fields.json"), .{});
    defer extra_parsed.deinit();
    const extra_decoded = try decodeAsk(@TypeOf(extra), &dec, extra_parsed.value);
    try std.testing.expectEqual(0.92, extra_decoded.answers.is_urgent.noul);

    const unknown = .{ .is_urgent = question.noul("Urgent?", .{}) };
    var unknown_parsed = try std.json.parseFromSlice(std.json.Value, gpa, @embedFile("testdata/responses/unknown_type.json"), .{});
    defer unknown_parsed.deinit();
    _ = try decodeAsk(@TypeOf(unknown), &dec, unknown_parsed.value);

    var missing_parsed = try std.json.parseFromSlice(std.json.Value, gpa, @embedFile("testdata/responses/missing_usage.json"), .{});
    defer missing_parsed.deinit();
    const missing = try decodeAsk(@TypeOf(unknown), &dec, missing_parsed.value);
    try std.testing.expectEqual(null, missing.usage.input_tokens);
}

test "decodeAsk decodes structured legends" {
    const gpa = std.testing.allocator;
    const Route = enum { billing, technical, other };
    const questions = .{
        .route = question.choice(Route, "Route the ticket", .{}),
        .severity = question.score(.{ "Rate", "severity" }, .{ .{ .level = "low" }, .{"medium"}, "high" }),
        .refund = question.noul(null, .{ .yes = .{ .asks_for = "refund" }, .no = null }),
    };
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, @embedFile("testdata/responses/recorded_structured.json"), .{});
    defer parsed.deinit();
    var dec: json.Decoder = .{};
    const decoded = try decodeAsk(@TypeOf(questions), &dec, parsed.value);
    try std.testing.expectEqualStrings("low", decoded.answers.severity.legend[0].object.get("level").?.string);
    try std.testing.expectEqualStrings("medium", decoded.answers.severity.legend[1].array.items[0].string);
    try std.testing.expectEqual(0, decoded.answers.severity.maxLevel());
}

fn expectDecodeFailure(comptime Questions: type, body: []const u8, path: []const u8, message: []const u8) !void {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer parsed.deinit();
    var dec: json.Decoder = .{};
    try std.testing.expectError(error.InvalidResponse, decodeAsk(Questions, &dec, parsed.value));
    try std.testing.expectEqualStrings(path, dec.failure.path());
    try std.testing.expectEqualStrings(message, dec.failure.message());
}

test "decodeAsk reports what is wrong and where" {
    const Q = @TypeOf(mixed_questions);
    const good_choice =
        \\"department":{"type":"choice","choice":"technical","probabilities":{"billing":0.1,"technical":0.8,"sales":0.1},"confidence":0.8}
    ;
    const good_score =
        \\"frustration":{"type":"score","score":1,"legend":{"0":"a","1":"b","2":"c"},"probabilities":{"0":0.1,"1":0.8,"2":0.1},"confidence":0.5}
    ;
    try expectDecodeFailure(Q, "[]", "", "expected an object, got an array");
    try expectDecodeFailure(Q, "{\"answers\":{}}", "model", "missing required field");
    try expectDecodeFailure(Q, "{\"model\":\"m\",\"answers\":{}}", "answers.department", "missing required field");
    try expectDecodeFailure(Q, "{\"model\":\"m\",\"answers\":{\"department\":{\"type\":\"noul\",\"noul\":1}}}", "answers.department.type", "expected a choice answer, got \"noul\"");
    try expectDecodeFailure(Q, "{\"model\":\"m\",\"answers\":{\"department\":{\"type\":\"choice\",\"choice\":\"legal\"}}}", "answers.department.choice", "\"legal\" is not an option of the question");
    try expectDecodeFailure(Q, "{\"model\":\"m\",\"answers\":{\"department\":{\"type\":\"choice\",\"choice\":\"sales\",\"probabilities\":{\"billing\":0.5,\"technical\":0.5},\"confidence\":1}}}", "answers.department.probabilities.sales", "missing required field");
    try expectDecodeFailure(Q, "{\"model\":\"m\",\"answers\":{" ++ good_choice ++ ",\"is_urgent\":{\"type\":\"noul\",\"noul\":2}}}", "answers.is_urgent.noul", "expected a number from 0 to 1, got 2");
    try expectDecodeFailure(Q, "{\"model\":\"m\",\"answers\":{" ++ good_choice ++ ",\"is_urgent\":{\"type\":\"noul\",\"noul\":\"high\"}}}", "answers.is_urgent.noul", "expected a number, got a string");
    try expectDecodeFailure(Q, "{\"model\":\"m\",\"answers\":{" ++ good_choice ++ ",\"is_urgent\":{\"type\":\"noul\",\"noul\":0.5},\"frustration\":{\"type\":\"score\",\"score\":1,\"confidence\":1,\"probabilities\":{\"0\":0.5,\"1\":0.5}}}}", "answers.frustration.probabilities.2", "missing required field");
    try expectDecodeFailure(Q, "{\"model\":\"m\",\"answers\":{" ++ good_choice ++ ",\"is_urgent\":{\"type\":\"noul\",\"noul\":0.5}," ++ good_score ++ "},\"usage\":{\"input_tokens\":-1}}", "usage.input_tokens", "expected a non-negative integer, got -1");
}

test "decodeModels" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, @embedFile("testdata/responses/recorded_models.json"), .{});
    defer parsed.deinit();
    var dec: json.Decoder = .{};
    const models = try decodeModels(arena.allocator(), &dec, parsed.value);
    try std.testing.expectEqual(2, models.len);
    try std.testing.expectEqualStrings("jev-latest", models[0].name);
    try std.testing.expectEqualStrings("2026-09-10T18:39:06.057655+00:00", models[1].release_date);

    var bad = try std.json.parseFromSlice(std.json.Value, gpa, "{\"models\":[{\"name\":\"x\",\"description\":\"y\"}]}", .{});
    defer bad.deinit();
    try std.testing.expectError(error.InvalidResponse, decodeModels(arena.allocator(), &dec, bad.value));
    try std.testing.expectEqualStrings("models[0].release_date", dec.failure.path());
}

test parseErrorBody {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const auth = try parseErrorBody(a, .unauthorized,
        \\{"detail":{"error_type":"authentication_error","message":"Cannot authenticate with the server. Please check your API key and try again."}}
    );
    try std.testing.expectEqualStrings("Cannot authenticate with the server. Please check your API key and try again.", auth.message);
    try std.testing.expectEqualStrings("authentication_error", auth.error_type.?);

    const validation = try parseErrorBody(a, @enumFromInt(422),
        \\{"detail":[{"type":"too_short","loc":["body","questions"],"msg":"Dictionary should have at least 1 item after validation, not 0"},{"type":"x","loc":["body","questions","a",0],"msg":"bad"}]}
    );
    try std.testing.expectEqualStrings("questions: Dictionary should have at least 1 item after validation, not 0; questions.a.0: bad", validation.message);
    try std.testing.expectEqual(null, validation.error_type);

    const not_found = try parseErrorBody(a, .not_found, "{\"detail\":\"Not Found\"}");
    try std.testing.expectEqualStrings("Not Found", not_found.message);

    const top_level = try parseErrorBody(a, .bad_request, "{\"error\":{\"message\":\"nope\"},\"detail\":\"ignored\"}");
    try std.testing.expectEqualStrings("nope", top_level.message);

    const empty = try parseErrorBody(a, .bad_gateway, "");
    try std.testing.expectEqualStrings("HTTP 502 with no body", empty.message);

    const text = try parseErrorBody(a, .bad_gateway, "upstream connect error");
    try std.testing.expectEqualStrings("upstream connect error", text.message);

    const long = "é" ** 150;
    const truncated = try parseErrorBody(a, .bad_gateway, long);
    try std.testing.expect(std.unicode.utf8ValidateSlice(truncated.message));
    try std.testing.expect(std.mem.endsWith(u8, truncated.message, "..."));
    try std.testing.expect(truncated.message.len <= max_body_in_message + 3);

    const no_message = try parseErrorBody(a, .bad_request, "{\"detail\":{\"error_type\":\"x\"}}");
    try std.testing.expectEqualStrings("{\"detail\":{\"error_type\":\"x\"}}", no_message.message);
    try std.testing.expectEqualStrings("x", no_message.error_type.?);
}

test "encodeAnswers round-trips through decodeAsk" {
    const gpa = std.testing.allocator;
    const body = try encodeAnswers(gpa, mixed_questions, .{
        .department = .{ .choice = .billing, .probabilities = .{ .billing = 0.7, .technical = 0.2, .sales = 0.1 }, .confidence = 0.6 },
        .is_urgent = .{ .noul = 0.25 },
        .frustration = .{ .score = 0.4, .probabilities = .{ 0.6, 0.4, 0 }, .confidence = 0.5 },
    }, .{ .model = "jev-1.13.0" });
    defer gpa.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer parsed.deinit();
    var dec: json.Decoder = .{};
    const decoded = try decodeAsk(@TypeOf(mixed_questions), &dec, parsed.value);
    try std.testing.expectEqual(Team.billing, decoded.answers.department.choice);
    try std.testing.expectEqual(0.25, decoded.answers.is_urgent.noul);
    try std.testing.expectEqualStrings("Frustrated but civil", decoded.answers.frustration.legend[1].string);
    try std.testing.expectEqual(100, decoded.usage.input_tokens);
}
