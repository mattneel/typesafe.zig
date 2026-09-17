//! Questions and answers with types derived at compile time.
//!
//! A question is built with `noul`, `choice` or `score` and placed in an
//! anonymous struct whose field names are the question ids:
//!
//! ```zig
//! const Team = enum { billing, technical, sales };
//!
//! const questions = .{
//!     .is_urgent = typesafe.noul("Does this convey urgency?", .{}),
//!     .department = typesafe.choice(Team, "Which team should handle this?", .{
//!         .billing = "Payments, invoicing, refunds",
//!     }),
//!     .frustration = typesafe.score("How frustrated is the customer?", .{ "Calm", "Frustrated", "Very angry" }),
//! };
//! ```
//!
//! `Answers(@TypeOf(questions))` is then a struct with the same field names:
//! `answers.is_urgent` is a `NoulAnswer`, `answers.department` a
//! `ChoiceAnswer(Team)` whose `choice` is a `Team`, and `answers.frustration`
//! a `ScoreAnswer(3)` with a `[3]f64` of probabilities. A misspelled question
//! id, an unknown option or a missing level is a compile error.
//!
//! Every instructions value, option description, level and Noul criterion
//! accepts JSON structure: a string, or any value `std.json` can write, such
//! as an anonymous struct literal, a tuple, a `std.json.Value` or a
//! `typesafe.RawJson`. Structure is sent as JSON, never stringified. See
//! https://docs.typesafe.ai/primitives/advanced.

const std = @import("std");
const json = @import("json.zig");

/// The three TypeSafe question types.
pub const Kind = enum {
    noul,
    choice,
    score,
};

/// The answer to a Noul (yes/no) question: the probability, from 0 to 1, that
/// the answer is yes.
///
/// The value is a calibrated probability, not a verdict. Your code picks the
/// threshold, and can treat the middle of the range as "not sure" and route
/// it elsewhere. See https://docs.typesafe.ai/confidence.
pub const NoulAnswer = struct {
    noul: f64,

    /// Returns `true` when the probability of yes is at least `threshold`.
    pub fn isYes(answer: NoulAnswer, threshold: f64) bool {
        return answer.noul >= threshold;
    }

    test isYes {
        const answer: NoulAnswer = .{ .noul = 0.92 };
        try std.testing.expect(answer.isYes(0.5));
        try std.testing.expect(!answer.isYes(0.95));
    }
};

/// The answer to a Choice question over the enum `Option`.
pub fn ChoiceAnswer(comptime Option: type) type {
    comptime checkOptionEnum(Option);
    const option_values = std.enums.values(Option);

    return struct {
        /// The option with the highest probability.
        choice: Option,
        /// One probability per option; they sum to about 1.
        probabilities: Probabilities,
        /// How certain the model is, from 0 to 1, derived from the distribution.
        confidence: f64,

        const Self = @This();

        /// A struct with one `f64` field per option, named after the enum tags.
        pub const Probabilities = std.enums.EnumFieldStruct(Option, f64, null);

        /// An option paired with its probability.
        pub const Ranked = struct {
            option: Option,
            probability: f64,
        };

        /// Returns the probability of `option`.
        pub fn probability(answer: Self, option: Option) f64 {
            return switch (option) {
                inline else => |tag| @field(answer.probabilities, @tagName(tag)),
            };
        }

        /// Returns every option with its probability, from most to least
        /// likely. Ties keep the enum declaration order.
        pub fn ranked(answer: Self) [option_values.len]Ranked {
            var result: [option_values.len]Ranked = undefined;
            for (option_values, &result) |option, *entry| {
                entry.* = .{ .option = option, .probability = answer.probability(option) };
            }
            std.sort.insertion(Ranked, &result, {}, moreLikely);
            return result;
        }

        /// Returns the top probability minus the second, rounded to 10
        /// decimal places so that, for example, 0.3 minus 0.2 is exactly 0.1.
        /// A small margin means the model saw two options as nearly equally
        /// likely. With a single option, the margin is that option's
        /// probability.
        pub fn margin(answer: Self) f64 {
            const order = answer.ranked();
            if (order.len == 1) return order[0].probability;
            return roundMargin(order[0].probability - order[1].probability);
        }

        fn moreLikely(_: void, a: Ranked, b: Ranked) bool {
            return a.probability > b.probability;
        }
    };
}

/// Rounds a probability difference to 10 decimal places, removing the
/// floating-point noise of subtracting two-decimal probabilities.
pub fn roundMargin(difference: f64) f64 {
    return @round(difference * 1e10) / 1e10;
}

test roundMargin {
    try std.testing.expectEqual(0.1, roundMargin(0.3 - 0.2));
    try std.testing.expectEqual(0.2, roundMargin(0.6 - 0.4));
    try std.testing.expectEqual(0.77, roundMargin(0.85 - 0.08));
}

