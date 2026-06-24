//! importer.zig — ingestion entry point: detect format, dispatch to format readers
//! Phase 7 — src/import/
//! Supported formats: plain text (.txt), JSON (.json), TEI XML (.xml)
//! Mirrors: src/infer/loader.zig (format detection + dispatch)

const std = @import("std");
const Allocator = std.mem.Allocator;
const TextRecord  = @import("../common/schema.zig").TextRecord;
const EntityId    = @import("../common/id.zig").EntityId;
const IdSequence  = @import("../common/id.zig").IdSequence;
const makeUrn     = @import("../common/id.zig").makeUrn;
const URN_BUF_SIZE = @import("../common/id.zig").URN_BUF_SIZE;

// ---------------------------------------------------------------------------
// Import format
// ---------------------------------------------------------------------------

pub const ImportFormat = enum {
    plain_text,
    json_record,
    tei_xml,
    auto,  // detect from file extension
};

/// Metadata hints provided by the caller at import time.
pub const ImportMeta = struct {
    title:            []const u8 = "Untitled",
    author:           []const u8 = "Unknown",
    language:         []const u8 = "und",  // ISO 639-3 undetermined
    period:           []const u8 = "",
    source_tradition: []const u8 = "",
    has_translation:  bool        = false,
    translation_lang: []const u8 = "",
    thematic_tags:    [][]const u8 = &.{},
    canonical_urn:    []const u8 = "",
};

// ---------------------------------------------------------------------------
// Importer
// ---------------------------------------------------------------------------

pub const Importer = struct {
    seq:       *IdSequence,
    allocator: Allocator,

    pub fn init(allocator: Allocator, seq: *IdSequence) Importer {
        return .{ .seq = seq, .allocator = allocator };
    }

    /// Import a file from disk. Returns an owned TextRecord. Caller frees string fields.
    pub fn importFile(
        self: *Importer,
        path: []const u8,
        meta: ImportMeta,
        format: ImportFormat,
    ) !TextRecord {
        const fmt = if (format == .auto) detectFormat(path) else format;
        const body = try readBody(self.allocator, path, fmt);
        errdefer self.allocator.free(body);
        return self.buildRecord(meta, body);
    }

    /// Import raw UTF-8 text directly (no file I/O).
    pub fn importText(
        self: *Importer,
        text: []const u8,
        meta: ImportMeta,
    ) !TextRecord {
        const body = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(body);
        return self.buildRecord(meta, body);
    }

    fn buildRecord(self: *Importer, meta: ImportMeta, body: []const u8) !TextRecord {
        const id  = self.seq.next(.text);
        var urn_buf: [URN_BUF_SIZE]u8 = undefined;
        const urn = try self.allocator.dupe(u8, makeUrn(.text, id, &urn_buf));
        const now = std.time.milliTimestamp();
        return TextRecord{
            .id               = id,
            .urn              = urn,
            .canonical_urn    = meta.canonical_urn,
            .title            = meta.title,
            .author           = meta.author,
            .language         = meta.language,
            .period           = meta.period,
            .source_tradition = meta.source_tradition,
            .has_translation  = meta.has_translation,
            .translation_lang = meta.translation_lang,
            .thematic_tags    = meta.thematic_tags,
            .body             = body,
            .created_at       = now,
            .updated_at       = now,
        };
    }
};

// ---------------------------------------------------------------------------
// Format detection
// ---------------------------------------------------------------------------

fn detectFormat(path: []const u8) ImportFormat {
    if (std.mem.endsWith(u8, path, ".xml"))  return .tei_xml;
    if (std.mem.endsWith(u8, path, ".json")) return .json_record;
    return .plain_text;
}

// ---------------------------------------------------------------------------
// Body readers
// ---------------------------------------------------------------------------

fn readBody(allocator: Allocator, path: []const u8, fmt: ImportFormat) ![]u8 {
    return switch (fmt) {
        .plain_text  => readPlainText(allocator, path),
        .json_record => readJsonBody(allocator, path),
        .tei_xml     => readTeiBody(allocator, path),
        .auto        => unreachable,
    };
}

fn readPlainText(allocator: Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    const buf  = try allocator.alloc(u8, stat.size);
    _ = try file.readAll(buf);
    return buf;
}

fn readJsonBody(allocator: Allocator, path: []const u8) ![]u8 {
    // Expect a JSON object with a "body" string field.
    const raw = try readPlainText(allocator, path);
    defer allocator.free(raw);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    const body_val = obj.get("body") orelse return error.MissingBodyField;
    return try allocator.dupe(u8, body_val.string);
}

fn readTeiBody(allocator: Allocator, path: []const u8) ![]u8 {
    // Minimal TEI: strip XML tags, return inner text.
    const raw = try readPlainText(allocator, path);
    defer allocator.free(raw);
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    var in_tag = false;
    for (raw) |ch| {
        if (ch == '<') { in_tag = true; continue; }
        if (ch == '>') { in_tag = false; continue; }
        if (!in_tag) try out.append(ch);
    }
    return try out.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "detectFormat" {
    try std.testing.expectEqual(ImportFormat.tei_xml,     detectFormat("text.xml"));
    try std.testing.expectEqual(ImportFormat.json_record, detectFormat("data.json"));
    try std.testing.expectEqual(ImportFormat.plain_text,  detectFormat("notes.txt"));
}

test "Importer.importText" {
    const allocator = std.testing.allocator;
    var seq = @import("../common/id.zig").IdSequence.init();
    var imp = Importer.init(allocator, &seq);
    const rec = try imp.importText("Hello world", .{ .title = "Test" });
    defer allocator.free(rec.body);
    defer allocator.free(rec.urn);
    try std.testing.expectEqualStrings("Hello world", rec.body);
    try std.testing.expectEqualStrings("Test", rec.title);
    try std.testing.expectEqual(@as(EntityId, 1), rec.id);
}
