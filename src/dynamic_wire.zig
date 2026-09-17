//! The wire format for dynamic questions: validation and request encoding,
//! and response decoding. Internal; `Client.askDynamic` is the public entry.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("json.zig");
const wire = @import("wire.zig");
const dynamic = @import("dynamic.zig");
const Question = dynamic.Question;
const Json = dynamic.Json;

/// Validates `questions` and encodes a `POST /v1/systemone` body. On
/// `error.InvalidRequest`, `failure` names the offending question.
pub fn encodeRequest(
    gpa: Allocator,
    state: anytype,
    model: []const u8,
    questions: []const Question,
    failure: *json.Failure,
) json.Encoder.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var enc: json.Encoder = .init(gpa, &out.writer);
    writeRequest(gpa, &enc, state, model, questions) catch |err| {
        failure.* = enc.failure;
        return err;
    };
    return out.toOwnedSlice() catch error.OutOfMemory;
}

fn writeRequest(
    gpa: Allocator,
    enc: *json.Encoder,
    state: anytype,
    model: []const u8,
    questions: []const Question,
) json.Encoder.Error!void {
    try enc.beginObject();
    try wire.writeState(enc, state);
    try enc.objectField("model");
    try enc.string(model);
    try enc.objectField("questions");
    try enc.beginObject();
    if (questions.len == 0) return enc.fail("at least one question is required", .{});

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(gpa);
    try seen.ensureTotalCapacity(gpa, @intCast(questions.len));

    for (questions, 0..) |q, index| {
        if (q.id.len == 0) return enc.fail("question {d} has an empty id", .{index});
        try enc.objectField(q.id);
        if (seen.getOrPutAssumeCapacity(q.id).found_existing) {
            return enc.fail("duplicate question id \"{s}\"", .{q.id});
        }
        try writeQuestion(gpa, enc, q);
    }
    try enc.endObject();
    try enc.endObject();
}

fn writeQuestion(gpa: Allocator, enc: *json.Encoder, q: Question) json.Encoder.Error!void {
    try enc.beginObject();
    try enc.objectField("type");
    try enc.string(@tagName(q.spec));
    switch (q.spec) {
        .noul => |noul| {
            const has_yes = if (noul.yes) |yes| !yes.isEmpty() else false;
            const has_no = if (noul.no) |no| !no.isEmpty() else false;
            if (noul.instructions.isEmpty() and !has_yes and !has_no) {
                return enc.fail("a noul question needs instructions or criteria", .{});
            }
            try writeEntry(enc, "instructions", noul.instructions);
            if (noul.yes != null or noul.no != null) {
                try enc.objectField("criteria");
                try enc.beginObject();
                if (noul.yes) |yes| try writeEntry(enc, "true", yes);
                if (noul.no) |no| try writeEntry(enc, "false", no);
                try enc.endObject();
            }
        },
        .choice => |choice| {
            try writeEntry(enc, "instructions", choice.instructions);
            try enc.objectField("criteria");
            try enc.beginObject();
            const count = choice.options.len();
            if (count == 0) return enc.fail("a choice question needs at least one option", .{});
            var seen: std.StringHashMapUnmanaged(void) = .empty;
            defer seen.deinit(gpa);
            try seen.ensureTotalCapacity(gpa, @intCast(count));
            for (0..count) |index| {
                const name = choice.options.name(index);
                if (name.len == 0) return enc.fail("option {d} has an empty name", .{index});
                if (seen.getOrPutAssumeCapacity(name).found_existing) {
                    try enc.objectField(name);
                    return enc.fail("duplicate option \"{s}\"", .{name});
                }
                try writeEntry(enc, name, choice.options.description(index));
            }
            try enc.endObject();
        },
        .score => |score| {
            try writeEntry(enc, "instructions", score.instructions);
            try enc.objectField("criteria");
            if (score.levels.len() < 2) {
                return enc.fail("a score question needs at least two levels, got {d}", .{score.levels.len()});
            }
            try enc.beginArray();
            switch (score.levels) {
                .text => |levels| for (levels) |level| try enc.string(level),
                .json => |levels| for (levels) |level| {
                    switch (level.kind()) {
                        .string, .array, .object => try enc.write(level),
                        else => |kind| return enc.fail("a score level must be a string, object or array, got {t}", .{kind}),
                    }
                },
            }
            try enc.endArray();
        },
    }
    try enc.endObject();
}