/// The answer to a Score question with `level_count` levels.
pub fn ScoreAnswer(comptime level_count: usize) type {
    comptime checkLevelCount(level_count);

    return struct {
        /// The probability-weighted level. It can land between levels, such
        /// as `1.6`.
        score: f64,
        /// The probability of each level, indexed by level; they sum to about 1.
        probabilities: [level_count]f64,
        /// How certain the model is, from 0 to 1, derived from the distribution.
        confidence: f64,
        /// Each level as the server echoed it back: the JSON of the level you
        /// defined. Decoding always fills it; it defaults to nulls so test
        /// code can build an answer without it.
        legend: [level_count]std.json.Value = @splat(.null),

        const Self = @This();

        /// A level paired with its probability.
        pub const Ranked = struct {
            level: usize,
            probability: f64,
        };

        /// Returns the score rounded to the nearest level, clamped to the
        /// valid range.
        pub fn expectedLevel(answer: Self) usize {
            const rounded = @round(answer.score);
            if (!(rounded > 0)) return 0;
            const max: f64 = @floatFromInt(level_count - 1);
            if (rounded >= max) return level_count - 1;
            return @intFromFloat(rounded);
        }

        /// Returns the single most likely level. Ties go to the lower level.
        pub fn maxLevel(answer: Self) usize {
            return std.mem.findMax(f64, &answer.probabilities);
        }

        /// Returns every level with its probability, from most to least
        /// likely. Ties go to the lower level.
        pub fn ranked(answer: Self) [level_count]Ranked {
            var result: [level_count]Ranked = undefined;
            for (answer.probabilities, &result, 0..) |p, *entry, level| {
                entry.* = .{ .level = level, .probability = p };
            }
            std.sort.insertion(Ranked, &result, {}, moreLikely);
            return result;
        }

        fn moreLikely(_: void, a: Ranked, b: Ranked) bool {
            return a.probability > b.probability;
        }
    };
}

/// A Noul (yes/no) question. Build one with `noul`.
pub fn Noul(comptime Instructions: type, comptime Criteria: type) type {
    comptime checkNoulCriteria(Instructions, Criteria);

    return struct {
        instructions: Instructions,
        criteria: Criteria,

        /// This question's wire type.
        pub const kind: Kind = .noul;
        /// The answer the API returns for this question.
        pub const Answer = NoulAnswer;

        /// Writes the question's wire JSON to a `std.json.Stringify` or the
        /// client's validating encoder.
        pub fn writeTypesafeJson(question: @This(), w: anytype) !void {
            try w.beginObject();
            try question.writeFields(w);
            try w.endObject();
        }

        /// Writes the question's members without the enclosing object.
        pub fn writeFields(question: @This(), w: anytype) !void {
            if (@TypeOf(w) == *json.Encoder) {
                const no_yes = !@hasField(Criteria, "yes") or isEmptyEntry(question.criteria.yes);
                const no_no = !@hasField(Criteria, "no") or isEmptyEntry(question.criteria.no);
                if (isEmptyEntry(question.instructions) and no_yes and no_no) {
                    return w.fail("a noul question needs instructions or criteria", .{});
                }
            }
            const checked = @TypeOf(w) == *json.Encoder;
            try w.objectField("type");
            try w.write("noul");
            try w.objectField("instructions");
            if (checked) try checkRuntimeEntry(w, question.instructions, "noul instructions", true);
            try w.write(question.instructions);
            if (@typeInfo(Criteria).@"struct".fields.len > 0) {
                try w.objectField("criteria");
                try w.beginObject();
                if (@hasField(Criteria, "yes")) {
                    try w.objectField("true");
                    if (checked) try checkRuntimeEntry(w, question.criteria.yes, "a noul criterion", true);
                    try w.write(question.criteria.yes);
                }
                if (@hasField(Criteria, "no")) {
                    try w.objectField("false");
                    if (checked) try checkRuntimeEntry(w, question.criteria.no, "a noul criterion", true);
                    try w.write(question.criteria.no);
                }
                try w.endObject();
            }
        }

        /// Writes the question's wire JSON, so `std.json.Stringify` can
        /// encode it directly as well as through the client.
        pub fn jsonStringify(question: @This(), jws: *std.json.Stringify) std.json.Stringify.Error!void {
            return question.writeTypesafeJson(jws);
        }
    };
}

