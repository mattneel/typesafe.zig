//! Questions defined at run time.
//!
//! The comptime API (`typesafe.noul`, `choice`, `score`) needs option sets
//! and level counts that are known when the program is compiled. When they
//! are not, for example a taxonomy loaded from a database or levels read from
//! a config file, build `dynamic.Question` values instead and call
//! `Client.askDynamic`. Answers are keyed by id and option name strings, and
//! the questions are validated at run time rather than at compile time.
//!
//! ```zig
//! const departments: []const []const u8 = try loadDepartments(arena);
//! const questions = [_]typesafe.dynamic.Question{
//!     .noul("is_urgent", "Does this convey urgency?"),
//!     .choice("department", "Which department should handle this?", .{ .names = departments }),
//!     .score("frustration", "How frustrated is the customer?", .{ .text = &.{ "Calm", "Frustrated", "Very angry" } }),
//! };
//! var result = try client.askDynamic(ticket_text, &questions, .{});
//! defer result.deinit();
//!
//! const department = result.get("department").?.choice;
//! std.log.info("route to {s} ({d:.2})", .{ department.choice, department.confidence });
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("json.zig");
const question = @import("question.zig");
const answer_types = @import("answer.zig");
const wire = @import("wire.zig");

/// A JSON value for instructions, descriptions, levels, criteria and extra
/// fields.
pub const Json = union(enum) {
    null,
    /// A JSON string.
    string: []const u8,
    /// Any JSON value, sent as structure.
    value: std.json.Value,
    /// Pre-encoded JSON text, validated before sending.
    raw: []const u8,

    /// The JSON type this value encodes as. `raw` text is classified by its
    /// first character; the encoder checks that it is valid.
    pub const Kind = enum { null, bool, number, string, array, object };

    /// The JSON type this value encodes as.
    pub fn kind(value: Json) Kind {
        return switch (value) {
            .null => .null,
            .string => .string,
            .value => |v| switch (v) {
                .null => .null,
                .bool => .bool,
                .integer, .float, .number_string => .number,
                .string => .string,
                .array => .array,
                .object => .object,
            },
            .raw => |text| {
                const trimmed = std.mem.trimStart(u8, text, " \t\r\n");
                if (trimmed.len == 0) return .null;
                return switch (trimmed[0]) {
                    'n' => .null,
                    't', 'f' => .bool,
                    '"' => .string,
                    '[' => .array,
                    '{' => .object,
                    else => .number,
                };
            },
        };
    }

    /// Whether the value is absent: `null`, or an empty string.
    pub fn isEmpty(value: Json) bool {
        return switch (value) {
            .null => true,
            .string => |s| s.len == 0,
            .value => |v| v == .null or (v == .string and v.string.len == 0),
            .raw => |text| blk: {
                const trimmed = std.mem.trim(u8, text, " \t\r\n");
                break :blk std.mem.eql(u8, trimmed, "null") or std.mem.eql(u8, trimmed, "\"\"");
            },
        };
    }

    /// Writes the value as JSON. The client's checking encoder uses this
    /// wherever a question takes a `Json`.
    pub fn writeTypesafeJson(value: Json, w: anytype) !void {
        switch (value) {
            .null => try w.write(null),
            .string => |s| try w.write(s),
            .value => |v| try w.write(v),
            .raw => |text| try w.write(json.RawJson{ .text = text }),
        }
    }

    /// Writes the value, so `std.json.Stringify` can encode it as well as
    /// the client's checking encoder.
    pub fn jsonStringify(value: Json, jws: *std.json.Stringify) std.json.Stringify.Error!void {
        return value.writeTypesafeJson(jws);
    }
};