/// Writes a member whose value may be a string, object, array or null, the
/// JSON the API accepts for instructions, descriptions and criteria.
fn writeEntry(enc: *json.Encoder, name: []const u8, value: Json) json.Encoder.Error!void {
    try enc.objectField(name);
    switch (value.kind()) {
        .null, .string, .array, .object => try enc.write(value),
        else => |kind| return enc.fail("expected a string, object, array or null, got {t}", .{kind}),
    }
}

pub const Decoded = struct {
    model: []const u8,
    answers: []const dynamic.Entry,
    usage: wire.Usage,
};

/// Decodes a `POST /v1/systemone` response for dynamic questions into
/// `arena`. Every question must have an answer of the matching type.
pub fn decodeResponse(
    arena: Allocator,
    reader: *json.Reader,
    questions: []const Question,
) (json.Reader.Error || Allocator.Error)!Decoded {
    var model: ?[]const u8 = null;
    var answers: ?[]const dynamic.Entry = null;
    var usage: wire.Usage = .{};

    try reader.beginObject();
    while (try reader.nextKey()) |key| {
        if (std.mem.eql(u8, key, "model")) {
            model = try reader.string();
        } else if (std.mem.eql(u8, key, "answers")) {
            answers = try decodeAnswers(arena, reader, questions);
        } else if (std.mem.eql(u8, key, "usage")) {
            usage = try wire.decodeUsage(reader);
        } else {
            try reader.skipValue();
        }
    }
    return .{
        .model = model orelse return reader.missingField("model"),
        .answers = answers orelse return reader.missingField("answers"),
        .usage = usage,
    };
}

/// Decodes the answers object: one entry per question, by id.
fn decodeAnswers(
    arena: Allocator,
    reader: *json.Reader,
    questions: []const Question,
) (json.Reader.Error || Allocator.Error)![]const dynamic.Entry {
    const entries = try arena.alloc(dynamic.Entry, questions.len);
    const found = try arena.alloc(bool, questions.len);
    @memset(found, false);

    try reader.beginObject();
    while (try reader.nextKey()) |key| {
        var matched = false;
        for (questions, 0..) |q, i| {
            if (!matched and std.mem.eql(u8, q.id, key)) {
                entries[i] = .{ .id = try arena.dupe(u8, q.id), .answer = try decodeAnswer(arena, reader, q) };
                found[i] = true;
                matched = true;
            }
        }
        if (!matched) try reader.skipValue();
    }
    for (questions, 0..) |q, i| {
        if (!found[i]) return reader.missingField(q.id);
    }
    return entries;
}

fn decodeAnswer(arena: Allocator, reader: *json.Reader, q: Question) (json.Reader.Error || Allocator.Error)!dynamic.Answer {
    return switch (q.spec) {
        .noul => .{ .noul = .{ .noul = try decodeNoulAnswer(reader) } },
        .choice => |choice| .{ .choice = try decodeChoiceAnswer(arena, reader, choice) },
        .score => |score| .{ .score = try decodeScoreAnswer(arena, reader, score) },
    };
}

fn decodeNoulAnswer(reader: *json.Reader) json.Reader.Error!f64 {
    var value: ?f64 = null;
    var saw_type = false;

    try reader.beginObject();
    while (try reader.nextKey()) |key| {
        if (std.mem.eql(u8, key, "type")) {
            try wire.expectType(reader, "noul");
            saw_type = true;
        } else if (std.mem.eql(u8, key, "noul")) {
            value = try reader.probability();
        } else {
            try reader.skipValue();
        }
    }
    if (!saw_type) return reader.missingField("type");
    return value orelse return reader.missingField("noul");
}

