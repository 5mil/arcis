//! catalog.zig — ancient text library catalog: ingest, tag, cross-link to ontology
//! Phase 8 — src/library/
//! Depends on: src/common/schema.zig, store.zig, src/import/importer.zig

const std = @import("std");
const Allocator  = std.mem.Allocator;
const TextRecord = @import("../common/schema.zig").TextRecord;
const Concept    = @import("../common/schema.zig").Concept;
const EntityStore = @import("../common/store.zig").EntityStore;
const EntityId   = @import("../common/id.zig").EntityId;
const IdSequence = @import("../common/id.zig").IdSequence;
const Importer   = @import("../import/importer.zig").Importer;
const ImportMeta = @import("../import/importer.zig").ImportMeta;

// ---------------------------------------------------------------------------
// TextIndex — inverted tag index for fast thematic lookup
// ---------------------------------------------------------------------------

/// Maps tag string → list of TextRecord IDs.
pub const TagIndex = struct {
    map:       std.StringHashMap(std.ArrayList(EntityId)),
    allocator: Allocator,

    pub fn init(allocator: Allocator) TagIndex {
        return .{ .map = std.StringHashMap(std.ArrayList(EntityId)).init(allocator), .allocator = allocator };
    }

    pub fn deinit(self: *TagIndex) void {
        var it = self.map.valueIterator();
        while (it.next()) |v| v.deinit();
        self.map.deinit();
    }

    pub fn index(self: *TagIndex, tag: []const u8, id: EntityId) !void {
        const gop = try self.map.getOrPut(tag);
        if (!gop.found_existing) {
            gop.value_ptr.* = std.ArrayList(EntityId).init(self.allocator);
        }
        try gop.value_ptr.append(id);
    }

    pub fn lookup(self: *TagIndex, tag: []const u8) []const EntityId {
        const list = self.map.get(tag) orelse return &.{};
        return list.items;
    }
};

// ---------------------------------------------------------------------------
// Catalog
// ---------------------------------------------------------------------------

pub const Catalog = struct {
    texts:     EntityStore(TextRecord),
    tag_index: TagIndex,
    importer:  Importer,
    allocator: Allocator,

    pub fn init(allocator: Allocator, seq: *IdSequence) Catalog {
        return .{
            .texts     = EntityStore(TextRecord).init(allocator),
            .tag_index = TagIndex.init(allocator),
            .importer  = Importer.init(allocator, seq),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Catalog) void {
        self.texts.deinit();
        self.tag_index.deinit();
    }

    /// Ingest raw text with metadata. Returns assigned EntityId.
    pub fn ingest(self: *Catalog, text: []const u8, meta: ImportMeta) !EntityId {
        const rec = try self.importer.importText(text, meta);
        const id  = rec.id;
        try self.texts.put(rec);
        // Index all thematic tags.
        for (meta.thematic_tags) |tag| {
            try self.tag_index.index(tag, id);
        }
        return id;
    }

    /// Ingest a file from disk.
    pub fn ingestFile(self: *Catalog, path: []const u8, meta: ImportMeta) !EntityId {
        const rec = try self.importer.importFile(path, meta, .auto);
        const id  = rec.id;
        try self.texts.put(rec);
        for (meta.thematic_tags) |tag| {
            try self.tag_index.index(tag, id);
        }
        return id;
    }

    /// Find texts by thematic tag.
    pub fn findByTag(self: *Catalog, tag: []const u8) []const EntityId {
        return self.tag_index.lookup(tag);
    }

    /// Find texts by language (ISO 639-3).
    pub fn findByLanguage(
        self: *Catalog,
        lang: []const u8,
        out: *std.ArrayList(EntityId),
    ) !void {
        for (self.texts.items.items) |t| {
            if (std.mem.eql(u8, t.language, lang)) try out.append(t.id);
        }
    }

    /// Find texts by source tradition.
    pub fn findByTradition(
        self: *Catalog,
        tradition: []const u8,
        out: *std.ArrayList(EntityId),
    ) !void {
        for (self.texts.items.items) |t| {
            if (std.mem.eql(u8, t.source_tradition, tradition)) try out.append(t.id);
        }
    }

    pub fn count(self: Catalog) usize { return self.texts.count(); }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Catalog ingest and tag lookup" {
    const allocator = std.testing.allocator;
    var seq  = IdSequence.init();
    var cat  = Catalog.init(allocator, &seq);
    defer cat.deinit();

    const tags = [_][]const u8{ "philosophy", "ethics" };
    const id = try cat.ingest(
        "Know thyself.",
        .{ .title = "Aphorism", .author = "Socrates", .language = "grc",
           .thematic_tags = @constCast(&tags) },
    );
    try std.testing.expectEqual(@as(usize, 1), cat.count());
    const by_tag = cat.findByTag("philosophy");
    try std.testing.expectEqual(@as(usize, 1), by_tag.len);
    try std.testing.expectEqual(id, by_tag[0]);
}