/// One question and the id its answer comes back under.
pub const Question = struct {
    /// Non-empty and unique within a call. Not shown to the model.
    id: []const u8,
    spec: Spec,

    pub const Spec = union(question.Kind) {
        noul: Noul,
        choice: Choice,
        score: Score,
    };

    /// A Noul question with text instructions and no criteria.
    pub fn noul(id: []const u8, instructions: []const u8) Question {
        return .{ .id = id, .spec = .{ .noul = .{ .instructions = .{ .string = instructions } } } };
    }

    /// A Choice question with text instructions.
    pub fn choice(id: []const u8, instructions: []const u8, options: Options) Question {
        return .{ .id = id, .spec = .{ .choice = .{ .instructions = .{ .string = instructions }, .options = options } } };
    }

    /// A Score question with text instructions.
    pub fn score(id: []const u8, instructions: []const u8, levels: Levels) Question {
        return .{ .id = id, .spec = .{ .score = .{ .instructions = .{ .string = instructions }, .levels = levels } } };
    }

    /// The question type this one asks: `noul`, `choice` or `score`.
    pub fn kind(q: Question) question.Kind {
        return q.spec;
    }
};

/// A yes/no question. Needs non-empty instructions or at least one
/// non-empty criterion.
pub const Noul = struct {
    instructions: Json = .null,
    /// What a yes means, sent as the wire's `criteria.true`.
    yes: ?Json = null,
    /// What a no means, sent as the wire's `criteria.false`.
    no: ?Json = null,
};

/// A question that picks one of `options`.
pub const Choice = struct {
    instructions: Json = .null,
    options: Options,
};

/// The options of a Choice question, in the order the model reads them.
/// Names must be non-empty and unique.
pub const Options = union(enum) {
    /// Option names without descriptions.
    names: []const []const u8,
    /// Options with descriptions.
    described: []const Option,

    /// How many options there are; at least one.
    pub fn len(options: Options) usize {
        return switch (options) {
            inline else => |items| items.len,
        };
    }

    /// The option at `index`, in the order they were given.
    pub fn name(options: Options, index: usize) []const u8 {
        return switch (options) {
            .names => |names| names[index],
            .described => |described| described[index].name,
        };
    }

    /// The description of the option at `index`, or `Json.null`.
    pub fn description(options: Options, index: usize) Json {
        return switch (options) {
            .names => .null,
            .described => |described| described[index].description,
        };
    }
};

/// An option name with an optional description.
pub const Option = struct {
    name: []const u8,
    description: Json = .null,
};

/// A question that rates the state against ordered levels.
pub const Score = struct {
    instructions: Json = .null,
    levels: Levels,
};

/// The levels of a Score question: at least two, each a string, object or
/// array. A level's position is its score, starting at zero.
pub const Levels = union(enum) {
    text: []const []const u8,
    json: []const Json,

    /// How many levels there are; at least two.
    pub fn len(levels: Levels) usize {
        return switch (levels) {
            inline else => |items| items.len,
        };
    }
};

/// The answer to a dynamic question.
pub const Answer = union(question.Kind) {
    noul: answer_types.NoulAnswer,
    choice: ChoiceAnswer,
    score: ScoreAnswer,
};

/// The answer to a dynamic Choice question.
pub const ChoiceAnswer = struct {
    /// The option with the highest probability.
    choice: []const u8,
    /// The position of `choice` in the question's options.
    index: usize,
    /// The question's option names, in order.
    options: []const []const u8,
    /// One probability per option, in the same order as `options`.
    probabilities: []const f64,
    /// How certain the model is, from 0 to 1.
    confidence: f64,

    /// An option or level paired with its probability.
    pub const Ranked = struct {
        option: []const u8,
        probability: f64,
    };

    /// Returns the probability of the option named `name`, or `null` when the
    /// question has no such option.
    pub fn probability(answer: ChoiceAnswer, name: []const u8) ?f64 {
        for (answer.options, answer.probabilities) |option, p| {
            if (std.mem.eql(u8, option, name)) return p;
        }
        return null;
    }

    /// Returns every option with its probability, from most to least likely.
    /// Ties keep the question's order. Caller owns the returned slice.
    pub fn ranked(answer: ChoiceAnswer, allocator: Allocator) Allocator.Error![]Ranked {
        const result = try allocator.alloc(Ranked, answer.options.len);
        for (result, answer.options, answer.probabilities) |*entry, option, p| {
            entry.* = .{ .option = option, .probability = p };
        }
        std.sort.insertion(Ranked, result, {}, struct {
            fn moreLikely(_: void, a: Ranked, b: Ranked) bool {
                return a.probability > b.probability;
            }
        }.moreLikely);
        return result;
    }

    /// Returns the top probability minus the second, rounded to 10 decimal
    /// places, or the only probability when there is one option.
    pub fn margin(answer: ChoiceAnswer) f64 {
        if (answer.probabilities.len == 1) return answer.probabilities[0];
        var first: f64 = 0;
        var second: f64 = 0;
        for (answer.probabilities) |p| {
            if (p > first) {
                second = first;
                first = p;
            } else if (p > second) {
                second = p;
            }
        }
        return answer_types.roundMargin(first - second);
    }
};