fn decodeChoiceAnswer(
    arena: Allocator,
    reader: *json.Reader,
    choice: dynamic.Choice,
) (json.Reader.Error || Allocator.Error)!dynamic.ChoiceAnswer {
    const count = choice.options.len();
    const options = try arena.alloc([]const u8, count);
    for (options, 0..) |*option, index| option.* = try arena.dupe(u8, choice.options.name(index));
    const probabilities = try arena.alloc(f64, count);
    @memset(probabilities, 0);
    const found = try arena.alloc(bool, count);
    @memset(found, false);
    var index: ?usize = null;
    var confidence: ?f64 = null;
    var saw_type = false;

    try reader.beginObject();
    while (try reader.nextKey()) |key| {
        if (std.mem.eql(u8, key, "type")) {
            try wire.expectType(reader, "choice");
            saw_type = true;
        } else if (std.mem.eql(u8, key, "choice")) {
            const text = try reader.string();
            index = for (options, 0..) |option, i| {
                if (std.mem.eql(u8, option, text)) break i;
            } else return reader.fail("\"{s}\" is not an option of the question", .{text});
        } else if (std.mem.eql(u8, key, "probabilities")) {
            try reader.beginObject();
            while (try reader.nextKey()) |name| {
                const at = for (options, 0..) |option, i| {
                    if (std.mem.eql(u8, option, name)) break i;
                } else {
                    try reader.skipValue();
                    continue;
                };
                probabilities[at] = try reader.probability();
                found[at] = true;
            }
        } else if (std.mem.eql(u8, key, "confidence")) {
            confidence = try reader.probability();
        } else {
            try reader.skipValue();
        }
    }
    if (!saw_type) return reader.missingField("type");
    const picked = index orelse return reader.missingField("choice");
    for (options, 0..) |option, i| {
        if (!found[i]) return reader.missingField(option);
    }
    return .{
        .choice = options[picked],
        .index = picked,
        .options = options,
        .probabilities = probabilities,
        .confidence = confidence orelse return reader.missingField("confidence"),
    };
}

fn decodeScoreAnswer(
    arena: Allocator,
    reader: *json.Reader,
    score: dynamic.Score,
) (json.Reader.Error || Allocator.Error)!dynamic.ScoreAnswer {
    const count = score.levels.len();
    const probabilities = try arena.alloc(f64, count);
    @memset(probabilities, 0);
    const legend = try arena.alloc(std.json.Value, count);
    @memset(legend, .null);
    const found_probabilities = try arena.alloc(bool, count);
    @memset(found_probabilities, false);
    const found_legend = try arena.alloc(bool, count);
    @memset(found_legend, false);
    var answer_score: ?f64 = null;
    var confidence: ?f64 = null;
    var saw_type = false;
    var key_buffer: [20]u8 = undefined;

    try reader.beginObject();
    while (try reader.nextKey()) |key| {
        if (std.mem.eql(u8, key, "type")) {
            try wire.expectType(reader, "score");
            saw_type = true;
        } else if (std.mem.eql(u8, key, "score")) {
            answer_score = try reader.number();
        } else if (std.mem.eql(u8, key, "confidence")) {
            confidence = try reader.probability();
        } else if (std.mem.eql(u8, key, "probabilities") or std.mem.eql(u8, key, "legend")) {
            const is_legend = std.mem.eql(u8, key, "legend");
            try reader.beginObject();
            while (try reader.nextKey()) |name| {
                const level = std.fmt.parseInt(usize, name, 10) catch {
                    try reader.skipValue();
                    continue;
                };
                if (level >= count) {
                    try reader.skipValue();
                    continue;
                }
                if (is_legend) {
                    legend[level] = try reader.value();
                    found_legend[level] = true;
                } else {
                    probabilities[level] = try reader.probability();
                    found_probabilities[level] = true;
                }
            }
        } else {
            try reader.skipValue();
        }
    }
    if (!saw_type) return reader.missingField("type");
    // The maps have been closed by now, so their name is put back for the
    // path the failure is reported at.
    var level: usize = 0;
    while (level < count) : (level += 1) {
        const key = std.fmt.bufPrint(&key_buffer, "{d}", .{level}) catch unreachable;
        if (!found_probabilities[level]) {
            reader.pushKey("probabilities");
            defer reader.pop();
            return reader.missingField(key);
        }
    }
    level = 0;
    while (level < count) : (level += 1) {
        const key = std.fmt.bufPrint(&key_buffer, "{d}", .{level}) catch unreachable;
        if (!found_legend[level]) {
            reader.pushKey("legend");
            defer reader.pop();
            return reader.missingField(key);
        }
    }
    return .{
        .score = answer_score orelse return reader.missingField("score"),
        .probabilities = probabilities,
        .legend = legend,
        .confidence = confidence orelse return reader.missingField("confidence"),
    };
}

