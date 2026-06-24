//! basic_session.zig — minimal example: init ArcisSession, ingest text, propose term, generate name
//! Phase 12 — examples/
//! Run: zig run examples/basic_session.zig

const std = @import("std");
const ArcisSession = @import("../src/dashboard/arcis_session.zig").ArcisSession;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Arcis Basic Session Example ===\n\n", .{});

    var session = try ArcisSession.init(allocator, "visio");
    defer session.deinit();
    std.debug.print("Session init: tier=visio\n", .{});

    // 1. Ingest a text into the library.
    const text_id = try session.catalog.ingest(
        "The unexamined life is not worth living.",
        .{
            .title          = "Apology",
            .author         = "Socrates",
            .language       = "grc",
            .period         = "Classical",
            .source_tradition = "Greek",
            .thematic_tags  = @constCast(&[_][]const u8{ "philosophy", "ethics" }),
        },
    );
    std.debug.print("Ingested text id={d}\n", .{text_id});

    // 2. Propose and validate a terminology concept.
    const concept_id = try session.terms.propose("eudaimonia", "flourishing / happiness", "ethics");
    _ = session.terms.validate(concept_id);
    std.debug.print("Concept validated id={d} label=eudaimonia\n", .{concept_id});

    // 3. Generate a wizard name.
    const name_id = try session.names.generateAndStore(.wizard, .greek, .sage, 42);
    const name_val = session.names.names.items[0].value;
    std.debug.print("Generated name id={d} value={s}\n", .{ name_id, name_val });

    // 4. Search the keyword index.
    try session.search.keyword.indexDocument(text_id, "The unexamined life is not worth living.");
    var results = std.ArrayList(u64).init(allocator);
    defer results.deinit();
    try session.search.keyword.search("life", &results);
    std.debug.print("Keyword search 'life': {d} result(s)\n", .{results.items.len});

    std.debug.print("\nDone.\n", .{});
}