/// A Choice question over the options of the enum `Option`. Build one with
/// `choice`.
pub fn Choice(comptime Option: type, comptime Instructions: type, comptime Descriptions: type) type {
    comptime checkOptionEnum(Option);
    comptime checkEntry(Instructions, "choice instructions");
    comptime checkDescriptions(Option, Descriptions);

    return struct {
        instructions: Instructions,
        descriptions: Descriptions,

        /// This question's wire type.
        pub const kind: Kind = .choice;
        /// The answer the API returns for this question.
        pub const Answer = ChoiceAnswer(Option);

        /// Writes the question's wire JSON. Options are written in enum
        /// declaration order; an option without a description is `null`.
        pub fn writeTypesafeJson(question: @This(), w: anytype) !void {
            try w.beginObject();
            try question.writeFields(w);
            try w.endObject();
        }

        /// Writes the question's members without the enclosing object.
        pub fn writeFields(question: @This(), w: anytype) !void {
            const option_fields = @typeInfo(Option).@"enum".fields;
            @setEvalBranchQuota(eval_branch_quota_base + 8 * option_fields.len);
            const checked = @TypeOf(w) == *json.Encoder;
            try w.objectField("type");
            try w.write("choice");
            try w.objectField("instructions");
            if (checked) try checkRuntimeEntry(w, question.instructions, "choice instructions", true);
            try w.write(question.instructions);
            try w.objectField("criteria");
            try w.beginObject();
            inline for (option_fields) |field| {
                try w.objectField(field.name);
                if (@hasField(Descriptions, field.name)) {
                    const description = @field(question.descriptions, field.name);
                    if (checked) try checkRuntimeEntry(w, description, "a choice description", true);
                    try w.write(description);
                } else {
                    try w.write(null);
                }
            }
            try w.endObject();
        }

        /// Writes the question's wire JSON, so `std.json.Stringify` can
        /// encode it directly as well as through the client.
        pub fn jsonStringify(question: @This(), jws: *std.json.Stringify) std.json.Stringify.Error!void {
            return question.writeTypesafeJson(jws);
        }
    };
}

/// A Score question with `level_count` ordered levels. Build one with `score`.
pub fn Score(comptime level_count: usize, comptime Instructions: type, comptime Levels: type) type {
    comptime checkLevelCount(level_count);
    comptime checkEntry(Instructions, "score instructions");
    comptime checkLevels(Levels);

    return struct {
        instructions: Instructions,
        levels: Levels,

        /// This question's wire type.
        pub const kind: Kind = .score;
        /// The answer the API returns for this question.
        pub const Answer = ScoreAnswer(level_count);

        /// Writes the question's wire JSON. Levels are written in order; a
        /// level's position is its score, starting at zero.
        pub fn writeTypesafeJson(question: @This(), w: anytype) !void {
            try w.beginObject();
            try question.writeFields(w);
            try w.endObject();
        }

        /// Writes the question's members without the enclosing object.
        pub fn writeFields(question: @This(), w: anytype) !void {
            // Each level's check and stored type are charged against the
            // caller's comptime branch budget, so a Score with many levels
            // needs the margin its own enumeration does not cover.
            @setEvalBranchQuota(eval_branch_quota_base + 512 * level_count);
            const checked = @TypeOf(w) == *json.Encoder;
            try w.objectField("type");
            try w.write("score");
            try w.objectField("instructions");
            if (checked) try checkRuntimeEntry(w, question.instructions, "score instructions", true);
            try w.write(question.instructions);
            try w.objectField("criteria");
            if (checked) {
                inline for (0..level_count) |level| {
                    const entry = question.levels[level];
                    if (isNullEntry(entry)) return w.fail("score level {d} must not be null", .{level});
                    try checkRuntimeEntry(w, entry, std.fmt.comptimePrint("score level {d}", .{level}), false);
                }
            }
            try w.write(question.levels);
        }

        /// Writes the question's wire JSON, so `std.json.Stringify` can
        /// encode it directly as well as through the client.
        pub fn jsonStringify(question: @This(), jws: *std.json.Stringify) std.json.Stringify.Error!void {
            return question.writeTypesafeJson(jws);
        }
    };
}

/// A question with additional wire fields. Build one with `withExtra`.
pub fn WithExtra(comptime Question: type, comptime Extra: type) type {
    comptime checkExtra(Question, Extra);

    return struct {
        question: Question,
        extra: Extra,

        /// The wire type of the question this one extends.
        pub const kind: Kind = Question.kind;
        /// The answer the API returns for this question.
        pub const Answer = Question.Answer;
        /// The question type this one extends.
        pub const Base = Question;

        /// Writes the question's members and then the extra fields, without
        /// the enclosing object.
        pub fn writeTypesafeJson(extended: @This(), w: anytype) !void {
            try w.beginObject();
            try extended.writeFields(w);
            try w.endObject();
        }

        /// Writes the question's members, then the extra fields, without the
        /// enclosing object.
        pub fn writeFields(extended: @This(), w: anytype) !void {
            try extended.question.writeFields(w);
            inline for (@typeInfo(Extra).@"struct".fields) |field| {
                try w.objectField(field.name);
                try w.write(@field(extended.extra, field.name));
            }
        }

        /// Writes the question and its extra fields, so `std.json.Stringify`
        /// can encode it directly as well as through the client.
        pub fn jsonStringify(extended: @This(), jws: *std.json.Stringify) std.json.Stringify.Error!void {
            return extended.writeTypesafeJson(jws);
        }
    };
}

/// Builds a Noul (yes/no) question.
///
/// `instructions` is a string or any JSON-encodable value. `criteria`
/// describes what a yes and a no mean, as a struct literal with optional
/// `yes` and `no` fields (sent as the wire's `true` and `false` keys); pass
/// `.{}` for none. A Noul needs instructions or at least one criterion: with
/// neither, it is a compile error, or `error.InvalidRequest` when the values
/// are only known to be empty at run time.
///
/// ```zig
/// const plain = typesafe.noul("Is this spam?", .{});
/// const described = typesafe.noul("Does this convey urgency?", .{
///     .yes = "Explicitly time-sensitive",
///     .no = "No urgency expressed",
/// });
/// ```
///
/// See https://docs.typesafe.ai/primitives/noul.
pub fn noul(instructions: anytype, criteria: anytype) Noul(Stored(@TypeOf(instructions)), StoredStruct(@TypeOf(criteria))) {
    return .{
        .instructions = instructions,
        .criteria = storeStruct(criteria),
    };
}