test "encodeRequest matches the typed encoder" {
    const gpa = std.testing.allocator;
    const questions = [_]Question{
        .choice("department", "Which team should handle this", .{ .described = &.{
            .{ .name = "billing", .description = .{ .string = "Payment or subscription issues" } },
            .{ .name = "technical", .description = .{ .string = "Bugs or integration problems" } },
            .{ .name = "sales", .description = .{ .string = "Pricing or account questions" } },
        } }),
        .noul("is_urgent", "The message conveys urgency or time-sensitivity"),
        .score("frustration", "How frustrated the customer appears", .{ .text = &.{
            "Calm, just stating facts",
            "Frustrated but civil",
            "Very angry, strong language",
        } }),
    };
    var failure: json.Failure = .{};
    const body = try encodeRequest(
        gpa,
        "Our API integration started returning 500 errors on every request about 20 minutes ago, and we can't process any customer orders until this is fixed.",
        "jev-latest",
        &questions,
        &failure,
    );
    defer gpa.free(body);

    var expected = try std.json.parseFromSlice(std.json.Value, gpa, @embedFile("testdata/requests/mixed.json"), .{});
    defer expected.deinit();
    const normalized = try std.json.Stringify.valueAlloc(gpa, expected.value, .{});
    defer gpa.free(normalized);
    try std.testing.expectEqualStrings(normalized, body);
}

test "encodeRequest writes structured JSON entries and extra fields" {
    const gpa = std.testing.allocator;
    const questions = [_]Question{
        .{ .id = "requests_credentials", .spec = .{ .noul = .{
            .instructions = .{ .raw = "{\"question\":\"Does the `message` ask for a credential?\"}" },
            .yes = .{ .string = "Asks for a password" },
            .no = .null,
        } } },
        .{
            .id = "severity",
            .spec = .{ .score = .{ .levels = .{ .json = &.{
                .{ .raw = "{\"level\":\"low\"}" },
                .{ .string = "high" },
            } } } },
        },
    };
    var failure: json.Failure = .{};
    const body = try encodeRequest(gpa, .{ .message = "hi" }, "jev-latest", &questions, &failure);
    defer gpa.free(body);
    try std.testing.expectEqualStrings(
        \\{"state":{"message":"hi"},"model":"jev-latest","questions":{"requests_credentials":{"type":"noul","instructions":{"question":"Does the `message` ask for a credential?"},"criteria":{"true":"Asks for a password","false":null}},"severity":{"type":"score","instructions":null,"criteria":[{"level":"low"},"high"]}}}
    , body);
}

fn expectInvalid(questions: []const Question, path: []const u8, message: []const u8) !void {
    const gpa = std.testing.allocator;
    var failure: json.Failure = .{};
    try std.testing.expectError(error.InvalidRequest, encodeRequest(gpa, "state", "jev-latest", questions, &failure));
    try std.testing.expectEqualStrings(path, failure.path());
    try std.testing.expectEqualStrings(message, failure.message());
}

