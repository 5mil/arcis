const std = @import("std");
const Embedding = @import("embedder.zig").Embedding;
const cosineSim = @import("embedder.zig").cosineSimilarity;

/// A stored vector with its source chunk reference.
pub const VectorEntry = struct {
    id:        u64,
    source_id: []u8,
    chunk_idx: usize,
    vec:       []f32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *VectorEntry) void {
        self.allocator.free(self.source_id);
        self.allocator.free(self.vec);
    }
};

/// A retrieval result.
pub const SearchResult = struct {
    id:        u64,
    source_id: []const u8,
    chunk_idx: usize,
    score:     f32,
};

/// Flat in-memory vector index with brute-force cosine search.
/// Suitable for up to ~100k entries; HNSW will be added as a tier-3 upgrade.
pub const VectorIndex = struct {
    entries:   std.ArrayList(VectorEntry),
    dim:       usize,
    next_id:   u64,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, dim: usize) VectorIndex {
        return .{
            .entries   = std.ArrayList(VectorEntry).init(allocator),
            .dim       = dim,
            .next_id   = 1,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *VectorIndex) void {
        for (self.entries.items) |*e| e.deinit();
        self.entries.deinit();
    }

    /// Add a normalized embedding to the index.
    pub fn add(
        self: *VectorIndex,
        source_id: []const u8,
        chunk_idx: usize,
        vec: []const f32,
    ) !u64 {
        std.debug.assert(vec.len == self.dim);
        const id = self.next_id;
        self.next_id += 1;
        const owned_vec = try self.allocator.dupe(f32, vec);
        const owned_sid = try self.allocator.dupe(u8, source_id);
        try self.entries.append(.{
            .id        = id,
            .source_id = owned_sid,
            .chunk_idx = chunk_idx,
            .vec       = owned_vec,
            .allocator = self.allocator,
        });
        return id;
    }

    /// Brute-force top-k cosine search. Returns sorted results slice.
    /// Caller owns returned slice.
    pub fn search(
        self: *const VectorIndex,
        query: []const f32,
        top_k: usize,
    ) ![]SearchResult {
        std.debug.assert(query.len == self.dim);
        var results = try self.allocator.alloc(SearchResult, self.entries.items.len);
        defer self.allocator.free(results);

        for (self.entries.items, 0..) |e, i| {
            results[i] = .{
                .id        = e.id,
                .source_id = e.source_id,
                .chunk_idx = e.chunk_idx,
                .score     = cosineSim(query, e.vec),
            };
        }

        std.mem.sort(SearchResult, results, {}, struct {
            pub fn lessThan(_: void, a: SearchResult, b: SearchResult) bool {
                return a.score > b.score;
            }
        }.lessThan);

        const k = @min(top_k, results.len);
        const out = try self.allocator.dupe(SearchResult, results[0..k]);
        return out;
    }
};
