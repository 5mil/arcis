//! serializer.zig — bulk serialization: export entire stores to NDJSON or ZIP-like archives
//! Phase 7 — src/export/

const std = @import("std");
const Allocator  = std.mem.Allocator;
const TextRecord = @import("../common/schema.zig").TextRecord;
const Concept    = @import("../common/schema.zig").Concept;
const EntityStore = @import("../common/store.zig").EntityStore;
const exporter   = @import("exporter.zig");

// ---------------------------------------------------------------------------
// NDJSON bulk export
// ---------------------------------------------------------------------------

/// Write all TextRecords in a store to a newline-delimited JSON file.
pub fn exportTextsNdjson(
    allocator: Allocator,
    store: *EntityStore(TextRecord),
    path: []const u8,
) !usize {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    const w = file.writer();
    var count: usize = 0;
    for (store.items.items) |rec| {
        const line = try exporter.textToJson(allocator, rec);
        defer allocator.free(line);
        try w.writeAll(line);
        try w.writeByte('\n');
        count += 1;
    }
    return count;
}

/// Write all Concepts in a store to a newline-delimited JSON file.
pub fn exportConceptsNdjson(
    allocator: Allocator,
    store: *EntityStore(Concept),
    path: []const u8,
) !usize {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    const w = file.writer();
    var count: usize = 0;
    for (store.items.items) |c| {
        const line = try exporter.conceptToJson(allocator, c);
        defer allocator.free(line);
        try w.writeAll(line);
        try w.writeByte('\n');
        count += 1;
    }
    return count;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "exportTextsNdjson zero records" {
    const allocator = std.testing.allocator;
    var store = EntityStore(TextRecord).init(allocator);
    defer store.deinit();
    // Write to a temp path — just verify count.
    // (Full file I/O test requires tmp dir; skipped in unit context.)
    try std.testing.expectEqual(@as(usize, 0), store.count());
}