/// Builds a Choice question over the options of the enum `Option`.
///
/// Options are sent as the enum's tag names in declaration order, and the
/// answer's `choice` is an `Option`. Use `@"..."` tags for option names that
/// are not identifiers, such as `@"Home & Kitchen"`. Option order is part of
/// what the model reads.
///
/// `descriptions` is a struct literal mapping some or all option names to a
/// description (a string or any JSON-encodable value); options left out are
/// sent with a `null` description. Pass `.{}` when the option names say
/// enough. A name that is not an option is a compile error.
///
/// ```zig
/// const Team = enum { billing, technical, sales };
/// const q = typesafe.choice(Team, "Which team should handle this?", .{
///     .billing = "Payments, invoicing, refunds",
///     .technical = "Bugs, outages, integrations",
/// });
/// ```
///
/// See https://docs.typesafe.ai/primitives/choice.
pub fn choice(
    comptime Option: type,
    instructions: anytype,
    descriptions: anytype,
) Choice(Option, Stored(@TypeOf(instructions)), StoredStruct(@TypeOf(descriptions))) {
    return .{
        .instructions = instructions,
        .descriptions = storeStruct(descriptions),
    };
}

/// Builds a Score question from ordered levels.
///
/// `levels` is a tuple or array with at least two elements, known in length
/// at compile time: `.{ "Calm", "Frustrated", "Very angry" }`. Each level is a
/// string or a JSON object or array (such as a struct literal), and its
/// position is its score, starting at zero. The answer's probabilities are a
/// `[levels.len]f64`.
///
/// See https://docs.typesafe.ai/primitives/score.
pub fn score(
    instructions: anytype,
    levels: anytype,
) Score(levelCount(@TypeOf(levels)), Stored(@TypeOf(instructions)), StoredLevels(@TypeOf(levels))) {
    return .{
        .instructions = instructions,
        .levels = storeLevels(StoredLevels(@TypeOf(levels)), levels),
    };
}

/// Adds wire fields to a question, for API features newer than this client.
///
/// `extra` is a struct literal whose fields are written after the question's
/// own members. The names `type`, `instructions` and `criteria` are compile
/// errors, as is calling `withExtra` on a question that already has extras.
///
/// ```zig
/// const q = typesafe.withExtra(typesafe.noul("Is this spam?", .{}), .{ .future_field = true });
/// ```
pub fn withExtra(question: anytype, extra: anytype) WithExtra(@TypeOf(question), StoredStruct(@TypeOf(extra))) {
    return .{ .question = question, .extra = storeStruct(extra) };
}

/// Returns `true` when `T` is a question type: it declares `kind` and
/// `Answer`, as the types built by `noul`, `choice`, `score` and `withExtra`
/// do.
pub fn isQuestion(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and
        @hasDecl(T, "kind") and @TypeOf(T.kind) == Kind and
        @hasDecl(T, "Answer") and @TypeOf(T.Answer) == type;
}

/// Returns the levels of a Score question, looking through `withExtra`.
pub fn scoreLevels(question: anytype) @TypeOf(baseQuestion(question).levels) {
    return baseQuestion(question).levels;
}

fn baseQuestion(question: anytype) BaseQuestion(@TypeOf(question)) {
    if (@hasDecl(@TypeOf(question), "Base")) return baseQuestion(question.question);
    return question;
}

fn BaseQuestion(comptime T: type) type {
    return if (@hasDecl(T, "Base")) BaseQuestion(T.Base) else T;
}

/// The struct of typed answers for a questions struct: the same field names,
/// each holding the answer type of its question.
///
/// `Questions` must be a struct (usually an anonymous struct literal's type)
/// with at least one field, and every field must be a question built with
/// `noul`, `choice` or `score`.
pub fn Answers(comptime Questions: type) type {
    const fields = comptime checkQuestions(Questions);
    @setEvalBranchQuota(eval_branch_quota_base + 8 * fields.len);
    var names: [fields.len][]const u8 = undefined;
    var types: [fields.len]type = undefined;
    for (fields, 0..) |field, i| {
        names[i] = field.name;
        types[i] = field.type.Answer;
    }
    return @Struct(.auto, null, &names, &types, &@splat(.{}));
}

/// The comptime branch budget helpers start from before adding a margin per
/// field, so large enums and question sets compile without the caller raising
/// `@setEvalBranchQuota`.
const eval_branch_quota_base = 1000;

