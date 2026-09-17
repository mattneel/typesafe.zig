# Questions

A question is a small, focused judgment about the state you send. TypeSafe has three question
types, called primitives. This guide covers how to build each one in Zig, the criteria shapes
they accept, structured JSON, extra wire fields, ids, and what is checked at compile time and at
run time. For how to write good instructions and pick a type, read TypeSafe's
[Primitives](https://docs.typesafe.ai/primitives) page first.

| Primitive | Build with | Criteria | Answer |
| --- | --- | --- | --- |
| [Noul](https://docs.typesafe.ai/primitives/noul) | `typesafe.noul(instructions, criteria)` | `.{}`, or a struct literal with `.yes` and `.no` | `NoulAnswer`: probability of yes |
| [Choice](https://docs.typesafe.ai/primitives/choice) | `typesafe.choice(Enum, instructions, descriptions)` | the enum's tags, each optionally described | `ChoiceAnswer(Enum)`: top option, probabilities, confidence |
| [Score](https://docs.typesafe.ai/primitives/score) | `typesafe.score(instructions, levels)` | a tuple or array of at least two levels | `ScoreAnswer(N)`: weighted score, probabilities, confidence |

Questions are ordinary Zig values. Their types carry the shape of each question (the options of
a Choice, the number of levels of a Score), and the type of the answers is derived from them, so
most mistakes are compile errors.

## Noul

A Noul asks a yes/no question. The answer is the probability, from 0 to 1, that the answer is
yes.

```zig
const wants_refund = typesafe.noul("Does the customer request a refund?", .{});

const is_urgent = typesafe.noul("Does this convey urgency?", .{
    .yes = "Explicitly time-sensitive",
    .no = "No urgency expressed",
});
```

The second argument is a struct literal describing what yes and no mean. `.yes` and `.no` are
sent as the wire's `true` and `false` keys, and either can be left out. Pass `.{}` for no
criteria, and the request carries no `criteria` object at all.

Instructions can be `null` when at least one criterion says what is being asked, as in
`typesafe.noul(null, .{ .yes = .{ .asks_for = "refund" } })`. A Noul needs one or the other:
`null` instructions with no criteria, or only `null` ones, is a compile error. Values that turn
out empty at run time, such as empty strings or `null` optionals for the instructions and every
criterion, fail the call with `error.InvalidRequest` at `questions.<id>`.

## Choice

A Choice picks one option from a set you define as a Zig enum. The answer's `choice` is a value
of that enum, and its `probabilities` is a struct with one `f64` field per tag.

```zig
const Team = enum { billing, technical, sales, other };

const department = typesafe.choice(Team, "Which team should handle this?", .{
    .billing = "Payments, invoicing, refunds",
    .technical = "Bugs, outages, integrations",
    .sales = "Pricing, upgrades, new accounts",
});
```

The third argument maps some or all tags to a description. Options left out, such as `other`
above, are sent with a `null` description. Pass `.{}` when the option names say enough.

When the options might not cover every input, add an `other` option, as the TypeSafe docs
recommend. Otherwise the probability of an input that fits nowhere has to land on an option that
does not fit.

Options are sent as the enum's tag names. Names that are not Zig identifiers use `@"..."` tags,
and the answer comes back as the same tag:

```zig
const Department = enum { @"Sporting Goods", @"Home & Kitchen", @"Baby & Toddler" };

const product_department = typesafe.choice(Department, "Which top-level department does this product belong to?", .{
    .@"Sporting Goods" = .{ .Cycling = .{ "Bike Bottles & Cages", "Bike Lights", "Helmets" } },
    .@"Home & Kitchen" = .{ .Drinkware = .{ "Water Bottles", "Travel Mugs", "Tumblers" } },
});
```

### Option order

Options are sent in enum declaration order, whatever order the descriptions struct uses. That
order is part of what the model reads, and it can move probabilities by a few points. With the
same text, the same instructions and the same three options, the order alone changed the answer
from `billing: 0.95` (billing listed first) to `billing: 0.97` (technical listed first). The
choice was the same in both cases, but a threshold near those values would not have been.

Keep an enum's order stable between calls whose answers you compare.

## Score

A Score rates the state against ordered levels you define. The answer has a probability-weighted
score, a probability for every level, and a confidence.

```zig
const frustration = typesafe.score("How frustrated is the customer?", .{ "Calm", "Frustrated", "Very angry" });
```

Levels are a tuple or an array whose length is known at compile time, such as
`[_][]const u8{ "None", "Low", "High" }`. A level's position is its value, starting at 0, so the
score above runs from 0 to 2 and can land between levels, such as `1.05`. The answer type is
`ScoreAnswer(3)`, and its `probabilities` is a `[3]f64` indexed by level.
When every level is a string, the question stores them as `[N][]const u8`, so
`frustration.levels[answer.maxLevel()]` is the text of the most likely level. The answer's
`legend` holds each level as the server echoed it back, as a `std.json.Value`.

Each level is a string or a JSON object or array. Passing a string where the levels belong, as in
`typesafe.score("How urgent is this?", "Low")`, is a compile error, and so is a boolean or number
level. A level that is `null` fails the call with `error.InvalidRequest` and the message
`score level 1 must not be null` (for the second level) at `questions.<id>.criteria`.

## Structured JSON

State, instructions, Choice descriptions, Score levels and Noul criteria all accept JSON
structure. Structure is sent as JSON objects and arrays, never as strings. See
[State](https://docs.typesafe.ai/concepts/state) and
[Advanced: structure](https://docs.typesafe.ai/primitives/advanced) in the TypeSafe docs.

| Zig value | Sent as |
| --- | --- |
| string (`[]const u8`, string literal) | string |
| integer, float, `bool` | number, boolean |
| optional | its payload, or `null` |
| enum value, enum literal | the tag name as a string |
| struct literal, your own struct | object |
| tuple, array, slice | array |
| tagged union | an object with one key, the active tag |
| `std.json.Value` | as the value describes |
| `typesafe.RawJson{ .text = ... }` | the text verbatim, after validation |

Numbers and booleans can appear anywhere inside structure, but instructions, Choice descriptions,
Noul criteria and Score levels themselves must be a string, an object, an array or `null`
(levels cannot be `null`). A Zig `bool`, integer or float in one of those places is a compile
error.

A structured state keeps related records together under descriptive names. Instructions can
point at one part of it with a path in backticks, as the TypeSafe docs describe:

```zig
const Resolution = enum { refund, investigate, reply_only };

const questions = .{
    .refund_requested = typesafe.noul("Does `ticket.messages[0].text` request a refund?", .{}),
    .resolution = typesafe.choice(Resolution, .{
        .task = "Pick the resolution for this ticket",
        .constraints = .{"Follow `refund_policy`"},
    }, .{
        .refund = .{ .action = "Refund the duplicate charge", .requires = .{ "a duplicate charge", "the policy allows it" } },
        .investigate = .{ .action = "Send to the payments team" },
    }),
    .effort = typesafe.score("How much agent effort does this ticket need?", .{
        .{ .level = "none", .example = "An automated reply" },
        .{ .level = "low", .example = "One action in the admin panel" },
        .{ .level = "high", .example = "An investigation across systems" },
    }),
};

const state = .{
    .ticket = .{ .messages = .{.{ .from = "customer", .text = "I was charged twice for order A-104. Please refund one." }} },
    .order = .{ .id = "A-104", .charges = .{ .{ .amount = 49.0 }, .{ .amount = 49.0 } } },
    .refund_policy = "Duplicate charges are eligible for a refund.",
};

var result = try client.ask(state, questions, .{});
defer result.deinit();

// Structured levels come back as JSON objects.
const effort = result.answers.effort;
const level = effort.legend[effort.maxLevel()].object.get("level").?.string;
```

Your own structs work the same way, so a state can be `.{ .order = order, .history = history }`
where `order` is a struct of yours and `history` is a `std.json.Value` or a
`typesafe.RawJson{ .text = history_json }` holding JSON you already have.

### Runtime values

Only the shape of the questions must be known at compile time: the ids, the enum of a Choice,
the number of Score levels, and the field names of structured values. The values themselves can
come from run time. Build the questions struct inside the function that has them:

```zig
fn invoiceNumberIsCorrect(client: *typesafe.Client, invoice: Invoice, extracted: []const u8) !f64 {
    const questions = .{
        .invoice_number_is_correct = typesafe.noul(.{
            .field = .{ .name = "invoice_number", .description = "The identifier printed on the invoice." },
            .extracted_value = extracted,
            .question = "Does `extracted_value` match the `field` as it appears in `source_text`?",
        }, .{}),
    };
    var result = try client.ask(invoice, questions, .{});
    defer result.deinit();
    return result.answers.invoice_number_is_correct.noul;
}
```

When the shape itself comes from data, use [dynamic questions](#questions-defined-at-run-time).

## Question ids

The field names of the questions struct are the question ids, and `result.answers` has the same
field names. Ids are for your code and are not shown to the model, so write the whole question
in the instructions. Ids that are not Zig identifiers use `@"..."`, such as `.@"is-urgent"`.

`typesafe.Answers(@TypeOf(questions))` names the answers type, so decision logic can take it as a
parameter:

```zig
const ticket_questions = .{
    .is_urgent = typesafe.noul("Does this convey urgency?", .{}),
    .department = typesafe.choice(Team, "Which team should handle this?", .{}),
};

const TicketAnswers = typesafe.Answers(@TypeOf(ticket_questions));

// answers.is_urgent is a NoulAnswer, and answers.department a ChoiceAnswer(Team).
fn isUrgentBilling(answers: TicketAnswers) bool {
    return answers.is_urgent.isYes(0.8) and answers.department.choice == .billing;
}
```

Questions are sent in field order. Answers are independent of each other, so the order does not
change the results. A misspelled id, such as `result.answers.is_urgnet`, is a compile error.

The answers struct holds numbers and enums, so you can copy it out of the result and keep it
after `deinit`. The exception is a Score answer's `legend`, which points into the result's arena
along with `model`, `request_id` and `raw`.

## What is checked at compile time

These mistakes stop the build with a `typesafe:` compile error:

- The questions argument is not a struct literal with named fields. A tuple such as
  `.{ typesafe.noul("Is this spam?", .{}) }` is rejected.
- The questions struct is empty: "at least one question is required".
- A field is not built with `noul`, `choice` or `score`.
- A Choice's options are not an enum, the enum is non-exhaustive, or it has no tags.
- A Choice's descriptions are not a struct literal, or name a tag the enum does not have, such
  as `.legal` for `Team`.
- A Noul's criteria are not a struct literal or have a field other than `.yes` and `.no`, or a
  Noul has `null` instructions and no criteria, or only `null` ones: "a noul question needs
  instructions or criteria".
- A Score's levels are not a tuple or array whose length is known at compile time, such as a
  slice, or are a single string such as `"Low"`.
- A Score has fewer than two levels: "a score question needs at least two levels, got 1".
- Instructions, a Choice description, a Noul criterion or a Score level is a `bool`, an integer
  or a float, directly, through an optional such as `??bool`, or behind a pointer such as
  `*bool`: "noul instructions must be a string, a JSON object or array, or null, got bool".

The encoder also rejects, at compile time, values that have no JSON form: an untagged union, a
many-item pointer without a sentinel, or a type such as a function.

The helpers raise `@setEvalBranchQuota` for you, so question sets of a few dozen questions and
Scores with dozens of levels compile as they are. An unusually large set, such as many questions
over a 64-tag enum, can still reach the comptime branch limit; the compiler then says so and
names `@setEvalBranchQuota` for you to raise.

## What is checked at run time

Before anything is sent, the client encodes the request with a strict encoder. A value that
would produce invalid or misleading JSON fails the call with `error.InvalidRequest`, no request
is made, and a `Diagnostics` passed in the call options names the offending path:

- a string or object key that is not valid UTF-8;
- a float that is NaN or infinite;
- a `std.json.Value` `number_string` that is not a JSON number;
- `RawJson` text that is not exactly one valid JSON value;
- nesting deeper than 256 levels, including inside `RawJson` text;
- a selection from a non-exhaustive enum whose value has no name of its own, which would be sent
  as a number;
- a `jsonStringify` method on your own type whose error is not `error.WriteFailed` (a
  `WriteFailed`, the only error such a method can raise, arrives as `error.OutOfMemory`);
- a state that is not a JSON string, object or array, such as a number or `null`;
- a Noul whose instructions and criteria are all empty strings or `null`, at `questions.<id>`;
- a Score level that is `null`, at `questions.<id>.criteria`.

```zig
var diagnostics: typesafe.Diagnostics = .init(gpa);
defer diagnostics.deinit();

var result = client.ask(.{ .ticket = .{ .text = text } }, questions, .{ .diagnostics = &diagnostics }) catch |err| {
    std.log.err("{f}", .{diagnostics});
    return err;
};
defer result.deinit();
```

```text
InvalidRequest: string is not valid UTF-8 at state.ticket.text [POST https://api.typesafe.ai/v1/systemone]
```

Paths start at the request body, such as `state.ticket.text` or
`questions.department.instructions`.

The checks cover every value the encoder walks, including a `std.json.Value` and its
`std.json.ObjectMap` and `std.json.Array`, and `typesafe.RawJson`. The one exception is any other
type with a `jsonStringify` method, such as one of your own: the client hands it to that method
and writes whatever it produces, without these checks. To have such a type checked, give it a
`writeTypesafeJson` method that writes through the writer it is passed. The client calls it with
its checking encoder, and a `jsonStringify` that calls it keeps the type working with `std.json`,
as the question types do:

```zig
const Ticket = struct {
    subject: []const u8,
    body: []const u8,

    pub fn writeTypesafeJson(ticket: Ticket, w: anytype) !void {
        try w.beginObject();
        try w.objectField("subject");
        try w.write(ticket.subject);
        try w.objectField("body");
        try w.write(ticket.body);
        try w.endObject();
    }

    pub fn jsonStringify(ticket: Ticket, jws: *std.json.Stringify) std.json.Stringify.Error!void {
        return ticket.writeTypesafeJson(jws);
    }
};
```

The writer offers `beginObject`, `endObject`, `beginArray`, `endArray`, `objectField` and `write`.
A body that is not valid UTF-8 in `.{ .ticket = ticket }` then fails at `state.ticket.body`.
Question types also expose `writeFields`, which writes their members without the enclosing
object.

The API validates too. A request the client accepts but the API rejects, such as an unknown
model, fails with `error.BadRequest` or `error.Unprocessable`, and the diagnostics carry the
server's message.

## Decoding and forward compatibility

Decoding is strict about what your code relies on:

- every question you asked has an answer, with the matching `type`;
- a Choice's `choice` is one of your enum's tags, and there is a probability for every tag;
- a Score has a probability and a legend entry for every level;
- probabilities and confidence are numbers from 0 to 1, and `score` is a finite number.

A response that breaks one of these fails with `error.InvalidResponse`. The diagnostics give the
path and the problem, such as `answers.department.choice` and
`"legal" is not an option of the question`.

Everything else is ignored: answers you did not ask for (including answers of a type this
version does not know), and fields it does not know at any level. A missing `usage` or token
count comes back as `null`. A newer server never breaks an older client, and `result.body` keeps
the response as the server sent it, so you can read a new field before the client exposes it. A
key repeated in one object keeps its last value.

## Questions defined at run time

The typed API needs the options and level counts when the program is compiled. When they come
from a database or a config file, build `typesafe.dynamic.Question` values and call
`askDynamic`:

```zig
const dynamic = typesafe.dynamic;

const questions = [_]dynamic.Question{
    .noul("is_urgent", "Does this convey urgency?"),
    .choice("department", "Which department should handle this?", .{ .names = department_names }),
    .score("frustration", "How frustrated is the customer?", .{ .text = &.{ "Calm", "Frustrated", "Very angry" } }),
};

var result = try client.askDynamic(ticket_text, &questions, .{});
defer result.deinit();

const department = result.get("department").?.choice;
std.log.info("{s} ({d:.2})", .{ department.choice, department.confidence });
```

For equivalent questions, the request is the same JSON the typed API sends. What you give up is
the types: answers are looked up by id with `result.get`, a Choice's `choice` is a `[]const u8`,
`probability(name)` returns `?f64`, and `ranked` takes an allocator. The checks move to run time
too. These fail with `error.InvalidRequest` before anything is sent, and the diagnostics name the
question:

- no questions, or an empty or duplicate id;
- a Choice with no options, or an empty or duplicate option name;
- a Score with fewer than two levels, or a level that is not a string, object or array;
- a Noul with no instructions or criteria, where an empty string counts as missing;
- instructions, a description or a criterion that is a boolean or a number;
- an extra field with an empty, duplicate or reserved name (`type`, `instructions`, `criteria`).

Structured values take a `dynamic.Json` (`.null`, `.string`, `.value` or `.raw`). `kind()`
returns the JSON type a value encodes as (a `.raw` value is classified by its first character and
validated when encoded), and `isEmpty()` is `true` for `null` and an empty string. The
constructors take text instructions, so for Noul criteria or structured instructions, fill in the
`Question` fields yourself. `extra` takes the extra wire fields, each a
`dynamic.Question.Field` with a `name` and a `Json` `value`:

```zig
const questions = [_]dynamic.Question{
    .{
        .id = "is_spam",
        .spec = .{ .noul = .{ .instructions = .{ .string = "Is this spam?" } } },
        .extra = &.{.{ .name = "future_field", .value = .{ .raw = "true" } }},
    },
};
```

See `examples/dynamic.zig`.
