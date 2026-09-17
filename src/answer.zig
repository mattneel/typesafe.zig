//! The answers a question comes back with.
//!
//! Each question type names its answer as `Answer`, and `question.Answers`
//! builds a struct of them from a questions struct. The types are plain data
//! with a few helpers; nothing here allocates, and nothing points into the
//! response except a Score answer's `legend`.

const std = @import("std");

/// Rejects an option type an answer cannot be built over: anything but an
/// exhaustive enum with at least one tag.
pub fn checkOptionEnum(comptime Option: type) void {
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

/// Rejects a level count an answer cannot be built over: fewer than two.
pub fn checkLevelCount(comptime level_count: usize) void {
    if (level_count < 2) {
        @compileError(std.fmt.comptimePrint("typesafe: a score question needs at least two levels, got {d}", .{level_count}));
    }
}

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

        /// Returns the probability of `level`, the way
        /// `ChoiceAnswer.probability` takes an option. Indexing
        /// `probabilities` directly does the same and checks the index the
        /// same way.
        pub fn probability(answer: Self, level: usize) f64 {
            return answer.probabilities[level];
        }

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
    try std.testing.expectEqual(0.65, answer.probability(2));
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