test "encodeRequest validates questions" {
    try expectInvalid(&.{}, "questions", "at least one question is required");
    try expectInvalid(&.{ .noul("a", "x"), .noul("a", "y") }, "questions.a", "duplicate question id \"a\"");
    try expectInvalid(&.{.noul("", "x")}, "questions", "question 0 has an empty id");
    try expectInvalid(&.{.choice("c", "x", .{ .names = &.{} })}, "questions.c.criteria", "a choice question needs at least one option");
    try expectInvalid(&.{.choice("c", "x", .{ .names = &.{ "a", "b", "a" } })}, "questions.c.criteria.a", "duplicate option \"a\"");
    try expectInvalid(&.{.score("s", "x", .{ .text = &.{"only"} })}, "questions.s.criteria", "a score question needs at least two levels, got 1");
    try expectInvalid(&.{.score("s", "x", .{ .json = &.{ .{ .string = "a" }, .null } })}, "questions.s.criteria[1]", "a score level must be a string, object or array, got null");
    try expectInvalid(&.{.score("s", "x", .{ .json = &.{ .{ .string = "a" }, .{ .raw = "null" } } })}, "questions.s.criteria[1]", "a score level must be a string, object or array, got null");
    try expectInvalid(&.{.score("s", "x", .{ .json = &.{ .{ .string = "a" }, .{ .value = .{ .integer = 1 } } } })}, "questions.s.criteria[1]", "a score level must be a string, object or array, got number");
    try expectInvalid(&.{.{ .id = "n", .spec = .{ .noul = .{} } }}, "questions.n", "a noul question needs instructions or criteria");
    try expectInvalid(&.{.noul("n", "")}, "questions.n", "a noul question needs instructions or criteria");
    try expectInvalid(&.{.{ .id = "n", .spec = .{ .noul = .{ .yes = .null, .no = .{ .string = "" } } } }}, "questions.n", "a noul question needs instructions or criteria");
    try expectInvalid(&.{.{ .id = "n", .spec = .{ .noul = .{ .instructions = .{ .raw = "42" } } } }}, "questions.n.instructions", "expected a string, object, array or null, got number");
    try expectInvalid(&.{.score("s", "x", .{ .json = &.{ .{ .string = "a" }, .{ .raw = "{" } } })}, "questions.s.criteria[1]", "raw JSON is not a single valid JSON value");
}

test "decodeResponse decodes answers in question order" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const questions = [_]Question{
        .noul("is_urgent", "Urgent?"),
        .choice("department", "Team?", .{ .names = &.{ "billing", "technical", "sales" } }),
        .score("frustration", "Frustration?", .{ .text = &.{ "Calm", "Frustrated", "Very angry" } }),
    };
    var reader: json.Reader = .init(arena.allocator(), @embedFile("testdata/responses/mixed.json"));
    defer reader.deinit();
    const decoded = try decodeResponse(arena.allocator(), &reader, &questions);

    try std.testing.expectEqualStrings("is_urgent", decoded.answers[0].id);
    try std.testing.expectEqual(0.92, decoded.answers[0].answer.noul.noul);
    const department = decoded.answers[1].answer.choice;
    try std.testing.expectEqualStrings("technical", department.choice);
    try std.testing.expectEqual(1, department.index);
    try std.testing.expectEqual(0.85, department.probability("technical").?);
    try std.testing.expectEqual(null, department.probability("legal"));
    try std.testing.expectEqual(0.77, department.margin());
    const order = try department.ranked(arena.allocator());
    try std.testing.expectEqualStrings("technical", order[0].option);
    const frustration = decoded.answers[2].answer.score;
    try std.testing.expectEqual(2, frustration.expectedLevel());
    try std.testing.expectEqual(2, frustration.maxLevel());
    try std.testing.expectEqualStrings("Calm", frustration.legend[0].string);

    const unknown = [_]Question{.choice("department", "Team?", .{ .names = &.{ "billing", "sales" } })};
    var retry: json.Reader = .init(arena.allocator(), @embedFile("testdata/responses/mixed.json"));
    defer retry.deinit();
    try std.testing.expectError(error.InvalidResponse, decodeResponse(arena.allocator(), &retry, &unknown));
    try std.testing.expectEqualStrings("answers.department.choice", retry.failure.path());
}
