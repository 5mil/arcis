const std = @import("std");
const Embedder    = @import("embedder.zig").Embedder;
const VectorIndex = @import("index.zig").VectorIndex;
const SearchResult = @import("index.zig").SearchResult;
const Chunk       = @import("chunker.zig").Chunk;

/// A retrieved passage with its score and original chunk text.
pub const RetrievedPassage = struct {
    source_id:  []const u8,
    chunk_idx:  usize,
    score:      f32,
    text:       []const u8,
};

/// Retriever: embeds a query and retrieves the top-k most similar chunks.
pub const Retriever = struct {
    embedder:  *Embedder,
    index:     *VectorIndex,
    /// All chunks stored in the index, indexed by (source_id, chunk_idx).
    chunk_store: std.ArrayList(Chunk),
    allocator:   std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        embedder: *Embedder,
        index: *VectorIndex,
    ) Retriever {
        return .{
            .embedder    = embedder,
            .index       = index,
            .chunk_store = std.ArrayList(Chunk).init(allocator),
            .allocator   = allocator,
        };
    }

    pub fn deinit(self: *Retriever) void {
        for (self.chunk_store.items) |*c| c.deinit();
        self.chunk_store.deinit();
    }

    /// Ingest a document: chunk it, embed each chunk, add to index.
    pub fn ingest(
        self: *Retriever,
        text: []const u8,
        source_id: []const u8,
        chunk_cfg: @import("chunker.zig").ChunkerConfig,
    ) !void {
        const chunker = @import("chunker.zig");
        var chunks = try chunker.chunk(self.allocator, text, source_id, chunk_cfg);
        defer chunks.deinit();

        for (chunks.items) |*c| {
            var emb = try self.embedder.embed(c.text);
            defer emb.deinit();
            _ = try self.index.add(c.source_id, c.chunk_idx, emb.vec);
            // Move chunk into store for text retrieval.
            try self.chunk_store.append(c.*);
        }
    }

    /// Retrieve top-k passages for a query string.
    /// Caller owns the returned slice.
    pub fn retrieve(
        self: *Retriever,
        query: []const u8,
        top_k: usize,
    ) ![]RetrievedPassage {
        var q_emb = try self.embedder.embed(query);
        defer q_emb.deinit();

        const results = try self.index.search(q_emb.vec, top_k);
        defer self.allocator.free(results);

        var passages = try self.allocator.alloc(RetrievedPassage, results.len);
        for (results, 0..) |r, i| {
            // Find matching chunk in store.
            var text: []const u8 = "";
            for (self.chunk_store.items) |c| {
                if (std.mem.eql(u8, c.source_id, r.source_id) and c.chunk_idx == r.chunk_idx) {
                    text = c.text;
                    break;
                }
            }
            passages[i] = .{
                .source_id = r.source_id,
                .chunk_idx = r.chunk_idx,
                .score     = r.score,
                .text      = text,
            };
        }
        return passages;
    }
};
