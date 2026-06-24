//! query.zig — query parser and dispatcher: keyword, semantic, cross-link, name lookup
//! Phase 10 — src/search/

const std = @import("std");
const Allocator  = std.mem.Allocator;
const EntityId   = @import("../common/id.zig").EntityId;
const UnifiedSearchIndex = @import("index.zig").UnifiedSearchIndex;
const SearchResult = @import("index.zig").SearchResult;
const Embedder   = @import("../rag/embedder.zig").Embedder;

// ---------------------------------------------------------------------------
// Query kinds
// ---------------------------------------------------------------------------

pub const QueryKind = enum {
    keyword,    // exact word match
    semantic,   // embedding similarity
    hybrid,     // keyword + semantic, merged and re-ranked
    name,       // name-specific lookup (naming engine)
};

pub const Query = struct {
    text:  []const u8,
    kind:  QueryKind,
    top_k: usize = 10,
};

// ---------------------------------------------------------------------------
// QueryEngine
// ---------------------------------------------------------------------------

pub const QueryEngine = struct {
    index:     *UnifiedSearchIndex,
    embedder:  *Embedder,
    allocator: Allocator,

    pub fn init(
        allocator: Allocator,
        index: *UnifiedSearchIndex,
        embedder: *Embedder,
    ) QueryEngine {
        return .{ .index = index, .embedder = embedder, .allocator = allocator };
    }

    /// Run a query. Returns owned []SearchResult. Caller frees.
    pub fn run(self: *QueryEngine, q: Query) ![]SearchResult {
        return switch (q.kind) {
            .keyword  => try self.runKeyword(q),
            .semantic => try self.runSemantic(q),
            .hybrid   => try self.runHybrid(q),
            .name     => try self.runKeyword(q), // name search uses keyword layer
        };
    }

    fn runKeyword(self: *QueryEngine, q: Query) ![]SearchResult {
        var ids = std.ArrayList(EntityId).init(self.allocator);
        defer ids.deinit();
        try self.index.searchKeyword(q.text, &ids);
        var results = try self.allocator.alloc(SearchResult, @min(ids.items.len, q.top_k));
        for (results, 0..) |*r, i| {
            r.* = .{ .entity_id = ids.items[i], .score = 1.0, .kind = "entity", .excerpt = q.text };
        }
        return results;
    }

    fn runSemantic(self: *QueryEngine, q: Query) ![]SearchResult {
        const emb = try self.embedder.embed(self.allocator, q.text);
        defer self.allocator.free(emb);
        const scored = try self.index.searchSemantic(emb, q.top_k);
        defer self.allocator.free(scored);
        var results = try self.allocator.alloc(SearchResult, scored.len);
        for (results, scored) |*r, s| {
            r.* = .{ .entity_id = @intCast(s.doc_id), .score = s.score, .kind = "entity", .excerpt = "" };
        }
        return results;
    }

    fn runHybrid(self: *QueryEngine, q: Query) ![]SearchResult {
        const kw  = try self.runKeyword(q);
        defer self.allocator.free(kw);
        const sem = try self.runSemantic(q);
        defer self.allocator.free(sem);
        // Simple merge: keyword results first, then semantic (deduplicated in Phase 12).
        var merged = try self.allocator.alloc(SearchResult, kw.len + sem.len);
        @memcpy(merged[0..kw.len], kw);
        @memcpy(merged[kw.len..], sem);
        return merged;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Query struct defaults" {
    const q = Query{ .text = "logos", .kind = .keyword };
    try std.testing.expectEqual(@as(usize, 10), q.top_k);
    try std.testing.expectEqual(QueryKind.keyword, q.kind);
}
