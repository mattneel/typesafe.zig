# Confidence

TypeSafe answers are probabilities, not verdicts. The client hands them to you unchanged, and
your code decides what is certain enough to act on. This guide covers how to read probabilities
and confidence, where thresholds belong, and how to route uncertain cases. The concepts come
from TypeSafe's [Confidence](https://docs.typesafe.ai/confidence) page and the
[Confidence-gated routing](https://docs.typesafe.ai/patterns/confidence-routing) pattern.

## Probability and confidence

Each answer type carries a different signal:

- A **Noul** answer is one probability: `noul` is how likely the answer is yes. A value near 1 is
  a strong yes, near 0 a strong no, and near 0.5 means the model gives yes and no about equal
  weight. `NoulAnswer` has no separate confidence.
- A **Choice** answer has `probabilities`, one `f64` field per enum tag, and `choice` is the most
  likely tag.
- A **Score** answer has `probabilities`, one `f64` per level, and `score` is the
  probability-weighted position along the levels.

`ChoiceAnswer` and `ScoreAnswer` also carry `confidence`, a number from 0 to 1 that TypeSafe
derives from the shape of the distribution. A distribution concentrated on one outcome gives
high confidence, and a flat one gives low confidence. TypeSafe does not publish the exact
formula, and this client does not recompute or adjust it. If a different measure suits your
problem better, compute it from `probabilities`, which are always included.

Confidence is not the top probability. These are real answers to a department question like the
one in the [README](../../README.md) (billing, technical or sales) for three messages:

| Message | Probabilities | `confidence` | `margin()` |
| --- | --- | --- | --- |
| "Help! My payouts have been failing for 3 days." | billing 0.87, technical 0.13, sales 0.0 | 0.81 | 0.74 |
| "I want to talk to someone about my invoice and the API limits on our plan." | billing 0.89, sales 0.1, technical 0.01 | 0.82 | 0.79 |
| "Hello?" | technical 0.67, sales 0.33, billing 0.0 | 0.5 | 0.34 |

"Hello?" has no department, and its top option still has a probability of 0.67. Acting on
`choice` alone would send it to the technical team. The confidence of 0.5 and the margin of 0.34
show that the model is not sure.

## Thresholds belong in your code

The client has no thresholds, so nothing is decided behind your back. Put thresholds next to the
actions they gate, and scale them with the cost of a mistake. A wrong read-only action is cheap,
while a wrong refund or deletion is not:

```zig
const std = @import("std");
const typesafe = @import("typesafe");

pub const Intent = enum { refund, order_status, how_to, other };

pub const questions = .{
    .intent = typesafe.choice(Intent, "What does the customer want?", .{
        .refund = "Money returned for a charge",
        .order_status = "Where an order is or when it arrives",
        .how_to = "Help using the product",
    }),
    .is_urgent = typesafe.noul("Does this convey urgency?", .{}),
};

pub const Answers = typesafe.Answers(@TypeOf(questions));

pub const Priority = enum { high, normal };

pub const Decision = union(enum) {
    automate: struct { intent: Intent, priority: Priority },
    confirm_with_customer: struct { intent: Intent, priority: Priority },
    human_review: struct { priority: Priority, ranked: [std.meta.fields(Intent).len]typesafe.ChoiceAnswer(Intent).Ranked },
};

// Below these, a person decides.
const min_confidence = 0.6;
const min_margin = 0.2;

// Refunds move money, so they need more certainty to run without confirmation.
const refund_confidence = 0.85;

pub fn route(client: *typesafe.Client, text: []const u8) typesafe.Error!Decision {
    var result = try client.ask(text, questions, .{});
    defer result.deinit();
    return decide(result.answers);
}

pub fn decide(answers: Answers) Decision {
    const intent = answers.intent;
    const priority: Priority = if (answers.is_urgent.isYes(0.8)) .high else .normal;

    if (intent.confidence < min_confidence or intent.margin() < min_margin or intent.choice == .other) {
        return .{ .human_review = .{ .priority = priority, .ranked = intent.ranked() } };
    }
    if (intent.choice == .refund and intent.confidence < refund_confidence) {
        return .{ .confirm_with_customer = .{ .intent = .refund, .priority = priority } };
    }
    return .{ .automate = .{ .intent = intent.choice, .priority = priority } };
}
```

`decide` is a pure function of the answers struct, so you can test every branch without a
server (see [Testing](testing.md)).

Start with conservative thresholds, then adjust them against your own data. The TypeSafe docs
are explicit that correct values depend on your domain and on how the model performs for your
use case.

## Reading Choice answers

`ranked()` returns every option with its probability, from most to least likely, as a
fixed-size array of `Ranked` structs with `option` and `probability` fields. Ties keep the enum's
declaration order. `margin()` returns the top probability minus the second, rounded to 10
decimal places so that floating-point noise does not tip a threshold (0.3 minus 0.2 is exactly
0.1), and `probability(tag)` reads one option:

```zig
for (answer.ranked()) |entry| {
    std.debug.print("{t}: {d:.2}\n", .{ entry.option, entry.probability });
}
std.debug.print("margin: {d:.2}\n", .{answer.margin()});
```

```text
technical: 0.67
sales: 0.33
billing: 0.00
margin: 0.34
```

The margin tells you whether the model is split between two specific options. That can matter
more than overall confidence. A ticket split between `billing` and `sales` can go to either team
with a note, while a ticket split between `refund` and `order_status` needs a person. The ranked
array is also a useful payload for a review queue, because it shows the reviewer what the model
considered. It holds only enums and numbers, so it outlives the result.

## Reading Noul answers

A Noul has no confidence field. The probability is the whole signal, so use two thresholds and
treat the middle as "not sure". `isYes(threshold)` returns `true` when `noul` is at least the
threshold:

```zig
const Urgency = enum { urgent, unsure, not_urgent };

fn urgency(answer: typesafe.NoulAnswer) Urgency {
    if (answer.isYes(0.8)) return .urgent;
    if (answer.isYes(0.2)) return .unsure;
    return .not_urgent;
}
```

Asked "Does this convey urgency?", "Help! My payouts have been failing for 3 days." scored `0.95`
(`.urgent`) and "Hello?" scored `0.06` (`.not_urgent`). "Your docs say webhooks retry, but we
were billed for the failed calls." scored `0.71`, which lands in `.unsure`. That message is a
reasonable one to hand to a person or a slower check. A single threshold at 0.5 would have
labelled it urgent with no sign of doubt.

As the TypeSafe docs warn, a Noul of 0.5 means yes and no are equally likely. It does not mean
"somewhat". If you want a degree, such as how urgent or how skilled, ask a Score with defined
levels.

## Reading Score answers

`score` is a weighted average, so it can hide a split. Compare it with the distribution. Consider
an answer like this one for levels Calm, Frustrated and Very angry:

```zig
const answer: typesafe.ScoreAnswer(3) = .{
    .score = 1.0,
    .probabilities = .{ 0.45, 0.1, 0.45 },
    .confidence = 0.3,
};

_ = answer.expectedLevel(); // 1: "Frustrated"
_ = answer.maxLevel(); //      0: "Calm"
_ = answer.ranked(); //        level 0 (0.45), level 2 (0.45), level 1 (0.1)
```

The score rounds to "Frustrated", the least likely level. `expectedLevel()` rounds the score to
the nearest level, clamped to the valid range. `maxLevel()` returns the single most likely
level, and ties go to the lower level. When the two disagree, or confidence is low, the levels
are probably ambiguous for this input, or the state does not contain enough to decide.

The helpers return level indexes. For string levels, index the question's `levels`, such as
`questions.frustration.levels[answer.maxLevel()]`. A decoded answer also has `legend`, each level
as the server echoed it back.

For a clear answer the helpers agree. The frustration answer for "Help! My payouts have been
failing for 3 days." was `score` 1.05 with probabilities 0.0, 0.95 and 0.05, and a confidence of
0.93. Both helpers return 1, "Frustrated".

When you threshold a Score, a threshold on `score` itself (for example, escalate above `1.5`)
works well once confidence is high enough to trust the position.

## Routing uncertain cases

Low confidence is useful output. It is the model saying "I don't know", and your code can send
those cases somewhere better equipped:

- **A person.** Put the case in a review queue with the ranked probabilities attached.
- **A slower model.** Send only the uncertain cases to a reasoning model or a larger pipeline.
  Most cases take the fast, cheap path, and the hard ones get more attention.
- **The user.** Ask a confirming question, as the refund branch above does.
- **More context.** Fetch more state, such as order history, and ask again.

With the router above in `router.zig`, the caller acts on each kind of decision:

```zig
const router = @import("router.zig");

fn process(client: *typesafe.Client, ticket: Ticket) void {
    const decision = router.route(client, ticket.body) catch |err| {
        // A failed call is an uncertain case too.
        return review_queue.pushFailed(ticket, err, client.retry.isRetryable(err));
    };
    switch (decision) {
        .automate => |d| support.handle(ticket, d.intent, d.priority),
        .confirm_with_customer => |d| support.askToConfirm(ticket, d.intent),
        .human_review => |d| review_queue.push(ticket, d.priority, d.ranked),
    }
}
```

Once the client's retries are spent, sending the ticket to a person is often better than
dropping it. `client.retry.isRetryable(err)` tells you whether the error is transient, so that
trying again later could help. It classifies HTTP status errors by the default retryable
statuses; a policy with a custom `isRetryableStatus` decides by status, which
`client.retry.retriesStatus(status)` applies.

## Calibrating with your own data

Thresholds are guesses until you check them. Record enough with each decision to review it
later:

- the probabilities and confidence (or `ranked()`) for each answer that drove the decision;
- `result.model`, the concrete model version such as `jev-1.13.0`, because answers can shift
  between versions;
- `result.request_id`, for support questions;
- what happened next: whether a reviewer agreed, or whether the automated action was reversed.

For example, `route` from above can log each decision with what drove it:

```zig
pub fn route(client: *typesafe.Client, text: []const u8) typesafe.Error!Decision {
    var result = try client.ask(text, questions, .{});
    defer result.deinit();

    const decision = decide(result.answers);
    const intent = result.answers.intent;
    std.log.info("decision={t} intent={t} confidence={d:.2} margin={d:.2} model={s} request_id={s}", .{
        decision,
        intent.choice,
        intent.confidence,
        intent.margin(),
        result.model,
        result.request_id orelse "-",
    });
    return decision;
}
```

`result.model` and `result.request_id` live in the result's arena, so copy them before `deinit`
if you store them rather than log them.

With a few hundred reviewed cases, you can see how often each confidence band was right and move
the thresholds to match your risk tolerance. The [Observability guide](observability.md) shows
how to pass your own ids to hooks through `user_data`, so decisions and calls can be joined.