fn checkQuestions(comptime Questions: type) []const std.builtin.Type.StructField {
    const fields = literalFields(Questions) orelse {
        @compileError("typesafe: questions must be a struct literal such as " ++
            ".{ .is_urgent = typesafe.noul(\"Does this convey urgency?\", .{}) }, got " ++ @typeName(Questions));
    };
    if (fields.len == 0) {
        @compileError("typesafe: at least one question is required");
    }
    @setEvalBranchQuota(eval_branch_quota_base + 8 * fields.len);
    for (fields) |field| {
        if (!isQuestion(field.type)) {
            @compileError("typesafe: question '" ++ field.name ++ "' has type " ++ @typeName(field.type) ++
                ", which is not a TypeSafe question; build it with typesafe.noul, typesafe.choice or typesafe.score");
        }
    }
    return fields;
}

fn checkOptionEnum(comptime Option: type) void {
    const info = @typeInfo(Option);
    if (info != .@"enum") {
        @compileError("typesafe: choice options must be an enum, got " ++ @typeName(Option));
    }
    if (!info.@"enum".is_exhaustive) {
        @compileError("typesafe: choice options must be an exhaustive enum, got " ++ @typeName(Option));
    }
    if (info.@"enum".fields.len == 0) {
        @compileError("typesafe: choice options enum " ++ @typeName(Option) ++ " needs at least one tag");
    }
}

/// The fields of a struct literal type. The empty literal `.{}` has an empty
/// tuple type, which counts as a struct with no fields. Returns `null` for
/// any other type.
fn literalFields(comptime T: type) ?[]const std.builtin.Type.StructField {
    const info = @typeInfo(T);
    if (info != .@"struct") return null;
    if (info.@"struct".is_tuple and info.@"struct".fields.len > 0) return null;
    return info.@"struct".fields;
}

fn checkDescriptions(comptime Option: type, comptime Descriptions: type) void {
    const fields = literalFields(Descriptions) orelse {
        @compileError("typesafe: choice descriptions must be a struct literal such as .{ .billing = \"Payments\" }, got " ++
            @typeName(Descriptions));
    };
    @setEvalBranchQuota(eval_branch_quota_base + 16 * (fields.len + @typeInfo(Option).@"enum".fields.len));
    for (fields) |field| {
        if (!@hasField(Option, field.name)) {
            @compileError("typesafe: choice description '" ++ field.name ++ "' is not an option of " ++ @typeName(Option));
        }
        checkEntry(field.type, "choice description '" ++ field.name ++ "'");
    }
}

fn checkNoulCriteria(comptime Instructions: type, comptime Criteria: type) void {
    const fields = literalFields(Criteria) orelse {
        @compileError("typesafe: noul criteria must be a struct literal with optional .yes and .no fields, got " ++
            @typeName(Criteria));
    };
    checkEntry(Instructions, "noul instructions");
    var has_criterion = false;
    for (fields) |field| {
        if (!std.mem.eql(u8, field.name, "yes") and !std.mem.eql(u8, field.name, "no")) {
            @compileError("typesafe: noul criteria field '" ++ field.name ++
                "' is not allowed; use .yes and .no (sent as the wire's true and false)");
        }
        checkEntry(field.type, "noul criterion '" ++ field.name ++ "'");
        if (field.type != Stored(@TypeOf(null))) has_criterion = true;
    }
    if (Instructions == Stored(@TypeOf(null)) and !has_criterion) {
        @compileError("typesafe: a noul question needs instructions or criteria");
    }
}

fn checkLevelCount(comptime level_count: usize) void {
    if (level_count < 2) {
        @compileError(std.fmt.comptimePrint("typesafe: a score question needs at least two levels, got {d}", .{level_count}));
    }
}

/// Rejects entry types the API never accepts: booleans and numbers. Strings,
/// objects, arrays and null are fine.
fn checkEntry(comptime T: type, comptime what: []const u8) void {
    @setEvalBranchQuota(1 << 16);
    if (T == Stored(@TypeOf(null))) return;
    // An entry reaches the wire as the value inside its optionals and
    // single-item pointers, so `??bool`, `*bool` and `*u8` are as invalid as
    // `bool` and `u8`. Pointers to arrays, slices and structs stay as they are.
    var Payload = T;
    while (true) {
        const info = @typeInfo(Payload);
        if (info == .optional) {
            Payload = info.optional.child;
        } else if (info == .pointer and info.pointer.size == .one and @typeInfo(info.pointer.child) != .array) {
            Payload = info.pointer.child;
        } else break;
    }
    const expected = if (std.mem.eql(u8, what, "a score level"))
        " must be a string or a JSON object or array, got "
    else
        " must be a string, a JSON object or array, or null, got ";
    switch (@typeInfo(Payload)) {
        .bool, .int, .float, .comptime_int, .comptime_float => @compileError("typesafe: " ++ what ++ expected ++ @typeName(T)),
        else => {},
    }
}

fn checkLevels(comptime Levels: type) void {
    const Element = switch (@typeInfo(Levels)) {
        .array => |array| array.child,
        .@"struct" => |info| {
            for (info.fields) |field| checkLevel(field.type);
            return;
        },
        else => unreachable,
    };
    checkLevel(Element);
}