/// The answer to a dynamic Score question.
pub const ScoreAnswer = struct {
    /// The probability-weighted level; it can land between levels.
    score: f64,
    /// The probability of each level, indexed by level.
    probabilities: []const f64,
    /// Each level as the server echoed it back.
    legend: []const std.json.Value,
    /// How certain the model is, from 0 to 1.
    confidence: f64,

    /// Returns the score rounded to the nearest level, clamped to the valid range.
    pub fn expectedLevel(answer: ScoreAnswer) usize {
        const rounded = @round(answer.score);
        if (!(rounded > 0)) return 0;
        const max: f64 = @floatFromInt(answer.probabilities.len - 1);
        if (rounded >= max) return answer.probabilities.len - 1;
        return @intFromFloat(rounded);
    }

    /// Returns the single most likely level. Ties go to the lower level.
    pub fn maxLevel(answer: ScoreAnswer) usize {
        return std.mem.findMax(f64, answer.probabilities);
    }
};

/// An answer and the id of its question.
pub const Entry = struct {
    id: []const u8,
    answer: Answer,
};

/// The result of `Client.askDynamic`. Call `deinit` to free it.
pub const Result = struct {
    /// One entry per question, in the order the questions were given.
    answers: []const Entry,
    /// The concrete model that answered.
    model: []const u8,
    usage: wire.Usage,
    /// The `x-typesafe-request-id` response header.
    request_id: ?[]const u8,
    /// Attempts made, including the first.
    attempts: u32,
    /// The response body exactly as the server sent it, for fields this
    /// version of the client does not know.
    body: []const u8,
    /// Owns every string, slice and JSON value above.
    arena: *std.heap.ArenaAllocator,

    /// Returns the answer for question `id`, or `null` when there is no such
    /// question.
    pub fn get(result: Result, id: []const u8) ?Answer {
        for (result.answers) |entry| {
            if (std.mem.eql(u8, entry.id, id)) return entry.answer;
        }
        return null;
    }

    /// Frees the arena this result owns: every answer, question id, option
    /// name and string in it.
    pub fn deinit(result: Result) void {
        const gpa = result.arena.child_allocator;
        result.arena.deinit();
        gpa.destroy(result.arena);
    }
};

test "Json.kind and isEmpty" {
    try std.testing.expectEqual(Json.Kind.null, (Json{ .raw = "  null" }).kind());
    try std.testing.expectEqual(Json.Kind.number, (Json{ .raw = "-1" }).kind());
    try std.testing.expectEqual(Json.Kind.object, (Json{ .raw = "{}" }).kind());
    try std.testing.expectEqual(Json.Kind.number, (Json{ .value = .{ .integer = 1 } }).kind());
    try std.testing.expect((Json{ .string = "" }).isEmpty());
    try std.testing.expect((Json{ .raw = " null " }).isEmpty());
    try std.testing.expect((Json{ .value = .null }).isEmpty());
    try std.testing.expect(!(Json{ .raw = "{}" }).isEmpty());
}

test "ChoiceAnswer.margin is rounded" {
    const answer: ChoiceAnswer = .{
        .choice = "a",
        .index = 0,
        .options = &.{ "a", "b" },
        .probabilities = &.{ 0.3, 0.2 },
        .confidence = 0.1,
    };
    try std.testing.expectEqual(0.1, answer.margin());
}
