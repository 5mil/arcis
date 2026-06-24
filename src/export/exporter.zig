//! exporter.zig — export entities to JSON, plain text, or TEI XML
//! Phase 7 — src/export/
//! Mirrors: src/import/importer.zig (symmetric format handling)

const std = @import("std");
const Allocator  = std.mem.Allocator;
const TextRecord = @import("../common/schema.zig").TextRecord;
const Concept    = @import("../common/schema.zig").Concept;
const Relation   = @import("../common/schema.zig").Relation;

// ---------------------------------------------------------------------------
// Export format
// ---------------------------------------------------------------------------

pub const ExportFormat = enum {
    json,
    plain_text,
    tei_xml,
};

// ---------------------------------------------------------------------------
// TextRecord exporters
// ---------------------------------------------------------------------------

/// Serialize a TextRecord to JSON. Returns owned string. Caller frees.
pub fn textToJson(allocator: Allocator, rec: TextRecord) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const w = buf.writer();
    try w.print(
        "{{{\n" ++
        "  \"id\": {d},{\n" ++
        "  \"urn\": \"{s}\",{\n" ++
        "  \"title\": \"{s}\",{\n" ++
        "  \"author\": \"{s}\",{\n" ++
        "  \"language\": \"{s}\",{\n" ++
        "  \"period\": \"{s}\",{\n" ++
        "  \"source_tradition\": \"{s}\",{\n" ++
        "  \"has_translation\": {},{\n" ++
        "  \"body_length\": {d}{\n" ++
        "}}",
        .{
            rec.id, rec.urn, rec.title, rec.author,
            rec.language, rec.period, rec.source_tradition,
            rec.has_translation, rec.body.len,
        },
    );
    return try buf.toOwnedSlice();
}

/// Serialize a TextRecord body to plain UTF-8 text. Returns owned string. Caller frees.
pub fn textToPlain(allocator: Allocator, rec: TextRecord) ![]u8 {
    return try allocator.dupe(u8, rec.body);
}

/// Wrap a TextRecord body in a minimal TEI XML envelope. Returns owned string. Caller frees.
pub fn textToTei(allocator: Allocator, rec: TextRecord) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const w = buf.writer();
    try w.print(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" ++
        "<TEI xmlns=\"http://www.tei-c.org/ns/1.0\">\n" ++
        "  <teiHeader>\n" ++
        "    <fileDesc><titleStmt><title>{s}</title>" ++
        "<author>{s}</author></titleStmt></fileDesc>\n" ++
        "  </teiHeader>\n" ++
        "  <text><body><p>{s}</p></body></text>\n" ++
        "</TEI>\n",
        .{ rec.title, rec.author, rec.body },
    );
    return try buf.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Concept exporter
// ---------------------------------------------------------------------------

/// Serialize a Concept to JSON. Returns owned string. Caller frees.
pub fn conceptToJson(allocator: Allocator, c: Concept) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const w = buf.writer();
    try w.print(
        "{{{\n" ++
        "  \"id\": {d},{\n" ++
        "  \"urn\": \"{s}\",{\n" ++
        "  \"label\": \"{s}\",{\n" ++
        "  \"definition\": \"{s}\",{\n" ++
        "  \"domain\": \"{s}\",{\n" ++
        "  \"status\": \"{s}\",{\n" ++
        "  \"modifiable\": {}{\n" ++
        "}}",
        .{
            c.id, c.urn, c.label, c.definition,
            c.domain, @tagName(c.status), c.modifiable,
        },
    );
    return try buf.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// File writer
// ---------------------------------------------------------------------------

/// Write a serialized entity to a file path.
pub fn writeToFile(path: []const u8, data: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(data);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "textToPlain round-trip" {
    const allocator = std.testing.allocator;
    const rec = TextRecord{
        .id = 1, .urn = "arcis:text:00000001", .canonical_urn = "",
        .title = "Iliad", .author = "Homer", .language = "grc",
        .period = "Archaic", .source_tradition = "Greek",
        .has_translation = false, .translation_lang = "",
        .thematic_tags = &.{}, .body = "Sing, O goddess",
        .created_at = 0, .updated_at = 0,
    };
    const out = try textToPlain(allocator, rec);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("Sing, O goddess", out);
}

test "conceptToJson contains label" {
    const allocator = std.testing.allocator;
    const schema = @import("../common/schema.zig");
    const c = Concept{
        .id = 1, .urn = "arcis:concept:00000001",
        .label = "logos", .definition = "reason", .domain = "philosophy",
        .status = schema.Status.validated, .modifiable = false,
        .source_urns = &.{}, .created_at = 0, .updated_at = 0,
    };
    const out = try conceptToJson(allocator, c);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "logos") != null);
}
