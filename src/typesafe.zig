//! A Zig client for TypeSafe's System One API and its Jev model.
//!
//! Ask typed Noul, Choice and Score questions about your application's state
//! in one request, and get back a struct of answers whose types are derived
//! from your questions at compile time: a Choice answer is your enum, its
//! probabilities are one `f64` per tag, a Score answer carries a fixed-size
//! probability array.
//!
//! ```zig
//! const std = @import("std");
//! const typesafe = @import("typesafe");
//!
//! const Team = enum { billing, technical, sales };
//!
//! pub fn main(init: std.process.Init) !void {
//!     var client: typesafe.Client = try .initFromEnv(init.gpa, init.io, init.environ_map, .{});
//!     defer client.deinit();
//!
//!     const questions = .{
//!         .is_urgent = typesafe.noul("Does this convey urgency?", .{}),
//!         .department = typesafe.choice(Team, "Which team should handle this?", .{
//!             .billing = "Payments, invoicing, refunds",
//!             .technical = "Bugs, outages, integrations",
//!         }),
//!         .frustration = typesafe.score("How frustrated is the customer?", .{ "Calm", "Frustrated", "Very angry" }),
//!     };
//!
//!     var result = try client.ask("Help! My payouts have been failing for 3 days.", questions, .{});
//!     defer result.deinit();
//!
//!     const answers = result.answers;
//!     _ = answers.is_urgent.noul; // f64: 0.95
//!     _ = answers.department.choice; // Team: .billing
//!     _ = answers.department.probabilities.technical; // f64: 0.15
//!     _ = answers.frustration.probabilities[2]; // f64: 0.04
//! }
//! ```
//!
//! The client returns judgments as data. Thresholds and policy stay in your
//! code.
//!
//! This is an unofficial community client. It is not an official TypeSafe
//! SDK, and it is not affiliated with or endorsed by TypeSafe.

const std = @import("std");

const question = @import("question.zig");
const answer = @import("answer.zig");
const errors = @import("errors.zig");
const json = @import("json.zig");
const wire = @import("wire.zig");

/// This package's version, from `build.zig.zon`.
pub const version = Client.version;

/// A TypeSafe API client: configuration, a connection pool and `ask`.
pub const Client = @import("Client.zig");
/// The optional out-parameter that describes why a call failed.
pub const Diagnostics = @import("Diagnostics.zig");
/// The retry policy and its backoff arithmetic.
pub const Retry = @import("Retry.zig");

/// Every way a call can fail. See `errors.Error` for the table.
pub const Error = errors.Error;
/// Configuration mistakes reported by `Client.init` and `Client.initFromEnv`.
pub const InitError = errors.InitError;
/// Returns the error for a non-2xx HTTP status, or `null` for a 2xx status.
pub const errorFromStatus = errors.fromStatus;

/// Builds a Noul (yes/no) question.
pub const noul = question.noul;
/// Builds a Choice question over an enum's options.
pub const choice = question.choice;
/// Builds a Score question from ordered levels.
pub const score = question.score;

/// The three TypeSafe question types.
pub const Kind = question.Kind;
/// A Noul question with the given instructions and criteria types.
pub const Noul = question.Noul;
/// A Choice question over `Options`.
pub const Choice = question.Choice;
/// A Score question with `level_count` levels.
pub const Score = question.Score;
/// The answer to a Noul question: the probability of yes.
pub const NoulAnswer = answer.NoulAnswer;
/// The answer to a Choice question over `Option`.
pub const ChoiceAnswer = answer.ChoiceAnswer;
/// The answer to a Score question with `level_count` levels.
pub const ScoreAnswer = answer.ScoreAnswer;
/// The struct of typed answers for a questions struct.
pub const Answers = question.Answers;
/// Whether a type is a question built with `noul`, `choice` or `score`.
pub const isQuestion = question.isQuestion;

/// The result of `Client.ask`.
pub const Result = Client.Result;
/// The result of `Client.listModels`.
pub const Models = Client.Models;
/// A model or alias from `Client.listModels`.
pub const Model = wire.Model;
/// Token counts reported for one request.
pub const Usage = wire.Usage;

/// Pre-encoded JSON text, sent verbatim after it is validated.
pub const RawJson = json.RawJson;

/// Observability callbacks: `Hooks` and the events passed to them.
pub const hooks = @import("hooks.zig");
/// The observability callbacks and their events.
pub const Hooks = hooks.Hooks;

/// Questions defined at run time, answered with `Client.askDynamic`.
pub const dynamic = @import("dynamic.zig");

/// `MockServer`, for testing code that uses the client without network access.
pub const testing = @import("testing.zig");

test {
    std.testing.refAllDecls(@This());
    _ = question;
    _ = answer;
    _ = errors;
    _ = json;
    _ = wire;
    _ = @import("dynamic_wire.zig");
    _ = hooks;
    _ = dynamic;
    _ = testing;
    _ = Client;
    _ = Diagnostics;
    _ = Retry;
    _ = @import("client_test.zig");
    _ = @import("wire_test.zig");
    _ = @import("oom_test.zig");
}