fn checkLevel(comptime T: type) void {
    if (T == Stored(@TypeOf(null)) or T == @TypeOf(null)) {
        @compileError("typesafe: a score level must not be null");
    }
    checkEntry(T, "a score level");
}

fn checkExtra(comptime Question: type, comptime Extra: type) void {
    if (!isQuestion(Question) or !std.meta.hasFn(Question, "writeFields")) {
        @compileError("typesafe: withExtra needs a question built with typesafe.noul, typesafe.choice or typesafe.score, got " ++
            @typeName(Question));
    }
    if (@hasDecl(Question, "Base")) {
        @compileError("typesafe: the question already has extra fields; pass every extra field to one withExtra call");
    }
    const fields = literalFields(Extra) orelse {
        @compileError("typesafe: extra fields must be a struct literal such as .{ .future_field = true }, got " ++ @typeName(Extra));
    };
    for (fields) |field| {
        for ([_][]const u8{ "type", "instructions", "criteria" }) |reserved| {
            if (std.mem.eql(u8, field.name, reserved)) {
                @compileError("typesafe: extra field '" ++ field.name ++ "' would overwrite the question's own member");
            }
        }
    }
}

fn levelCount(comptime Levels: type) usize {
    const len, const Element = switch (@typeInfo(Levels)) {
        .@"struct" => |info| if (info.is_tuple) return info.fields.len else .{ 0, void },
        .array => |info| .{ info.len, info.child },
        .pointer => |info| if (info.size == .one and @typeInfo(info.child) == .array)
            .{ @typeInfo(info.child).array.len, @typeInfo(info.child).array.child }
        else
            .{ 0, void },
        else => .{ 0, void },
    };
    if (Element == u8) {
        @compileError("typesafe: score levels must be a tuple or array of levels, such as .{ \"Low\", \"High\" }, " ++
            "got the string " ++ @typeName(Levels));
    }
    if (Element == void) {
        @compileError("typesafe: score levels must be a tuple or array whose length is known at compile time, " ++
            "such as .{ \"Low\", \"High\" }, got " ++ @typeName(Levels));
    }
    return len;
}

/// Checks an entry whose JSON type is only known at run time: a
/// `std.json.Value` or `json.RawJson`, possibly optional. Other types were
/// checked at compile time. Booleans and numbers are never accepted; `null`
/// only when `allow_null`.
fn checkRuntimeEntry(w: *json.Encoder, value: anytype, comptime what: []const u8, allow_null: bool) error{InvalidRequest}!void {
    const T = @TypeOf(value);
    const kind: []const u8 = if (T == std.json.Value) switch (value) {
        .null => "null",
        .bool => "a boolean",
        .integer, .float, .number_string => "a number",
        .string, .array, .object => return,
    } else if (T == json.RawJson) raw: {
        const trimmed = std.mem.trimStart(u8, value.text, " \t\r\n");
        if (trimmed.len == 0) return; // the encoder rejects it as invalid JSON
        break :raw switch (trimmed[0]) {
            '"', '[', '{' => return,
            'n' => "null",
            't', 'f' => "a boolean",
            else => "a number",
        };
    } else switch (@typeInfo(T)) {
        // A non-exhaustive enum value with no tag of its own encodes as a
        // number, which an entry never accepts.
        .@"enum" => |info| if (!info.is_exhaustive and std.enums.tagName(T, value) == null) "a number" else return,
        .optional => return if (value) |payload| checkRuntimeEntry(w, payload, what, allow_null) else {},
        else => return,
    };
    if (allow_null and std.mem.eql(u8, kind, "null")) return;
    return w.fail("{s} must be a string, object{s}, got {s}", .{
        what,
        if (allow_null) ", array or null" else " or array",
        kind,
    });
}

/// Whether an entry value is absent: `null`, an empty string, or a
/// `std.json.Value` holding either.
fn isEmptyEntry(value: anytype) bool {
    const T = @TypeOf(value);
    if (T == std.json.Value) return value == .null or (value == .string and value.string.len == 0);
    return switch (@typeInfo(T)) {
        .null => true,
        .optional => if (value) |payload| isEmptyEntry(payload) else true,
        .pointer => |ptr| if (isStringPointer(ptr)) @as([]const u8, value).len == 0 else false,
        else => false,
    };
}

/// Whether an entry value is `null`, directly or as a `std.json.Value`.
fn isNullEntry(value: anytype) bool {
    const T = @TypeOf(value);
    if (T == std.json.Value) return value == .null;
    return switch (@typeInfo(T)) {
        .null => true,
        .optional => if (value) |payload| isNullEntry(payload) else true,
        else => false,
    };
}

/// The type a question stores for a value of type `T`: strings become
/// `[]const u8`, so question types stay small and nameable.
fn Stored(comptime T: type) type {
    return switch (@typeInfo(T)) {
        // A bare `null` literal has a comptime-only type; an always-null
        // optional encodes the same way.
        .null => ?u0,
        .pointer => |ptr| if (isStringPointer(ptr)) []const u8 else T,
        else => T,
    };
}

