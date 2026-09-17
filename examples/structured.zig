//! Verifies fields extracted from an invoice, using JSON structure for the
//! state, the instructions and the Score levels.
//!
//!     TYPESAFE_API_KEY=... zig build run -Dexample=structured

const std = @import("std");
const typesafe = @import("typesafe");

/// Candidate values for the customer name. Tags that are not identifiers are
/// written with `@"..."`.
const Customer = enum { @"Beaver Logistics", @"Dam Logistics", @"Beaver Dam Logistics", Beaver, Dam };

const Invoice = struct {
    source_text: []const u8,
};

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout_writer.interface;
    defer out.flush() catch {};

    var client: typesafe.Client = try .initFromEnv(init.gpa, init.io, init.environ_map, .{});
    defer client.deinit();

    // The extraction step under review, for example from an OCR pipeline.
    const extracted_invoice_number = "4471";
    const invoice: Invoice = .{
        .source_text = "Invoice #4471 issued March 3, 2026 to Beaver Dam Logistics for $12,840.00, net 30.",
    };

    const questions = .{
        .invoice_number_is_correct = typesafe.noul(.{
            .field = .{ .name = "invoice_number", .type = "string", .description = "The identifier printed on the invoice." },
            .extracted_value = extracted_invoice_number,
            .question = "Does `extracted_value` match the `field` as it appears in `source_text`?",
        }, .{}),
        .customer_name = typesafe.choice(Customer, .{
            .field = .{ .name = "customer_name", .type = "string", .description = "The organization the invoice was issued to." },
            .question = "Which option is the value of `field` in `source_text`?",
        }, .{}),
        .amount_due = typesafe.score(.{
            .field = .{ .name = "amount_due", .type = "number", .unit = "USD" },
            .question = "How large is the `field` value in `source_text`?",
        }, .{ "Under $1,000", "$1,000 to $10,000", "$10,000 to $100,000", "$100,000 to $1,000,000", "Over $1,000,000" }),
        .payment_terms = typesafe.score(.{
            .field = .{ .name = "payment_terms", .type = "integer", .unit = "days" },
            .question = "How many days does the `field` in `source_text` allow for payment?",
        }, .{
            .{ .terms = "Due on receipt", .days = 0 },
            .{ .terms = "Net 10", .days = 10 },
            .{ .terms = "Net 30", .days = 30 },
            .{ .terms = "Net 60", .days = 60 },
        }),
    };

    var result = try client.ask(invoice, questions, .{});
    defer result.deinit();
    const answers = result.answers;

    try out.print("invoice number \"{s}\" is correct: {d:.2}\n", .{ extracted_invoice_number, answers.invoice_number_is_correct.noul });
    try out.print("customer: {t} (confidence {d:.2})\n", .{ answers.customer_name.choice, answers.customer_name.confidence });

    const amount_levels = @field(questions, "amount_due").levels;
    try out.print("amount due: {s}\n", .{amount_levels[answers.amount_due.maxLevel()]});

    // Levels are structured, so the legend echoes them back as JSON objects.
    const terms = answers.payment_terms.legend[answers.payment_terms.maxLevel()];
    try out.print("payment terms: {f}\n", .{std.json.fmt(terms, .{})});
}
