//! index.zig — unified search index: full-text keyword + semantic vector search
//! Phase 10 — src/search/
//! Depends on: src/common/schema.zig, src/rag/embedder.zig, src/rag/index.zig
//! Mirrors: src/rag/index.zig (vector search) + adds keyword layer

const std = @import("std");
const Allocator  = std.mem.Allocator;
const EntityId   = @import("../common/id.zig").EntityId;
const Embedder   = @import("../rag/embedder.zig").Embedder;
const VectorIndex = @import("../rag/index.zig").VectorIndex;
const ScoredDoc  = @import("../rag/index.zig").ScoredDoc;

// ---------------------------------------------------------------------------
// SearchResult
// ---------------------------------------------------------------------------

pub const SearchResult = struct {
    entity_id: EntityId,
    score:     f32,
    kind:      []const u8,   // "concept", "text", "name"
    excerpt:   []const u8,   // snippet; not owned by SearchResult
};

// ---------------------------------------------------------------------------
// KeywordIndex — inverted word index
// ---------------------------------------------------------------------------

pub const KeywordIndex = struct {
    map:       std.StringHashMap(std.ArrayList(EntityId)),
    allocator: Allocator,

    pub fn init(allocator: Allocator) KeywordIndex {
        return .{ .map = std.StringHashMap(std.ArrayList(EntityId)).init(allocator), .allocator = allocator };
    }

    pub fn deinit(self: *KeywordIndex) void {
        var it = self.map.valueIterator();
        while (it.next()) |v| v.deinit();
        self.map.deinit();
    }

    /// Index a document: tokenize text into words, map each word → entity_id.
    pub fn indexDocument(self: *KeywordIndex, entity_id: EntityId, text: []const u8) !void {
        var it = std.mem.tokenizeAny(u8, text, " \t\n\r,.;:!?\"'()[]{}");
        while (it.next()) |word| {
            if (word.len < 2) continue;
            const gop = try self.map.getOrPut(word);
            if (!gop.found_existing)
                gop.value_ptr.* = std.ArrayList(EntityId).init(self.allocator);
            // Avoid duplicate entries per document.
            var found = false;
            for (gop.value_ptr.items) |id| { if (id == entity_id) { found = true; break; } }
            if (!found) try gop.value_ptr.append(entity_id);
        }
    }

    /// Keyword search: returns all entity IDs matching the query word.
    pub fn search(self: *KeywordIndex, word: []const u8, out: *std.ArrayList(EntityId)) !void {
        const list = self.map.get(word) orelse return;
        try out.appendSlice(list.items);
    }
};

// ---------------------------------------------------------------------------
// UnifiedSearchIndex
// ---------------------------------------------------------------------------

pub const UnifiedSearchIndex = struct {
    keyword:   KeywordIndex,
    vectors:   VectorIndex,
    allocator: Allocator,

    pub fn init(allocator: Allocator) UnifiedSearchIndex {
        return .{
            .keyword  = KeywordIndex.init(allocator),
            .vectors  = VectorIndex.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *UnifiedSearchIndex) void {
        self.keyword.deinit();
        self.vectors.deinit();
    }

    /// Add a document to both keyword and vector indexes.
    pub fn add(
        self: *UnifiedSearchIndex,
        entity_id: EntityId,
        text: []const u8,
        embedding: []const f32,
    ) !void {
        try self.keyword.indexDocument(entity_id, text);
        try self.vectors.add(@intCast(entity_id), embedding);
    }

    /// Keyword search. Returns matching entity IDs.
    pub fn searchKeyword(
        self: *UnifiedSearchIndex,
        query: []const u8,
        out: *std.ArrayList(EntityId),
    ) !void {
        var words = std.mem.tokenizeAny(u8, query, " \t\n");
        while (words.next()) |word| {
            try self.keyword.search(word, out);
        }
    }

    /// Semantic vector search. Returns top-k ScoredDocs.
    pub fn searchSemantic(
        self: *UnifiedSearchIndex,
        query_embedding: []const f32,
        top_k: usize,
    ) ![]ScoredDoc {
        return try self.vectors.topK(self.allocator, query_embedding, top_k);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "KeywordIndex index and search" {
    const allocator = std.testing.allocator;
    var ki = KeywordIndex.init(allocator);
    defer ki.deinit();
    try ki.indexDocument(1, "The logos of being");
    try ki.indexDocument(2, "The eidos of becoming");
    var out = std.ArrayList(EntityId).init(allocator);
    defer out.deinit();
    try ki.search("logos", &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqual(@as(EntityId, 1), out.items[0]);
}