fn isStringPointer(comptime ptr: std.builtin.Type.Pointer) bool {
    return switch (ptr.size) {
        .slice => ptr.child == u8,
        .one => switch (@typeInfo(ptr.child)) {
            .array => |array| array.child == u8,
            else => false,
        },
        else => false,
    };
}

/// A struct literal's type with each field's type passed through `Stored`.
fn StoredStruct(comptime T: type) type {
    const info = @typeInfo(T);
    if (info != .@"struct" or info.@"struct".is_tuple) return T;
    const fields = info.@"struct".fields;
    @setEvalBranchQuota(eval_branch_quota_base + 8 * fields.len);
    var names: [fields.len][]const u8 = undefined;
    var types: [fields.len]type = undefined;
    for (fields, 0..) |field, i| {
        names[i] = field.name;
        types[i] = Stored(field.type);
    }
    return @Struct(.auto, null, &names, &types, &@splat(.{}));
}

fn storeStruct(value: anytype) StoredStruct(@TypeOf(value)) {
    const T = @TypeOf(value);
    const Result = StoredStruct(T);
    if (Result == T) return value;
    var result: Result = undefined;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        @field(result, field.name) = @field(value, field.name);
    }
    return result;
}

/// Levels whose elements are all strings are stored as `[N][]const u8`;
/// anything else is stored as given.
fn StoredLevels(comptime Levels: type) type {
    const n = levelCount(Levels);
    const Element = switch (@typeInfo(Levels)) {
        .@"struct" => |info| blk: {
            for (info.fields) |field| {
                if (Stored(field.type) != []const u8) return Levels;
            }
            break :blk []const u8;
        },
        .array => |info| info.child,
        .pointer => |info| @typeInfo(info.child).array.child,
        else => unreachable,
    };
    if (Stored(Element) == []const u8) return [n][]const u8;
    return switch (@typeInfo(Levels)) {
        .pointer => |info| info.child,
        else => Levels,
    };
}

fn storeLevels(comptime Result: type, levels: anytype) Result {
    const T = @TypeOf(levels);
    if (Result == T) return levels;
    switch (@typeInfo(T)) {
        .pointer => if (Result == @typeInfo(T).pointer.child) return levels.*,
        else => {},
    }
    var result: Result = undefined;
    inline for (0..comptime levelCount(T)) |i| result[i] = levels[i];
    return result;
}

test "noul encodes like the API reference" {
    const gpa = std.testing.allocator;
    const plain = noul("Does this convey urgency?", .{});
    const plain_json = try std.json.Stringify.valueAlloc(gpa, plain, .{});
    defer gpa.free(plain_json);
    try std.testing.expectEqualStrings(
        \\{"type":"noul","instructions":"Does this convey urgency?"}
    , plain_json);

    const described = noul("Does this convey urgency?", .{
        .yes = "Explicitly time-sensitive",
        .no = "No urgency expressed",
    });
    const described_json = try std.json.Stringify.valueAlloc(gpa, described, .{});
    defer gpa.free(described_json);
    try std.testing.expectEqualStrings(
        \\{"type":"noul","instructions":"Does this convey urgency?","criteria":{"true":"Explicitly time-sensitive","false":"No urgency expressed"}}
    , described_json);

    const only_criteria = noul(null, .{ .yes = .{ .asks_for = "refund" }, .no = null });
    const only_json = try std.json.Stringify.valueAlloc(gpa, only_criteria, .{});
    defer gpa.free(only_json);
    try std.testing.expectEqualStrings(
        \\{"type":"noul","instructions":null,"criteria":{"true":{"asks_for":"refund"},"false":null}}
    , only_json);
}

test "choice encodes every option in declaration order" {
    const gpa = std.testing.allocator;
    const Team = enum { billing, technical, sales };
    const q = choice(Team, "Which team should handle this?", .{
        .technical = "Bugs, outages, integrations",
        .billing = "Payments, invoicing, refunds",
    });
    try std.testing.expect(@TypeOf(q.instructions) == []const u8);
    const out = try std.json.Stringify.valueAlloc(gpa, q, .{});
    defer gpa.free(out);
    try std.testing.expectEqualStrings(
        \\{"type":"choice","instructions":"Which team should handle this?","criteria":{"billing":"Payments, invoicing, refunds","technical":"Bugs, outages, integrations","sales":null}}
    , out);
}

test "choice option names that are not identifiers" {
    const gpa = std.testing.allocator;
    const Department = enum { @"Sporting Goods", @"Home & Kitchen" };
    const q = choice(Department, "Which department?", .{
        .@"Sporting Goods" = .{ .Cycling = .{ "Bike Bottles & Cages", "Helmets" } },
    });
    const out = try std.json.Stringify.valueAlloc(gpa, q, .{});
    defer gpa.free(out);
    try std.testing.expectEqualStrings(
        \\{"type":"choice","instructions":"Which department?","criteria":{"Sporting Goods":{"Cycling":["Bike Bottles & Cages","Helmets"]},"Home & Kitchen":null}}
    , out);
}

test "score encodes levels as an array and normalizes string levels" {
    const gpa = std.testing.allocator;
    const q = score("How frustrated is the customer?", .{ "Calm", "Frustrated", "Very angry" });
    try std.testing.expect(@TypeOf(q.levels) == [3][]const u8);
    try std.testing.expect(@TypeOf(q).Answer == ScoreAnswer(3));
    const out = try std.json.Stringify.valueAlloc(gpa, q, .{});
    defer gpa.free(out);
    try std.testing.expectEqualStrings(
        \\{"type":"score","instructions":"How frustrated is the customer?","criteria":["Calm","Frustrated","Very angry"]}
    , out);

    const runtime_levels = [_][]const u8{ "Low", "High" };
    const from_array = score("Urgency?", runtime_levels);
    try std.testing.expect(@TypeOf(from_array.levels) == [2][]const u8);
    const from_pointer = score("Urgency?", &runtime_levels);
    try std.testing.expectEqualStrings("High", from_pointer.levels[1]);

    const structured = score(.{ "Rate", "severity" }, .{ .{ .level = "low" }, .{"medium"}, "high" });
    const structured_json = try std.json.Stringify.valueAlloc(gpa, structured, .{});
    defer gpa.free(structured_json);
    try std.testing.expectEqualStrings(
        \\{"type":"score","instructions":["Rate","severity"],"criteria":[{"level":"low"},["medium"],"high"]}
    , structured_json);
}

test "answers mirror question ids and types" {
    const Team = enum { billing, technical, sales };
    const questions = .{
        .is_urgent = noul("Does this convey urgency?", .{}),
        .department = choice(Team, "Which team?", .{}),
        .frustration = score("How frustrated?", .{ "Calm", "Frustrated", "Very angry" }),
    };
    const A = Answers(@TypeOf(questions));
    try std.testing.expect(@FieldType(A, "is_urgent") == NoulAnswer);
    try std.testing.expect(@FieldType(A, "department") == ChoiceAnswer(Team));
    try std.testing.expect(@FieldType(A, "frustration") == ScoreAnswer(3));
    try std.testing.expect(isQuestion(@TypeOf(questions.department)));
    try std.testing.expect(!isQuestion(Team));
}

test "question values can be built at run time" {
    const gpa = std.testing.allocator;
    var buffer: [32]u8 = undefined;
    const instructions = try std.fmt.bufPrint(&buffer, "Is ticket {d} urgent?", .{42});
    const q = noul(instructions, .{ .yes = instructions });
    const out = try std.json.Stringify.valueAlloc(gpa, q, .{});
    defer gpa.free(out);
    try std.testing.expectEqualStrings(
        \\{"type":"noul","instructions":"Is ticket 42 urgent?","criteria":{"true":"Is ticket 42 urgent?"}}
    , out);
}

test "choice answer helpers" {
    const Tone = enum { calm, angry, sad };
    const answer: ChoiceAnswer(Tone) = .{
        .choice = .angry,
        .probabilities = .{ .calm = 0.08, .angry = 0.85, .sad = 0.07 },
        .confidence = 0.82,
    };
    try std.testing.expectEqual(0.85, answer.probability(.angry));
    const order = answer.ranked();
    try std.testing.expectEqual(Tone.angry, order[0].option);
    try std.testing.expectEqual(Tone.calm, order[1].option);
    try std.testing.expectEqual(Tone.sad, order[2].option);
    try std.testing.expectApproxEqAbs(0.77, answer.margin(), 1e-12);

    const Single = enum { only };
    const single: ChoiceAnswer(Single) = .{ .choice = .only, .probabilities = .{ .only = 1 }, .confidence = 1 };
    try std.testing.expectEqual(1, single.margin());

    const tied: ChoiceAnswer(Tone) = .{
        .choice = .calm,
        .probabilities = .{ .calm = 0.4, .angry = 0.2, .sad = 0.4 },
        .confidence = 0.1,
    };
    const tied_order = tied.ranked();
    try std.testing.expectEqual(Tone.calm, tied_order[0].option);
    try std.testing.expectEqual(Tone.sad, tied_order[1].option);
}

test "score answer helpers" {
    const answer: ScoreAnswer(3) = .{
        .score = 1.6,
        .probabilities = .{ 0.05, 0.3, 0.65 },
        .confidence = 0.78,
    };
    try std.testing.expectEqual(2, answer.expectedLevel());
    try std.testing.expectEqual(2, answer.maxLevel());
    const order = answer.ranked();
    try std.testing.expectEqual(2, order[0].level);
    try std.testing.expectEqual(1, order[1].level);
    try std.testing.expectEqual(0, order[2].level);

    const low: ScoreAnswer(3) = .{ .score = -0.4, .probabilities = .{ 0.5, 0.5, 0 }, .confidence = 0 };
    try std.testing.expectEqual(0, low.expectedLevel());
    try std.testing.expectEqual(0, low.maxLevel());
    const high: ScoreAnswer(3) = .{ .score = 7, .probabilities = .{ 0, 0, 1 }, .confidence = 1 };
    try std.testing.expectEqual(2, high.expectedLevel());
}
